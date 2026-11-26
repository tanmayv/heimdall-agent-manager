package contracts

import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

STREAM_PROTOCOL_VERSION :: 1
STREAM_MAX_CONTROL_BYTES :: 4 * 1024
STREAM_MAX_PIECE_BYTES :: 12 * 1024
STREAM_MAX_FPS :: 8
STREAM_MAX_BYTES_PER_SECOND :: 1_000_000
STREAM_MAX_WIDTH :: 1280
STREAM_MAX_HEIGHT :: 800
STREAM_MAX_PER_BRIDGE :: 4
STREAM_EXPIRY_MS :: 2 * 60 * 60 * 1000
STREAM_ID_BYTES :: 32 // Lowercase hex on both transports, encoding 16 random bytes.
STREAM_MAX_MIME_BYTES :: 127
STREAM_MIME_JPEG :: "image/jpeg"
STREAM_SOURCE_BROWSER_TAB :: "browser_tab"

Stream_Source_Ref :: struct { kind, ref: string }
Stream_Registration :: struct {
	stream_id, owner, bridge, instance, task: string,
	source: Stream_Source_Ref,
	title: string,
	expires: u64, // Unix epoch milliseconds.
}
Stream_Register_Ack :: struct { stream_id: string, accepted: bool, code: string }
Stream_Attach :: struct { stream_id: string }
Stream_Detach :: struct { stream_id: string }
Stream_Stop :: struct { stream_id: string }
Stream_Ended :: struct { stream_id, reason: string }
Stream_Control :: union {
	Stream_Registration, Stream_Register_Ack, Stream_Attach, Stream_Detach, Stream_Stop, Stream_Ended,
}

// Capture providers deliver whole encoded frames. The receiver must consume or
// copy borrowed bytes before returning. stop must quiesce delivery before it
// returns. The worker owns throttling, routing and splitting, not the source.
Stream_On_Frame :: proc(userdata: rawptr, mime: string, data: []byte)
Stream_Source :: struct {
	userdata: rawptr,
	start: proc(userdata: rawptr, source: Stream_Source_Ref, on_frame: Stream_On_Frame, receiver: rawptr) -> bool,
	stop: proc(userdata: rawptr),
}

stream_id_valid :: proc(id: string) -> bool {
	if len(id) != STREAM_ID_BYTES do return false
	for c in id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') do return false
	}
	return true
}

// Check against a caller-supplied receipt time (not the sender's clock).
stream_expiry_valid :: proc(expires, received_ms: u64) -> bool {
	return expires > received_ms && expires - received_ms <= STREAM_EXPIRY_MS
}

@(private = "file")
stream_registration_valid :: proc(r: Stream_Registration) -> bool {
	if !stream_id_valid(r.stream_id) || !multi_question_valid_id(r.owner) ||
	   !multi_question_valid_id(r.bridge) || !multi_question_valid_id(r.instance) ||
	   r.task != "" && !multi_question_valid_id(r.task) ||
	   r.expires == 0 ||
	   r.source.kind != STREAM_SOURCE_BROWSER_TAB || len(r.source.ref) < 1 || len(r.source.ref) > 128 ||
	   len(r.title) > 200 || !utf8.valid_string(r.title) {
		return false
	}
	for c in r.source.ref {
		if c < 0x20 || c > 0x7e do return false
	}
	for c in r.title {
		if c < 0x20 || c >= 0x7f && c <= 0x9f do return false
	}
	return true
}

@(private = "file")
stream_ack_valid :: proc(a: Stream_Register_Ack) -> bool {
	if a.accepted do return a.code == ""
	return a.code == "invalid" || a.code == "unauthorized" || a.code == "limit" || a.code == "duplicate"
}

@(private = "file")
stream_reason_valid :: proc(reason: string) -> bool {
	switch reason {
	case "source_closed", "stopped", "expired", "instance_ended", "source_error": return true
	}
	return false
}

@(private = "file")
stream_marshal :: proc(kind: string, payload: $T, allocator := context.allocator) -> []byte {
	out, err := json.marshal(struct {type: string, protocol_version: int, payload: T}{
		kind, STREAM_PROTOCOL_VERSION, payload,
	}, allocator = allocator)
	if err != nil do return nil
	return out
}

// Caller owns the result. Nil denotes an invalid control.
stream_encode_control :: proc(control: Stream_Control, allocator := context.allocator) -> []byte {
	switch p in control {
	case Stream_Registration:
		if stream_registration_valid(p) do return stream_marshal("stream_register", p, allocator)
	case Stream_Register_Ack:
		if stream_id_valid(p.stream_id) && stream_ack_valid(p) do return stream_marshal("stream_register_ack", p, allocator)
	case Stream_Attach:
		if stream_id_valid(p.stream_id) do return stream_marshal("stream_attach", p, allocator)
	case Stream_Detach:
		if stream_id_valid(p.stream_id) do return stream_marshal("stream_detach", p, allocator)
	case Stream_Stop:
		if stream_id_valid(p.stream_id) do return stream_marshal("stream_stop", p, allocator)
	case Stream_Ended:
		if stream_id_valid(p.stream_id) && stream_reason_valid(p.reason) do return stream_marshal("stream_ended", p, allocator)
	}
	return nil
}

// Compare token member count to the validated schema's total to reject
// duplicate members. Also validate integers lexically: the JSON object
// parser represents them as i64 and ignores conversion overflow.
@(private = "file")
stream_control_numbers :: proc(raw: string, expected_members: int) -> (expires: u64, ok: bool) {
	t := json.make_tokenizer(raw, .JSON, true)
	count, depth := 0, 0
	for {
		tok, err := json.get_token(&t)
		if err == .EOF do return expires, count == expected_members
		if err != nil do return 0, false
		#partial switch tok.kind {
		case .Open_Brace: depth += 1
		case .Close_Brace: depth -= 1
		case .Colon: count += 1
		case .Integer:
			if depth == 1 {
				if tok.text != "1" do return 0, false
			} else if depth == 2 {
				for c in tok.text {
					if c < '0' || c > '9' do return 0, false
					digit := u64(c - '0')
					if expires > (max(u64) - digit) / 10 do return 0, false
					expires = expires * 10 + digit
				}
			}
		}
	}
}

// Use a temporary/arena allocator for the parsed JSON and returned strings.
// Receipt time applies only to registration. Authentication and binding IDs
// to the authenticated bridge/session belong to the caller.
stream_decode_control :: proc(raw: string, received_ms: u64, allocator := context.temp_allocator) -> (Stream_Control, bool) {
	// The core tokenizer treats a raw NUL as end-of-input.
	if len(raw) > STREAM_MAX_CONTROL_BYTES || strings.contains(raw, "\x00") do return nil, false
	o, ok := secure_form_object(raw, STREAM_MAX_CONTROL_BYTES, allocator)
	if !ok || len(o) != 3 do return nil, false
	version, v_ok := o["protocol_version"].(json.Integer)
	p, p_ok := o["payload"].(json.Object)
	if !v_ok || version != STREAM_PROTOCOL_VERSION || !p_ok do return nil, false
	id := mq_string(p, "stream_id")
	if !stream_id_valid(id) do return nil, false
	switch mq_string(o, "type") {
	case "stream_register":
		source, s_ok := p["source"].(json.Object)
		title, title_ok := p["title"].(json.String)
		task, task_ok := p["task"].(json.String)
		_, exp_ok := p["expires"].(json.Integer)
		expires, numbers_ok := stream_control_numbers(raw, 13)
		if len(p) != 8 || len(source) != 2 || !s_ok || !title_ok || !task_ok ||
		   !exp_ok || !numbers_ok {
			return nil, false
		}
		r := Stream_Registration{
			id, mq_string(p, "owner"), mq_string(p, "bridge"), mq_string(p, "instance"),
			string(task), {mq_string(source, "kind"), mq_string(source, "ref")}, string(title), expires,
		}
		if stream_registration_valid(r) && stream_expiry_valid(r.expires, received_ms) do return r, true
	case "stream_register_ack":
		accepted, a_ok := p["accepted"].(json.Boolean)
		code, c_ok := p["code"].(json.String)
		a := Stream_Register_Ack{id, bool(accepted), string(code)}
		_, numbers_ok := stream_control_numbers(raw, 6)
		if len(p) == 3 && a_ok && c_ok && stream_ack_valid(a) && numbers_ok do return a, true
	case "stream_ended":
		reason := mq_string(p, "reason")
		_, numbers_ok := stream_control_numbers(raw, 5)
		if len(p) == 2 && stream_reason_valid(reason) && numbers_ok do return Stream_Ended{id, reason}, true
	case "stream_attach", "stream_detach", "stream_stop":
		_, numbers_ok := stream_control_numbers(raw, 4)
		if len(p) != 1 || !numbers_ok do return nil, false
		switch mq_string(o, "type") {
		case "stream_attach": return Stream_Attach{id}, true
		case "stream_detach": return Stream_Detach{id}, true
		case "stream_stop": return Stream_Stop{id}, true
		}
	}
	return nil, false
}

// Session-envelope-compatible binary layout. The ID slot carries stream_id.
// u8 kind | u8 flags=0 | u16be ID length | ID
// | u64be frame_seq | u16be piece_index (zero-based) | u16be piece_count
// | u8 MIME length | ASCII MIME | nonempty piece bytes.
// Decoded strings and bytes borrow from the input frame.
Stream_Piece :: struct {
	stream_id: string,
	frame_seq: u64,
	piece_index, piece_count: u16,
	mime: string,
	data: []byte,
}

STREAM_PIECE_HEADER_BYTES :: 13
STREAM_MAX_PIECE_WIRE_BYTES :: PTY_WIRE_SESSION_HEADER_BYTES + STREAM_ID_BYTES +
	STREAM_PIECE_HEADER_BYTES + STREAM_MAX_MIME_BYTES + STREAM_MAX_PIECE_BYTES

@(private = "file")
stream_mime_valid :: proc(mime: string) -> bool {
	if len(mime) < 3 || len(mime) > STREAM_MAX_MIME_BYTES do return false
	slash := false
	for c, i in mime {
		if c == '/' {
			if slash || i == 0 || i == len(mime)-1 do return false
			slash = true
		} else if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		            c == '!' || c == '#' || c == '$' || c == '&' || c == '^' || c == '_' ||
		            c == '.' || c == '+' || c == '-') {
			return false
		}
	}
	return slash
}

@(private = "file")
stream_piece_valid :: proc(p: Stream_Piece) -> bool {
	return stream_id_valid(p.stream_id) && p.piece_index < p.piece_count &&
		stream_mime_valid(p.mime) && len(p.data) > 0 && len(p.data) <= STREAM_MAX_PIECE_BYTES
}

// Caller owns the encoded bytes. Nil denotes an invalid piece.
stream_encode_piece :: proc(p: Stream_Piece, allocator := context.allocator) -> []byte {
	if !stream_piece_valid(p) do return nil
	header := PTY_WIRE_SESSION_HEADER_BYTES + STREAM_ID_BYTES
	out := make([]byte, header + STREAM_PIECE_HEADER_BYTES + len(p.mime) + len(p.data), allocator)
	out[0] = STREAM_WIRE_KIND_PIECE
	out[1] = 0
	out[2] = 0
	out[3] = STREAM_ID_BYTES
	copy(out[4:header], transmute([]byte)p.stream_id)
	body := out[header:]
	for i in 0..<8 do body[i] = byte(p.frame_seq >> uint(56 - 8*i))
	body[8], body[9] = byte(p.piece_index >> 8), byte(p.piece_index)
	body[10], body[11] = byte(p.piece_count >> 8), byte(p.piece_count)
	body[12] = byte(len(p.mime))
	end := STREAM_PIECE_HEADER_BYTES + len(p.mime)
	copy(body[STREAM_PIECE_HEADER_BYTES:end], transmute([]byte)p.mime)
	copy(body[end:], p.data)
	return out
}

stream_decode_piece :: proc(frame: []byte) -> (Stream_Piece, bool) {
	if len(frame) > STREAM_MAX_PIECE_WIRE_BYTES do return {}, false
	kind, flags, id, body, ok := pty_wire_decode_session_frame(frame)
	if !ok || kind != STREAM_WIRE_KIND_PIECE || flags != 0 || len(body) < STREAM_PIECE_HEADER_BYTES do return {}, false
	end := STREAM_PIECE_HEADER_BYTES + int(body[12])
	if end > len(body) do return {}, false
	seq: u64
	for b in body[:8] do seq = seq << 8 | u64(b)
	p := Stream_Piece{
		id, seq, u16(body[8]) << 8 | u16(body[9]), u16(body[10]) << 8 | u16(body[11]),
		string(body[STREAM_PIECE_HEADER_BYTES:end]), body[end:],
	}
	if !stream_piece_valid(p) do return {}, false
	return p, true
}
