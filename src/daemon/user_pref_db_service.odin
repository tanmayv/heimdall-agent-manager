package main

import "core:fmt"
import "core:os"
import "core:strings"

User_Preference :: struct {
	value:           string,
	interrupt:       bool,
	is_custom:       bool,
	updated_unix_ms: i64,
}

User_Pref_Db_Service :: struct {
	db:      sqlite3,
	db_path: string,
}

user_pref_db: User_Pref_Db_Service

user_pref_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/preferences", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/preference.db", db_dir)
	user_pref_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &user_pref_db.db)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !user_pref_db_create_schema() {
		fmt.println("user_pref_db_init: failed to create schema")
		sqlite3_close(user_pref_db.db)
		return false
	}

	fmt.println("user_pref_db_init: database initialized at", db_path)
	return true
}

user_pref_db_close :: proc() {
	if user_pref_db.db != nil {
		sqlite3_close(user_pref_db.db)
		user_pref_db.db = nil
	}
}

user_pref_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS user_preferences (
		user_id TEXT NOT NULL,
		key TEXT NOT NULL,
		value TEXT NOT NULL,
		interrupt INTEGER NOT NULL DEFAULT 0,
		is_custom INTEGER NOT NULL DEFAULT 0,
		updated_unix_ms INTEGER NOT NULL,
		PRIMARY KEY (user_id, key)
	);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(user_pref_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

user_pref_db_set :: proc(user_id, key, value: string, interrupt: bool) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO user_preferences 
		(user_id, key, value, interrupt, is_custom, updated_unix_ms) 
		VALUES (?, ?, ?, ?, 1, ?)`

	rc := sqlite3_prepare_v2(user_pref_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_set: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	now := now_unix_ms()
	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(key)), i32(len(key)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(value)), i32(len(value)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 4, interrupt ? 1 : 0)
	sqlite3_bind_int64(stmt, 5, now)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("user_pref_db_set: step failed:", rc)
		return false
	}
	return true
}

user_pref_db_get :: proc(user_id, key: string) -> (pref: User_Preference, ok: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT value, interrupt, is_custom, updated_unix_ms FROM user_preferences WHERE user_id = ? AND key = ?`

	rc := sqlite3_prepare_v2(user_pref_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_get: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(key)), i32(len(key)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		pref.value = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		pref.interrupt = sqlite3_column_int64(stmt, 1) == 1
		pref.is_custom = sqlite3_column_int64(stmt, 2) == 1
		pref.updated_unix_ms = sqlite3_column_int64(stmt, 3)
		return pref, true
	}
	return {}, false
}

user_pref_db_get_any :: proc(key: string) -> (pref: User_Preference, ok: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT value, interrupt, is_custom, updated_unix_ms FROM user_preferences WHERE key = ? LIMIT 1`

	rc := sqlite3_prepare_v2(user_pref_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_get_any: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(key)), i32(len(key)), SQLITE_TRANSIENT)

	if sqlite3_step(stmt) == SQLITE_ROW {
		pref.value = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		pref.interrupt = sqlite3_column_int64(stmt, 1) == 1
		pref.is_custom = sqlite3_column_int64(stmt, 2) == 1
		pref.updated_unix_ms = sqlite3_column_int64(stmt, 3)
		return pref, true
	}
	return {}, false
}

user_pref_db_delete :: proc(user_id, key: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := `DELETE FROM user_preferences WHERE user_id = ? AND key = ?`

	rc := sqlite3_prepare_v2(user_pref_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_delete: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(key)), i32(len(key)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("user_pref_db_delete: step failed:", rc)
		return false
	}
	return true
}

user_pref_db_load_all :: proc(user_id: string) -> (prefs: map[string]User_Preference, ok: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT key, value, interrupt, is_custom, updated_unix_ms FROM user_preferences WHERE user_id = ?`

	rc := sqlite3_prepare_v2(user_pref_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("user_pref_db_load_all: prepare failed:", rc)
		return nil, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(user_id)), i32(len(user_id)), SQLITE_TRANSIENT)

	prefs = make(map[string]User_Preference)
	for sqlite3_step(stmt) == SQLITE_ROW {
		key := strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		pref := User_Preference{
			value = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			interrupt = sqlite3_column_int64(stmt, 2) == 1,
			is_custom = sqlite3_column_int64(stmt, 3) == 1,
			updated_unix_ms = sqlite3_column_int64(stmt, 4),
		}
		prefs[key] = pref
	}
	return prefs, true
}
