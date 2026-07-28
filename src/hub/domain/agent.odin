package domain

Agent_State :: enum {
	Active,
	Archived,
}

Agent :: struct {
	agent_id: string,
	owner_user_id: User_ID,
	name: string,
	slug: string,
	template_id: string,
	default_provider: string,
	default_tier: string,
	instructions: string,
	state: Agent_State,
	created_at: string,
	updated_at: string,
}

Agent_Bridge_Support :: struct {
	agent_id: string,
	bridge_id: string,
	owner_user_id: User_ID,
	enabled: bool,
	provider: string,
	tier: string,
	priority: int,
	max_instances: int,
	created_at: string,
	updated_at: string,
}

Resolved_Provider_Tier :: struct {
	provider: string,
	tier: string,
}

Agent_Instance :: struct {
	agent_instance_id: string,
	owner_user_id: User_ID,
	agent_id: string,
	bridge_id: string,
	provider: string,
	tier: string,
	project_id: Project_ID,
	project_path: string,
	chain_id: string,
	conversation_id: string,
	runtime_status: string,
	startup_status: string,
	activity_status: string,
	status_message: string,
	last_applied_seq: int,
	run_count: int,
	created_at: string,
	updated_at: string,
	started_at: string,
	stopped_at: string,
	last_seen_at: string,
}

agent_state_string :: proc(state: Agent_State) -> string {
	if state == .Archived do return "archived"
	return "active"
}
