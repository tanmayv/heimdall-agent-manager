package http

import "base:runtime"

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import users "odin_test:hub/service/user"
import sqlite "odin_test:hub/repository/sqlite"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project "odin_test:hub/service/project"
import events "odin_test:hub/service/events"

@(test)
test_secure_form_route_reservation_and_restart :: proc(t: ^testing.T) {
	routing: Secure_Form_Routing
	defer {
		for _, route in routing.forms do secure_form_route_free(route)
		delete(routing.forms)
	}
	request := contracts.Secure_Form_Request{request_id = "synthetic-request", bridge = "synthetic-bridge", owner = "owner"}
	testing.expect_value(t, secure_form_route_insert(&routing, request, "public registration", 1, 1, 100, 200, 1), Secure_Form_Register_Result.Registered)
	testing.expect_value(t, secure_form_route_insert(&routing, request, "public registration", 1, 2, 100, 200, 1), Secure_Form_Register_Result.Duplicate)
	testing.expect_value(t, secure_form_route_insert(&routing, request, "public registration", 2, 2, 100, 200, 1), Secure_Form_Register_Result.Refused)
	testing.expect_value(t, secure_form_route_insert(&routing, request, "replaced public registration", 1, 2, 100, 200, 1), Secure_Form_Register_Result.Refused)

	sync.lock(&routing.mu)
	defer sync.unlock(&routing.mu)
	_, cross_owner := secure_form_route_reserve(&routing, "other", request.request_id, 1, 10)
	_, stale_generation := secure_form_route_reserve(&routing, request.owner, request.request_id, 2, 10)
	route, reserved := secure_form_route_reserve(&routing, request.owner, request.request_id, 1, 10)
	_, duplicate := secure_form_route_reserve(&routing, request.owner, request.request_id, 1, 10)
	testing.expect_value(t, cross_owner, Secure_Form_Reserve_Result.Missing)
	testing.expect_value(t, stale_generation, Secure_Form_Reserve_Result.Stale)
	testing.expect_value(t, reserved, Secure_Form_Reserve_Result.Reserved)
	testing.expect_value(t, duplicate, Secure_Form_Reserve_Result.Conflict)
	if route == nil do return

	secure_form_route_unreserve(route)
	_, next := secure_form_route_reserve(&routing, request.owner, request.request_id, 1, 11)
	testing.expect_value(t, next, Secure_Form_Reserve_Result.Reserved)
	testing.expect(t, secure_form_route_apply_ack(route, {state = "final", code = contracts.Secure_Form_Exit.Unknown}))
	testing.expect(t, !secure_form_route_apply_ack(route, {state = "accepted"}))
	route.in_flight = false

	restarted: Secure_Form_Routing
	testing.expect(t, secure_form_route_lookup(&restarted, request.owner, request.request_id) == nil)
	secure_form_route_sweep(&routing, 199)
	testing.expect(t, secure_form_route_lookup(&routing, request.owner, request.request_id) != nil)
	secure_form_route_sweep(&routing, 200)
	testing.expect(t, secure_form_route_lookup(&routing, request.owner, request.request_id) == nil)
}

@(test)
test_secure_form_only_one_concurrent_reservation :: proc(t: ^testing.T) {
	routing: Secure_Form_Routing
	defer {
		for _, route in routing.forms do secure_form_route_free(route)
		delete(routing.forms)
	}
	request := contracts.Secure_Form_Request{request_id = "race-id", bridge = "synthetic-bridge", owner = "owner"}
	testing.expect_value(t, secure_form_route_insert(&routing, request, "public registration", 1, 1, 100, 200, 1), Secure_Form_Register_Result.Registered)
	Race :: struct {
		routing: ^Secure_Form_Routing,
		result: Secure_Form_Reserve_Result,
	}
	races := [2]Race{{routing = &routing}, {routing = &routing}}
	workers: [2]^thread.Thread
	sync.lock(&routing.mu)
	for &race, i in races {
		workers[i] = thread.create_and_start_with_data(&race, proc(raw: rawptr) {
			job := (^Race)(raw)
			sync.lock(&job.routing.mu)
			defer sync.unlock(&job.routing.mu)
			_, job.result = secure_form_route_reserve(job.routing, "owner", "race-id", 1, 10)
		}, self_cleanup = false)
	}
	sync.unlock(&routing.mu)
	for worker in workers {
		if !testing.expect(t, worker != nil) do continue
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expect(t, (races[0].result == .Reserved && races[1].result == .Conflict) ||
		(races[1].result == .Reserved && races[0].result == .Conflict))
}

SECURE_FORM_TEST_FIXTURE :: #load("../../../../tests/fixtures/secure-form-v1.json", string)
SECURE_FORM_TEST_ID :: "abababababababababababababababababababababababababababababababab"
SECURE_FORM_TEST_PROOF :: "secure-form-proof-canary-1238bc24"

secure_form_sql_changes :: proc(conn: ^sqlite.Conn) -> i64 {
	stmt: sqlite.sqlite3_stmt
	if sqlite.sqlite3_prepare_v2(conn.db, "SELECT total_changes()", -1, &stmt, nil) != sqlite.SQLITE_OK do return -1
	defer sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW do return -1
	return sqlite.sqlite3_column_int64(stmt, 0)
}

secure_form_test_request :: proc(method, path, query, body, cookie, origin: string) -> Request {
	headers := make([dynamic]contracts.HTTP_Header)
	append(&headers, auth_service.session_cookie_request_header(cookie))
	if origin != "" do append(&headers, contracts.HTTP_Header{"Origin", origin})
	return {method = method, path = path, query = query, body = body, headers = headers[:]}
}

secure_form_test_read_text :: proc(peer: net.TCP_Socket) -> string {
	received := make([dynamic]byte)
	buf: [4096]byte
	for len(received) < 4096 {
		n, err := net.recv_tcp(peer, buf[:])
		if n > 0 do append(&received, ..buf[:n])
		if len(received) >= 2 {
			n := int(received[1] & 127)
			hdr := 2
			if received[0] != 0x81 || n == 127 do return ""
			if n == 126 {
				if len(received) < 4 && err == nil do continue
				if len(received) < 4 do return ""
				n = int(received[2]) * 256 + int(received[3])
				hdr = 4
			}
			if len(received) >= n + hdr do return string(received[hdr:hdr+n])
		}
		if err != nil || n == 0 do break
	}
	return ""
}

@(test)
test_secure_form_http_routes_never_publish_or_store_answer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	user_impl: sqlite.User_Repo_SQLite
	user_repo := sqlite.new_user_repository(&user_impl, &conn)
	session_impl: sqlite.Session_Repo_SQLite
	session_repo := sqlite.new_session_repository(&session_impl, &conn)
	clock := platform.Clock{now = proc(_: rawptr) -> string { return "2026-10-19T10:00:00Z" }}
	user_svc := users.new_user_service_basic(&user_repo, &clock, nil)
	for id in ([]string{"alice", "bob"}) {
		_, saved, _ := iface.user_save(&user_repo, domain.User{user_id = domain.User_ID(id), name = id, status = .Active})
		if !testing.expect(t, saved) do return
	}
	origin := "https://hub.example.test"
	auth := auth_service.Auth_Service{users = &user_svc, clock = &clock, sessions = &session_repo,
		web = {enabled = true, ui_origin = origin}}
	owner, owner_ok := auth_service.mint_session(&auth, "alice", ensure_user = false)
	other, other_ok := auth_service.mint_session(&auth, "bob", ensure_user = false)
	if !testing.expect(t, owner_ok && other_ok) do return
	router := new_router()
	defer router_free(&router)
	registry: project.Bridge_Runtime_Registry
	h := Bridge_Handlers{auth = &auth, bridge_runtime_registry = &registry}
	defer secure_form_routing_destroy(&h.secure_forms)
	defer bridge_runtime.runtime_command_cache_destroy(&registry)
	router_add_secure_forms(&router, &h)

	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	peer, dial_err := net.dial_tcp(endpoint)
	if !testing.expect(t, dial_err == nil) do return
	defer net.close(peer)
	connection, _, accept_err := net.accept_tcp(listener)
	if !testing.expect(t, accept_err == nil) do return
	defer net.close(connection)
	_ = net.set_option(peer, .Receive_Timeout, 2 * time.Second)

	bridge_id := "brg_secure_form_http"
	hello, connected, _ := bridge_runtime.runtime_accept_hello(&registry, bridge_id, bridge_runtime.PROTOCOL_VERSION, "", owner_user_id = "alice")
	if !testing.expect(t, connected) do return
	project.bridge_runtime_registry_set_command_socket(&registry, bridge_id, connection, hello.generation)
	generation := fmt.tprintf("%d", hello.generation)
	signed := contracts.Secure_Form_Request{owner = "alice", bridge = bridge_id, conversation = "chat_alice", request_id = SECURE_FORM_TEST_ID}
	now := secure_form_now_ms()
	testing.expect_value(t, secure_form_route_insert(&h.secure_forms, signed, `{"schema":"public metadata"}`, hello.generation, now, now+60_000, now+1_000_000, 4), Secure_Form_Register_Result.Registered)
	h.secure_forms.forms[signed.request_id].registered = true

	vector, vector_err := json.parse_string(SECURE_FORM_TEST_FIXTURE)
	if !testing.expect(t, vector_err == nil) do return
	answer := vector.(json.Object)["answer"].(json.Object)
	ciphertext := string(answer["ciphertext"].(json.String))
	envelope, envelope_err := json.marshal(answer)
	if !testing.expect(t, envelope_err == nil) do return
	submission, body_err := json.marshal(contracts.Secure_Form_Submission{1, signed.request_id, generation, string(envelope), SECURE_FORM_TEST_PROOF})
	if !testing.expect(t, body_err == nil) do return
	path := strings.concatenate({contracts.SECURE_FORM_API_PATH, "/", signed.request_id})
	check_status := proc(t: ^testing.T, r: Response, code: int, ciphertext: string) {
		testing.expect_value(t, r.status, code)
		testing.expect_value(t, header_value(r.headers, "Cache-Control"), "no-store")
		testing.expect(t, !strings.contains(r.body, ciphertext))
		testing.expect(t, !strings.contains(r.body, SECURE_FORM_TEST_PROOF))
	}
	baseline := secure_form_sql_changes(&conn)
	testing.expect(t, baseline >= 0)
	check_status(t, router_dispatch(&router, secure_form_test_request("GET", path, "", "", other, "")), 404, ciphertext)
	list := router_dispatch(&router, secure_form_test_request("GET", contracts.SECURE_FORM_API_PATH, "conversation_id=chat_alice", "", other, ""))
	check_status(t, list, 200, ciphertext)
	testing.expect(t, !strings.contains(list.body, signed.request_id))
	list = router_dispatch(&router, secure_form_test_request("GET", contracts.SECURE_FORM_API_PATH, "conversation_id=chat_alice", "", owner, ""))
	check_status(t, list, 200, ciphertext)
	testing.expect(t, strings.contains(list.body, signed.request_id))

	submit := strings.concatenate({path, "/submit"})
	req := secure_form_test_request("POST", submit, "", string(submission), other, origin)
	check_status(t, router_dispatch(&router, req), 404, ciphertext)
	req = secure_form_test_request("POST", submit, "", string(submission), owner, "https://evil.example.test")
	check_status(t, router_dispatch(&router, req), 403, ciphertext)
	req = secure_form_test_request("POST", submit, "", string(submission), owner, origin)
	live := project.bridge_runtime_connection_acquire(&registry, bridge_id, hello.generation)
	if !testing.expect(t, live != nil) do return
	sync.lock(&live.writer_mutex)
	busy := router_dispatch(&router, req)
	sync.unlock(&live.writer_mutex)
	project.bridge_runtime_connection_release(&registry, live)
	check_status(t, busy, 503, ciphertext)
	check_status(t, router_dispatch(&router, req), 202, ciphertext)
	check_status(t, router_dispatch(&router, req), 409, ciphertext)

	frame := secure_form_test_read_text(peer)
	testing.expect(t, strings.contains(frame, ciphertext))
	testing.expect(t, strings.contains(frame, SECURE_FORM_TEST_PROOF))
	ack := contracts.Secure_Form_Ack{1, signed.request_id, generation, "accepted", nil}
	wire, err := json.marshal(contracts.Secure_Form_Wire_Frame(contracts.Secure_Form_Ack){contracts.SECURE_FORM_ACK_FRAME, 1, ack})
	if !testing.expect(t, err == nil) do return
	secure_form_bridge_status(&h, bridge_id, hello.generation + 1, contracts.SECURE_FORM_ACK_FRAME, string(wire))
	stale := router_dispatch(&router, secure_form_test_request("GET", path, "", "", owner, ""))
	testing.expect(t, strings.contains(stale.body, "forwarding"))
	// Observe a real browser bus delivery. It is invalidation-only and
	// never carries ciphertext, proof or public registration data.
	event_peer, event_dial_err := net.dial_tcp(endpoint)
	if !testing.expect(t, event_dial_err == nil) do return
	defer net.close(event_peer)
	event_hub, _, event_accept_err := net.accept_tcp(listener)
	if !testing.expect(t, event_accept_err == nil) do return
	defer net.close(event_hub)
	_ = net.set_option(event_peer, .Receive_Timeout, 2 * time.Second)
	bus: events.User_Event_Bus
	h.event_bus = &bus
	subscriber := events.user_ws_add(&bus, "alice", event_hub)
	if !testing.expect(t, subscriber >= 0) do return
	defer events.user_ws_remove(&bus, subscriber)

	secure_form_bridge_status(&h, bridge_id, hello.generation, contracts.SECURE_FORM_ACK_FRAME, string(wire))
	event := secure_form_test_read_text(event_peer)
	testing.expect(t, strings.contains(event, contracts.SECURE_FORM_CHANGED_EVENT))
	testing.expect(t, strings.contains(event, signed.request_id))
	testing.expect(t, !strings.contains(event, ciphertext) && !strings.contains(event, SECURE_FORM_TEST_PROOF))
	testing.expect(t, !strings.contains(event, "public metadata"))
	status := router_dispatch(&router, secure_form_test_request("GET", path, "", "", owner, ""))
	check_status(t, status, 200, ciphertext)
	testing.expect(t, strings.contains(status.body, "accepted"))

	ack.state, ack.code = "final", .Child_Failed
	wire, err = json.marshal(contracts.Secure_Form_Wire_Frame(contracts.Secure_Form_Ack){contracts.SECURE_FORM_ACK_FRAME, 1, ack})
	if !testing.expect(t, err == nil) do return
	secure_form_bridge_status(&h, bridge_id, hello.generation, contracts.SECURE_FORM_ACK_FRAME, string(wire))
	final_status := router_dispatch(&router, secure_form_test_request("GET", path, "", "", owner, ""))
	check_status(t, final_status, 200, ciphertext)
	testing.expect(t, strings.contains(final_status.body, `"code":26`))

	testing.expect_value(t, secure_form_sql_changes(&conn), baseline)
}

@(test)
test_secure_form_write_outcomes_distinguish_no_write_from_partial_write :: proc(t: ^testing.T) {
	h: Bridge_Handlers
	for result in ([]bridge_runtime.Command_Write_Result{.Not_Connected, .Send_Failed}) {
		route := Secure_Form_Route{state = .Forwarding, in_flight = true}
		job := new(Secure_Form_Write_Context, runtime.heap_allocator())
		job^ = {&h, &route, false}
		secure_form_write_complete(job, result)
		expected := contracts.Secure_Form_Exit.Not_Delivered if result == .Not_Connected else contracts.Secure_Form_Exit.Unknown
		code, present := route.code.?
		testing.expect(t, !route.in_flight && route.state == .Final && present)
		testing.expect_value(t, code, expected)
	}
}
