package domain

Action_State :: enum {
	Active,
	In_Flight,
	Completed,
}

Scheduled_Prompt_State :: Action_State

Action_Target_Mode :: enum {
	Instance,
	Agent,
}

Action :: struct {
	id:                 Action_ID,
	owner_user_id:      User_ID,
	target_instance_id: Agent_Instance_ID,
	prompt_text:        string,
	// Schedule fields (nullable/optional):
	cron_expr:          string, // 5-field standard cron, empty if run-only
	timezone:           string, // IANA timezone, defaults to "UTC"
	blackout_dates:     string, // JSON array of "YYYY-MM-DD" strings to skip
	active_from:        string, // ISO timestamp window start
	active_until:       string, // ISO timestamp window end
	target_run_at:      string, // Next computed fire time (ISO timestamp UTC)
	interval:           string, // Legacy interval or empty
	state:              Action_State,
	in_flight:          bool,
	leased_at:          string,
	deleted_at:         string,
	created_at:         string,
	updated_at:         string,
	// Agent targeting fields (REQ-SCHED-1):
	target_agent_id:    Agent_ID,
	target_bridge_id:   Bridge_ID,
	target_provider:    string,
	target_tier:        string,
	target_project_id:  Project_ID,
}

action_target_mode :: proc(action: Action) -> Action_Target_Mode {
	if action.target_instance_id != "" {
		return .Instance
	}
	return .Agent
}

Scheduled_Prompt :: Action

