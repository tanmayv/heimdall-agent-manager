package ownership

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

owner_from_auth :: proc(auth: contracts.Auth_Context) -> (domain.User_ID, bool, domain.Domain_Error) {
	if auth.user_id == "" {
		return domain.User_ID(""), false, domain.domain_error(.Unauthenticated, "authenticated user is required")
	}
	return domain.User_ID(auth.user_id), true, domain.Domain_Error{}
}

require_owner :: proc(auth: contracts.Auth_Context, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if auth.user_id == "" do return false, domain.domain_error(.Unauthenticated, "authenticated user is required")
	if string(owner_user_id) != auth.user_id do return false, domain.domain_error(.Not_Found, "resource not found")
	return true, domain.Domain_Error{}
}

require_same_owner :: proc(parent_owner, child_owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	if parent_owner != child_owner do return false, domain.domain_error(.Forbidden, "child owner must match parent owner")
	return true, domain.Domain_Error{}
}

reject_owner_mutation :: proc(existing_owner, requested_owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	if requested_owner != "" && requested_owner != existing_owner {
		return false, domain.domain_error(.Conflict, "owner_user_id is immutable")
	}
	return true, domain.Domain_Error{}
}
