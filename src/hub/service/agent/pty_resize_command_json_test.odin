package agent

import "core:strings"
import "core:testing"

@(test)
agent_pty_resize_command_json_formats_payload :: proc(t: ^testing.T) {
	got := agent_pty_resize_command_json("cmd_resize_123", "inst_456", 25, 110)
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"type\":\"shell_pty_resize\"") || strings.contains(got, "\"type\":\"agent_pty_resize\""), "type field must be shell_pty_resize or agent_pty_resize")
	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_resize_123\""), "command_id must match")
	testing.expect(t, strings.contains(got, "\"shell_id\":\"inst_456\""), "shell_id must match")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_456\""), "agent_instance_id must match")
	testing.expect(t, strings.contains(got, "\"rows\":25"), "rows field must match")
	testing.expect(t, strings.contains(got, "\"cols\":110"), "cols field must match")
}

@(test)
agent_pty_resize_command_json_handles_special_characters :: proc(t: ^testing.T) {
	got := agent_pty_resize_command_json("cmd_resize_\"special\"", "inst_\"quoted\"", 30, 80)
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"command_id\":\"cmd_resize_\\\"special\\\"\""), "quotes in command_id must be escaped")
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_\\\"quoted\\\"\""), "quotes in instance_id must be escaped")
	testing.expect(t, strings.contains(got, "\"rows\":30"), "rows field must match")
	testing.expect(t, strings.contains(got, "\"cols\":80"), "cols field must match")
}
