package sqlite

import "core:testing"
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
test_migration_209_applies_and_is_idempotent :: proc(t: ^testing.T) {
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
	ok, err = run_migrations(&base, stop_before = "209_bots.sql")
	if !testing.expect(t, ok) || !bot_test_expect_ok(t, err) do return
	testing.expect(t, migration_applied(&base, "208_extension_version_sync_0_5_54.sql"))
	testing.expect(t, !migration_applied(&base, "209_bots.sql"))
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
	testing.expect(t, migration_applied(&copy, "209_bots.sql"))
	testing.expect(t, !migration_applied(&base, "209_bots.sql"))
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
