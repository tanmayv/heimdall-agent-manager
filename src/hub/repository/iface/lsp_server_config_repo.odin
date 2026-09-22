package iface

import domain "odin_test:hub/domain"

Lsp_Server_Config_Upsert_Proc        :: proc(ctx: rawptr, cfg: domain.Lsp_Server_Config) -> (bool, domain.Domain_Error)
Lsp_Server_Config_Get_Proc            :: proc(ctx: rawptr, owner_user_id, config_id: string) -> (domain.Lsp_Server_Config, bool, domain.Domain_Error)
Lsp_Server_Config_List_By_Bridge_Proc :: proc(ctx: rawptr, owner_user_id, bridge_id: string) -> ([dynamic]domain.Lsp_Server_Config, domain.Domain_Error)
Lsp_Server_Config_Delete_Proc         :: proc(ctx: rawptr, owner_user_id, config_id: string) -> (bool, domain.Domain_Error)

Lsp_Server_Config_Repository :: struct {
	ctx:             rawptr,
	upsert:          Lsp_Server_Config_Upsert_Proc,
	get:             Lsp_Server_Config_Get_Proc,
	list_by_bridge:  Lsp_Server_Config_List_By_Bridge_Proc,
	delete:          Lsp_Server_Config_Delete_Proc,
}

lsp_server_config_upsert :: proc(repo: ^Lsp_Server_Config_Repository, cfg: domain.Lsp_Server_Config) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.upsert == nil do return false, domain.domain_error(.Internal_Error, "lsp server config repository is not configured")
	return repo.upsert(repo.ctx, cfg)
}

lsp_server_config_get :: proc(repo: ^Lsp_Server_Config_Repository, owner_user_id, config_id: string) -> (domain.Lsp_Server_Config, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Lsp_Server_Config{}, false, domain.domain_error(.Internal_Error, "lsp server config repository is not configured")
	return repo.get(repo.ctx, owner_user_id, config_id)
}

lsp_server_config_list_by_bridge :: proc(repo: ^Lsp_Server_Config_Repository, owner_user_id, bridge_id: string) -> ([dynamic]domain.Lsp_Server_Config, domain.Domain_Error) {
	if repo == nil || repo.list_by_bridge == nil do return nil, domain.domain_error(.Internal_Error, "lsp server config repository is not configured")
	return repo.list_by_bridge(repo.ctx, owner_user_id, bridge_id)
}

lsp_server_config_delete :: proc(repo: ^Lsp_Server_Config_Repository, owner_user_id, config_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete == nil do return false, domain.domain_error(.Internal_Error, "lsp server config repository is not configured")
	return repo.delete(repo.ctx, owner_user_id, config_id)
}
