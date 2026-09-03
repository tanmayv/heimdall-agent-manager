package domain

Agent_State :: enum {
	Active,
	Archived,
}

// Current_Task_Role describes, for an instance's persisted current_task, whether
// the instance is acting on it as the assignee doing work or as a reviewer.
// None means the instance has no active current task.
Current_Task_Role :: enum {
	None,
	Work,
	Review,
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
	// display_name is the human-readable title for this instance (defaults to "<agent-name> #<n>").
	display_name: string,
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
	// current_task_id is the single task this instance is actively focused on
	// (either working or reviewing). Empty when the instance has no current task.
	current_task_id: string,
	// current_task_role indicates whether current_task_id is work or review.
	current_task_role: Current_Task_Role,
	created_at: string,
	updated_at: string,
	started_at: string,
	stopped_at: string,
	last_seen_at: string,
}

current_task_role_string :: proc(role: Current_Task_Role) -> string {
	switch role {
	case .Work: return "work"
	case .Review: return "review"
	case .None: return "none"
	}
	return "none"
}

current_task_role_from_string :: proc(value: string) -> Current_Task_Role {
	switch value {
	case "work": return .Work
	case "review": return .Review
	}
	return .None
}

agent_state_string :: proc(state: Agent_State) -> string {
	if state == .Archived do return "archived"
	return "active"
}
