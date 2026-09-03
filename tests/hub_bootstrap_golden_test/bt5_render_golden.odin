// BT-5 — Golden/no-drift guard for the NEW single-template bootstrap AGENTS.md.
//
// Unlike the per-fragment goldens in main.odin (which pin each render_* fragment
// body in isolation), these goldens pin the FULLY-ASSEMBLED AGENTS.md as a real
// launch would produce it. Each case is driven through the ACTUAL render path:
//
//   hub  : bootstrap_build_project_variables + bootstrap_append_identity_variables
//          + bootstrap_write_template_and_variables_json  -> the variables manifest
//   bridge: bridge_bootstrap_assemble_agents_md -> bridge_bootstrap_render_template
//          -> bridge_bootstrap_eval_role_sections + bridge_bootstrap_substitute_scalars
//          -> ctl-guidance appendix
//
// So a change to the template (src/prompts/bootstrap_agents.md), the hub variable
// set/order, or the bridge substitution/role-conditional engine that alters the
// rendered bytes is caught here with no live stack required.
//
// Goldens live in tests/hub_bootstrap_golden_test/golden_bt5/<case>.md and are
// regenerated intentionally with:  HEIMDALL_GOLDEN_UPDATE=1 <run test>
// (only for a DELIBERATE output change — otherwise a mismatch is a drift bug).
//
// Cases (REQ BT-5 §Scope):
//   - coordinator_full        : coordinator in a chain + project + persona/instructions
//   - worker_no_project       : worker in a chain, empty project + empty identity
//   - reviewer_in_chain       : reviewer in a chain (is_reviewer role block)
//   - standalone_agent_instr  : coordinator of an auto-chain, agent.instructions only
//   - empty_agent             : coordinator of an auto-chain, no identity at all
package hub_bootstrap_golden_test

import "core:fmt"
import "core:os"
import "core:strings"
import bridge "odin_test:bridge"
import agent_service "odin_test:hub/service/agent"

GOLDEN_BT5_DIR :: "tests/hub_bootstrap_golden_test/golden_bt5"

// Bt5_Case is one fully-parameterised bootstrap render: the descriptor values the
// bridge injects locally (header + role) plus the DB-backed variable values the
// hub serves (project_* and the three identity variables).
Bt5_Case :: struct {
	name:                  string,
	// Header / role (bridge-local descriptor fields).
	agent_name:            string,
	instance_id:           string,
	chain_title:           string,
	chain_id:              string,
	coordinator_id:        string,
	role:                  string, // "coordinator" | "worker" | "reviewer"
	// Identity variables (hub DB values).
	template_persona:      string,
	template_instructions: string,
	agent_instructions:    string,
	// Project variables (hub DB values).
	project_name:          string,
	project_path:          string,
	project_repo:          string,
	project_vcs:           string,
	project_description:   string,
}

// bt5_render_goldens_checks renders every BT-5 case through the real hub+bridge
// path and compares each against its committed golden. Shares the module-level
// `failures` counter with main.odin so a mismatch fails the whole test binary.
bt5_render_goldens_checks :: proc() {
	cases := []Bt5_Case{
		// Coordinator in a chain, full project + persona/template/agent instructions.
		// This is the case the reviewer flagged: it MUST render the COORDINATOR role
		// block and "Coordinator: you (coordinator)" (role = "coordinator").
		{
			name = "coordinator_full",
			agent_name = "Coordinator Agent",
			instance_id = "inst_18d1d31cff18dc90",
			chain_title = "Bootstrap refactor",
			chain_id = "chain_18d1d2feb77fa2d8",
			role = "coordinator",
			template_persona = "You are a meticulous systems engineer named Odin.",
			template_instructions = "Follow the house style. Write tests before code.",
			agent_instructions = "Prefer small, reviewed diffs. Cite file:line in every claim.",
			project_name = "Heimdall",
			project_path = "~/heimdall-hub-rewrite",
			project_repo = "git@github.com:tanmayv/heimdall-agent-manager.git",
			project_vcs = "git",
			project_description = "Enterprise multi-agent orchestrator.",
		},
		// Worker in a chain, no project, no identity — verifies the WORKER block, the
		// worker "Coordinator: <id>" line (empty here), and the empty-heading behavior.
		{
			name = "worker_no_project",
			agent_name = "Worker Agent",
			instance_id = "inst_18d1d31d1df150c0",
			chain_title = "Bootstrap refactor",
			chain_id = "chain_18d1d2feb77fa2d8",
			role = "worker",
		},
		// Reviewer in a chain — verifies the is_reviewer role block is emitted and the
		// coordinator/worker blocks are dropped.
		{
			name = "reviewer_in_chain",
			agent_name = "Reviewer Agent",
			instance_id = "inst_18d1d31d9aa1b2c0",
			chain_title = "Bootstrap refactor",
			chain_id = "chain_18d1d2feb77fa2d8",
			coordinator_id = "inst_18d1d31cff18dc90",
			role = "reviewer",
		},
		// Standalone launch: the hub auto-creates a chain with the instance AS its
		// coordinator, so role = "coordinator". agent.instructions is the only
		// identity source (no persona, no template instructions).
		{
			name = "standalone_agent_instr",
			agent_name = "Standalone Agent",
			instance_id = "inst_18d1d31d7be18498",
			chain_title = "Standalone Agent #1",
			chain_id = "chain_18d1d31d7b1b3ae0",
			role = "coordinator",
			agent_instructions = "Just do what is needed.",
		},
		// Standalone launch with NO identity at all — verifies the empty ### Persona /
		// ### Instructions headings render (empty-heading behavior, BT-1 §2.1).
		{
			name = "empty_agent",
			agent_name = "Empty Agent",
			instance_id = "inst_18d1d31dd16f7708",
			chain_title = "Empty Agent #1",
			chain_id = "chain_18d1d31dd0c61f78",
			role = "coordinator",
		},
	}

	for c in cases {
		got, ok := bt5_render_case(c)
		if !ok {
			failures += 1
			fmt.eprintfln("BT-5 render FAILED to assemble case %s", c.name)
			continue
		}
		check_golden_bt5(c.name, got)
		delete(got)
	}
}

// bt5_render_case builds the hub variables manifest for a case and renders it
// through the real bridge assembler. Returns the assembled AGENTS.md body.
bt5_render_case :: proc(c: Bt5_Case) -> (string, bool) {
	// --- HUB half: build the variable set + template-and-variables manifest ----
	vars := agent_service.bootstrap_build_project_variables(
		c.project_name, c.project_path, c.project_repo, c.project_vcs, c.project_description)
	defer delete(vars)
	agent_service.bootstrap_append_identity_variables(
		&vars, c.template_persona, c.template_instructions, c.agent_instructions)

	tpl_hash := agent_service.bootstrap_template_hash()
	defer delete(tpl_hash)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"protocol\":2")
	agent_service.bootstrap_write_template_and_variables_json(&b, tpl_hash, vars[:])
	strings.write_string(&b, "}")
	manifest := strings.to_string(b)

	// --- BRIDGE half: seed the template blob, then drive the real assembler ----
	tmp := strings.concatenate({"/tmp/heimdall-bt5-golden-", c.name})
	defer delete(tmp)
	_ = os.remove_all(tmp)
	defer _ = os.remove_all(tmp)

	cache: bridge.Bootstrap_Cache
	bridge.bootstrap_cache_init(&cache, tmp, 8 * 1024 * 1024)
	if !bridge.bootstrap_cache_put(&cache, tpl_hash, agent_service.BOOTSTRAP_AGENTS_TEMPLATE) {
		return "", false
	}

	d := bridge.Bridge_Bootstrap_Descriptor{
		instance_id    = c.instance_id,
		agent_name     = c.agent_name,
		role           = c.role,
		coordinator_id = c.coordinator_id,
		chain_id       = c.chain_id,
		chain_title    = c.chain_title,
	}
	return bridge.bridge_bootstrap_assemble_agents_md(manifest, d, &cache)
}

// check_golden_bt5 compares `got` against golden_bt5/<name>.md. Mirrors
// check_golden (main.odin) but targets the assembled-document goldens and shares
// the `failures` counter. HEIMDALL_GOLDEN_UPDATE=1 (re)writes the golden.
check_golden_bt5 :: proc(name, got: string) {
	path := strings.concatenate({GOLDEN_BT5_DIR, "/", name, ".md"})
	defer delete(path)

	if os.get_env("HEIMDALL_GOLDEN_UPDATE", context.allocator) == "1" {
		if os.write_entire_file(path, transmute([]byte)got) == nil {
			fmt.printfln("updated golden_bt5 %s (%d bytes)", name, len(got))
		} else {
			fmt.eprintfln("FAILED to write golden_bt5 %s", name)
			failures += 1
		}
		return
	}

	want_bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("MISSING golden_bt5 %s (run with HEIMDALL_GOLDEN_UPDATE=1 to create)", name)
		failures += 1
		return
	}
	defer delete(want_bytes)
	want := string(want_bytes)
	if got != want {
		failures += 1
		fmt.eprintfln("GOLDEN_BT5 MISMATCH %s", name)
		fmt.eprintfln("  got  (%d bytes): %q", len(got), got)
		fmt.eprintfln("  want (%d bytes): %q", len(want), want)
	} else {
		fmt.printfln("ok bt5 %s (%d bytes)", name, len(got))
	}
}
