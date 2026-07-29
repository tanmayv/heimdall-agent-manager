package main

import "core:strings"
import cfg_lib "odin_test:lib/config"

command_tokens :: proc(args: []string) -> [dynamic]string {
	cmd := make([dynamic]string)
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == cfg_lib.CONFIG_PATH_FLAG || arg == "--as" || arg == "--daemon-url" || arg == "--hub-url" || arg == "--bridge-endpoint" || arg == "--agent-token" || arg == "--wrapper-bin" || arg == "--agent" || arg == "--agent-id" || arg == "--instance-id" || arg == "--bridge-id" || arg == "--provider" || arg == "--tier" || arg == "--conversation-id" || arg == "--chat-id" || arg == "--initial-body" || arg == "--slug" || arg == "--instructions" || arg == "--message" || arg == "--coordinator-agent-id" || arg == "--token" || arg == "--user-token" || arg == "--to" || arg == "--body" || arg == "--limit" || arg == "--task-id" || arg == "--task" || arg == "--chain-id" || arg == "--chain" || arg == "--status" || arg == "--agent-instance-id" || arg == "--role" || arg == "--use" || arg == "--final-summary" || arg == "--summary" || arg == "--user-id" || arg == "--client-instance-id" || arg == "--message-id" || arg == "--result" || arg == "--comment" || arg == "--title" || arg == "--description" || arg == "--goal" || arg == "--priority" || arg == "--assignee-agent-instance-id" || arg == "--assignee" || arg == "--reviewer-agent-instance-id" || arg == "--coordinator-agent-instance-id" || arg == "--coordinator" || arg == "--reviewer" || arg == "--comment-id" || arg == "--depends-on" || arg == "--subject-agent" || arg == "--subject-key" || arg == "--scope" || arg == "--type" || arg == "--memory-id" || arg == "--memory" || arg == "--proposal-id" || arg == "--decision" || arg == "--reason" || arg == "--evidence" || arg == "--source-task-id" || arg == "--source-task" || arg == "--expected-version" || arg == "--project-id" || arg == "--project" || arg == "--repo-url" || arg == "--repo" || arg == "--vcs-kind" || arg == "--default-path" || arg == "--path" || arg == "--content-type" || arg == "--name" || arg == "--anchor-type" || arg == "--anchor-value" || arg == "--anchor-note" || arg == "--cursor" || arg == "--since" || arg == "--target-project-id" || arg == "--target-role" || arg == "--target-team-kind" || arg == "--team" || arg == "--team-id" || arg == "--project-ids" || arg == "--role-key" || arg == "--role-keys" || arg == "--task-chain-type" || arg == "--task-chain-types" || arg == "--template-key" || arg == "--template" || arg == "--file" || arg == "--out" || arg == "--artifact-id" || arg == "--artifact" || arg == "--kind" || arg == "--mime" || arg == "--creator-id" || arg == "--origin-kind" || arg == "--origin-ref" || arg == "--data" || arg == "--version" || arg == "--change-reason" || arg == "--annotation-id" || arg == "--context-type" || arg == "--context-json" {
			i += 1
			continue
		}
		if arg == "--remote" {
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") do i += 1
			continue
		}
		if strings.has_prefix(arg, "--") do continue
		append(&cmd, arg)
	}
	return cmd
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] == name do return args[i + 1]
	}
	return fallback
}

has_flag :: proc(args: []string, name: string) -> bool {
	for arg in args {
		if arg == name do return true
	}
	return false
}
