package domain

// Project_State mirrors Agent_State: projects are soft-archived (reversible),
// never hard-deleted. Archived projects are still returned by lists (parity with
// agents) and simply carry the Archived state.
Project_State :: enum {
	Active,
	Archived,
}

Project :: struct {
	project_id:    Project_ID,
	owner_user_id: User_ID,
	name:          string,
	slug:          string,
	description:   string,
	repo_url:      string,
	vcs_kind:      string,
	default_path:   string,
	state:          Project_State,
	project_type:   string, // "local" | "fig" (default "local")
	workspace_name: string,
	relative_path:  string,
	created_at:     string,
	updated_at:     string,
}

project_state_string :: proc(state: Project_State) -> string {
	if state == .Archived do return "archived"
	return "active"
}

Project_Bridge_Path :: struct {
	project_id:        Project_ID,
	bridge_id:         string,
	owner_user_id:     User_ID,
	path:              string,
	is_validated:      bool,
	last_validated_at: string,
	validation_error:  string,
	validation_details_json: string,
	created_at:        string,
	updated_at:        string,
}
