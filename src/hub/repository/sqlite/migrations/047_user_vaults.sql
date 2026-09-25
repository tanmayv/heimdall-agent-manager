CREATE TABLE IF NOT EXISTS user_vaults (
    user_id                      TEXT PRIMARY KEY,
    encrypted_vault_key          TEXT NOT NULL,
    vault_key_nonce              TEXT NOT NULL,
    vault_key_tag                TEXT NOT NULL,
    kdf_algorithm                TEXT NOT NULL,
    kdf_salt                     TEXT NOT NULL,
    kdf_iterations               INTEGER NOT NULL,
    recovery_encrypted_vault_key TEXT NOT NULL,
    recovery_nonce               TEXT NOT NULL,
    recovery_tag                 TEXT NOT NULL,
    recovery_salt                TEXT NOT NULL,
    created_at                   TEXT NOT NULL,
    updated_at                   TEXT NOT NULL
);
