package contracts

import "core:strings"
import "core:testing"

@(private = "file")
TEST_STREAM_ID :: "0123456789abcdef0123456789abcdef"
@(private = "file")
TEST_STREAM_NOW :: u64(1_795_736_800_000)
@(private = "file")
TEST_STREAM_REGISTER :: `{"type":"stream_register","protocol_version":1,"payload":{"stream_id":"0123456789abcdef0123456789abcdef","owner":"owner_1","bridge":"brg_1","instance":"inst_1","task":"","source":{"kind":"browser_tab","ref":"Target-1"},"title":"","expires":1795744000000}}`

@(test)
test_stream_control_round_trip :: proc(t: ^testing.T) {
	registration := Stream_Registration{
		TEST_STREAM_ID, "owner_1", "brg_1", "inst_1", "",
		{STREAM_SOURCE_BROWSER_TAB, "Target-1"}, "Example \"title\" 漢", TEST_STREAM_NOW + STREAM_EXPIRY_MS,
	}
	controls := [?]Stream_Control{
		registration, Stream_Attach{TEST_STREAM_ID}, Stream_Detach{TEST_STREAM_ID},
		Stream_Stop{TEST_STREAM_ID}, Stream_Register_Ack{TEST_STREAM_ID, true, ""},
		Stream_Register_Ack{TEST_STREAM_ID, false, "unauthorized"},
		Stream_Ended{TEST_STREAM_ID, "source_closed"},
	}
	kinds := [?]string{
		"stream_register", "stream_attach", "stream_detach", "stream_stop",
		"stream_register_ack", "stream_register_ack", "stream_ended",
	}
	for want, i in controls {
		raw := stream_encode_control(want, context.temp_allocator)
		got, ok := stream_decode_control(string(raw), TEST_STREAM_NOW)
		testing.expect(t, ok && got == want, kinds[i])
		testing.expect(t, strings.contains(string(raw), kinds[i]), "not a legacy browser_stream_* frame")
	}
	wire, ok := stream_decode_control(TEST_STREAM_REGISTER, TEST_STREAM_NOW)
	parsed, is_registration := wire.(Stream_Registration)
	testing.expect(t, ok && is_registration && parsed.expires == TEST_STREAM_NOW + STREAM_EXPIRY_MS && parsed.title == "")
	registration.expires = max(u64)
	raw := stream_encode_control(registration, context.temp_allocator)
	got, max_ok := stream_decode_control(string(raw), max(u64) - STREAM_EXPIRY_MS)
	testing.expect(t, max_ok && got == Stream_Control(registration), "unsigned expiry and no receipt-window overflow")
}

@(test)
test_stream_control_rejects_invalid_shapes :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{`"protocol_version":1`, `"protocol_version":2`},
		{`"protocol_version":1`, `"protocol_version":1,"extra":true`},
		{`"protocol_version":1`, `"protocol_version":1,"type":"stream_register"`},
		{`"protocol_version":1`, `"protocol_version":1.0`},
		{`"protocol_version":1`, `"protocol_version":01`},
		{`"protocol_version":1`, `"protocol_version":18446744073709551617`},
		{"stream_register", "browser_stream_register"},
		{"0123456789abcdef", "0123456789ABCDEF"},
		{`"task":""`, `"extra":""`},
		{`"title":""`, `"title":false`},
		{`"title":""`, `"title":"\u0085"`},
		{`"title":""`, `"title":"\ud800"`},
		{`"title":""`, `"title":"\x20"`},
		{`"ref":"Target-1"`, `"ref":"Target-1","extra":""`},
		{`"ref":"Target-1"`, `"ref":"Target-1","r\u0065f":"Target-1"`},
		{`"ref":"Target-1"`, `"ref":"é"`},
		{"browser_tab", "os_window"},
		{"1795744000000", "1795744000001"},
		{"1795744000000", "1795736800000"},
		{"1795744000000", "-1"},
		{"1795744000000", `"1795744000000"`},
		{"1795744000000", "18446744073709551616"},
		{"1795744000000", "18446745869453551616"},
	}
	for parts in cases {
		raw, replaced := strings.replace_all(TEST_STREAM_REGISTER, parts[0], parts[1], context.temp_allocator)
		_, ok := stream_decode_control(raw, TEST_STREAM_NOW)
		testing.expect(t, replaced && !ok, parts[1])
	}
	bad_controls := [?]string{
		"{}", `{"payload":{,}}`,
		TEST_STREAM_REGISTER + "{}", TEST_STREAM_REGISTER + "\x00",
		strings.concatenate({TEST_STREAM_REGISTER, strings.repeat(" ", STREAM_MAX_CONTROL_BYTES, context.temp_allocator)}, context.temp_allocator),
		`{"type":"stream_attach","protocol_version":1,"payload":{"stream_id":"0123456789abcdef0123456789abcdef","reason":"stopped"}}`,
		`{"type":"stream_register_ack","protocol_version":1,"payload":{"stream_id":"0123456789abcdef0123456789abcdef","accepted":true,"code":"limit"}}`,
		`{"type":"stream_register_ack","protocol_version":1,"payload":{"stream_id":"0123456789abcdef0123456789abcdef","accepted":false,"code":""}}`,
		`{"type":"stream_ended","protocol_version":1,"payload":{"stream_id":"0123456789abcdef0123456789abcdef","reason":"tab_closed"}}`,
	}
	for malformed in bad_controls {
		_, ok := stream_decode_control(malformed, TEST_STREAM_NOW)
		testing.expect(t, !ok)
	}
	raw, _ := strings.replace_all(TEST_STREAM_REGISTER, `"title":""`,
		strings.concatenate({`"title":"`, strings.repeat("é", 101, context.temp_allocator), `"`}, context.temp_allocator),
		context.temp_allocator)
	_, title_ok := stream_decode_control(raw, TEST_STREAM_NOW)
	testing.expect(t, !title_ok, "title cap is in UTF-8 bytes")
	testing.expect(t, stream_encode_control(Stream_Ended{TEST_STREAM_ID, "tab_closed"}, context.temp_allocator) == nil)
}

@(test)
test_stream_piece_round_trip_and_session_envelope :: proc(t: ^testing.T) {
	data: [STREAM_MAX_PIECE_BYTES]byte
	data[0], data[len(data)-1] = 0xd8, 0xd9
	piece := Stream_Piece{TEST_STREAM_ID, 0xfedcba9876543210, 0x0102, 0x0304, "image/webp", data[:]}
	raw := stream_encode_piece(piece, context.temp_allocator)
	kind, flags, sid, body, envelope_ok := pty_wire_decode_session_frame(raw)
	testing.expect(t, envelope_ok && kind == 0x04 && flags == 0 && sid == TEST_STREAM_ID)
	testing.expect(t, kind != PTY_WIRE_KIND_OUTPUT && kind != PTY_WIRE_KIND_INPUT && kind != PTY_WIRE_KIND_SCREEN)
	if !envelope_ok do return
	testing.expect(t, len(raw) < 16*1024)
	testing.expect(t, string(body[:13]) == "\xfe\xdc\xba\x98\x76\x54\x32\x10\x01\x02\x03\x04\x0a")
	got, ok := stream_decode_piece(raw)
	testing.expect(t, ok && got.stream_id == piece.stream_id && got.frame_seq == piece.frame_seq &&
		got.piece_index == piece.piece_index && got.piece_count == piece.piece_count && got.mime == piece.mime &&
		string(got.data) == string(piece.data))
}

@(test)
test_stream_piece_rejects_invalid_frames :: proc(t: ^testing.T) {
	data: [STREAM_MAX_PIECE_BYTES + 1]byte
	piece := Stream_Piece{TEST_STREAM_ID, 1, 0, 1, STREAM_MIME_JPEG, data[:STREAM_MAX_PIECE_BYTES]}
	raw := stream_encode_piece(piece, context.temp_allocator)
	if !testing.expect(t, raw != nil) do return
	header := PTY_WIRE_SESSION_HEADER_BYTES + STREAM_ID_BYTES
	for size in 0..<(header + STREAM_PIECE_HEADER_BYTES + len(piece.mime) + 1) {
		_, ok := stream_decode_piece(raw[:size])
		testing.expect(t, !ok, "every truncated header or missing data fails")
	}
	edits := [?]struct {offset: int, value: byte}{
		{0, PTY_WIRE_KIND_OUTPUT}, {1, PTY_WIRE_FLAG_ENCRYPTED}, {3, 0}, {4, 'G'},
		{header + 9, 1}, {header + 11, 0}, {header + 12, 255}, {header + 13, '/'},
	}
	for edit in edits {
		old := raw[edit.offset]
		raw[edit.offset] = edit.value
		_, ok := stream_decode_piece(raw)
		testing.expect(t, !ok)
		raw[edit.offset] = old
	}
	oversized := make([]byte, len(raw)+1, context.temp_allocator)
	copy(oversized, raw)
	_, over_ok := stream_decode_piece(oversized)
	testing.expect(t, !over_ok, "piece byte cap enforced separately from total wire size")
	piece.data = data[:]
	testing.expect(t, stream_encode_piece(piece, context.temp_allocator) == nil)
}
