package agent

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"

@(private = "file")
Stop_Reason_Sink :: struct { bodies: [dynamic]string }

@(private = "file")
stop_reason_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	sink := (^Stop_Reason_Sink)(ctx)
	append(&sink.bodies, strings.clone(command.body_json))
	return true, {}
}

// The coordinator idle stop goes through stop_instance like any other stop:
// its reason reaches the bridge, is recorded as stop_reason, and does NOT mark
// the instance user-stopped (the wake paths skip only user stops).
@(test)
test_stop_instance_records_idle_reason_without_user_stop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened, "open") do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations") do return
	agent_impl: sqlite.Agent_Repo_SQLite
	bridge_impl: sqlite.Bridge_Repo_SQLite
	agents := sqlite.new_agent_repository(&agent_impl, &conn)
	bridges := sqlite.new_bridge_repository(&bridge_impl, &conn)
	registry: project_service.Bridge_Runtime_Registry
	defer project_service.bridge_runtime_registry_destroy(&registry)
	sink: Stop_Reason_Sink
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_agent_service_with_runtime(&agents, &bridges, nil, nil, nil, project_service.Bridge_Command_Sink{ctx = &sink, send_runtime_command = stop_reason_send}, &registry, &clock, &ids)
	_, _, live := project_service.bridge_runtime_registry_accept_live(&registry, "brg_sr", false, "", "u_sr")
	if !testing.expect(t, live, "bridge live") do return
	now := platform.clock_now(&clock)
	_, saved, serr := iface.agent_save_instance(&agents, domain.Agent_Instance{agent_instance_id = "inst_sr", owner_user_id = "u_sr", agent_id = "agt_sr", bridge_id = "brg_sr", runtime_status = "running", run_count = 1, created_at = now, updated_at = now})
	if !testing.expect(t, saved, serr.message) do return

	inst, ok, err := stop_instance(&service, contracts.Auth_Context{kind = .Internal_User, user_id = "u_sr"}, "inst_sr", Stop_Instance_Input{reason = "coordinator_idle_completed"})
	if !testing.expect(t, ok, err.message) do return
	testing.expect_value(t, inst.stop_reason, "coordinator_idle_completed")
	testing.expect_value(t, inst.runtime_status, "stopping")
	stored, _, _ := iface.agent_get_instance(&agents, "inst_sr")
	testing.expect_value(t, stored.stop_reason, "coordinator_idle_completed")
	testing.expect_value(t, stored.stopped_by, "")
	testing.expect(t, len(sink.bodies) == 1 && strings.contains(sink.bodies[0], `"coordinator_idle_completed"`), "the reason reaches the bridge")
}
