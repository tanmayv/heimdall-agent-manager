package user

import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

home_layout_account_guard :: proc(auth: contracts.Auth_Context, expected_user: string) -> domain.Domain_Error {
	if !contracts.is_user_auth(auth) || auth.user_id == "" do return domain.domain_error(.Forbidden, "user authentication is required")
	if expected_user == "" do return domain.domain_error(.Validation_Failed, "X-Heimdall-Expected-User is required")
	if expected_user != auth.user_id do return domain.domain_error(.Account_Mismatch, "The signed-in account changed. Reload to continue as the active account.")
	return {}
}

get_home_layout :: proc(service: ^User_Service, auth: contracts.Auth_Context, expected_user: string) -> (domain.Home_Layout, domain.Domain_Error) {
	if err := home_layout_account_guard(auth, expected_user); err.code != .None do return {}, err
	if service == nil do return {}, domain.domain_error(.Internal_Error, "user service is not configured")
	row, found, err := iface.home_layout_get(service.users, domain.User_ID(auth.user_id))
	if err.code != .None do return {}, err
	if !found do return domain.home_layout_default(), {}
	defer delete(row.payload_json)
	layout, parse_err := domain.home_layout_parse(row.payload_json, false)
	if parse_err.code != .None || row.revision < 1 || row.revision > domain.HOME_LAYOUT_MAX_VERSION do return {}, domain.domain_error(.Internal_Error, "invalid persisted Home layout")
	layout.version = row.revision
	return layout, {}
}

put_home_layout :: proc(service: ^User_Service, auth: contracts.Auth_Context, expected_user: string, expected_version: i64, payload: string) -> (domain.Home_Layout, domain.Domain_Error) {
	if err := home_layout_account_guard(auth, expected_user); err.code != .None do return {}, err
	if service == nil do return {}, domain.domain_error(.Internal_Error, "user service is not configured")
	if expected_version < 0 || expected_version >= domain.HOME_LAYOUT_MAX_VERSION do return {}, domain.domain_error(.Validation_Failed, "invalid Home layout version precondition")
	layout, err := domain.home_layout_parse(payload, true)
	if err.code != .None do return {}, err
	if layout.version != expected_version do return {}, domain.domain_error(.Validation_Failed, "Home layout version must match If-Match")
	layout.version = expected_version + 1
	encoded, encode_err := json.marshal(layout, allocator = context.temp_allocator)
	if encode_err != nil do return {}, domain.domain_error(.Internal_Error, "failed to encode Home layout")
	// Canonicalization may add defaults or expand escaped JSON.
	if len(encoded) > domain.HOME_LAYOUT_MAX_BYTES do return {}, domain.domain_error(.Validation_Failed, "canonical Home layout exceeds 32 KiB")
	if _, save_err := iface.home_layout_cas(service.users, domain.User_ID(auth.user_id), expected_version, string(encoded)); save_err.code != .None do return {}, save_err
	return layout, {}
}
