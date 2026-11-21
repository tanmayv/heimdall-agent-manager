package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Coordinator idle-stop columns (coordinator_idle_001/002): user_activity_at
// only moves forward; stop_reason survives saves of the same run and is
// cleared when a new run starts. Neither is written by save_instance.
@(test)
test_coordinator_idle_columns_lifecycle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened, "open") do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations") do return
	testing.expect(t, table_column_exists(&conn, "agent_instances", "user_activity_at"), "user_activity_at column")
	testing.expect(t, table_column_exists(&conn, "agent_instances", "stop_reason"), "stop_reason column")
	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)
	inst := domain.Agent_Instance{agent_instance_id = "inst_cic", owner_user_id = "u", agent_id = "agt", bridge_id = "brg", runtime_status = "running", run_count = 1, created_at = "2026-11-21T00:00:00Z", updated_at = "2026-11-21T00:00:00Z"}
	_, saved, _ := iface.agent_save_instance(&repo, inst)
	if !testing.expect(t, saved, "save instance") do return

	at, found, _ := iface.agent_get_user_activity(&repo, "inst_cic")
	testing.expect(t, found && at == "", "no stamp yet")
	moved, _ := iface.agent_touch_user_activity(&repo, "inst_cic", "2026-11-21T01:00:00Z")
	testing.expect(t, moved, "first touch")
	back, _ := iface.agent_touch_user_activity(&repo, "inst_cic", "2026-11-21T00:30:00Z")
	testing.expect(t, !back, "never backwards")
	at, _, _ = iface.agent_get_user_activity(&repo, "inst_cic")
	testing.expect_value(t, at, "2026-11-21T01:00:00Z")
	// A save of the stale struct never touches the stamp.
	_, _, _ = iface.agent_save_instance(&repo, inst)
	at, _, _ = iface.agent_get_user_activity(&repo, "inst_cic")
	testing.expect_value(t, at, "2026-11-21T01:00:00Z")

	recorded, _ := iface.agent_set_stop_reason(&repo, "inst_cic", "coordinator_idle")
	testing.expect(t, recorded, "stop reason recorded")
	stopping := inst
	stopping.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&repo, stopping) // same run: reason kept
	got, _, _ := iface.agent_get_instance(&repo, "inst_cic")
	testing.expect_value(t, got.stop_reason, "coordinator_idle")
	relaunch := got
	relaunch.stop_reason = ""
	relaunch.runtime_status = "launching"
	relaunch.run_count = got.run_count + 1
	_, _, _ = iface.agent_save_instance(&repo, relaunch) // new run: reason cleared
	got, _, _ = iface.agent_get_instance(&repo, "inst_cic")
	testing.expect_value(t, got.stop_reason, "")
	testing.expect_value(t, got.run_count, 2)
}
