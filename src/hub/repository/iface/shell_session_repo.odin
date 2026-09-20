package iface

import domain "odin_test:hub/domain"

Shell_Session_Upsert_Proc        :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error)
Shell_Session_Get_Proc            :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error)
Shell_Session_List_By_Bridge_Proc :: proc(ctx: rawptr, owner_user_id, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
Shell_Session_List_By_Project_Proc :: proc(ctx: rawptr, owner_user_id, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
Shell_Session_List_By_Chain_Proc  :: proc(ctx: rawptr, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
Shell_Session_Delete_Proc         :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (bool, domain.Domain_Error)

Shell_Session_Repository :: struct {
	ctx:             rawptr,
	upsert:          Shell_Session_Upsert_Proc,
	get:             Shell_Session_Get_Proc,
	list_by_bridge:  Shell_Session_List_By_Bridge_Proc,
	list_by_project: Shell_Session_List_By_Project_Proc,
	list_by_chain:   Shell_Session_List_By_Chain_Proc,
	delete:          Shell_Session_Delete_Proc,
}

shell_session_upsert :: proc(repo: ^Shell_Session_Repository, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.upsert == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.upsert(repo.ctx, session)
}

shell_session_get :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.get(repo.ctx, owner_user_id, session_id)
}

shell_session_list_by_bridge :: proc(repo: ^Shell_Session_Repository, owner_user_id, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if repo == nil || repo.list_by_bridge == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.list_by_bridge(repo.ctx, owner_user_id, bridge_id, status_filter, cursor, limit)
}

shell_session_list_by_project :: proc(repo: ^Shell_Session_Repository, owner_user_id, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if repo == nil || repo.list_by_project == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.list_by_project(repo.ctx, owner_user_id, project_id, status_filter, cursor, limit)
}

shell_session_list_by_chain :: proc(repo: ^Shell_Session_Repository, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if repo == nil || repo.list_by_chain == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.list_by_chain(repo.ctx, owner_user_id, chain_id, status_filter, cursor, limit)
}

shell_session_delete :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.delete(repo.ctx, owner_user_id, session_id)
}
