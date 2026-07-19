package main

import "core:c"
import "core:fmt"
import "core:strings"

TASK_NOTIFICATION_REPLAY_LIMIT :: 100
TASK_NOTIFICATION_RETENTION_MS :: i64(7 * 24 * 60 * 60 * 1000)

notification_outbox_seq: int

notification_outbox_payload_event_id :: proc(recipient_agent_instance_id, payload: string) -> string {
	event_id := extract_json_string(payload, "event_id", "")
	if event_id != "" do return event_id
	notification_outbox_seq += 1
	return fmt.tprintf("notif_%d_%d", router_now_unix_ms(), notification_outbox_seq)
}

// notification_outbox_dedupe_key derives the coalescing key for a task_event
// payload. Undelivered notifications that share a key for the same recipient are
// superseded on insert, so an agent that was offline for a long time is not woken
// with a backlog of stale intermediate task pings -- only the latest state per
// (task, event-category) survives. An empty key disables coalescing (each row is
// kept distinct), which is the correct default for non-task payloads.
notification_outbox_dedupe_key :: proc(payload: string) -> string {
	type_field := extract_json_string(payload, "type", "")
	if type_field != "task_event" do return ""
	task_id := extract_json_string(payload, "task_id", "")
	if task_id == "" do return ""
	// Collapse all status/assignment/nudge pings for a task into one live row.
	// The newest payload always carries the current status and body, so a single
	// coalesced notification is sufficient to bring the agent up to date.
	return strings.concatenate({"task:", task_id})
}

notification_outbox_insert_pending :: proc(recipient_agent_instance_id, payload: string) -> string {
	if recipient_agent_instance_id == "" || payload == "" do return ""
	if !task_db_ready do return ""
	event_id := notification_outbox_payload_event_id(recipient_agent_instance_id, payload)
	dedupe_key := notification_outbox_dedupe_key(payload)
	// Supersede any prior UNDELIVERED notification for the same recipient+key so
	// the queue holds at most one live entry per task. Delivered rows are left
	// alone (retention/cleanup handles them).
	if dedupe_key != "" {
		supersede_stmt: sqlite3_stmt = nil
		supersede_query := `DELETE FROM task_notification_outbox WHERE recipient_agent_instance_id = ? AND dedupe_key = ? AND delivered_unix_ms = 0`
		if sqlite3_prepare_v2(task_db.db, cstring(raw_data(supersede_query)), -1, &supersede_stmt, nil) == SQLITE_OK {
			task_db_bind_text(supersede_stmt, 1, recipient_agent_instance_id)
			task_db_bind_text(supersede_stmt, 2, dedupe_key)
			_ = sqlite3_step(supersede_stmt)
			sqlite3_finalize(supersede_stmt)
		}
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO task_notification_outbox (
		recipient_agent_instance_id, event_id, payload, created_unix_ms,
		delivered_unix_ms, attempts, last_attempt_unix_ms, dedupe_key
	) VALUES (?, ?, ?, ?, 0, 0, 0, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("notification_outbox_insert_pending: prepare failed:", rc)
		return ""
	}
	defer sqlite3_finalize(stmt)

	task_db_bind_text(stmt, 1, recipient_agent_instance_id)
	task_db_bind_text(stmt, 2, event_id)
	task_db_bind_text(stmt, 3, payload)
	sqlite3_bind_int64(stmt, 4, router_now_unix_ms())
	task_db_bind_text(stmt, 5, dedupe_key)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("notification_outbox_insert_pending: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return ""
	}
	return event_id
}

notification_outbox_pending_exists :: proc(recipient_agent_instance_id, event_id: string) -> bool {
	if recipient_agent_instance_id == "" || event_id == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `SELECT 1 FROM task_notification_outbox WHERE recipient_agent_instance_id = ? AND event_id = ? AND delivered_unix_ms = 0 LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("notification_outbox_pending_exists: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, recipient_agent_instance_id)
	task_db_bind_text(stmt, 2, event_id)
	return sqlite3_step(stmt) == SQLITE_ROW
}

notification_outbox_mark_remote_ack :: proc(event_id: string) -> bool {
	if event_id == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `UPDATE task_notification_outbox
		SET attempts = attempts + 1,
		    last_attempt_unix_ms = ?,
		    delivered_unix_ms = CASE WHEN delivered_unix_ms = 0 THEN ? ELSE delivered_unix_ms END
		WHERE event_id = ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("notification_outbox_mark_remote_ack: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)
	now := router_now_unix_ms()
	sqlite3_bind_int64(stmt, 1, now)
	sqlite3_bind_int64(stmt, 2, now)
	task_db_bind_text(stmt, 3, event_id)
	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("notification_outbox_mark_remote_ack: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return sqlite3_changes(task_db.db) > 0
}

notification_outbox_mark_attempt :: proc(recipient_agent_instance_id, event_id: string, delivered: bool) -> bool {
	if recipient_agent_instance_id == "" || event_id == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `UPDATE task_notification_outbox
		SET attempts = attempts + 1,
		    last_attempt_unix_ms = ?,
		    delivered_unix_ms = CASE WHEN ? != 0 THEN ? ELSE delivered_unix_ms END
		WHERE recipient_agent_instance_id = ? AND event_id = ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("notification_outbox_mark_attempt: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	now := router_now_unix_ms()
	sqlite3_bind_int64(stmt, 1, now)
	sqlite3_bind_int64(stmt, 2, 1 if delivered else 0)
	sqlite3_bind_int64(stmt, 3, now)
	task_db_bind_text(stmt, 4, recipient_agent_instance_id)
	task_db_bind_text(stmt, 5, event_id)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("notification_outbox_mark_attempt: step failed: %d (%s)\n", rc, sqlite3_errmsg(task_db.db))
		return false
	}
	return true
}

notification_outbox_cleanup_delivered :: proc() {
	if !task_db_ready do return
	cutoff := router_now_unix_ms() - TASK_NOTIFICATION_RETENTION_MS
	stmt: sqlite3_stmt = nil
	query := `DELETE FROM task_notification_outbox WHERE delivered_unix_ms > 0 AND delivered_unix_ms < ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("notification_outbox_cleanup_delivered: prepare failed:", rc)
		return
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, cutoff)
	_ = sqlite3_step(stmt)
}

notification_outbox_replay_pending :: proc(recipient_agent_instance_id: string) -> int {
	if recipient_agent_instance_id == "" || !task_db_ready do return 0
	notification_outbox_cleanup_delivered()

	event_ids := make([dynamic]string)
	payloads := make([dynamic]string)
	defer {
		for event_id in event_ids do delete(event_id)
		for payload in payloads do delete(payload)
		delete(event_ids)
		delete(payloads)
	}

	stmt: sqlite3_stmt = nil
	query := `SELECT event_id, payload
		FROM task_notification_outbox
		WHERE recipient_agent_instance_id = ? AND delivered_unix_ms = 0
		ORDER BY created_unix_ms ASC, event_id ASC
		LIMIT ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("notification_outbox_replay_pending: prepare failed:", rc)
		return 0
	}
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, recipient_agent_instance_id)
	sqlite3_bind_int64(stmt, 2, TASK_NOTIFICATION_REPLAY_LIMIT)

	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&event_ids, strings.clone_from_cstring(sqlite3_column_text(stmt, 0)))
		append(&payloads, strings.clone_from_cstring(sqlite3_column_text(stmt, 1)))
	}

	_, _, is_remote := agent_remote_proxy_lookup(recipient_agent_instance_id)

	// Local agents: coalesce the whole pending backlog into ONE task_event_batch
	// message so an agent coming online after downtime gets a single combined
	// wake-up instead of N separate pane injections. Remote proxies keep the
	// per-event forward path (each event needs its own idempotency key/ACK).
	if !is_remote && len(event_ids) > 1 {
		batch := notification_outbox_build_batch_json(payloads[:])
		if registry_send_ws_text_or_remote(recipient_agent_instance_id, batch) {
			for i in 0..<len(event_ids) {
				_ = notification_outbox_mark_attempt(recipient_agent_instance_id, event_ids[i], true)
			}
			return len(event_ids)
		}
		// Batch send failed (e.g. socket vanished mid-flush); fall through to the
		// per-event path which records attempts and stops at the first failure.
	}

	delivered := 0
	for i in 0..<len(event_ids) {
		if is_remote {
			accepted := registry_send_ws_text_or_remote_transport_accepted(recipient_agent_instance_id, payloads[i])
			// Remote bridge acceptance is a transport attempt only; delivery_ack marks delivered.
			_ = notification_outbox_mark_attempt(recipient_agent_instance_id, event_ids[i], false)
			if !accepted do break
			continue
		}
		sent := registry_send_ws_text_or_remote(recipient_agent_instance_id, payloads[i])
		_ = notification_outbox_mark_attempt(recipient_agent_instance_id, event_ids[i], sent)
		if !sent do break
		delivered += 1
	}
	return delivered
}

// notification_outbox_build_batch_json wraps N task_event payloads into a single
// task_event_batch envelope. The batch is interrupt=true iff any child event is,
// so a queued nudge still breaks through on reconnect. Wrappers that predate the
// batch type simply ignore an unknown type; the events array carries the raw
// child payloads verbatim for forward/backward compatibility.
notification_outbox_build_batch_json :: proc(payloads: []string) -> string {
	b := strings.builder_make()
	any_interrupt := false
	for p in payloads {
		if extract_json_bool(p, "interrupt", false) { any_interrupt = true; break }
	}
	strings.write_string(&b, `{"type":"task_event_batch","count":`)
	strings.write_string(&b, fmt.tprintf("%d", len(payloads)))
	strings.write_string(&b, `,"interrupt":`)
	strings.write_string(&b, "true" if any_interrupt else "false")
	strings.write_string(&b, `,"send_escape_prefix":`)
	strings.write_string(&b, "true" if any_interrupt else "false")
	strings.write_string(&b, `,"events":[`)
	for p, i in payloads {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, p)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}
