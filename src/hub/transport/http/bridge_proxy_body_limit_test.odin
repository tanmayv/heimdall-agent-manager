package http

// REQ-VOICE-6: the hub's copy of the relay request-body limit.
//
// A current bridge refuses an oversized Content-Length before it sends proxy_open, so
// the hub-side check exists for bridges that predate that (or misreport the length):
// once a stream's forwarded body passes contracts.RELAY_MAX_REQUEST_BODY_BYTES, the hub
// answers the origin with a 413 and closes both legs instead of relaying an unbounded
// body. These tests drive bridge_proxy_handle_data against a capturing command sink.

import base64 "core:encoding/base64"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "odin_test:contracts"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

@(private = "file")
Captured_Command :: struct {
	bridge_id: string,
	body:      string,
}

@(private = "file")
Capture :: struct {
	mu:       sync.Mutex,
	commands: [dynamic]Captured_Command,
}

@(private = "file")
capture_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	c := (^Capture)(ctx)
	heap := runtime.heap_allocator()
	sync.mutex_lock(&c.mu)
	append(&c.commands, Captured_Command{strings.clone(command.bridge_id, heap), strings.clone(command.body_json, heap)})
	sync.mutex_unlock(&c.mu)
	return true, {}
}

@(private = "file")
capture_destroy :: proc(c: ^Capture) {
	heap := runtime.heap_allocator()
	for cmd in c.commands {
		delete(cmd.bridge_id, heap)
		delete(cmd.body, heap)
	}
	delete(c.commands)
}

@(private = "file")
data_frame :: proc(proxy_id: string, payload: string) -> string {
	encoded := base64.encode(transmute([]byte)payload)
	defer delete(encoded)
	return strings.concatenate({"{\"type\":\"proxy_data\",\"proxy_id\":\"", proxy_id, "\",\"data_b64\":\"", string(encoded), "\",\"last\":false}"})
}

@(test)
bridge_proxy_hub_refuses_body_past_relay_limit :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	capture: Capture
	capture.commands = make([dynamic]Captured_Command)
	defer capture_destroy(&capture)
	svc := shell_session_svc.Shell_Session_Service{}
	svc.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = &capture, send_runtime_command = capture_send}
	h := Bridge_Handlers{shell_sessions = &svc}

	ORIGIN :: "brg_voice6_origin"
	TARGET :: "brg_voice6_target"
	PROXY :: "px_voice6_limit"
	hub_proxy_ensure_init()
	key := hub_proxy_key(ORIGIN, PROXY, heap)
	rec := new(Hub_Proxy_Stream, heap)
	rec^ = Hub_Proxy_Stream{
		key              = key,
		proxy_id         = strings.clone(PROXY, heap),
		stream_id        = strings.clone("pxvoice6_stream", heap),
		origin_bridge_id = strings.clone(ORIGIN, heap),
		target_bridge_id = strings.clone(TARGET, heap),
		// Two bytes short of the limit, so the test need not send 64 MiB.
		body_bytes       = contracts.RELAY_MAX_REQUEST_BODY_BYTES - 2,
	}
	sync.mutex_lock(&hub_proxy_mu)
	hub_proxy_streams[strings.clone(key, heap)] = rec
	sync.mutex_unlock(&hub_proxy_mu)

	// Exactly AT the limit: still relayed to the target as tunnel_data.
	at := data_frame(PROXY, "ab")
	defer delete(at)
	bridge_proxy_handle_data(&h, ORIGIN, at)
	testing.expect_value(t, len(capture.commands), 1)
	if len(capture.commands) == 1 {
		testing.expect_value(t, capture.commands[0].bridge_id, TARGET)
		testing.expect(t, strings.contains(capture.commands[0].body, "\"tunnel_data\""), "at-limit bytes go to the target")
	}

	// One byte past it: 413 to the origin, then its close, then the target leg closes.
	over := data_frame(PROXY, "c")
	defer delete(over)
	bridge_proxy_handle_data(&h, ORIGIN, over)
	testing.expect_value(t, len(capture.commands), 4)
	if len(capture.commands) == 4 {
		refusal := capture.commands[1]
		testing.expect_value(t, refusal.bridge_id, ORIGIN)
		testing.expect(t, strings.contains(refusal.body, "\"proxy_data\""), "the 413 travels as response bytes")
		b64_start := strings.index(refusal.body, "\"data_b64\":\"") + len("\"data_b64\":\"")
		b64_end := b64_start + strings.index(refusal.body[b64_start:], "\"")
		raw, _ := base64.decode(refusal.body[b64_start:b64_end])
		defer delete(raw)
		testing.expectf(t, strings.has_prefix(string(raw), "HTTP/1.1 413 Content Too Large\r\n"), "got %q", string(raw))
		testing.expect(t, strings.contains(string(raw), "request_body_too_large"), "reason in the body")

		testing.expect_value(t, capture.commands[2].bridge_id, ORIGIN)
		testing.expect(t, strings.contains(capture.commands[2].body, "\"proxy_close\""), "origin stream closed after the 413")
		testing.expect_value(t, capture.commands[3].bridge_id, TARGET)
		testing.expect(t, strings.contains(capture.commands[3].body, "\"tunnel_close\""), "target leg closed")
	}

	// The stream is gone: later body bytes are dropped, not relayed.
	lookup_key := hub_proxy_key(ORIGIN, PROXY, heap) // rec.key was freed with the record
	defer delete(lookup_key, heap)
	sync.mutex_lock(&hub_proxy_mu)
	_, still := hub_proxy_streams[lookup_key]
	sync.mutex_unlock(&hub_proxy_mu)
	testing.expect(t, !still, "the stream record is removed")
	late := data_frame(PROXY, "d")
	defer delete(late)
	bridge_proxy_handle_data(&h, ORIGIN, late)
	testing.expect_value(t, len(capture.commands), 4)
}

@(test)
bridge_proxy_hub_refusal_status_text :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_proxy_status_text(413), "Content Too Large")
	testing.expect_value(t, bridge_proxy_status_text(404), "Not Found")
	testing.expect_value(t, bridge_proxy_status_text(409), "Conflict")
	testing.expect_value(t, bridge_proxy_status_text(503), "Service Unavailable")
	testing.expect_value(t, bridge_proxy_status_text(403), "Forbidden")
}
