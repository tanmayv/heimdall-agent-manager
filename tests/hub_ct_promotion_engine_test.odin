package hub_ct_promotion_engine_test

// Phase 2 (CT-4, CT-5, CT-7) auto-promotion engine verification.
//
// Exercises recompute_chain_promotions against an in-memory fake Taskchain +
// Agent repository and asserts the single-current-task model:
//   - priority ordering: P0 > P1 > P2 picks the current work task (CT-3/CT-4)
//   - oldest-first tiebreak within equal priority (CT-4)
//   - runner-up unblocked work tasks demoted to Queued (CT-2/CT-4)
//   - review WINS over work when one instance is both assignee and reviewer (R7)
//   - the instance current_task pointer (id + role) is persisted (CT-1/CT-4)
//   - auto-advance: completing the focus advances to the next task (CT-5)
//   - reassign-away / instance-clear consistency helper (CT-7)

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import project_service "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

// --- Fake repositories -------------------------------------------------------

Fake :: struct {
	chains:     [8]domain.Task_Chain,
	chain_n:    int,
	tasks:      [32]domain.Task,
	task_n:     int,
	deps:       [16]domain.Task_Dependency,
	dep_n:      int,
	instances:  [16]domain.Agent_Instance,
	inst_n:     int,
	votes:      [16]domain.Task_Vote,
	vote_n:     int,
	sent_cmds:  int,
	last_cmd:   string,
	seq:        int,
}

clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string {
	f := (^Fake)(ctx); f.seq += 1
	return strings.concatenate({prefix, fmt.tprintf("%d", f.seq)})
}

// taskchain repo procs
tc_chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.chain_n { if f.chains[i].chain_id == id do return f.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "chain not found")
}
tc_chain_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.chain_n { if f.chains[i].chain_id == c.chain_id { f.chains[i] = c; return c, true, {} } }
	f.chains[f.chain_n] = c; f.chain_n += 1; return c, true, {}
}
tc_task_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.task_n { if f.tasks[i].task_id == id do return f.tasks[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "task not found")
}
tc_task_save :: proc(ctx: rawptr, t: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.task_n { if f.tasks[i].task_id == t.task_id { f.tasks[i] = t; return t, true, {} } }
	f.tasks[f.task_n] = t; f.task_n += 1; return t, true, {}
}
tc_task_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	f := (^Fake)(ctx)
	out := make([dynamic]domain.Task)
	for i in 0..<f.task_n { if f.tasks[i].chain_id == chain_id do append(&out, f.tasks[i]) }
	return out[:], {}
}
tc_dep_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	f := (^Fake)(ctx)
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<f.dep_n { if f.deps[i].chain_id == chain_id do append(&out, f.deps[i]) }
	return out[:], {}
}

// agent repo procs
ag_inst_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.inst_n { if f.instances[i].agent_instance_id == id do return f.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "instance not found")
}
ag_inst_save :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.inst_n { if f.instances[i].agent_instance_id == inst.agent_instance_id { f.instances[i] = inst; return inst, true, {} } }
	f.instances[f.inst_n] = inst; f.inst_n += 1; return inst, true, {}
}

tc_dep_remove :: proc(ctx: rawptr, task_id, depends_on_task_id: domain.Task_ID, owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.dep_n {
		if f.deps[i].task_id == task_id && f.deps[i].depends_on_task_id == depends_on_task_id {
			// compact-remove
			f.deps[i] = f.deps[f.dep_n-1]; f.dep_n -= 1; return true, {}
		}
	}
	return false, {}
}
tc_vote_save :: proc(ctx: rawptr, v: domain.Task_Vote) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	f.votes[f.vote_n] = v; f.vote_n += 1; return v, true, {}
}
tc_vote_list :: proc(ctx: rawptr, task_id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	f := (^Fake)(ctx)
	out := make([dynamic]domain.Task_Vote)
	for i in 0..<f.vote_n { if f.votes[i].task_id == task_id do append(&out, f.votes[i]) }
	return out[:], {}
}

make_tc_repo :: proc(f: ^Fake) -> iface.Taskchain_Repository {
	return iface.Taskchain_Repository{
		ctx = rawptr(f),
		get_chain = tc_chain_get, save_chain = tc_chain_save,
		get_task = tc_task_get, save_task = tc_task_save,
		list_tasks_by_chain = tc_task_list,
		list_dependencies_by_chain = tc_dep_list,
		remove_dependency = tc_dep_remove,
		save_vote = tc_vote_save, list_votes_by_task = tc_vote_list,
	}
}
make_ag_repo :: proc(f: ^Fake) -> iface.Agent_Repository {
	return iface.Agent_Repository{ ctx = rawptr(f), get_instance = ag_inst_get, save_instance = ag_inst_save }
}

// Capturing bridge sink: records runtime commands so notification tests can
// assert a current-task-changed command was fanned out.
fake_send_runtime :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	f.sent_cmds += 1
	f.last_cmd = strings.clone(cmd.body_json)
	return true, {}
}
make_sink :: proc(f: ^Fake) -> project_service.Bridge_Command_Sink {
	return project_service.Bridge_Command_Sink{ctx = rawptr(f), send_runtime_command = fake_send_runtime}
}

aref :: proc(id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, id, `"}`}) }
rref :: proc(id: string) -> string { return strings.concatenate({`[{"type":"agent_instance","agent_instance_id":"`, id, `"}]`}) }

seed_instance :: proc(f: ^Fake, id: string) {
	ag_inst_save(rawptr(f), domain.Agent_Instance{agent_instance_id = id, owner_user_id = "alice", chain_id = "chain_p", bridge_id = "bridge_1"})
}

new_service :: proc(f: ^Fake, tc: ^iface.Taskchain_Repository, ag: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> taskchain_service.Taskchain_Service {
	return taskchain_service.new_taskchain_service(tc, ag, clock, ids)
}

main :: proc() {
	test_priority_and_demotion()
	test_oldest_first_tiebreak()
	test_review_wins_over_work()
	test_auto_advance()
	test_reassign_clears_pointer()
	test_review_resolution_ngtm()
	test_review_resolution_lgtm()
	test_manual_set_current_task()
	test_priority_patch_reorders()
	test_not_good_autopromotes_to_in_progress()
	test_unblock_preempts_busy_assignee()
	test_self_set_current_task()
	fmt.println("PASS: hub CT promotion engine (CT-4/CT-5/CT-7/CT-10 + manual set + priority patch)")
}

// --- CT-4: priority ordering + demotion to Queued + current_task pointer ------
test_priority_and_demotion :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	// Three eligible tasks for one instance with mixed priorities. P0 must win.
	tc_task_save(&f, domain.Task{task_id = "t_p2", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_p0", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P0, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:05:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_p1", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:02:00Z"})

	chain, _, _ := tc_chain_get(&f, "chain_p")
	n := taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 1, fmt.tprintf("expected 1 promotion (P0), got %d", n))

	p0, _, _ := tc_task_get(&f, "t_p0")
	p1, _, _ := tc_task_get(&f, "t_p1")
	p2, _, _ := tc_task_get(&f, "t_p2")
	check(p0.status == .In_Progress, "P0 must become the current work task (In_Progress)")
	check(p1.status == .Queued, "P1 runner-up must be demoted to Queued")
	check(p2.status == .Queued, "P2 runner-up must be demoted to Queued")

	// current_task pointer persisted on the instance (role=work).
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_p0", fmt.tprintf("current_task_id must be t_p0, got %q", inst.current_task_id))
	check(inst.current_task_role == .Work, "current_task_role must be Work")
}

// --- CT-4: oldest-first tiebreak within equal priority ------------------------
test_oldest_first_tiebreak :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	// Same priority; the earlier created_at must win the slot.
	tc_task_save(&f, domain.Task{task_id = "t_late", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:30:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_early", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:10:00Z"})

	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	early, _, _ := tc_task_get(&f, "t_early")
	late, _, _ := tc_task_get(&f, "t_late")
	check(early.status == .In_Progress, "earliest-created equal-priority task wins")
	check(late.status == .Queued, "later task queued")
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_early", "current_task points at earliest task")
}

// --- R7: review WINS over work for a dual-role instance -----------------------
test_review_wins_over_work :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	// inst_x is assignee of a P0 work task AND reviewer of a task in validation.
	// Review must win: the work task is demoted to Queued and the focus is review.
	tc_task_save(&f, domain.Task{task_id = "t_work", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P0, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_review", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .In_Validation, priority = .P2, assignee_ref_json = aref("inst_author"), reviewer_refs_json = rref("inst_x"), created_at = "2026-07-22T09:20:00Z"})

	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)

	work, _, _ := tc_task_get(&f, "t_work")
	review, _, _ := tc_task_get(&f, "t_review")
	check(review.status == .In_Validation, "review task status is untouched by promotion")
	check(work.status == .Queued, "work task demoted to Queued when review wins")
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_review", "review task becomes current_task")
	check(inst.current_task_role == .Review, "current_task_role must be Review (review wins over work)")
}

// --- CT-5: auto-advance to the next task when the focus completes -------------
test_auto_advance :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	tc_task_save(&f, domain.Task{task_id = "t_first", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P0, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_next", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:05:00Z"})

	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_first", "first focus is the P0 task")
	next, _, _ := tc_task_get(&f, "t_next")
	check(next.status == .Queued, "next task queued behind the focus")

	// Drive the focus through its lifecycle to Completed via change_task_status,
	// which recomputes the chain and must auto-advance the focus to t_next.
	for st in ([?]domain.Task_Status{.In_Progress, .In_Validation, .Validated_Good, .Completed}) {
		_, ok, err := taskchain_service.change_task_status(&service, auth, "t_first", st)
		check(ok, fmt.tprintf("t_first -> %v failed: %s", st, err.message))
	}

	inst, _, _ = ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_next", fmt.tprintf("focus must auto-advance to t_next, got %q", inst.current_task_id))
	check(inst.current_task_role == .Work, "advanced focus role is Work")
	next, _, _ = tc_task_get(&f, "t_next")
	check(next.status == .In_Progress, "auto-advanced task promoted to In_Progress")
}

// --- CT-7: clear_instance_current_task drops a stale pointer -------------------
test_reassign_clears_pointer :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	// Seed an instance already pointing at a task.
	ag_inst_save(rawptr(&f), domain.Agent_Instance{agent_instance_id = "inst_x", owner_user_id = "alice", chain_id = "chain_p", current_task_id = "t_gone", current_task_role = .Work})

	taskchain_service.clear_instance_current_task(&service, "inst_x")
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "", "current_task_id cleared")
	check(inst.current_task_role == .None, "current_task_role reset to None")
}

// --- CT-10: NGTM review resolution advances reviewer AND re-promotes rework ----
// A reviewer (inst_rev) is focused on a task in validation; the author (inst_dev)
// is its assignee. An NGTM vote resolves the task to Validated_Not_Good. After
// evaluate_task_quorum: (a) the reviewer advances off the resolved task, and
// (b) the not-good task re-enters the assignee's focus via auto-promotion.
test_review_resolution_ngtm :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_dev")
	seed_instance(&f, "inst_rev")

	// Task under review, authored by inst_dev, reviewed by inst_rev.
	tc_task_save(&f, domain.Task{task_id = "t_rev", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .In_Validation, priority = .P1, assignee_ref_json = aref("inst_dev"), reviewer_refs_json = rref("inst_rev"), created_at = "2026-07-22T09:00:00Z", started_at = "2026-07-22T09:00:00Z"})

	// Establish focus: reviewer points at t_rev (role review); assignee has no
	// other actionable work so points nowhere.
	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	rev, _, _ := ag_inst_get(&f, "inst_rev")
	check(rev.current_task_id == "t_rev" && rev.current_task_role == .Review, "reviewer focus is the review task before the vote")

	// Record an NGTM vote and evaluate quorum (the vote path).
	tc_vote_save(rawptr(&f), domain.Task_Vote{task_id = "t_rev", chain_id = "chain_p", owner_user_id = "alice", reviewer_agent_instance_id = "inst_rev", vote = "ngtm", created_at = "2026-07-22T10:00:00Z"})
	task, _, _ := tc_task_get(&f, "t_rev")
	taskchain_service.evaluate_task_quorum(&service, task)

	// CT-10 req 1: reviewer advanced off the resolved task (no other review work).
	rev, _, _ = ag_inst_get(&f, "inst_rev")
	check(rev.current_task_id == "" && rev.current_task_role == .None, "reviewer focus cleared after NGTM resolution")

	// CT-10 req 2: the not-good task re-entered the assignee's focus (role work)
	// automatically via the recompute the NGTM path now triggers. Because the
	// engine is now actively resuming the rework, the picked-up Validated_Not_Good
	// task also advances to In_Progress.
	resolved, _, _ := tc_task_get(&f, "t_rev")
	check(resolved.status == .In_Progress, "picked-up not-good rework auto-advances to In_Progress")
	dev, _, _ := ag_inst_get(&f, "inst_dev")
	check(dev.current_task_id == "t_rev", fmt.tprintf("assignee must re-focus the not-good rework, got %q", dev.current_task_id))
	check(dev.current_task_role == .Work, "rework focus role is Work")
}

// --- CT-10: LGTM review resolution advances reviewer + unblocks dependents -----
test_review_resolution_lgtm :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_dev")
	seed_instance(&f, "inst_rev")

	// t_rev under review; t_down depends on it and is assigned to inst_dev.
	tc_task_save(&f, domain.Task{task_id = "t_rev", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .In_Validation, priority = .P1, assignee_ref_json = aref("inst_author"), reviewer_refs_json = rref("inst_rev"), created_at = "2026-07-22T09:00:00Z", started_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_down", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_dev"), created_at = "2026-07-22T09:05:00Z"})
	f.deps[f.dep_n] = domain.Task_Dependency{task_id = "t_down", depends_on_task_id = "t_rev", chain_id = "chain_p", owner_user_id = "alice"}
	f.dep_n += 1

	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	rev, _, _ := ag_inst_get(&f, "inst_rev")
	check(rev.current_task_id == "t_rev" && rev.current_task_role == .Review, "reviewer focused on review task pre-vote")
	down, _, _ := tc_task_get(&f, "t_down")
	check(down.status == .Assigned, "dependent stays assigned while parent under review")

	// Single required reviewer LGTM -> quorum auto-finalizes to Completed.
	tc_vote_save(rawptr(&f), domain.Task_Vote{task_id = "t_rev", chain_id = "chain_p", owner_user_id = "alice", reviewer_agent_instance_id = "inst_rev", vote = "lgtm", created_at = "2026-07-22T10:00:00Z"})
	task, _, _ := tc_task_get(&f, "t_rev")
	taskchain_service.evaluate_task_quorum(&service, task)

	resolved, _, _ := tc_task_get(&f, "t_rev")
	check(resolved.status == .Completed, "LGTM quorum auto-finalizes to Completed")

	// Reviewer advanced off the completed task.
	rev, _, _ = ag_inst_get(&f, "inst_rev")
	check(rev.current_task_id == "" && rev.current_task_role == .None, "reviewer focus cleared after LGTM completion")

	// Dependent auto-promoted into the assignee's focus.
	down, _, _ = tc_task_get(&f, "t_down")
	check(down.status == .In_Progress, "dependent auto-promotes after parent completes")
	dev, _, _ := ag_inst_get(&f, "inst_dev")
	check(dev.current_task_id == "t_down" && dev.current_task_role == .Work, "assignee focus advances to the unblocked dependent")
}

// --- CT-9 manual override: coordinator/user sets an agent's current task -------
// Validates the happy paths (work + review) with notification, and the rejection
// paths (non-participant, non-actionable status).
test_manual_set_current_task :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	sink := make_sink(&f)
	service := taskchain_service.new_taskchain_service_with_runtime(&tc, &ag, sink, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_dev")
	seed_instance(&f, "inst_rev")

	// A work task (Assigned) for inst_dev, and an in-validation task reviewed by
	// inst_rev (authored by someone else). Also a not-yet-actionable draft.
	tc_task_save(&f, domain.Task{task_id = "t_work", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_dev"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_review", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .In_Validation, priority = .P2, assignee_ref_json = aref("inst_author"), reviewer_refs_json = rref("inst_rev"), created_at = "2026-07-22T09:10:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_draft", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Draft, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_dev"), created_at = "2026-07-22T09:20:00Z"})

	// Happy path — pin inst_dev to its work task; role resolves to Work + notified.
	f.sent_cmds = 0
	inst, ok, err := taskchain_service.set_instance_current_task(&service, auth, "inst_dev", "t_work")
	check(ok, fmt.tprintf("set work current task failed: %s", err.message))
	check(inst.current_task_id == "t_work" && inst.current_task_role == .Work, "work focus pinned")
	check(f.sent_cmds == 1, "agent notified on current-task change")
	check(strings.contains(f.last_cmd, "current_task_changed") && strings.contains(f.last_cmd, `"action":"work"`), "notify states work action (R8)")

	// Happy path — pin inst_rev to the review task; role resolves to Review.
	inst, ok, err = taskchain_service.set_instance_current_task(&service, auth, "inst_rev", "t_review")
	check(ok, fmt.tprintf("set review current task failed: %s", err.message))
	check(inst.current_task_id == "t_review" && inst.current_task_role == .Review, "review focus pinned")

	// Rejection — inst_rev is neither assignee nor reviewer of t_work.
	_, bad_ok, bad_err := taskchain_service.set_instance_current_task(&service, auth, "inst_rev", "t_work")
	check(!bad_ok && bad_err.code == .Forbidden, "non-participant rejected")

	// Rejection — the review task is not actionable WORK for its own author path;
	// here pin inst_author (assignee) to t_review which is In_Validation (not an
	// actionable work status for the assignee).
	seed_instance(&f, "inst_author")
	_, bad2_ok, bad2_err := taskchain_service.set_instance_current_task(&service, auth, "inst_author", "t_review")
	check(!bad2_ok && bad2_err.code == .Conflict, "non-actionable work status rejected")

	// Rejection — draft task cannot be focused.
	_, bad3_ok, bad3_err := taskchain_service.set_instance_current_task(&service, auth, "inst_dev", "t_draft")
	check(!bad3_ok && bad3_err.code == .Conflict, "draft task rejected")
}

// --- CT-9: an agent sets its OWN current task via instance-token auth ----------
// A non-coordinator instance token may move its own pointer (self-service focus
// switch), but must NOT be able to move another instance's pointer.
test_self_set_current_task :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	sink := make_sink(&f)
	service := taskchain_service.new_taskchain_service_with_runtime(&tc, &ag, sink, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_self")
	seed_instance(&f, "inst_other")

	// inst_self is assignee of two actionable tasks; it may pick either as focus.
	tc_task_save(&f, domain.Task{task_id = "t_1", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_self"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_2", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_self"), created_at = "2026-07-22T09:05:00Z"})
	// A task assigned to inst_other (inst_self must not be able to focus another).
	tc_task_save(&f, domain.Task{task_id = "t_other", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_other"), created_at = "2026-07-22T09:10:00Z"})

	self_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_self"}

	// Self-set to t_2 is allowed even though the engine's default pick would be t_1.
	inst, ok, err := taskchain_service.set_instance_current_task(&service, self_auth, "inst_self", "t_2")
	check(ok, fmt.tprintf("self-set current task failed: %s", err.message))
	check(inst.current_task_id == "t_2" && inst.current_task_role == .Work, "agent pinned its own current task")

	// Self-token cannot move another instance's pointer (not coordinator).
	_, bad_ok, bad_err := taskchain_service.set_instance_current_task(&service, self_auth, "inst_other", "t_other")
	check(!bad_ok && bad_err.code == .Forbidden, "non-coordinator instance cannot set another agent's current task")
}

// --- Stale-pointer fix: unblocking a task via remove_task_dependency reconciles
// the busy assignee's current_task pointer (a P0 task that was blocked behind a
// dependency preempts the in-progress P1 once unblocked). ---------------------
test_unblock_preempts_busy_assignee :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	// A P1 task inst_x can work now, and a higher-priority P0 task blocked behind a
	// (never-completing) gate task, all assigned to inst_x.
	tc_task_save(&f, domain.Task{task_id = "t_p1", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_p0", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P0, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:05:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_gate", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .In_Progress, priority = .P2, assignee_ref_json = aref("inst_other"), created_at = "2026-07-22T08:00:00Z"})
	f.deps[f.dep_n] = domain.Task_Dependency{task_id = "t_p0", depends_on_task_id = "t_gate", chain_id = "chain_p", owner_user_id = "alice"}
	f.dep_n += 1

	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_p1", "busy on P1 while P0 is blocked")

	// Unblock the P0 by removing its dependency; remove_task_dependency must
	// recompute and preempt the busy assignee onto the P0.
	_, err := taskchain_service.remove_task_dependency(&service, auth, "t_p0", "t_gate")
	check(err.code == .None, fmt.tprintf("remove dep failed: %s", err.message))
	inst, _, _ = ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_p0" && inst.current_task_role == .Work, "unblocked P0 must preempt the busy assignee's pointer")
	p0, _, _ := tc_task_get(&f, "t_p0")
	check(p0.status == .In_Progress, "unblocked P0 auto-promotes to In_Progress")
	p1, _, _ := tc_task_get(&f, "t_p1")
	check(p1.status == .Queued, "preempted P1 demoted to Queued")
}

// --- Auto-promotion picks up a Validated_Not_Good task -> In_Progress ----------
// When the engine selects a Validated_Not_Good task as the instance's current
// work focus, it auto-advances that task to In_Progress (the agent is resuming
// its rework), rather than leaving it resting in Validated_Not_Good.
test_not_good_autopromotes_to_in_progress :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	// A lone Validated_Not_Good task for the instance.
	tc_task_save(&f, domain.Task{task_id = "t_ng", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Validated_Not_Good, priority = .P1, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:00:00Z", started_at = "2026-07-22T09:00:00Z"})

	chain, _, _ := tc_chain_get(&f, "chain_p")
	n := taskchain_service.recompute_chain_promotions(&service, chain)
	check(n == 1, fmt.tprintf("expected the not-good task to auto-promote, got %d", n))
	t, _, _ := tc_task_get(&f, "t_ng")
	check(t.status == .In_Progress, "picked-up Validated_Not_Good task auto-advances to In_Progress")
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_ng" && inst.current_task_role == .Work, "not-good task becomes the current work focus")
}

// --- CT-9 priority patch re-orders the current-task selection -----------------
test_priority_patch_reorders :: proc() {
	f: Fake
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = gen_id}
	tc := make_tc_repo(&f); ag := make_ag_repo(&f)
	service := new_service(&f, &tc, &ag, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	tc_chain_save(&f, domain.Task_Chain{chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Active})
	seed_instance(&f, "inst_x")

	// Two P2 work tasks; the earlier one wins initially.
	tc_task_save(&f, domain.Task{task_id = "t_first", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:00:00Z"})
	tc_task_save(&f, domain.Task{task_id = "t_second", chain_id = "chain_p", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P2, assignee_ref_json = aref("inst_x"), created_at = "2026-07-22T09:05:00Z"})

	chain, _, _ := tc_chain_get(&f, "chain_p")
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	inst, _, _ := ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_first", "earliest P2 task is the initial focus")

	// Bump t_second to P0 via update_task; the recompute inside update_task must
	// re-order so t_second becomes the focus and t_first is demoted to Queued.
	_, ok, err := taskchain_service.update_task(&service, auth, "t_second", taskchain_service.Update_Task_Input{priority = .P0, has_priority = true})
	check(ok, fmt.tprintf("priority patch failed: %s", err.message))
	inst, _, _ = ag_inst_get(&f, "inst_x")
	check(inst.current_task_id == "t_second" && inst.current_task_role == .Work, "raising priority re-focuses to the P0 task")
	first, _, _ := tc_task_get(&f, "t_first")
	check(first.status == .Queued, "previously-focused task demoted to Queued after priority bump")
	second, _, _ := tc_task_get(&f, "t_second")
	check(second.status == .In_Progress, "newly-prioritized task promoted to In_Progress")
}
