package auth

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import user_service "odin_test:hub/service/user"

@(test)
test_session_ring_parser_and_cookie_attributes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := strings.repeat("A", 32, context.temp_allocator)
	second := strings.repeat("b", 128, context.temp_allocator)
	bad := []string{"short", strings.repeat("c", 129, context.temp_allocator), fmt.tprintf("%s.", strings.repeat("d", 31, context.temp_allocator)), fmt.tprintf("%s=", strings.repeat("e", 31, context.temp_allocator)), fmt.tprintf("%s/", strings.repeat("f", 31, context.temp_allocator))}
	for invalid in bad do testing.expect(t, !session_token_syntax_valid(invalid))
	headers := []contracts.HTTP_Header{{"Cookie", fmt.tprintf("%s=%s; %s=%s.%s.%s.short", SESSION_COOKIE, first, SESSIONS_RING_COOKIE, second, first, second)}}
	ring := parse_sessions_ring(headers)
	testing.expect_value(t, len(ring), 2)
	if len(ring) == 2 { testing.expect_value(t, ring[0], first); testing.expect_value(t, ring[1], second) }
	cookie := sessions_ring_cookie_header(ring[:], 600)
	for attr in ([]string{SESSIONS_RING_COOKIE, "Path=/", "Secure", "HttpOnly", "SameSite=Lax", "Max-Age=600"}) do testing.expect(t, strings.contains(cookie, attr), attr)
	testing.expect(t, !strings.contains(cookie, "Domain="))
	testing.expect_value(t, sessions_ring_cookie_header(nil, 600), expired_cookie_header(SESSIONS_RING_COOKIE))
	// Ambiguous duplicate cookie names are never selected by the parser.
	ambiguous := []contracts.HTTP_Header{{"Cookie", fmt.tprintf("%s=%s; %s=%s", SESSION_COOKIE, first, SESSION_COOKIE, second)}}
	testing.expect_value(t, len(parse_sessions_ring(ambiguous)), 0)
}

@(private = "file")
ring_test_get_user :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	return domain.User{user_id = user_id, name = string(user_id), display_name = "Account", email = "account@example.test", status = .Active}, true, {}
}

@(private = "file")
ring_test_now :: proc(ctx: rawptr) -> string { return (^string)(ctx)^ }

// REQ-ACCT-RING-3: duplicate-user and overflow pruning is only a cookie view.
// Both touch/delete callbacks are disabled, proving GET resolution never writes.
@(test)
test_session_ring_read_only_duplicate_and_overflow :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	now := "2026-10-19T10:00:00Z"
	clock := platform.Clock{now = ring_test_now, ctx = &now}
	repo := iface.User_Repository{get_by_id = ring_test_get_user}
	users := user_service.new_user_service_basic(&repo, &clock, nil)
	service := new_auth_service({}, &users, &clock)
	store := use_memory_sessions(&service)
	defer release_memory_sessions(&service, store)
	raws := make([dynamic]string, context.temp_allocator)
	for user_id in ([]string{"alice", "alice", "bob", "carol", "dave", "eve", "frank"}) {
		raw, ok := mint_session(&service, user_id, ensure_user = false)
		testing.expect(t, ok)
		append(&raws, raw)
	}
	store.repo.touch_session, store.repo.delete_session = nil, nil
	now = "2026-10-19T10:02:00Z"
	// Active cookie takes precedence over the opposite order in the ring.
	headers := []contracts.HTTP_Header{{"Cookie", fmt.tprintf("%s=%s; %s=%s", SESSION_COOKIE, raws[2], SESSIONS_RING_COOKIE, strings.join(raws[:], ".", context.temp_allocator))}}
	active, ring, accounts, changed := resolve_session_ring(&service, headers)
	testing.expect(t, changed)
	testing.expect_value(t, active, raws[2])
	testing.expect_value(t, len(ring), MAX_BROWSER_ACCOUNTS)
	testing.expect_value(t, len(accounts), MAX_BROWSER_ACCOUNTS)
	for account, i in accounts {
		testing.expect_value(t, account.active, i == 0)
		for other in accounts[:i] do testing.expect(t, other.user_id != account.user_id)
	}
	for raw in raws {
		row, found, err := store.repo.get_session(store.repo.ctx, sha256_hex(raw))
		testing.expect(t, found && err.code == .None)
		base_ms, _ := platform.rfc3339_to_unix_ms("2026-10-19T10:00:00Z")
		testing.expect_value(t, row.last_seen_at_ms, base_ms)
	}
	clean := []contracts.HTTP_Header{{"Cookie", fmt.tprintf("%s=%s; %s=%s", SESSION_COOKIE, active, SESSIONS_RING_COOKIE, strings.join(ring[:], ".", context.temp_allocator))}}
	_, _, _, changed = resolve_session_ring(&service, clean)
	testing.expect(t, !changed, "repeated listing with the repaired cookie is idempotent")
}
