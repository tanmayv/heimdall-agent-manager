package hub_task_promotion_nudge_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

// Fake repo with tasks + dependencies to exercise auto-promotion.
Fake_Repo :: struct {
	chains:     [8]domain.Task_Chain,
	chain_count: int,
	tasks:      [16]domain.Task,
	task_count: int,
	deps:       [16]domain.Task_Dependency,
	dep_count:  int,
	seq:        int,
}

fixed_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
fake_id :: proc(ctx: rawptr, prefix: string) -> string {
	r := (^Fake_Repo)(ctx); r.seq += 1
	return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)})
}

chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == id do return r.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == c.chain_id { r.chains[i] = c; return c, true, {} } }
	r.chains[r.chain_count] = c; r.chain_count += 1; return c, true, {}
}
task_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	for i in 0..<r.task_count { if r.tasks[i].task_id == id do return r.tasks[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "task not found")
}
task_save :: proc(ctx: rawptr, t: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	for i in 0..<r.task_count { if r.tasks[i].task_id == t.task_id { r.tasks[i] = t; return t, true, {} } }
	r.tasks[r.task_count] = t; r.task_count += 1; return t, true, {}
}
task_list_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task)
	for i in 0..<r.task_count { if r.tasks[i].chain_id == chain_id do append(&out, r.tasks[i]) }
	return out[:], {}
}
dep_list_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	r := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<r.dep_count { if r.deps[i].chain_id == chain_id do append(&out, r.deps[i]) }
	return out[:], {}
}

make_repo :: proc(r: ^Fake_Repo) -> iface.Taskchain_Repository {
	return iface.Taskchain_Repository{
		ctx = rawptr(r),
		get_chain = chain_get, save_chain = chain_save,
		get_task = task_get, save_task = task_save,
		list_tasks_by_chain = task_list_by_chain,
		list_dependencies_by_chain = dep_list_by_chain,
	}
}

assignee_ref :: proc(instance_id: string) -> string {
	return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, instance_id, `"}`})
}

main :: proc() {
	test_deps_and_promotion()
	test_assignee_serialization()
	test_cross_bridge_cascade()
	test_nudge_decision()
	fmt.println("PASS: hub task promotion + nudge decision")
}

// Cross-bridge cascade via the full mutation path: completing an upstream task
// (assignee on "bridge A") must auto-promote the downstream task whose assignee
// is a different instance ("bridge B"). recompute_chain_promotions is
// chain-scoped and assignee-agnostic, so the promotion happens regardless of
// which bridge hosts the downstream assignee; the Hub then fans out to B.
test_cross_bridge_cascade :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	chain := domain.Task_Chain{chain_id = "chain_x", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	// upstream on "bridge A" (inst_a), downstream on "bridge B" (inst_b), B depends on A.
	up := domain.Task{task_id = "up", chain_id = "chain_x", owner_user_id = "alice", publish_state = .Published, status = .In_Progress, assignee_ref_json = assignee_ref("inst_a"), created_at = "2026-07-22T09:00:00Z", started_at = "2026-07-22T09:00:00Z"}
	down := domain.Task{task_id = "down", chain_id = "chain_x", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_b"), created_at = "2026-07-22T09:01:00Z"}
	task_save(&r, up)
	task_save(&r, down)
	r.deps[r.dep_count] = domain.Task_Dependency{task_id = "down", depends_on_task_id = "up", chain_id = "chain_x", owner_user_id = "alice"}
	r.dep_count += 1

	// Downstream is blocked while upstream is open.
	blocked, blocked_ok, _ := taskchain_service.change_task_status(&service, auth, "down", .In_Progress)
	check(!blocked_ok, "downstream must not start while upstream open")
	_ = blocked

	// Drive upstream to terminal through the real valid transition chain, ending
	// in Completed. The Completed transition triggers the cascade recompute.
	for st in ([?]domain.Task_Status{.In_Validation, .Validated_Good, .Completed}) {
		_, ok, err := taskchain_service.change_task_status(&service, auth, "up", st)
		check(ok, fmt.tprintf("upstream transition failed: %v", err.message))
	}

	// The downstream (different bridge) task must now be auto-claimed by the
	// cascade fired inside change_task_status(Completed).
	d, _, _ := task_get(&r, "down")
	check(d.status == .In_Progress, "cross-bridge downstream must auto-promote after upstream completes")
}

// --- Promotion: dependency gating + auto-claim ---
test_deps_and_promotion :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)

	chain := domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	// parent (blocks child) + child that depends on parent, both assigned to same-ish
	// distinct assignees so serialization does not interfere here.
	parent := domain.Task{task_id = "task_parent", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_p"), created_at = "2026-07-22T09:00:00Z"}
	child := domain.Task{task_id = "task_child", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_c"), created_at = "2026-07-22T09:01:00Z"}
	task_save(&r, parent)
	task_save(&r, child)
	r.deps[r.dep_count] = domain.Task_Dependency{task_id = "task_child", depends_on_task_id = "task_parent", chain_id = "chain_1", owner_user_id = "alice"}
	r.dep_count += 1

	// First recompute: parent has no deps -> promotes; child blocked by parent -> stays.
	n := taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 1, fmt.tprintf("expected 1 promotion, got %d", n))
	p, _, _ := task_get(&r, "task_parent")
	c, _, _ := task_get(&r, "task_child")
	check(p.status == .In_Progress, "parent must auto-claim to in_progress")
	check(c.status == .Assigned, "child must remain assigned while parent open")
	check(p.started_at != "", "promoted task must set started_at")

	// Complete parent; child deps now satisfied -> promotes on next recompute.
	p.status = .Completed
	task_save(&r, p)
	n = taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 1, fmt.tprintf("expected 1 promotion after parent done, got %d", n))
	c, _, _ = task_get(&r, "task_child")
	check(c.status == .In_Progress, "child must auto-claim after parent completes")
}

// --- Promotion: one active task per assignee ---
test_assignee_serialization :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)

	chain := domain.Task_Chain{chain_id = "chain_s", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	// Two eligible tasks for the same assignee; only the earliest promotes.
	t1 := domain.Task{task_id = "task_b", chain_id = "chain_s", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_x"), created_at = "2026-07-22T09:05:00Z"}
	t2 := domain.Task{task_id = "task_a", chain_id = "chain_s", owner_user_id = "alice", publish_state = .Published, status = .Assigned, assignee_ref_json = assignee_ref("inst_x"), created_at = "2026-07-22T09:02:00Z"}
	task_save(&r, t1)
	task_save(&r, t2)

	n := taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 1, fmt.tprintf("expected exactly 1 promotion for one assignee, got %d", n))
	a, _, _ := task_get(&r, "task_a")
	b, _, _ := task_get(&r, "task_b")
	check(a.status == .In_Progress, "earliest-created task must win the assignee slot")
	check(b.status == .Assigned, "second task must wait while assignee busy")

	// While inst_x is busy, no further promotion.
	n = taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 0, "busy assignee must not get a second in_progress task")
}

// --- Nudge decision math ---
test_nudge_decision :: proc() {
	cfg := taskchain_service.default_nudge_config()
	cfg.enabled = true
	cfg.ready_after_seconds = 300
	cfg.working_stale_after_seconds = 900
	cfg.review_after_seconds = 300
	cfg.cooldown_seconds = 300

	now: i64 = 10_000_000

	// Disabled short-circuits.
	off := cfg; off.enabled = false
	d := taskchain_service.evaluate_nudge(off, .Assigned, now - 999_000, 0, now)
	check(!d.should_nudge && d.reason == "disabled", "disabled config must not nudge")

	// Not stale yet (Assigned, only 100s old vs 300s threshold).
	d = taskchain_service.evaluate_nudge(cfg, .Assigned, now - 100_000, 0, now)
	check(!d.should_nudge && d.reason == "not_stale", "fresh task must not nudge")

	// Stale Assigned -> nudge assignee.
	d = taskchain_service.evaluate_nudge(cfg, .Assigned, now - 400_000, 0, now)
	check(d.should_nudge && d.target == .Assignee, "stale assigned must nudge assignee")

	// Stale In_Validation -> nudge reviewer.
	d = taskchain_service.evaluate_nudge(cfg, .In_Validation, now - 400_000, 0, now)
	check(d.should_nudge && d.target == .Reviewer, "stale in_validation must nudge reviewer")

	// Cooldown active: last nudge 100s ago (< 300s cooldown).
	d = taskchain_service.evaluate_nudge(cfg, .Assigned, now - 400_000, now - 100_000, now)
	check(!d.should_nudge && d.reason == "cooldown", "recent nudge must be suppressed by cooldown")

	// Cooldown expired: last nudge 400s ago.
	d = taskchain_service.evaluate_nudge(cfg, .Assigned, now - 400_000, now - 400_000, now)
	check(d.should_nudge, "nudge allowed after cooldown expires")

	// Terminal status -> no target.
	d = taskchain_service.evaluate_nudge(cfg, .Completed, now - 999_000, 0, now)
	check(!d.should_nudge && d.target == .None, "completed task must not nudge")

	// Validated_Good targets coordinator but has no threshold -> no scheduled nudge.
	d = taskchain_service.evaluate_nudge(cfg, .Validated_Good, now - 999_000, 0, now)
	check(!d.should_nudge && d.reason == "no_threshold", "validated_good has no scheduled nudge threshold")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
