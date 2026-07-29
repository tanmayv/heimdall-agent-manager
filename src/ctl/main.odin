package main

import "core:fmt"
import "core:os"
import "core:strings"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--version" {
		fmt.println("ham-ctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}

	cmd := command_tokens(os.args)
	defer delete(cmd)
	if len(cmd) == 0 {
		print_usage(cfg_lib.config_path_from_args(os.args), "")
		return
	}

	if cmd[0] == "health" {
		url := hub_user_mode_url(os.args)
		if url == "" do url = "http://127.0.0.1:49328"
		tok := hub_user_mode_token(os.args)
		ctl_hub_request(strings.trim_right(url, "/"), tok, "GET", "/api/v1/health", "")
		return
	}

	if cmd[0] == "help" {
		ctl_help(cmd[:])
		return
	}

		if cmd[0] == "task-chains" || cmd[0] == "task-chain" || cmd[0] == "chains" || cmd[0] == "chain" {
		ctl_task_chains_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "tasks" || cmd[0] == "task" {
		ctl_tasks_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "hub" || has_flag(os.args, "--hub") {
		ctl_hub_user_mode(cmd[:], os.args)
		return
	}

	if cmd[0] == "agent" || has_flag(os.args, "--agent-mode") {
		ctl_agent_mode(cmd[:], os.args)
		return
	}

	// Convenience for Bridge-launched agents: the managed .heimdall/bin/ham-ctl
	// wrapper exports local endpoint/token env, so allow `ham-ctl agents live`
	// without requiring the extra `agent` namespace.
	if cmd[0] == "agents" || cmd[0] == "instances" || cmd[0] == "artifacts" || cmd[0] == "artifact" {
		if agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != "" {
			ctl_agent_mode(cmd[:], os.args)
			return
		}
	}

	if cmd[0] == "start-success" {
		if agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != "" {
			agent_cmd := [?]string{"agent", "start-success"}
			ctl_agent_mode(agent_cmd[:], os.args)
			return
		}
		fmt.println(`{"ok":false,"message":"start-success is only available as 'ham-ctl agent start-success' inside a Bridge-launched agent"}`)
		os.exit(1)
	}

	print_usage(cfg_lib.config_path_from_args(os.args), "")
}
