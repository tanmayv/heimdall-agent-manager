package hub_instance_reaper_test

// Unit tests for stale-running cleanup (task_18d0d69935b13c01):
//   - mark_bridge_instances_unreachable: clears a disconnected bridge's instances
//   - reap_stale_instances: time-based sweep by last_seen_at
//   - rfc3339_to_unix_ms: the timestamp parser the reaper relies on
// Uses a small in-memory Agent_Repository and a mutable clock so we control time.

import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import platform "odin_test:hub/platform"

Fake_Repo :: struct {
	instances: [32]domain.Agent_Instance,
	count:     int,
}

fake_save_instance :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.instances[i].agent_instance_id == inst.agent_instance_id {
			repo.instances[i] = inst
			return inst, true, domain.Domain_Error{}
		}
	}
	repo.instances[repo.count] = inst
	repo.count += 1
	return inst, true, domain.Domain_Error{}
}

fake_list_by_bridge :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<repo.count {
		if repo.instances[i].bridge_id == bridge_id do append(&out, repo.instances[i])
	}
	return out[:], domain.Domain_Error{}
}

fake_list_active_runtime :: proc(ctx: rawptr) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<repo.count {
		s := repo.instances[i].runtime_status
		if s == "running" || s == "idle" || s == "busy" || s == "launching" || s == "starting" || s == "stopping" {
			append(&out, repo.instances[i])
		}
	}
	return out[:], domain.Domain_Error{}
}

fake_get_instance :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.instances[i].agent_instance_id == id do return repo.instances[i], true, domain.Domain_Error{}
	}
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "nf")
}

now_value: string = "2026-08-31T10:00:00Z"
fake_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return now_value }

find_status :: proc(repo: ^Fake_Repo, id: string) -> string {
	for i in 0..<repo.count { if repo.instances[i].agent_instance_id == id do return repo.instances[i].runtime_status }
	return "<missing>"
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }

main :: proc() {
	// --- rfc3339_to_unix_ms sanity ---
	epoch, ok0 := agent_service.rfc3339_to_unix_ms("1970-01-01T00:00:00Z")
	check(ok0 && epoch == 0, "epoch must parse to 0 ms")
	oneday, ok1 := agent_service.rfc3339_to_unix_ms("1970-01-02T00:00:00Z")
	check(ok1 && oneday == 86_400_000, "1970-01-02 must be 86400000 ms")
	t1, _ := agent_service.rfc3339_to_unix_ms("2026-08-31T10:00:00Z")
	t2, _ := agent_service.rfc3339_to_unix_ms("2026-08-31T10:01:30Z")
	check(t2 - t1 == 90_000, "90s delta must parse to 90000 ms")
	_, bad := agent_service.rfc3339_to_unix_ms("not-a-timestamp")
	check(!bad, "malformed timestamp must return ok=false")

	repo := new(Fake_Repo)
	agents := iface.Agent_Repository{
		ctx = rawptr(repo),
		save_instance = fake_save_instance,
		get_instance = fake_get_instance,
		list_instances_by_bridge = fake_list_by_bridge,
		list_active_runtime_instances = fake_list_active_runtime,
	}
	clock := platform.Clock{ctx = nil, now = fake_clock_now}
	svc := agent_service.Agent_Service{agents = &agents, clock = &clock}

	// Seed: two instances on a dead bridge (running+idle), one already stopped,
	// plus one instance on a live bridge that is fresh.
	fresh := now_value
	_, _, _ = fake_save_instance(rawptr(repo), domain.Agent_Instance{agent_instance_id = "inst_dead_running", bridge_id = "brg_dead", runtime_status = "running", activity_status = "active", last_seen_at = fresh})
	_, _, _ = fake_save_instance(rawptr(repo), domain.Agent_Instance{agent_instance_id = "inst_dead_idle", bridge_id = "brg_dead", runtime_status = "idle", activity_status = "idle", last_seen_at = fresh})
	_, _, _ = fake_save_instance(rawptr(repo), domain.Agent_Instance{agent_instance_id = "inst_dead_stopped", bridge_id = "brg_dead", runtime_status = "stopped", activity_status = "idle", last_seen_at = fresh})
	_, _, _ = fake_save_instance(rawptr(repo), domain.Agent_Instance{agent_instance_id = "inst_live_fresh", bridge_id = "brg_live", runtime_status = "running", activity_status = "active", last_seen_at = fresh})

	// --- mark_bridge_instances_unreachable clears only the dead bridge's ACTIVE ones ---
	cleared := agent_service.mark_bridge_instances_unreachable(&svc, "brg_dead")
	check(len(cleared) == 2, "disconnect must clear exactly the 2 active instances on the dead bridge")
	check(find_status(repo, "inst_dead_running") == "unreachable", "dead running -> unreachable")
	check(find_status(repo, "inst_dead_idle") == "unreachable", "dead idle -> unreachable")
	check(find_status(repo, "inst_dead_stopped") == "stopped", "already-stopped stays stopped")
	check(find_status(repo, "inst_live_fresh") == "running", "other bridge untouched by disconnect")

	// --- reap_stale_instances: only the stale one on the live bridge is reaped ---
	// Add a stale running instance (last_seen 5 minutes ago) and a fresh one.
	_, _, _ = fake_save_instance(rawptr(repo), domain.Agent_Instance{agent_instance_id = "inst_stale", bridge_id = "brg_live", runtime_status = "running", activity_status = "idle", last_seen_at = "2026-08-31T09:55:00Z"})
	reaped := agent_service.reap_stale_instances(&svc, 90_000) // 90s threshold
	// inst_stale is 300s old -> reaped; inst_live_fresh is 0s old -> kept.
	found_stale := false
	for inst in reaped { if inst.agent_instance_id == "inst_stale" do found_stale = true }
	check(found_stale, "5-min-stale running instance must be reaped")
	check(find_status(repo, "inst_stale") == "unreachable", "stale -> unreachable")
	check(find_status(repo, "inst_live_fresh") == "running", "fresh instance must NOT be reaped")

	// Second reap is a no-op (nothing left stale+active on freshness terms).
	reaped2 := agent_service.reap_stale_instances(&svc, 90_000)
	check(len(reaped2) == 0, "reap must be idempotent once stale rows are cleared")

	_ = strings.trim_space("")
	fmt.println("PASS: hub instance reaper (disconnect clear + staleness sweep + rfc3339)")
}
