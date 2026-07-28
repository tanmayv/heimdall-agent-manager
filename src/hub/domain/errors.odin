package domain

Error_Code :: enum {
	None,
	Unauthenticated,
	Forbidden,
	Not_Found,
	Validation_Failed,
	Conflict,
	Bridge_Offline,
	Bridge_Revoked,
	Provider_Unavailable,
	Instance_Not_Running,
	Rate_Limited,
	Gone,
	Internal_Error,
}

Domain_Error :: struct {
	code:    Error_Code,
	message: string,
	details_json: string,
}

error_code_string :: proc(code: Error_Code) -> string {
	switch code {
	case .None: return ""
	case .Unauthenticated: return "unauthenticated"
	case .Forbidden: return "forbidden"
	case .Not_Found: return "not_found"
	case .Validation_Failed: return "validation_failed"
	case .Conflict: return "conflict"
	case .Bridge_Offline: return "bridge_offline"
	case .Bridge_Revoked: return "bridge_revoked"
	case .Provider_Unavailable: return "provider_unavailable"
	case .Instance_Not_Running: return "instance_not_running"
	case .Rate_Limited: return "rate_limited"
	case .Gone: return "gone"
	case .Internal_Error: return "internal_error"
	}
	return "internal_error"
}

domain_error :: proc(code: Error_Code, message: string, details_json := "") -> Domain_Error {
	return Domain_Error{code = code, message = message, details_json = details_json}
}
