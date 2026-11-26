package iface

import domain "odin_test:hub/domain"

Agent_Save_Proc :: proc(ctx: rawptr, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error)
Agent_Get_Proc :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error)
Agent_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent, domain.Domain_Error)
Agent_Save_Support_Proc :: proc(ctx: rawptr, support: domain.Agent_Bridge_Support) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error)
Agent_Get_Support_Proc :: proc(ctx: rawptr, agent_id, bridge_id: string) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error)
Agent_List_Support_Proc :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error)
Agent_Delete_Support_Proc :: proc(ctx: rawptr, agent_id, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)
Agent_Save_Instance_Proc :: proc(ctx: rawptr, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error)
Agent_Get_Instance_Proc :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error)
Agent_Delete_Instance_Proc :: proc(ctx: rawptr, instance_id: string) -> (bool, domain.Domain_Error)
Agent_List_Instances_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent_Instance, domain.Domain_Error)
Agent_List_Instances_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error)
// Lists the owner's instances bound to one chain (agent_instances.chain_id) — the
// matcher's chain-scoped read, so it never loads the owner's whole instance history.
Agent_List_Instances_By_Chain_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error)
// Lists instances still in an active runtime state (running/idle/busy/launching/
// starting/stopping) across all owners — used by the staleness reaper.
Agent_List_Active_Runtime_Instances_Proc :: proc(ctx: rawptr) -> ([]domain.Agent_Instance, domain.Domain_Error)
// Atomically increments and returns the per-agent global title counter. The
// counter survives daemon restarts (persisted in agent_title_counters) and is
// used to mint default per-run titles "<agent-name> #<n>".
Agent_Next_Title_Counter_Proc :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID, now: string) -> (int, bool, domain.Domain_Error)

// Token usage (T3r). update_token_usage replaces an instance's latest snapshot
// (only when the instance is pinned to bridge_id). add_token_totals adds one
// finished run's final usage to the lifetime totals exactly once: it applies
// only when run_count is newer than the last counted run and not beyond the
// instance's current run_count; added=false means it was a duplicate/stale.
Agent_Update_Token_Usage_Proc :: proc(ctx: rawptr, instance_id, bridge_id, usage_json, updated_at: string) -> (bool, domain.Domain_Error)
Agent_Add_Token_Totals_Proc :: proc(ctx: rawptr, instance_id, bridge_id: string, run_count: int, context_tokens, est_tool_tokens, output_tokens: i64) -> (added: bool, err: domain.Domain_Error)

// User activity stamp (coordinator idle-stop timers, REQ-CIS-1). touch moves
// agent_instances.user_activity_at forward to `at` (never backwards: an older
// or equal stamp leaves the row alone, changed=false). get reads it ("" =
// never touched). The column is not part of save_instance, so a stale save
// cannot roll it back.
Agent_Touch_User_Activity_Proc :: proc(ctx: rawptr, instance_id, at: string) -> (changed: bool, err: domain.Domain_Error)
Agent_Get_User_Activity_Proc :: proc(ctx: rawptr, instance_id: string) -> (at: string, found: bool, err: domain.Domain_Error)
// set_stop_reason records why the Hub stopped the instance (stop_instance's
// reason). Instance saves never write it; a new run (higher run_count) clears it.
Agent_Set_Stop_Reason_Proc :: proc(ctx: rawptr, instance_id, reason: string) -> (bool, domain.Domain_Error)

// Saved rows borrow the input fields, matching agent_save_instance. updated=false
// with no error means the expected generation no longer matches.
Agent_Save_Instance_Guarded_Proc :: proc(ctx: rawptr, instance: domain.Agent_Instance, expect_run_count: int, expect_launch_epoch: string, expect_configuration_revision: int) -> (saved: domain.Agent_Instance, updated: bool, err: domain.Domain_Error)

// Empty fields do not filter. runtime_statuses matches any listed status.
// cursor is the created_at of the last row of the previous page.
Agent_Instance_Filter :: struct {
	agent_id:         string,
	bridge_id:        string,
	project_id:       string,
	runtime_statuses: []string,
}

Agent_List_Instances_Filtered_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, filter: Agent_Instance_Filter, limit: int, cursor: string) -> ([]domain.Agent_Instance, domain.Domain_Error)

Agent_Repository :: struct {
	list_instances_filtered: Agent_List_Instances_Filtered_Proc,
 list_action_instances: proc(ctx:rawptr,owner:domain.User_ID,agent_id,bridge_id:string)->([]domain.Agent_Instance,domain.Domain_Error),
	update_token_usage: Agent_Update_Token_Usage_Proc,
	add_token_totals: Agent_Add_Token_Totals_Proc,
	runtime_busy:Agent_Runtime_Busy_Proc,
	ctx: rawptr,
	reconfiguration_begin: Instance_Reconfiguration_Begin_Proc,
	reconfiguration_get: Instance_Reconfiguration_Get_Proc,
	reconfiguration_advance: Instance_Reconfiguration_Advance_Proc,
	reconfiguration_list: Instance_Reconfiguration_List_Proc,
	// Additive (T4): optional; nil means no queued operations are supported.
	reconfiguration_list_waiting: Instance_Reconfiguration_List_Waiting_Proc,
	reconfiguration_begin_superseding: Instance_Reconfiguration_Begin_Superseding_Proc,
	save: Agent_Save_Proc,
	get: Agent_Get_Proc,
	list_by_owner: Agent_List_By_Owner_Proc,
	list_agent_refs: Agent_Catalog_Page_Proc,
	list_instance_refs: Agent_Catalog_Page_Proc,
	save_support: Agent_Save_Support_Proc,
	get_support: Agent_Get_Support_Proc,
	list_support: Agent_List_Support_Proc,
	delete_support: Agent_Delete_Support_Proc,
	save_instance: Agent_Save_Instance_Proc,
	save_instance_guarded: Agent_Save_Instance_Guarded_Proc,
	get_instance: Agent_Get_Instance_Proc,
	delete_instance: Agent_Delete_Instance_Proc,
	list_instances_by_owner: Agent_List_Instances_By_Owner_Proc,
	list_instances_by_bridge: Agent_List_Instances_By_Bridge_Proc,
	list_instances_by_chain: Agent_List_Instances_By_Chain_Proc,
	list_tool_instances_by_chain: Agent_List_Instances_By_Chain_Proc,
	get_tool_instance: Agent_Get_Instance_Proc,
	list_active_runtime_instances: Agent_List_Active_Runtime_Instances_Proc,
	next_title_counter: Agent_Next_Title_Counter_Proc,
	touch_user_activity: Agent_Touch_User_Activity_Proc,
	get_user_activity: Agent_Get_User_Activity_Proc,
	set_stop_reason: Agent_Set_Stop_Reason_Proc,
}

agent_next_title_counter :: proc(repo: ^Agent_Repository, agent_id: string, owner_user_id: domain.User_ID, now: string) -> (int, bool, domain.Domain_Error) {
	if repo == nil || repo.next_title_counter == nil do return 0, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.next_title_counter(repo.ctx, agent_id, owner_user_id, now)
}

agent_save :: proc(repo: ^Agent_Repository, agent: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	if repo == nil || repo.save == nil do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.save(repo.ctx, agent)
}

agent_get :: proc(repo: ^Agent_Repository, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	if repo == nil || repo.get == nil do return domain.Agent{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get(repo.ctx, agent_id)
}

agent_list_by_owner :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, limit: int = 50, cursor: string = "") -> ([]domain.Agent, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id, limit, cursor)
}

agent_save_support :: proc(repo: ^Agent_Repository, support: domain.Agent_Bridge_Support) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	if repo == nil || repo.save_support == nil do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.save_support(repo.ctx, support)
}

agent_get_support :: proc(repo: ^Agent_Repository, agent_id, bridge_id: string) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	if repo == nil || repo.get_support == nil do return domain.Agent_Bridge_Support{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get_support(repo.ctx, agent_id, bridge_id)
}

agent_list_support :: proc(repo: ^Agent_Repository, agent_id: string, owner_user_id: domain.User_ID) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error) {
	if repo == nil || repo.list_support == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_support(repo.ctx, agent_id, owner_user_id)
}

agent_delete_support :: proc(repo: ^Agent_Repository, agent_id, bridge_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_support == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.delete_support(repo.ctx, agent_id, bridge_id, owner_user_id)
}

agent_save_instance :: proc(repo: ^Agent_Repository, instance: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if repo == nil || repo.save_instance == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.save_instance(repo.ctx, instance)
}

agent_get_instance :: proc(repo: ^Agent_Repository, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if repo == nil || repo.get_instance == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get_instance(repo.ctx, instance_id)
}

agent_delete_instance :: proc(repo: ^Agent_Repository, instance_id: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_instance == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.delete_instance(repo.ctx, instance_id)
}

agent_list_instances_by_owner :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_by_owner(repo.ctx, owner_user_id, limit, cursor)
}

agent_list_instances_filtered :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, filter: Agent_Instance_Filter, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_filtered == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_filtered(repo.ctx, owner_user_id, filter, limit, cursor)
}

agent_list_active_runtime_instances :: proc(repo: ^Agent_Repository) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_active_runtime_instances == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_active_runtime_instances(repo.ctx)
}

agent_list_instances_by_bridge :: proc(repo: ^Agent_Repository, bridge_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_by_bridge == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_by_bridge(repo.ctx, bridge_id)
}

agent_list_instances_by_chain :: proc(repo: ^Agent_Repository, owner_user_id: domain.User_ID, chain_id: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
	if repo == nil || repo.list_instances_by_chain == nil do return nil, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.list_instances_by_chain(repo.ctx, owner_user_id, chain_id)
}

agent_touch_user_activity :: proc(repo: ^Agent_Repository, instance_id, at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.touch_user_activity == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.touch_user_activity(repo.ctx, instance_id, at)
}

agent_set_stop_reason :: proc(repo: ^Agent_Repository, instance_id, reason: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.set_stop_reason == nil do return false, {}
	return repo.set_stop_reason(repo.ctx, instance_id, reason)
}

agent_get_user_activity :: proc(repo: ^Agent_Repository, instance_id: string) -> (string, bool, domain.Domain_Error) {
	if repo == nil || repo.get_user_activity == nil do return "", false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	return repo.get_user_activity(repo.ctx, instance_id)
}

agent_update_token_usage :: proc(repo: ^Agent_Repository, instance_id, bridge_id, usage_json, updated_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.update_token_usage == nil do return false, {}
	return repo.update_token_usage(repo.ctx, instance_id, bridge_id, usage_json, updated_at)
}

agent_add_token_totals :: proc(repo: ^Agent_Repository, instance_id, bridge_id: string, run_count: int, context_tokens, est_tool_tokens, output_tokens: i64) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.add_token_totals == nil do return false, {}
	return repo.add_token_totals(repo.ctx, instance_id, bridge_id, run_count, context_tokens, est_tool_tokens, output_tokens)
}


agent_save_instance_guarded :: proc(repo: ^Agent_Repository, instance: domain.Agent_Instance, expect_run_count: int, expect_launch_epoch: string, expect_configuration_revision: int) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
 if repo == nil || repo.save_instance_guarded == nil do return {}, false, domain.domain_error(.Internal_Error, "guarded agent repository is not configured")
 return repo.save_instance_guarded(repo.ctx, instance, expect_run_count, expect_launch_epoch, expect_configuration_revision)
}
