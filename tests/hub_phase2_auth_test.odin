package hub_phase2_auth_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import api_http "odin_test:hub/transport/http"
import platform "odin_test:hub/platform"

Fake_User_Repo :: struct {
	users: [8]domain.User,
	count: int,
}

fake_get_by_id :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	repo := (^Fake_User_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.users[i].user_id == user_id do return repo.users[i], true, domain.Domain_Error{}
	}
	return domain.User{}, false, domain.domain_error(.Not_Found, "fake user not found")
}

fake_save :: proc(ctx: rawptr, user: domain.User) -> (domain.User, bool, domain.Domain_Error) {
	repo := (^Fake_User_Repo)(ctx)
	if repo.count >= len(repo.users) do return domain.User{}, false, domain.domain_error(.Internal_Error, "fake repo full")
	repo.users[repo.count] = user
	repo.count += 1
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
	test_trusted_proxy_auth_success_and_failures()
	test_me_route_with_sqlite_app_graph()
	fmt.println("PASS: hub phase2 auth")
}

test_trusted_proxy_auth_success_and_failures :: proc() {
	fake: Fake_User_Repo
	repo := iface.User_Repository{ctx = rawptr(&fake), get_by_id = fake_get_by_id, save = fake_save}
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = nil, generate = fixed_id_generate}
	users := user_service.new_user_service(&repo, &clock, &ids)
	cidrs := [?]string{"127.0.0.1/32"}
	auth := auth_service.new_auth_service(auth_service.Trusted_Proxy_Config{
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
	}, &users)
	headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "Tanmay"},
		{name = "X-authentik-name", value = "Tanmay Vijay"},
		{name = "X-authentik-email", value = "tanmay@example.com"},
	}
	ctx, ok, err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "127.0.0.1:9999", headers = headers[:]})
	check(ok, err.message)
	check(ctx.kind == .Trusted_Proxy && ctx.user_id == "tanmay", "trusted proxy auth must normalize/provision user")
	check(fake.count == 1, "trusted proxy auth must auto-provision missing user")

	_, missing_ok, missing_err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "127.0.0.1", headers = []contracts.HTTP_Header{}})
	check(!missing_ok && missing_err.code == .Unauthenticated, "missing identity must be 401/unauthenticated")
	_, spoof_ok, spoof_err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "10.0.0.5", headers = headers[:]})
	check(!spoof_ok && spoof_err.code == .Unauthenticated, "spoofed trusted headers from untrusted IP must be rejected")
	_, query_token_ok, query_token_err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "127.0.0.1", query = "token=bad", headers = headers[:]})
	check(!query_token_ok && query_token_err.code == .Unauthenticated, "query tokens must be rejected")
	_, body_token_ok, body_token_err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "127.0.0.1", body = "{\"token\":\"bad\"}", headers = headers[:]})
	check(!body_token_ok && body_token_err.code == .Unauthenticated, "body tokens must be rejected")

	fake.users[fake.count] = domain.User{user_id = domain.User_ID("disabled"), name = "disabled", display_name = "Disabled", status = .Disabled}
	fake.count += 1
	disabled_headers := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "disabled"}}
	_, disabled_ok, disabled_err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "127.0.0.1", headers = disabled_headers[:]})
	check(!disabled_ok && disabled_err.code == .Forbidden, "disabled users must be rejected")
}

test_me_route_with_sqlite_app_graph :: proc() {
	db_path := "/tmp/heimdall-hub-phase2-auth-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
	})
	check(ok, message)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}
	headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "reviewer"},
		{name = "X-authentik-name", value = "Reviewer User"},
		{name = "X-authentik-email", value = "reviewer@example.com"},
	}
	resp := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_me", remote_addr = "127.0.0.1", headers = headers[:]})
	check(resp.status == 200, "valid trusted proxy user should call /me")
	check(strings.contains(resp.body, `"user_id":"reviewer"`), "/me must return current user_id")
	spoof := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_spoof", remote_addr = "10.0.0.9", headers = headers[:]})
	check(spoof.status == 401, "spoofed trusted headers from untrusted IP should get 401")
	query_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", query = "token=bad", request_id = "req_q", remote_addr = "127.0.0.1", headers = headers[:]})
	check(query_token.status == 401, "/me must reject query tokens")
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
