package main

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

// Task System v2 wire: tasks carry `state` (not `status`) and a `brief` object
// (goal/acceptance/verify/reviewers/assignee) instead of assignee_ref /
// reviewer_refs. These tests pin the ctl's typed read of a task create response
// in both the agent-mode (double `data`) and user-mode (single `data`) envelopes.

@(test)
test_v2_assignee_field_is_plain_agent_id :: proc(t: ^testing.T) {
	testing.expect_value(t, ctl_v2_assignee_field("agt_worker"), `"assignee":"agt_worker"`)
	testing.expect_value(t, ctl_v2_assignee_field("  agt_worker "), `"assignee":"agt_worker"`)
}

@(test)
test_v2_reviewers_field_repeatable_and_csv :: proc(t: ^testing.T) {
	one := ctl_v2_reviewers_field([]string{"--reviewer", "agt_a"})
	testing.expect_value(t, one, `"reviewers":["agt_a"]`)

	repeated := ctl_v2_reviewers_field([]string{"--reviewer", "agt_a", "--title", "x", "--reviewer", "agt_b"})
	testing.expect_value(t, repeated, `"reviewers":["agt_a","agt_b"]`)

	csv := ctl_v2_reviewers_field([]string{"--reviewer", "agt_a, agt_b,,"})
	testing.expect_value(t, csv, `"reviewers":["agt_a","agt_b"]`)

	// `--reviewer ""` must still emit an empty array so update can CLEAR the list.
	cleared := ctl_v2_reviewers_field([]string{"--reviewer", ""})
	testing.expect_value(t, cleared, `"reviewers":[]`)
}

@(test)
test_agentmode_task_params_use_v2_actor_keys :: proc(t: ^testing.T) {
	create := unseal_out(ctl_agentmode_task_create_params(with_kr([]string{"--title", "t", "--assignee", "agt_w", "--reviewer", "agt_r1", "--reviewer", "agt_r2"})))
	testing.expect(t, strings.contains(create, `"assignee":"agt_w"`), "create sends assignee as a plain agent_id")
	testing.expect(t, strings.contains(create, `"reviewers":["agt_r1","agt_r2"]`), "create sends reviewers as an agent_id array")
	testing.expect(t, !strings.contains(create, "assignee_ref") && !strings.contains(create, "reviewer_refs"), "legacy ref shapes are gone")

	update := unseal_out(ctl_agentmode_task_update_params("task_1", with_kr([]string{"--assignee", "agt_w2", "--reviewer", ""})))
	testing.expect(t, strings.contains(update, `"assignee":"agt_w2"`), "update sends assignee as a plain agent_id")
	testing.expect(t, strings.contains(update, `"reviewers":[]`), "update --reviewer \"\" clears the list")
}

@(test)
test_task_actor_flags_reject_instance_pins :: proc(t: ^testing.T) {
	testing.expect(t, ctl_task_reviewer_flags_valid([]string{"--assignee", "agt_w", "--reviewer", "agt_r"}, false), "agent ids are accepted")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--assignee", "inst_worker"}, false), "inst_ assignee must be rejected client-side")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--reviewer", "agt_a,inst_b"}, true), "inst_ reviewer in a csv must be rejected")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--reviewer", "agt_a", "--reviewer", "inst_b"}, true), "inst_ reviewer in a repeated flag must be rejected")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--assignee-agent-instance-id", "inst_x"}, true), "removed instance-pin flags must be rejected")
}
