package agent_runtime

import "core:strings"
import "core:testing"

@(test)
startup_prompt_preserves_bootstrap_and_runtime :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for command in ([]string{"{ctl_bin} agent start-success", "{ctl_bin} start-success", "{ctl_bin} --token {token} start-success"}) {
		profile := Agent_Profile{starter_prompt = strings.concatenate({"First, run: ", command, ". Then read AGENTS.md for context."}), extension_expected = true}
		out := render_starter_prompt_for_agent(profile, "http://hub", "tok", "inst")
		testing.expect(t, strings.has_prefix(out, "Then take your task lease with `./bin/ham-ctl lease next`, read MEMORY.md and TASK.md"), "lease instruction replaces the bootstrap read")
		testing.expect(t, !strings.contains(out, "AGENTS.md"), "no bootstrap read for an auto-loading harness")
		testing.expect(t, !strings.contains(out, "start-success"), "remove the known startup instruction")
		testing.expect(t, strings.contains(out, "Your agent token is `tok`") && strings.contains(out, "instance id is `inst`"), "retain runtime identity")
	}
}

// A Hub older than its bridge renders the pre-bin/ shim path; the known sentence is
// still stripped when the extension reports readiness itself.
@(test)
startup_prompt_strips_legacy_rendered_instruction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: ./.heimdall/bin/ham-ctl agent start-success. Then read AGENTS.md for context.", extension_expected = true}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, !strings.contains(out, "First, run:"), "legacy sentence removed")
	testing.expect(t, strings.contains(out, "`./bin/ham-ctl lease next`"), "lease instruction present")
}

@(test)
startup_prompt_unknown_extension_keeps_instruction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context."}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, strings.contains(out, "First, run: ./bin/ham-ctl agent start-success."), "absent/unknown extension keeps command")
	testing.expect(t, strings.contains(out, "Then take your task lease with `./bin/ham-ctl lease next`"), "lease instruction present")
	testing.expect(t, !strings.contains(out, "read AGENTS.md"), "bootstrap read replaced")
}

@(test)
startup_prompt_custom_prose_is_preserved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Read AGENTS.md. The start-success command is documented there. Preserve this custom guidance."
	out := render_starter_prompt_for_agent(Agent_Profile{starter_prompt = text, extension_expected = true}, "", "tok", "inst")
	testing.expect(t, strings.has_prefix(out, text), "do not strip lines or arbitrary command mentions")
}

@(test)
startup_prompt_claude_sentence_replaced :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: {ctl_bin} agent start-success. Then read your bootstrap file (CLAUDE.md) for context, identity, and what you can do."}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, strings.has_prefix(out, "First, run: ./bin/ham-ctl agent start-success. Then take your task lease with `./bin/ham-ctl lease next`, read MEMORY.md and TASK.md, and start working on the leased task;"), out)
	testing.expect(t, !strings.contains(out, "bootstrap file"), "bootstrap read gone")
	testing.expect(t, !strings.contains(out, "{ctl_bin}"), "placeholder rendered")
}

@(test)
startup_prompt_keep_bootstrap_read_adds_lease_after_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.", keep_bootstrap_read = true}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, strings.contains(out, "Then read AGENTS.md for context. Then take your task lease with `./bin/ham-ctl lease next`"), out)
}

@(test)
startup_prompt_custom_prose_gets_lease_instruction_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Do the custom thing."
	out := render_starter_prompt_for_agent(Agent_Profile{starter_prompt = text}, "", "tok", "inst")
	testing.expect(t, strings.has_prefix(out, "Do the custom thing. Then take your task lease"), out)
	again := render_starter_prompt_for_agent(Agent_Profile{starter_prompt = out}, "", "tok", "inst")
	testing.expect_value(t, strings.count(again, "lease next"), 1)
}

@(test)
startup_prompt_stripped_start_success_still_has_lease :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	profile := Agent_Profile{starter_prompt = "First, run: {ctl_bin} agent start-success. Then read your bootstrap file (CLAUDE.md) for context, identity, and what you can do.", extension_expected = true}
	out := render_starter_prompt_for_agent(profile, "", "tok", "inst")
	testing.expect(t, strings.has_prefix(out, "Then take your task lease with `./bin/ham-ctl lease next`"), out)
}

@(test)
acp_starter_prompt_renders_ctl_and_lease :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	starter := "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context."
	out := render_acp_starter_prompt(starter, false)
	testing.expect(t, strings.has_prefix(out, "First, run: ./bin/ham-ctl agent start-success. Then take your task lease with `./bin/ham-ctl lease next`"), out)
	testing.expect(t, !strings.contains(out, "{") && !strings.contains(out, "AGENTS.md"), out)
	linked := render_acp_starter_prompt(starter, true)
	testing.expect(t, strings.contains(linked, "Then read AGENTS.md for context. Then take your task lease"), linked)
}
