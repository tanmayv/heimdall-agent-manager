#+private file
package sqlite

import "core:testing"
import "core:strings"

// Simulates interruption after 203's ALTER, before deadline conversion or the
// schema ledger write. Startup must finish conversion instead of rejecting a
// duplicate phase column. A normal second run alone cannot catch this window.
@(test)
test_durable_claim_migration_recovers_after_column_before_ledger :: proc(t: ^testing.T) {
 context.allocator = context.temp_allocator
 conn, path, ok := tmpl_open_file_prod(t, "durable_partial")
 defer tmpl_remove_db(path)
 if !ok do return
 defer close(&conn)
 before, _ := run_migrations(&conn, stop_before="203_durable_task_claims.sql")
 if !testing.expect(t,before,"pre-203 schema") do return
 seeded := exec(&conn, `INSERT INTO task_leases
 (lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery)
 VALUES ('legacy_claim','legacy_task','legacy_chain','u1',4,'legacy_holder','work','2026-01-01T00:00:00Z','2026-01-01T00:15:00Z','2026-01-01T01:00:00Z','inline');`)
 if !testing.expect(t,seeded,"deployed active claim") do return
 if !testing.expect(t,exec(&conn,"ALTER TABLE task_leases ADD COLUMN phase TEXT NOT NULL DEFAULT 'active' CHECK (phase IN ('active','waiting'));"),"interrupted ALTER") do return
 migrated,err:=run_migrations(&conn)
 if !testing.expect(t,migrated,err.message) do return
 testing.expect_value(t,durable_migration_text(&conn,"SELECT lease_id||':'||holder_instance_id||':'||attempt_no||':'||phase||':'||expires_at||':'||hard_deadline_at FROM task_leases;"),"legacy_claim:legacy_holder:4:active::")
 testing.expect(t,migration_applied(&conn,"203_durable_task_claims.sql"),"conversion recorded only after completion")
 again,again_err:=run_migrations(&conn)
 testing.expect(t,again,again_err.message)
 testing.expect_value(t,durable_migration_text(&conn,"SELECT count(*) FROM task_leases;"),"1")
}

durable_migration_text :: proc(conn:^Conn, query:string)->string {
 stmt:sqlite3_stmt
 if sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return "<prepare-failed>"
 defer sqlite3_finalize(stmt)
 if sqlite3_step(stmt)!=SQLITE_ROW do return "<no-row>"
 return strings.clone(column_text_unowned(stmt,0),context.temp_allocator)
}
