package iface

import domain "odin_test:hub/domain"

Shell_Job_Upsert_Proc :: proc(ctx: rawptr, job: domain.Shell_Job) -> (bool, domain.Domain_Error)
Shell_Job_List_By_Instance_Proc :: proc(ctx: rawptr, owner_user_id, agent_instance_id, status_filter, cursor: string, limit: int) -> ([]domain.Shell_Job, domain.Domain_Error)
Shell_Job_Get_By_Exec_ID_Proc :: proc(ctx: rawptr, owner_user_id, agent_instance_id, exec_id: string) -> (domain.Shell_Job, bool, domain.Domain_Error)

Shell_Job_Repository :: struct {
	ctx:              rawptr,
	upsert:           Shell_Job_Upsert_Proc,
	list_by_instance: Shell_Job_List_By_Instance_Proc,
	get_by_exec_id:   Shell_Job_Get_By_Exec_ID_Proc,
}

shell_job_upsert :: proc(repo: ^Shell_Job_Repository, job: domain.Shell_Job) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.upsert == nil do return false, domain.domain_error(.Internal_Error, "shell job repository is not configured")
	return repo.upsert(repo.ctx, job)
}

shell_job_list_by_instance :: proc(repo: ^Shell_Job_Repository, owner_user_id, agent_instance_id, status_filter, cursor: string, limit: int) -> ([]domain.Shell_Job, domain.Domain_Error) {
	if repo == nil || repo.list_by_instance == nil do return nil, domain.domain_error(.Internal_Error, "shell job repository is not configured")
	return repo.list_by_instance(repo.ctx, owner_user_id, agent_instance_id, status_filter, cursor, limit)
}

shell_job_get_by_exec_id :: proc(repo: ^Shell_Job_Repository, owner_user_id, agent_instance_id, exec_id: string) -> (domain.Shell_Job, bool, domain.Domain_Error) {
	if repo == nil || repo.get_by_exec_id == nil do return domain.Shell_Job{}, false, domain.domain_error(.Internal_Error, "shell job repository is not configured")
	return repo.get_by_exec_id(repo.ctx, owner_user_id, agent_instance_id, exec_id)
}
