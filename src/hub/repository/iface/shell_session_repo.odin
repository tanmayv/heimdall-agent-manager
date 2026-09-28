package iface

import domain "odin_test:hub/domain"

Shell_Session_Upsert_Proc        :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error)
Shell_Session_Get_Proc            :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error)
// Shell_Session_Get_By_Id_Proc looks a session up with no OWNER scoping. It
// exists for the internal bridge-event path (shell_exited), where the caller is
// a trusted bridge event and there is no authenticated user to scope by. It MUST
// NOT be used from any user-facing handler: those keep using
// Shell_Session_Get_Proc, or they leak sessions across tenants.
//
// It is still BRIDGE scoped (REQ-SHELL-1 §7): the key is (bridge_id, session_id)
// and the reporting bridge is always known at the call site, so this resolves
// only within the bridge that reported the event.
Shell_Session_Get_By_Id_Proc      :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error)
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
	bridge_id:         string,
	project_id:        string,
	chain_id:          string,
	// agent_instance_id is the scope key for kind=run (REQ-SHELL-1 §5). Without it
	// an agent-scoped session has no filter that can name its scope, and the rule
	// would exist in the domain with nothing able to query by it.
	agent_instance_id: string,
	status:            string,
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

// Shell_Session_Find_Live_By_Port_Proc finds the LIVE session holding a port on a
// bridge, if any. REQ-SHELL-2 §10: two servers declaring the same port on one
// bridge used to mean the second silently lost the bind, or the preview pointed
// at whichever process won it.
//
// OWNER-UNSCOPED, and that is the point rather than an oversight. A TCP port is a
// property of the HOST, not of a tenant: two different users' servers on one
// bridge contend for :8080 exactly as one user's two servers do. An owner-scoped
// check would pass cleanly and then fail at bind, which is the failure this
// exists to replace. Like Shell_Session_Get_By_Id_Proc it is bridge-scoped and
// internal — it returns at most the id/kind/owner needed to NAME the conflict,
// and it must not be used to serve a session to a user.
//
// "Live" is domain.SHELL_SESSION_TERMINAL_STATUSES inverted, the same definition
// the `live` status-group filter builds from, so a terminal session releases its
// port by the same rule everywhere.
Shell_Session_Find_Live_By_Port_Proc :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error)

// Shell_Session_Count_Live_Proc counts an owner's LIVE sessions of one kind in
// one scope, for the caps in REQ-SHELL-2 §11. scope_column is the domain scope
// column to narrow by and scope_value its value, so the caller expresses "live
// runs for this agent instance" or "live servers for this chain" without either
// pairing being restated here — the kind/scope pairing itself stays in
// domain.SHELL_SESSION_SCOPE_RULES.
//
// A count rather than a list: the caps are large (32 and 16), and listing to
// measure length would page and allocate for a question that is one COUNT(*).
Shell_Session_Count_Live_Proc :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error)

// Shell_Session_Set_Kill_Requested_Proc records that a kill was ACCEPTED for a
// session (REQ-SHELL-3), owner-scoped. A separate op rather than a field on the
// upsert for the same reason set_server_port is one: the upsert has to let a
// bridge-event write omit fields it does not know about, so it cannot also be the
// authority on a column whose empty value is meaningful.
//
// FIRST-WRITER-WINS. It sets the column only when no intent is outstanding, so a
// second kill of the same session keeps the moment the user first asked instead of
// sliding the timestamp forward on every retry. The bool reports whether the row
// was matched at all, not whether this call was the writer — a second kill is a
// legitimate success, not a failure.
//
// It deliberately does not clear: clearing is the upsert's job, keyed on a terminal
// status landing, so an intent cannot be retired while the process is still alive.
Shell_Session_Set_Kill_Requested_Proc :: proc(ctx: rawptr, owner_user_id, session_id, kill_requested_at: string) -> (bool, domain.Domain_Error)

// Shell_Session_List_Pending_Kills_Proc lists the sessions on one bridge with an
// OUTSTANDING kill — set and not yet terminal, the SQL twin of
// domain.shell_session_kill_intent_pending. This is the reconnect replay's query
// and the only reason the column has an index.
//
// OWNER-UNSCOPED, like Shell_Session_Get_By_Id_Proc and for the same reason: the
// caller is the bridge-WS accept path, which authenticates a BRIDGE and has no
// authenticated user to scope by. It is still bridge-scoped — a bridge only ever
// replays its own sessions — and internal: it feeds command dispatch, never a
// user-facing response.
//
// Unpaged on purpose. The pending set is the kills outstanding on one bridge, which
// is normally zero and is bounded in practice by the live-session caps; a cursor
// would add a resumption protocol to a list that is read once per reconnect and
// acted on in full. `limit` is a runaway backstop, not pagination.
Shell_Session_List_Pending_Kills_Proc :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error)

// Shell_Session_List_Live_By_Bridge_Proc lists one bridge's NON-TERMINAL sessions.
// It is the hub half of REQ-SHELL-10's convergence diff: the set the incoming
// inventory is compared against, so that a row the hub still believes is live while
// the bridge does not list it can be recognised as having died while we were away.
//
// OWNER-UNSCOPED, like Shell_Session_Get_By_Id_Proc and
// Shell_Session_List_Pending_Kills_Proc, and for the identical reason: the caller is
// the bridge-WS frame path, which authenticates a BRIDGE and has no authenticated
// user to scope by. It is still BRIDGE-scoped, and that matters more here than
// anywhere else in this file — an inventory mutates MANY rows at once, so the query
// that decides which rows are in play must not be able to name another bridge's. It
// is internal: it feeds the diff, never a user-facing response.
//
// "Live" is domain.SHELL_SESSION_TERMINAL_STATUSES inverted, the same definition the
// `live` status-group filter and find_live_by_port build from, so a session is live
// by one rule everywhere.
//
// Unpaged, like the pending-kill listing: this is read once per reconnect and acted
// on in full, and `limit` is a runaway backstop rather than pagination.
Shell_Session_List_Live_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error)

// Shell_Session_Delete_Terminal_Before_Proc removes TERMINAL rows whose effective
// end timestamp is strictly older than cutoff_rfc3339, returning how many went.
// REQ-SHELL-8 item 6: shell output got a retention window but the rows never did,
// so terminal sessions accumulated forever and every list query and chain summary
// degraded permanently.
//
// OWNER-UNSCOPED, like get_by_id and find_live_by_port, and for the same kind of
// reason: the caller is the hub's own periodic sweep, which acts for no user and
// has no auth context to scope by. It is a maintenance operation over the whole
// table and is not reachable from any request handler.
//
// It can only ever delete rows that are already terminal — a live session is
// excluded by status, not by age, so a server running for a month is untouchable
// however old its row is.
Shell_Session_Delete_Terminal_Before_Proc :: proc(ctx: rawptr, cutoff_rfc3339: string) -> (int, domain.Domain_Error)

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
	find_live_by_port: Shell_Session_Find_Live_By_Port_Proc,
	count_live:        Shell_Session_Count_Live_Proc,
	set_kill_requested: Shell_Session_Set_Kill_Requested_Proc,
	list_pending_kills: Shell_Session_List_Pending_Kills_Proc,
	list_live_by_bridge: Shell_Session_List_Live_By_Bridge_Proc,
	delete_terminal_before: Shell_Session_Delete_Terminal_Before_Proc,
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
shell_session_get_by_id :: proc(repo: ^Shell_Session_Repository, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if repo == nil || repo.get_by_id == nil do return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.get_by_id(repo.ctx, bridge_id, session_id)
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
// shell_session_delete_terminal_before is the row-retention sweep's entry point.
// See Shell_Session_Delete_Terminal_Before_Proc for why it is owner-unscoped.
shell_session_delete_terminal_before :: proc(repo: ^Shell_Session_Repository, cutoff_rfc3339: string) -> (int, domain.Domain_Error) {
	if repo == nil || repo.delete_terminal_before == nil do return 0, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.delete_terminal_before(repo.ctx, cutoff_rfc3339)
}

shell_session_set_server_port :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id: string, server_port: int) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.set_server_port == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.set_server_port(repo.ctx, owner_user_id, session_id, server_port)
}

// shell_session_find_live_by_port is the bridge-scoped, owner-unscoped port
// holder lookup. See Shell_Session_Find_Live_By_Port_Proc for why it is unscoped.
shell_session_find_live_by_port :: proc(repo: ^Shell_Session_Repository, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if repo == nil || repo.find_live_by_port == nil do return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.find_live_by_port(repo.ctx, bridge_id, server_port)
}

// shell_session_count_live counts live sessions of one kind in one scope, for the
// per-agent and per-chain caps.
shell_session_count_live :: proc(repo: ^Shell_Session_Repository, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	if repo == nil || repo.count_live == nil do return 0, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.count_live(repo.ctx, owner_user_id, kind, scope_column, scope_value)
}

// shell_session_set_kill_requested records an accepted kill on the row. See
// Shell_Session_Set_Kill_Requested_Proc for the first-writer-wins rule.
shell_session_set_kill_requested :: proc(repo: ^Shell_Session_Repository, owner_user_id, session_id, kill_requested_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.set_kill_requested == nil do return false, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.set_kill_requested(repo.ctx, owner_user_id, session_id, kill_requested_at)
}

// shell_session_list_pending_kills lists one bridge's outstanding kill intents for
// the reconnect replay. Bridge-scoped and owner-unscoped; internal only.
shell_session_list_pending_kills :: proc(repo: ^Shell_Session_Repository, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	if repo == nil || repo.list_pending_kills == nil do return nil, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.list_pending_kills(repo.ctx, bridge_id, limit)
}

// shell_session_list_live_by_bridge lists one bridge's non-terminal sessions for the
// REQ-SHELL-10 inventory diff. Bridge-scoped and owner-unscoped; internal only.
shell_session_list_live_by_bridge :: proc(repo: ^Shell_Session_Repository, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	if repo == nil || repo.list_live_by_bridge == nil do return nil, domain.domain_error(.Internal_Error, "shell session repository is not configured")
	return repo.list_live_by_bridge(repo.ctx, bridge_id, limit)
}
