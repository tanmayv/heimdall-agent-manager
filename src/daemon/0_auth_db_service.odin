package main

import "core:fmt"
import "core:os"
import "core:strings"

Auth_Db_Service :: struct {
	db: sqlite3,
	db_path: string,
}

auth_db: Auth_Db_Service

auth_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/auth", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/tokens.db", db_dir)
	auth_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &auth_db.db)
	if rc != SQLITE_OK {
		fmt.println("auth_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !auth_db_create_schema() {
		fmt.println("auth_db_init: failed to create schema")
		sqlite3_close(auth_db.db)
		return false
	}

	fmt.println("auth_db_init: database initialized at", db_path)
	return true
}

auth_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS tokens (
		token TEXT PRIMARY KEY,
		identity_type TEXT NOT NULL,
		identity_id TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		last_seen_unix_ms INTEGER NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_identity ON tokens(identity_type, identity_id);
	CREATE INDEX IF NOT EXISTS idx_last_seen ON tokens(last_seen_unix_ms);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(auth_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("auth_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}

	return true
}

auth_db_store_token :: proc(token, identity_type, identity_id: string, now_unix_ms: i64) -> bool {
	limit := 20
	if len(token) < limit do limit = len(token)
	fmt.println("DEBUG: auth_db_store_token for", identity_type, identity_id, "token =", token[:limit], "...")
	stmt: sqlite3_stmt = nil

	query := `INSERT OR REPLACE INTO tokens (token, identity_type, identity_id, created_unix_ms, last_seen_unix_ms) VALUES (?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(auth_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("auth_db_store_token: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(token)), -1, SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(identity_type)), -1, SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(identity_id)), -1, SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 4, now_unix_ms)
	sqlite3_bind_int64(stmt, 5, now_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("auth_db_store_token: step failed:", rc)
		return false
	}

	fmt.println("DEBUG: auth_db_store_token succeeded")
	return true
}

auth_db_get_token :: proc(identity_type, identity_id: string) -> string {
	stmt: sqlite3_stmt = nil

	query := `SELECT token FROM tokens WHERE identity_type = ? AND identity_id = ? ORDER BY last_seen_unix_ms DESC LIMIT 1`

	rc := sqlite3_prepare_v2(auth_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("auth_db_get_token: prepare failed:", rc)
		return ""
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(identity_type)), -1, SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(identity_id)), -1, SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		token := strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		fmt.println("DEBUG: auth_db_get_token found token for", identity_type, identity_id)
		return token
	}

	fmt.println("DEBUG: auth_db_get_token no token found for", identity_type, identity_id)
	return ""
}

auth_db_update_last_seen :: proc(token: string, now_unix_ms: i64) -> bool {
	stmt: sqlite3_stmt = nil

	query := `UPDATE tokens SET last_seen_unix_ms = ? WHERE token = ?`

	rc := sqlite3_prepare_v2(auth_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("auth_db_update_last_seen: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_int64(stmt, 1, now_unix_ms)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(token)), -1, SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("auth_db_update_last_seen: step failed:", rc)
		return false
	}

	return true
}

auth_db_get_identity :: proc(token: string) -> (identity_type: string, identity_id: string) {
	stmt: sqlite3_stmt = nil

	query := `SELECT identity_type, identity_id FROM tokens WHERE token = ?`

	rc := sqlite3_prepare_v2(auth_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("auth_db_get_identity: prepare failed:", rc)
		return "", ""
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(token)), -1, SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		itype := strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		iid := strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
		fmt.println("DEBUG: auth_db_get_identity found token, identity_type =", itype, "identity_id =", iid)
		return itype, iid
	}

	fmt.println("DEBUG: auth_db_get_identity no identity found for token")
	return "", ""
}

auth_db_close :: proc() {
	if auth_db.db != nil {
		sqlite3_close(auth_db.db)
		auth_db.db = nil
	}
}
