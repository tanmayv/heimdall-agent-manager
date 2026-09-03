package main

import "core:strings"
import "core:testing"

// BT-3: unit tests for the single-template substitution + role-conditional engine
// (bridge_bootstrap_eval_role_sections + bridge_bootstrap_substitute_scalars).

@(test)
bt3_scalar_substitution_basic :: proc(t: ^testing.T) {
	names := []string{"agent_name", "instance_id", "project_name"}
	values := []string{"Backend Agent", "inst_1", "Heimdall"}
	got := bridge_bootstrap_substitute_scalars("Agent: {agent_name}\nInstance: {instance_id}\n- Name: {project_name}", names, values)
	defer delete(got)
	testing.expect_value(t, got, "Agent: Backend Agent\nInstance: inst_1\n- Name: Heimdall")
}

@(test)
bt3_scalar_empty_value_leaves_heading :: proc(t: ^testing.T) {
	// Empty value substitutes to empty; the static "- Name: " prefix stays (BT-1 §3).
	names := []string{"project_name"}
	values := []string{""}
	got := bridge_bootstrap_substitute_scalars("- Name: {project_name}", names, values)
	defer delete(got)
	testing.expect_value(t, got, "- Name: ")
}

@(test)
bt3_scalar_unknown_placeholder_fails_soft :: proc(t: ^testing.T) {
	// Unknown placeholder-looking token -> empty; non-placeholder braces kept verbatim.
	got := bridge_bootstrap_substitute_scalars("a={unknown_var} b={not a key}", nil, nil)
	defer delete(got)
	testing.expect_value(t, got, "a= b={not a key}")
}

@(test)
bt3_scalar_keeps_code_braces :: proc(t: ^testing.T) {
	// JSON/code braces must survive (they are not simple placeholder tokens).
	got := bridge_bootstrap_substitute_scalars("json: {\"k\": 1}", nil, nil)
	defer delete(got)
	testing.expect_value(t, got, "json: {\"k\": 1}")
}

@(test)
bt3_role_coordinator_kept_others_dropped :: proc(t: ^testing.T) {
	tpl := "H\n{{#is_coordinator}}\nCOORD\n{{/is_coordinator}}{{#is_worker}}\nWORK\n{{/is_worker}}{{#is_reviewer}}\nREVIEW\n{{/is_reviewer}}T"
	got := bridge_bootstrap_eval_role_sections(tpl, true, false, false)
	defer delete(got)
	testing.expect_value(t, got, "H\nCOORD\nT")
}

@(test)
bt3_role_worker_kept :: proc(t: ^testing.T) {
	tpl := "H\n{{#is_coordinator}}\nCOORD\n{{/is_coordinator}}{{#is_worker}}\nWORK\n{{/is_worker}}{{#is_reviewer}}\nREVIEW\n{{/is_reviewer}}T"
	got := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	defer delete(got)
	testing.expect_value(t, got, "H\nWORK\nT")
}

@(test)
bt3_role_reviewer_kept :: proc(t: ^testing.T) {
	tpl := "H\n{{#is_coordinator}}\nCOORD\n{{/is_coordinator}}{{#is_worker}}\nWORK\n{{/is_worker}}{{#is_reviewer}}\nREVIEW\n{{/is_reviewer}}T"
	got := bridge_bootstrap_eval_role_sections(tpl, false, false, true)
	defer delete(got)
	testing.expect_value(t, got, "H\nREVIEW\nT")
}

@(test)
bt3_role_inline_coordinator_line :: proc(t: ^testing.T) {
	// The header uses inline (no-leading-newline) role blocks for the Coordinator line.
	tpl := "Instance: x\n{{#is_coordinator}}Coordinator: you (coordinator)\n{{/is_coordinator}}{{#is_worker}}Coordinator: {coordinator_id}\n{{/is_worker}}next"
	coord := bridge_bootstrap_eval_role_sections(tpl, true, false, false)
	defer delete(coord)
	testing.expect_value(t, coord, "Instance: x\nCoordinator: you (coordinator)\nnext")
	work := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	defer delete(work)
	testing.expect_value(t, work, "Instance: x\nCoordinator: {coordinator_id}\nnext")
}

@(test)
bt3_full_pipeline_worker :: proc(t: ^testing.T) {
	// Role eval THEN scalar substitution, matching bridge_bootstrap_render_template order.
	tpl := "Agent: {agent_name}\n{{#is_worker}}Coordinator: {coordinator_id}\n{{/is_worker}}{{#is_coordinator}}Coordinator: you (coordinator)\n{{/is_coordinator}}## {project_name}"
	after_roles := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	names := []string{"agent_name", "coordinator_id", "project_name"}
	values := []string{"A", "inst_coord", "Proj"}
	got := bridge_bootstrap_substitute_scalars(after_roles, names, values)
	delete(after_roles)
	defer delete(got)
	testing.expect_value(t, got, "Agent: A\nCoordinator: inst_coord\n## Proj")
}

@(test)
bt3_is_placeholder_key :: proc(t: ^testing.T) {
	testing.expect(t, bridge_bootstrap_is_placeholder_key("agent_name"))
	testing.expect(t, bridge_bootstrap_is_placeholder_key("project_name2"))
	testing.expect(t, !bridge_bootstrap_is_placeholder_key(""))
	testing.expect(t, !bridge_bootstrap_is_placeholder_key("has space"))
	testing.expect(t, !bridge_bootstrap_is_placeholder_key("\"k\": 1"))
}

// BT-3 end-to-end: feed the REAL template file through eval+substitute and confirm
// a coordinator render has the right sections and no leftover placeholders/tags.
@(test)
bt3_e2e_real_template_coordinator :: proc(t: ^testing.T) {
	tpl := string(#load("../prompts/bootstrap_agents.md", string))
	after := bridge_bootstrap_eval_role_sections(tpl, true, false, false)
	defer delete(after)
	names := []string{"agent_name","instance_id","chain_title","chain_id","coordinator_id","template_persona","template_instructions","agent_instructions","project_name","project_path","project_repo","project_vcs","project_description"}
	values := []string{"Backend Agent","inst_1","Prompts audit","chain_1","","You are Odin.","Base rules.","Agent rules.","Heimdall","~/h","git@x","git","Desc"}
	got := bridge_bootstrap_substitute_scalars(after, names, values)
	defer delete(got)
	// coordinator section present, worker/reviewer absent
	testing.expect(t, strings.contains(got, "## You are the COORDINATOR"))
	testing.expect(t, !strings.contains(got, "## You are a WORKER"))
	testing.expect(t, !strings.contains(got, "## You are a REVIEWER"))
	// header + identity + project substituted
	testing.expect(t, strings.contains(got, "Agent: Backend Agent"))
	testing.expect(t, strings.contains(got, "Coordinator: you (coordinator)"))
	testing.expect(t, strings.contains(got, "You are Odin."))
	testing.expect(t, strings.contains(got, "- Name: Heimdall"))
	// no leftover role tags or known placeholders
	testing.expect(t, !strings.contains(got, "{{#"))
	testing.expect(t, !strings.contains(got, "{{/"))
	testing.expect(t, !strings.contains(got, "{agent_name}"))
	testing.expect(t, !strings.contains(got, "{project_name}"))
	testing.expect(t, !strings.contains(got, "{template_persona}"))
}

@(test)
bt3_e2e_real_template_worker :: proc(t: ^testing.T) {
	tpl := string(#load("../prompts/bootstrap_agents.md", string))
	after := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	defer delete(after)
	names := []string{"coordinator_id"}
	values := []string{"inst_coord"}
	got := bridge_bootstrap_substitute_scalars(after, names, values)
	defer delete(got)
	testing.expect(t, strings.contains(got, "## You are a WORKER"))
	testing.expect(t, !strings.contains(got, "## You are the COORDINATOR"))
	testing.expect(t, strings.contains(got, "Coordinator: inst_coord"))
}
