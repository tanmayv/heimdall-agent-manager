package main

import "core:strings"
import "core:testing"

// Unit coverage for the pure memory-propose param-builder. It must emit the T1
// JSON contract: targeting is JSON string arrays agent_ids/project_ids/
// bridge_ids/template_ids. An omitted dimension is left OUT entirely so the hub
// applies its default (agent -> caller's own; the rest -> applies to all). One
// id, two ids via CSV, and two ids via repeated flags must all produce the
// correct array. Values are JSON-escaped.

@(test)
test_memory_params_zero_ids_omits_target_arrays :: proc(t: ^testing.T) {
	args := []string{"--type", "fact", "--title", "T", "--body", "B"}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"type":"fact"`), "type present")
	testing.expect(t, strings.contains(out, `"title":"T"`), "title present")
	testing.expect(t, strings.contains(out, `"body":"B"`), "body present")
	// No targeting flags -> no arrays emitted (hub defaults apply).
	testing.expect(t, !strings.contains(out, "agent_ids"), "agent_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "project_ids"), "project_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "bridge_ids"), "bridge_ids omitted when no ids")
	testing.expect(t, !strings.contains(out, "template_ids"), "template_ids omitted when no ids")
	// Optional evidence omitted when blank.
	testing.expect(t, !strings.contains(out, "evidence"), "evidence omitted when blank")
}

@(test)
test_memory_params_single_id_per_dimension :: proc(t: ^testing.T) {
	args := []string{
		"--type", "fact", "--title", "T", "--body", "B",
		"--agent-id", "agt_a", "--project-id", "proj_1",
		"--bridge-id", "brg_1", "--template-id", "tmpl_1",
	}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_a"]`), out)
	testing.expect(t, strings.contains(out, `"project_ids":["proj_1"]`), out)
	testing.expect(t, strings.contains(out, `"bridge_ids":["brg_1"]`), out)
	testing.expect(t, strings.contains(out, `"template_ids":["tmpl_1"]`), out)
}

@(test)
test_memory_params_two_ids_via_csv :: proc(t: ^testing.T) {
	args := []string{"--type", "fact", "--title", "T", "--body", "B", "--agent-ids", "agt_a,agt_b"}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_a","agt_b"]`), out)
}

@(test)
test_memory_params_two_ids_via_repeated_flags :: proc(t: ^testing.T) {
	args := []string{"--type", "fact", "--title", "T", "--body", "B", "--agent", "agt_a", "--agent", "agt_b"}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_a","agt_b"]`), out)
}

@(test)
test_memory_params_csv_and_repeated_combine_and_trim :: proc(t: ^testing.T) {
	// Mixed repeated + CSV with surrounding spaces; blanks are skipped.
	args := []string{"--type", "fact", "--title", "T", "--body", "B", "--project-ids", "proj_1, proj_2", "--project", "proj_3", "--project-ids", ""}
	out := ctl_agentmode_memory_propose_params(args)
	testing.expect(t, strings.contains(out, `"project_ids":["proj_1","proj_2","proj_3"]`), out)
}

@(test)
test_json_string_array_field_escapes_values :: proc(t: ^testing.T) {
	vals := []string{"a\"b", "c\\d"}
	got := json_string_array_field("agent_ids", vals)
	testing.expect_value(t, got, `"agent_ids":["a\"b","c\\d"]`)
	// Empty list yields an explicit empty array.
	empty := json_string_array_field("agent_ids", []string{})
	testing.expect_value(t, empty, `"agent_ids":[]`)
}

@(test)
test_memory_params_description_handling :: proc(t: ^testing.T) {
	args_with := []string{"--type", "fact", "--title", "T", "--description", "Desc text", "--body", "B"}
	out_with := ctl_agentmode_memory_propose_params(args_with)
	testing.expect(t, strings.contains(out_with, `"description":"Desc text"`), out_with)

	args_without := []string{"--type", "fact", "--title", "T", "--body", "B"}
	out_without := ctl_agentmode_memory_propose_params(args_without)
	testing.expect(t, !strings.contains(out_without, `"description"`), out_without)
}

@(test)
test_memory_list_params_defaults :: proc(t: ^testing.T) {
	args := []string{}
	out := ctl_agentmode_memory_list_params(args)
	testing.expect_value(t, out, `{}`)
}

@(test)
test_memory_list_params_status_type_limit :: proc(t: ^testing.T) {
	args := []string{"--status", "active", "--type", "fact", "--limit", "25"}
	out := ctl_agentmode_memory_list_params(args)
	testing.expect(t, strings.contains(out, `"status":"active"`), out)
	testing.expect(t, strings.contains(out, `"type":"fact"`), out)
	testing.expect(t, strings.contains(out, `"limit":25`), out)
}

@(test)
test_memory_list_params_scope_dimensions :: proc(t: ^testing.T) {
	args := []string{
		"--agent-ids", "agt_1,agt_2",
		"--project", "proj_1", "--project-ids", "proj_2",
		"--bridge-id", "brg_1",
		"--template-ids", "tmpl_1",
	}
	out := ctl_agentmode_memory_list_params(args)
	testing.expect(t, strings.contains(out, `"agent_ids":["agt_1","agt_2"]`), out)
	testing.expect(t, strings.contains(out, `"project_ids":["proj_1","proj_2"]`), out)
	testing.expect(t, strings.contains(out, `"bridge_ids":["brg_1"]`), out)
	testing.expect(t, strings.contains(out, `"template_ids":["tmpl_1"]`), out)
}
