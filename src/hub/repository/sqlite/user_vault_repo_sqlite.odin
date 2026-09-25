package sqlite

import "core:c"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

User_Vault_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_user_vault_repository :: proc(impl: ^User_Vault_Repo_SQLite, conn: ^Conn) -> iface.User_Vault_Repository {
	impl.conn = conn
	return iface.User_Vault_Repository{
		ctx        = rawptr(impl),
		get_vault  = user_vault_get_sqlite,
		save_vault = user_vault_save_sqlite,
	}
}

user_vault_get_sqlite :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User_Vault, bool, domain.Domain_Error) {
	impl := (^User_Vault_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.User_Vault{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT user_id, encrypted_vault_key, vault_key_nonce, vault_key_tag,
kdf_algorithm, kdf_salt, kdf_iterations,
recovery_encrypted_vault_key, recovery_nonce, recovery_tag, recovery_salt,
created_at, updated_at
FROM user_vaults WHERE user_id = ? LIMIT 1;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.User_Vault{}, false, domain.domain_error(.Internal_Error, "failed to prepare user vault query")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(user_id))
	if sqlite3_step(stmt) == SQLITE_ROW {
		vault: domain.User_Vault
		vault.user_id                      = domain.User_ID(column_text(stmt, 0))
		vault.encrypted_vault_key          = column_text(stmt, 1)
		vault.vault_key_nonce              = column_text(stmt, 2)
		vault.vault_key_tag                = column_text(stmt, 3)
		vault.kdf_algorithm                = column_text(stmt, 4)
		vault.kdf_salt                     = column_text(stmt, 5)
		vault.kdf_iterations               = int_v(column_text_unowned(stmt, 6))
		vault.recovery_encrypted_vault_key = column_text(stmt, 7)
		vault.recovery_nonce               = column_text(stmt, 8)
		vault.recovery_tag                 = column_text(stmt, 9)
		vault.recovery_salt                = column_text(stmt, 10)
		vault.created_at                   = column_text(stmt, 11)
		vault.updated_at                   = column_text(stmt, 12)
		return vault, true, domain.Domain_Error{}
	}
	return domain.User_Vault{}, false, domain.Domain_Error{}
}

user_vault_save_sqlite :: proc(ctx: rawptr, vault: domain.User_Vault) -> (bool, domain.Domain_Error) {
	impl := (^User_Vault_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO user_vaults (
    user_id, encrypted_vault_key, vault_key_nonce, vault_key_tag,
    kdf_algorithm, kdf_salt, kdf_iterations,
    recovery_encrypted_vault_key, recovery_nonce, recovery_tag, recovery_salt,
    created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(user_id) DO UPDATE SET
    encrypted_vault_key          = excluded.encrypted_vault_key,
    vault_key_nonce              = excluded.vault_key_nonce,
    vault_key_tag                = excluded.vault_key_tag,
    kdf_algorithm                = excluded.kdf_algorithm,
    kdf_salt                     = excluded.kdf_salt,
    kdf_iterations               = excluded.kdf_iterations,
    recovery_encrypted_vault_key = excluded.recovery_encrypted_vault_key,
    recovery_nonce               = excluded.recovery_nonce,
    recovery_tag                 = excluded.recovery_tag,
    recovery_salt                = excluded.recovery_salt,
    updated_at                   = excluded.updated_at;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare user vault save")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(vault.user_id))
	bind_text(stmt, 2, vault.encrypted_vault_key)
	bind_text(stmt, 3, vault.vault_key_nonce)
	bind_text(stmt, 4, vault.vault_key_tag)
	bind_text(stmt, 5, vault.kdf_algorithm)
	bind_text(stmt, 6, vault.kdf_salt)
	sqlite3_bind_int(stmt, 7, c.int(vault.kdf_iterations))
	bind_text(stmt, 8, vault.recovery_encrypted_vault_key)
	bind_text(stmt, 9, vault.recovery_nonce)
	bind_text(stmt, 10, vault.recovery_tag)
	bind_text(stmt, 11, vault.recovery_salt)
	bind_text(stmt, 12, vault.created_at)
	bind_text(stmt, 13, vault.updated_at)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to save user vault")
	}
	return true, domain.Domain_Error{}
}
