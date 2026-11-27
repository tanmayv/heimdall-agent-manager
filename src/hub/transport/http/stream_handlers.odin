package http

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import stream "odin_test:hub/service/stream"
import ws "odin_test:lib/ws"

STREAM_API_PATH :: "/api/v1/streams"

stream_now_ms :: proc() -> u64 {
	return u64(max(i64(0), time.to_unix_nanoseconds(time.now()) / 1_000_000))
}

stream_control_send :: proc(h: ^Bridge_Handlers, bridge: string, generation: int, msg: contracts.Stream_Control) -> bool {
	c := project.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge, generation)
	if c == nil do return false
	defer project.bridge_runtime_connection_release(h.bridge_runtime_registry, c)
	bytes := contracts.stream_encode_control(msg)
	defer delete(bytes)
	if len(bytes) == 0 do return false
	return write_ws_text_frame_locked(h, bridge, c.socket, string(bytes))
}

stream_placement_valid :: proc(h: ^Bridge_Handlers, c: ^project.Bridge_Runtime_Connection, r: contracts.Stream_Registration) -> bool {
	if c == nil || h.agents == nil || r.owner != c.owner_id || r.bridge != c.bridge_id do return false
	instance, found, err := iface.agent_get_instance(h.agents.agents, r.instance)
	if !found || err.code != .None do return false
	defer domain.agent_instance_destroy(&instance)
	return string(instance.owner_user_id) == c.owner_id && instance.bridge_id == c.bridge_id && instance.current_task_id == r.task
}

stream_bridge_control :: proc(h: ^Bridge_Handlers, bridge: string, generation: int, raw: string) {
	now := stream_now_ms()
	control, valid := contracts.stream_decode_control(raw, now)
	if !valid do return
	reg := &h.streams
	sync.lock(&h.stream_controls)
	defer sync.unlock(&h.stream_controls)
	c := project.bridge_runtime_connection_acquire(h.bridge_runtime_registry, bridge, generation)
	if c == nil do return
	defer project.bridge_runtime_connection_release(h.bridge_runtime_registry, c)
	// Registry-owned allocations outlive this reader and its request allocator.
	context.allocator = runtime.heap_allocator()
	#partial switch p in control {
	case contracts.Stream_Registration:
		code := "unauthorized"
		serial: u64
		if stream_placement_valid(h, c, p) {
			sync.lock(&reg.mu)
			code = stream.register(reg, p, generation, now)
			if code == "" do serial = reg.routes[p.stream_id].serial
			sync.unlock(&reg.mu)
		}
		sent := stream_control_send(h, bridge, generation, contracts.Stream_Register_Ack{p.stream_id, code == "", code})
		if code != "" do return
		sync.lock(&reg.mu)
		if r := reg.routes[p.stream_id]; r != nil && r.serial == serial {
			if sent {
				r.ready = true
			} else {
				stream.remove(reg, r)
			}
		}
		sync.unlock(&reg.mu)
	case contracts.Stream_Ended:
		sync.lock(&reg.mu)
		if r := reg.routes[p.stream_id]; r != nil && r.info.bridge == bridge && r.info.owner == c.owner_id && r.generation == generation {
			stream.remove(reg, r)
		}
		sync.unlock(&reg.mu)
	}
}

stream_bridge_disconnected :: proc(h: ^Bridge_Handlers, bridge: string, generation: int) {
	context.allocator = runtime.heap_allocator()
	sync.lock(&h.stream_controls)
	defer sync.unlock(&h.stream_controls)
	sync.lock(&h.streams.mu)
	defer sync.unlock(&h.streams.mu)
	stream.prune(&h.streams, stream_now_ms(), bridge, generation)
}

stream_expire_routes :: proc(h: ^Bridge_Handlers) {
	context.allocator = runtime.heap_allocator()
	sync.lock(&h.streams.mu)
	defer sync.unlock(&h.streams.mu)
	stream.prune(&h.streams, stream_now_ms())
}

stream_bridge_piece :: proc(h: ^Bridge_Handlers, bridge: string, generation: int, raw: []byte) {
	p, valid := contracts.stream_decode_piece(raw)
	if !valid do return
	context.allocator = runtime.heap_allocator()
	sync.lock(&h.streams.mu)
	defer sync.unlock(&h.streams.mu)
	if r := h.streams.routes[p.stream_id]; r != nil && r.info.bridge == bridge && r.generation == generation {
		stream.accept_piece(r, p, stream_now_ms())
	}
}

stream_routing_destroy :: proc(h: ^Bridge_Handlers) {
	context.allocator = runtime.heap_allocator()
	sync.lock(&h.streams.mu)
	defer sync.unlock(&h.streams.mu)
	stream.destroy(&h.streams)
}

stream_http_error :: proc(req: Request, code: domain.Error_Code, message: string) -> Response {
	return secure_form_no_store(respond_error(domain.domain_error(code, message), req.request_id))
}

stream_interactive_auth :: proc(auth: contracts.Auth_Context) -> bool {
	return contracts.is_interactive_browser_auth(auth)
}

// reg.mu is held. Registry generation takes no stream lock.
stream_live_for_owner :: proc(h: ^Bridge_Handlers, owner, id: string) -> ^stream.Route {
	r := stream.lookup(&h.streams, owner, id, stream_now_ms())
	if r == nil || project.bridge_runtime_registry_generation(h.bridge_runtime_registry, r.info.bridge) != r.generation do return nil
	return r
}

stream_metadata_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth, ok, refused := require_auth(h.auth, req)
	if !ok do return secure_form_no_store(refused)
	if !stream_interactive_auth(auth) do return stream_http_error(req, .Forbidden, "owner authentication required")
	id := path_part(req.path, 4)
	if !contracts.stream_id_valid(id) || req.path != strings.concatenate({STREAM_API_PATH, "/", id}, context.temp_allocator) {
		return stream_http_error(req, .Not_Found, "stream not found")
	}
	sync.lock(&h.streams.mu)
	r := stream_live_for_owner(h, auth.user_id, id)
	info: contracts.Stream_Registration
	if r != nil do info = stream.clone_info(r.info, context.temp_allocator)
	sync.unlock(&h.streams.mu)
	if r == nil do return stream_http_error(req, .Not_Found, "stream not found")
	return secure_form_no_store(respond_success_typed(info, req.request_id, ""))
}

stream_view_leave :: proc(h: ^Bridge_Handlers, owner, id: string, serial: u64) {
	sync.lock(&h.stream_controls)
	defer sync.unlock(&h.stream_controls)
	sync.lock(&h.streams.mu)
	r := h.streams.routes[id]
	if r == nil || r.serial != serial || r.info.owner != owner {
		sync.unlock(&h.streams.mu)
		return
	}
	r.viewers -= 1
	if r.viewers != 0 {
		sync.unlock(&h.streams.mu)
		return
	}
	bridge := strings.clone(r.info.bridge)
	generation := r.generation
	r.count = 0
	clear(&r.partial)
	sync.unlock(&h.streams.mu)
	defer delete(bridge)
	_ = stream_control_send(h, bridge, generation, contracts.Stream_Detach{id})
}

// One socket handler owns all writes to its viewer. Bridge ingestion never
// waits on that socket. The existing reader retains any partial inbound frame
// across receive deadlines; application messages are rejected (watch only).
stream_view_handler :: proc(ctx: rawptr, req: Request, socket: net.TCP_Socket) {
	h := (^Bridge_Handlers)(ctx)
	ticket := query_value(req.query, "ticket")
	if ticket == "" || h.stream_tickets == nil {
		write_stream_error(socket, stream_http_error(req, .Unauthenticated, "websocket ticket required"))
		return
	}
	auth, ok := user_ws_ticket_store_consume(h.stream_tickets, ticket)
	if !ok || !stream_interactive_auth(auth) {
		write_stream_error(socket, stream_http_error(req, .Unauthenticated, "invalid websocket ticket"))
		return
	}
	origin := header_value(req.headers, "Origin")
	if origin != "" && (h.auth == nil || !csrf_origin_equal(origin, h.auth.web.ui_origin)) {
		write_stream_error(socket, stream_http_error(req, .Forbidden, "same-origin request required"))
		return
	}
	id := path_part(req.path, 4)
	if !contracts.stream_id_valid(id) || req.path != strings.concatenate({STREAM_API_PATH, "/", id, "/view"}, context.temp_allocator) {
		write_stream_error(socket, stream_http_error(req, .Not_Found, "stream not found"))
		return
	}
	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" {
		write_stream_error(socket, stream_http_error(req, .Validation_Failed, "missing websocket key"))
		return
	}
	sync.lock(&h.stream_controls)
	sync.lock(&h.streams.mu)
	r := stream_live_for_owner(h, auth.user_id, id)
	if r == nil || r.viewers >= stream.MAX_VIEWERS_PER_STREAM {
		sync.unlock(&h.streams.mu)
		sync.unlock(&h.stream_controls)
		if r == nil {
			write_stream_error(socket, stream_http_error(req, .Not_Found, "stream not found"))
		} else {
			write_stream_error(socket, stream_http_error(req, .Conflict, "stream viewer limit reached"))
		}
		return
	}
	r.viewers += 1
	first, serial := r.viewers == 1, r.serial
	request_allocator := context.allocator
	bridge, generation := strings.clone(r.info.bridge), r.generation
	defer delete(bridge, request_allocator)
	sync.unlock(&h.streams.mu)
	attached := !first || stream_control_send(h, bridge, generation, contracts.Stream_Attach{id})
	if !attached {
		sync.lock(&h.streams.mu)
		if existing := h.streams.routes[id]; existing != nil && existing.serial == serial {
			existing.viewers -= 1
			existing.count = 0
			clear(&existing.partial)
		}
		sync.unlock(&h.streams.mu)
	}
	sync.unlock(&h.stream_controls)
	if !attached {
		write_stream_error(socket, stream_http_error(req, .Conflict, "stream is unavailable"))
		return
	}
	defer stream_view_leave(h, auth.user_id, id, serial)
	if !write_user_ws_upgrade_response(socket, user_ws_accept_key(key)) do return
	// The HTTP request arena cannot reclaim individual frames while the upgrade lives.
	context.allocator = runtime.heap_allocator()
	reader := bridge_ws_reader_make(socket)
	reader.max_buffer_bytes = 4096 // Control frames only on this watch-only socket.
	defer bridge_ws_reader_destroy(&reader)
	guard := stream_auth_guard_make(h.auth, auth)
	version: u64
	for {
		if !stream_auth_still_valid(&guard) do return
		sync.lock(&h.streams.mu)
		r = stream_live_for_owner(h, auth.user_id, id)
		if r == nil || r.serial != serial {
			sync.unlock(&h.streams.mu)
			return
		}
		jpeg, seq, current := stream.snapshot(r, version)
		sync.unlock(&h.streams.mu)
		if jpeg != nil {
			sent := stream_view_write(socket, id, seq, jpeg)
			delete(jpeg)
			if !sent do return
			version = current
		}
		message, read, reason := bridge_ws_read_frame(&reader, 100 * time.Millisecond)
		if read {
			delete(message)
			return
		}
		if reason != .Read_Deadline do return
	}
}

stream_view_write :: proc(socket: net.TCP_Socket, id: string, seq: u64, jpeg: []byte) -> bool {
	size :: contracts.STREAM_MAX_PIECE_BYTES
	count := (len(jpeg) + size - 1) / size
	started := time.tick_now()
	for i in 0..<count {
		remaining := time.Second - time.tick_since(started)
		if remaining <= 0 do return false
		wire := contracts.stream_encode_piece({id, seq, u16(i), u16(count), contracts.STREAM_MIME_JPEG, jpeg[i*size:min((i+1)*size,len(jpeg))]})
		_, result := ws.write_server_opcode_counted(socket, 0x2, string(wire), false, remaining)
		delete(wire)
		if result != .Ok do return false
	}
	return true
}
