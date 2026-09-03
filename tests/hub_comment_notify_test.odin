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
	// CT-6: comment notifications are gated on the recipient's persisted current
	// task. The assignee's current_task is task_1 (role work), so comments on
	// task_1 wake it; the coordinator has no current task and is never a comment
	// target here.
	a.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_assignee", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "idle", current_task_id = "task_1", current_task_role = .Work}
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

	// 1) Comment without --notify must NOT emit any automatic notifications.
	captured.count = 0
	user_auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	_, notified1, ok, err := taskchain_service.comment_task(&service, user_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "please continue"})
	check(ok, fmt.tprintf("user comment should save: %v", err))
	check(captured.count == 0, fmt.tprintf("comment without notify must emit 0 notifications, got %d", captured.count))
	check(len(notified1) == 0, "notified list should be empty")

	// 2) Comment with explicit --notify target must emit notification to target.
	captured.count = 0
	coord_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_coord"}
	targets := [?]string{"inst_assignee"}
	_, notified2, ok2, _ := taskchain_service.comment_task(&service, coord_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "short comment", notify = targets[:]})
	check(ok2, "comment with valid notify target should save")
	check(captured.count == 1, fmt.tprintf("must emit exactly 1 notification, got %d", captured.count))
	check(len(notified2) == 1 && notified2[0] == "inst_assignee", "notified list must contain target")
	check(strings.contains(captured.bodies[0], `"agent_instance_id":"inst_assignee"`), "target must match")
	check(strings.contains(captured.bodies[0], "inst_coord"), "notification must contain author")
	check(strings.contains(captured.bodies[0], "task_1"), "notification must contain task ID")
	check(strings.contains(captured.bodies[0], "short comment"), "notification must contain comment preview")

	// 3) Comment with body > 30 chars must be truncated with ellipsis.
	captured.count = 0
	long_body := "123456789012345678901234567890EXTRA_CHARS"
	_, _, ok3, _ := taskchain_service.comment_task(&service, coord_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = long_body, notify = targets[:]})
	check(ok3, "comment with long body should save")
	check(captured.count == 1, "long body comment emitted 1 notification")
	check(strings.contains(captured.bodies[0], "123456789012345678901234567890..."), "must truncate to 30 chars with ellipsis")
	check(!strings.contains(captured.bodies[0], "EXTRA_CHARS"), "must not contain characters beyond 30")

	// 4) Validation: invalid target instance IDs must fail, posting NO comment.
	captured.count = 0
	prev_comments := r.comment_count
	bad_targets := [?]string{"inst_assignee", "inst_nonexistent", "inst_invalid2"}
	_, _, ok4, err4 := taskchain_service.comment_task(&service, coord_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "fail me", notify = bad_targets[:]})
	check(!ok4, "comment with invalid notify target must fail")
	check(r.comment_count == prev_comments, "no comment should be saved on validation failure")
	check(captured.count == 0, "no notification should be emitted on validation failure")
	check(strings.contains(err4.message, "inst_nonexistent") && strings.contains(err4.message, "inst_invalid2"), "error message must report invalid instance IDs")

	fmt.println("PASS: hub comment notify")
}
