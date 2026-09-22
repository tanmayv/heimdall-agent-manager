package domain

import "core:strings"

Issue_Status :: enum {
	New,
	Fixed,
	Obsolete,
}

issue_status_string :: proc(status: Issue_Status) -> string {
	switch status {
	case .New:
		return "new"
	case .Fixed:
		return "fixed"
	case .Obsolete:
		return "obsolete"
	}
	return "new"
}

issue_status_from_string :: proc(value: string) -> Issue_Status {
	switch strings.to_lower(strings.trim_space(value)) {
	case "fixed":
		return .Fixed
	case "obsolete":
		return .Obsolete
	case "new", "":
		return .New
	}
	return .New
}

Issue_Scope_Type :: enum {
	Global,
	Project,
	Agent_ID,
	Bridge_ID,
}

issue_scope_type_string :: proc(scope_type: Issue_Scope_Type) -> string {
	switch scope_type {
	case .Global:
		return "global"
	case .Project:
		return "project"
	case .Agent_ID:
		return "agent_id"
	case .Bridge_ID:
		return "bridge_id"
	}
	return "global"
}

issue_scope_type_from_string :: proc(value: string) -> Issue_Scope_Type {
	switch strings.to_lower(strings.trim_space(value)) {
	case "project":
		return .Project
	case "agent_id", "agent":
		return .Agent_ID
	case "bridge_id", "bridge":
		return .Bridge_ID
	case "global", "":
		return .Global
	}
	return .Global
}

Issue :: struct {
	issue_id:      Issue_ID,
	owner_user_id: User_ID,
	title:         string,
	description:   string,
	created_by:    string,
	status:        Issue_Status,
	scope_type:    Issue_Scope_Type,
	target_id:     string,
	chain_id:      string,
	created_at:    string,
	updated_at:    string,
	closed_at:     string,
	vote_count:    int,
	comment_count: int,
	has_voted:     bool,
}

Issue_Comment :: struct {
	comment_id:    Issue_Comment_ID,
	issue_id:      Issue_ID,
	owner_user_id: User_ID,
	author_id:     string,
	author_name:   string,
	body:          string,
	created_at:    string,
	updated_at:    string,
}

Issue_Vote :: struct {
	issue_id:      Issue_ID,
	voter_id:      string,
	owner_user_id: User_ID,
	voter_name:    string,
	created_at:    string,
}

Issue_Filter :: struct {
	owner_user_id: User_ID,
	status:        string,
	scope_type:    string,
	target_id:     string,
	chain_id:      string,
	query:         string,
	limit:         int,
	offset:        int,
}
