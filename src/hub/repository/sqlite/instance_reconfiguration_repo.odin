package sqlite

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

instance_reconfiguration_decode :: proc(stmt: sqlite3_stmt) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	raw := column_text(stmt, 0)
	defer delete(raw)
	op: domain.Instance_Reconfiguration
	if json.unmarshal(transmute([]byte)raw, &op) != nil do return {}, false, domain.domain_error(.Internal_Error, "invalid persisted reconfiguration")
	return op, true, {}
}

instance_reconfiguration_get_sqlite :: proc(ctx: rawptr, owner, instance_id, key: string) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	query := "SELECT payload_json FROM instance_reconfigurations WHERE owner_user_id=? AND agent_instance_id=? AND idempotency_key=?;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed reconfiguration lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, instance_id); bind_text(stmt, 3, key)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Not_Found, "reconfiguration not found")
	return instance_reconfiguration_decode(stmt)
}

instance_reconfiguration_begin_sqlite :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	return instance_reconfiguration_write_sqlite(ctx, op, 0, true)
}

instance_reconfiguration_begin_superseding_sqlite :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, superseded: domain.Instance_Reconfiguration, superseded_expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	if superseded.phase != .Failed || superseded.failure_code != domain.RECONFIGURATION_SUPERSEDED || superseded.agent_instance_id != op.agent_instance_id || superseded.owner_user_id != op.owner_user_id {
		return {}, false, domain.domain_error(.Validation_Failed, "invalid superseded reconfiguration")
	}
	factory := SQLite_Unit_Of_Work_Factory{conn=impl.conn}
	uow, begun, err := sqlite_uow_begin(&factory)
	if !begun do return {}, false, err
	finished := false
	defer if !finished do iface.unit_of_work_rollback(&uow)
	old, found, get_err := instance_reconfiguration_get_sqlite(ctx, superseded.owner_user_id, superseded.agent_instance_id, superseded.idempotency_key)
	if !found do return {}, false, get_err
	waiting := old.phase == .Waiting_For_Idle
	domain.instance_reconfiguration_destroy(&old)
	if !waiting do return {}, false, domain.domain_error(.Conflict, "queued operation changed; refresh before applying")
	ended, ended_ok, end_err := instance_reconfiguration_advance_impl(ctx, superseded, superseded_expected_revision)
	if !ended_ok do return {}, false, end_err
	domain.instance_reconfiguration_destroy(&ended)
	stored, ok, begin_err := instance_reconfiguration_begin_impl(ctx, op)
	if !ok do return {}, false, begin_err
	finished = true
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {domain.instance_reconfiguration_destroy(&stored); return {}, false, commit_err}
	return stored, true, {}
}

instance_reconfiguration_advance_sqlite :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	return instance_reconfiguration_write_sqlite(ctx, op, expected_revision, false)
}

// Reconciliation also runs outside HTTP units of work. Serialize these writes
// with the shared connection's transaction owner, otherwise a concurrent MCP
// read/rejected request can observe and then roll back native move progress.
instance_reconfiguration_write_sqlite :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, expected_revision: int, initial: bool) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	factory := SQLite_Unit_Of_Work_Factory{conn=impl.conn}
	uow, begun, err := sqlite_uow_begin(&factory)
	if !begun do return {}, false, err
	finished := false
	defer if !finished do iface.unit_of_work_rollback(&uow)
	stored: domain.Instance_Reconfiguration
	ok: bool
	if initial {stored,ok,err=instance_reconfiguration_begin_impl(ctx,op)} else {stored,ok,err=instance_reconfiguration_advance_impl(ctx,op,expected_revision)}
	if !ok do return {},false,err
	finished=true // COMMIT consumes the UOW even when it fails.
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {domain.instance_reconfiguration_destroy(&stored);return {},false,commit_err}
	return stored,true,{}
}

instance_reconfiguration_begin_impl :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	if op.operation_id == "" || op.idempotency_key == "" || len(op.idempotency_key) > 128 || (op.phase != .Prepared && op.phase != .Waiting_For_Idle) || op.revision != 1 || op.source_stopped || op.destination_committed {
		return {}, false, domain.domain_error(.Validation_Failed, "invalid initial reconfiguration")
	}
	// A key is immutable: a retry cannot silently change its destination.
	if existing, found, _ := instance_reconfiguration_get_sqlite(ctx, op.owner_user_id, op.agent_instance_id, op.idempotency_key); found {
		if !domain.instance_configuration_equal(existing.destination, op.destination) {
			domain.instance_reconfiguration_destroy(&existing)
			return {}, false, domain.domain_error(.Conflict, "idempotency key already belongs to another configuration")
		}
		return existing, true, {}
	}
	data, encode_err := json.marshal(op)
	if encode_err != nil do return {}, false, domain.domain_error(.Internal_Error, "failed reconfiguration encode")
	defer delete(data)
	// One INSERT both compares the configuration snapshot and acquires the unique
	// per-instance active slot. No shared-connection BEGIN/COMMIT window is needed.
	// A queued (waiting_for_idle) operation takes the same slot without blocking
	// input; the exclusive index covers both (migration 264).
	query := "INSERT INTO instance_reconfigurations (operation_id, owner_user_id, agent_instance_id, idempotency_key, revision, phase, blocks_input, payload_json, created_at, updated_at) SELECT ?, ?, ?, ?, 1, ?, ?, ?, ?, ? FROM agent_instances WHERE agent_instance_id=? AND owner_user_id=? AND bridge_id=? AND project_id=? AND project_path=? AND provider=? AND model=? AND configuration_revision=? AND conversation_id=? AND provider_profile=? RETURNING payload_json;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed reconfiguration prepare")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, op.operation_id); bind_text(stmt, 2, op.owner_user_id); bind_text(stmt, 3, op.agent_instance_id); bind_text(stmt, 4, op.idempotency_key)
	bind_text(stmt, 5, domain.instance_reconfiguration_phase_string(op.phase)); bind_text(stmt, 6, "1" if domain.instance_reconfiguration_blocks_input(op) else "0")
	bind_text(stmt, 7, string(data)); bind_text(stmt, 8, op.created_at); bind_text(stmt, 9, op.updated_at)
	bind_text(stmt, 10, op.agent_instance_id); bind_text(stmt, 11, op.owner_user_id); bind_text(stmt, 12, op.source.bridge_id)
	bind_text(stmt, 13, op.source.project_id); bind_text(stmt, 14, op.source.project_path); bind_text(stmt, 15, op.source.provider); bind_text(stmt, 16, op.source.model)
	bind_text(stmt, 17, i32_to_string(op.expected_revision)); bind_text(stmt, 18, op.conversation_id)
	bind_text(stmt,19,domain.profile_effective_id(op.source.provider,op.source.provider_profile))
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Conflict, "configuration changed or another reconfiguration requires recovery")
	return instance_reconfiguration_decode(stmt)
}

instance_reconfiguration_advance_impl :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	old, found, err := instance_reconfiguration_get_sqlite(ctx, op.owner_user_id, op.agent_instance_id, op.idempotency_key)
	if !found do return {}, false, err
	defer domain.instance_reconfiguration_destroy(&old)
	if old.revision != expected_revision || op.revision != expected_revision + 1 do return {}, false, domain.domain_error(.Conflict, "stale operation revision")
	if old.operation_id != op.operation_id || old.conversation_id != op.conversation_id || old.actor_user_id != op.actor_user_id || old.created_at != op.created_at || old.expected_revision != op.expected_revision || old.source != op.source || old.destination != op.destination || old.launch_epoch != op.launch_epoch || old.apply != op.apply || old.waiting_since != op.waiting_since {
		return {}, false, domain.domain_error(.Conflict, "operation identity and configuration are immutable")
	}
	recovery_stop := op.phase == .Recovery_Required && op.failure_code == "force_stopping"
	confirmed_recovery_stop := old.phase == .Recovery_Required && old.failure_code == "force_stopping" && op.phase == .Failed && op.failure_code == "recovery_stopped"
	stop_retry := recovery_stop || old.phase == .Recovery_Required && op.phase == .Stopping && !old.source_stopped && !old.destination_committed
	launch_retry := old.phase == .Recovery_Required && op.phase == .Launching && old.destination_committed
	if old.source_launch_epoch != op.source_launch_epoch || old.source_run_count != op.source_run_count do return {},false,domain.domain_error(.Conflict,"source generation is immutable")
	freeze_frame := old.phase==.Launching && op.phase==.Launching && old.launch_json=="" && op.launch_json!=""
	if old.launch_json!=op.launch_json && !freeze_frame && !(launch_retry && op.launch_json=="") do return {},false,domain.domain_error(.Conflict,"launch frame is immutable outside retry")
	if old.phase==.Launching && op.phase==.Launching && !freeze_frame do return {},false,domain.domain_error(.Conflict,"only initial frame freeze may retain launching phase")
	if (old.stop_command_id != op.stop_command_id && !stop_retry) || (old.launch_command_id != op.launch_command_id && !launch_retry) do return {}, false, domain.domain_error(.Conflict, "command ids can change only on a reconciled retry")
	if !domain.instance_reconfiguration_transition_allowed(old.phase, op.phase) do return {}, false, domain.domain_error(.Conflict, "invalid reconfiguration phase transition")
	if (old.source_stopped && !op.source_stopped) || (old.destination_committed && !op.destination_committed) || (op.destination_committed && !op.source_stopped) || (op.phase == .Source_Stopped && !op.source_stopped) || (op.phase == .Launching && !op.destination_committed) || (op.phase == .Ready && !op.destination_committed) || (op.phase == .Failed && op.destination_committed && !confirmed_recovery_stop) {
		return {}, false, domain.domain_error(.Conflict, "invalid reconfiguration completion flags")
	}
	if op.failure_code == "recovery_stopped" && !confirmed_recovery_stop do return {}, false, domain.domain_error(.Conflict, "recovery stop must be confirmed")
	data, encode_err := json.marshal(op)
	if encode_err != nil do return {}, false, domain.domain_error(.Internal_Error, "failed reconfiguration encode")
	defer delete(data)
	query := "UPDATE instance_reconfigurations SET revision=?, phase=?, blocks_input=?, payload_json=?, updated_at=? WHERE operation_id=? AND owner_user_id=? AND revision=? RETURNING payload_json;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed reconfiguration update prepare")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, i32_to_string(op.revision)); bind_text(stmt, 2, domain.instance_reconfiguration_phase_string(op.phase))
	bind_text(stmt, 3, "1" if domain.instance_reconfiguration_blocks_input(op) else "0"); bind_text(stmt, 4, string(data)); bind_text(stmt, 5, op.updated_at)
	bind_text(stmt, 6, op.operation_id); bind_text(stmt, 7, op.owner_user_id); bind_text(stmt, 8, i32_to_string(expected_revision))
	if step_write_healing(impl.conn, stmt) != SQLITE_ROW do return {}, false, domain.domain_error(.Conflict, "operation was concurrently advanced or destination could not be committed")
	return instance_reconfiguration_decode(stmt)
}

instance_reconfiguration_list_sqlite :: proc(ctx: rawptr, owner, instance_id: string, active_only: bool) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	query := "SELECT payload_json FROM instance_reconfigurations WHERE (?='' OR owner_user_id=?) AND (?='' OR agent_instance_id=?) AND (?='0' OR blocks_input=1) ORDER BY created_at DESC, operation_id DESC LIMIT 128;"
	// Reconciliation must see every accepted operation, even when more than 128
	// targets are waiting on acknowledgements. Only terminal UI history is capped.
	if active_only do query = "SELECT payload_json FROM instance_reconfigurations WHERE (?='' OR owner_user_id=?) AND (?='' OR agent_instance_id=?) AND (?='0' OR blocks_input=1) ORDER BY created_at DESC, operation_id DESC;"
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed reconfiguration list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, owner); bind_text(stmt, 3, instance_id); bind_text(stmt, 4, instance_id); bind_text(stmt, 5, "1" if active_only else "0")
	ops := make([dynamic]domain.Instance_Reconfiguration)
	for sqlite3_step(stmt) == SQLITE_ROW {
		op, found, err := instance_reconfiguration_decode(stmt)
		if !found {
			for &previous in ops do domain.instance_reconfiguration_destroy(&previous)
			delete(ops)
			return nil, err
		}
		append(&ops, op)
	}
	return ops[:], {}
}

RECONFIGURATION_LIST_WAITING_INSTANCE_SQL :: "SELECT payload_json FROM instance_reconfigurations INDEXED BY instance_reconfigurations_exclusive WHERE agent_instance_id=?3 AND phase='waiting_for_idle' AND (?1='' OR owner_user_id=?2) ORDER BY created_at, operation_id;"
RECONFIGURATION_LIST_WAITING_ALL_SQL :: "SELECT payload_json FROM instance_reconfigurations INDEXED BY instance_reconfigurations_exclusive WHERE phase='waiting_for_idle' AND (?1='' OR owner_user_id=?2) ORDER BY created_at, operation_id;"

instance_reconfiguration_list_waiting_sqlite :: proc(ctx: rawptr, owner, instance_id: string) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	// Both shapes use the partial exclusive index (its WHERE is blocking OR
	// waiting_for_idle; phase='waiting_for_idle' implies it): the per-instance
	// form is an index lookup on the hot idle-report path, the sweep form scans
	// only active rows, never history.
	query := RECONFIGURATION_LIST_WAITING_ALL_SQL
	if instance_id != "" do query = RECONFIGURATION_LIST_WAITING_INSTANCE_SQL
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed queued reconfiguration list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, owner)
	if instance_id != "" do bind_text(stmt, 3, instance_id)
	ops := make([dynamic]domain.Instance_Reconfiguration)
	for sqlite3_step(stmt) == SQLITE_ROW {
		op, found, err := instance_reconfiguration_decode(stmt)
		if !found {
			for &previous in ops do domain.instance_reconfiguration_destroy(&previous)
			delete(ops)
			return nil, err
		}
		append(&ops, op)
	}
	return ops[:], {}
}
