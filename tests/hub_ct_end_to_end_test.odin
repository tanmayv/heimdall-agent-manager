package hub_ct_end_to_end_test

// Phase 6 end-to-end validation of the Current-Task & Notification-Gating feature
// (all CT REQ-IDs together). One instance (inst_dual) is BOTH assignee (of three
// work tasks with mixed P0/P1/P2 priorities) AND reviewer (of a task in
// validation). Drives the real service functions and asserts, in one flow:
//   - review-over-work (R7): the review task is the current focus, not the P0 work
//   - priority ordering (CT-3/CT-4): among work, P0 > P1 > P2
//   - oldest-first tiebreak (CT-4): equal priority -> earliest created_at
//   - other unblocked work tasks demoted to Queued (CT-2/R2)
//   - auto-advance on completion (CT-5/CT-10): reviewer advances off a resolved
//     task; the next-highest work becomes current and goes In_Progress
//   - notification gating (CT-6/R4) with the correct work-vs-review action label
//     (R8): a status/comment notify only wakes the recipient for its CURRENT task.

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

E :: struct {
	chains:    [4]domain.Task_Chain,
	chain_n:   int,
	tasks:     [32]domain.Task,
	task_n:    int,
	deps:      [16]domain.Task_Dependency,
	dep_n:     int,
	insts:     [8]domain.Agent_Instance,
	inst_n:    int,
	members:   [8]domain.Task_Chain_Member,
	member_n:  int,
	votes:     [16]domain.Task_Vote,
	vote_n:    int,
	cmds:      [64]string,
	cmd_n:     int,
	seq:       int,
}
e: E

enow :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
eid :: proc(ctx: rawptr, prefix: string) -> string { e.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", e.seq)}) }

ec_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	for i in 0..<e.chain_n { if e.chains[i].chain_id == id do return e.chains[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "chain")
}
ec_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	for i in 0..<e.chain_n { if e.chains[i].chain_id == c.chain_id { e.chains[i] = c; return c, true, {} } }
	e.chains[e.chain_n] = c; e.chain_n += 1; return c, true, {}
}
ec_list :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain)
	for i in 0..<e.chain_n { if e.chains[i].owner_user_id == owner do append(&out, e.chains[i]) }
	return out[:], {}
}
et_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	for i in 0..<e.task_n { if e.tasks[i].task_id == id do return e.tasks[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "task")
}
et_save :: proc(ctx: rawptr, t: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	for i in 0..<e.task_n { if e.tasks[i].task_id == t.task_id { e.tasks[i] = t; return t, true, {} } }
	e.tasks[e.task_n] = t; e.task_n += 1; return t, true, {}
}
et_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	out := make([dynamic]domain.Task)
	for i in 0..<e.task_n { if e.tasks[i].chain_id == chain_id do append(&out, e.tasks[i]) }
	return out[:], {}
}
ed_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<e.dep_n { if e.deps[i].chain_id == chain_id do append(&out, e.deps[i]) }
	return out[:], {}
}
em_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<e.member_n { if e.members[i].chain_id == chain_id do append(&out, e.members[i]) }
	return out[:], {}
}
ev_save :: proc(ctx: rawptr, v: domain.Task_Vote) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	e.votes[e.vote_n] = v; e.vote_n += 1; return v, true, {}
}
ev_list :: proc(ctx: rawptr, task_id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	out := make([dynamic]domain.Task_Vote)
	for i in 0..<e.vote_n { if e.votes[i].task_id == task_id do append(&out, e.votes[i]) }
	return out[:], {}
}
ecm_save :: proc(ctx: rawptr, c: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) { return c, true, {} }

ea_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for i in 0..<e.inst_n { if e.insts[i].agent_instance_id == id do return e.insts[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "inst")
}
ea_save :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	for i in 0..<e.inst_n { if e.insts[i].agent_instance_id == inst.agent_instance_id { e.insts[i] = inst; return inst, true, {} } }
	e.insts[e.inst_n] = inst; e.inst_n += 1; return inst, true, {}
}
ea_by_bridge :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<e.inst_n { if e.insts[i].bridge_id == bridge_id do append(&out, e.insts[i]) }
	return out[:], {}
}
esink :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	e.cmds[e.cmd_n] = strings.clone(cmd.body_json); e.cmd_n += 1; return true, {}
}

earef :: proc(id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, id, `"}`}) }
errefs :: proc(id: string) -> string { return strings.concatenate({`[{"type":"agent_instance","agent_instance_id":"`, id, `"}]`}) }

// count commands whose body contains BOTH needles.
cmds_with :: proc(a, b: string) -> int {
	n := 0
	for i in 0..<e.cmd_n { if strings.contains(e.cmds[i], a) && strings.contains(e.cmds[i], b) do n += 1 }
	return n
}

instance_current :: proc(id: string) -> (string, domain.Current_Task_Role) {
	inst, _, _ := ea_get(nil, id)
	return inst.current_task_id, inst.current_task_role
}

main :: proc() {
	clock := platform.Clock{ctx = nil, now = enow}
	ids := platform.ID_Generator{ctx = nil, generate = eid}
	repo := iface.Taskchain_Repository{
		ctx = nil, get_chain = ec_get, save_chain = ec_save, list_chains_by_owner = ec_list,
		get_task = et_get, save_task = et_save, list_tasks_by_chain = et_list,
		list_dependencies_by_chain = ed_list, list_members_by_chain = em_list,
		save_vote = ev_save, list_votes_by_task = ev_list, save_comment = ecm_save,
	}
	agents := iface.Agent_Repository{ctx = nil, get_instance = ea_get, save_instance = ea_save, list_instances_by_bridge = ea_by_bridge}
	sink := project_service.Bridge_Command_Sink{ctx = nil, send_runtime_command = esink}
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)
	proxy := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	// Chain with the dual-role instance as coordinator + the author of the review task.
	ec_save(nil, domain.Task_Chain{chain_id = "chain_e", owner_user_id = "alice", publish_state = .Published, status = .Active, coordinator_agent_instance_id = "inst_dual"})
	e.members[e.member_n] = domain.Task_Chain_Member{chain_id = "chain_e", agent_instance_id = "inst_dual", owner_user_id = "alice", role = "coordinator"}; e.member_n += 1
	e.members[e.member_n] = domain.Task_Chain_Member{chain_id = "chain_e", agent_instance_id = "inst_author", owner_user_id = "alice", role = "worker"}; e.member_n += 1

	ea_save(nil, domain.Agent_Instance{agent_instance_id = "inst_dual", owner_user_id = "alice", chain_id = "chain_e", bridge_id = "brg_d", runtime_status = "running"})
	ea_save(nil, domain.Agent_Instance{agent_instance_id = "inst_author", owner_user_id = "alice", chain_id = "chain_e", bridge_id = "brg_a", runtime_status = "running"})

	// Three WORK tasks assigned to inst_dual: P1(early), P1(late), P0. Plus a review
	// task authored by inst_author and reviewed by inst_dual, currently In_Validation.
	et_save(nil, domain.Task{task_id = "w_p1_early", chain_id = "chain_e", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = earef("inst_dual"), created_at = "2026-07-22T09:00:00Z"})
	et_save(nil, domain.Task{task_id = "w_p1_late", chain_id = "chain_e", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P1, assignee_ref_json = earef("inst_dual"), created_at = "2026-07-22T09:30:00Z"})
	et_save(nil, domain.Task{task_id = "w_p0", chain_id = "chain_e", owner_user_id = "alice", publish_state = .Published, status = .Assigned, priority = .P0, assignee_ref_json = earef("inst_dual"), created_at = "2026-07-22T09:15:00Z"})
	et_save(nil, domain.Task{task_id = "r_task", chain_id = "chain_e", owner_user_id = "alice", publish_state = .Published, status = .In_Validation, priority = .P2, assignee_ref_json = earef("inst_author"), reviewer_refs_json = errefs("inst_dual"), created_at = "2026-07-22T09:45:00Z", started_at = "2026-07-22T09:00:00Z"})

	chain, _, _ := ec_get(nil, "chain_e")

	// --- Recompute: review-over-work wins the focus ---------------------------
	_ = taskchain_service.recompute_chain_promotions(&service, chain)
	cur, role := instance_current("inst_dual")
	check(cur == "r_task" && role == .Review, "R7: review task must be inst_dual's current focus over any work")
	// All three work tasks demoted/held to Queued (none In_Progress) while reviewing.
	for id in ([?]string{"w_p0", "w_p1_early", "w_p1_late"}) {
		t, _, _ := et_get(nil, domain.Task_ID(id))
		check(t.status == .Queued, fmt.tprintf("work task %s must be Queued while inst_dual reviews", id))
	}

	// --- Gating: a status notify on a WORK task must NOT wake inst_dual (its
	// current task is r_task); a comment on r_task DOES wake it, labeled review. --
	e.cmd_n = 0
	w_p0, _, _ := et_get(nil, "w_p0")
	taskchain_service.notify_task_status_change(&service, contracts.Auth_Context{}, w_p0, chain)
	check(cmds_with("inst_dual", "w_p0") == 0, "CT-6: inst_dual must be gated out of a work notify while its current task is the review")

	e.cmd_n = 0
	r_task_now, _, _ := et_get(nil, "r_task")
	taskchain_service.notify_task_comment(&service, "inst_author", r_task_now)
	check(cmds_with("inst_dual", "r_task") == 1, "R4: comment on the review task wakes inst_dual (its current task)")
	check(cmds_with("inst_dual", `"action":"review"`) == 1, "R8: comment wake to a reviewer must be labeled review")

	// --- Reviewer resolves the review (LGTM -> Completed): auto-advance ---------
	// inst_dual is done reviewing; its focus must advance to the highest-priority
	// oldest work task (P0), which auto-promotes to In_Progress (CT-5/CT-10).
	ev_save(nil, domain.Task_Vote{task_id = "r_task", chain_id = "chain_e", owner_user_id = "alice", reviewer_agent_instance_id = "inst_dual", vote = "lgtm", created_at = "2026-07-22T10:00:00Z"})
	rt, _, _ := et_get(nil, "r_task")
	taskchain_service.evaluate_task_quorum(&service, rt)

	rt2, _, _ := et_get(nil, "r_task")
	check(rt2.status == .Completed, "LGTM quorum finalizes the review task to Completed")
	cur2, role2 := instance_current("inst_dual")
	check(cur2 == "w_p0" && role2 == .Work, "CT-5: after review resolves, focus auto-advances to the P0 work task (role work)")
	wp0b, _, _ := et_get(nil, "w_p0")
	check(wp0b.status == .In_Progress, "the newly-focused P0 work task auto-promotes to In_Progress")
	// The two P1 tasks remain Queued behind the P0.
	for id in ([?]string{"w_p1_early", "w_p1_late"}) {
		t, _, _ := et_get(nil, domain.Task_ID(id))
		check(t.status == .Queued, fmt.tprintf("lower-priority work %s stays Queued behind the P0", id))
	}

	// --- Complete the P0; focus advances to P1 with oldest-first tiebreak -------
	for st in ([?]domain.Task_Status{.In_Validation}) {
		_, ok, err := taskchain_service.change_task_status(&service, proxy, "w_p0", st)
		check(ok, fmt.tprintf("w_p0 -> %v failed: %s", st, err.message))
	}
	// w_p0 is now In_Validation; inst_dual is its assignee (cannot review own task),
	// so it should advance to the next actionable WORK: the earlier-created P1.
	cur3, role3 := instance_current("inst_dual")
	check(cur3 == "w_p1_early" && role3 == .Work, "CT-4 tiebreak: focus advances to the OLDEST equal-priority P1 (w_p1_early)")
	e_early, _, _ := et_get(nil, "w_p1_early")
	check(e_early.status == .In_Progress, "the oldest P1 auto-promotes to In_Progress")
	e_late, _, _ := et_get(nil, "w_p1_late")
	check(e_late.status == .Queued, "the later P1 stays Queued behind the oldest P1")

	// --- Gating with the new focus: a status notify on w_p1_early (now the current
	// task) wakes inst_dual labeled work; one on w_p1_late (Queued) does not. ------
	e.cmd_n = 0
	early_now, _, _ := et_get(nil, "w_p1_early")
	taskchain_service.notify_task_status_change(&service, contracts.Auth_Context{}, early_now, chain)
	check(cmds_with("inst_dual", "w_p1_early") == 1, "status notify on the current work task wakes inst_dual")
	check(cmds_with("inst_dual", `"action":"work"`) == 1, "R8: work wake must be labeled work")

	fmt.println("PASS: hub CT end-to-end (dual-role review-over-work, priority, tiebreak, queued demotion, auto-advance, gated labeled notifications)")
}
