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
	test_status_transitions_and_completed_at()
	test_manual_start_demotes_in_progress()
	test_ngtm_rework_precedence()
	test_pending_validation_demotes_other_tasks()
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
	// Phase 2: the runner-up work task for a busy assignee is demoted to Queued
	// (held back), not left in Assigned, so exactly one work item is active.
	check(b.status == .Queued, "second task must be queued while assignee busy")

	// While inst_x is busy, no further promotion.
	n = taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 0, "busy assignee must not get a second in_progress task")
	b, _, _ = task_get(&r, "task_b")
	check(b.status == .Queued, "runner-up stays queued on a stable recompute")
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

// --- Transitions: Paused, Cancelled, Completed and completed_at behavior ---
test_status_transitions_and_completed_at :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	// 1. Check valid_task_transition directly
	check(taskchain_service.valid_task_transition(.Paused, .In_Progress), "Paused -> In_Progress must be valid")
	check(taskchain_service.valid_task_transition(.Paused, .Assigned), "Paused -> Assigned must be valid")
	check(taskchain_service.valid_task_transition(.Paused, .Cancelled), "Paused -> Cancelled must be valid")
	check(!taskchain_service.valid_task_transition(.Paused, .Completed), "Paused -> Completed must be invalid")

	check(taskchain_service.valid_task_transition(.Cancelled, .Assigned), "Cancelled -> Assigned must be valid (uncancel)")
	check(!taskchain_service.valid_task_transition(.Cancelled, .In_Progress), "Cancelled -> In_Progress must be invalid")
	check(!taskchain_service.valid_task_transition(.Cancelled, .Completed), "Cancelled -> Completed must be invalid")

	check(taskchain_service.valid_task_transition(.Completed, .Assigned), "Completed -> Assigned must be valid (re-open)")
	check(taskchain_service.valid_task_transition(.Completed, .In_Progress), "Completed -> In_Progress must be valid (re-open to work)")
	check(taskchain_service.valid_task_transition(.Completed, .In_Validation), "Completed -> In_Validation must be valid (re-validate)")
	check(!taskchain_service.valid_task_transition(.Completed, .Cancelled), "Completed -> Cancelled must be invalid")

	// 2. Check change_task_status and completed_at behavior
	chain := domain.Task_Chain{chain_id = "chain_trans", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	task := domain.Task{
		task_id = "task_t1",
		chain_id = "chain_trans",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .In_Progress,
		assignee_ref_json = assignee_ref("inst_worker"),
		created_at = "2026-07-22T09:00:00Z",
		started_at = "2026-07-22T09:00:00Z",
	}
	task_save(&r, task)

	// In_Progress -> Paused
	ret, ok, _ := taskchain_service.change_task_status(&service, auth, "task_t1", .Paused)
	check(ok, "transition to Paused must succeed")
	check(ret.status == .Paused, "returned status must be Paused")
	check(ret.completed_at == "", "completed_at must be empty on Paused")
	t, _, _ := task_get(&r, "task_t1")
	check(t.status == .Paused, "persisted status must be Paused")
	check(t.completed_at == "", "persisted completed_at must be empty on Paused")

	// Paused -> Assigned (ret is Assigned; post-reconcile idle instance auto-promotes to In_Progress)
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Assigned)
	check(ok, "transition Paused -> Assigned must succeed")
	check(ret.status == .Assigned, "returned status must be Assigned")
	check(ret.completed_at == "", "completed_at must be empty on Assigned")
	t, _, _ = task_get(&r, "task_t1")
	check(t.completed_at == "", "completed_at must be empty after auto-promotion")

	// In_Progress -> Cancelled
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Cancelled)
	check(ok, "transition to Cancelled must succeed")
	check(ret.status == .Cancelled, "returned status must be Cancelled")
	check(ret.completed_at == "2026-07-22T10:00:00Z", "completed_at must be set on Cancelled")
	t, _, _ = task_get(&r, "task_t1")
	check(t.status == .Cancelled, "persisted status must be Cancelled")
	check(t.completed_at == "2026-07-22T10:00:00Z", "persisted completed_at must be set on Cancelled")

	// Cancelled -> Assigned (uncancel: ret is Assigned; completed_at cleared)
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Assigned)
	check(ok, "transition Cancelled -> Assigned (uncancel) must succeed")
	check(ret.status == .Assigned, "returned status must be Assigned after uncancel")
	check(ret.completed_at == "", "completed_at must be cleared after uncancel to Assigned")
	t, _, _ = task_get(&r, "task_t1")
	check(t.completed_at == "", "persisted completed_at must be cleared after uncancel")

	// In_Progress -> In_Validation -> Completed
	_, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .In_Validation)
	check(ok, "transition to In_Validation must succeed")
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Completed)
	check(ok, "transition to Completed must succeed")
	check(ret.status == .Completed, "returned status must be Completed")
	check(ret.completed_at == "2026-07-22T10:00:00Z", "completed_at must be set on Completed")
	t, _, _ = task_get(&r, "task_t1")
	check(t.status == .Completed, "persisted status must be Completed")
	check(t.completed_at == "2026-07-22T10:00:00Z", "persisted completed_at must be set on Completed")

	// Completed -> Assigned (re-open: ret is Assigned; completed_at cleared)
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Assigned)
	check(ok, "transition Completed -> Assigned (re-open) must succeed")
	check(ret.status == .Assigned, "returned status must be Assigned after re-open")
	check(ret.completed_at == "", "completed_at must be cleared after re-open to Assigned")
	t, _, _ = task_get(&r, "task_t1")
	check(t.completed_at == "", "persisted completed_at must be cleared after re-open")

	// In_Progress -> In_Validation -> Completed
	_, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .In_Validation)
	_, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Completed)
	t, _, _ = task_get(&r, "task_t1")
	check(t.completed_at != "", "completed_at must be set on Completed")

	// Completed -> In_Progress (re-open directly to In_Progress)
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .In_Progress)
	check(ok, "transition Completed -> In_Progress must succeed")
	check(ret.status == .In_Progress, "returned status must be In_Progress")
	check(ret.completed_at == "", "completed_at must be cleared after re-open to In_Progress")
	t, _, _ = task_get(&r, "task_t1")
	check(t.status == .In_Progress, "persisted status must be In_Progress")
	check(t.completed_at == "", "persisted completed_at must be cleared after re-open to In_Progress")

	// In_Progress -> In_Validation -> Completed
	_, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .In_Validation)
	_, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .Completed)
	t, _, _ = task_get(&r, "task_t1")
	check(t.completed_at != "", "completed_at must be set on Completed")

	// Completed -> In_Validation (re-validate directly from Completed)
	ret, ok, _ = taskchain_service.change_task_status(&service, auth, "task_t1", .In_Validation)
	check(ok, "transition Completed -> In_Validation (re-validate) must succeed")
	check(ret.status == .In_Validation, "returned status must be In_Validation")
	check(ret.completed_at == "", "completed_at must be cleared after re-validate")
	t, _, _ = task_get(&r, "task_t1")
	check(t.status == .In_Validation, "persisted status must be In_Validation")
	check(t.completed_at == "", "persisted completed_at must be cleared after re-validate")
}

// --- Invariant: manual start of queued task demotes previous In_Progress task to Queued ---
test_manual_start_demotes_in_progress :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	chain := domain.Task_Chain{chain_id = "chain_manual", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	t1 := domain.Task{
		task_id = "task_m1",
		chain_id = "chain_manual",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .In_Progress,
		assignee_ref_json = assignee_ref("inst_w"),
		created_at = "2026-07-22T09:00:00Z",
		started_at = "2026-07-22T09:00:00Z",
		updated_at = "2026-07-22T09:00:00Z",
	}
	t2 := domain.Task{
		task_id = "task_m2",
		chain_id = "chain_manual",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .Queued,
		assignee_ref_json = assignee_ref("inst_w"),
		created_at = "2026-07-22T09:05:00Z",
		updated_at = "2026-07-22T09:05:00Z",
	}
	task_save(&r, t1)
	task_save(&r, t2)

	// Manual start of task_m2 (queued task) to In_Progress at a later time
	clock.now = proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T09:10:00Z" }
	_, ok, err := taskchain_service.change_task_status(&service, auth, "task_m2", .In_Progress)
	check(ok, fmt.tprintf("manual start of task_m2 failed: %v", err.message))

	// Verify post-reconcile invariant:
	// task_m2 is now In_Progress, task_m1 has been demoted to Queued
	m1, _, _ := task_get(&r, "task_m1")
	m2, _, _ := task_get(&r, "task_m2")
	check(m2.status == .In_Progress, "manually started task must be In_Progress")
	check(m1.status == .Queued, "previous In_Progress task must be demoted to Queued")
}

// --- Invariant: NGTM on validation task demotes existing In_Progress task to Queued and focuses rework ---
test_ngtm_rework_precedence :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)

	chain := domain.Task_Chain{chain_id = "chain_ngtm", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	t_active := domain.Task{
		task_id = "task_active",
		chain_id = "chain_ngtm",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .In_Progress,
		priority = .P0,
		assignee_ref_json = assignee_ref("inst_w"),
		created_at = "2026-07-22T09:00:00Z",
		started_at = "2026-07-22T09:00:00Z",
		updated_at = "2026-07-22T09:00:00Z",
	}
	t_rework := domain.Task{
		task_id = "task_rework",
		chain_id = "chain_ngtm",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .Validated_Not_Good,
		priority = .P2,
		assignee_ref_json = assignee_ref("inst_w"),
		created_at = "2026-07-22T09:05:00Z",
		updated_at = "2026-07-22T09:05:00Z",
	}
	task_save(&r, t_active)
	task_save(&r, t_rework)

	// Run reconcile
	_ = taskchain_service.recompute_chain_promotions(&service, chain)

	// task_rework (Validated_Not_Good) must take precedence over task_active,
	// promoting task_rework to In_Progress and demoting task_active to Queued.
	act, _, _ := task_get(&r, "task_active")
	rew, _, _ := task_get(&r, "task_rework")
	check(rew.status == .In_Progress, "rework task must be promoted to In_Progress")
	check(act.status == .Queued, "active task must be demoted to Queued in favor of rework")
}

// --- Invariant: instance awaiting review has 0 active In_Progress tasks ---
test_pending_validation_demotes_other_tasks :: proc() {
	r: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = fake_id}
	repo := make_repo(&r)
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)

	chain := domain.Task_Chain{chain_id = "chain_pv", owner_user_id = "alice", publish_state = .Published, status = .Active}
	chain_save(&r, chain)

	t_val := domain.Task{
		task_id = "task_val",
		chain_id = "chain_pv",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .In_Validation,
		assignee_ref_json = assignee_ref("inst_w"),
		created_at = "2026-07-22T09:00:00Z",
	}
	t_other := domain.Task{
		task_id = "task_other",
		chain_id = "chain_pv",
		owner_user_id = "alice",
		publish_state = .Published,
		status = .In_Progress,
		assignee_ref_json = assignee_ref("inst_w"),
		created_at = "2026-07-22T09:05:00Z",
	}
	task_save(&r, t_val)
	task_save(&r, t_other)

	_ = taskchain_service.recompute_chain_promotions(&service, chain)

	// t_other must be demoted to Queued, so inst_w has 0 active In_Progress tasks
	val, _, _ := task_get(&r, "task_val")
	oth, _, _ := task_get(&r, "task_other")
	check(val.status == .In_Validation, "task_val must stay In_Validation")
	check(oth.status == .Queued, "task_other must be demoted to Queued while awaiting review")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
