package iface

import domain "odin_test:hub/domain"

Project_Get_Proc :: proc(ctx: rawptr, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error)
Project_Save_Proc :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error)
Project_Update_Proc :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error)
Project_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Project, domain.Domain_Error)
Project_Save_Bridge_Path_Proc :: proc(ctx: rawptr, path: domain.Project_Bridge_Path) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error)
Project_Get_Bridge_Path_Proc :: proc(ctx: rawptr, project_id: domain.Project_ID, bridge_id: string) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error)
Project_List_Bridge_Paths_Proc :: proc(ctx: rawptr, project_id: domain.Project_ID, owner_user_id: domain.User_ID) -> ([]domain.Project_Bridge_Path, domain.Domain_Error)
Project_Delete_Bridge_Path_Proc :: proc(ctx: rawptr, project_id: domain.Project_ID, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)

Project_Repository :: struct {
	ctx: rawptr,
	get: Project_Get_Proc,
	save: Project_Save_Proc,
	update: Project_Update_Proc,
	list_by_owner: Project_List_By_Owner_Proc,
	save_bridge_path: Project_Save_Bridge_Path_Proc,
	get_bridge_path: Project_Get_Bridge_Path_Proc,
	list_bridge_paths: Project_List_Bridge_Paths_Proc,
	delete_bridge_path: Project_Delete_Bridge_Path_Proc,
}

project_get :: proc(repo: ^Project_Repository, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Project{}, false, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.get(repo.ctx, project_id)
}

project_save :: proc(repo: ^Project_Repository, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	if repo == nil || repo.save == nil do return domain.Project{}, false, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.save(repo.ctx, project)
}

project_update :: proc(repo: ^Project_Repository, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	if repo == nil || repo.update == nil do return domain.Project{}, false, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.update(repo.ctx, project)
}

project_list_by_owner :: proc(repo: ^Project_Repository, owner_user_id: domain.User_ID) -> ([]domain.Project, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id)
}

project_save_bridge_path :: proc(repo: ^Project_Repository, path: domain.Project_Bridge_Path) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	if repo == nil || repo.save_bridge_path == nil do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.save_bridge_path(repo.ctx, path)
}

project_get_bridge_path :: proc(repo: ^Project_Repository, project_id: domain.Project_ID, bridge_id: string) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	if repo == nil || repo.get_bridge_path == nil do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.get_bridge_path(repo.ctx, project_id, bridge_id)
}

project_list_bridge_paths :: proc(repo: ^Project_Repository, project_id: domain.Project_ID, owner_user_id: domain.User_ID) -> ([]domain.Project_Bridge_Path, domain.Domain_Error) {
	if repo == nil || repo.list_bridge_paths == nil do return nil, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.list_bridge_paths(repo.ctx, project_id, owner_user_id)
}

project_delete_bridge_path :: proc(repo: ^Project_Repository, project_id: domain.Project_ID, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_bridge_path == nil do return false, domain.domain_error(.Internal_Error, "project repository is not configured")
	return repo.delete_bridge_path(repo.ctx, project_id, bridge_id, owner_user_id)
}
