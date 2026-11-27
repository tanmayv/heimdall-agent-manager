package main

import "base:runtime"

import "core:encoding/json"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:time"
import "core:sync"
import "core:unicode/utf8"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"

Stream_Tab :: struct {
	id, title, type: string,
}

// Only trust the port number from the profile file, never a returned host or
// WebSocket URL. The debug server is always addressed over loopback.
stream_cdp_parse_port :: proc(raw: string) -> u16 {
	if len(raw) == 0 || len(raw) > 5 do return 0
	for ch in raw {
		if ch < '0' || ch > '9' do return 0
	}
	value, ok := strconv.parse_int(raw)
	if !ok || value < 1 || value > 65535 do return 0
	return u16(value)
}

stream_cdp_profile_port :: proc(profile: string) -> u16 {
	if profile == "" do return 0
	path, path_err := filepath.join({profile, "DevToolsActivePort"}, context.temp_allocator)
	if path_err != nil do return 0
	file, err := os.open(path)
	if err != nil do return 0
	defer os.close(file)
	buf: [512]byte
	n, _ := os.read(file, buf[:])
	end := strings.index_byte(string(buf[:n]), '\n')
	if end < 0 do return 0
	line := string(buf[:end])
	return stream_cdp_parse_port(strings.trim_right(line, "\r"))
}

stream_profile_port :: proc(profile: string, override: u16) -> u16 {
	if profile == "" do return 0
	if override != 0 do return override
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, profile, digest[:])
	first := u32(digest[0]) << 24 | u32(digest[1]) << 16 | u32(digest[2]) << 8 | u32(digest[3])
	return u16(20000 + first % 40000)
}

stream_cdp_tabs :: proc(conn: ^httpc.WebSocket) -> ([]Stream_Tab, bool) {
	if !stream_cdp_send(conn, `{"id":9,"method":"Target.getTargets"}`) do return nil, false
	reply, ok := stream_cdp_wait(conn, 9)
	if !ok do return nil, false
	out := make([dynamic]Stream_Tab, context.temp_allocator)
	for tab in reply.result.targetInfos {
		if tab.type == "page" && stream_cdp_target_valid(tab.targetId) {
			append(&out, Stream_Tab{tab.targetId, stream_cdp_title(tab.title), tab.type})
		}
	}
	return out[:], true
}

stream_cdp_list :: proc(profile: string) -> (tabs: []Stream_Tab, port: u16, occupied, ok: bool) {
	port = stream_profile_port(profile, bridge_config.browser_cdp_port)
	if port == 0 do return
	candidates := [2]u16{port, stream_cdp_profile_port(profile)}
	for candidate in candidates {
		if candidate == 0 do continue
		conn, state := stream_cdp_verified(candidate, profile)
		if state == .Foreign do return nil, 0, true, false
		if state == .Absent do continue
		defer httpc.websocket_close(&conn)
		tabs, ok = stream_cdp_tabs(&conn)
		return tabs, candidate, false, ok
	}
	return
}

stream_cdp_target_valid :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > 128 do return false
	for ch in id {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_') do return false
	}
	return true
}

Stream_Identity :: enum {Absent, Foreign, Verified}
Stream_CDP_Message :: struct {
	id: int,
	method, sessionId: string,
	result: struct { arguments: []string, sessionId: string, targetInfos: []struct {targetId, title, type: string} },
	params: json.Object,
	error: struct {code: int},
}

stream_cdp_identity_matches :: proc(args: []string, profile: string) -> bool {
	found := false
	for arg, i in args {
		value := ""
		if strings.has_prefix(arg, "--user-data-dir=") {
			value = strings.trim_prefix(arg, "--user-data-dir=")
		} else if arg == "--user-data-dir" && i + 1 < len(args) {
			value = args[i + 1]
		} else {
			continue
		}
		if found || value != profile || value == "" do return false
		found = true
	}
	return found
}

stream_cdp_send :: proc(conn: ^httpc.WebSocket, raw: string) -> bool {
	return httpc.websocket_send(conn, transmute([]byte)raw, timeout = 250 * time.Millisecond)
}

// Keep only a bounded in-memory message. A transport read can contain only part
// of a WebSocket frame. Continue until both frame and message are complete.
stream_cdp_read :: proc(conn: ^httpc.WebSocket, buf: ^[dynamic]byte) -> (complete, ok: bool) {
	chunk: [16 * 1024]byte
	n, info, success := httpc.websocket_receive(conn, chunk[:])
	if !success || info.kind == .Close do return false, false
	if info.kind == .Again || info.kind == .Ping || info.kind == .Pong do return false, true
	if info.kind != .Text || len(buf^) + n > 2 * contracts.STREAM_MAX_BYTES_PER_SECOND do return false, false
	append(buf, ..chunk[:n])
	return info.bytes_left == 0 && !info.continuation, true
}

stream_cdp_wait :: proc(conn: ^httpc.WebSocket, id: int) -> (Stream_CDP_Message, bool) {
	buf := make([dynamic]byte, context.temp_allocator)
	start := time.tick_now()
	for time.tick_since(start) < 750 * time.Millisecond {
		complete, ok := stream_cdp_read(conn, &buf)
		if !ok do break
		if !complete { time.sleep(2 * time.Millisecond); continue }
		reply: Stream_CDP_Message
		err := json.unmarshal(buf[:], &reply, allocator = context.temp_allocator)
		if err == nil && reply.id == id do return reply, reply.error.code == 0
		clear(&buf)
	}
	return {}, false
}

stream_cdp_verified :: proc(port: u16, profile: string) -> (httpc.WebSocket, Stream_Identity) {
	url, url_err := httpc.url_from_parts("http", "127.0.0.1", int(port))
	if url_err != .None do return {}, .Absent
	resp, err := httpc.send({method = .GET, url = url, path = {"json", "version"}, timeout_ms = 500, max_response_bytes = 16 * 1024})
	defer httpc.response_destroy(&resp)
	if err != .None do return {}, .Absent
	if resp.status != 200 do return {}, .Foreign
	info: struct { webSocketDebuggerUrl: string }
	if json.unmarshal(resp.body, &info, allocator = context.temp_allocator) != nil do return {}, .Foreign
	// Ignore the returned authority, even when the debug server is local.
	_, found, path := strings.partition(info.webSocketDebuggerUrl, "/devtools/browser/")
	if found == "" || !stream_cdp_target_valid(path) do return {}, .Foreign
	conn, ws_err, _ := httpc.websocket_connect(fmt.tprintf("ws://127.0.0.1:%d/devtools/browser/%s", port, path), "", 750)
	if ws_err != .None do return {}, .Foreign
	verified := false
	defer if !verified do httpc.websocket_close(&conn)
	if !stream_cdp_send(&conn, `{"id":1,"method":"Browser.getBrowserCommandLine"}`) do return {}, .Foreign
	reply, ok := stream_cdp_wait(&conn, 1)
	if !ok || !stream_cdp_identity_matches(reply.result.arguments, profile) do return {}, .Foreign
	verified = true
	return conn, .Verified
}

stream_capture_worker :: proc(data: rawptr) {
	live := cast(^Stream_Live)data
	reason := "source_error"
	stage := "verify"
	defer {
		sync.mutex_lock(&stream_mu)
		if !live.worker_stop && live.reason == "" { live.reason, live.source_stage = reason, stage }
		sync.mutex_unlock(&stream_mu)
	}
	conn, identity := stream_cdp_verified(live.port, live.profile)
	if identity != .Verified do return
	defer httpc.websocket_close(&conn)
	if live.worker_watching {
		reason = stream_watch_source(&conn, live)
		return
	}
	stage = "attach_send"
	if !stream_cdp_target_valid(live.reg.source.ref) { stage = "target"; return }
	if !stream_cdp_command(&conn, 2, "", "Target.attachToTarget",
		struct {targetId: string, flatten: bool}{live.reg.source.ref, true}) { return }
	stage = "attach_wait"
	attach, attached := stream_cdp_wait(&conn, 2)
	if !attached {
		if attach.error.code != 0 { reason, stage = "source_closed", "attach_cdp_error" }
		return
	}
	session := strings.clone(attach.result.sessionId)
	defer delete(session)
	stage = "session"
	if !stream_cdp_target_valid(session) do return
	fmt.eprintln("bridge stream: CDP attached")
	stage = "start"
	if !stream_cdp_command(&conn, 3, session, "Page.startScreencast",
		struct {format: string, quality, maxWidth, maxHeight: int}{"jpeg", 60, contracts.STREAM_MAX_WIDTH, contracts.STREAM_MAX_HEIGHT}) { return }
	if _, started := stream_cdp_wait(&conn, 3); !started do return
	fmt.eprintln("bridge stream: screencast started")
	defer _ = stream_cdp_command(&conn, 4, session, "Page.stopScreencast", struct {}{})

	buf := make([dynamic]byte)
	defer delete(buf)
	stage = "receive"
	request_id := 4
	first_frame := true
	first_frame_wait := time.tick_now()
	reported_wait := false
	for {
		sync.mutex_lock(&stream_mu)
		stop := live.worker_stop
		acked, ack_session := live.acked, live.ack_session
		live.acked = 0
		sync.mutex_unlock(&stream_mu)
		if stop do return
		if first_frame && !reported_wait && time.tick_since(first_frame_wait) >= 5 * time.Second {
			fmt.eprintln("bridge stream: waiting for first screencast frame")
			reported_wait = true
		}
		for _ in 0..<acked {
			request_id += 1
			if !stream_cdp_ack(&conn, request_id, session, ack_session) do return
		}
		complete, read_ok := stream_cdp_read(&conn, &buf)
		if !read_ok { stage = "read"; return }
		if !complete { time.sleep(2 * time.Millisecond); continue }
		defer free_all(context.temp_allocator)
		message: Stream_CDP_Message
		parse_err := json.unmarshal(buf[:], &message, allocator = context.temp_allocator)
		clear(&buf)
		if parse_err != nil { stage = "parse"; return }
		if message.method == "Target.detachedFromTarget" || message.method == "Inspector.detached" {
			reason = "source_closed"
			return
		}
		if message.method != "Page.screencastFrame" || message.sessionId != session do continue
		encoded, has_data := message.params["data"].(json.String)
		frame_session, has_session := message.params["sessionId"].(json.Integer)
		if !has_data || !has_session || frame_session <= 0 { stage = "frame_metadata"; return }
		data, decode_err := base64.decode(string(encoded), allocator = runtime.heap_allocator())
		discard_session := 0
		if decode_err != nil || len(data) == 0 || len(data) > contracts.STREAM_MAX_BYTES_PER_SECOND {
			delete(data, runtime.heap_allocator())
			discard_session = int(frame_session)
		} else {
			discard_session = stream_offer_frame(live, data, int(frame_session))
			if first_frame {
				fmt.eprintln("bridge stream: first screencast frame")
				first_frame = false
			}
		}
		if discard_session != 0 {
			request_id += 1
			if !stream_cdp_ack(&conn, request_id, session, discard_session) do return
		}
	}
}

stream_cdp_ack :: proc(conn: ^httpc.WebSocket, id: int, session: string, frame_session: int) -> bool {
	return stream_cdp_command(conn, id, session, "Page.screencastFrameAck", struct {sessionId: int}{frame_session})
}

stream_cdp_title :: proc(raw_title: string) -> string {
	if !utf8.valid_string(raw_title) do return "Browser tab"
	title := strings.trim_space(raw_title)
	if len(title) >= len("data:") && strings.equal_fold(title[:len("data:")], "data:") do return "Data URL tab"
	if title == "" do return "Browser tab"
	for ch, offset in title {
		if ch < 0x20 || ch >= 0x7f && ch <= 0x9f || (len(title) > 200 && offset >= 194) {
			if offset == 0 do return "Browser tab"
			return strings.concatenate({strings.trim_space(title[:offset]), "…"}, context.temp_allocator)
		}
	}
	return title
}

// A shared link can have zero viewers. Watch target lifetime without starting a
// screencast, so closing the tab ends the link even before the first attach.
stream_watch_source :: proc(conn: ^httpc.WebSocket, live: ^Stream_Live) -> string {
	last_poll: time.Tick
	for {
		sync.mutex_lock(&stream_mu)
		stop := live.worker_stop
		sync.mutex_unlock(&stream_mu)
		if stop do return "stopped"
		if last_poll._nsec == 0 || time.tick_since(last_poll) >= 2 * time.Second {
			defer free_all(context.temp_allocator)
			tabs, ok := stream_cdp_tabs(conn)
			if !ok do return "source_error"
			found := false
			for tab in tabs {
				if tab.id == live.reg.source.ref { found = true; break }
			}
			if !found do return "source_closed"
			last_poll = time.tick_now()
		}
		time.sleep(25 * time.Millisecond)
	}
}

stream_cdp_command :: proc(conn: ^httpc.WebSocket, id: int, session, method: string, params: $T) -> bool {
	raw: []byte
	err: json.Marshal_Error
	if session == "" {
		raw, err = json.marshal(struct {id: int, method: string, params: T}{id, method, params})
	} else {
		raw, err = json.marshal(struct {id: int, sessionId, method: string, params: T}{id, session, method, params})
	}
	defer delete(raw)
	return err == nil && httpc.websocket_send(conn, raw, timeout = 250 * time.Millisecond)
}
