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
}
