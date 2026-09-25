package domain

import "core:strings"

// User_Vault models the client-encrypted zero-knowledge user vault envelope
// stored on the Hub SQLite database (REQ-VAULT-DB-SCHEMA-1).
// The Hub stores opaque ciphertexts and KDF parameters; raw 256-bit vault keys
// and passwords never touch the server.
User_Vault :: struct {
	user_id:                      User_ID,
	encrypted_vault_key:          string,
	vault_key_nonce:              string,
	vault_key_tag:                string,
	kdf_algorithm:                string,
	kdf_salt:                     string,
	kdf_iterations:               int,
	recovery_encrypted_vault_key: string,
	recovery_nonce:               string,
	recovery_tag:                 string,
	recovery_salt:                string,
	created_at:                   string,
	updated_at:                   string,
}

Set_User_Vault_Input :: struct {
	user_id:                      User_ID,
	encrypted_vault_key:          string,
	vault_key_nonce:              string,
	vault_key_tag:                string,
	kdf_algorithm:                string,
	kdf_salt:                     string,
	kdf_iterations:               int,
	recovery_encrypted_vault_key: string,
	recovery_nonce:               string,
	recovery_tag:                 string,
	recovery_salt:                string,
}

validate_set_user_vault_input :: proc(input: Set_User_Vault_Input) -> Domain_Error {
	if id_is_empty(string(input.user_id)) {
		return domain_error(.Validation_Failed, "user_id is required")
	}
	if strings.trim_space(input.encrypted_vault_key) == "" {
		return domain_error(.Validation_Failed, "encrypted_vault_key is required")
	}
	if strings.trim_space(input.vault_key_nonce) == "" {
		return domain_error(.Validation_Failed, "vault_key_nonce is required")
	}
	if strings.trim_space(input.vault_key_tag) == "" {
		return domain_error(.Validation_Failed, "vault_key_tag is required")
	}
	if strings.trim_space(input.kdf_algorithm) == "" {
		return domain_error(.Validation_Failed, "kdf_algorithm is required")
	}
	if strings.trim_space(input.kdf_salt) == "" {
		return domain_error(.Validation_Failed, "kdf_salt is required")
	}
	if input.kdf_iterations <= 0 {
		return domain_error(.Validation_Failed, "kdf_iterations must be positive")
	}
	if strings.trim_space(input.recovery_encrypted_vault_key) == "" {
		return domain_error(.Validation_Failed, "recovery_encrypted_vault_key is required")
	}
	if strings.trim_space(input.recovery_nonce) == "" {
		return domain_error(.Validation_Failed, "recovery_nonce is required")
	}
	if strings.trim_space(input.recovery_tag) == "" {
		return domain_error(.Validation_Failed, "recovery_tag is required")
	}
	if strings.trim_space(input.recovery_salt) == "" {
		return domain_error(.Validation_Failed, "recovery_salt is required")
	}
	return Domain_Error{}
}
