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

@(private = "file")
TEST_STREAM_INPUT_PREFIX :: `{"type":"stream_input","protocol_version":1,"payload":{"stream_id":"` + TEST_STREAM_ID + `","events":[`
@(private = "file")
TEST_STREAM_INPUT_SUFFIX :: `]}}`

@(test)
test_stream_input_round_trip :: proc(t: ^testing.T) {
	events := [?]Stream_Input_Event{
		Stream_Input_Pointer{"down", 0, 0, 1, 1},
		Stream_Input_Pointer{"move", -1, 0.35, 0.75, nil},
		Stream_Input_Pointer{"up", 4, 1, 0, 0},
		Stream_Input_Wheel{-100_000, 1.25, 0.5, 1},
		Stream_Input_Key{"down", "a", "KeyA", 15},
		Stream_Input_Key{"up", "é", "", 0},
		Stream_Input_Text{"漢字: \"hello\"\n\x00"},
		Stream_Input_Text{""},
	}
	raw := stream_encode_input({TEST_STREAM_ID, events[:]}, context.temp_allocator)
	if !testing.expect(t, len(raw) > 0) do return
	got, ok := stream_decode_input(string(raw))
	if !testing.expect(t, ok && got.stream_id == TEST_STREAM_ID && len(got.events) == len(events)) do return
	for want, i in events {
		testing.expect_value(t, got.events[i], want)
	}
	// Viewer JSON can contain both integer and fractional/exponential numbers.
	browser := TEST_STREAM_INPUT_PREFIX + `{"kind":"wheel","dx":0,"dy":1e2,"x":1,"y":0.5}` + TEST_STREAM_INPUT_SUFFIX
	wheel, wheel_ok := stream_decode_input(browser)
	if testing.expect(t, wheel_ok && len(wheel.events) == 1) {
		testing.expect_value(t, wheel.events[0], Stream_Input_Event(Stream_Input_Wheel{0, 100, 1, 0.5}))
	}
}

@(test)
test_stream_input_rejects_malformed_and_out_of_range :: proc(t: ^testing.T) {
	rows := [?]string{
		``,
		`null`,
		`{"kind":"unknown"}`,
		`{"kind":"text","text":null}`,
		`{"kind":"text","text":"\uD800"}`,
		`{"kind":"text","text":"x","x":0}`,
		`{"kind":"text","text":"x","text":"y"}`,
		`{"kind":"text","text":"x","te\u0078t":"y"}`,
		`{"kind":"text","text":"x","":0}`,
		`{"kind":"text","text":"x"},`,
		`{"kind":"pointer","action":"cancel","button":0,"x":0,"y":0}`,
		`{"kind":"pointer","action":"down","button":-1,"x":0,"y":0}`,
		`{"kind":"pointer","action":"down","button":18446744073709551616,"x":0,"y":0}`,
		`{"kind":"pointer","action":"move","button":-1,"buttons":32,"x":0,"y":1}`,
		`{"kind":"pointer","action":"move","button":-1,"buttons":null,"x":0,"y":1}`,
		`{"kind":"pointer","action":"move","button":-1,"buttons":0,"x":0,"unknown":1}`,
		`{"kind":"pointer","action":"move","button":-1,"x":-0.01,"y":1}`,
		`{"kind":"pointer","action":"move","button":-1,"x":0,"y":1.01}`,
		`{"kind":"pointer","action":"move","button":-1,"x":0,"y":NaN}`,
		`{"kind":"pointer","action":"move","button":-1,"x":0,"y":1e999}`,
		`{"kind":"wheel","dx":100001,"dy":0,"x":0,"y":0}`,
		`{"kind":"wheel","dx":0,"dy":"0","x":0,"y":0}`,
		`{"kind":"key","action":"move","key":"x","code":"","modifiers":0}`,
		`{"kind":"key","action":"down","key":"","code":"","modifiers":0}`,
		`{"kind":"key","action":"down","key":"x","code":false,"modifiers":0}`,
		`{"kind":"key","action":"down","key":"x","code":"","modifiers":16}`,
		`{"kind":"key","action":"down","key":"x","code":"","modifiers":0.5}`,
		`{"kind":"key","action":"down","key":"x","code":"","modifiers":0,"y":0}`,
	}
	for row in rows {
		_, ok := stream_decode_input(strings.concatenate({TEST_STREAM_INPUT_PREFIX, row, TEST_STREAM_INPUT_SUFFIX}, context.temp_allocator))
		testing.expect(t, !ok, row)
	}
	valid :: TEST_STREAM_INPUT_PREFIX + `{"kind":"text","text":"x"}` + TEST_STREAM_INPUT_SUFFIX
	bad_envelopes := [?]string{
		valid + "{}",
		valid + "\x00",
		strings.replace_all(valid, `"protocol_version":1`, `"protocol_version":1,"protocol_version":1`, context.temp_allocator) or_else "",
		strings.replace_all(valid, `"protocol_version":1`, `"protocol_version":2`, context.temp_allocator) or_else "",
		strings.replace_all(valid, `"protocol_version":1`, `"protocol_version":1,"extra":true`, context.temp_allocator) or_else "",
		strings.replace_all(valid, `"events":[`, `"extra":true,"events":[`, context.temp_allocator) or_else "",
		strings.replace_all(valid, TEST_STREAM_ID, "not-a-stream-id", context.temp_allocator) or_else "",
	}
	for bad in bad_envelopes {
		_, ok := stream_decode_input(bad)
		testing.expect(t, !ok, bad)
	}
}

@(test)
test_stream_input_bounds :: proc(t: ^testing.T) {
	max_text := strings.repeat("é", STREAM_MAX_INPUT_TEXT_BYTES / 2, context.temp_allocator)
	full: [STREAM_MAX_INPUT_EVENTS + 1]Stream_Input_Event
	for &event in full do event = Stream_Input_Text{max_text}
	raw := stream_encode_input({TEST_STREAM_ID, full[:STREAM_MAX_INPUT_EVENTS]}, context.temp_allocator)
	got, ok := stream_decode_input(string(raw))
	testing.expect(t, ok && len(got.events) == STREAM_MAX_INPUT_EVENTS)
	// The raw cap must also fit a full batch when JSON expands each byte.
	escaped := strings.repeat("\x01", STREAM_MAX_INPUT_TEXT_BYTES, context.temp_allocator)
	for &event in full do event = Stream_Input_Text{escaped}
	escaped_raw := stream_encode_input({TEST_STREAM_ID, full[:STREAM_MAX_INPUT_EVENTS]}, context.temp_allocator)
	escaped_batch, escaped_ok := stream_decode_input(string(escaped_raw))
	if testing.expect(t, escaped_ok && len(escaped_batch.events) == STREAM_MAX_INPUT_EVENTS) {
		testing.expect_value(t, escaped_batch.events[STREAM_MAX_INPUT_EVENTS - 1], Stream_Input_Event(Stream_Input_Text{escaped}))
	}
	testing.expect(t, len(stream_encode_input({TEST_STREAM_ID, full[:]}, context.temp_allocator)) == 0)
	testing.expect(t, len(stream_encode_input({TEST_STREAM_ID, nil}, context.temp_allocator)) == 0)
	text_too_long := strings.concatenate({max_text, "x"}, context.temp_allocator)
	bad_event := [?]Stream_Input_Event{Stream_Input_Text{text_too_long}}
	testing.expect(t, len(stream_encode_input({TEST_STREAM_ID, bad_event[:]}, context.temp_allocator)) == 0)
	key_too_long := strings.repeat("é", STREAM_MAX_INPUT_KEY_BYTES / 2 + 1, context.temp_allocator)
	too_many := strings.repeat(`{"kind":"text","text":"x"},`, STREAM_MAX_INPUT_EVENTS, context.temp_allocator)
	bad_frames := [?]string{
		strings.concatenate({TEST_STREAM_INPUT_PREFIX, `{"kind":"text","text":"`, text_too_long, `"}`, TEST_STREAM_INPUT_SUFFIX}, context.temp_allocator),
		strings.concatenate({TEST_STREAM_INPUT_PREFIX, `{"kind":"key","action":"down","key":"x","code":"`, key_too_long, `","modifiers":0}`, TEST_STREAM_INPUT_SUFFIX}, context.temp_allocator),
		strings.concatenate({TEST_STREAM_INPUT_PREFIX, too_many, `{"kind":"text","text":"x"}`, TEST_STREAM_INPUT_SUFFIX}, context.temp_allocator),
		strings.concatenate({string(raw), strings.repeat(" ", STREAM_MAX_INPUT_BYTES, context.temp_allocator)}, context.temp_allocator),
	}
	for bad in bad_frames {
		_, accepted := stream_decode_input(bad)
		testing.expect(t, !accepted)
	}
}
