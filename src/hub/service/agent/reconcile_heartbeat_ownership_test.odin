package agent

// reconcile_bridge_heartbeat ownership tests.
//
// This proc returns instances to a caller that destroys them, and it had NO tests
// when its signature changed from a bare count to []Agent_Instance — which is
// exactly how it shipped a version whose own deferred destroy freed every element
// before the caller ever read it. The caller then read freed strings, freed them a
// second time, and called free() on string literals.
//
// These tests pin the OWNERSHIP CONTRACT rather than the status arithmetic:
//   - a returned instance's strings are readable AFTER the call returns, and carry
//     the right values (a use-after-free reads garbage, not the right id);
//   - destroying the returned instances, as every real caller does, is safe and is
//     the ONLY destroy they need — no element is freed twice;
//   - the overwritten fields are heap clones, not the literals or the single shared
//     clock string that made the double-free one pointer freed once per instance.
//
// They go through reconcile_bridge_heartbeat itself on purpose. The AC12 service
// tests call shell_session_background_runs_for_agent directly and never touch this
// wiring, so they passed throughout.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

@(private = "file")
Hb_Repo :: struct {
	instances: [dynamic]domain.Agent_Instance,
	saves:     int,
}

// Returns freshly CLONED instances, like the sqlite repo does: the caller of
// list_instances_by_bridge owns what it gets back. A fake that handed out aliases
// of its own storage would hide exactly the bug under test.
@(private = "file")
hb_list_by_bridge :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	r := (^Hb_Repo)(ctx)
	out := make([]domain.Agent_Instance, len(r.instances))
	for inst, i in r.instances {
		c: domain.Agent_Instance
		c.agent_instance_id = strings.clone(inst.agent_instance_id)
		c.owner_user_id     = domain.User_ID(strings.clone(string(inst.owner_user_id)))
		c.agent_id          = strings.clone(inst.agent_id)
		c.bridge_id         = strings.clone(inst.bridge_id)
		c.runtime_status    = strings.clone(inst.runtime_status)
		c.startup_status    = strings.clone(inst.startup_status)
		c.activity_status   = strings.clone(inst.activity_status)
		c.updated_at        = strings.clone(inst.updated_at)
		c.stopped_at        = strings.clone(inst.stopped_at)
		c.last_seen_at      = strings.clone(inst.last_seen_at)
		c.created_at        = strings.clone(inst.created_at)
		out[i] = c
	}
	return out, domain.Domain_Error{}
}

// Returns its INPUT verbatim, which is what agent_repo_sqlite does. That is the
// property that made the defect reachable: the returned struct aliases whatever the
// caller handed in, so the caller's own ownership decisions are the only thing
// keeping it valid.
@(private = "file")
hb_save_instance :: proc(ctx: rawptr, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	r := (^Hb_Repo)(ctx)
	r.saves += 1
	return instance, true, domain.Domain_Error{}
}

@(private = "file")
HB_NOW :: "2026-09-28T10:00:00Z"

@(private = "file")
hb_now :: proc(ctx: rawptr) -> string { _ = ctx; return HB_NOW }

@(private = "file")
hb_service :: proc(repo: ^iface.Agent_Repository, clk: ^platform.Clock) -> Agent_Service {
	svc: Agent_Service
	svc.agents = repo
	svc.clock  = clk
	return svc
}

@(private = "file")
hb_instance :: proc(id, status: string) -> domain.Agent_Instance {
	return domain.Agent_Instance{
		agent_instance_id = id,
		owner_user_id     = domain.User_ID("owner_a"),
		agent_id          = "agt_a",
		bridge_id         = "brg_1",
		runtime_status    = status,
		startup_status    = "ready",
		activity_status   = "idle",
		updated_at        = "2026-09-28T09:00:00Z",
		stopped_at        = "",
		last_seen_at      = "2026-09-28T09:00:00Z",
		created_at        = "2026-09-28T08:00:00Z",
	}
}

// The core contract: what comes back is still readable, and still correct, after
// the proc has returned and done its own cleanup.
@(test)
test_reconcile_heartbeat_returns_instances_the_caller_can_read_and_own :: proc(t: ^testing.T) {
	r: Hb_Repo
	r.instances = make([dynamic]domain.Agent_Instance)
	defer delete(r.instances)
	append(&r.instances, hb_instance("inst_gone", "running"))
	append(&r.instances, hb_instance("inst_here", "running"))

	repo := iface.Agent_Repository{
		ctx                      = rawptr(&r),
		list_instances_by_bridge = hb_list_by_bridge,
		save_instance            = hb_save_instance,
	}
	clk := platform.Clock{ctx = nil, now = hb_now}
	svc := hb_service(&repo, &clk)

	// inst_here is still reported active; inst_gone has dropped out.
	active := []string{"inst_here"}
	changed := reconcile_bridge_heartbeat(&svc, "brg_1", active)

	testing.expect_value(t, len(changed), 1)
	if len(changed) != 1 do return

	// READ AFTER RETURN. Under the defect these strings were already freed, so this
	// read is the assertion — it must be the right id, not merely non-empty.
	testing.expect_value(t, changed[0].agent_instance_id, "inst_gone")
	testing.expect_value(t, string(changed[0].owner_user_id), "owner_a")
	testing.expect_value(t, changed[0].runtime_status, "unreachable")
	testing.expect_value(t, changed[0].startup_status, "stopped")
	testing.expect_value(t, changed[0].updated_at, HB_NOW)
	testing.expect_value(t, changed[0].stopped_at, HB_NOW)

	// The overwritten fields must be independently owned clones, not the literal
	// "unreachable" and not two aliases of the one clock string. If updated_at and
	// stopped_at were the same pointer, destroying the instance would free it twice.
	testing.expect(t, raw_data(changed[0].updated_at) != raw_data(changed[0].stopped_at),
		"updated_at and stopped_at must be separate allocations, not two aliases of `now`")
	// raw_data needs a typed string, so the literals are bound first; comparing the
	// POINTERS is the point — equal contents prove nothing about ownership.
	clock_string: string = HB_NOW
	unreachable_literal: string = "unreachable"
	testing.expect(t, raw_data(changed[0].updated_at) != raw_data(clock_string),
		"updated_at must be a clone, not an alias of the clock's own string")
	testing.expect(t, raw_data(changed[0].runtime_status) != raw_data(unreachable_literal),
		"runtime_status must be a clone, not a string literal in static storage")

	// EXACTLY ONE destroy, by the caller — which is what every real call site does
	// (bridge_handlers.odin and app/reaper.odin both `defer agent_instances_destroy`).
	// A blanket destroy inside the proc would make this the second free.
	for i in 0 ..< len(changed) do domain.agent_instance_destroy(&changed[i])
	delete(changed)
}

// The instances that do NOT escape must be destroyed by the proc, or every
// heartbeat leaks the whole roster. Exercised by a heartbeat where nothing changed:
// there is nothing to return, so every instance took the internal-destroy path.
@(test)
test_reconcile_heartbeat_owns_the_instances_it_does_not_return :: proc(t: ^testing.T) {
	r: Hb_Repo
	r.instances = make([dynamic]domain.Agent_Instance)
	defer delete(r.instances)
	append(&r.instances, hb_instance("inst_a", "running"))
	append(&r.instances, hb_instance("inst_b", "running"))

	repo := iface.Agent_Repository{
		ctx                      = rawptr(&r),
		list_instances_by_bridge = hb_list_by_bridge,
		save_instance            = hb_save_instance,
	}
	clk := platform.Clock{ctx = nil, now = hb_now}
	svc := hb_service(&repo, &clk)

	// Both still active: nothing is marked unreachable, so nothing escapes.
	changed := reconcile_bridge_heartbeat(&svc, "brg_1", []string{"inst_a", "inst_b"})
	testing.expect_value(t, len(changed), 0)
	// last_seen_at is refreshed for both, which is the branch that must still not
	// leak or double-free.
	testing.expect_value(t, r.saves, 2)
}

// An instance already in a non-active state is neither saved nor returned, and is
// still cleaned up.
@(test)
test_reconcile_heartbeat_ignores_already_inactive_instances :: proc(t: ^testing.T) {
	r: Hb_Repo
	r.instances = make([dynamic]domain.Agent_Instance)
	defer delete(r.instances)
	append(&r.instances, hb_instance("inst_stopped", "stopped"))

	repo := iface.Agent_Repository{
		ctx                      = rawptr(&r),
		list_instances_by_bridge = hb_list_by_bridge,
		save_instance            = hb_save_instance,
	}
	clk := platform.Clock{ctx = nil, now = hb_now}
	svc := hb_service(&repo, &clk)

	changed := reconcile_bridge_heartbeat(&svc, "brg_1", []string{})
	testing.expect_value(t, len(changed), 0)
	testing.expect_value(t, r.saves, 0)
}
