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
