package agent

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

TASK_STOP_COMMAND_PREFIX :: "cmd_task_stop_"

task_stop_command_id :: proc(instance_id: string, run_count: int) -> string {
	return fmt.aprintf("%s%d_%s", TASK_STOP_COMMAND_PREFIX, run_count, instance_id)
}

task_stop_command :: proc(bridge_id, instance_id, reason: string, run_count: int) -> project.Runtime_Command {
	id := task_stop_command_id(instance_id, run_count)
	return {bridge_id = bridge_id, command_id = id, body_json = stop_command_json(id, instance_id, reason, expected_run_count = run_count)}
}

// Only call for a command result from the current authenticated connection.
// A scheduler stop records its intent before dispatch. Bridge confirms the
// generation under its process lock after pty-host acknowledges close. A
// duplicate, unrelated or superseded result cannot stop a replacement row.
apply_task_stop_receipt :: proc(service: ^Agent_Service, bridge_id, command_id, reply: string, owner: domain.User_ID) -> (domain.Agent_Instance, bool) {
	if service == nil || !strings.has_prefix(command_id, TASK_STOP_COMMAND_PREFIX) do return {}, false
	payload, ok := jsonx.extract_raw_object(reply, "payload", true, context.temp_allocator)
	if !ok do return {}, false
	result, has_result := jsonx.extract_raw_object(payload, "result", true, context.temp_allocator)
	if !has_result do return {}, false
	instance_id := jsonx.extract_string(result, "agent_instance_id", "", true, context.temp_allocator)
	run_count := jsonx.extract_int(result, "expected_run_count", -1, true)
	if instance_id == "" || run_count < 0 do return {}, false
	expected := task_stop_command_id(instance_id, run_count)
	defer delete(expected)
	if command_id != expected || !confirmed_stop_receipt(reply, expected, instance_id, 0, run_count) do return {}, false
	inst, found, _ := iface.agent_get_instance(service.agents, instance_id)
	if !found do return {}, false
	defer domain.agent_instance_destroy(&inst)
	if inst.owner_user_id != owner || inst.bridge_id != bridge_id || inst.run_count != run_count || inst.stop_reason == "" || inst.current_task_id != "" ||
	   inst.status_message == "pty_stop_confirmed" {
		return {}, false
	}
	next := inst
	next.runtime_status, next.startup_status, next.activity_status = "stopped", "stopped", "idle"
	next.status_message = "pty_stop_confirmed"
	next.updated_at = platform.clock_now(service.clock)
	next.stopped_at = next.updated_at
	saved, applied, _ := iface.agent_save_instance_guarded(service.agents, next, inst.run_count, inst.launch_epoch, inst.configuration_revision)
	if !applied do return {}, false
	log_runtime_terminal_transition(saved, inst.runtime_status, "apply_task_stop_receipt", "pty_stop_confirmed")
	defer if saved.runtime_transport != inst.runtime_transport do delete(saved.runtime_transport)
	return domain.agent_instance_clone(saved), true
}
