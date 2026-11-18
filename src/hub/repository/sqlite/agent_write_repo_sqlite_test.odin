package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_migration_210_applies_fresh_and_upgrade :: proc(t: ^testing.T) {
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
	ok, err = run_migrations(&base, stop_before = "210_agent_writes.sql")
	if !testing.expect(t, ok) || !bot_test_expect_ok(t, err) do return
	testing.expect(t, migration_applied(&base, "209_bots.sql"))
	testing.expect(t, !migration_applied(&base, "210_agent_writes.sql"))
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
	testing.expect(t, migration_applied(&copy, "210_agent_writes.sql"))
	testing.expect(t, !migration_applied(&base, "210_agent_writes.sql"))

	for name in ([]string{"agent_writes_owner_seq", "agent_writes_owner_resource"}) {
		stmt, err := bot_repo_prepare(
			&copy,
			"SELECT 1 FROM sqlite_master WHERE type='index' AND name=?;",
			[]string{name},
		)
		if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
		testing.expect_value(t, sqlite3_step(stmt), SQLITE_ROW)
		sqlite3_finalize(stmt)
	}
	testing.expect(
		t,
		exec(
			&copy,
			"INSERT INTO agent_writes (write_id,owner_user_id,actor_agent_instance_id,resource_kind,resource_id,action,created_at) VALUES ('awr_test','a','i','memory','m','create','now');",
		),
	)
}

@(test)
test_agent_write_insert_and_list :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Agent_Write_Repo_SQLite
	repo := new_agent_write_repository(&impl, &conn)
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO agent_instances (agent_instance_id,agent_id,owner_user_id,bridge_id,display_name,runtime_status,created_at,updated_at) VALUES ('inst_write','agt_write','alice','brg_write','Writer','running','now','now');",
		),
	)
	for owner in ([]string{"alice", "bob", "alice"}) {
		err := iface.agent_write_insert(
			&repo,
			{
				owner_user_id = owner,
				actor_agent_instance_id = "inst_write",
				actor_agent_id = "forged",
				write_id = "forged",
				created_at = "forged",
				resource_kind = "memory",
				resource_id = "mem_write",
				action = "update",
				fields = []string{"title", "body"},
			},
		)
		testing.expect_value(t, err.code, domain.Error_Code.None)
	}
	rows, err := iface.agent_write_list_by_owner(&repo, "alice", 0, 10)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer {for &w in rows do domain.agent_write_destroy(&w); delete(rows)}
	if !testing.expect_value(t, len(rows), 2) do return
	testing.expect(t, rows[0].seq > rows[1].seq)
	for w in rows {
		testing.expect_value(t, w.actor_agent_id, "agt_write")
		testing.expect_value(t, w.actor_display_name, "Writer")
		testing.expect(t, strings.has_prefix(w.write_id, "awr_") && len(w.write_id) == 20)
		testing.expect_value(t, len(w.created_at), 20)
		testing.expect_value(t, len(w.fields), 2)
		if len(w.fields) ==
		   2 {testing.expect_value(t, w.fields[0], "title"); testing.expect_value(t, w.fields[1], "body")}
	}
	page, page_err := iface.agent_write_list_by_owner(&repo, "alice", rows[0].seq, 1)
	testing.expect_value(t, page_err.code, domain.Error_Code.None)
	defer {for &w in page do domain.agent_write_destroy(&w); delete(page)}
	if testing.expect_value(t, len(page), 1) do testing.expect_value(t, page[0].seq, rows[1].seq)
	other, other_err := iface.agent_write_list_by_owner(&repo, "bob", 0, 10)
	testing.expect_value(t, other_err.code, domain.Error_Code.None)
	defer {for &w in other do domain.agent_write_destroy(&w); delete(other)}
	if testing.expect_value(
		t,
		len(other),
		1,
	) {testing.expect_value(t, other[0].actor_agent_id, ""); testing.expect_value(t, other[0].actor_display_name, "")}
	testing.expect_value(
		t,
		iface.agent_write_insert(&repo, {owner_user_id = "alice", actor_agent_instance_id = "missing", resource_kind = "project", resource_id = "p", action = "archive"}).code,
		domain.Error_Code.None,
	)
	missing, missing_err := iface.agent_write_list_by_owner(&repo, "alice", 0, 1)
	testing.expect_value(t, missing_err.code, domain.Error_Code.None)
	defer {for &w in missing do domain.agent_write_destroy(&w); delete(missing)}
	if testing.expect_value(
		t,
		len(missing),
		1,
	) {testing.expect_value(t, len(missing[0].fields), 0); testing.expect_value(t, missing[0].actor_agent_id, "")}
	testing.expect(
		t,
		iface.agent_write_insert(&repo, {owner_user_id = "alice", resource_kind = "invalid", resource_id = "m", action = "create"}).code !=
		.None,
	)
}
