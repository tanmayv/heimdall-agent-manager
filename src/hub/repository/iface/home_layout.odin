package iface

import domain "odin_test:hub/domain"

Home_Layout_Get_Proc :: proc(ctx: rawptr, owner: domain.User_ID) -> (domain.Home_Layout_Record, bool, domain.Domain_Error)
Home_Layout_CAS_Proc :: proc(ctx: rawptr, owner: domain.User_ID, expected_version: i64, payload: string) -> (bool, domain.Domain_Error)

home_layout_get :: proc(repo: ^User_Repository, owner: domain.User_ID) -> (domain.Home_Layout_Record, bool, domain.Domain_Error) {
	if repo == nil || repo.home_layout_get == nil do return {}, false, domain.domain_error(.Internal_Error, "Home layout storage is not configured")
	return repo.home_layout_get(repo.ctx, owner)
}

home_layout_cas :: proc(repo: ^User_Repository, owner: domain.User_ID, expected_version: i64, payload: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.home_layout_cas == nil do return false, domain.domain_error(.Internal_Error, "Home layout storage is not configured")
	return repo.home_layout_cas(repo.ctx, owner, expected_version, payload)
}
