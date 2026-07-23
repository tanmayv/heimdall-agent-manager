package iface

import domain "odin_test:hub/domain"

Bridge_Save_Enrollment_Proc :: proc(ctx: rawptr, enrollment: domain.Bridge_Enrollment) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error)
Bridge_Get_Enrollment_By_Token_Hash_Proc :: proc(ctx: rawptr, token_hash: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error)
Bridge_Get_Enrollment_Proc :: proc(ctx: rawptr, enrollment_id: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error)
Bridge_List_Enrollments_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge_Enrollment, domain.Domain_Error)
Bridge_Save_Proc :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_Get_Proc :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_Get_By_Token_Hash_Proc :: proc(ctx: rawptr, token_hash: string) -> (domain.Bridge, bool, domain.Domain_Error)
Bridge_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error)

Bridge_Repository :: struct {
	ctx: rawptr,
	save_enrollment: Bridge_Save_Enrollment_Proc,
	get_enrollment_by_token_hash: Bridge_Get_Enrollment_By_Token_Hash_Proc,
	get_enrollment: Bridge_Get_Enrollment_Proc,
	list_enrollments_by_owner: Bridge_List_Enrollments_By_Owner_Proc,
	save_bridge: Bridge_Save_Proc,
	get_bridge: Bridge_Get_Proc,
	get_bridge_by_token_hash: Bridge_Get_By_Token_Hash_Proc,
	list_by_owner: Bridge_List_By_Owner_Proc,
}

bridge_save_enrollment :: proc(repo: ^Bridge_Repository, enrollment: domain.Bridge_Enrollment) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	if repo == nil || repo.save_enrollment == nil do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.save_enrollment(repo.ctx, enrollment)
}

bridge_get_enrollment_by_token_hash :: proc(repo: ^Bridge_Repository, token_hash: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	if repo == nil || repo.get_enrollment_by_token_hash == nil do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.get_enrollment_by_token_hash(repo.ctx, token_hash)
}

bridge_get_enrollment :: proc(repo: ^Bridge_Repository, enrollment_id: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	if repo == nil || repo.get_enrollment == nil do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.get_enrollment(repo.ctx, enrollment_id)
}

bridge_list_enrollments_by_owner :: proc(repo: ^Bridge_Repository, owner_user_id: domain.User_ID) -> ([]domain.Bridge_Enrollment, domain.Domain_Error) {
	if repo == nil || repo.list_enrollments_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_enrollments_by_owner(repo.ctx, owner_user_id)
}

bridge_save_bridge :: proc(repo: ^Bridge_Repository, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	if repo == nil || repo.save_bridge == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.save_bridge(repo.ctx, bridge)
}

bridge_get_bridge :: proc(repo: ^Bridge_Repository, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	if repo == nil || repo.get_bridge == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.get_bridge(repo.ctx, bridge_id)
}

bridge_get_bridge_by_token_hash :: proc(repo: ^Bridge_Repository, token_hash: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	if repo == nil || repo.get_bridge_by_token_hash == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.get_bridge_by_token_hash(repo.ctx, token_hash)
}

bridge_list_by_owner :: proc(repo: ^Bridge_Repository, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "bridge repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id)
}
