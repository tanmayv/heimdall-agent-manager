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
