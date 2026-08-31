package hub_comment_notify_test

// Verifies that posting a NEW comment on an actionable task notifies (wakes) the
// task's current actionable owner via a bridge command — previously only status
// changes did, and comments were UI-only (task_18d0ecc6855d888e).
// Also asserts the comment author is NOT self-notified.

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import project "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

Repo :: struct {
	chain:    domain.Task_Chain,
	task:     domain.Task,
	comments: [8]domain.Task_Comment,
	comment_count: int,
	seq:      int,
}

Agents :: struct {
	instances: [8]domain.Agent_Instance,
	count:     int,
}

// Captured bridge commands (fire-and-forget notify path).
Captured :: struct {
	bodies: [16]string,
	count:  int,
}
captured: Captured

clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-08-31T10:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string {
	r := (^Repo)(ctx); r.seq += 1
	return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)})
}

chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	if r.chain.chain_id == id do return r.chain, true, {}
	return {}, false, domain.domain_error(.Not_Found, "chain")
}
task_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	if r.task.task_id == id do return r.task, true, {}
	return {}, false, domain.domain_error(.Not_Found, "task")
}
comment_save :: proc(ctx: rawptr, c: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	r.comments[r.comment_count] = c; r.comment_count += 1
	return c, true, {}
}
members_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	// assignee + coordinator are chain members (coordinator is checked separately).
	out := make([dynamic]domain.Task_Chain_Member)
	append(&out, domain.Task_Chain_Member{chain_id = chain_id, agent_instance_id = "inst_assignee", owner_user_id = owner, role = "worker"})
	append(&out, domain.Task_Chain_Member{chain_id = chain_id, agent_instance_id = "inst_coord", owner_user_id = owner, role = "coordinator"})
	return out[:], {}
}

make_repo :: proc(r: ^Repo) -> iface.Taskchain_Repository {
	return iface.Taskchain_Repository{ctx = rawptr(r), get_chain = chain_get, get_task = task_get, save_comment = comment_save, list_members_by_chain = members_list}
}

agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	a := (^Agents)(ctx)
	for i in 0..<a.count { if a.instances[i].agent_instance_id == id do return a.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "instance")
}
make_agents :: proc(a: ^Agents) -> iface.Agent_Repository {
	return iface.Agent_Repository{ctx = rawptr(a), get_instance = agent_get}
}

capture_send :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	captured.bodies[captured.count] = strings.clone(command.body_json)
	captured.count += 1
	return true, {}
}

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

main :: proc() {
	r: Repo
	a: Agents
	// Assignee + coordinator instances, both on a bridge.
	a.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_assignee", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "idle"}
	a.instances[1] = domain.Agent_Instance{agent_instance_id = "inst_coord", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "running"}
	a.count = 2

	r.chain = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", coordinator_agent_instance_id = "inst_coord", publish_state = .Published, status = .Active}
	r.task = domain.Task{task_id = "task_1", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .In_Progress,
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_assignee"}`}

	repo := make_repo(&r)
	agents := make_agents(&a)
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = gen_id}
	sink := project.Bridge_Command_Sink{ctx = nil, send_runtime_command = capture_send}
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)

	// 1) A USER comment (Trusted_Proxy, no agent author) must notify the assignee
	//    (task is In_Progress -> actionable owner is the assignee).
	captured.count = 0
	user_auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	_, ok, err := taskchain_service.comment_task(&service, user_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "please continue"})
	check(ok, fmt.tprintf("user comment should save: %v", err))
	check(captured.count == 1, fmt.tprintf("user comment must emit exactly one bridge notify, got %d", captured.count))
	check(strings.contains(captured.bodies[0], `"type":"notify_task_nudge"`), "notify command type must be notify_task_nudge")
	check(strings.contains(captured.bodies[0], `"origin":"comment"`), "notify must be tagged origin=comment")
	check(strings.contains(captured.bodies[0], "inst_assignee"), "notify must target the assignee")

	// 2) The ASSIGNEE commenting on their OWN task must NOT self-notify.
	captured.count = 0
	assignee_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_assignee"}
	_, ok2, _ := taskchain_service.comment_task(&service, assignee_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "on it"})
	check(ok2, "assignee self-comment should save")
	check(captured.count == 0, fmt.tprintf("assignee commenting on own task must NOT self-notify, got %d", captured.count))

	// 3) The COORDINATOR commenting must notify the assignee (author != target).
	captured.count = 0
	coord_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_coord"}
	_, ok3, _ := taskchain_service.comment_task(&service, coord_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "any update?"})
	check(ok3, "coordinator comment should save")
	check(captured.count == 1, "coordinator comment must notify the assignee")
	check(strings.contains(captured.bodies[0], "inst_assignee"), "coordinator comment targets assignee")

	fmt.println("PASS: hub comment notify")
}
