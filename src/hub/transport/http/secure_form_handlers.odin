package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import events "odin_test:hub/service/events"
import project "odin_test:hub/service/project"

// Hub routing state holds public registration and status only. It has no
// repository interface and cannot retain an answer or directory proof.
Secure_Form_Routing :: struct {
	mu: sync.Mutex,
	forms: map[string]^Secure_Form_Route,
}

Secure_Form_Route :: struct {
	owner, bridge, conversation, request_id, registration: string,
	generation: int,
	deadline_ms, forget_ms: u64,
	state: contracts.Secure_Form_Hub_State,
	code: Maybe(contracts.Secure_Form_Exit),
	in_flight, registered: bool,
}

secure_form_route_finish :: proc(route: ^Secure_Form_Route, code: contracts.Secure_Form_Exit) {
	if !contracts.secure_form_hub_transition(route.state, .Final) do return
	route.state = .Final
	route.code = code
}

secure_form_route_free :: proc(route: ^Secure_Form_Route) {
	heap := runtime.heap_allocator()
	delete(route.owner, heap)
	delete(route.bridge, heap)
	delete(route.conversation, heap)
	delete(route.request_id, heap)
	delete(route.registration, heap)
	free(route, heap)
}

// The routing mutex must be held for lookup, traversal and transitions.
secure_form_route_sweep :: proc(routing: ^Secure_Form_Routing, now_ms: u64) {
	expired: [dynamic]^Secure_Form_Route
	defer delete(expired)
	for _, route in routing.forms {
		if !route.in_flight && now_ms >= route.forget_ms {
			append(&expired, route)
		} else if route.state == .Pending && now_ms >= route.deadline_ms {
			secure_form_route_finish(route, .Response_Expired)
		}
	}
	for route in expired {
		delete_key(&routing.forms, route.request_id)
		secure_form_route_free(route)
	}
}

Secure_Form_Register_Result :: enum { Registered, Duplicate, Refused }

secure_form_route_insert :: proc(routing: ^Secure_Form_Routing, request: contracts.Secure_Form_Request,
	raw_registration: string, generation: int, now_ms, deadline_ms, forget_ms: u64,
	max_records: int) -> Secure_Form_Register_Result {
	sync.lock(&routing.mu)
	defer sync.unlock(&routing.mu)
	secure_form_route_sweep(routing, now_ms)
	if deadline_ms <= now_ms || forget_ms < deadline_ms do return .Refused
	if existing, found := routing.forms[request.request_id]; found {
		if existing.bridge == request.bridge && existing.generation == generation &&
			existing.registration == raw_registration {
			return .Duplicate
		}
		return .Refused
	}
	if len(routing.forms) >= max_records do return .Refused
	heap := runtime.heap_allocator()
	if routing.forms == nil do routing.forms = make(map[string]^Secure_Form_Route, heap)
	route := new(Secure_Form_Route, heap)
	route^ = {
		owner = strings.clone(request.owner, heap),
		bridge = strings.clone(request.bridge, heap),
		conversation = strings.clone(request.conversation, heap),
		request_id = strings.clone(request.request_id, heap),
		registration = strings.clone(raw_registration, heap),
		generation = generation,
		deadline_ms = deadline_ms,
		forget_ms = forget_ms,
	}
	routing.forms[route.request_id] = route
	return .Registered
}

Secure_Form_Reserve_Result :: enum { Reserved, Missing, Stale, Conflict }

secure_form_route_lookup :: proc(routing: ^Secure_Form_Routing, owner, request_id: string) -> ^Secure_Form_Route {
	route := routing.forms[request_id]
	if route == nil || route.owner != owner do return nil
	return route
}

// Keep the routing lock through the nonblocking transport admission, so a
// rejected enqueue can roll back before a second submit observes forwarding.
secure_form_route_reserve :: proc(routing: ^Secure_Form_Routing, owner, request_id: string,
	generation: int, now_ms: u64) -> (^Secure_Form_Route, Secure_Form_Reserve_Result) {
	route := secure_form_route_lookup(routing, owner, request_id)
	if route == nil do return nil, .Missing
	if route.generation != generation do return nil, .Stale
	if now_ms >= route.deadline_ms || route.in_flight ||
		!contracts.secure_form_hub_transition(route.state, .Forwarding) {
		return nil, .Conflict
	}
	route.state = .Forwarding
	route.in_flight = true
	return route, .Reserved
}

secure_form_route_unreserve :: proc(route: ^Secure_Form_Route) {
	route.in_flight = false
	route.state = .Pending
}

secure_form_route_apply_ack :: proc(route: ^Secure_Form_Route, ack: contracts.Secure_Form_Ack) -> bool {
	switch ack.state {
	case "accepted":
		if !contracts.secure_form_hub_transition(route.state, .Accepted) do return false
		route.state = .Accepted
		return true
	case "final":
		code, has_code := ack.code.?
		if !has_code || !contracts.secure_form_hub_transition(route.state, .Final) do return false
		if route.state == .Pending && code != .Cancelled && code != .Response_Expired && code != .Not_Delivered do return false
		secure_form_route_finish(route, code)
		return true
	}
	return false
}

SECURE_FORM_RECORD_LIMIT :: 128
SECURE_FORM_REGISTRATION_WIRE_LIMIT :: 6 * contracts.SECURE_FORM_SCHEMA_MAX + 512 * 1024 + 128

secure_form_now_ms :: proc() -> u64 {
	return u64(max(i64(0), time.to_unix_nanoseconds(time.now()) / 1_000_000))
}

secure_form_state_name :: proc(s: contracts.Secure_Form_Hub_State) -> string {
	switch s {
	case .Pending: return "pending"
	case .Forwarding: return "forwarding"
	case .Accepted: return "accepted"
	case .Final: return "final"
	}
	return "final"
}

secure_form_ack_snapshot :: proc(route: ^Secure_Form_Route) -> contracts.Secure_Form_Ack {
	return {1, route.request_id, fmt.tprintf("%d", route.generation), secure_form_state_name(route.state), route.code}
}

secure_form_publish :: proc(h: ^Bridge_Handlers, owner, conversation, id: string) {
	data, err := json.marshal(struct {type, conversation_id, request_id: string}{
		contracts.SECURE_FORM_CHANGED_EVENT, conversation, id,
	})
	if err == nil do events.publish_owned(h.event_bus, owner, string(data))
}

secure_form_registration_placement :: proc(h: ^Bridge_Handlers, c: ^project.Bridge_Runtime_Connection,
	request: contracts.Secure_Form_Request) -> bool {
	if c == nil || h.agents == nil || h.content == nil || request.bridge != c.bridge_id || request.owner != c.owner_id do return false
	generation, ok := contracts.secure_form_uint(request.generation)
	if !ok || generation != u64(c.generation) do return false
	instance, found, err := iface.agent_get_instance(h.agents.agents, request.instance)
	if !found || err.code != .None do return false
	defer domain.agent_instance_destroy(&instance)
	if string(instance.owner_user_id) != c.owner_id || instance.bridge_id != c.bridge_id ||
		instance.conversation_id != request.conversation || instance.current_task_id != request.task {
		return false
	}
	conversation, exists, conv_err := iface.content_get_conversation(h.content.content, request.conversation)
	if !exists || conv_err.code != .None do return false
	return string(conversation.owner_user_id) == c.owner_id && conversation.agent_instance_id == request.instance
}

secure_form_bridge_register :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, client: net.TCP_Socket, raw: string) {
	payload, wrapped := contracts.secure_form_wire_payload(raw, contracts.SECURE_FORM_REGISTER_FRAME, SECURE_FORM_REGISTRATION_WIRE_LIMIT, context.allocator)
	if !wrapped do return
	registration, valid := contracts.secure_form_parse_registration(payload, context.allocator)
	if !valid do return
	r := registration.request
	current, live := bridge_runtime_state_enter(h, bridge_id, generation)
	if !live do return
	result := Secure_Form_Register_Result.Refused
	now := secure_form_now_ms()
	deadline, _ := contracts.secure_form_uint(r.deadline)
	if deadline > now && deadline - now <= contracts.SECURE_FORM_WAIT_MAX_SECONDS * 1000 &&
		secure_form_registration_placement(h, current, r) {
		forget := deadline + contracts.SECURE_FORM_RETENTION_MS +
			contracts.SECURE_FORM_EXECUTION_MAX_SECONDS * 1000 + contracts.SECURE_FORM_TOMBSTONE_GRACE_MS
		// A typed re-encode fixes object key order for idempotency while preserving
		// the exact decoded schema string, including non-ASCII bytes.
		canonical, err := json.marshal(registration)
		if err == nil {
			defer delete(canonical)
			result = secure_form_route_insert(&h.secure_forms, r, string(canonical), generation, now, deadline, forget, SECURE_FORM_RECORD_LIMIT)
		}
	}
	bridge_runtime_state_leave(h, current)

	ack := contracts.Secure_Form_Ack{1, r.request_id, r.generation, "pending", nil}
	if result == .Refused {
		ack.state = "final"
		ack.code = .Unauthorized
	}
	frame := contracts.Secure_Form_Wire_Frame(contracts.Secure_Form_Ack){contracts.SECURE_FORM_REGISTER_ACK_FRAME, 1, ack}
	bytes, err := json.marshal(frame)
	if err != nil do return
	if result == .Refused {
		_ = write_ws_text_frame_locked(h, bridge_id, client, string(bytes))
		return
	}
	if !write_ws_text_frame_locked(h, bridge_id, client, string(bytes)) do return
	sync.lock(&h.secure_forms.mu)
	route := secure_form_route_lookup(&h.secure_forms, r.owner, r.request_id)
	announce := route != nil && route.generation == generation && !route.registered
	if announce do route.registered = true
	sync.unlock(&h.secure_forms.mu)
	if announce do secure_form_publish(h, r.owner, r.conversation, r.request_id)
}

secure_form_bridge_status :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, kind, raw: string) {
	payload, wrapped := contracts.secure_form_wire_payload(raw, kind, 1200, context.allocator)
	if !wrapped do return
	ack: contracts.Secure_Form_Ack
	if kind == contracts.SECURE_FORM_CANCEL_FRAME {
		ref, valid := contracts.secure_form_parse_reference(payload, context.allocator)
		if !valid do return
		// The Bridge sends this frame only when local cancellation won.
		ack = {1, ref.request_id, ref.generation, "final", .Cancelled}
	} else {
		parsed, valid := contracts.secure_form_parse_ack(payload, context.allocator)
		if !valid do return
		ack = parsed
	}
	wire_generation, _ := contracts.secure_form_uint(ack.generation)
	if wire_generation != u64(generation) do return

	current, live := bridge_runtime_state_enter(h, bridge_id, generation)
	if !live || current == nil do return
	routing := &h.secure_forms
	sync.lock(&routing.mu)
	route := secure_form_route_lookup(routing, current.owner_id, ack.request_id)
	owner, conversation, id: string
	if route != nil && route.generation == generation && route.bridge == bridge_id && secure_form_route_apply_ack(route, ack) {
		owner = strings.clone(route.owner)
		conversation = strings.clone(route.conversation)
		id = strings.clone(route.request_id)
	}
	sync.unlock(&routing.mu)
	bridge_runtime_state_leave(h, current)
	if id != "" do secure_form_publish(h, owner, conversation, id)
}

secure_form_route_refresh :: proc(h: ^Bridge_Handlers, route: ^Secure_Form_Route, now: u64) {
	if route.state == .Final do return
	if project.bridge_runtime_registry_generation(h.bridge_runtime_registry, route.bridge) != route.generation {
		if route.in_flight do return
		secure_form_route_finish(route, .Not_Delivered if route.state == .Pending else .Unknown)
	} else if route.state == .Pending && now >= route.deadline_ms {
		secure_form_route_finish(route, .Response_Expired)
	}
}

Secure_Form_Write_Context :: struct {
	handlers: ^Bridge_Handlers,
	route: ^Secure_Form_Route,
	prior_answer_possible: bool,
}

secure_form_write_complete :: proc(raw: rawptr, result: bridge_runtime.Command_Write_Result) {
	job := (^Secure_Form_Write_Context)(raw)
	defer free(job, runtime.heap_allocator())
	routing := &job.handlers.secure_forms
	sync.lock(&routing.mu)
	route := job.route
	route.in_flight = false
	before := route.state
	// An authoritative acknowledgement may have raced the write completion.
	if route.state == .Forwarding && result != .Ok {
		secure_form_route_finish(route, .Unknown if result == .Send_Failed || job.prior_answer_possible else .Not_Delivered)
	} else {
		secure_form_route_refresh(job.handlers, route, secure_form_now_ms())
	}
	owner, conversation, id: string
	if route.state != before {
		owner = strings.clone(route.owner)
		conversation = strings.clone(route.conversation)
		id = strings.clone(route.request_id)
	}
	sync.unlock(&routing.mu)
	if id != "" {
		defer delete(owner)
		defer delete(conversation)
		defer delete(id)
		secure_form_publish(job.handlers, owner, conversation, id)
	}
}

secure_form_no_store :: proc(response: Response) -> Response {
	out := response
	headers := make([dynamic]contracts.HTTP_Header, 0, len(out.headers) + 1)
	append(&headers, ..out.headers)
	append(&headers, contracts.HTTP_Header{"Cache-Control", "no-store"})
	out.headers = headers[:]
	return out
}

secure_form_http_error :: proc(req: Request, code: domain.Error_Code, message: string, status := 0) -> Response {
	out := secure_form_no_store(respond_error(domain.domain_error(code, message), req.request_id))
	if status != 0 do out.status = status
	return out
}

Secure_Form_Status_View :: struct {
	registration: json.Value,
	status: contracts.Secure_Form_Ack,
}

secure_form_status_view :: proc(route: ^Secure_Form_Route) -> Secure_Form_Status_View {
	registration, _ := json.parse_string(route.registration, allocator = context.allocator)
	return {registration, secure_form_ack_snapshot(route)}
}

secure_form_http_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth, ok, refused := require_auth(h.auth, req)
	if !ok do return secure_form_no_store(refused)
	if !contracts.is_interactive_browser_auth(auth) && auth.kind != .OIDC {
		return secure_form_http_error(req, .Forbidden, "owner authentication required")
	}
	origin := header_value(req.headers, "Origin")
	if (req.method == "POST" || origin != "") && (origin == "" || h.auth.web.ui_origin == "" || !csrf_origin_equal(origin, h.auth.web.ui_origin)) {
		return secure_form_http_error(req, .Forbidden, "same-origin request required")
	}
	csrf_ok, _ := csrf_decide(req.method, req.headers, h.auth.web.ui_origin, false)
	if !csrf_ok do return secure_form_http_error(req, .Forbidden, "same-origin request required")

	path := strings.split(req.path, "/", context.allocator)
	now := secure_form_now_ms()
	routing := &h.secure_forms
	if req.method == "GET" {
		sync.lock(&routing.mu)
		defer sync.unlock(&routing.mu)
		secure_form_route_sweep(routing, now)
		if len(path) == 4 {
			conversation := query_value(req.query, "conversation_id")
			if conversation == "" do return secure_form_http_error(req, .Validation_Failed, "conversation_id is required")
			items := make([dynamic]Secure_Form_Status_View)
			for _, route in routing.forms {
				if !route.registered || route.owner != auth.user_id || route.conversation != conversation do continue
				secure_form_route_refresh(h, route, now)
				if route.state == .Pending do append(&items, secure_form_status_view(route))
			}
			return secure_form_no_store(respond_success_typed(items[:], req.request_id, ""))
		}
		route := secure_form_route_lookup(routing, auth.user_id, path[4])
		if route == nil || !route.registered do return secure_form_http_error(req, .Not_Found, "secure form not found")
		secure_form_route_refresh(h, route, now)
		return secure_form_no_store(respond_success_typed(secure_form_status_view(route), req.request_id, ""))
	}
	if len(path) != 6 do return secure_form_http_error(req, .Not_Found, "secure form not found")
	return secure_form_http_decide(h, req, auth.user_id, path[4], path[5], now)
}

secure_form_http_decide :: proc(h: ^Bridge_Handlers, req: Request, owner, id, action: string, now: u64) -> Response {
	ref: contracts.Secure_Form_Reference
	type: string
	if action == "submit" {
		parsed, valid := contracts.secure_form_parse_submission(req.body, context.allocator)
		if !valid do return secure_form_http_error(req, .Validation_Failed, "invalid secure form submission")
		ref = {1, parsed.request_id, parsed.generation}
		type = contracts.SECURE_FORM_ANSWER_FRAME
	} else {
		parsed, valid := contracts.secure_form_parse_reference(req.body, context.allocator)
		if !valid do return secure_form_http_error(req, .Validation_Failed, "invalid secure form reference")
		ref = parsed
		type = contracts.SECURE_FORM_DECLINE_FRAME
	}
	if ref.request_id != id do return secure_form_http_error(req, .Validation_Failed, "secure form reference mismatch")

	// Preserve validated endpoint payloads verbatim. The Hub does not derive
	// secrets or change the signed bytes recovered by the recipient.
	wire := strings.concatenate({`{"type":"`, type, `","protocol_version":1,"payload":`, req.body, "}"})
	defer delete(wire)
	generation, _ := contracts.secure_form_uint(ref.generation)

	routing := &h.secure_forms
	sync.lock(&routing.mu)
	defer sync.unlock(&routing.mu)
	secure_form_route_sweep(routing, now)
	route := secure_form_route_lookup(routing, owner, id)
	if route == nil || !route.registered do return secure_form_http_error(req, .Not_Found, "secure form not found")
	if generation != u64(route.generation) ||
		project.bridge_runtime_registry_generation(h.bridge_runtime_registry, route.bridge) != route.generation {
		return secure_form_http_error(req, .Conflict, "secure form connection changed")
	}
	old_state := route.state
	if action == "decline" && route.state == .Forwarding && !route.in_flight && now < route.deadline_ms {
		// A forwarded answer may already be consumed. Only the live Bridge
		// acknowledgement can resolve which decision won.
		route.in_flight = true
	} else {
		_, reserved := secure_form_route_reserve(routing, owner, id, route.generation, now)
		if reserved != .Reserved do return secure_form_http_error(req, .Conflict, "secure form is no longer pending")
	}
	job := new(Secure_Form_Write_Context, runtime.heap_allocator())
	job^ = {h, route, old_state == .Forwarding}
	dispatched := bridge_runtime.secure_form_dispatch(h.bridge_runtime_registry, route.bridge, route.generation, wire, secure_form_write_complete, job)
	if dispatched != .Queued {
		free(job, runtime.heap_allocator())
		secure_form_route_unreserve(route)
		route.state = old_state
		if dispatched == .Stale do return secure_form_http_error(req, .Conflict, "secure form connection changed")
		return secure_form_http_error(req, .Bridge_Offline, "secure form writer is unavailable", 503)
	}
	return secure_form_no_store(respond_success_typed(secure_form_ack_snapshot(route), req.request_id, "", 202))
}

// Call after the bridge runtime registry has drained detached write references.
secure_form_routing_destroy :: proc(routing: ^Secure_Form_Routing) {
	for _, route in routing.forms do secure_form_route_free(route)
	delete(routing.forms)
	routing.forms = nil
}
