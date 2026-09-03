package domain

Scheduled_Prompt_State :: enum {
	Active,
	In_Flight,
	Completed,
}

Scheduled_Prompt :: struct {
	id:                 Scheduled_Prompt_ID,
	owner_user_id:      User_ID,
	target_instance_id: Agent_Instance_ID,
	prompt_text:        string,
	target_run_at:      string, // ISO timestamp
	interval:           string, // empty = once
	state:              Scheduled_Prompt_State,
	in_flight:          bool,
	leased_at:          string,
	deleted_at:         string,
	created_at:         string,
	updated_at:         string,
}
