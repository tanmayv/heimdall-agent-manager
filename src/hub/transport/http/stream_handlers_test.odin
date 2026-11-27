package http

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agents "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import events "odin_test:hub/service/events"
import project "odin_test:hub/service/project"
import users "odin_test:hub/service/user"

STREAM_TEST_ID :: "123456789012345678901234567890ab"
STREAM_TEST_BRIDGE :: "brg_stream_a"
STREAM_TEST_INSTANCE :: "inst_stream_a"
STREAM_TEST_TASK :: "task_stream_a"
STREAM_TEST_MARKER :: "synthetic-image-canary-c5ac1640"

Stream_Test_Pair :: struct {peer, hub: net.TCP_Socket}

stream_test_pair :: proc(t: ^testing.T) -> (Stream_Test_Pair, bool) {
	listener, le := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, le == nil) do return {}, false
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	peer, de := net.dial_tcp(endpoint)
	if !testing.expect(t, de == nil) do return {}, false
	hub, _, ae := net.accept_tcp(listener)
	if !testing.expect(t, ae == nil) {
		net.close(peer)
		return {}, false
	}
	_ = net.set_option(peer, .Receive_Timeout, time.Second)
	return {peer, hub}, true
}

stream_test_pair_close :: proc(p: Stream_Test_Pair) {
	net.close(p.peer)
	net.close(p.hub)
}

stream_test_http_header :: proc(peer: net.TCP_Socket) -> string {
	// Leave any immediately replayed binary frame in the socket.
	header: [dynamic]byte
	defer delete(header)
	next: [1]byte
	for len(header) < 4096 {
		n, err := net.recv_tcp(peer, next[:])
		if err != nil || n == 0 do break
		append(&header, next[0])
		if strings.has_suffix(string(header[:]), "\r\n\r\n") do break
	}
	return strings.clone(string(header[:]), context.temp_allocator)
}

Stream_Test_Viewer :: struct {router: ^Router, req: Request, socket: net.TCP_Socket}

stream_test_run_viewer :: proc(raw: rawptr) {
	data := (^Stream_Test_Viewer)(raw)
	_ = router_dispatch_upgrade(data.router, data.req, data.socket)
	_ = net.shutdown(net.Any_Socket(data.socket), .Both)
}

stream_test_join :: proc(th: ^thread.Thread, peer: net.TCP_Socket) {
	if th == nil do return
	_ = net.shutdown(net.Any_Socket(peer), .Both)
	thread.join(th)
	thread.destroy(th)
}

stream_test_view_request :: proc(path, ticket: string) -> Request {
	headers := make([]contracts.HTTP_Header, 3)
	headers[0] = {"Upgrade", "websocket"}
	headers[1] = {"Connection", "Upgrade"}
	headers[2] = {"Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="}
	return Request{method = "GET", path = path, query = fmt.tprintf("ticket=%s", ticket), headers = headers}
}

stream_test_read_exact :: proc(peer: net.TCP_Socket, buffer: []byte) -> bool {
	offset := 0
	for offset < len(buffer) {
		n, err := net.recv_tcp(peer, buffer[offset:])
		if n <= 0 || err != nil do return false
		offset += n
	}
	return true
}

stream_test_frame :: proc(t: ^testing.T, peer: net.TCP_Socket) {
	// Server frames are not masked, unlike the Bridge-to-Hub input reader.
	header: [2]byte
	if !testing.expect(t, stream_test_read_exact(peer, header[:]) && header[0] == 0x82) do return
	if !testing.expect(t, header[1] < 126) do return
	data: [125]byte
	body := data[:header[1]]
	if !testing.expect(t, stream_test_read_exact(peer, body)) do return
	p, ok := contracts.stream_decode_piece(body)
	testing.expect(t, ok)
	testing.expect(t, string(p.data) == STREAM_TEST_MARKER, "the viewer received exactly the synthetic image")
}

@(test)
test_stream_hub_owner_view_lifecycle_and_private_transport :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	user_impl: sqlite.User_Repo_SQLite
	session_impl: sqlite.Session_Repo_SQLite
	user_repo := sqlite.new_user_repository(&user_impl, &conn)
	session_repo := sqlite.new_session_repository(&session_impl, &conn)
	clock := platform.Clock{now = proc(_: rawptr) -> string { return "2026-10-19T10:00:00Z" }}
	user_svc := users.new_user_service_basic(&user_repo, &clock, nil)
	for id in ([]string{"alice", "bob"}) {
		_, saved, _ := iface.user_save(&user_repo, domain.User{user_id = domain.User_ID(id), name = id, status = .Active})
		if !testing.expect(t, saved) do return
	}
	auth := auth_service.Auth_Service{users = &user_svc, clock = &clock, sessions = &session_repo,
		web = {enabled = true, ui_origin = "https://hub.example.test"}}
	alice, a_ok := auth_service.mint_session(&auth, "alice", ensure_user = false)
	bob, b_ok := auth_service.mint_session(&auth, "bob", ensure_user = false)
	if !testing.expect(t, a_ok && b_ok) do return
	fake_repo := iface.Agent_Repository{get_instance = proc(_: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
		owner, bridge, task, status := "alice", STREAM_TEST_BRIDGE, "task_other", "running"
		switch id {
		case STREAM_TEST_INSTANCE:
		case "inst_idle": task = ""
		case "inst_foreign_owner": owner = "bob"
		case "inst_foreign_bridge": bridge = "brg_other"
		case "inst_stopped": status = "stopped"
		case: return {}, false, {}
		}
		return {agent_instance_id = strings.clone(id), owner_user_id = domain.User_ID(strings.clone(owner)),
			bridge_id = strings.clone(bridge), current_task_id = strings.clone(task), runtime_status = strings.clone(status)}, true, {}
	}}
	agent := agents.Agent_Service{agents = &fake_repo}
	router := new_router()
	defer router_free(&router)
	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	registry: project.Bridge_Runtime_Registry
	defer project.bridge_runtime_registry_destroy(&registry)
	bus: events.User_Event_Bus
	h := Bridge_Handlers{auth = &auth, agents = &agent, bridge_runtime_registry = &registry, event_bus = &bus}
	defer stream_routing_destroy(&h)
	router_add_streams(&router, &h, &tickets)
	bridge, bridge_ok := stream_test_pair(t)
	if !bridge_ok do return
	defer stream_test_pair_close(bridge)
	hello, connected, _ := bridge_runtime.runtime_accept_hello(&registry, STREAM_TEST_BRIDGE, bridge_runtime.PROTOCOL_VERSION, "", owner_user_id = "alice")
	if !testing.expect(t, connected) do return
	project.bridge_runtime_registry_set_command_socket(&registry, STREAM_TEST_BRIDGE, bridge.hub, hello.generation)
	path :: STREAM_API_PATH + "/" + STREAM_TEST_ID
	view_path := path + "/view"
	owner_auth, owner_authenticated, _ := require_auth(&auth, secure_form_test_request("GET", path, "", "", alice, ""))
	other_auth, other_authenticated, _ := require_auth(&auth, secure_form_test_request("GET", path, "", "", bob, ""))
	if !testing.expect(t, owner_authenticated && other_authenticated) do return
	tickets.auth = &auth
	r := contracts.Stream_Registration{STREAM_TEST_ID, "bob", STREAM_TEST_BRIDGE, STREAM_TEST_INSTANCE,
		STREAM_TEST_TASK, {contracts.STREAM_SOURCE_BROWSER_TAB, "tab_1"}, "Example tab", stream_now_ms() + 60_000}
	reg := contracts.stream_encode_control(r)
	stream_bridge_control(&h, STREAM_TEST_BRIDGE, hello.generation, string(reg))
	testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), "unauthorized"))
	r.owner = "alice"
	for instance in ([]string{"inst_foreign_owner", "inst_foreign_bridge", "inst_unknown", "inst_stopped"}) {
		r.instance = instance
		reg = contracts.stream_encode_control(r)
		stream_bridge_control(&h, STREAM_TEST_BRIDGE, hello.generation, string(reg))
		testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), `"code":"unauthorized"`))
	}
	r.instance = "inst_idle"
	reg = contracts.stream_encode_control(r)
	stream_bridge_control(&h, STREAM_TEST_BRIDGE, hello.generation, string(reg))
	if !testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), `"accepted":true`)) do return
	ended := contracts.stream_encode_control(contracts.Stream_Ended{STREAM_TEST_ID, "stopped"})
	stream_bridge_control(&h, STREAM_TEST_BRIDGE, hello.generation, string(ended))
	r.instance = STREAM_TEST_INSTANCE
	reg = contracts.stream_encode_control(r)
	stream_bridge_control(&h, STREAM_TEST_BRIDGE, hello.generation, string(reg))
	if !testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), `"accepted":true`)) do return
	for principal in ([]string{alice, bob}) {
		got := router_dispatch(&router, secure_form_test_request("GET", path, "", "", principal, ""))
		testing.expect_value(t, got.status, 200 if principal == alice else 404)
	}
	unknown := router_dispatch(&router, secure_form_test_request("GET", STREAM_API_PATH + "/00000000000000000000000000000000", "", "", alice, ""))
	testing.expect_value(t, unknown.status, 404)

	forms_path := path + "/secure-forms"
	defer {
		for _, route in h.secure_forms.forms do secure_form_route_free(route)
		delete(h.secure_forms.forms)
	}
	now := stream_now_ms()
	for fixture in ([]struct { id, owner, bridge, instance: string, expired, unregistered, accepted: bool }{
		{"matching-public-form", "alice", STREAM_TEST_BRIDGE, STREAM_TEST_INSTANCE, false, false, false},
		{"wrong-instance", "alice", STREAM_TEST_BRIDGE, "inst_idle", false, false, false},
		{"wrong-owner", "bob", STREAM_TEST_BRIDGE, STREAM_TEST_INSTANCE, false, false, false},
		{"wrong-bridge", "alice", "brg_other", STREAM_TEST_INSTANCE, false, false, false},
		{"expired-form", "alice", STREAM_TEST_BRIDGE, STREAM_TEST_INSTANCE, true, false, false},
		{"unregistered-form", "alice", STREAM_TEST_BRIDGE, STREAM_TEST_INSTANCE, false, true, false},
		{"accepted-form", "alice", STREAM_TEST_BRIDGE, STREAM_TEST_INSTANCE, false, false, true},
	}) {
		request := contracts.Secure_Form_Request{request_id = fixture.id, owner = fixture.owner, bridge = fixture.bridge, instance = fixture.instance}
		deadline := now + 30_000
		testing.expect_value(t, secure_form_route_insert(&h.secure_forms, request, "{}", hello.generation, now, deadline, deadline + 60_000, 16), Secure_Form_Register_Result.Registered)
		if form := h.secure_forms.forms[fixture.id]; form != nil {
			form.registered = !fixture.unregistered
			if fixture.expired do form.deadline_ms = now
			if fixture.accepted do form.state = .Accepted
		}
	}
	form_views := router_dispatch(&router, secure_form_test_request("GET", forms_path, "", "", alice, ""))
	testing.expect_value(t, form_views.status, 200)
	testing.expect(t, strings.contains(form_views.body, "matching-public-form"))
	for excluded in ([]string{"wrong-instance", "wrong-owner", "wrong-bridge", "expired-form", "unregistered-form", "accepted-form"}) {
		testing.expect(t, !strings.contains(form_views.body, excluded))
	}
	testing.expect_value(t, header_value(form_views.headers, "Cache-Control"), "no-store")
	testing.expect_value(t, router_dispatch(&router, secure_form_test_request("GET", forms_path, "", "", bob, "")).status, 404)
	testing.expect_value(t, router_dispatch(&router, secure_form_test_request("GET", forms_path, "", "", "", "")).status, 401)
	testing.expect_value(t, router_dispatch(&router, secure_form_test_request("GET", forms_path, "", "", alice, "https://foreign.test")).status, 403)

	denied, denied_ok := stream_test_pair(t)
	if !denied_ok do return
	defer stream_test_pair_close(denied)
	user_ws_ticket_store_put(&tickets, "foreign", other_auth, 60)
	testing.expect(t, router_dispatch_upgrade(&router, stream_test_view_request(view_path, "foreign"), denied.hub))
	testing.expect(t, strings.contains(stream_test_http_header(denied.peer), "404 Not Found"))

	event, event_ok := stream_test_pair(t)
	if !event_ok do return
	defer stream_test_pair_close(event)
	sub := events.user_ws_add(&bus, "alice", event.hub)
	defer events.user_ws_remove(&bus, sub)
	baseline := secure_form_sql_changes(&conn)
	testing.expect(t, baseline >= 0)

	first, first_ok := stream_test_pair(t)
	if !first_ok do return
	defer stream_test_pair_close(first)
	user_ws_ticket_store_put(&tickets, "first", owner_auth, 60)
	first_req := Stream_Test_Viewer{&router, stream_test_view_request(view_path, "first"), first.hub}
	first_thread := thread.create_and_start_with_data(&first_req, stream_test_run_viewer, self_cleanup = false)
	defer { stream_test_join(first_thread, first.peer) }
	if !testing.expect(t, strings.contains(stream_test_http_header(first.peer), "101 Switching Protocols")) do return
	testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), "stream_attach"))

	wire := contracts.stream_encode_piece({STREAM_TEST_ID, 1, 0, 1, contracts.STREAM_MIME_JPEG, transmute([]byte)string(STREAM_TEST_MARKER)})
	testing.expect(t, bridge_ws_process_binary_frame(&h, STREAM_TEST_BRIDGE, hello.generation, string(wire)))
	stream_test_frame(t, first.peer)

	late, late_ok := stream_test_pair(t)
	if !late_ok do return
	defer stream_test_pair_close(late)
	user_ws_ticket_store_put(&tickets, "late", owner_auth, 60)
	late_req := Stream_Test_Viewer{&router, stream_test_view_request(view_path, "late"), late.hub}
	late_thread := thread.create_and_start_with_data(&late_req, stream_test_run_viewer, self_cleanup = false)
	defer { stream_test_join(late_thread, late.peer) }
	if !testing.expect(t, strings.contains(stream_test_http_header(late.peer), "101 Switching Protocols")) do return
	stream_test_frame(t, late.peer)
	_ = net.shutdown(net.Any_Socket(first.peer), .Both)
	thread.join(first_thread)
	thread.destroy(first_thread)
	first_thread = nil
	_ = net.set_option(bridge.peer, .Receive_Timeout, 100 * time.Millisecond)
	testing.expect(t, secure_form_test_read_text(bridge.peer) == "", "no second attach or early detach")
	_ = net.set_option(bridge.peer, .Receive_Timeout, time.Second)
	_ = net.shutdown(net.Any_Socket(late.peer), .Both)
	thread.join(late_thread)
	thread.destroy(late_thread)
	late_thread = nil
	testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), "stream_detach"))
	testing.expect_value(t, secure_form_sql_changes(&conn), baseline)
	_ = net.set_option(event.peer, .Receive_Timeout, 100 * time.Millisecond)
	event_buf: [128]byte
	event_bytes, _ := net.recv_tcp(event.peer, event_buf[:])
	testing.expect_value(t, event_bytes, 0)
	cached := router_dispatch(&router, secure_form_test_request("GET", path, "", "", alice, ""))
	testing.expect(t, !strings.contains(cached.body, STREAM_TEST_MARKER))
	testing.expect_value(t, header_value(cached.headers, "Cache-Control"), "no-store")

	disconnected, dc_ok := stream_test_pair(t)
	if !dc_ok do return
	defer stream_test_pair_close(disconnected)
	user_ws_ticket_store_put(&tickets, "disconnect", owner_auth, 60)
	dc_req := Stream_Test_Viewer{&router, stream_test_view_request(view_path, "disconnect"), disconnected.hub}
	dc_thread := thread.create_and_start_with_data(&dc_req, stream_test_run_viewer, self_cleanup = false)
	defer stream_test_join(dc_thread, disconnected.peer)
	if !testing.expect(t, strings.contains(stream_test_http_header(disconnected.peer), "101 Switching Protocols")) do return
	testing.expect(t, strings.contains(secure_form_test_read_text(bridge.peer), "stream_attach"))
	stream_test_frame(t, disconnected.peer)
	project.bridge_runtime_registry_mark_offline(&registry, STREAM_TEST_BRIDGE, hello.generation)
	stream_bridge_disconnected(&h, STREAM_TEST_BRIDGE, hello.generation)
	received, eof := net.recv_tcp(disconnected.peer, event_buf[:])
	testing.expect(t, received == 0 && eof == nil, "Bridge disconnect should end viewer socket")
	got := router_dispatch(&router, secure_form_test_request("GET", path, "", "", alice, ""))
	testing.expect_value(t, got.status, 404)

	replacement, replacement_ok := stream_test_pair(t)
	if !replacement_ok do return
	defer stream_test_pair_close(replacement)
	next, reconnected, _ := bridge_runtime.runtime_accept_hello(&registry, STREAM_TEST_BRIDGE, bridge_runtime.PROTOCOL_VERSION, "", owner_user_id = "alice")
	if !testing.expect(t, reconnected) do return
	project.bridge_runtime_registry_set_command_socket(&registry, STREAM_TEST_BRIDGE, replacement.hub, next.generation)
	stream_bridge_control(&h, STREAM_TEST_BRIDGE, next.generation, string(reg))
	testing.expect(t, strings.contains(secure_form_test_read_text(replacement.peer), `"accepted":true`))
	got = router_dispatch(&router, secure_form_test_request("GET", path, "", "", alice, ""))
	testing.expect_value(t, got.status, 200)
	// Test expiry without a sleep. No viewer is active after reconnect.
	h.streams.routes[STREAM_TEST_ID].info.expires = stream_now_ms()
	got = router_dispatch(&router, secure_form_test_request("GET", path, "", "", alice, ""))
	testing.expect_value(t, got.status, 404)
	expired, expired_ok := stream_test_pair(t)
	if !expired_ok do return
	defer stream_test_pair_close(expired)
	user_ws_ticket_store_put(&tickets, "expired_stream", owner_auth, 60)
	testing.expect(t, router_dispatch_upgrade(&router, stream_test_view_request(view_path, "expired_stream"), expired.hub))
	testing.expect(t, strings.contains(stream_test_http_header(expired.peer), "404 Not Found"))
}
