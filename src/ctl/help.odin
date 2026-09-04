package main

import "core:fmt"
import "core:os"
import "core:strings"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

ctl_help :: proc(cmd: []string) {
	if len(cmd) >= 2 && cmd[1] == "work-guide" {
		fmt.println(strings.trim_space(#load("../prompts/bootstrap_profile_guidance.md", string)))
		return
	}
	if len(cmd) >= 2 && cmd[1] == "hub" { print_hub_help(cmd[2:]); return }
	// `help agent` and any group name render the skill-style agent help.
	if len(cmd) >= 2 && cmd[1] == "agent" { print_agent_help(cmd[2:]); return }
	if len(cmd) >= 2 {
		switch cmd[1] {
		case "bridge", "bridges", "agents", "task-chain", "task-chains",
		     "task", "tasks", "chat", "chats", "artifact", "artifacts",
		     "memory", "context", "start-success":
			print_agent_help(cmd[1:]); return
		}
	}
	print_usage(cfg_lib.config_path_from_args(os.args), "")
}

// print_usage renders the Level-1 skill-style overview (agent API v2). The
// canonical text lives in print_help_overview (agent_mode.odin) so `ham-ctl`,
// `ham-ctl help`, and `ham-ctl --help` all show the same thing.
print_usage :: proc(config_path, daemon_url: string) {
	_ = config_path
	_ = daemon_url
	print_help_overview()
	fmt.println("")
	fmt.println("OTHER")
	fmt.println("  hub    Hub /api/v1 user commands (needs --hub-url + --user-token)")
	fmt.println("  help   ham-ctl <group> --help | ham-ctl help hub | ham-ctl help work-guide")
}

