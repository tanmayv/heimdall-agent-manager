package hub_agent_id_ref_resolve_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

// Functional test: a durable agent_id assignee ref is normalized into a concrete
// agent_instance ref by reusing an owner-owned instance of that agent_id, and the
// instance is auto-added to the chain members so validation passes.

Fake :: struct {
	chains: [8]domain.Task_Chain,
	chain_count: int,
	tasks: [8]domain.Task,
	task_count: int,
	members: [16]domain.Task_Chain_Member,
	member_count: int,
	instances: [8]domain.Agent_Instance,
	instance_count: int,
}

now_p :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
id_p :: proc(ctx: rawptr, prefix: string) -> string {
	f := (^Fake)(ctx)
	return strings.concatenate({prefix, fmt.tprintf("%d", f.chain_count + f.task_count + f.member_count + 1)})
}

chain_get :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.chain_count { if f.chains[i].chain_id == chain_id do return f.chains[i], true, domain.Domain_Error{} }
	return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.chain_count { if f.chains[i].chain_id == chain.chain_id { f.chains[i] = chain; return chain, true, domain.Domain_Error{} } }
	f.chains[f.chain_count] = chain; f.chain_count += 1; return chain, true, domain.Domain_Error{}
}
task_save :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.task_count { if f.tasks[i].task_id == task.task_id { f.tasks[i] = task; return task, true, domain.Domain_Error{} } }
	f.tasks[f.task_count] = task; f.task_count += 1; return task, true, domain.Domain_Error{}
}
task_get :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.task_count { if f.tasks[i].task_id == task_id do return f.tasks[i], true, domain.Domain_Error{} }
	return domain.Task{}, false, domain.domain_error(.Not_Found, "task not found")
}
member_save :: proc(ctx: rawptr, m: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.member_count { if f.members[i].agent_instance_id == m.agent_instance_id && f.members[i].chain_id == m.chain_id { f.members[i] = m; return m, true, domain.Domain_Error{} } }
	f.members[f.member_count] = m; f.member_count += 1; return m, true, domain.Domain_Error{}
}
member_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	f := (^Fake)(ctx)
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<f.member_count { if f.members[i].chain_id == chain_id do append(&out, f.members[i]) }
	return out[:], domain.Domain_Error{}
}
inst_get :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Fake)(ctx)
	for i in 0..<f.instance_count { if f.instances[i].agent_instance_id == instance_id do return f.instances[i], true, domain.Domain_Error{} }
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "instance not found")
}
inst_list :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	f := (^Fake)(ctx)
	out := make([dynamic]domain.Agent_Instance)
	for i in 0..<f.instance_count { if f.instances[i].owner_user_id == owner do append(&out, f.instances[i]) }
	return out[:], domain.Domain_Error{}
}

check :: proc(cond: bool, msg: string) { if !cond { fmt.eprintln("FAIL:", msg); os.exit(1) } }

main :: proc() {
	f: Fake
	// Seed an owner-owned instance of durable agent_id "reviewer".
	f.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_rev1", owner_user_id = "alice", agent_id = "reviewer", runtime_status = "running"}
	f.instance_count = 1

	clock := platform.Clock{ctx = nil, now = now_p}
	ids := platform.ID_Generator{ctx = rawptr(&f), generate = id_p}
	repo := iface.Taskchain_Repository{ctx = rawptr(&f), get_chain = chain_get, save_chain = chain_save, save_task = task_save, get_task = task_get, save_member = member_save, list_members_by_chain = member_list}
	agents := iface.Agent_Repository{ctx = rawptr(&f), get_instance = inst_get, list_instances_by_owner = inst_list}
	service := taskchain_service.new_taskchain_service(&repo, &agents, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}

	chain, ok, err := taskchain_service.create_chain(&service, auth, taskchain_service.Create_Chain_Input{title = "chain"})
	check(ok, err.message)

	// Create a task assigning by durable agent_id "reviewer".
	assignee := `{"type":"agent_id","agent_id":"reviewer"}`
	task, task_ok, task_err := taskchain_service.create_task(&service, auth, taskchain_service.Create_Task_Input{chain_id = chain.chain_id, title = "t1", assignee_ref_json = assignee})
	check(task_ok, task_err.message)

	// The stored assignee ref must now be a concrete agent_instance ref for inst_rev1.
	check(strings.contains(task.assignee_ref_json, "agent_instance"), "assignee ref should be rewritten to agent_instance")
	check(strings.contains(task.assignee_ref_json, "inst_rev1"), "assignee ref should resolve to the reused instance inst_rev1")
	check(!strings.contains(task.assignee_ref_json, "agent_id"), "agent_id ref should be fully replaced")

	// The reused instance must have been added to the chain members.
	found_member := false
	for i in 0..<f.member_count { if f.members[i].agent_instance_id == "inst_rev1" && f.members[i].chain_id == chain.chain_id do found_member = true }
	check(found_member, "resolved instance should be added to chain members")

	// Unknown agent_id must fail clearly.
	_, bad_ok, bad_err := taskchain_service.create_task(&service, auth, taskchain_service.Create_Task_Input{chain_id = chain.chain_id, title = "t2", assignee_ref_json = `{"type":"agent_id","agent_id":"ghost"}`})
	check(!bad_ok, "unknown agent_id should not resolve")
	check(bad_err.code == .Not_Found, "unknown agent_id should return Not_Found")

	fmt.println("PASS: hub agent_id actor ref resolve/reuse")
}
