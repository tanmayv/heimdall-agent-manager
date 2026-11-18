#+private file
package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// REQ-SWFIX-STALE-1: a stale browser context names the user it last synced as.

@(test)
test_expected_user_gate_mismatch_is_409_account_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for kind in ([]contracts.Auth_Kind{.OIDC, .Session}) {
		principal := contracts.Auth_Context{kind = kind, user_id = "usr_b"}
		ok, resp := expected_user_gate(principal, "usr_a", "req_1")
		testing.expect(t, !ok)
		testing.expect_value(t, resp.status, 409)
		testing.expect(t, strings.contains(resp.body, "\"code\":\"account_mismatch\""))
	}
}

@(test)
test_expected_user_gate_unchanged_without_header_or_on_match :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	principal := contracts.Auth_Context{kind = .Session, user_id = "usr_b"}
	missing_ok, _ := expected_user_gate(principal, "", "req_1")
	testing.expect(t, missing_ok)
	match_ok, _ := expected_user_gate(principal, "usr_b", "req_1")
	testing.expect(t, match_ok)
	// CLI/bridge principals never carry the browser header semantics.
	bridge_ok, _ := expected_user_gate(contracts.Auth_Context{kind = .Bridge_Token, user_id = "usr_b"}, "usr_a", "req_1")
	testing.expect(t, bridge_ok)
}
