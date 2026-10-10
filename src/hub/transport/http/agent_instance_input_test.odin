package http

import "core:testing"

@(test)
test_json_string_unicode_escapes :: proc(t: ^testing.T) {
	body := `{"data":"hello\u0020world\u000a\u001b[31mred\u001b[0m"}`
	parsed := json_string(body, "data")
	defer delete(parsed)

	testing.expect_value(t, parsed, "hello world\n\x1b[31mred\x1b[0m")
}

@(test)
test_json_string_ctrl_c :: proc(t: ^testing.T) {
	body := `{"data":"\u0003"}`
	parsed := json_string(body, "data")
	defer delete(parsed)

	testing.expect_value(t, parsed, "\x03")
}

@(test)
test_input_frame_single_encrypted_payload :: proc(t: ^testing.T) {
	body := `{"type":"input","data_b64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==","is_encrypted":true}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)
	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
	testing.expect_value(t, frame.plain, "")
}

@(test)
test_input_frame_plain_data_b64_unchanged :: proc(t: ^testing.T) {
	frame := shell_stream_decode_input_frame(`{"type":"input","data_b64":"bHMgLWxhCg==","is_encrypted":false}`)
	defer shell_stream_input_destroy(&frame)
	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "ls -la\n")
}

@(test)
test_input_frame_plain_data_b64_ctrl_c :: proc(t: ^testing.T) {
	frame := shell_stream_decode_input_frame(`{"type":"input","data_b64":"Aw==","is_encrypted":false}`)
	defer shell_stream_input_destroy(&frame)
	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "\x03")
}

@(test)
test_input_frame_requires_unambiguous_flag_and_payload :: proc(t: ^testing.T) {
	bodies := []string{
		`{"type":"input","enc_b64":"QUJD"}`,
		`{"type":"input","data_b64":"QUJD"}`,
		`{"type":"input","data_b64":"QUJD","is_encrypted":"false"}`,
		`{"type":"input","data_b64":"vault:v1:QUJD","is_encrypted":true}`,
		`{"type":"input","data_b64":"not!base64","is_encrypted":false}`,
		`{"type":"input","data_b64":"QUJD","is_encrypted":true}`,
	}
	for body in bodies {
		frame := shell_stream_decode_input_frame(body)
		testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Undecodable)
		testing.expect_value(t, frame.plain, "")
		testing.expect_value(t, frame.armored, "")
		testing.expect(t, frame.reason != "")
		shell_stream_input_destroy(&frame)
	}
}
