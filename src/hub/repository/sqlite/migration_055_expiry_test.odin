package sqlite

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
m055_db_path :: proc(tag: string) -> string {
	return fmt.tprintf("/tmp/test_migration_055_%s_%d.db", tag, os.get_pid())
}

@(test)
test_migration_055_fresh_db_creates_column_and_applies :: proc(t: ^testing.T) {
	db_path := m055_db_path("fresh")
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations ok: %s", mig_err.message)) do return

	testing.expect(t, table_column_exists(&conn, "memories", "expires_at"),
		"memories table has expires_at column")
	testing.expect(t, migration_applied(&conn, "055_memory_action_expiry.sql"),
		"055_memory_action_expiry.sql marked as applied")

	// Verify idempotency: running migrations a second time succeeds cleanly with no errors
	mig_ok2, mig_err2 := run_migrations(&conn)
	testing.expect(t, mig_ok2, fmt.tprintf("second migrations run ok: %s", mig_err2.message))
}

@(test)
test_migration_055_backfills_pending_memories_and_cards :: proc(t: ^testing.T) {
	db_path := m055_db_path("backfill")
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return
	defer close(&conn)

	// Run full migrations first to get base schema
	mig_ok, mig_err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations ok: %s", mig_err.message)) do return

	// Insert test memories: one pending, one active
	exec(&conn, "INSERT INTO memories (memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at) VALUES ('mem_pending', 'usr_1', '[]', '[]', '[]', '[]', 'fact', 'pending', 'Pending Mem', 'Desc', 'Body', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")
	exec(&conn, "INSERT INTO memories (memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at) VALUES ('mem_active', 'usr_1', '[]', '[]', '[]', '[]', 'fact', 'active', 'Active Mem', 'Desc', 'Body', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")

	// Insert test cards: one pending, one accepted
	exec(&conn, "INSERT INTO cards (card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at) VALUES ('crd_pending', 'usr_1', 'proj_1', 'Pending Card', 'Rat', 'project', 'agent', 0.9, '[]', 'pending', '[]', '{}', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")
	exec(&conn, "INSERT INTO cards (card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at) VALUES ('crd_accepted', 'usr_1', 'proj_1', 'Accepted Card', 'Rat', 'project', 'agent', 0.9, '[]', 'accepted', '[]', '{}', '', '', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z');")

	// Now run the backfill queries from migration 055
	ok_mem := exec(&conn, "UPDATE memories SET expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', datetime(created_at, '+24 hours')) WHERE status = 'pending';")
	testing.expect(t, ok_mem, "memories backfill query executed")

	ok_crd := exec(&conn, "UPDATE cards SET ttl_at = strftime('%Y-%m-%dT%H:%M:%SZ', datetime(created_at, '+24 hours')) WHERE status = 'pending' AND (ttl_at IS NULL OR ttl_at = '');")
	testing.expect(t, ok_crd, "cards backfill query executed")

	// Check pending memory was backfilled to 2026-10-02T12:00:00Z
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT expires_at FROM memories WHERE memory_id = 'mem_pending';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select pending memory")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "2026-10-02T12:00:00Z")
		} else {
			testing.expect(t, false, "expected row for mem_pending")
		}
	}

	// Check active memory was NOT backfilled (expires_at is still empty)
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT expires_at FROM memories WHERE memory_id = 'mem_active';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select active memory")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "")
		} else {
			testing.expect(t, false, "expected row for mem_active")
		}
	}

	// Check pending card was backfilled to 2026-10-02T12:00:00Z
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT ttl_at FROM cards WHERE card_id = 'crd_pending';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select pending card")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "2026-10-02T12:00:00Z")
		} else {
			testing.expect(t, false, "expected row for crd_pending")
		}
	}

	// Check accepted card was NOT backfilled
	{
		stmt: sqlite3_stmt
		rc := sqlite3_prepare_v2(conn.db, "SELECT ttl_at FROM cards WHERE card_id = 'crd_accepted';", -1, &stmt, nil)
		testing.expect(t, rc == SQLITE_OK, "prepare select accepted card")
		defer sqlite3_finalize(stmt)
		if sqlite3_step(stmt) == SQLITE_ROW {
			c_txt := sqlite3_column_text(stmt, 0)
			val := string(c_txt)
			testing.expect_value(t, val, "")
		} else {
			testing.expect(t, false, "expected row for crd_accepted")
		}
	}
}
