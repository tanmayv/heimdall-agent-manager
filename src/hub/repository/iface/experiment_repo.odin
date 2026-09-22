package iface

import domain "odin_test:hub/domain"

Experiment_Set_Proc           :: proc(ctx: rawptr, exp: domain.Experiment) -> (bool, domain.Domain_Error)
Experiment_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error)

Experiment_Repository :: struct {
	ctx:            rawptr,
	set:            Experiment_Set_Proc,
	list_by_owner:  Experiment_List_By_Owner_Proc,
}

experiment_set :: proc(repo: ^Experiment_Repository, exp: domain.Experiment) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.set == nil do return false, domain.domain_error(.Internal_Error, "experiment repository is not configured")
	return repo.set(repo.ctx, exp)
}

experiment_list_by_owner :: proc(repo: ^Experiment_Repository, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "experiment repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id)
}
