package main

import "core:testing"

// REQ-CLI-4 coverage for the search unknown-flag rejector. Before this, `search`
// parsed only the flags it recognised and ignored the rest, so
// `search rag --zzz-invented foo` returned ok:true with the exact unflagged
// baseline result set — a typo'd flag was indistinguishable from a working one.
//
// search_validate_flags returns the first offending argument, or "" when the
// whole argument list is acceptable.

@(test)
test_search_flags_accepts_every_real_flag :: proc(t: ^testing.T) {
	args := []string{
		"--scope", "task,comment", "--limit", "5", "--exclude", "smoke",
		"--task-ids", "task_1", "--chain-ids", "chain_1",
		"--project-ids", "proj_1", "--conversation-ids", "chat_1",
		"--not-in-task-ids", "task_2", "--not-in-chain-ids", "chain_2",
		"--not-in-project-ids", "proj_2", "--not-in-conversation-ids", "chat_2",
	}
	testing.expect(t, search_validate_flags(args, false) == "", "user mode accepts every real flag")
	testing.expect(t, search_validate_flags(args, true) == "", "agent mode accepts every real flag")
}

@(test)
test_search_flags_rejects_unknown :: proc(t: ^testing.T) {
	args := []string{"--scope", "task", "--zzz-invented", "foo"}
	testing.expect(t, search_validate_flags(args, false) == "--zzz-invented", "user mode rejects unknown flag")
	testing.expect(t, search_validate_flags(args, true) == "--zzz-invented", "agent mode rejects unknown flag")
}

// The globals must stay accepted or ordinary invocations break.
@(test)
test_search_flags_allows_globals :: proc(t: ^testing.T) {
	args := []string{"--hub", "--hub-url", "http://localhost:8080", "--user-token", "tok", "--scope", "task"}
	testing.expect(t, search_validate_flags(args, false) == "", "globals stay valid in user mode")
	agent := []string{"--agent-mode", "--bridge-endpoint", "http://127.0.0.1:1", "--agent-token", "tok"}
	testing.expect(t, search_validate_flags(agent, true) == "", "globals stay valid in agent mode")
	testing.expect(t, search_validate_flags([]string{"--config", "/tmp/c.json", "--as", "alice"}, false) == "", "--config/--as stay valid")
	testing.expect(t, search_validate_flags([]string{"--help"}, false) == "", "--help stays valid")
	testing.expect(t, search_validate_flags([]string{"-h"}, false) == "", "-h stays valid")
}

// --json is user mode only; --cursor/--since are agent mode only. Each must be
// rejected in the mode that does not read it, or it is silently ignored again.
@(test)
test_search_flags_mode_specific :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"--json"}, false) == "", "--json valid in user mode")
	testing.expect(t, search_validate_flags([]string{"--json"}, true) == "--json", "--json rejected in agent mode")
	testing.expect(t, search_validate_flags([]string{"--cursor", "c"}, true) == "", "--cursor valid in agent mode")
	testing.expect(t, search_validate_flags([]string{"--since", "c"}, true) == "", "--since alias valid in agent mode")
	testing.expect(t, search_validate_flags([]string{"--cursor", "c"}, false) == "--cursor", "--cursor rejected in user mode")
}

// A flag VALUE that happens to look like a flag must not be scanned as one.
@(test)
test_search_flags_value_not_scanned :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"--exclude", "--weird"}, false) == "", "value is consumed, not scanned")
	testing.expect(t, search_validate_flags([]string{"--scope", "--zzz"}, false) == "", "scope value consumed")
}

// --flag=value is not a form this CLI parses; it must be reported rather than
// silently taking the default.
@(test)
test_search_flags_rejects_equals_form :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"--scope=task"}, false) == "--scope=task", "--scope=task reported")
}

// Positional arguments (the query) are not flags and must pass through.
@(test)
test_search_flags_ignores_positionals :: proc(t: ^testing.T) {
	testing.expect(t, search_validate_flags([]string{"search", "rag"}, false) == "", "positionals ignored")
	testing.expect(t, search_validate_flags([]string{}, false) == "", "empty args accepted")
}
