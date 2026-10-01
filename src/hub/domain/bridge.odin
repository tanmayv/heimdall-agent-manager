package domain

Bridge_Status :: enum {
	Online,
	Offline,
	Revoked,
}

Enrollment_Status :: enum {
	Pending,
	Consumed,
	Revoked,
	Expired,
}

Bridge :: struct {
	bridge_id: string,
	owner_user_id: User_ID,
	label: string,
	label_is_user_customized: bool,
	machine_hostname: string,
	machine_os: string,
	machine_arch: string,
	capabilities_json: string,
	hub_url: string,
	status: Bridge_Status,
	bridge_token_hash: string,
	created_at: string,
	updated_at: string,
	last_seen_at: string,
	revoked_at: string,
	version: string,
	commit_sha: string,
	build_timestamp: string,
	update_status: string,
	update_error: string,
}

// bridge_destroy frees every heap string on a Bridge read from a repository.
//
// It exists because the REQ-SHELL-14 sweep reads bridges on the reaper's
// process-scoped thread, which has no per-request arena: anything allocated there
// stays allocated. The repository's row reader hands back thirteen owned strings, so a
// caller that wanted one field and dropped the value leaked the other twelve, every
// sweep, forever. Mirrors domain.agent_instance_destroy, which exists for the same
// reason on the same thread.
bridge_destroy :: proc(b: ^Bridge) {
	if b == nil do return
	if len(b.bridge_id) > 0 do delete(b.bridge_id)
	if len(string(b.owner_user_id)) > 0 do delete(string(b.owner_user_id))
	if len(b.label) > 0 do delete(b.label)
	if len(b.machine_hostname) > 0 do delete(b.machine_hostname)
	if len(b.machine_os) > 0 do delete(b.machine_os)
	if len(b.machine_arch) > 0 do delete(b.machine_arch)
	if len(b.capabilities_json) > 0 do delete(b.capabilities_json)
	if len(b.hub_url) > 0 do delete(b.hub_url)
	if len(b.bridge_token_hash) > 0 do delete(b.bridge_token_hash)
	if len(b.created_at) > 0 do delete(b.created_at)
	if len(b.updated_at) > 0 do delete(b.updated_at)
	if len(b.last_seen_at) > 0 do delete(b.last_seen_at)
	if len(b.revoked_at) > 0 do delete(b.revoked_at)
	if len(b.version) > 0 do delete(b.version)
	if len(b.commit_sha) > 0 do delete(b.commit_sha)
	if len(b.build_timestamp) > 0 do delete(b.build_timestamp)
	if len(b.update_status) > 0 do delete(b.update_status)
	if len(b.update_error) > 0 do delete(b.update_error)
	b^ = Bridge{}
}

Bridge_Enrollment :: struct {
	enrollment_id: string,
	owner_user_id: User_ID,
	label: string,
	token_hash: string,
	status: Enrollment_Status,
	expires_at: string,
	consumed_at: string,
	consumed_by_bridge_id: string,
	created_at: string,
	updated_at: string,
}

bridge_status_string :: proc(status: Bridge_Status) -> string {
	switch status {
	case .Online: return "online"
	case .Offline: return "offline"
	case .Revoked: return "revoked"
	}
	return "offline"
}

enrollment_status_string :: proc(status: Enrollment_Status) -> string {
	switch status {
	case .Pending: return "pending"
	case .Consumed: return "consumed"
	case .Revoked: return "revoked"
	case .Expired: return "expired"
	}
	return "pending"
}
