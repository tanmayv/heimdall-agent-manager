package iface

import domain "odin_test:hub/domain"

Task_Chain_Get_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error)
Task_Chain_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error)
Task_Chain_Save_Proc :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error)
Task_Save_Proc :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error)
Task_Get_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error)
Task_List_By_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task, domain.Domain_Error)
Task_Comment_Save_Proc :: proc(ctx: rawptr, comment: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error)
Task_Comment_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Comment, domain.Domain_Error)
// Cheap comment rollup for a task (COUNT + newest row), so list/show/context can
// embed a summary without loading every comment body.
Task_Comment_Summary_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (domain.Task_Comment_Summary, domain.Domain_Error)
// List the newest `last` comments (ascending), or all when last <= 0.
Task_Comment_List_Recent_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID, last: int) -> ([]domain.Task_Comment, domain.Domain_Error)

Task_Chain_Member_Save_Proc :: proc(ctx: rawptr, member: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error)
Task_Chain_Member_Remove_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, agent_instance_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)
Task_Chain_Member_List_By_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error)
// H9: reverse lookup — the chains an agent instance COORDINATES (member row with
// role='coordinator'), owner-scoped. An agent can coordinate multiple chains.
Task_Chain_List_By_Coordinator_Proc :: proc(ctx: rawptr, agent_instance_id: string, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error)

Task_Dependency_Save_Proc :: proc(ctx: rawptr, dep: domain.Task_Dependency) -> (domain.Task_Dependency, bool, domain.Domain_Error)
Task_Dependency_Remove_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, depends_on_task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)
Task_Dependency_List_By_Chain_Proc :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error)

Task_Vote_Save_Proc :: proc(ctx: rawptr, vote: domain.Task_Vote) -> (domain.Task_Vote, bool, domain.Domain_Error)
Task_Vote_List_By_Task_Proc :: proc(ctx: rawptr, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Vote, domain.Domain_Error)

Taskchain_Repository :: struct {
	ctx: rawptr,
	get_chain: Task_Chain_Get_Proc,
	list_chains_by_owner: Task_Chain_List_By_Owner_Proc,
	save_chain: Task_Chain_Save_Proc,
	save_task: Task_Save_Proc,
	get_task: Task_Get_Proc,
	list_tasks_by_chain: Task_List_By_Chain_Proc,
	save_comment: Task_Comment_Save_Proc,
	list_comments_by_task: Task_Comment_List_By_Task_Proc,
	comment_summary_by_task: Task_Comment_Summary_Proc,
	list_recent_comments_by_task: Task_Comment_List_Recent_Proc,
	save_member: Task_Chain_Member_Save_Proc,
	remove_member: Task_Chain_Member_Remove_Proc,
	list_members_by_chain: Task_Chain_Member_List_By_Chain_Proc,
	list_chains_by_coordinator: Task_Chain_List_By_Coordinator_Proc,
	save_dependency: Task_Dependency_Save_Proc,
	remove_dependency: Task_Dependency_Remove_Proc,
	list_dependencies_by_chain: Task_Dependency_List_By_Chain_Proc,
	save_vote: Task_Vote_Save_Proc,
	list_votes_by_task: Task_Vote_List_By_Task_Proc,
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

taskchain_save_comment :: proc(repo: ^Taskchain_Repository, comment: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	if repo == nil || repo.save_comment == nil do return domain.Task_Comment{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.save_comment(repo.ctx, comment)
}

taskchain_list_comments_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	if repo == nil || repo.list_comments_by_task == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_comments_by_task(repo.ctx, task_id, owner_user_id)
}

taskchain_comment_summary_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (domain.Task_Comment_Summary, domain.Domain_Error) {
	if repo == nil || repo.comment_summary_by_task == nil do return domain.Task_Comment_Summary{}, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.comment_summary_by_task(repo.ctx, task_id, owner_user_id)
}

taskchain_list_recent_comments_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID, last: int) -> ([]domain.Task_Comment, domain.Domain_Error) {
	if repo == nil || repo.list_recent_comments_by_task == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_recent_comments_by_task(repo.ctx, task_id, owner_user_id, last)
}

taskchain_save_member :: proc(repo: ^Taskchain_Repository, member: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	if repo == nil || repo.save_member == nil do return domain.Task_Chain_Member{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.save_member(repo.ctx, member)
}

taskchain_remove_member :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, agent_instance_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.remove_member == nil do return false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.remove_member(repo.ctx, chain_id, agent_instance_id, owner_user_id)
}

taskchain_list_members_by_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	if repo == nil || repo.list_members_by_chain == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_members_by_chain(repo.ctx, chain_id, owner_user_id)
}

taskchain_list_chains_by_coordinator :: proc(repo: ^Taskchain_Repository, agent_instance_id: string, owner_user_id: domain.User_ID) -> ([]domain.Task_Chain, domain.Domain_Error) {
	if repo == nil || repo.list_chains_by_coordinator == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_chains_by_coordinator(repo.ctx, agent_instance_id, owner_user_id)
}

taskchain_save_dependency :: proc(repo: ^Taskchain_Repository, dep: domain.Task_Dependency) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
	if repo == nil || repo.save_dependency == nil do return domain.Task_Dependency{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.save_dependency(repo.ctx, dep)
}

taskchain_remove_dependency :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, depends_on_task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.remove_dependency == nil do return false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.remove_dependency(repo.ctx, task_id, depends_on_task_id, owner_user_id)
}

taskchain_list_dependencies_by_chain :: proc(repo: ^Taskchain_Repository, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	if repo == nil || repo.list_dependencies_by_chain == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_dependencies_by_chain(repo.ctx, chain_id, owner_user_id)
}

taskchain_save_vote :: proc(repo: ^Taskchain_Repository, vote: domain.Task_Vote) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	if repo == nil || repo.save_vote == nil do return domain.Task_Vote{}, false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.save_vote(repo.ctx, vote)
}

taskchain_list_votes_by_task :: proc(repo: ^Taskchain_Repository, task_id: domain.Task_ID, owner_user_id: domain.User_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	if repo == nil || repo.list_votes_by_task == nil do return nil, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	return repo.list_votes_by_task(repo.ctx, task_id, owner_user_id)
}
