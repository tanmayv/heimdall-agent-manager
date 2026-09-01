package hub_phase4_task_lifecycle_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

Fake_Repo :: struct {
	chains: [8]domain.Task_Chain,
	chain_count: int,
	tasks: [8]domain.Task,
	task_count: int,
}

fixed_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
fixed_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	repo := (^Fake_Repo)(ctx)
	return strings.concatenate({prefix, fmt.tprintf("%d", repo.chain_count + repo.task_count + 1)})
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

main :: proc() {
	repo_data: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&repo_data), generate = fixed_id_generate}
	repo := iface.Taskchain_Repository{ctx = rawptr(&repo_data), get_chain = chain_get, save_chain = chain_save, save_task = task_save, get_task = task_get}
	service := taskchain_service.new_taskchain_service(&repo, nil, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	chain, ok, err := taskchain_service.create_chain(&service, auth, taskchain_service.Create_Chain_Input{title = "chain"})
	check(ok, err.message)
	check(chain.publish_state == .Draft, "chain must start draft")
	_, draft_status_ok, draft_status_err := taskchain_service.change_chain_status(&service, auth, chain.chain_id, .Completed)
	check(!draft_status_ok && draft_status_err.code == .Conflict, "draft chain status transition must fail")
	task, task_ok, task_err := taskchain_service.create_task(&service, auth, taskchain_service.Create_Task_Input{chain_id = chain.chain_id, title = "task"})
	check(task_ok, task_err.message)
	check(task.publish_state == .Draft, "task must start draft")
	_, nudge_draft_ok, nudge_draft_err := taskchain_service.manual_nudge(&service, auth, task.task_id, "wake")
	check(!nudge_draft_ok && nudge_draft_err.code == .Conflict, "draft task must not be nudged")
	_, publish_task_early_ok, publish_task_early_err := taskchain_service.publish_task(&service, auth, task.task_id)
	check(!publish_task_early_ok && publish_task_early_err.code == .Conflict, "task cannot publish before chain")

	chain, ok, err = taskchain_service.publish_chain(&service, auth, chain.chain_id)
	check(ok && chain.publish_state == .Published && chain.status == .Active, "publish_chain must publish and activate")
	task, ok, err = taskchain_service.publish_task(&service, auth, task.task_id)
	check(ok && task.publish_state == .Published && task.status == .Assigned, "publish_task must set assigned")
	_, invalid_ok, invalid_err := taskchain_service.change_task_status(&service, auth, task.task_id, .Completed)
	check(!invalid_ok && invalid_err.code == .Conflict, "assigned -> completed must be invalid")
	task, ok, err = taskchain_service.change_task_status(&service, auth, task.task_id, .In_Progress)
	check(ok && task.status == .In_Progress, "assigned -> in_progress must pass")
	nudge, nudge_ok, nudge_err := taskchain_service.manual_nudge(&service, auth, task.task_id, "please continue")
	check(nudge_ok && nudge.target == .Assignee && task.status == .In_Progress, "manual nudge must notify assignee without changing status")
	task, ok, err = taskchain_service.change_task_status(&service, auth, task.task_id, .In_Validation)
	check(ok && task.status == .In_Validation, "in_progress -> in_validation must pass")
	nudge, nudge_ok, nudge_err = taskchain_service.manual_nudge(&service, auth, task.task_id, "review")
	check(nudge_ok && nudge.target == .Reviewer, "in_validation nudge must target reviewer")
	task, ok, err = taskchain_service.change_task_status(&service, auth, task.task_id, .Validated_Good)
	check(ok, err.message)
	nudge, nudge_ok, nudge_err = taskchain_service.manual_nudge(&service, auth, task.task_id, "complete gate")
	check(nudge_ok && nudge.target == .Coordinator, "validated_good nudge must target coordinator")
	task, ok, err = taskchain_service.change_task_status(&service, auth, task.task_id, .Completed)
	check(ok && domain.task_status_unblocks_dependents(task.status), "completed must unblock dependents")
	check(!domain.task_status_unblocks_dependents(.Paused), "paused must not unblock dependents")
	_, terminal_nudge_ok, terminal_nudge_err := taskchain_service.manual_nudge(&service, auth, task.task_id, "wake")
	check(!terminal_nudge_ok && terminal_nudge_err.code == .Conflict, "terminal task must not be nudged")

	// H1: chain-level transition guards + reopen recovery path.
	// valid_chain_transition unit coverage.
	check(taskchain_service.valid_chain_transition(.Active, .Completed), "active -> completed must be valid")
	check(taskchain_service.valid_chain_transition(.Active, .Cancelled), "active -> cancelled must be valid")
	check(taskchain_service.valid_chain_transition(.Completed, .Active), "completed -> active (reopen) must be valid")
	check(!taskchain_service.valid_chain_transition(.Cancelled, .Active), "cancelled -> active must stay invalid")
	check(!taskchain_service.valid_chain_transition(.Completed, .Cancelled), "completed -> cancelled must be invalid")

	// End-to-end: complete the chain, then reopen it back to active.
	chain, ok, err = taskchain_service.change_chain_status(&service, auth, chain.chain_id, .Completed)
	check(ok && chain.status == .Completed && chain.completed_at != "", "chain must complete and stamp completed_at")
	chain, ok, err = taskchain_service.update_chain(&service, auth, chain.chain_id, taskchain_service.Update_Chain_Input{status = "active"})
	check(ok && chain.status == .Active && chain.completed_at == "", "reopen must return chain to active and clear completed_at")

	fmt.println("PASS: hub phase4 task lifecycle")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
