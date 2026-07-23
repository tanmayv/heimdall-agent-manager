package iface

import domain "odin_test:hub/domain"

Task_Chain_Get_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error)
Task_Chain_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error)
Task_Chain_Save_Proc :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error)
Task_Save_Proc :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error)
Task_Get_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error)
Task_List_By_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task, domain.Domain_Error)

Taskchain_Repository :: struct {
	ctx: rawptr,
	get_chain: Task_Chain_Get_Proc,
	list_chains_by_owner: Task_Chain_List_By_Owner_Proc,
	save_chain: Task_Chain_Save_Proc,
	save_task: Task_Save_Proc,
	get_task: Task_Get_Proc,
	list_tasks_by_chain: Task_List_By_Chain_Proc,
}

taskchain_get_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if repo == nil || repo.get_chain == nil do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.get_chain(repo.ctx, chain_id)
}

taskchain_list_chains_by_owner :: proc(repo: ^Taskchain_Repository, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	if repo == nil || repo.list_chains_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_chains_by_owner(repo.ctx, owner_user_id)
}

taskchain_save_chain :: proc(repo: ^Taskchain_Repository, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if repo == nil || repo.save_chain == nil do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.save_chain(repo.ctx, chain)
}

taskchain_save_task :: proc(repo: ^Taskchain_Repository, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	if repo == nil || repo.save_task == nil do return domain.Task{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.save_task(repo.ctx, task)
}

taskchain_get_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	if repo == nil || repo.get_task == nil do return domain.Task{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.get_task(repo.ctx, task_id)
}

taskchain_list_tasks_by_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
	if repo == nil || repo.list_tasks_by_chain == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_tasks_by_chain(repo.ctx, chain_id, owner_user_id)
}
