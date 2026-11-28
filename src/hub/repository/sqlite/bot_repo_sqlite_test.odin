package sqlite

import "core:testing"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

bot_test_expect_ok :: proc(t: ^testing.T, err: domain.Domain_Error) -> bool {
	return testing.expect_value(t, err.code, domain.Error_Code.None)
}
bot_test_row :: proc(id := "bot_a", owner := "alice") -> domain.Bot {
	return {
		bot_id = id,
		owner_user_id = owner,
		agent_id = "agt_a",
		display_name = "Ninjy bot",
		placement_revision = 1,
		created_at = "2026-11-17T00:00:00Z",
		updated_at = "2026-11-17T00:00:00Z",
	}
}
bot_test_message :: proc(id, update: string) -> domain.Channel_Message {
	return {
		message_id = id,
		binding_id = "chb_a",
		owner_user_id = "alice",
		bot_id = "bot_a",
		direction = .Inbound,
		provider_update_key = update,
		body = "hello",
		created_at = "2026-11-17T00:00:00Z",
	}
}
bot_test_delivery :: proc(id := "bdl_a") -> domain.Bot_Delivery {
	return {
		delivery_id = id,
		bot_id = "bot_a",
		owner_user_id = "alice",
		through_message_id = "chm_a",
		state = .Pending,
		round = 1,
		created_at = "2026-11-17T00:00:00Z",
		updated_at = "2026-11-17T00:00:00Z",
	}
}

@(test)
test_migration_213_applies_and_is_idempotent :: proc(t: ^testing.T) {
	fresh, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&fresh)
	ok, err := run_migrations(&fresh)
	if !testing.expect(t, ok) || !bot_test_expect_ok(t, err) do return
	ok, err = run_migrations(&fresh)
	testing.expect(t, ok)
	bot_test_expect_ok(t, err)
	base, base_open, _ := open(":memory:")
	if !testing.expect(t, base_open) do return
	defer close(&base)
	ok, err = run_migrations(&base, stop_before = "213_bots.sql")
	if !testing.expect(t, ok) || !bot_test_expect_ok(t, err) do return
	testing.expect(t, migration_applied(&base, "208_extension_version_sync_0_5_54.sql"))
	testing.expect(t, !migration_applied(&base, "213_bots.sql"))
	copy, copy_open, _ := open(":memory:")
	if !testing.expect(t, copy_open) do return
	defer close(&copy)
	backup := tmpl_sqlite3_backup_init(copy.db, "main", base.db, "main")
	if !testing.expect(t, backup != nil) do return
	testing.expect_value(t, tmpl_sqlite3_backup_step(backup, -1), SQLITE_DONE)
	testing.expect_value(t, tmpl_sqlite3_backup_finish(backup), SQLITE_OK)
	for _ in 0 ..< 2 {
		ok, err = run_migrations(&copy)
		testing.expect(t, ok)
		bot_test_expect_ok(t, err)
	}
	testing.expect(t, migration_applied(&copy, "213_bots.sql"))
	testing.expect(t, !migration_applied(&base, "213_bots.sql"))
	testing.expect(
		t,
		exec(
			&copy,
			"INSERT INTO bots (bot_id,owner_user_id,agent_id,created_at,updated_at) VALUES ('bot_a','alice','agt_a','now','now');",
		),
	)
}

@(test)
test_bot_one_per_owner :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	bot_test_expect_ok(t, iface.bot_insert(&repo, bot_test_row()))
	testing.expect_value(t, iface.bot_insert(&repo, bot_test_row("bot_b")).code, domain.Error_Code.Conflict)
	row, found, err := iface.bot_get_by_owner(&repo, "alice")
	defer domain.bot_destroy(&row)
	bot_test_expect_ok(t, err)
	testing.expect(t, found)
	testing.expect_value(t, row.bot_id, "bot_a")
	bot_test_expect_ok(t, iface.bot_set_instance(&repo, row.bot_id, "inst_a", "later"))
	inst_row, inst_found, inst_err := iface.bot_get_by_instance(&repo, "inst_a")
	defer domain.bot_destroy(&inst_row)
	bot_test_expect_ok(t, inst_err)
	testing.expect(t, inst_found)
	testing.expect_value(t, inst_row.agent_instance_id, "inst_a")
	_, empty_found, _ := iface.bot_get_by_instance(&repo, "")
	testing.expect(t, !empty_found)
}

@(test)
test_binding_unique_active_chat_and_owner :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	for code in ([]string{"one", "two", "three"}) {
		bot_test_expect_ok(
			t,
			iface.pairing_insert(
				&repo,
				{
					code_hash = code,
					owner_user_id = "alice",
					bot_id = "bot_a",
					provider = "telegram",
					created_at = "2026-01-01",
					expires_at = "2027-01-01",
				},
			),
		)
	}
	binding := domain.Channel_Binding {
		binding_id       = "chb_a",
		owner_user_id    = "alice",
		bot_id           = "bot_a",
		provider         = "telegram",
		external_chat_id = "123",
		external_user_id = "321",
		state            = .Active,
		created_at       = "2026-01-01",
	}
	previous, had_previous, err := iface.binding_activate(&repo, binding, "one", "2026-11-17")
	defer domain.channel_binding_destroy(&previous)
	bot_test_expect_ok(t, err)
	testing.expect(t, !had_previous)
	binding.binding_id = "chb_b"
	binding.external_chat_id = "456"
	previous2, had_previous2, err2 := iface.binding_activate(&repo, binding, "two", "2026-11-17")
	defer domain.channel_binding_destroy(&previous2)
	bot_test_expect_ok(t, err2)
	testing.expect(t, had_previous2)
	testing.expect_value(t, previous2.binding_id, "chb_a")
	_, old_active, _ := iface.binding_get_active_by_chat(&repo, "telegram", "123")
	testing.expect(t, !old_active)
	// A different owner cannot activate the same chat. Rollback retains pairing.
	bot_test_expect_ok(
		t,
		iface.pairing_insert(
			&repo,
			{
				code_hash = "bob",
				owner_user_id = "bob",
				bot_id = "bot_b",
				provider = "telegram",
				expires_at = "2027-01-01",
			},
		),
	)
	binding.binding_id = "chb_c"; binding.owner_user_id = "bob"; binding.bot_id = "bot_b"
	_, _, conflict := iface.binding_activate(&repo, binding, "bob", "2026-11-17")
	testing.expect_value(t, conflict.code, domain.Error_Code.Conflict)
	pairing, found, pair_err := iface.pairing_get(&repo, "bob")
	defer domain.channel_pairing_destroy(&pairing)
	bot_test_expect_ok(t, pair_err)
	testing.expect(t, found)
	testing.expect_value(t, pairing.consumed_at, "")
	// Reusing an already consumed code refuses activation.
	_, _, reused := iface.binding_activate(&repo, binding, "one", "2026-11-17")
	testing.expect_value(t, reused.code, domain.Error_Code.Conflict)
	// Direct writes also enforce the one-active-owner index.
	_, owner_conflict := bot_repo_write(
		&conn,
		"INSERT INTO channel_bindings (binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES ('chb_d','alice','bot_a','telegram','789','321','active','now');",
		{},
	)
	testing.expect_value(t, owner_conflict.code, domain.Error_Code.Conflict)
}

@(test)
test_inbound_store_batch_dedupes_update_key_and_advances_cursor_atomically :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	ids, err := iface.inbound_store_batch(
		&repo,
		"telegram",
		{bot_test_message("chm_a", "telegram:7:1"), bot_test_message("chm_b", "telegram:7:1")},
		"2",
		"now",
	)
	defer {for id in ids do delete(id); delete(ids)}
	bot_test_expect_ok(t, err)
	testing.expect_value(t, len(ids), 1)
	testing.expect_value(t, ids[0], "chm_a")
	cursor, found, cursor_err := iface.cursor_get(&repo, "telegram")
	defer delete(cursor)
	bot_test_expect_ok(t, cursor_err)
	testing.expect(t, found)
	testing.expect_value(t, cursor, "2")
	empty_ids, empty_err := iface.inbound_store_batch(&repo, "telegram", {}, "3", "later")
	defer delete(empty_ids)
	bot_test_expect_ok(t, empty_err)
	next, _, _ := iface.cursor_get(&repo, "telegram")
	defer delete(next)
	testing.expect_value(t, next, "3")
}

@(test)
test_inbound_store_batch_rollback_keeps_cursor :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	ids, err := iface.inbound_store_batch(&repo, "telegram", {}, "1", "now")
	delete(ids)
	bot_test_expect_ok(t, err)
	// Duplicate primary key with different update keys must fail, not be ignored.
	failed_ids, failed_err := iface.inbound_store_batch(
		&repo,
		"telegram",
		{bot_test_message("chm_a", "telegram:7:1"), bot_test_message("chm_a", "telegram:7:2")},
		"3",
		"now",
	)
	delete(failed_ids)
	testing.expect_value(t, failed_err.code, domain.Error_Code.Conflict)
	cursor, found, cursor_err := iface.cursor_get(&repo, "telegram")
	defer delete(cursor)
	bot_test_expect_ok(t, cursor_err)
	testing.expect(t, found)
	testing.expect_value(t, cursor, "1")
	rows, rows_err := iface.messages_pending(&repo, "bot_a", 10)
	defer delete(rows)
	bot_test_expect_ok(t, rows_err)
	testing.expect_value(t, len(rows), 0)
	// Failure updating the cursor also rolls back the newly inserted message.
	testing.expect(
		t,
		exec(
			&conn,
			"CREATE TRIGGER reject_bot_cursor BEFORE UPDATE ON channel_cursors BEGIN SELECT RAISE(ABORT,'cursor failed'); END;",
		),
	)
	rejected_ids, rejected_err := iface.inbound_store_batch(
		&repo,
		"telegram",
		{bot_test_message("chm_c", "telegram:7:3")},
		"4",
		"now",
	)
	delete(rejected_ids)
	testing.expect(t, rejected_err.code != .None)
	after, after_err := iface.messages_pending(&repo, "bot_a", 10)
	defer delete(after)
	bot_test_expect_ok(t, after_err)
	testing.expect_value(t, len(after), 0)
}

@(test)
test_delivery_one_open_per_bot :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	d := bot_test_delivery()
	bot_test_expect_ok(t, iface.delivery_insert(&repo, d))
	testing.expect_value(t, iface.delivery_insert(&repo, bot_test_delivery("bdl_b")).code, domain.Error_Code.Conflict)
	d.state = .Acted
	changed, err := iface.delivery_update(&repo, d, .Pending)
	bot_test_expect_ok(t, err)
	testing.expect(t, changed)
	changed, err = iface.delivery_update(&repo, d, .Pending)
	bot_test_expect_ok(t, err)
	testing.expect(t, !changed)
	bot_test_expect_ok(t, iface.delivery_insert(&repo, bot_test_delivery("bdl_b")))
	open, found, get_err := iface.delivery_get_open(&repo, "bot_a")
	defer domain.bot_delivery_destroy(&open)
	bot_test_expect_ok(t, get_err)
	testing.expect(t, found)
	testing.expect_value(t, open.delivery_id, "bdl_b")
	owners, owner_err := iface.bot_list_owners_with_open_deliveries(&repo)
	defer {for owner in owners do delete(owner); delete(owners)}
	bot_test_expect_ok(t, owner_err)
	testing.expect_value(t, len(owners), 1)
	testing.expect_value(t, owners[0], "alice")
}

@(test)
test_attempt_cas_rejects_stale_state :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	bot_test_expect_ok(t, iface.delivery_insert(&repo, bot_test_delivery()))
	a := domain.Bot_Delivery_Attempt {
		attempt_id      = "bda_a",
		delivery_id     = "bdl_a",
		round           = 1,
		bridge_id       = "brg_a",
		state           = .Sent,
		candidates_json = "[]",
		report_json     = "{}",
		created_at      = "now",
	}
	bot_test_expect_ok(t, iface.attempt_insert(&repo, a))
	a.attempt_id = "bda_b"
	testing.expect_value(t, iface.attempt_insert(&repo, a).code, domain.Error_Code.Conflict)
	a.attempt_id = "bda_a"; a.state = .Accepted; a.report_seq = 1; a.report_json = `{"state":"working"}`
	changed, err := iface.attempt_update(&repo, a, .Sent)
	bot_test_expect_ok(t, err)
	testing.expect(t, changed)
	a.state = .Exhausted; a.report_seq = 0
	changed, err = iface.attempt_update(&repo, a, .Sent)
	bot_test_expect_ok(t, err)
	testing.expect(t, !changed)
	saved, found, get_err := iface.attempt_get(&repo, "bda_a")
	defer domain.bot_delivery_attempt_destroy(&saved)
	bot_test_expect_ok(t, get_err)
	testing.expect(t, found)
	testing.expect_value(t, saved.state, domain.Bot_Attempt_State.Accepted)
	testing.expect_value(t, saved.report_seq, 1)
}

@(test)
test_messages_mark_replied_only_read_rows :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	ids, err := iface.inbound_store_batch(
		&repo,
		"telegram",
		{bot_test_message("chm_a", "telegram:7:1"), bot_test_message("chm_b", "telegram:7:2")},
		"3",
		"now",
	)
	defer {for id in ids do delete(id); delete(ids)}
	bot_test_expect_ok(t, err)
	outbound := bot_test_message("chm_c", "")
	outbound.direction = .Outbound
	outbound.send_state = .Pending
	bot_test_expect_ok(t, iface.message_insert_outbound(&repo, outbound))
	bot_test_expect_ok(t, iface.messages_mark_read(&repo, "bot_a", {"chm_a", "chm_c"}, "read"))
	bot_test_expect_ok(t, iface.messages_mark_read(&repo, "bot_a", {"chm_a"}, "later"))
	count, reply_err := iface.messages_mark_replied(&repo, "bot_a", "replied")
	bot_test_expect_ok(t, reply_err)
	testing.expect_value(t, count, 1)
	count, reply_err = iface.messages_mark_replied(&repo, "bot_a", "later")
	bot_test_expect_ok(t, reply_err)
	testing.expect_value(t, count, 0)
	bot_test_expect_ok(t, iface.message_set_send_result(&repo, "chm_c", .Sent, "999", ""))
	history, hist_err := iface.messages_history(&repo, "bot_a", 10)
	defer {for &row in history do domain.channel_message_destroy(&row); delete(history)}
	bot_test_expect_ok(t, hist_err)
	testing.expect_value(t, len(history), 3)
	for row in history {
		if row.message_id == "chm_a" {
			testing.expect_value(t, row.read_at, "read")
			testing.expect_value(t, row.replied_at, "replied")
		}
		if row.message_id == "chm_c" {
			testing.expect_value(t, row.read_at, "")
			testing.expect_value(t, row.replied_at, "")
			testing.expect_value(t, row.external_message_id, "999")
		}
	}
	pending, pending_err := iface.messages_pending(&repo, "bot_a", 10)
	defer {for &row in pending do domain.channel_message_destroy(&row); delete(pending)}
	bot_test_expect_ok(t, pending_err)
	testing.expect_value(t, len(pending), 1)
	testing.expect_value(t, pending[0].message_id, "chm_b")
}

@(test)
test_purge_older_than :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	old := bot_test_message("chm_a", "telegram:7:1")
	recent := bot_test_message("chm_b", "telegram:7:2")
	recent.created_at = "2026-11-18T00:00:00Z"
	ids, err := iface.inbound_store_batch(&repo, "telegram", {old, recent}, "3", "now")
	defer {for id in ids do delete(id); delete(ids)}
	bot_test_expect_ok(t, err)
	count, purge_err := iface.messages_purge_older_than(&repo, recent.created_at)
	bot_test_expect_ok(t, purge_err)
	testing.expect_value(t, count, 1)
	rows, rows_err := iface.messages_history(&repo, "bot_a", 10)
	defer {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}
	bot_test_expect_ok(t, rows_err)
	testing.expect_value(t, rows[0].body, "hello")
	testing.expect(t, rows[1].body_purged)
	testing.expect_value(t, rows[1].body, "")
	bot_test_expect_ok(t, iface.messages_purge_binding(&repo, "chb_a"))
	count, purge_err = iface.messages_purge_older_than(&repo, "2027")
	bot_test_expect_ok(t, purge_err)
	testing.expect_value(t, count, 0)
}

@(test)
test_bot_placement_replace_atomic_revision_and_cascade :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite
	repo := new_bot_repository(&impl, &conn)
	bot_test_expect_ok(t, iface.bot_insert(&repo, bot_test_row()))
	rows := []domain.Bot_Placement_Candidate {
		{position = 0, bridge_id = "*", provider = "*", model = "*", tier = .Allowed},
	}
	revision, err := iface.placement_replace(&repo, "bot_a", 1, rows, "later")
	bot_test_expect_ok(t, err)
	testing.expect_value(t, revision, 2)
	_, stale_err := iface.placement_replace(&repo, "bot_a", 1, {}, "later")
	testing.expect_value(t, stale_err.code, domain.Error_Code.Conflict)
	rows[0].model = "invalid-wildcard-model"
	_, invalid_err := iface.placement_replace(&repo, "bot_a", 2, rows, "later")
	testing.expect_value(t, invalid_err.code, domain.Error_Code.Conflict)
	saved, saved_err := iface.placement_list(&repo, "bot_a")
	defer {for &row in saved do domain.bot_placement_candidate_destroy(&row); delete(saved)}
	bot_test_expect_ok(t, saved_err)
	testing.expect_value(t, len(saved), 1)
	testing.expect_value(t, saved[0].model, "*")
	bot, found, get_err := iface.bot_get(&repo, "bot_a")
	defer domain.bot_destroy(&bot)
	bot_test_expect_ok(t, get_err)
	testing.expect(t, found)
	testing.expect_value(t, bot.placement_revision, 2)
	bot_test_expect_ok(t, iface.bot_delete(&repo, "bot_a"))
	deleted, deleted_err := iface.placement_list(&repo, "bot_a")
	defer delete(deleted)
	bot_test_expect_ok(t, deleted_err)
	testing.expect_value(t, len(deleted), 0)
}


// W1 fixtures deliberately keep foreign providers and owners in the same database.
w1_binding :: proc(
	t: ^testing.T,
	conn: ^Conn,
	id := "chb_a",
	provider := "whatsapp",
	owner := "alice",
	state := "active",
) {
	_, err := bot_repo_write(
		conn,
		"INSERT INTO channel_bindings (binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,external_display,state,created_at,last_inbound_at) VALUES (?,?, 'bot_a',?,?,?,'Fixture',?,'2026-01-01','2026-11-17T00:00:00Z');",
		{id, owner, provider, id, id, state},
	)
	bot_test_expect_ok(t, err)
}
w1_event :: proc(key := "wa:one") -> domain.Channel_Push_Event {
	return {
		provider = "whatsapp",
		event_key = key,
		kind = .Text,
		external_chat_id = "chb_a",
		external_user_id = "user",
		external_message_id = "wamid.one",
		sender_display = "Fixture",
		body = "hello",
		provider_time = "2026-11-18T00:00:00Z",
		received_at = "2026-11-18T00:00:01Z",
	}
}
w1_expect_scalar :: proc(t: ^testing.T, conn: ^Conn, sql, expected: string) {
	stmt, err := bot_repo_prepare(conn, sql, nil)
	if !bot_test_expect_ok(t, err) do return
	defer sqlite3_finalize(stmt)
	if !testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW) do return
	testing.expect_value(t, column_text_unowned(stmt, 0), expected)
}
w1_destroy_events :: proc(rows: []domain.Channel_Push_Event) {
	for &row in rows do domain.channel_push_event_destroy(&row)
	delete(rows)
}
w1_destroy_messages :: proc(rows: []domain.Channel_Message) {
	for &row in rows do domain.channel_message_destroy(&row)
	delete(rows)
}
w1_destroy_ids :: proc(ids: []string) {
	for id in ids do delete(id)
	delete(ids)
}

@(test)
test_migration_215_carries_existing_rows :: proc(t: ^testing.T) {
	base, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&base)
	ok, err := run_migrations(&base, stop_before = "215_bots_whatsapp.sql")
	if !testing.expect(t, ok) || !bot_test_expect_ok(t, err) do return
	// A1: inspect every schema object mentioning channel_; none may be a dependent
	// trigger/view, and no other table may carry a foreign key to these tables.
	stmt, scan_err := bot_repo_prepare(
		&base,
		"SELECT type,name,sql FROM sqlite_master WHERE sql LIKE '%channel_%';",
		nil,
	)
	if !bot_test_expect_ok(t, scan_err) do return
	for sqlite3_step(stmt) == SQLITE_ROW {
		kind := column_text_unowned(stmt, 0)
		name := column_text_unowned(stmt, 1)
		testing.expect(t, kind == "table" || kind == "index")
		if kind == "table" && name != "channel_bindings" && name != "channel_pairings" && name != "channel_messages" {
			testing.expect(
				t,
				!strings.contains(
					strings.to_lower(column_text_unowned(stmt, 2), context.temp_allocator),
					"references channel_",
				),
			)
		}
	}
	sqlite3_finalize(stmt)
	testing.expect(
		t,
		exec(
			&base,
			"INSERT INTO channel_bindings VALUES ('legacy','alice','bot_a','telegram','123','456','Legacy','active','created','revoked'); INSERT INTO channel_pairings VALUES ('hash','alice','bot_a','telegram','created','expires','consumed'); INSERT INTO channel_messages VALUES ('in','legacy','alice','bot_a','inbound','telegram:key','11','in body',0,'','in error','created-in','read-in','replied-in'); INSERT INTO channel_messages VALUES ('out','legacy','alice','bot_a','outbound','','22','out body',1,'failed','out error','created-out','read-out','replied-out');",
		),
	)
	// Keep the source pristine and migrate its SQLite backup, like a slice-1 upgrade.
	copy, copied, _ := open(":memory:")
	if !testing.expect(t, copied) do return
	defer close(&copy)
	backup := tmpl_sqlite3_backup_init(copy.db, "main", base.db, "main")
	if !testing.expect(t, backup != nil) do return
	testing.expect_value(t, tmpl_sqlite3_backup_step(backup, -1), SQLITE_DONE)
	testing.expect_value(t, tmpl_sqlite3_backup_finish(backup), SQLITE_OK)
	ok, err = run_migrations(&copy)
	testing.expect(t, ok); bot_test_expect_ok(t, err)
	w1_expect_scalar(
		t,
		&copy,
		"SELECT count(*) FROM channel_bindings WHERE binding_id='legacy' AND owner_user_id='alice' AND bot_id='bot_a' AND provider='telegram' AND external_chat_id='123' AND external_user_id='456' AND external_display='Legacy' AND state='active' AND created_at='created' AND revoked_at='revoked' AND last_inbound_at='' AND reengage_sent_at='' AND reengage_error='';",
		"1",
	)
	w1_expect_scalar(
		t,
		&copy,
		"SELECT count(*) FROM channel_pairings WHERE code_hash='hash' AND owner_user_id='alice' AND bot_id='bot_a' AND provider='telegram' AND created_at='created' AND expires_at='expires' AND consumed_at='consumed';",
		"1",
	)
	// Compare every original message column, including purged bodies and errors.
	// Read both databases column by column so every carried value is checked.
	a, ae := bot_repo_prepare(&base, "SELECT * FROM channel_messages ORDER BY message_id;", nil)
	b, be := bot_repo_prepare(&copy, "SELECT * FROM channel_messages ORDER BY message_id;", nil)
	if !bot_test_expect_ok(t, ae) || !bot_test_expect_ok(t, be) do return
	defer sqlite3_finalize(a); defer sqlite3_finalize(b)
	for _ in 0 ..< 2 {
		testing.expect_value(t, sqlite3_step(a), SQLITE_ROW)
		testing.expect_value(t, sqlite3_step(b), SQLITE_ROW)
		for col in 0 ..< 14 do testing.expect_value(t, column_text_unowned(b, col), column_text_unowned(a, col))
	}
	testing.expect(t, !migration_applied(&base, "215_bots_whatsapp.sql"))
	ok, err = run_migrations(&copy)
	testing.expect(t, ok); bot_test_expect_ok(t, err)
}

@(test)
test_migration_215_allows_whatsapp_and_held :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	w1_binding(t, &conn)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO channel_pairings (code_hash,owner_user_id,bot_id,provider,created_at,expires_at,consumed_at) VALUES ('wa','alice','bot_a','whatsapp','now','later',''); INSERT INTO channel_messages (message_id,binding_id,owner_user_id,bot_id,direction,body,send_state,created_at) VALUES ('held','chb_a','alice','bot_a','outbound','reply','held','now');",
		),
	)
	// The widened schema still refuses unknown providers and send states.
	testing.expect(t, !exec(&conn, "UPDATE channel_bindings SET provider='other';"))
	testing.expect(t, !exec(&conn, "UPDATE channel_messages SET send_state='other';"))
}

@(test)
test_migration_215_skip_guard_marks_applied :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	w1_binding(t, &conn)
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='215_bots_whatsapp.sql';"))
	applied, err := run_migrations(&conn)
	testing.expect(t, applied); bot_test_expect_ok(t, err)
	testing.expect(t, migration_applied(&conn, "215_bots_whatsapp.sql"))
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_bindings;", "1")
}

@(test)
test_push_events_insert_dedupes_event_key :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	e := w1_event()
	n, err := iface.push_events_insert(&repo, {e, e, w1_event("wa:two")})
	bot_test_expect_ok(t, err); testing.expect_value(t, n, 2)
	n, err = iface.push_events_insert(&repo, {e})
	bot_test_expect_ok(t, err); testing.expect_value(t, n, 0)
	rows, read_err := iface.push_events_pending(&repo, "whatsapp", 1)
	defer w1_destroy_events(rows)
	bot_test_expect_ok(t, read_err)
	if !testing.expect_value(t, len(rows), 1) do return
	testing.expect_value(t, rows[0].event_key, e.event_key)
	testing.expect_value(t, rows[0].body, e.body)
	testing.expect_value(t, rows[0].provider_time, e.provider_time)
	testing.expect_value(t, rows[0].external_user_id, e.external_user_id)
	testing.expect_value(t, rows[0].sender_display, e.sender_display)
	// A late statement failure rolls back earlier inserts too.
	testing.expect(
		t,
		exec(
			&conn,
			"CREATE TRIGGER reject_push BEFORE INSERT ON channel_push_events WHEN NEW.event_key='reject' BEGIN SELECT RAISE(ABORT,'reject'); END;",
		),
	)
	n, err = iface.push_events_insert(&repo, {w1_event("new"), w1_event("reject")})
	testing.expect(t, err.code != .None); testing.expect_value(t, n, 0)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_push_events;", "2")
}

@(test)
test_push_batch_commit_is_atomic :: proc(t: ^testing.T) {
	// Fail at each stage, including after rows and touches have already changed.
	for stage in ([]string{"row", "touch", "mark"}) {
		conn, ok := tmpl_clone_migrated(t); if !ok do return
		w1_binding(t, &conn)
		impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
		n, err := iface.push_events_insert(&repo, {w1_event()})
		bot_test_expect_ok(t, err); testing.expect_value(t, n, 1)
		events, read_err := iface.push_events_pending(&repo, "whatsapp", 10)
		bot_test_expect_ok(t, read_err)
		if len(events) != 1 {w1_destroy_events(events); close(&conn); return}
		trigger := ""
		switch stage {
		case "row":
			trigger = "CREATE TRIGGER reject_stage BEFORE INSERT ON channel_messages WHEN NEW.message_id='chm_b' BEGIN SELECT RAISE(ABORT,'row'); END;"
		case "touch":
			trigger = "CREATE TRIGGER reject_stage BEFORE UPDATE ON channel_bindings BEGIN SELECT RAISE(ABORT,'touch'); END;"
		case "mark":
			trigger = "CREATE TRIGGER reject_stage BEFORE UPDATE ON channel_push_events BEGIN SELECT RAISE(ABORT,'mark'); END;"
		}
		testing.expect(t, exec(&conn, trigger))
		rows := []domain.Channel_Message{bot_test_message("chm_a", "wa:1"), bot_test_message("chm_b", "wa:2")}
		touches := []domain.Channel_Inbound_Touch{{binding_id = "chb_a", at = "2026-11-18T00:00:00Z"}}
		ids, commit_err := iface.push_batch_commit(&repo, rows, touches, {events[0].seq}, "processed")
		testing.expect(t, commit_err.code != .None); testing.expect_value(t, len(ids), 0)
		w1_destroy_ids(ids)
		w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages;", "0")
		w1_expect_scalar(t, &conn, "SELECT last_inbound_at FROM channel_bindings;", "2026-11-17T00:00:00Z")
		w1_expect_scalar(t, &conn, "SELECT body FROM channel_push_events WHERE processed_at='';", "hello")
		testing.expect(t, exec(&conn, "DROP TRIGGER reject_stage;"))
		ids, commit_err = iface.push_batch_commit(&repo, rows, touches, {events[0].seq}, "processed")
		bot_test_expect_ok(t, commit_err); testing.expect_value(t, len(ids), 2)
		w1_destroy_ids(ids)
		ids, commit_err = iface.push_batch_commit(&repo, rows, touches, {events[0].seq}, "later")
		bot_test_expect_ok(t, commit_err); testing.expect_value(t, len(ids), 0)
		w1_destroy_ids(ids)
		w1_expect_scalar(t, &conn, "SELECT processed_at || ':' || body FROM channel_push_events;", "processed:")
		w1_destroy_events(events); close(&conn)
	}
}

@(test)
test_push_batch_touch_keeps_latest_and_clears_reengage :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	w1_binding(t, &conn); w1_binding(t, &conn, "revoked", "whatsapp", "bob", "revoked")
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	bot_test_expect_ok(t, iface.binding_set_reengage(&repo, "chb_a", "sent", "send_failed"))
	touches := []domain.Channel_Inbound_Touch {
		{"chb_a", "2026-11-19T00:00:00Z"},
		{"chb_a", "2026-11-18T00:00:00Z"},
		{"revoked", "2026-11-20T00:00:00Z"},
	}
	ids, err := iface.push_batch_commit(&repo, nil, touches, nil, "now")
	defer w1_destroy_ids(ids); bot_test_expect_ok(t, err)
	row, found, get_err := iface.binding_get(&repo, "chb_a")
	defer domain.channel_binding_destroy(&row)
	bot_test_expect_ok(t, get_err); testing.expect(t, found)
	testing.expect_value(t, row.last_inbound_at, "2026-11-19T00:00:00Z")
	testing.expect_value(t, row.reengage_sent_at, ""); testing.expect_value(t, row.reengage_error, "")
	w1_expect_scalar(
		t,
		&conn,
		"SELECT last_inbound_at FROM channel_bindings WHERE binding_id='revoked';",
		"2026-11-17T00:00:00Z",
	)
}

@(test)
test_binding_get_active_by_user :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	w1_binding(t, &conn)
	w1_binding(t, &conn, "old", "whatsapp", "bob", "revoked")
	testing.expect(
		t,
		exec(&conn, "UPDATE channel_bindings SET external_user_id='chb_a', created_at='2027' WHERE binding_id='old';"),
	)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	row, found, err := iface.binding_get_active_by_user(&repo, "whatsapp", "chb_a")
	defer domain.channel_binding_destroy(&row)
	bot_test_expect_ok(t, err); testing.expect(t, found)
	testing.expect_value(t, row.binding_id, "chb_a")
	empty, other, other_err := iface.binding_get_active_by_user(&repo, "telegram", "chb_a")
	defer domain.channel_binding_destroy(&empty)
	bot_test_expect_ok(t, other_err); testing.expect(t, !other)
	// Exercise activation's new timestamp and both existing SELECT paths.
	bot_test_expect_ok(
		t,
		iface.pairing_insert(
			&repo,
			{
				code_hash = "pair",
				owner_user_id = "carol",
				bot_id = "bot_a",
				provider = "whatsapp",
				expires_at = "2028",
			},
		),
	)
	previous, _, activate_err := iface.binding_activate(
		&repo,
		{
			binding_id = "new",
			owner_user_id = "carol",
			bot_id = "bot_a",
			provider = "whatsapp",
			external_chat_id = "new",
			external_user_id = "new",
			state = .Active,
			created_at = "2026",
			last_inbound_at = "2026-11-18T00:00:00Z",
		},
		"pair",
		"2026",
	)
	defer domain.channel_binding_destroy(&previous)
	bot_test_expect_ok(t, activate_err)
	by_owner, _, owner_err := iface.binding_get_active_by_owner(&repo, "carol", "whatsapp")
	defer domain.channel_binding_destroy(&by_owner)
	bot_test_expect_ok(t, owner_err); testing.expect_value(t, by_owner.last_inbound_at, "2026-11-18T00:00:00Z")
	by_chat, _, chat_err := iface.binding_get_active_by_chat(&repo, "whatsapp", "new")
	defer domain.channel_binding_destroy(&by_chat)
	bot_test_expect_ok(t, chat_err); testing.expect_value(t, by_chat.last_inbound_at, by_owner.last_inbound_at)
}

@(test)
test_bindings_active_for_owner_orders_telegram_first :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	w1_binding(t, &conn); w1_binding(t, &conn, "tg", "telegram")
	w1_binding(t, &conn, "other", "whatsapp", "bob")
	w1_binding(t, &conn, "old", "telegram", "alice", "revoked")
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	rows, err := iface.bindings_active_for_owner(&repo, "alice")
	defer {for &row in rows do domain.channel_binding_destroy(&row); delete(rows)}
	bot_test_expect_ok(t, err)
	if !testing.expect_value(t, len(rows), 2) do return
	testing.expect_value(t, rows[0].provider, "telegram")
	testing.expect_value(t, rows[1].provider, "whatsapp")
}

@(test)
test_binding_set_reengage_only_active :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	w1_binding(t, &conn); w1_binding(t, &conn, "old", "whatsapp", "bob", "revoked")
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	for id in ([]string{"chb_a", "old", "absent"}) do bot_test_expect_ok(t, iface.binding_set_reengage(&repo, id, "sent", "template_unavailable"))
	w1_expect_scalar(
		t,
		&conn,
		"SELECT reengage_sent_at || ':' || reengage_error FROM channel_bindings WHERE binding_id='chb_a';",
		"sent:template_unavailable",
	)
	w1_expect_scalar(
		t,
		&conn,
		"SELECT reengage_sent_at || ':' || reengage_error FROM channel_bindings WHERE binding_id='old';",
		":",
	)
}

@(test)
test_messages_mark_replied_binding_is_scoped :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	a := bot_test_message("a", "a"); a.read_at = "read"
	b := bot_test_message("b", "b"); b.binding_id = "other"
	c := bot_test_message("c", "c"); c.bot_id = "other"
	ids, err := iface.push_batch_commit(&repo, {a, b, c, bot_test_message("unread", "u")}, nil, nil, "now")
	defer w1_destroy_ids(ids); bot_test_expect_ok(t, err)
	bot_test_expect_ok(t, iface.messages_mark_read(&repo, "bot_a", {"a", "b"}, "read"))
	bot_test_expect_ok(t, iface.messages_mark_read(&repo, "other", {"c"}, "read"))
	n, reply_err := iface.messages_mark_replied_binding(&repo, "bot_a", "chb_a", "replied")
	bot_test_expect_ok(t, reply_err); testing.expect_value(t, n, 1)
	n, reply_err = iface.messages_mark_replied_binding(&repo, "bot_a", "chb_a", "later")
	bot_test_expect_ok(t, reply_err); testing.expect_value(t, n, 0)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages WHERE replied_at='';", "3")
}

w1_held :: proc(t: ^testing.T, repo: ^iface.Bot_Repository, id, at: string, binding := "chb_a", purged := false) {
	row := bot_test_message(id, "")
	row.direction = .Outbound; row.send_state = .Held; row.created_at = at; row.binding_id = binding; row.body_purged = purged; row.external_message_id = id
	bot_test_expect_ok(t, iface.message_insert_outbound(repo, row))
}

@(test)
test_messages_held_oldest_first_excludes_purged :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	w1_held(t, &repo, "b", "2026"); w1_held(t, &repo, "a", "2026"); w1_held(t, &repo, "c", "2027")
	w1_held(t, &repo, "purged", "2025", purged = true); w1_held(t, &repo, "other", "2025", "other")
	rows, err := iface.messages_held(&repo, "chb_a")
	defer w1_destroy_messages(rows); bot_test_expect_ok(t, err)
	if !testing.expect_value(t, len(rows), 3) do return
	expected := []string{"a", "b", "c"}
	for row, i in rows do testing.expect_value(t, row.message_id, expected[i])
}

@(test)
test_purge_expires_held_rows :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	w1_held(t, &repo, "old", "2025"); w1_held(t, &repo, "recent", "2027"); w1_held(t, &repo, "other", "2027", "other")
	n, err := iface.messages_purge_older_than(&repo, "2026")
	bot_test_expect_ok(t, err); testing.expect_value(t, n, 1)
	w1_expect_scalar(
		t,
		&conn,
		"SELECT send_state || ':' || send_error || ':' || body FROM channel_messages WHERE message_id='old';",
		"failed:held_expired:",
	)
	bot_test_expect_ok(t, iface.messages_purge_binding(&repo, "chb_a"))
	w1_expect_scalar(
		t,
		&conn,
		"SELECT send_state || ':' || send_error || ':' || body FROM channel_messages WHERE message_id='recent';",
		"failed:held_expired:",
	)
	w1_expect_scalar(t, &conn, "SELECT send_state FROM channel_messages WHERE message_id='other';", "held")
}

@(test)
test_message_get_outbound_by_external :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	w1_held(t, &repo, "wamid", "now")
	row, found, err := iface.message_get_outbound_by_external(&repo, "chb_a", "wamid")
	defer domain.channel_message_destroy(&row)
	bot_test_expect_ok(t, err); testing.expect(t, found); testing.expect_value(t, row.message_id, "wamid")
	empty, other, other_err := iface.message_get_outbound_by_external(&repo, "other", "wamid")
	defer domain.channel_message_destroy(&empty)
	bot_test_expect_ok(t, other_err); testing.expect(t, !other)
}

@(test)
test_push_events_purge_processed_keeps_unprocessed :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	a := w1_event("processed"); a.processed_at = "done"; a.received_at = "2025"
	b := w1_event("pending"); b.received_at = "2025"
	c := w1_event("recent"); c.processed_at = "done"; c.received_at = "2027"
	n, err := iface.push_events_insert(&repo, {a, b, c})
	bot_test_expect_ok(t, err); testing.expect_value(t, n, 3)
	n, err = iface.push_events_purge_processed(&repo, "2026")
	bot_test_expect_ok(t, err); testing.expect_value(t, n, 1)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_push_events;", "2")
	rows, read_err := iface.push_events_pending(&repo, "whatsapp", 10)
	defer w1_destroy_events(rows); bot_test_expect_ok(t, read_err)
	if testing.expect_value(t, len(rows), 1) do testing.expect_value(t, rows[0].event_key, "pending")
}

// D1 fixtures use borrowed input metadata; repository outputs own all strings.
d1_message :: proc(id := "chm_media", update := "media:key", attachment_id := "cha_media") -> domain.Channel_Message {
	msg := bot_test_message(id, update)
	msg.attachment = {
		attachment_id = attachment_id, kind = .Document, file_ref = "provider-ref",
		name = "report.pdf", mime = "application/pdf", size_bytes = 1234, state = .Pending,
		// The repository must replace identity and timestamps from the message.
		message_id = "wrong", binding_id = "wrong", owner_user_id = "wrong",
		bot_id = "wrong", direction = .Outbound, created_at = "wrong", updated_at = "wrong",
	}
	return msg
}
d1_destroy_attachments :: proc(rows: []domain.Channel_Attachment) {
	for &row in rows do domain.channel_attachment_destroy(&row)
	delete(rows)
}
d1_insert_inbound :: proc(t: ^testing.T, repo: ^iface.Bot_Repository, msg: domain.Channel_Message) {
	ids, err := iface.inbound_store_batch(repo, "telegram", {msg}, "next", "now")
	defer w1_destroy_ids(ids)
	bot_test_expect_ok(t, err)
	testing.expect_value(t, len(ids), 1)
}

@(test)
test_migration_216_carries_push_events :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, err := run_migrations(&conn, stop_before = "216_bots_media.sql")
	if !testing.expect(t, ok) || !bot_test_expect_ok(t, err) do return
	// A1: no dependent views/triggers or foreign keys reference the rebuilt table.
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM sqlite_master WHERE type IN ('trigger','view') AND sql LIKE '%channel_push_events%';", "0")
	stmt, scan_err := bot_repo_prepare(&conn, "SELECT name FROM sqlite_master WHERE type='table';", nil)
	if !bot_test_expect_ok(t, scan_err) do return
	for sqlite3_step(stmt) == SQLITE_ROW {
		name := column_text_unowned(stmt, 0)
		fk, fk_err := bot_repo_prepare(&conn, fmt.tprintf("PRAGMA foreign_key_list('%s');", name), nil)
		if !bot_test_expect_ok(t, fk_err) do continue
		for sqlite3_step(fk) == SQLITE_ROW do testing.expect(t, column_text_unowned(fk, 2) != "channel_push_events")
		sqlite3_finalize(fk)
	}
	sqlite3_finalize(stmt)
	testing.expect(t, exec(&conn, "INSERT INTO channel_push_events VALUES (7,'whatsapp','pending','text','chat-a','user-a','msg-a','Sender A','body-a',42,'time-a','received-a',''), (41,'whatsapp','processed','delivery_failed','chat-b','user-b','msg-b','Sender B','',131047,'time-b','received-b','processed-b');"))
	// Keep a SQL copy containing all old columns to compare every value and seq.
	testing.expect(t, exec(&conn, "CREATE TEMP TABLE d1_before AS SELECT * FROM channel_push_events;"))
	ok, err = run_migrations(&conn)
	testing.expect(t, ok); bot_test_expect_ok(t, err)
	columns := "seq,provider,event_key,kind,external_chat_id,external_user_id,external_message_id,sender_display,body,provider_code,provider_time,received_at,processed_at"
	w1_expect_scalar(t, &conn, fmt.tprintf("SELECT count(*) FROM (SELECT %s FROM channel_push_events EXCEPT SELECT * FROM d1_before);", columns), "0")
	w1_expect_scalar(t, &conn, fmt.tprintf("SELECT count(*) FROM (SELECT * FROM d1_before EXCEPT SELECT %s FROM channel_push_events);", columns), "0")
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_push_events WHERE media_kind='' AND media_ref='' AND media_name='' AND media_mime='' AND media_size=0;", "2")
	testing.expect(t, exec(&conn, "INSERT INTO channel_push_events (provider,event_key,kind,external_chat_id,received_at) VALUES ('whatsapp','new','text','chat','now');"))
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_push_events WHERE event_key='new' AND seq>41;", "1")
}

@(test)
test_migration_216_allows_media_kind :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	testing.expect(t, exec(&conn, "INSERT INTO channel_push_events (provider,event_key,kind,external_chat_id,received_at,media_kind) VALUES ('whatsapp','media','media','chat','now','image');"))
	testing.expect(t, !exec(&conn, "UPDATE channel_push_events SET media_kind='video';"))
	testing.expect(t, !exec(&conn, "UPDATE channel_push_events SET kind='other';"))
}

@(test)
test_migration_216_skip_guard_marks_applied :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	d1_insert_inbound(t, &repo, d1_message())
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='216_bots_media.sql';"))
	applied, err := run_migrations(&conn)
	testing.expect(t, applied); bot_test_expect_ok(t, err)
	testing.expect(t, migration_applied(&conn, "216_bots_media.sql"))
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_attachments;", "1")
}

@(test)
test_inbound_store_batch_writes_attachment_once :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	d1_insert_inbound(t, &repo, d1_message())
	ids, err := iface.inbound_store_batch(&repo, "telegram", {d1_message("duplicate", "media:key", "cha_duplicate")}, "again", "later")
	defer w1_destroy_ids(ids)
	bot_test_expect_ok(t, err); testing.expect_value(t, len(ids), 0)
	a, found, read_err := iface.attachment_get(&repo, "cha_media")
	defer domain.channel_attachment_destroy(&a)
	bot_test_expect_ok(t, read_err); testing.expect(t, found)
	testing.expect_value(t, a.message_id, "chm_media")
	testing.expect_value(t, a.binding_id, "chb_a")
	testing.expect_value(t, a.owner_user_id, "alice")
	testing.expect_value(t, a.bot_id, "bot_a")
	testing.expect_value(t, a.direction, domain.Channel_Direction.Inbound)
	testing.expect_value(t, a.created_at, "2026-11-17T00:00:00Z")
	testing.expect_value(t, a.updated_at, a.created_at)
	testing.expect_value(t, a.file_ref, "provider-ref")
	testing.expect_value(t, a.name, "report.pdf")
	testing.expect_value(t, a.mime, "application/pdf")
	testing.expect_value(t, a.size_bytes, i64(1234))
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_attachments;", "1")
	// Attachment failure rolls back both messages and the cursor.
	bad := d1_message("bad", "new-key", "cha_media")
	failed, failed_err := iface.inbound_store_batch(&repo, "telegram", {bad}, "bad-cursor", "later")
	defer w1_destroy_ids(failed)
	testing.expect(t, failed_err.code != .None)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages;", "1")
	w1_expect_scalar(t, &conn, "SELECT cursor FROM channel_cursors;", "again")
}

@(test)
test_push_batch_commit_writes_attachment_and_blanks_media_ref :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	event := w1_event(); event.kind = .Media; event.media_kind = .Document
	event.media_ref = "provider-ref"; event.media_name = "report.pdf"
	event.media_mime = "application/pdf"; event.media_size = 1234
	_, err := iface.push_events_insert(&repo, {event}); bot_test_expect_ok(t, err)
	events, read_err := iface.push_events_pending(&repo, "whatsapp", 10)
	defer w1_destroy_events(events); bot_test_expect_ok(t, read_err)
	if !testing.expect_value(t, len(events), 1) do return
	msg := d1_message()
	msg.direction = .Outbound // push writes are always persisted as inbound.
	// Failure in attachment insert must leave the push event pending.
	testing.expect(t, exec(&conn, "CREATE TRIGGER d1_reject BEFORE INSERT ON channel_attachments BEGIN SELECT RAISE(ABORT,'reject'); END;"))
	failed, failed_err := iface.push_batch_commit(&repo, {msg}, nil, {events[0].seq}, "processed")
	w1_destroy_ids(failed); testing.expect(t, failed_err.code != .None)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages;", "0")
	w1_expect_scalar(t, &conn, "SELECT media_ref FROM channel_push_events WHERE processed_at='';", "provider-ref")
	testing.expect(t, exec(&conn, "DROP TRIGGER d1_reject;"))
	ids, write_err := iface.push_batch_commit(&repo, {msg}, nil, {events[0].seq}, "processed")
	defer w1_destroy_ids(ids); bot_test_expect_ok(t, write_err)
	testing.expect_value(t, len(ids), 1)
	duplicate, duplicate_err := iface.push_batch_commit(&repo, {msg}, nil, {events[0].seq}, "again")
	defer w1_destroy_ids(duplicate); bot_test_expect_ok(t, duplicate_err)
	testing.expect_value(t, len(duplicate), 0)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_attachments;", "1")
	w1_expect_scalar(t, &conn, "SELECT direction FROM channel_attachments;", "inbound")
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_push_events WHERE processed_at='processed' AND body='' AND media_ref='' AND media_name='' AND media_mime='application/pdf' AND media_size=1234;", "1")
}

@(test)
test_message_insert_outbound_with_attachment_is_atomic :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	msg := d1_message(); msg.direction = .Outbound; msg.attachment.state = .Native
	bot_test_expect_ok(t, iface.message_insert_outbound(&repo, msg))
	// Exercise nested savepoints; an attachment conflict cannot undo outer work.
	testing.expect(t, exec(&conn, "BEGIN IMMEDIATE;"))
	bad := d1_message("bad", "bad-key"); bad.direction = .Outbound
	testing.expect(t, iface.message_insert_outbound(&repo, bad).code != .None)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages WHERE message_id='bad';", "0")
	w1_expect_scalar(t, &conn, "SELECT direction FROM channel_attachments;", "outbound")
	good := d1_message("nested", "nested-key", "cha_nested"); good.direction = .Outbound
	bot_test_expect_ok(t, iface.message_insert_outbound(&repo, good))
	testing.expect(t, exec(&conn, "ROLLBACK;"))
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages;", "1")
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_attachments;", "1")
	bad.message_id = "bad-outside"; bad.provider_update_key = "bad-outside"
	testing.expect(t, iface.message_insert_outbound(&repo, bad).code != .None)
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages;", "1")
}

@(test)
test_attachments_for_messages_chunks_over_500 :: proc(t: ^testing.T) {
	// Empty input returns before even accessing a connection.
	empty, empty_err := attachments_for_messages_sqlite(nil, nil)
	defer d1_destroy_attachments(empty); bot_test_expect_ok(t, empty_err)
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	messages := make([]domain.Channel_Message, 1003, context.temp_allocator)
	ids := make([]string, len(messages), context.temp_allocator)
	for &msg, i in messages {
		ids[i] = fmt.tprintf("chm_%d", i)
		msg = d1_message(ids[i], fmt.tprintf("key_%d", i), fmt.tprintf("cha_%d", i))
	}
	inserted, err := iface.inbound_store_batch(&repo, "telegram", messages, "cursor", "now")
	defer w1_destroy_ids(inserted); bot_test_expect_ok(t, err)
	rows, read_err := iface.attachments_for_messages(&repo, ids)
	defer d1_destroy_attachments(rows); bot_test_expect_ok(t, read_err)
	testing.expect_value(t, len(rows), 1003)
	seen := make(map[string]bool, context.temp_allocator)
	for row in rows {
		testing.expect(t, !seen[row.message_id])
		seen[row.message_id] = true
	}
	for id in ids do testing.expect(t, seen[id])
}

@(test)
test_attachment_store_artifact_first_writer_wins :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	d1_insert_inbound(t, &repo, d1_message())
	first, err := iface.attachment_store_artifact(&repo, "cha_media", "art_first", "first")
	defer delete(first); bot_test_expect_ok(t, err)
	second, second_err := iface.attachment_store_artifact(&repo, "cha_media", "art_second", "second")
	defer delete(second); bot_test_expect_ok(t, second_err)
	testing.expect_value(t, first, "art_first"); testing.expect_value(t, second, first)
	a, found, read_err := iface.attachment_get(&repo, "cha_media")
	defer domain.channel_attachment_destroy(&a); bot_test_expect_ok(t, read_err)
	testing.expect(t, found); testing.expect_value(t, a.state, domain.Channel_Attachment_State.Stored)
	testing.expect_value(t, a.updated_at, "first")
	missing, missing_err := iface.attachment_store_artifact(&repo, "missing", "art", "now")
	defer delete(missing); bot_test_expect_ok(t, missing_err); testing.expect_value(t, missing, "")
	out := d1_message("out", "", "cha_out"); out.direction = .Outbound; out.attachment.state = .Native
	bot_test_expect_ok(t, iface.message_insert_outbound(&repo, out))
	ignored, ignored_err := iface.attachment_store_artifact(&repo, "cha_out", "art", "now")
	defer delete(ignored); bot_test_expect_ok(t, ignored_err); testing.expect_value(t, ignored, "")
	// The savepoint also composes with caller rollback.
	d1_insert_inbound(t, &repo, d1_message("nested", "nested", "cha_nested"))
	testing.expect(t, exec(&conn, "BEGIN IMMEDIATE;"))
	nested, nested_err := iface.attachment_store_artifact(&repo, "cha_nested", "art_nested", "now")
	defer delete(nested); bot_test_expect_ok(t, nested_err)
	testing.expect(t, exec(&conn, "ROLLBACK;"))
	w1_expect_scalar(t, &conn, "SELECT state || ':' || artifact_id FROM channel_attachments WHERE attachment_id='cha_nested';", "pending:")
}

@(test)
test_attachment_set_state_compare_and_set :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	d1_insert_inbound(t, &repo, d1_message())
	changed, err := iface.attachment_set_state(&repo, "cha_media", .Pending, .Too_Large, "first")
	bot_test_expect_ok(t, err); testing.expect(t, changed)
	changed, err = iface.attachment_set_state(&repo, "cha_media", .Pending, .Unavailable, "second")
	bot_test_expect_ok(t, err); testing.expect(t, !changed)
	ignored, ignored_err := iface.attachment_store_artifact(&repo, "cha_media", "art", "second")
	defer delete(ignored); bot_test_expect_ok(t, ignored_err); testing.expect_value(t, ignored, "")
	w1_expect_scalar(t, &conn, "SELECT state || ':' || updated_at FROM channel_attachments;", "too_large:first")
}

@(test)
test_purge_deletes_attachments_of_purged_messages :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	a := d1_message("a", "a", "cha_a")
	b := d1_message("b", "b", "cha_b"); b.binding_id = "other"
	c := d1_message("c", "c", "cha_c"); c.binding_id = "other"; c.created_at = "2027"
	ids, err := iface.inbound_store_batch(&repo, "telegram", {a,b,c}, "cursor", "now")
	defer w1_destroy_ids(ids); bot_test_expect_ok(t, err)
	bot_test_expect_ok(t, iface.messages_purge_binding(&repo, "chb_a"))
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_attachments;", "2")
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages WHERE message_id='a' AND body_purged=1 AND body='';", "1")
	count, purge_err := iface.messages_purge_older_than(&repo, "2026-12")
	bot_test_expect_ok(t, purge_err); testing.expect_value(t, count, 1)
	w1_expect_scalar(t, &conn, "SELECT attachment_id FROM channel_attachments;", "cha_c")
	w1_expect_scalar(t, &conn, "SELECT count(*) FROM channel_messages;", "3")
}

@(test)
test_push_events_media_roundtrip :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t); if !ok do return
	defer close(&conn)
	impl: Bot_Repo_SQLite; repo := new_bot_repository(&impl, &conn)
	for kind in domain.Channel_Media_Kind {
		if kind == .None do continue
		event := w1_event(fmt.tprintf("key_%d", int(kind)))
		event.kind = .Media; event.media_kind = kind; event.media_ref = "ref"
		event.media_name = "file"; event.media_mime = "application/octet-stream"; event.media_size = 9876543210
		n, err := iface.push_events_insert(&repo, {event})
		bot_test_expect_ok(t, err); testing.expect_value(t, n, 1)
	}
	rows, err := iface.push_events_pending(&repo, "whatsapp", 10)
	defer w1_destroy_events(rows); bot_test_expect_ok(t, err)
	if !testing.expect_value(t, len(rows), 4) do return
	for row, i in rows {
		testing.expect_value(t, row.kind, domain.Channel_Push_Kind.Media)
		testing.expect_value(t, row.media_kind, domain.Channel_Media_Kind(i+1))
		testing.expect_value(t, row.media_ref, "ref")
		testing.expect_value(t, row.media_name, "file")
		testing.expect_value(t, row.media_mime, "application/octet-stream")
		testing.expect_value(t, row.media_size, i64(9876543210))
	}
}
