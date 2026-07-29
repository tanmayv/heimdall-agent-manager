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
	if len(cmd) >= 2 && cmd[1] == "agent" { print_agent_help(cmd[2:]); return }
	if len(cmd) >= 2 && cmd[1] == "hub" { print_hub_help(cmd[2:]); return }
	print_usage(cfg_lib.config_path_from_args(os.args), "")
}

print_usage :: proc(config_path, daemon_url: string) {
	_ = config_path
	_ = daemon_url
	fmt.println("ham-ctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("command families:")
	fmt.println("  task-chains Unified task chains commands (user or agent): list, create, show, update, members, add-agent, publish, complete")
	fmt.println("  tasks       Unified task commands (user or agent): list, create, update, status, done, depend, cancel, comment, comments, vote, votes, nudge")
	fmt.println("  agent       Bridge-local agent commands: context, start-success, chat, tasks, artifacts, memory")
	fmt.println("  hub         Hub /api/v1 user commands: me, agents, launch, chats, tasks, task-chains, projects, artifacts, memories")
	fmt.println("  help    Show detailed help: ham-ctl help agent | ham-ctl help hub | ham-ctl help work-guide")
	fmt.println("examples:")
	fmt.println("  ham-ctl agent context")
	fmt.println("  ham-ctl agent chat read --since 2026-07-27T10:00:00Z")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... me")
	fmt.println("global flags: --version, --help")
}

