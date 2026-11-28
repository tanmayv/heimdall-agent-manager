package agent

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// R7: typed lifecycle reasons. Only named reasons reach a restart; explicit
// stop requests are user stops whatever free text came with them.
@(test)
test_lifecycle_reasons_are_typed :: proc(t: ^testing.T) {
	r, ok := restart_reason_parse("")
	testing.expect(t, ok && r == .User_Restart)
	r, ok = restart_reason_parse("context_rollover")
	testing.expect(t, ok && r == .Context_Rollover)
	_, ok = restart_reason_parse("lease_wake")
	testing.expect(t, !ok, "a caller cannot name an internal start reason for a restart")
	for reason in Start_Reason do testing.expect(t, start_reason_wire(reason) != "", "every start reason has a wire name")
	testing.expect_value(t, stop_reason_parse("done for now"), STOP_USER_REQUESTED)
	testing.expect_value(t, stop_reason_parse("user_force_stop"), STOP_USER_FORCE)
	testing.expect(t, stop_reason_is_user(stop_reason_parse("")))
	testing.expect(t, !stop_reason_is_user(STOP_IDLE_TTL) && !stop_reason_is_user(STOP_COORDINATOR_IDLE))
	body := stop_command_json("cmd_x", "inst", STOP_LEASE_REVOKED, force = true, expected_run_count = 2)
	defer delete(body)
	testing.expect(t, strings.contains(body, `"reason":"lease_revoked"`) && strings.contains(body, `"expected_run_count":2`) && strings.contains(body, `"force":true`))
}

// ensure_running keeps a live child and starts a stopped one: the one path
// chat send, MCP chains.message and coordinator wakes use.
lifecycle_ensure_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='running' WHERE agent_instance_id='inst';")
	inst, kept, ok, err := ensure_running(&h.service, start_test_auth(), "inst", .User_Message)
	testing.expect(t, ok && kept, err.message)
	testing.expect_value(t, len(h.commands), 0)
	domain.agent_instance_destroy(&inst)
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst';")
	inst, kept, ok, err = ensure_running(&h.service, start_test_auth(), "inst", .Chain_Message)
	testing.expect(t, ok && !kept, err.message)
	testing.expect_value(t, inst.run_count, 4)
	testing.expect_value(t, len(h.commands), 1)
	domain.agent_instance_destroy(&inst)
}

@(test)
test_ensure_running_keeps_live_and_starts_stopped :: proc(t: ^testing.T) { start_test_run(t, lifecycle_ensure_scenario) }

// N2 (task_18ebe2189adce9d8): a restart of a Fleet-managed instance relaunches
// it with its own provider, profile, model and transport, not the bridge's
// Fleet default. Only applying Fleet settings changes the instance.
lifecycle_restart_keeps_runtime_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	saved, did_save, save_err := iface.fleet_settings_save(&h.br, "owner", "brg", {default_runtime = {"claude", "claude", "claude-sonnet-5-5"}})
	if !testing.expect(t, did_save, save_err.message) do return
	domain.fleet_settings_destroy(saved)
	row := start_test_row(t, h)
	defer domain.agent_instance_destroy(&row)
	testing.expect_value(t, iface.fleet_scope_set(&h.br, row, "chain").code, domain.Error_Code.None)
	managed, _ := iface.fleet_scope_get(&h.br, row)
	if !testing.expect(t, managed, "the instance is Fleet managed") do return
	for reason in ([]Start_Reason{.User_Restart, .Context_Rollover}) {
		start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst';")
		inst, ok, err := restart_instance(&h.service, start_test_auth(), "inst", reason)
		if !testing.expect(t, ok, err.message) do continue
		testing.expect_value(t, inst.provider, "codex")
		testing.expect_value(t, inst.provider_profile, "codex")
		testing.expect_value(t, inst.model, "gpt-6.1-sol")
		testing.expect_value(t, inst.runtime_transport, "pty")
		domain.agent_instance_destroy(&inst)
		last := h.commands[len(h.commands) - 1]
		testing.expect(t, strings.contains(last, `"provider":"codex"`) && strings.contains(last, `"model":"gpt-6.1-sol"`) && !strings.contains(last, "claude"), "the launch command carries the instance's runtime")
	}
}

@(test)
test_restart_keeps_instance_provider_profile_model_transport :: proc(t: ^testing.T) { start_test_run(t, lifecycle_restart_keeps_runtime_scenario) }
