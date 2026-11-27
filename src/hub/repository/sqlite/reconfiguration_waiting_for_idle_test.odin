package sqlite

import "core:c"
import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// 267 (T4): phase waiting_for_idle. It never blocks input but holds the
// instance's single active-operation slot; Restart now supersedes it atomically.

@(private = "file")
rwi_int :: proc(conn: ^Conn, query: string) -> int {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return -1
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return -1
	return int(sqlite3_column_int64(stmt, 0))
}

@(private = "file")
rwi_config :: proc() -> domain.Instance_Configuration {
	return {bridge_id = "rwi_bridge", provider = "codex", provider_profile = "codex", model = "gpt-6.1-sol", runtime_transport = "pty"}
}

@(private = "file")
rwi_op :: proc(instance, key: string, phase: domain.Instance_Reconfiguration_Phase) -> domain.Instance_Reconfiguration {
	op := domain.Instance_Reconfiguration{operation_id = key, owner_user_id = "owner", agent_instance_id = instance, conversation_id = fmt.tprintf("chat_%s", instance), actor_user_id = "owner", idempotency_key = key, revision = 1, phase = phase, source = rwi_config(), destination = rwi_config(), stop_command_id = "stop", launch_command_id = "launch", launch_epoch = "epoch", created_at = "now", updated_at = "now"}
	op.destination.model = "gpt-6.1-sol-next"
	if phase == .Waiting_For_Idle { op.apply = "after_turn"; op.waiting_since = "now" }
	return op
}

@(private = "file")
rwi_instance :: proc(conn: ^Conn, id: string) -> bool {
	return exec(conn, fmt.tprintf("INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,provider,provider_profile,model,conversation_id,runtime_status,runtime_transport,created_at,updated_at) VALUES('%s','owner','agent','rwi_bridge','codex','codex','gpt-6.1-sol','chat_%s','running','pty','','');", id, id)) &&
		exec(conn, fmt.tprintf("INSERT INTO chat_conversations(conversation_id,owner_user_id,agent_instance_id,created_at,updated_at) VALUES('chat_%s','owner','%s','now','now');", id, id))
}

@(test)
test_reconfiguration_waiting_for_idle_migration_slot_and_supersede :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "267_reconfiguration_waiting_for_idle.sql")
	if !testing.expect(t, migrated, err.message) do return
	if !testing.expect(t, rwi_instance(&conn, "rwi_a") && rwi_instance(&conn, "rwi_b")) do return
	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)

	// An operation persisted before 267 survives the rebuild and keeps its slot.
	pre, began, begin_err := iface.instance_reconfiguration_begin(&repo, rwi_op("rwi_a", "pre", .Prepared))
	if !testing.expect(t, began, begin_err.message) do return
	domain.instance_reconfiguration_destroy(&pre)
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	testing.expect_value(t, rwi_int(&conn, "SELECT COUNT(*) FROM instance_reconfigurations WHERE operation_id='pre' AND blocks_input=1;"), 1)
	for name in ([]string{"instance_reconfiguration_commit", "instance_reconfiguration_requested", "instance_reconfiguration_outcome", "instance_reconfiguration_recovery_stopped", "instance_reconfiguration_hold_messages", "instance_reconfigurations_exclusive", "instance_reconfigurations_owner_instance"}) {
		testing.expectf(t, sqlite_object_exists(&conn, name), "%s recreated", name)
	}
	testing.expect(t, sqlite_trigger_mentions(&conn, "instance_reconfiguration_commit", "runtime_transport_override"), "commit keeps the 266 body")
	testing.expect(t, sqlite_trigger_mentions(&conn, "instance_reconfiguration_outcome", "Configuration change cancelled"))
	testing.expect_value(t, rwi_int(&conn, "SELECT COUNT(*) FROM sqlite_master WHERE name='instance_reconfigurations_v264';"), 0)
	// Re-running is a no-op (ledger + completion guard); embedded == disk.
	migrated, err = run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	embedded := migration_sql("267_reconfiguration_waiting_for_idle.sql", ""); defer delete(embedded)
	disk := migration_sql("267_reconfiguration_waiting_for_idle.sql", "src/hub/repository/sqlite/migrations"); defer delete(disk)
	testing.expect_value(t, embedded, disk)

	// One active operation per instance: a blocking one excludes a queued one.
	_, began, begin_err = iface.instance_reconfiguration_begin(&repo, rwi_op("rwi_a", "w0", .Waiting_For_Idle))
	testing.expect(t, !began && begin_err.code == .Conflict, "a queued op cannot join a blocking op")
	testing.expect(t, exec(&conn, "UPDATE instance_reconfigurations SET phase='failed', blocks_input=0 WHERE operation_id='pre';"))

	waiting, ok, wait_err := iface.instance_reconfiguration_begin(&repo, rwi_op("rwi_a", "w1", .Waiting_For_Idle))
	if !testing.expect(t, ok, wait_err.message) do return
	defer domain.instance_reconfiguration_destroy(&waiting)
	testing.expect_value(t, waiting.phase, domain.Instance_Reconfiguration_Phase.Waiting_For_Idle)
	testing.expect_value(t, waiting.apply, "after_turn")
	testing.expect_value(t, rwi_int(&conn, "SELECT blocks_input FROM instance_reconfigurations WHERE operation_id='w1';"), 0)
	// Queued: messages still flow (hold_messages only sees blocks_input=1).
	testing.expect(t, exec(&conn, "INSERT INTO chat_messages(message_id,conversation_id,owner_user_id,direction,body,created_at) VALUES('msg_rwi_1','chat_rwi_a','owner','user_to_agent','hi','now');"), "messages are not blocked while waiting")
	_, began, begin_err = iface.instance_reconfiguration_begin(&repo, rwi_op("rwi_a", "w2", .Waiting_For_Idle))
	testing.expect(t, !began && begin_err.code == .Conflict, "a second queued op is rejected")
	_, began, begin_err = iface.instance_reconfiguration_begin(&repo, rwi_op("rwi_a", "now0", .Prepared))
	testing.expect(t, !began && begin_err.code == .Conflict, "a plain begin cannot bypass the queued op")
	listed, list_err := iface.instance_reconfiguration_list_waiting(&repo, "", "")
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(listed), 1)
	for &op in listed do domain.instance_reconfiguration_destroy(&op)
	delete(listed)
	// Both list shapes are index-backed (INDEXED BY fails to prepare otherwise).
	for query in ([]string{RECONFIGURATION_LIST_WAITING_INSTANCE_SQL, RECONFIGURATION_LIST_WAITING_ALL_SQL}) {
		stmt: sqlite3_stmt
		testing.expect_value(t, sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil), SQLITE_OK)
		sqlite3_finalize(stmt)
	}
	mine, mine_err := iface.instance_reconfiguration_list_waiting(&repo, "owner", "rwi_a")
	testing.expect_value(t, mine_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(mine), 1)
	for &op in mine do domain.instance_reconfiguration_destroy(&op)
	delete(mine)
	others, _ := iface.instance_reconfiguration_list_waiting(&repo, "someone_else", "rwi_a")
	testing.expect_value(t, len(others), 0)
	delete(others)
	active, _ := iface.instance_reconfiguration_list(&repo, "", "rwi_a", true)
	testing.expect_value(t, len(active), 0) // active_only keeps meaning "blocks input"
	delete(active)

	// Restart now: end the queued op and begin the new one in one transaction.
	ended := waiting
	ended.phase = .Failed; ended.revision = 2; ended.failure_code = domain.RECONFIGURATION_SUPERSEDED; ended.failure_message = "Replaced by Restart now."
	now_op, superseded, sup_err := iface.instance_reconfiguration_begin_superseding(&repo, rwi_op("rwi_a", "now1", .Prepared), ended, 1)
	if !testing.expect(t, superseded, sup_err.message) do return
	domain.instance_reconfiguration_destroy(&now_op)
	testing.expect_value(t, rwi_int(&conn, "SELECT COUNT(*) FROM instance_reconfigurations WHERE operation_id='w1' AND phase='failed' AND blocks_input=0;"), 1)
	testing.expect_value(t, rwi_int(&conn, "SELECT COUNT(*) FROM instance_reconfigurations WHERE operation_id='now1' AND phase='prepared' AND blocks_input=1;"), 1)
	testing.expect_value(t, rwi_int(&conn, "SELECT COUNT(*) FROM chat_messages WHERE message_id='w1_failed' AND body='Configuration change cancelled';"), 1)
	// Superseding an op that is no longer queued rolls back: no new op either.
	_, superseded, sup_err = iface.instance_reconfiguration_begin_superseding(&repo, rwi_op("rwi_a", "now2", .Prepared), ended, 1)
	testing.expect(t, !superseded && sup_err.code == .Conflict)
	testing.expect_value(t, rwi_int(&conn, "SELECT COUNT(*) FROM instance_reconfigurations WHERE operation_id='now2';"), 0)

	// Fire: waiting_for_idle -> stopping takes the blocking slot; apply/waiting_since are immutable.
	queued, queued_ok, queued_err := iface.instance_reconfiguration_begin(&repo, rwi_op("rwi_b", "wb", .Waiting_For_Idle))
	if !testing.expect(t, queued_ok, queued_err.message) do return
	defer domain.instance_reconfiguration_destroy(&queued)
	tampered := queued; tampered.phase = .Stopping; tampered.revision = 2; tampered.waiting_since = "later"
	_, moved, move_err := iface.instance_reconfiguration_advance(&repo, tampered, 1)
	testing.expect(t, !moved && move_err.code == .Conflict, "waiting_since is immutable")
	fired := queued; fired.phase = .Stopping; fired.revision = 2
	stepped, moved2, move_err2 := iface.instance_reconfiguration_advance(&repo, fired, 1)
	if !testing.expect(t, moved2, move_err2.message) do return
	domain.instance_reconfiguration_destroy(&stepped)
	testing.expect_value(t, rwi_int(&conn, "SELECT blocks_input FROM instance_reconfigurations WHERE operation_id='wb';"), 1)
}

@(test)
test_reconfiguration_waiting_for_idle_domain_rules :: proc(t: ^testing.T) {
	op := domain.Instance_Reconfiguration{phase = .Waiting_For_Idle}
	testing.expect(t, !domain.instance_reconfiguration_blocks_input(op))
	testing.expect(t, domain.instance_reconfiguration_holds_slot(op))
	testing.expect_value(t, domain.instance_reconfiguration_phase_string(.Waiting_For_Idle), "waiting_for_idle")
	for to in domain.Instance_Reconfiguration_Phase {
		allowed := domain.instance_reconfiguration_transition_allowed(.Waiting_For_Idle, to)
		testing.expectf(t, allowed == (to == .Stopping || to == .Source_Stopped || to == .Failed), "waiting_for_idle -> %v", to)
		if to != .Waiting_For_Idle do testing.expectf(t, !domain.instance_reconfiguration_transition_allowed(to, .Waiting_For_Idle), "%v -> waiting_for_idle", to)
	}
	// Payloads persist the ordinal: appending keeps every existing phase stable.
	testing.expect_value(t, int(domain.Instance_Reconfiguration_Phase.Recovery_Required), 6)
	testing.expect_value(t, int(domain.Instance_Reconfiguration_Phase.Waiting_For_Idle), 7)
}
