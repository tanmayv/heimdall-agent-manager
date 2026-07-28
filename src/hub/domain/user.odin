package domain

User_Status :: enum {
	Active,
	Disabled,
}

User :: struct {
	user_id:       User_ID,
	name:          string,
	display_name:   string,
	email:          string,
	status:         User_Status,
	created_at:     string,
	updated_at:     string,
}

User_API_Token :: struct {
	token_id:      string,
	owner_user_id: User_ID,
	label:         string,
	token_hash:    string,
	created_at:    string,
	updated_at:    string,
	last_used_at:  string,
	expires_at:    string,
	revoked_at:    string,
	// Provenance (ELDA-4): 'operator' for CLI-issued tokens,
	// 'device_authorization' for device-flow tokens. Defaults to 'operator' so
	// pre-existing tokens stay valid after the 003 migration.
	created_from:  string,
	device_label:  string,
}
