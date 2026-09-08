package http

import "core:strings"
import "core:testing"

@(test)
fig_workspaces_command_json_contract :: proc(t: ^testing.T) {
	cmd := Bridge_Fig_Command{
		command_type = "fig_list_workspaces",
	}
	out := bridge_fig_command_json(cmd, "cmd_fig_1")
	testing.expect(t, strings.contains(out, "\"type\":\"fig_list_workspaces\""), "type present")
	testing.expect(t, strings.contains(out, "\"command_id\":\"cmd_fig_1\""), "command_id present")
}

@(test)
fig_create_workspace_command_json_contract :: proc(t: ^testing.T) {
	cmd := Bridge_Fig_Command{
		command_type = "fig_create_workspace",
		workspace = "new-workspace",
	}
	out := bridge_fig_command_json(cmd, "cmd_fig_2")
	testing.expect(t, strings.contains(out, "\"type\":\"fig_create_workspace\""), "type present")
	testing.expect(t, strings.contains(out, "\"command_id\":\"cmd_fig_2\""), "command_id present")
	testing.expect(t, strings.contains(out, "\"workspace\":\"new-workspace\""), "workspace present")
}

@(test)
fig_list_dir_command_json_contract :: proc(t: ^testing.T) {
	cmd := Bridge_Fig_Command{
		command_type = "fig_list_dir",
		workspace = "heimdall",
		path = "src/bridge",
		cursor = "eyJvZmZzZXQiOjUwfQ==",
		limit = 50,
		send_limit = true,
	}
	out := bridge_fig_command_json(cmd, "cmd_fig_3")
	testing.expect(t, strings.contains(out, "\"type\":\"fig_list_dir\""), "type present")
	testing.expect(t, strings.contains(out, "\"command_id\":\"cmd_fig_3\""), "command_id present")
	testing.expect(t, strings.contains(out, "\"workspace\":\"heimdall\""), "workspace present")
	testing.expect(t, strings.contains(out, "\"path\":\"src/bridge\""), "path present")
	testing.expect(t, strings.contains(out, "\"cursor\":\"eyJvZmZzZXQiOjUwfQ==\""), "cursor present")
	testing.expect(t, strings.contains(out, "\"limit\":50"), "limit present")
}
