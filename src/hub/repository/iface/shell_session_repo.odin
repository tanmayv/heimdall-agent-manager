package iface

import domain "odin_test:hub/domain"

Shell_Session_Upsert_Proc        :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error)
Shell_Session_Get_Proc            :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error)
// Shell_Session_Get_By_Id_Proc looks a session up by session_id ALONE, with no
// owner scoping. It exists for the internal bridge-event path (shell_exited),
// where the caller is a trusted bridge event and there is no authenticated user
// to scope by. It MUST NOT be used from any user-facing handler: those keep
// using Shell_Session_Get_Proc, or they leak sessions across tenants.
Shell_Session_Get_By_Id_Proc      :: proc(ctx: rawptr, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error)
Shell_Session_List_By_Bridge_Proc :: proc(ctx: rawptr, owner_user_id, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
Shell_Session_List_By_Project_Proc :: proc(ctx: rawptr, owner_user_id, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
Shell_Session_List_By_Chain_Proc  :: proc(ctx: rawptr, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
// Shell_Session_List_Filter narrows an owner-wide listing. Every non-empty
// field adds one AND-ed equality clause; all-empty means "every session this
// owner has, on every bridge", which is the default the owner-wide list serves.
// An empty string is the only "absent" spelling because none of these columns
// can legitimately hold one: a session always carries a bridge_id, and the
// project/chain/status columns are either set or empty-as-unset already.
Shell_Session_List_Filter :: struct {
	bridge_id:  string,
	project_id: string,
	chain_id:   string,
	status:     string,
}

// Shell_Session_List_By_Owner_Proc lists sessions across ALL of an owner's
// bridges, narrowed by filter. It is the general form of the three scoped list
// procs above, which remain because their callers pass a scope that is always
// present and would otherwise have to build a filter to say so.
Shell_Session_List_By_Owner_Proc  :: proc(ctx: rawptr, owner_user_id: string, filter: Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error)
Shell_Session_Delete_Proc         :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (bool, domain.Domain_Error)
// Shell_Session_Set_Server_Port_Proc writes server_port alone (XM-9). It is a
// separate op rather than a field on the upsert because the upsert treats a 0
// server_port as "leave it alone" — the guard that lets bridge-event upserts
// omit the field — so clearing a port through it is a silent no-op. Owner-scoped.
Shell_Session_Set_Server_Port_Proc :: proc(ctx: rawptr, owner_user_id, session_id: string, server_port: int) -> (bool, domain.Domain_Error)

Shell_Session_Repository :: struct {
	ctx:             rawptr,
	upsert:          Shell_Session_Upsert_Proc,
	get:             Shell_Session_Get_Proc,
	get_by_id:       Shell_Session_Get_By_Id_Proc,
	list_by_bridge:  Shell_Session_List_By_Bridge_Proc,
	list_by_project: Shell_Session_List_By_Project_Proc,
	list_by_chain:   Shell_Session_List_By_Chain_Proc,
	list_by_owner:   Shell_Session_List_By_Owner_Proc,
	delete:          Shell_Session_Delete_Proc,
	set_server_port: Shell_Session_Set_Server_Port_Proc,
}

shell_session_upsert :: proc(repo: ^Shell_Session_Repository, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.upsert == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.upsert(repo.ctx, session)
}

shell_session_get :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.get(repo.ctx, owner_user_id, session_id)
}

// shell_session_get_by_id is the unscoped lookup described on
// Shell_Session_Get_By_Id_Proc. Internal bridge-event path only.
shell_session_get_by_id :: proc(repo: ^Shell_Session_Repository, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if repo == nil || repo.get_by_id == nil do return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.get_by_id(repo.ctx, session_id)
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

// shell_session_list_by_owner lists every session the owner has, across all
// bridges, narrowed by the optional filter fields.
shell_session_list_by_owner :: proc(repo: ^Shell_Session_Repository, owner_user_id: string, filter: Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id, filter, cursor, limit)
}

shell_session_delete :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.delete(repo.ctx, owner_user_id, session_id)
}

// shell_session_set_server_port updates only the server_port column, scoped to
// the owner. See Shell_Session_Set_Server_Port_Proc for why it is not an upsert.
shell_session_set_server_port :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id: string, server_port: int) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.set_server_port == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.set_server_port(repo.ctx, owner_user_id, session_id, server_port)
}
