package iface

import domain "odin_test:hub/domain"

Scheduled_Prompt_Save_Proc :: proc(ctx: rawptr, prompt: domain.Scheduled_Prompt) -> (domain.Scheduled_Prompt, bool, domain.Domain_Error)
Scheduled_Prompt_Get_Proc :: proc(ctx: rawptr, id: domain.Scheduled_Prompt_ID) -> (domain.Scheduled_Prompt, bool, domain.Domain_Error)
Scheduled_Prompt_Delete_Proc :: proc(ctx: rawptr, id: domain.Scheduled_Prompt_ID) -> (bool, domain.Domain_Error)
Scheduled_Prompt_List_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Scheduled_Prompt, domain.Domain_Error)
Scheduled_Prompt_List_By_Instance_Proc :: proc(ctx: rawptr, instance_id: domain.Agent_Instance_ID) -> ([]domain.Scheduled_Prompt, domain.Domain_Error)
Scheduled_Prompt_CAS_Lease_Proc :: proc(ctx: rawptr, id: domain.Scheduled_Prompt_ID, leased_at: string, now: string) -> (bool, domain.Domain_Error)
Scheduled_Prompt_Max_Updated_Proc :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID) -> (string, domain.Domain_Error)

Scheduled_Prompt_Repository :: struct {
	ctx: rawptr,
	save: Scheduled_Prompt_Save_Proc,
	get: Scheduled_Prompt_Get_Proc,
	delete_prompt: Scheduled_Prompt_Delete_Proc,
	list: Scheduled_Prompt_List_Proc,
	list_by_instance: Scheduled_Prompt_List_By_Instance_Proc,
	cas_lease: Scheduled_Prompt_CAS_Lease_Proc,
	max_updated_at_for_bridge: Scheduled_Prompt_Max_Updated_Proc,
}
