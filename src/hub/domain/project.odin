package domain

Project :: struct {
	project_id:    Project_ID,
	owner_user_id: User_ID,
	name:          string,
	slug:          string,
	description:   string,
	repo_url:      string,
	vcs_kind:      string,
	default_path:  string,
	created_at:    string,
	updated_at:    string,
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
