package domain

Action_State :: enum {
	Active,
	In_Flight,
	Completed,
}

Scheduled_Prompt_State :: Action_State

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
}

Scheduled_Prompt :: Action
