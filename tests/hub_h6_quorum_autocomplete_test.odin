package hub_h6_quorum_autocomplete_test

// H6: Auto-complete a task once all required reviewers approve it.
// When quorum is satisfied (no ngtm, lgtm_count >= required_count) a task in
// In_Validation must advance all the way to Completed (with completed_at set),
// NOT merely to Validated_Good. This is the only status that unblocks
// dependents, so dependent tasks must auto-promote to In_Progress afterwards.
// Auto-promotion must also WAKE the promoted assignee: recompute_chain_promotions
// emits a task_status_changed_notify runtime command to the assignee's bridge.
// Scenario (d) verifies that wake via a fake Bridge_Command_Sink + agents repo.

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import project "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

Fake_Repo :: struct {
	chains: [8]domain.Task_Chain,
	chain_count: int,
	tasks: [8]domain.Task,
	task_count: int,
	votes: [16]domain.Task_Vote,
	vote_count: int,
	deps: [8]domain.Task_Dependency,
	dep_count: int,
	members: [8]domain.Task_Chain_Member,
	member_count: int,
}

fixed_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
fixed_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	repo := (^Fake_Repo)(ctx)
	return strings.concatenate({prefix, fmt.tprintf("%d", repo.chain_count + repo.task_count + repo.vote_count + 1)})
}

chain_get :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.chain_count { if repo.chains[i].chain_id == chain_id do return repo.chains[i], true, domain.Domain_Error{} }
	return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.chain_count { if repo.chains[i].chain_id == chain.chain_id { repo.chains[i] = chain; return chain, true, domain.Domain_Error{} } }
	repo.chains[repo.chain_count] = chain; repo.chain_count += 1; return chain, true, domain.Domain_Error{}
}
task_save :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.task_count { if repo.tasks[i].task_id == task.task_id { repo.tasks[i] = task; return task, true, domain.Domain_Error{} } }
	repo.tasks[repo.task_count] = task; repo.task_count += 1; return task, true, domain.Domain_Error{}
}
task_get :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.task_count { if repo.tasks[i].task_id == task_id do return repo.tasks[i], true, domain.Domain_Error{} }
	return domain.Task{}, false, domain.domain_error(.Not_Found, "task not found")
}
tasks_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task)
	for i in 0..<repo.task_count { if repo.tasks[i].chain_id == chain_id do append(&out, repo.tasks[i]) }
	return out[:], domain.Domain_Error{}
}
deps_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task_Dependency)
	for i in 0..<repo.dep_count { if repo.deps[i].chain_id == chain_id do append(&out, repo.deps[i]) }
	return out[:], domain.Domain_Error{}
}
vote_save :: proc(ctx: rawptr, vote: domain.Task_Vote) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	// One vote per reviewer per task (upsert on reviewer id).
	for i in 0..<repo.vote_count {
		if repo.votes[i].task_id == vote.task_id && repo.votes[i].reviewer_agent_instance_id == vote.reviewer_agent_instance_id {
			repo.votes[i] = vote; return vote, true, domain.Domain_Error{}
		}
	}
	repo.votes[repo.vote_count] = vote; repo.vote_count += 1; return vote, true, domain.Domain_Error{}
}
votes_by_task :: proc(ctx: rawptr, task_id: domain.Task_ID, owner: domain.User_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task_Vote)
	for i in 0..<repo.vote_count { if repo.votes[i].task_id == task_id do append(&out, repo.votes[i]) }
	return out[:], domain.Domain_Error{}
}
members_by_chain :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<repo.member_count { if repo.members[i].chain_id == chain_id do append(&out, repo.members[i]) }
	return out[:], domain.Domain_Error{}
}
seed_member :: proc(repo: ^Fake_Repo, chain_id: domain.Task_Chain_ID, instance_id: string, role: string) {
	repo.members[repo.member_count] = domain.Task_Chain_Member{chain_id = chain_id, agent_instance_id = instance_id, owner_user_id = "alice", role = role}
	repo.member_count += 1
}

// Fake agents repo so promotion can resolve an assignee instance -> bridge_id and
// emit the wake command.
Agents :: struct {
	instances: [8]domain.Agent_Instance,
	count:     int,
}
agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	a := (^Agents)(ctx)
	for i in 0..<a.count { if a.instances[i].agent_instance_id == id do return a.instances[i], true, domain.Domain_Error{} }
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "instance")
}

// Captured runtime commands emitted by the bridge command sink (fire-and-forget).
Captured :: struct {
	bodies: [16]string,
	count:  int,
}
captured: Captured
capture_send :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	captured.bodies[captured.count] = strings.clone(command.body_json)
	captured.count += 1
	return true, domain.Domain_Error{}
}

// Seed a published, In_Validation task directly into the fake repo.
seed_task :: proc(repo: ^Fake_Repo, task_id: domain.Task_ID, chain_id: domain.Task_Chain_ID, reviewer_refs_json: string, assignee_ref_json: string, status: domain.Task_Status) {
	repo.tasks[repo.task_count] = domain.Task{
		task_id = task_id,
		chain_id = chain_id,
		owner_user_id = "alice",
		title = string(task_id),
		publish_state = .Published,
		status = status,
		reviewer_refs_json = reviewer_refs_json,
		assignee_ref_json = assignee_ref_json,
		created_at = "2026-07-22T09:00:00Z",
	}
	repo.task_count += 1
}

main :: proc() {
	repo_data: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&repo_data), generate = fixed_id_generate}
	repo := iface.Taskchain_Repository{
		ctx = rawptr(&repo_data),
		get_chain = chain_get, save_chain = chain_save,
		save_task = task_save, get_task = task_get,
		list_tasks_by_chain = tasks_by_chain,
		list_dependencies_by_chain = deps_by_chain,
		save_vote = vote_save, list_votes_by_task = votes_by_task,
		list_members_by_chain = members_by_chain,
	}
	// Wire an agents repo + a fake bridge command sink so auto-promotion can
	// resolve the promoted assignee's bridge and emit its wake command. This lets
	// scenario (d) assert the assignee is actually woken, not just status-flipped.
	agents_data: Agents
	// Child assignee (worker_c) lives on a bridge so promotion can wake it.
	agents_data.instances[0] = domain.Agent_Instance{agent_instance_id = "worker_c", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "idle"}
	agents_data.count = 1
	agents := iface.Agent_Repository{ctx = rawptr(&agents_data), get_instance = agent_get}
	sink := project.Bridge_Command_Sink{ctx = nil, send_runtime_command = capture_send}
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)
	// Trusted_Proxy auth: the reviewer-instance gate in record_task_vote only
	// applies to Instance_Token, so proxy votes exercise the quorum path cleanly.
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	// Active, published chain to host the tasks.
	repo_data.chains[0] = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .Active}
	repo_data.chain_count = 1
	// Reviewers must be chain members so Instance_Token votes pass the get_task
	// membership gate.
	seed_member(&repo_data, "chain_1", "rev_a", "reviewer")
	seed_member(&repo_data, "chain_1", "rev_b", "reviewer")

	// (a) Single required reviewer: one lgtm -> Completed (not Validated_Good).
	seed_task(&repo_data, "task_single", "chain_1",
		`[{"agent_instance_id":"rev_a"}]`, `[{"agent_instance_id":"worker_x"}]`, .In_Validation)
	_, v_ok, v_err := taskchain_service.record_task_vote(&service, auth,
		taskchain_service.Vote_Input{task_id = "task_single", vote = "lgtm"})
	check(v_ok, v_err.message)
	t, _, _ := task_get(rawptr(&repo_data), "task_single")
	check(t.status == .Completed, "single-reviewer approval must auto-complete (got not-Completed)")
	check(t.completed_at != "", "auto-completed task must stamp completed_at")

	// (b) Multi-reviewer: partial approval stays In_Validation; final -> Completed.
	seed_task(&repo_data, "task_multi", "chain_1",
		`[{"agent_instance_id":"rev_a"},{"agent_instance_id":"rev_b"}]`, `[{"agent_instance_id":"worker_x"}]`, .In_Validation)
	_, _, _ = taskchain_service.record_task_vote(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "rev_a"},
		taskchain_service.Vote_Input{task_id = "task_multi", vote = "lgtm"})
	tm, _, _ := task_get(rawptr(&repo_data), "task_multi")
	check(tm.status == .In_Validation, "1-of-2 approvals must stay In_Validation")
	_, _, _ = taskchain_service.record_task_vote(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "rev_b"},
		taskchain_service.Vote_Input{task_id = "task_multi", vote = "lgtm"})
	tm, _, _ = task_get(rawptr(&repo_data), "task_multi")
	check(tm.status == .Completed, "2-of-2 approvals must auto-complete")
	check(tm.completed_at != "", "multi-reviewer auto-complete must stamp completed_at")

	// (c) ngtm never completes the task. After the NGTM resolution the task lands
	// in Validated_Not_Good, and because its assignee (worker_x) has no other work,
	// the auto-promotion engine immediately picks the rework back up as the
	// assignee's current task and advances it to In_Progress (agents resume their
	// own rework automatically). The invariant this scenario guards is that ngtm
	// never yields Completed/Validated_Good.
	seed_task(&repo_data, "task_reject", "chain_1",
		`[{"agent_instance_id":"rev_a"}]`, `[{"agent_instance_id":"worker_x"}]`, .In_Validation)
	_, _, _ = taskchain_service.record_task_vote(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "rev_a"},
		taskchain_service.Vote_Input{task_id = "task_reject", vote = "ngtm"})
	tr, _, _ := task_get(rawptr(&repo_data), "task_reject")
	check(tr.status == .In_Progress, "ngtm rework must auto-promote back to In_Progress for its assignee")
	check(tr.status != .Completed && tr.status != .Validated_Good, "ngtm must never complete/approve the task")

	// (d) Dependency promotion: when a parent auto-completes, an Assigned child
	//     whose only dependency is that parent must promote to In_Progress.
	seed_task(&repo_data, "task_parent", "chain_1",
		`[{"agent_instance_id":"rev_a"}]`, `[{"agent_instance_id":"worker_p"}]`, .In_Validation)
	seed_task(&repo_data, "task_child", "chain_1",
		`[{"agent_instance_id":"rev_a"}]`, `[{"agent_instance_id":"worker_c"}]`, .Assigned)
	repo_data.deps[0] = domain.Task_Dependency{task_id = "task_child", depends_on_task_id = "task_parent", chain_id = "chain_1", owner_user_id = "alice"}
	repo_data.dep_count = 1
	captured.count = 0
	_, _, _ = taskchain_service.record_task_vote(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "rev_a"},
		taskchain_service.Vote_Input{task_id = "task_parent", vote = "lgtm"})
	tp, _, _ := task_get(rawptr(&repo_data), "task_parent")
	check(tp.status == .Completed, "parent must auto-complete on approval")
	tc, _, _ := task_get(rawptr(&repo_data), "task_child")
	check(tc.status == .In_Progress, "child must auto-promote to In_Progress after parent auto-completes")
	// Added acceptance criterion: auto-promotion must WAKE the promoted assignee.
	// recompute_chain_promotions emits a task_status_changed_notify runtime command
	// to worker_c's bridge. Assert a wake was captured and targets the child task
	// + its assignee.
	wake_found := false
	for i in 0..<captured.count {
		body := captured.bodies[i]
		if strings.contains(body, `"type":"task_status_changed_notify"`) &&
		   strings.contains(body, `"task_id":"task_child"`) &&
		   strings.contains(body, "worker_c") {
			wake_found = true
		}
	}
	check(captured.count >= 1, "auto-promotion must emit at least one runtime wake command")
	check(wake_found, "auto-promotion must wake the child assignee via task_status_changed_notify targeting task_child/worker_c")

	// (e) Idempotency: a late/duplicate vote after completion is a no-op and
	//     does not error or re-stamp/double-transition.
	dup_completed_at := tp.completed_at
	_, dup_ok, _ := taskchain_service.record_task_vote(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "rev_a"},
		taskchain_service.Vote_Input{task_id = "task_parent", vote = "lgtm"})
	check(dup_ok, "duplicate vote after completion must be accepted (no-op)")
	tp2, _, _ := task_get(rawptr(&repo_data), "task_parent")
	check(tp2.status == .Completed, "late vote must not change terminal status")
	check(tp2.completed_at == dup_completed_at, "late vote must not re-stamp completed_at")

	// (f) State-machine sanity: the auto-finalize transition is declared legal.
	check(taskchain_service.valid_task_transition(.In_Validation, .Completed), "In_Validation -> Completed must be a legal transition")

	fmt.println("PASS: hub h6 quorum auto-complete")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
