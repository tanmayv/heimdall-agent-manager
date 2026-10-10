package sqlite
import "core:strings"
import domain "odin_test:hub/domain"
launch_preferences_get_sqlite :: proc(ctx: rawptr, owner: string) -> (string, domain.Domain_Error) {
 impl := (^User_Repo_SQLite)(ctx)
 query := "SELECT payload_json FROM user_conversation_launch_preferences WHERE owner_user_id=?;"
 stmt: sqlite3_stmt
 if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return "", domain.domain_error(.Internal_Error, "failed launch preference lookup")
 defer sqlite3_finalize(stmt)
 bind_text(stmt, 1, owner)
 step := sqlite3_step(stmt)
 if step == SQLITE_DONE do return strings.clone("{}"), {}
 if step != SQLITE_ROW do return "", domain.domain_error(.Internal_Error, "failed launch preference read")
 return column_text(stmt, 0), {}
}
launch_preferences_save_sqlite :: proc(ctx: rawptr, owner, payload: string) -> (bool, domain.Domain_Error) {
 impl := (^User_Repo_SQLite)(ctx)
 query := "INSERT INTO user_conversation_launch_preferences (owner_user_id,payload_json) VALUES (?,?) ON CONFLICT(owner_user_id) DO UPDATE SET payload_json=excluded.payload_json,updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');"
 stmt: sqlite3_stmt
 if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed launch preference save")
 defer sqlite3_finalize(stmt)
 bind_text(stmt, 1, owner); bind_text(stmt, 2, payload)
 if step_write_healing(impl.conn, stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed launch preference write")
 return true, {}
}
