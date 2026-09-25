package user_vault

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

User_Vault_Service :: struct {
	repo:  ^iface.User_Vault_Repository,
	clock: ^platform.Clock,
}

new_user_vault_service :: proc(repo: ^iface.User_Vault_Repository, clock: ^platform.Clock) -> User_Vault_Service {
	return User_Vault_Service{
		repo  = repo,
		clock = clock,
	}
}

get_vault :: proc(service: ^User_Vault_Service, user_id: domain.User_ID) -> (domain.User_Vault, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return domain.User_Vault{}, false, domain.domain_error(.Internal_Error, "user vault service is not configured")
	}
	if domain.id_is_empty(string(user_id)) {
		return domain.User_Vault{}, false, domain.domain_error(.Unauthenticated, "user is required")
	}
	vault, found, err := iface.user_vault_get(service.repo, user_id)
	if err.code != .None {
		return domain.User_Vault{}, false, err
	}
	if !found {
		return domain.User_Vault{}, false, domain.domain_error(.Not_Found, "user vault is not configured", "{\"configured\":false}")
	}
	return vault, true, domain.Domain_Error{}
}

set_vault :: proc(service: ^User_Vault_Service, input: domain.Set_User_Vault_Input) -> (domain.User_Vault, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return domain.User_Vault{}, false, domain.domain_error(.Internal_Error, "user vault service is not configured")
	}
	if domain.id_is_empty(string(input.user_id)) {
		return domain.User_Vault{}, false, domain.domain_error(.Unauthenticated, "user is required")
	}
	val_err := domain.validate_set_user_vault_input(input)
	if val_err.code != .None {
		return domain.User_Vault{}, false, val_err
	}

	now := platform.clock_now(service.clock)
	existing, exists, _ := iface.user_vault_get(service.repo, input.user_id)
	created_at := existing.created_at if exists && existing.created_at != "" else now

	vault := domain.User_Vault{
		user_id                      = input.user_id,
		encrypted_vault_key          = input.encrypted_vault_key,
		vault_key_nonce              = input.vault_key_nonce,
		vault_key_tag                = input.vault_key_tag,
		kdf_algorithm                = input.kdf_algorithm,
		kdf_salt                     = input.kdf_salt,
		kdf_iterations               = input.kdf_iterations,
		recovery_encrypted_vault_key = input.recovery_encrypted_vault_key,
		recovery_nonce               = input.recovery_nonce,
		recovery_tag                 = input.recovery_tag,
		recovery_salt                = input.recovery_salt,
		created_at                   = created_at,
		updated_at                   = now,
	}

	saved_ok, save_err := iface.user_vault_save(service.repo, vault)
	if !saved_ok {
		return domain.User_Vault{}, false, save_err
	}
	return vault, true, domain.Domain_Error{}
}
