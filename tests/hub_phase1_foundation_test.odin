package hub_phase1_foundation_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import user_service "odin_test:hub/service/user"
import api_http "odin_test:hub/transport/http"
import platform "odin_test:hub/platform"

Fake_User_Repo :: struct {
	saved: domain.User,
	has_saved: bool,
}

fake_get_by_id :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	repo := (^Fake_User_Repo)(ctx)
	if repo.has_saved && repo.saved.user_id == user_id do return repo.saved, true, domain.Domain_Error{}
	return domain.User{}, false, domain.domain_error(.Not_Found, "fake user not found")
}

fake_save :: proc(ctx: rawptr, user: domain.User) -> (domain.User, bool, domain.Domain_Error) {
	repo := (^Fake_User_Repo)(ctx)
	repo.saved = user
	repo.has_saved = true
	return user, true, domain.Domain_Error{}
}

fixed_clock_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	return "2026-07-22T10:00:00Z"
}

fixed_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	_ = ctx
	return strings.concatenate({prefix, "fixed"})
}

main :: proc() {
	test_envelopes()
	test_query_parser()
	test_service_with_fake_repo()
	test_router_envelope_dispatch()
	fmt.println("PASS: hub phase1 foundation")
}

test_envelopes :: proc() {
	meta := contracts.api_meta("req_123", "2026-07-22T10:00:00Z")
	success := contracts.api_success_json("{\"ok\":true}", meta)
	check(strings.contains(success, `"data":{"ok":true}`), "success envelope must include data")
	check(strings.contains(success, `"request_id":"req_123"`), "success envelope must include request_id")
	check(strings.contains(success, `"server_time":"2026-07-22T10:00:00Z"`), "success envelope must include server_time")

	list := contracts.api_list_json("[]", contracts.api_page(500, "cursor_abc", true), meta)
	check(strings.contains(list, `"limit":200`), "list envelope must clamp limit to max 200")
	check(strings.contains(list, `"next_cursor":"cursor_abc"`), "list envelope must include next_cursor")
	check(strings.contains(list, `"has_more":true`), "list envelope must include has_more")

	err := contracts.api_error_json(contracts.API_Error{code = "forbidden", message = "nope"}, meta)
	check(strings.contains(err, `"error":{"code":"forbidden"`), "error envelope must include error code")
	check(!strings.contains(err, "server_time"), "error envelope meta should only require request_id")
}

test_query_parser :: proc() {
	allowed_filters := [?]string{"status", "bridge_id"}
	allowed_sort := [?]string{"updated_at", "name"}
	allowed_expand := [?]string{"instances", "tasks"}
	parsed := api_http.parse_api_query("limit=250&cursor=abc&q=backend+agent&status=online&status=blocked&sort=-updated_at,name&expand=instances,tasks", allowed_filters[:], allowed_sort[:], allowed_expand[:])
	defer api_http.parsed_query_free(&parsed)
	check(parsed.limit == 200, "parser must clamp limit")
	check(parsed.cursor == "abc", "parser must parse cursor")
	check(parsed.search == "backend agent", "parser must decode q")
	check(len(parsed.filters) == 2, "parser must preserve repeated filter parameters")
	check(parsed.sort[0].field == "updated_at" && parsed.sort[0].direction == .Desc, "parser must parse descending sort")
	check(len(parsed.expand) == 2, "parser must parse whitelisted expansions")
	check(len(parsed.errors) == 0, "parser should not report errors for valid query")
}

test_service_with_fake_repo :: proc() {
	fake: Fake_User_Repo
	repo := iface.User_Repository{ctx = rawptr(&fake), get_by_id = fake_get_by_id, save = fake_save}
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = nil, generate = fixed_id_generate}
	svc := user_service.new_user_service(&repo, &clock, &ids)
	created, ok, err := user_service.create_user_stub(&svc, "Tester", "tester@example.test")
	check(ok, err.message)
	check(created.user_id == domain.User_ID("usr_fixed"), "service must use injected ID generator")
	loaded, loaded_ok, load_err := user_service.get_user(&svc, created.user_id)
	check(loaded_ok, load_err.message)
	check(loaded.display_name == "Tester", "service must use fake repo without DB")
}

test_router_envelope_dispatch :: proc() {
	router := api_http.new_router()
	defer api_http.router_free(&router)
	api_http.router_add(&router, "GET", "/api/v1/test", nil, test_handler)
	resp := api_http.router_dispatch(&router, api_http.Request{method = "GET", path = "/api/v1/test", request_id = "req_health"})
	check(resp.status == 200, "router should serve /api/v1 routes")
	check(strings.contains(resp.body, `"request_id":"req_health"`), "router response must use envelope meta")
	missing := api_http.router_dispatch(&router, api_http.Request{method = "GET", path = "/legacy/test", request_id = "req_missing"})
	check(missing.status == 404, "router should reject non-/api/v1 routes")
}

test_handler :: proc(ctx: rawptr, req: api_http.Request) -> api_http.Response {
	_ = ctx
	return api_http.respond_success("{\"ok\":true}", req.request_id, "2026-07-22T10:00:00Z")
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
