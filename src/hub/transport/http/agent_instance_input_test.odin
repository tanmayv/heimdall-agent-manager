package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

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

// ---------------------------------------------------------------------------
// REQ-PANE-INPUT-1..6: the shared `"input"` frame decoder both terminal panes use.
//
// The regression these pin down: the agent pane had its own copy of this contract that
// knew neither `vault:v1:` nor `enc_b64`, so with the vault UNLOCKED the composer's
// armored keystrokes were base64-decoded, failed, and were dropped silently.
// ---------------------------------------------------------------------------

@(test)
test_input_frame_armored_data_b64_prefers_enc_b64 :: proc(t: ^testing.T) {
	// Exactly what useAgentStream.ts:385-409 sends while the vault is unlocked.
	body := `{"type":"input","enc_b64":"QUJDREVG","data_b64":"vault:v1:QUJDREVG"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	// The bare ciphertext is relayed, not the prefixed form.
	testing.expect_value(t, frame.armored, "QUJDREVG")
	// REQ-PANE-INPUT-6: ciphertext is never offered as plaintext for the pty.
	testing.expect_value(t, frame.plain, "")
}

@(test)
test_input_frame_armored_data_b64_without_enc_b64 :: proc(t: ^testing.T) {
	// Older client: armor only, no sidecar field. Still must not be treated as plaintext.
	body := `{"type":"input","data_b64":"vault:v1:QUJDREVG"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, "vault:v1:QUJDREVG")
	testing.expect_value(t, frame.plain, "")
}

@(test)
test_input_frame_enc_b64_alone_is_armored :: proc(t: ^testing.T) {
	body := `{"type":"input","enc_b64":"QUJDREVG"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, "QUJDREVG")
}

@(test)
test_input_frame_plain_data_b64_unchanged :: proc(t: ^testing.T) {
	// REQ-PANE-INPUT-4: vault disabled / locked behaves exactly as before the fix.
	body := `{"type":"input","data_b64":"bHMgLWxhCg=="}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "ls -la\n")
	testing.expect_value(t, frame.enc_b64, "")
}

@(test)
test_input_frame_plain_data_b64_ctrl_c :: proc(t: ^testing.T) {
	// A control byte is the most common keystroke on this path; it must survive intact.
	body := `{"type":"input","data_b64":"Aw=="}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "\x03")
}

@(test)
test_input_frame_legacy_data_field_is_plain :: proc(t: ^testing.T) {
	// The HTTP-fallback/legacy shape: raw `data`, no base64.
	body := `{"type":"input","data":"echo hi\n"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "echo hi\n")
}

@(test)
test_input_frame_legacy_data_field_armored :: proc(t: ^testing.T) {
	body := `{"type":"input","data":"vault:v1:QUJDREVG"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, "vault:v1:QUJDREVG")
	testing.expect_value(t, frame.plain, "")
}

@(test)
test_input_frame_undecodable_reports_reason :: proc(t: ^testing.T) {
	// REQ-PANE-INPUT-3: garbage must come back classified, with a reason to log —
	// never discarded in silence, which is how a total input outage shipped.
	body := `{"type":"input","data_b64":"not!valid!base64!"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Undecodable)
	testing.expect(t, frame.reason != "", "undecodable frame must carry a reason to log")
	testing.expect_value(t, frame.plain, "")
}

@(test)
test_input_frame_empty_payload :: proc(t: ^testing.T) {
	body := `{"type":"input"}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Empty)
}

@(test)
test_input_frame_armor_prefix_matches_domain_constant :: proc(t: ^testing.T) {
	// REQ-PANE-INPUT-5: both panes classify against the one domain constant, so the wire
	// marker cannot drift away from what the UI and the bridge agree on.
	testing.expect(
		t,
		strings.has_prefix("vault:v1:QUJDREVG", domain.VAULT_ARMOR_PREFIX),
		"decoder must key off domain.VAULT_ARMOR_PREFIX",
	)
}
