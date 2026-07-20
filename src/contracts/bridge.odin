package contracts

// Federation v2 Phase 1 shared seam contracts.
//
// The daemon <-> bridge loopback API is intentionally separate from the
// bridge <-> bridge WebSocket frame API. Loopback requests name daemon ids and
// opaque payload bytes only; remote addresses, peer credentials, and WebSocket
// connection state are bridge-owned implementation details and must not appear
// in these loopback structs.

Daemon_ID :: distinct string
Bridge_Stream_ID :: distinct string
Bridge_Frame_ID :: distinct string

BRIDGE_LOOPBACK_CONTRACT_VERSION :: 1
BRIDGE_WS_FRAME_VERSION :: 1
BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS :: 5000
BRIDGE_DEFAULT_ENVELOPE_TTL :: 1 // Phase 1 is direct-only; Phase 2 may raise this for relays.

ROUTE_BRIDGE_SEND :: "/bridge/send"
ROUTE_BRIDGE_REQUEST :: "/bridge/request"
ROUTE_BRIDGE_REACHABLE :: "/bridge/reachable"
ROUTE_BRIDGE_HEALTH :: "/bridge/health"
ROUTE_BRIDGE_WS :: "/bridge-ws"

ROUTE_FEDERATION_INBOX :: "/federation/inbox"
ROUTE_FEDERATION_CALLBACK :: "/federation/callback"
ROUTE_FEDERATION_START :: "/federation/start"
ROUTE_FEDERATION_STOP :: "/federation/stop"
ROUTE_FEDERATION_REACHABILITY :: "/federation/reachability"
ROUTE_FEDERATION_PEERS :: "/federation/peers"
ROUTE_FEDERATION_ARTIFACTS_PREFIX :: "/federation/artifacts"
ROUTE_FEDERATION_TASKS_PREFIX :: "/federation/tasks"
ROUTE_FEDERATION_TASK_CHAINS_PREFIX :: "/federation/task-chains"

BRIDGE_LOOPBACK_AUTH_HEADER :: "Authorization"
BRIDGE_WS_AUTH_HEADER :: "Authorization"
BRIDGE_AUTH_BEARER_PREFIX :: "Bearer "
BRIDGE_SOURCE_DAEMON_HEADER :: "X-Heimdall-Source-Daemon"
BRIDGE_DEST_DAEMON_HEADER :: "X-Heimdall-Dest-Daemon"
BRIDGE_IDEMPOTENCY_HEADER :: "Idempotency-Key"

BRIDGE_HTTP_METHOD_GET :: "GET"
BRIDGE_HTTP_METHOD_POST :: "POST"

Bridge_Binary :: enum {
	Daemon,
	Bridge,
}

// Shared route coverage registry for Phase 1 bridge surfaces. Implementations
// should route through these constants/procs instead of duplicating endpoint
// strings in each binary. Unsupported routes must return explicit 404/501-style
// errors instead of falling through to peer transport.
bridge_route_supported :: proc(binary: Bridge_Binary, method, route: string) -> bool {
	switch binary {
	case .Bridge:
		return bridge_loopback_route_supported(method, route) || bridge_ws_route_supported(method, route)
	case .Daemon:
		return bridge_daemon_route_supported(method, route)
	}
	return false
}

bridge_loopback_route_supported :: proc(method, route: string) -> bool {
	switch route {
	case ROUTE_BRIDGE_HEALTH:
		return method == BRIDGE_HTTP_METHOD_GET || method == BRIDGE_HTTP_METHOD_POST
	case ROUTE_BRIDGE_SEND, ROUTE_BRIDGE_REQUEST:
		return method == BRIDGE_HTTP_METHOD_POST
	case ROUTE_BRIDGE_REACHABLE:
		return method == BRIDGE_HTTP_METHOD_GET || method == BRIDGE_HTTP_METHOD_POST
	}
	return false
}

bridge_ws_route_supported :: proc(method, route: string) -> bool {
	return method == BRIDGE_HTTP_METHOD_GET && route == ROUTE_BRIDGE_WS
}

bridge_daemon_route_supported :: proc(method, route: string) -> bool {
	switch route {
	case ROUTE_FEDERATION_INBOX,
	     ROUTE_FEDERATION_CALLBACK,
	     ROUTE_FEDERATION_START,
	     ROUTE_FEDERATION_STOP,
	     ROUTE_FEDERATION_REACHABILITY:
		return method == BRIDGE_HTTP_METHOD_POST
	case ROUTE_FEDERATION_PEERS:
		return method == BRIDGE_HTTP_METHOD_GET
	}
	return false
}

// Route kinds are stable bridge-facing names, not peer URLs or daemon REST
// credentials. The bridge maps them to local daemon federation routes while
// treating payload bytes as opaque business data.
BRIDGE_SEND_ROUTE_FEDERATION_INBOX :: "federation_inbox"
BRIDGE_SEND_ROUTE_FEDERATION_CALLBACK :: "federation_callback"

// Business payload kinds that already flow through /federation/inbox or
// /federation/callback. These are copied into contracts so bridge code need not
// import daemon internals; bridges must not inspect the payload body itself.
BRIDGE_PAYLOAD_KIND_NOTIFICATION :: "notification"
BRIDGE_PAYLOAD_KIND_INBOX_MESSAGE :: "inbox_message"
BRIDGE_PAYLOAD_KIND_READ_RECEIPT :: "read_receipt"
BRIDGE_PAYLOAD_KIND_TASK_COMMENT :: "comment"
BRIDGE_PAYLOAD_KIND_TASK_VOTE :: "vote"
BRIDGE_PAYLOAD_KIND_TASK_STATUS :: "status"

Bridge_Send_Request :: struct {
	contract_version: int,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	route_kind: string,
	idempotency_key: string,
	payload: []byte, // Opaque to bridge business logic.
	created_unix_ms: i64,
}

Bridge_Send_Acceptance :: enum {
	Accepted_Queued,       // Accepted by the local bridge for async transport; not business success.
	Duplicate_Queued,      // Same idempotency key is already accepted/queued.
	Rejected,              // Contract/auth/validation failure; not queued.
	Destination_Unreachable,
	Backpressure,
}

BRIDGE_SEND_ACCEPTANCE_ACCEPTED_QUEUED :: "accepted_queued"
BRIDGE_SEND_ACCEPTANCE_DUPLICATE_QUEUED :: "duplicate_queued"
BRIDGE_SEND_ACCEPTANCE_REJECTED :: "rejected"
BRIDGE_SEND_ACCEPTANCE_DESTINATION_UNREACHABLE :: "destination_unreachable"
BRIDGE_SEND_ACCEPTANCE_BACKPRESSURE :: "backpressure"

Bridge_Send_Response :: struct {
	ok: bool,
	contract_version: int,
	acceptance: Bridge_Send_Acceptance,
	bridge_message_id: string,
	idempotency_key: string,
	error_code: string,
	message: string,
}

Bridge_Request :: struct {
	contract_version: int,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	method: string,
	path: string,
	idempotency_key: string,
	body: []byte, // Opaque proxied HTTP body.
	timeout_ms: int,
}

Bridge_Request_Response :: struct {
	ok: bool,
	contract_version: int,
	result_kind: string, // BRIDGE_RESULT_DESTINATION_DAEMON_HTTP_RESPONSE on success; BRIDGE_RESULT_UNSUPPORTED_SCAFFOLD for local scaffold 501s.
	status_code: int,
	status_text: string,
	body: []byte, // Opaque destination-daemon response body.
	error_code: string,
	message: string,
}

BRIDGE_RESULT_BRIDGE_ACCEPTED_QUEUED :: "bridge_accepted_queued"
BRIDGE_RESULT_DESTINATION_DAEMON_HTTP_RESPONSE :: "destination_daemon_http_response"
BRIDGE_RESULT_END_TO_END_CALLBACK :: "end_to_end_callback"
BRIDGE_RESULT_TRANSPORT_ERROR :: "transport_error"
BRIDGE_RESULT_UNSUPPORTED_SCAFFOLD :: "unsupported_scaffold"
BRIDGE_ERROR_NOT_IMPLEMENTED :: "not_implemented"
BRIDGE_ERROR_UNSUPPORTED_ROUTE :: "unsupported_route"

Bridge_Reachability_Kind :: enum {
	Direct,
	Relayed,
}

Bridge_Reachability_Status :: enum {
	Linked,
	Unreachable,
}

BRIDGE_REACHABILITY_STATUS_LINKED :: "linked"
BRIDGE_REACHABILITY_STATUS_UNREACHABLE :: "unreachable"

Bridge_Reachable_Daemon :: struct {
	daemon_id: Daemon_ID,
	reach: Bridge_Reachability_Kind,
	next_hop_daemon_id: Daemon_ID,
	hops: int,
	status: Bridge_Reachability_Status,
	via: []Daemon_ID,
	last_seen_unix_ms: i64,
}

Bridge_Reachable_Request :: struct {
	contract_version: int,
	self_daemon_id: Daemon_ID,
}

Bridge_Reachable_Response :: struct {
	ok: bool,
	contract_version: int,
	self_daemon_id: Daemon_ID,
	reachable: []Bridge_Reachable_Daemon,
	message: string,
}

Bridge_Health_Request :: struct {
	contract_version: int,
	self_daemon_id: Daemon_ID,
	daemon_protocol_version: int,
}

Bridge_Health_Response :: struct {
	ok: bool,
	contract_version: int,
	ws_frame_version: int,
	self_daemon_id: Daemon_ID,
	bridge_id: string,
	message: string,
}

// Bridge -> daemon reachability push. The daemon may also poll
// ROUTE_BRIDGE_REACHABLE as a backstop; both shapes share the same secret-free
// reachable list.
Bridge_Reachability_Update :: struct {
	contract_version: int,
	self_daemon_id: Daemon_ID,
	reachable: []Bridge_Reachable_Daemon,
	changed_unix_ms: i64,
}

DAEMON_FEDERATION_PEER_KIND_DIRECT :: "direct"
DAEMON_FEDERATION_REACHABILITY_EVENT :: "federation_reachability_changed"

Daemon_Federation_Peer :: struct {
	peer_id: string,
	daemon_id: Daemon_ID,
	kind: string, // DAEMON_FEDERATION_PEER_KIND_DIRECT in Phase 1.
	reach: Bridge_Reachability_Kind,
	next_hop: Daemon_ID,
	hops: int,
	via: []Daemon_ID,
	status: Bridge_Reachability_Status,
	last_seen_unix_ms: i64,
	updated_unix_ms: i64,
}

Daemon_Federation_Peers_Response :: struct {
	ok: bool,
	contract_version: int,
	self_daemon_id: Daemon_ID,
	bridge_configured: bool,
	bridge_reachable: bool,
	peers: []Daemon_Federation_Peer, // Secret-free: no endpoint, token, or session ids.
}

Daemon_Federation_Reachability_Event :: struct {
	type: string,
	event: string, // DAEMON_FEDERATION_REACHABILITY_EVENT.
	changed_daemon_ids: []Daemon_ID,
	changed_count: int,
	linked_count: int,
	unreachable_count: int,
	changed_unix_ms: i64,
}

// WebSocket frames are bidirectional on whichever direct bridge connection is
// open. The dialer/acceptor role is deliberately not encoded in a frame; either
// side may send request, response, push, or keepalive frames on the same stream
// namespace so one-way-dialable pairs can carry return traffic over the socket
// that already exists.
BRIDGE_WS_FRAME_KIND_REQUEST :: "request"
BRIDGE_WS_FRAME_KIND_RESPONSE :: "response"
BRIDGE_WS_FRAME_KIND_PUSH :: "push"
BRIDGE_WS_FRAME_KIND_KEEPALIVE :: "keepalive"
BRIDGE_WS_FRAME_KIND_CHUNK :: "chunk"
BRIDGE_WS_FRAME_KIND_CHUNK_ACK :: "chunk_ack"
BRIDGE_WS_FRAME_KIND_ERROR :: "error"

BRIDGE_WS_DEFAULT_CHUNK_BYTES :: 65536
BRIDGE_WS_MAX_CHUNK_PAYLOAD_BYTES :: 45000 // Base64 + JSON wrapper stays below the 65 KiB WS frame cap.
BRIDGE_WS_LARGE_PAYLOAD_TARGET_BYTES :: 10 * 1024 * 1024
BRIDGE_WS_MAX_TRANSIT_QUEUE_FRAMES :: 1024
BRIDGE_WS_MAX_TRANSIT_QUEUE_BYTES :: 16 * 1024 * 1024
BRIDGE_WS_TRANSIT_QUEUE_TTL_MS :: 10 * 60 * 1000
BRIDGE_WS_MAX_REASSEMBLIES :: 64
BRIDGE_WS_MAX_REASSEMBLY_BYTES :: 16 * 1024 * 1024
BRIDGE_WS_MAX_CHUNK_COUNT :: 4096
BRIDGE_WS_CHUNK_ACK_TIMEOUT_MS :: 1000
BRIDGE_WS_CHUNK_MAX_SEND_ATTEMPTS :: 3
BRIDGE_WS_HEARTBEAT_INTERVAL_MS :: 5000
BRIDGE_WS_HEARTBEAT_TIMEOUT_MS :: 15000
BRIDGE_WS_RECONNECT_BACKOFF_MIN_MS :: 250
BRIDGE_WS_RECONNECT_BACKOFF_MAX_MS :: 30000
BRIDGE_WS_RECONNECT_JITTER_MS :: 250

BRIDGE_WS_RESPONSE_CLASS_TRANSPORT_ACCEPT :: "transport_accept"
BRIDGE_WS_RESPONSE_CLASS_DESTINATION_ACK :: "destination_ack"
BRIDGE_WS_RESPONSE_CLASS_DAEMON_HTTP :: "daemon_http"
BRIDGE_WS_RESPONSE_CLASS_STREAM_END :: "stream_end"

BRIDGE_WS_ERROR_SCAFFOLD_ONLY :: "scaffold_only"

BRIDGE_WS_ERROR_UNSUPPORTED_VERSION :: "unsupported_version"
BRIDGE_WS_ERROR_UNKNOWN_KIND :: "unknown_kind"
BRIDGE_WS_ERROR_MALFORMED_FRAME :: "malformed_frame"
BRIDGE_WS_ERROR_UNROUTABLE :: "unroutable"
BRIDGE_WS_ERROR_TIMEOUT :: "timeout"
BRIDGE_WS_ERROR_DESTINATION_DAEMON :: "destination_daemon_error"

// Explicit safe failure policy for frame parsing:
// - unsupported version: send an error frame when possible, then close the WS
//   connection without processing the frame;
// - chunk frames are a bridge-only reassembly detail for large opaque payloads;
//   daemon loopback callers still send and receive whole opaque bodies;
// - unknown kind with a stream_id: send an error frame for that stream and leave
//   other streams intact;
// - unknown kind without a stream_id or malformed keepalive: ignore or close the
//   connection, but never mutate routing/delivery state from that frame.
BRIDGE_WS_UNSUPPORTED_VERSION_POLICY :: "error_then_close_connection"
BRIDGE_WS_UNKNOWN_KIND_POLICY :: "stream_error_or_ignore"
BRIDGE_WS_MALFORMED_FRAME_POLICY :: "no_state_mutation"

Bridge_WS_Request_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_REQUEST
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	idempotency_key: string,
	method: string,
	path: string,
	body: []byte, // Opaque proxied HTTP body.
	timeout_ms: int,
	ttl: int,
}

Bridge_WS_Response_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_RESPONSE
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	idempotency_key: string,
	response_class: string,
	status_code: int,
	status_text: string,
	body: []byte, // Opaque destination-daemon response or empty transport ack body.
	end_stream: bool,
}

Bridge_WS_Push_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_PUSH
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	route_kind: string,
	idempotency_key: string,
	payload: []byte, // Opaque federation inbox/callback payload.
	ttl: int,
}

Bridge_WS_Keepalive_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_KEEPALIVE
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	sent_unix_ms: i64,
	observed_unix_ms: i64,
}

Bridge_WS_Chunk_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_CHUNK
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	original_kind: string,
	idempotency_key: string,
	chunk_id: string,
	chunk_index: int,
	chunk_count: int,
	total_bytes: int,
	payload_fragment: []byte, // Opaque slice of the original WS payload/body.
	end_stream: bool,
}

Bridge_WS_Chunk_Ack_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_CHUNK_ACK
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	chunk_id: string,
	chunk_index: int,
	chunk_count: int,
	accepted: bool,
}

Bridge_WS_Error_Frame :: struct {
	version: int,
	kind: string, // BRIDGE_WS_FRAME_KIND_ERROR
	frame_id: Bridge_Frame_ID,
	stream_id: Bridge_Stream_ID,
	src_daemon_id: Daemon_ID,
	dest_daemon_id: Daemon_ID,
	error_code: string,
	message: string,
	terminal: bool,
}

bridge_ws_frame_version_supported :: proc(version: int) -> bool {
	return version == BRIDGE_WS_FRAME_VERSION
}

bridge_ws_frame_kind_supported :: proc(kind: string) -> bool {
	switch kind {
	case BRIDGE_WS_FRAME_KIND_REQUEST,
	     BRIDGE_WS_FRAME_KIND_RESPONSE,
	     BRIDGE_WS_FRAME_KIND_PUSH,
	     BRIDGE_WS_FRAME_KIND_KEEPALIVE,
	     BRIDGE_WS_FRAME_KIND_CHUNK,
	     BRIDGE_WS_FRAME_KIND_CHUNK_ACK,
	     BRIDGE_WS_FRAME_KIND_ERROR:
		return true
	}
	return false
}

bridge_ws_frame_supported :: proc(binary: Bridge_Binary, kind: string) -> bool {
	// Bridge-to-bridge frames are intentionally unsupported by ham-daemon and
	// client/user WebSockets. Only ham-bridge should accept or emit them.
	switch binary {
	case .Bridge:
		return bridge_ws_frame_kind_supported(kind)
	case .Daemon:
		return false
	}
	return false
}

bridge_send_acceptance_wire :: proc(acceptance: Bridge_Send_Acceptance) -> string {
	switch acceptance {
	case .Accepted_Queued:
		return BRIDGE_SEND_ACCEPTANCE_ACCEPTED_QUEUED
	case .Duplicate_Queued:
		return BRIDGE_SEND_ACCEPTANCE_DUPLICATE_QUEUED
	case .Rejected:
		return BRIDGE_SEND_ACCEPTANCE_REJECTED
	case .Destination_Unreachable:
		return BRIDGE_SEND_ACCEPTANCE_DESTINATION_UNREACHABLE
	case .Backpressure:
		return BRIDGE_SEND_ACCEPTANCE_BACKPRESSURE
	}
	return BRIDGE_SEND_ACCEPTANCE_REJECTED
}

bridge_send_acceptance_is_queued :: proc(acceptance: Bridge_Send_Acceptance) -> bool {
	switch acceptance {
	case .Accepted_Queued, .Duplicate_Queued:
		return true
	case .Rejected, .Destination_Unreachable, .Backpressure:
		return false
	}
	return false
}
