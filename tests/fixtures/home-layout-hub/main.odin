package main

// Loopback-only integration fixture. Production HTTP parsing, session auth,
// account guard, layout service and SQLite repositories; no live Hub is used.
// The test-only login route replaces completion of OIDC, not request auth.
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth "odin_test:hub/service/auth"
import user "odin_test:hub/service/user"
import http "odin_test:hub/transport/http"

login :: proc(ctx: rawptr, req: http.Request) -> http.Response {
	svc := (^auth.Auth_Service)(ctx)
	name := http.query_value(req.query, "user")
	if !strings.has_prefix(name, "layout_") || len(name) > 64 {
		return http.Response{status = 400, body = "invalid fixture account"}
	}
	raw, ok := auth.mint_session(svc, name)
	if !ok do return http.Response{status = 500, body = "fixture session failed"}
	cookie := auth.session_cookie_request_header(raw)
	principal, valid, _ := auth.resolve_auth(svc, {headers = []contracts.HTTP_Header{cookie}})
	if !valid do return http.Response{status = 500, body = "fixture auth failed"}
	resp := http.respond_success_typed(struct { user_id: string }{principal.user_id}, req.request_id, "")
	resp.headers = make([]contracts.HTTP_Header, 1, context.temp_allocator)
	resp.headers[0] = {"Set-Cookie", strings.concatenate({cookie.value, "; Path=/; Secure; HttpOnly; SameSite=Lax"})}
	return resp
}

main :: proc() {
	if len(os.args) != 4 do panic("usage: home-layout-hub DATABASE PORT UI_ORIGIN")
	port, valid := strconv.parse_int(os.args[2])
	if !valid || port < 1024 || port > 65535 do panic("invalid port")
	conn, opened, err := sqlite.open(os.args[1])
	if !opened do panic(err.message)
	defer sqlite.close(&conn)
	if migrated, mig_err := sqlite.run_migrations(&conn); !migrated do panic(mig_err.message)
	impl: sqlite.User_Repo_SQLite
	repo := sqlite.new_user_repository(&impl, &conn)
	session_impl: sqlite.Session_Repo_SQLite
	sessions := sqlite.new_session_repository(&session_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	users := user.new_user_service_basic(&repo, &clock, &ids)
	auth_svc := auth.new_auth_service({auto_provision_users = true}, &users, &clock, &ids)
	auth_svc.sessions = &sessions
	auth_svc.web.enabled = true
	handlers := http.User_Handlers{auth = &auth_svc, home_layouts = &users}
	router := http.new_router()
	defer http.router_free(&router)
	for method in ([]string{"GET", "PUT"}) {
		http.router_add(&router, method, "/api/v1/me/home-layout", &handlers, http.home_layout_handler)
	}
	http.router_add(&router, "POST", "/api/v1/_fixture/login", &auth_svc, login)
	fmt.println("HOME_LAYOUT_FIXTURE_READY", os.args[1])
	if !http.serve(&router, {bind_host = "127.0.0.1", port = port, ui_origin = os.args[3]}) do os.exit(1)
}
