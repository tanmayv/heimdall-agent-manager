package main

import "core:strings"
import "core:testing"

// REQ-CLI-3 coverage for `ham-ctl search --help`. Two defects motivated this:
// the help page was unreachable in agent mode (so the agent-mode flag surface
// had no documentation at all), and the root help told agents search "needs
// --hub-url + --user-token", which is false in agent mode.
//
// The acceptance criterion is that the printed flag list matches what search
// ACTUALLY accepts in that mode. Eyeballing cannot hold that line, and a live
// ok:true run does not prove it either, so these tests bind the rendered text to
// search_validate_flags in BOTH directions:
//   - nothing documented is rejected  (help_flag_tokens -> search_validate_flags)
//   - nothing accepted is undocumented (the SEARCH_* tables -> rendered text)
// A flag added to one side without the other fails here.

// help_flag_tokens extracts every `--flag` documented in the indented block under
// "Flags:" — the region that claims "this mode accepts this". Sections reopened at
// column 0 ("Output:", "Auth:", "Examples:") are deliberately outside the scan, so
// prose may name a flag the mode REJECTS (the agent page says --json is user-mode
// only) without that reading as a claim of support.
help_flag_tokens :: proc(text: string) -> [dynamic]string {
	out := make([dynamic]string)
	in_flags := false
	// split_lines_iterator needs an addressable string, and a procedure parameter
	// is not addressable in Odin; copy the slice header into a local first.
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "Flags:" {
			in_flags = true
			continue
		}
		if !in_flags do continue
		// A non-indented, non-empty line ends the flag block.
		if line != "" && !strings.has_prefix(line, " ") do break
		// strings.fields allocates the slice of subslices; the subslices themselves
		// point into `line`, so freeing the slice alone is correct and keeps the
		// tracking allocator's report clean.
		words := strings.fields(line)
		defer delete(words)
		for raw in words {
			tok := strings.trim_right(raw, ",.;:)")
			if strings.has_prefix(tok, "--") do append(&out, tok)
		}
	}
	return out
}

@(test)
test_search_help_documents_only_accepted_flags :: proc(t: ^testing.T) {
	for agent_mode in ([?]bool{false, true}) {
		text := search_help_text(agent_mode)
		defer delete(text)
		tokens := help_flag_tokens(text)
		defer delete(tokens)
		testing.expect(t, len(tokens) > 0, "the Flags block documents at least one flag")
		for tok in tokens {
			args := []string{tok, "value"}
			testing.expectf(
				t,
				search_validate_flags(args, agent_mode) == "",
				"help documents %s but search rejects it (agent_mode=%v)",
				tok,
				agent_mode,
			)
		}
	}
}

@(test)
test_search_help_documents_every_accepted_flag :: proc(t: ^testing.T) {
	common := SEARCH_COMMON_VALUE_FLAGS
	agent_only := SEARCH_AGENT_ONLY_VALUE_FLAGS
	user_only := SEARCH_USER_ONLY_BOOL_FLAGS

	for agent_mode in ([?]bool{false, true}) {
		text := search_help_text(agent_mode)
		defer delete(text)
		for flag in common {
			testing.expectf(t, strings.contains(text, flag), "%s undocumented (agent_mode=%v)", flag, agent_mode)
		}
	}

	agent_text := search_help_text(true)
	defer delete(agent_text)
	user_text := search_help_text(false)
	defer delete(user_text)

	// Mode-only flags must be documented by the mode that accepts them. --since is
	// an accepted alias of --cursor rather than a separate concept, so it is named
	// in the --cursor line instead of getting one of its own.
	for flag in agent_only {
		testing.expectf(t, strings.contains(agent_text, flag), "agent-only %s undocumented in agent help", flag)
	}
	for flag in user_only {
		testing.expectf(t, strings.contains(user_text, flag), "user-only %s undocumented in user help", flag)
	}

	// …and must NOT appear in the Flags block of the mode that rejects them.
	agent_tokens := help_flag_tokens(agent_text)
	defer delete(agent_tokens)
	for tok in agent_tokens {
		testing.expectf(t, tok != "--json", "--json is rejected in agent mode but the agent Flags block lists it")
	}
	user_tokens := help_flag_tokens(user_text)
	defer delete(user_tokens)
	for tok in user_tokens {
		testing.expectf(t, tok != "--cursor" && tok != "--since", "%s is rejected in user mode but the user Flags block lists it", tok)
	}
}

@(test)
test_search_help_lists_all_eleven_scopes :: proc(t: ^testing.T) {
	// REQ-CLI-5 made an unknown scope a validation error, so the help must state
	// the whole vocabulary it is validated against. `message` is real and is the
	// one that keeps going missing.
	scopes := [?]string{
		"conversation", "message", "agent", "agent_instance", "task-chain",
		"task", "comment", "project", "artifact", "memory", "skill",
	}
	for agent_mode in ([?]bool{false, true}) {
		text := search_help_text(agent_mode)
		defer delete(text)
		for scope in scopes {
			testing.expectf(t, strings.contains(text, scope), "scope %s missing from help (agent_mode=%v)", scope, agent_mode)
		}
	}
}

@(test)
test_search_help_auth_line_is_mode_correct :: proc(t: ^testing.T) {
	// The defect this task exists for: telling an agent it needs a user token.
	agent_text := search_help_text(true)
	defer delete(agent_text)
	testing.expect(t, strings.contains(agent_text, "HEIMDALL_AGENT_TOKEN"), "agent help names the token the agent actually has")
	testing.expect(t, !strings.contains(agent_text, "--user-token"), "agent help must not ask an agent for a user token")
	testing.expect(t, !strings.contains(agent_text, "--hub-url"), "agent help must not ask an agent for a hub url")

	user_text := search_help_text(false)
	defer delete(user_text)
	testing.expect(t, strings.contains(user_text, "--user-token"), "user help still states the user-mode credential")
	testing.expect(t, strings.contains(user_text, "--hub-url"), "user help still states the user-mode hub url")
}
