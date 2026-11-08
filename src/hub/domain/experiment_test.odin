package domain

import "core:encoding/json"
import "core:testing"

// F1 (was REQ-EXP-GATE-1 opt-in): Actions, Project/VCS, LSP and the
// auto-approve-agent-memories setting default on; the user can turn each off.
@(test)
test_actions_project_vcs_lsp_and_memory_setting_default_on :: proc(t: ^testing.T) {
	testing.expect_value(t, ACTIONS_EXPERIMENT_KEY, "actions")
	testing.expect_value(t, PROJECT_VCS_EXPERIMENT_KEY, "project_vcs")
	testing.expect_value(t, LSP_EXPERIMENT_KEY, "lsp")
	testing.expect_value(t, AUTO_APPROVE_AGENT_MEMORIES_KEY, "auto_approve_agent_memories")
	testing.expect(t, experiment_default_enabled(ACTIONS_EXPERIMENT_KEY))
	testing.expect(t, experiment_default_enabled(PROJECT_VCS_EXPERIMENT_KEY))
	testing.expect(t, experiment_default_enabled(LSP_EXPERIMENT_KEY))
	testing.expect(t, experiment_default_enabled(AUTO_APPROVE_AGENT_MEMORIES_KEY))
	testing.expect(t, experiment_default_enabled(STREAMING_TERMINAL_PANE_EXPERIMENT_KEY))
	testing.expect(t, !experiment_default_enabled("some_new_flag"), "unknown keys stay off")
	off := []Experiment{{key = ACTIONS_EXPERIMENT_KEY, enabled = false}, {key = LSP_EXPERIMENT_KEY, enabled = false}, {key = AUTO_APPROVE_AGENT_MEMORIES_KEY, enabled = false}, {key = PROJECT_VCS_EXPERIMENT_KEY, enabled = false}}
	for k in ([]string{ACTIONS_EXPERIMENT_KEY, LSP_EXPERIMENT_KEY, AUTO_APPROVE_AGENT_MEMORIES_KEY, PROJECT_VCS_EXPERIMENT_KEY}) {
		testing.expect(t, !experiment_enabled_in(off, k), "the user can still turn it off")
	}
}

@(test)
test_experiment_enabled_in_stored_row_wins_over_default :: proc(t: ^testing.T) {
	testing.expect(t, !experiment_enabled_in({}, "some_new_flag"), "absent unknown key is off")
	testing.expect(t, experiment_enabled_in({}, ACTIONS_EXPERIMENT_KEY), "absent actions is on (F1)")
	testing.expect(t, experiment_enabled_in({}, STREAMING_TERMINAL_PANE_EXPERIMENT_KEY), "absent default-on is on")

	rows := []Experiment{
		{key = PROJECT_VCS_EXPERIMENT_KEY, enabled = true},
		{key = ACTIONS_EXPERIMENT_KEY, enabled = false},
		{key = STREAMING_TERMINAL_PANE_EXPERIMENT_KEY, enabled = false},
	}
	testing.expect(t, experiment_enabled_in(rows, PROJECT_VCS_EXPERIMENT_KEY), "existing project_vcs opt-in stays valid")
	testing.expect(t, !experiment_enabled_in(rows, ACTIONS_EXPERIMENT_KEY), "explicit off")
	testing.expect(t, !experiment_enabled_in(rows, STREAMING_TERMINAL_PANE_EXPERIMENT_KEY), "explicit off beats default-on")

	other_only := []Experiment{{key = "lsp", enabled = true}}
	testing.expect(t, !experiment_enabled_in(other_only, "some_new_flag"), "an unrelated flag does not enable another key")
}

// REQ-EXP-GATE-3: forbidden envelope, exact message and machine-readable details.
@(test)
test_experimental_feature_disabled_error_shape :: proc(t: ^testing.T) {
	Details :: struct {code: string, feature: string}

	actions := experimental_feature_disabled_error(ACTIONS_EXPERIMENT_KEY)
	testing.expect_value(t, actions.code, Error_Code.Forbidden)
	testing.expect_value(t, error_code_string(actions.code), "forbidden")
	testing.expect_value(t, actions.message, "Actions is experimental. Enable it in Settings > Experimental to use it.")
	d: Details
	testing.expect(t, json.unmarshal_string(actions.details_json, &d, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, d.code, "experimental_feature_disabled")
	testing.expect_value(t, d.feature, "actions")

	explorer := experimental_feature_disabled_error(PROJECT_VCS_EXPERIMENT_KEY)
	testing.expect_value(t, explorer.message, "Project Explorer is experimental. Enable it in Settings > Experimental to use it.")
	e: Details
	testing.expect(t, json.unmarshal_string(explorer.details_json, &e, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, e.feature, "project_vcs")

	// An unknown key is still valid JSON in details.
	odd := experimental_feature_disabled_error(`we"ird`)
	o: Details
	testing.expect(t, json.unmarshal_string(odd.details_json, &o, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, o.feature, `we"ird`)
}
