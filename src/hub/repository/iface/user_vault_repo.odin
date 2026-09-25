package iface

import domain "odin_test:hub/domain"

User_Vault_Get_Proc  :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User_Vault, bool, domain.Domain_Error)
User_Vault_Save_Proc :: proc(ctx: rawptr, vault: domain.User_Vault) -> (bool, domain.Domain_Error)

User_Vault_Repository :: struct {
	ctx:        rawptr,
	get_vault:  User_Vault_Get_Proc,
	save_vault: User_Vault_Save_Proc,
}

user_vault_get :: proc(repo: ^User_Vault_Repository, user_id: domain.User_ID) -> (domain.User_Vault, bool, domain.Domain_Error) {
	if repo == nil || repo.get_vault == nil do return domain.User_Vault{}, false, domain.domain_error(.Internal_Error, "user vault repository is not configured")
	return repo.get_vault(repo.ctx, user_id)
}

user_vault_save :: proc(repo: ^User_Vault_Repository, vault: domain.User_Vault) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.save_vault == nil do return false, domain.domain_error(.Internal_Error, "user vault repository is not configured")
	return repo.save_vault(repo.ctx, vault)
}
