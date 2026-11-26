package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"

home_layout_test_request :: proc(f: ^wire_fixture, method, body, expected, etag: string, account_headers: []contracts.HTTP_Header = nil) -> Request {
	req := wire_cookie_request(f, method, "/api/v1/me/home-layout", body)
	headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	base := f.user_headers if account_headers == nil else account_headers
	for header in base do append(&headers, header)
	if expected != "" do append(&headers, contracts.HTTP_Header{EXPECTED_USER_HEADER, expected})
	if etag != "" do append(&headers, contracts.HTTP_Header{"If-Match", etag})
	req.headers = headers[:]
	return req
}

@(test)
test_home_layout_if_match_contract :: proc(t: ^testing.T) {
	for bad in ([]string{"", "0", "\"\"", "*", "W/\"0\"", "\"0\",\"1\"", "\"-1\"", "\"01\"", "\"1.0\"", "\"1e2\"", "\"+1\"", "\" 1\"", "\"9007199254740991\"", "\"9007199254740992\"", "\"99999999999999999999999999\""}) {
		_, valid := home_layout_if_match(bad)
		testing.expectf(t, !valid, "reject %s", bad)
	}
	for good, i in ([]string{"\"0\"", "\"1\"", "\"2\""}) {
		n, valid := home_layout_if_match(good)
		testing.expect(t, valid && n == i64(i))
	}
	n, valid := home_layout_if_match("\"9007199254740990\"")
	testing.expect(t, valid && n == domain.HOME_LAYOUT_MAX_VERSION - 1)
}

@(test)
test_home_layout_http_persistence_conflicts_and_validation :: proc(t: ^testing.T) {
	// The shared fixture provisions bridges/users and leaves setup scratch values;
	// give the whole fixture a test-lifetime arena, as handlers have per-request arenas.
	context.allocator = context.temp_allocator
	f := wire_setup(t, "home_layout_http")
	defer wire_teardown(f)
	h := User_Handlers{auth = &f.auth_svc, home_layouts = &f.us_svc}
	owner := string(f.owner)
	get := home_layout_handler(&h, home_layout_test_request(f, "GET", "", owner, ""))
	if !testing.expect_value(t, get.status, 200) do return
	testing.expect_value(t, header_value(get.headers, "ETag"), "\"0\"")
	testing.expect_value(t, header_value(get.headers, "Cache-Control"), "no-store")
	_, found, read_err := iface.home_layout_get(&f.us_repo, f.owner)
	testing.expect(t, !found && read_err.code == .None, "default GET has no storage side effect")
	body := `{"version":0,"widgets":[{"id":"fleet","width":1,"hidden":true,"options":{"mobile_order":2,"custom":{"theme":"dark"}}},{"id":"uptime","width":2,"hidden":false,"options":{"mobile_order":0}}]}`
	put := home_layout_handler(&h, home_layout_test_request(f, "PUT", body, owner, "\"0\""))
	if !testing.expect_value(t, put.status, 200) do return
	testing.expect_value(t, header_value(put.headers, "ETag"), "\"1\"")
	wire: struct { data: domain.Home_Layout }
	testing.expect(t, json.unmarshal_string(put.body, &wire, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, wire.data.version, i64(1))
	testing.expect_value(t, len(wire.data.widgets), 4)
	testing.expect(t, wire.data.widgets[0].id == "fleet" && wire.data.widgets[0].hidden && wire.data.widgets[0].width == 1)
	testing.expect(t, wire.data.widgets[1].id == "uptime" && wire.data.widgets[1].width == 2)
	testing.expect_value(t, wire.data.widgets[2].id, "activity")
	testing.expect_value(t, wire.data.widgets[3].id, "chains")
	order, rank_ok := domain.home_layout_integer(wire.data.widgets[0].options["mobile_order"])
	testing.expect(t, rank_ok && order == 2)
	get = home_layout_handler(&h, home_layout_test_request(f, "GET", "", owner, ""))
	testing.expect_value(t, get.status, 200)
	testing.expect_value(t, header_value(get.headers, "ETag"), "\"1\"")
	testing.expect(t, strings.contains(get.body, `"custom":{"theme":"dark"}`))
	stale := home_layout_handler(&h, home_layout_test_request(f, "PUT", body, owner, "\"0\""))
	testing.expect(t, stale.status == 409 && strings.contains(stale.body, `"code":"conflict"`) && strings.contains(stale.body, "home_layout_version_conflict"))

	before, before_found, _ := iface.home_layout_get(&f.us_repo, f.owner)
	defer delete(before.payload_json)
	testing.expect(t, before_found && before.revision == 1)
	for bad in ([]string{
		`null`, `{"version":1,"widgets":[{"id":"fleet","width":7,"hidden":false}]}`,
		`{"version":1,"widgets":[{"id":"fleet","width":1,"hidden":"false"}]}`,
		`{"version":1,"widgets":[{"id":"fleet","width":1,"hidden":false,"options":[]}]}`,
		`{"version":1,"widgets":[],"owner_user_id":"other"}`, `{"version":0,"widgets":[]}`,
		strings.repeat(" ", domain.HOME_LAYOUT_MAX_BYTES + 1, context.temp_allocator),
	}) {
		resp := home_layout_handler(&h, home_layout_test_request(f, "PUT", bad, owner, "\"1\""))
		testing.expectf(t, resp.status == 400 && strings.contains(resp.body, `"code":"validation_failed"`), "invalid body refuses with 400: %s", resp.body)
	}
	for etag in ([]string{"", "1", "*", "W/\"1\"", "\"1\",\"2\""}) {
		resp := home_layout_handler(&h, home_layout_test_request(f, "PUT", `{"version":1,"widgets":[]}`, owner, etag))
		testing.expect_value(t, resp.status, 400)
	}
	duplicate := home_layout_test_request(f, "PUT", `{"version":1,"widgets":[]}`, owner, "\"1\"")
	headers := make([]contracts.HTTP_Header, len(duplicate.headers) + 1, context.temp_allocator)
	copy(headers, duplicate.headers); headers[len(duplicate.headers)] = {"if-match", "\"1\""}; duplicate.headers = headers
	testing.expect_value(t, home_layout_handler(&h, duplicate).status, 400)
	after, after_found, _ := iface.home_layout_get(&f.us_repo, f.owner)
	defer delete(after.payload_json)
	testing.expect(t, after_found && after.revision == 1 && before.payload_json == after.payload_json, "all invalid and stale writes leave the row unchanged")
	updated := home_layout_handler(&h, home_layout_test_request(f, "PUT", `{"version":1,"widgets":[]}`, owner, "\"1\""))
	testing.expect_value(t, updated.status, 200)
	testing.expect_value(t, header_value(updated.headers, "ETag"), "\"2\"")
}

@(test)
test_home_layout_http_account_switch_and_agent_denial :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := wire_setup(t, "home_layout_accounts")
	defer wire_teardown(f)
	h := User_Handlers{auth = &f.auth_svc, home_layouts = &f.us_svc}
	owner := string(f.owner)
	body := `{"version":0,"widgets":[]}`
	for method in ([]string{"GET", "PUT"}) {
		missing := home_layout_handler(&h, home_layout_test_request(f, method, body, "", "\"0\""))
		testing.expect_value(t, missing.status, 400)
		mismatch := home_layout_handler(&h, home_layout_test_request(f, method, body, "someone_else", "\"0\""))
		testing.expect(t, mismatch.status == 409 && strings.contains(mismatch.body, `"code":"account_mismatch"`))
		agent_req := wire_agent_request(f, "", body)
		agent_req.method = method; agent_req.path = "/api/v1/me/home-layout"
		agent_resp := home_layout_handler(&h, agent_req)
		testing.expect(t, agent_resp.status == 401 || agent_resp.status == 403, "agent cannot read or write preferences")
	}
	duplicate := home_layout_test_request(f, "GET", "", owner, "")
	headers := make([]contracts.HTTP_Header, len(duplicate.headers) + 1, context.temp_allocator)
	copy(headers, duplicate.headers); headers[len(duplicate.headers)] = {"x-heimdall-expected-user", owner}; duplicate.headers = headers
	testing.expect_value(t, home_layout_handler(&h, duplicate).status, 400)
	testing.expect_value(t, home_layout_handler(&h, home_layout_test_request(f, "PUT", body, owner, "\"0\"")).status, 200)

	other_headers := http_test_login(t, &f.auth_svc, "layout_other_account")
	other, other_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, {headers = other_headers, remote_addr = "127.0.0.1:4444"})
	if !testing.expect(t, other_ok && other.user_id != owner) do return
	// A queued request from A sent with B's now-active cookie is fenced on both verbs.
	for method in ([]string{"GET", "PUT"}) {
		resp := home_layout_handler(&h, home_layout_test_request(f, method, body, owner, "\"0\"", other_headers))
		testing.expect(t, resp.status == 409 && strings.contains(resp.body, `"code":"account_mismatch"`))
	}
	get_b := home_layout_handler(&h, home_layout_test_request(f, "GET", "", other.user_id, "", other_headers))
	testing.expect_value(t, get_b.status, 200)
	testing.expect_value(t, header_value(get_b.headers, "ETag"), "\"0\"")
	_, found_b, _ := iface.home_layout_get(&f.us_repo, domain.User_ID(other.user_id))
	testing.expect(t, !found_b, "mismatched A writes and B GET do not create a B row")
	get_a := home_layout_handler(&h, home_layout_test_request(f, "GET", "", owner, ""))
	testing.expect_value(t, header_value(get_a.headers, "ETag"), "\"1\"")
}
