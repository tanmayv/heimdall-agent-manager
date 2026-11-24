package sqlite

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Every row past the legacy caps (500 instances, 200 conversations) must still
// be found: the target rows are the oldest, behind 700 newer noise rows.
@(private = "file")
LOOKUP_NOISE :: 700

@(private = "file")
lookup_fixture :: proc(t: ^testing.T, db: ^Conn) -> (ar: iface.Agent_Repository, cr: iface.Content_Repository, ok: bool) {
	ai := new(Agent_Repo_SQLite, context.temp_allocator); ar = new_agent_repository(ai, db)
	ci := new(Content_Repo_SQLite, context.temp_allocator); cr = new_content_repository(ci, db)
	testing.expect(t, exec(db, "PRAGMA foreign_keys=OFF;")) or_return
	_, saved, err := ar.save_instance(ar.ctx, {agent_instance_id = "target", owner_user_id = "owner", agent_id = "agent", bridge_id = "bridge", project_id = "proj", runtime_status = "running", kind = "agent", runtime_transport = "pty", created_at = "2000-01-01T00:00:00Z", updated_at = "2000-01-01T00:00:00Z"})
	testing.expect(t, saved, err.message) or_return
	// An older conversation for the same instance: the lookup keeps the legacy
	// most-recent-activity choice instead of the first created row.
	_, saved, err = cr.save_conversation(cr.ctx, {conversation_id = "target_old", owner_user_id = "owner", agent_instance_id = "target", agent_id = "agent", created_at = "1999-01-01T00:00:00Z", updated_at = "1999-01-01T00:00:00Z"})
	testing.expect(t, saved, err.message) or_return
	_, saved, err = cr.save_conversation(cr.ctx, {conversation_id = "target_conversation", owner_user_id = "owner", agent_instance_id = "target", agent_id = "agent", created_at = "2000-01-01T00:00:00Z", updated_at = "2000-01-01T00:00:00Z"})
	testing.expect(t, saved, err.message) or_return
	_, saved, err = cr.save_message(cr.ctx, {message_id = "target_msg", conversation_id = "target_conversation", owner_user_id = "owner", direction = "user_to_agent", body = "hi", created_at = "2000-01-02T00:00:00Z"})
	testing.expect(t, saved, err.message) or_return
	for i in 0 ..< LOOKUP_NOISE {
		id := fmt.tprintf("noise%04d", i)
		at := fmt.tprintf("2026-01-01T00:%02d:%02dZ", i / 60, i % 60)
		_, written, e := ar.save_instance(ar.ctx, {agent_instance_id = id, owner_user_id = "owner", agent_id = "other", bridge_id = "bridge2", project_id = "proj2", runtime_status = "stopped", kind = "agent", runtime_transport = "pty", created_at = at, updated_at = at})
		testing.expect(t, written, e.message) or_return
		_, written, e = cr.save_conversation(cr.ctx, {conversation_id = id, owner_user_id = "owner", agent_instance_id = id, agent_id = "other", created_at = at, updated_at = at})
		testing.expect(t, written, e.message) or_return
	}
	// Another owner's identical partition must never leak in.
	_, saved, err = ar.save_instance(ar.ctx, {agent_instance_id = "foreign", owner_user_id = "other_owner", agent_id = "agent", bridge_id = "bridge", project_id = "proj", runtime_status = "running", kind = "agent", runtime_transport = "pty", created_at = "2001-01-01T00:00:00Z", updated_at = "2001-01-01T00:00:00Z"})
	testing.expect(t, saved, err.message) or_return
	return ar, cr, true
}

@(test)
test_filtered_instance_and_conversation_lookups_have_no_cap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	db, opened, _ := open(":memory:"); if !testing.expect(t, opened) do return
	defer close(&db)
	migrated, _ := run_migrations(&db); if !testing.expect(t, migrated) do return
	ar, cr, ok := lookup_fixture(t, &db); if !ok do return

	live := [?]string{"running", "idle"}
	stopped := [?]string{"stopped"}
	single_target := [?]iface.Agent_Instance_Filter{
		{agent_id = "agent"},
		{bridge_id = "bridge"},
		{project_id = "proj"},
		{runtime_statuses = live[:]},
		{agent_id = "agent", bridge_id = "bridge", project_id = "proj", runtime_statuses = live[:]},
	}
	for filter in single_target {
		rows, err := ar.list_instances_filtered(ar.ctx, "owner", filter, 10, "")
		if testing.expectf(t, err.code == .None && len(rows) == 1, "filter %v: err=%v rows=%d", filter, err.code, len(rows)) {
			testing.expect_value(t, rows[0].agent_instance_id, "target")
		}
	}
	none, nerr := ar.list_instances_filtered(ar.ctx, "owner", {agent_id = "agent", bridge_id = "bridge2"}, 10, "")
	testing.expect(t, nerr.code == .None && len(none) == 0)

	// Cursor paging over a filtered partition larger than one page is exact.
	seen := 0
	cursor := ""
	for page in 0 ..< 10 {
		rows, err := ar.list_instances_filtered(ar.ctx, "owner", {bridge_id = "bridge2", runtime_statuses = stopped[:]}, 300, cursor)
		if !testing.expect(t, err.code == .None) do return
		if len(rows) == 0 do break
		for r in rows do testing.expect_value(t, r.bridge_id, "bridge2")
		seen += len(rows)
		cursor = rows[len(rows) - 1].created_at
	}
	testing.expect_value(t, seen, LOOKUP_NOISE)

	c, found, cerr := cr.conversation_by_instance(cr.ctx, "owner", "target")
	if testing.expect(t, found && cerr.code == .None, cerr.message) {
		testing.expect_value(t, c.conversation_id, "target_conversation")
		testing.expect_value(t, c.last_message_id, "target_msg")
		testing.expect_value(t, c.message_count, 1)
	}
	_, found, cerr = cr.conversation_by_instance(cr.ctx, "other_owner", "target")
	testing.expect(t, !found && cerr.code == .Not_Found)
	_, found, cerr = cr.conversation_by_instance(cr.ctx, "owner", "missing")
	testing.expect(t, !found && cerr.code == .Not_Found)
}

// The lookups must seek an index, never scan agent_instances or chat_conversations.
@(test)
test_filtered_instance_and_conversation_lookup_plans_use_indexes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	db, opened, _ := open(":memory:"); if !testing.expect(t, opened) do return
	defer close(&db)
	migrated, _ := run_migrations(&db); if !testing.expect(t, migrated) do return
	_, _, ok := lookup_fixture(t, &db); if !ok do return
	testing.expect(t, exec(&db, "ANALYZE;"))

	statuses := [?]string{"running", "idle"}
	queries := make([dynamic]string)
	append(&queries, CONVERSATION_BY_INSTANCE_SQL)
	for has_cursor in ([?]bool{false, true}) {
		for filter in ([?]iface.Agent_Instance_Filter{
			{},
			{agent_id = "a"},
			{bridge_id = "b"},
			{project_id = "p"},
			{runtime_statuses = statuses[:]},
			{agent_id = "a", bridge_id = "b"},
			{agent_id = "a", bridge_id = "b", project_id = "p", runtime_statuses = statuses[:]},
		}) {
			append(&queries, agent_instances_filtered_sql(filter, has_cursor))
		}
	}
	for query in queries {
		stmt: sqlite3_stmt
		sql := strings.concatenate({"EXPLAIN QUERY PLAN ", query})
		if !testing.expect_value(t, sqlite3_prepare_v2(db.db, strings.clone_to_cstring(sql), -1, &stmt, nil), SQLITE_OK) do continue
		searched := false
		for sqlite3_step(stmt) == SQLITE_ROW {
			detail := column_text_unowned(stmt, 3)
			// Any SCAN of these tables, even "USING INDEX", walks every row.
			words := strings.fields(detail)
			if len(words) >= 2 && words[0] == "SCAN" {
				testing.expectf(t, words[1] != "agent_instances" && words[1] != "chat_conversations" && words[1] != "c", "table scan %q in plan for %s", detail, query)
			}
			if strings.has_prefix(detail, "SEARCH agent_instances USING") || strings.has_prefix(detail, "SEARCH c USING") do searched = true
		}
		sqlite3_finalize(stmt)
		testing.expectf(t, searched, "no indexed search in plan for %s", query)
	}
}
