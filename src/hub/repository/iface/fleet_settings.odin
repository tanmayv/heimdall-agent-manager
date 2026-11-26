package iface

import domain "odin_test:hub/domain"

Fleet_Application_Get_Proc :: proc(ctx: rawptr, owner: domain.User_ID, bridge_id, id: string, by_request: bool) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error)
Fleet_Application_Put_Proc :: proc(ctx: rawptr, record: domain.Fleet_Application_Record, expected_revision: int) -> (bool, domain.Domain_Error)
Fleet_Application_List_Proc :: proc(ctx: rawptr) -> ([]domain.Fleet_Application_Record, domain.Domain_Error)
Fleet_Application_Operation_Proc :: proc(ctx: rawptr, owner: domain.User_ID, instance_id, key: string) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error)
fleet_application_by_operation :: proc(repo: ^Bridge_Repository, owner: domain.User_ID, instance_id, key: string) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	if repo == nil || repo.fleet_application_operation == nil do return {}, false, domain.domain_error(.Not_Found, "Fleet application not found")
	return repo.fleet_application_operation(repo.ctx, owner, instance_id, key)
}
fleet_application_get :: proc(repo: ^Bridge_Repository, owner: domain.User_ID, bridge_id, id: string, by_request := false) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	if repo == nil || repo.fleet_application_get == nil do return {}, false, domain.domain_error(.Internal_Error, "Fleet application repository unavailable")
	return repo.fleet_application_get(repo.ctx, owner, bridge_id, id, by_request)
}
fleet_application_put :: proc(repo: ^Bridge_Repository, record: domain.Fleet_Application_Record, expected_revision: int) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.fleet_application_put == nil do return false, domain.domain_error(.Internal_Error, "Fleet application repository unavailable")
	return repo.fleet_application_put(repo.ctx, record, expected_revision)
}
fleet_application_list_active :: proc(repo: ^Bridge_Repository) -> ([]domain.Fleet_Application_Record, domain.Domain_Error) {
	if repo == nil || repo.fleet_application_list == nil do return nil, domain.domain_error(.Internal_Error, "Fleet application repository unavailable")
	return repo.fleet_application_list(repo.ctx)
}

Fleet_Scope_Get_Proc :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Fleet_Scope, domain.Domain_Error)
Fleet_Scope_Set_Proc :: proc(ctx: rawptr, inst: domain.Agent_Instance, scope: string) -> domain.Domain_Error

fleet_scope_get :: proc(repo: ^Bridge_Repository, inst: domain.Agent_Instance) -> (bool, domain.Domain_Error) {
	scope, err := fleet_scope_classify(repo, inst)
	return scope == .Chain, err
}
fleet_scope_classify :: proc(repo: ^Bridge_Repository, inst: domain.Agent_Instance) -> (domain.Fleet_Scope, domain.Domain_Error) {
	if repo == nil || repo.fleet_scope_get == nil do return .Unknown, {}
	return repo.fleet_scope_get(repo.ctx, inst)
}
fleet_scope_set :: proc(repo: ^Bridge_Repository, inst: domain.Agent_Instance, scope: string) -> domain.Domain_Error {
	if repo == nil || repo.fleet_scope_set == nil do return {}
	return repo.fleet_scope_set(repo.ctx, inst, scope)
}

// Implementations return owned snapshots. save replaces the complete snapshot
// atomically and checks owner/agent references and expected revision under lock.
Fleet_Settings_Get_Proc :: proc(ctx: rawptr, owner: domain.User_ID, bridge_id: string) -> (domain.Fleet_Settings, domain.Domain_Error)
Fleet_Settings_Save_Proc :: proc(ctx: rawptr, owner: domain.User_ID, bridge_id: string, draft: domain.Fleet_Settings_Draft) -> (domain.Fleet_Settings, bool, domain.Domain_Error)

fleet_settings_get :: proc(repo: ^Bridge_Repository, owner: domain.User_ID, bridge_id: string) -> (domain.Fleet_Settings, domain.Domain_Error) {
	// Old in-memory fakes have no settings. Production always wires this seam.
	if repo == nil || repo.fleet_settings_get == nil do return {bridge_id = ""}, {}
	return repo.fleet_settings_get(repo.ctx, owner, bridge_id)
}
fleet_settings_save :: proc(repo: ^Bridge_Repository, owner: domain.User_ID, bridge_id: string, draft: domain.Fleet_Settings_Draft) -> (domain.Fleet_Settings, bool, domain.Domain_Error) {
	if repo == nil || repo.fleet_settings_save == nil do return {}, false, domain.domain_error(.Internal_Error, "Fleet settings repository unavailable")
	return repo.fleet_settings_save(repo.ctx, owner, bridge_id, draft)
}
