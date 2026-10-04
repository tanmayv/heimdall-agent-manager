package agent

import "core:strings"
import "core:testing"

@(test)
agent_pty_input_command_json_formats_payload :: proc(t: ^testing.T) {
	got := agent_pty_input_command_json("cmd_123", "inst_456", "ls -la\n")
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"type\":\"shell_pty_input\"") || strings.contains(got, "\"type\":\"agent_pty_input\""), "type field must be shell_pty_input or agent_pty_input")
	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_123\""), "command_id must match")
	testing.expect(t, strings.contains(got, "\"shell_id\":\"inst_456\""), "shell_id must match")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_456\""), "agent_instance_id must match")
	testing.expect(t, strings.contains(got, "\"data\":\"ls -la\\n\""), "data field must be JSON-escaped")
}

@(test)
agent_pty_input_command_json_handles_special_characters :: proc(t: ^testing.T) {
	// Special characters: control characters, quotes, backslashes
	got := agent_pty_input_command_json("cmd_special", "inst_special", "\x03\x1b[A\"hello\\world\"")
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_special\""), "command_id must match")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_special\""), "agent_instance_id must match")
	testing.expect(t, strings.contains(got, "\\u0003"), "control character 0x03 must be escaped")
	testing.expect(t, strings.contains(got, "\\\"hello\\\\world\\\""), "quotes and backslashes must be escaped")
}

// REQ-PANE-INPUT-1/2: the agent pane relays vault ciphertext to the bridge rather than
// decrypting it (the Hub has no vault key). These pin the emitted wire shape, which the
// bridge reads in bridge_hub_handle_shell_pty_input (src/bridge/hub_runtime_client.odin:1327).

@(test)
agent_pty_input_command_json_relays_enc_b64 :: proc(t: ^testing.T) {
	got := agent_pty_input_command_json("cmd_enc", "inst_enc", "", "QUJDREVG")
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"enc_b64\":\"QUJDREVG\""), "enc_b64 must be relayed verbatim")
	// The bridge also accepts the armored data_b64; send both so an older bridge still works.
	testing.expect(t, strings.contains(got, "\"data_b64\":\"vault:v1:QUJDREVG\""), "armored data_b64 must accompany enc_b64")
	testing.expect(t, strings.contains(got, "\"data\":\"\""), "no plaintext may be sent alongside ciphertext")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_enc\""), "bridge resolves the pty by agent_instance_id")
}

@(test)
agent_pty_input_command_json_does_not_double_prefix_armored_enc_b64 :: proc(t: ^testing.T) {
	// An already-armored value must not become "vault:v1:vault:v1:...".
	got := agent_pty_input_command_json("cmd_armored", "inst_armored", "", "vault:v1:QUJDREVG")
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"data_b64\":\"vault:v1:QUJDREVG\""), "armor prefix must not be doubled")
	testing.expect(t, !strings.contains(got, "vault:v1:vault:v1:"), "armor prefix must not be doubled")
}

@(test)
agent_pty_input_command_json_omits_enc_b64_when_plain :: proc(t: ^testing.T) {
	// REQ-PANE-INPUT-4: the unencrypted path emits exactly what it emitted before the fix.
	got := agent_pty_input_command_json("cmd_plain", "inst_plain", "ls\n")
	defer delete(got)

	testing.expect(t, !strings.contains(got, "enc_b64"), "plain input must not carry enc_b64")
	testing.expect(t, !strings.contains(got, "data_b64"), "plain input must not carry data_b64")
	testing.expect(t, strings.contains(got, "\"data\":\"ls\\n\""), "plaintext data must be preserved")
}
