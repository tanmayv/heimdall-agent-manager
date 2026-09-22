package issue

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"

Issue_Create_Input :: struct {
	title:       string,
	description: string,
	created_by:  string,
	scope_type:  string,
	target_id:   string,
	chain_id:    string,
}

Issue_Update_Input :: struct {
	title:       string,
	has_title:   bool,
	description: string,
	has_desc:    bool,
	status:      string,
	has_status:  bool,
	scope_type:  string,
	has_scope:   bool,
	target_id:   string,
	has_target:  bool,
	chain_id:    string,
	has_chain:   bool,
}

Issue_Comment_Input :: struct {
	author_id:   string,
	author_name: string,
	body:        string,
}

Issue_Filter_Input :: struct {
	status:      string,
	scope_type:  string,
	target_id:   string,
	chain_id:    string,
	query:       string,
	voter_id:    string,
	limit:       int,
	offset:      int,
}

Issue_Service :: struct {
	issues: ^iface.Issue_Repository,
	clock:  ^platform.Clock,
	ids:    ^platform.ID_Generator,
}

new_issue_service :: proc(
	issues: ^iface.Issue_Repository,
	clock:  ^platform.Clock = nil,
	ids:    ^platform.ID_Generator = nil,
) -> Issue_Service {
	return Issue_Service{
		issues = issues,
		clock  = clock,
		ids    = ids,
	}
}

create_issue :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, input: Issue_Create_Input) -> (domain.Issue, bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return domain.Issue{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Issue{}, false, err

	title := strings.trim_space(input.title)
	if title == "" {
		return domain.Issue{}, false, domain.domain_error(.Validation_Failed, "issue title is required")
	}

	scope_type := domain.issue_scope_type_from_string(input.scope_type)
	created_by := input.created_by
	if created_by == "" do created_by = auth.user_id

	now := platform.clock_now(s.clock)
	issue_id := domain.Issue_ID(platform.generate_id(s.ids, "iss_"))

	issue := domain.Issue{
		issue_id      = issue_id,
		owner_user_id = owner,
		title         = title,
		description   = input.description,
		created_by    = created_by,
		status        = .New,
		scope_type    = scope_type,
		target_id     = input.target_id,
		chain_id      = input.chain_id,
		created_at    = now,
		updated_at    = now,
		closed_at     = "",
		vote_count    = 0,
		comment_count = 0,
		has_voted     = false,
	}

	return iface.issue_save(s.issues, issue)
}

get_issue :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID, voter_id: string = "") -> (domain.Issue, bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return domain.Issue{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Issue{}, false, err

	issue, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return domain.Issue{}, false, get_err

	if voter_id != "" {
		voted, _ := iface.issue_has_voted(s.issues, issue_id, voter_id)
		issue.has_voted = voted
	}

	return issue, true, domain.Domain_Error{}
}

list_issues :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, filter: Issue_Filter_Input) -> ([]domain.Issue, domain.Domain_Error) {
	if s == nil || s.issues == nil do return nil, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	domain_filter := domain.Issue_Filter{
		owner_user_id = owner,
		status        = filter.status,
		scope_type    = filter.scope_type,
		target_id     = filter.target_id,
		chain_id      = filter.chain_id,
		query         = filter.query,
		limit         = filter.limit,
		offset        = filter.offset,
	}

	issues, list_err := iface.issue_list(s.issues, domain_filter)
	if list_err.code != .None do return nil, list_err

	if filter.voter_id != "" {
		for &iss in issues {
			voted, _ := iface.issue_has_voted(s.issues, iss.issue_id, filter.voter_id)
			iss.has_voted = voted
		}
	}

	return issues, domain.Domain_Error{}
}

update_issue :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID, input: Issue_Update_Input) -> (domain.Issue, bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return domain.Issue{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Issue{}, false, err

	existing, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return domain.Issue{}, false, get_err

	now := platform.clock_now(s.clock)

	if input.has_title {
		title := strings.trim_space(input.title)
		if title == "" do return domain.Issue{}, false, domain.domain_error(.Validation_Failed, "issue title cannot be empty")
		existing.title = title
	}
	if input.has_desc {
		existing.description = input.description
	}
	if input.has_scope {
		existing.scope_type = domain.issue_scope_type_from_string(input.scope_type)
	}
	if input.has_target {
		existing.target_id = input.target_id
	}
	if input.has_chain {
		existing.chain_id = input.chain_id
	}
	if input.has_status {
		new_status := domain.issue_status_from_string(input.status)
		if (new_status == .Fixed || new_status == .Obsolete) {
			if existing.closed_at == "" {
				existing.closed_at = now
			}
		} else if new_status == .New {
			existing.closed_at = ""
		}
		existing.status = new_status
	}

	existing.updated_at = now

	return iface.issue_update(s.issues, existing)
}

delete_issue :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID) -> (bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err

	return iface.issue_delete(s.issues, issue_id, owner)
}

add_comment :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID, input: Issue_Comment_Input) -> (domain.Issue_Comment, bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return domain.Issue_Comment{}, false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Issue_Comment{}, false, err

	body := strings.trim_space(input.body)
	if body == "" do return domain.Issue_Comment{}, false, domain.domain_error(.Validation_Failed, "comment body cannot be empty")

	existing, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return domain.Issue_Comment{}, false, get_err

	now := platform.clock_now(s.clock)
	comment_id := domain.Issue_Comment_ID(platform.generate_id(s.ids, "icmt_"))

	author_id := input.author_id
	if author_id == "" do author_id = auth.user_id

	comment := domain.Issue_Comment{
		comment_id    = comment_id,
		issue_id      = issue_id,
		owner_user_id = owner,
		author_id     = author_id,
		author_name   = input.author_name,
		body          = body,
		created_at    = now,
		updated_at    = now,
	}

	saved, save_ok, save_err := iface.issue_save_comment(s.issues, comment)
	if !save_ok do return domain.Issue_Comment{}, false, save_err

	existing.updated_at = now
	_, _, _ = iface.issue_update(s.issues, existing)

	return saved, true, domain.Domain_Error{}
}

list_comments :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID) -> ([]domain.Issue_Comment, domain.Domain_Error) {
	if s == nil || s.issues == nil do return nil, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	_, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return nil, get_err

	return iface.issue_list_comments(s.issues, issue_id, owner)
}

delete_comment :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, comment_id: domain.Issue_Comment_ID) -> (bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err

	return iface.issue_delete_comment(s.issues, comment_id, owner)
}

vote_issue :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID, voter_id: string, voter_name: string = "") -> (bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err

	voter := strings.trim_space(voter_id)
	if voter == "" do voter = auth.user_id
	if voter == "" do return false, domain.domain_error(.Validation_Failed, "voter_id is required")

	existing, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return false, get_err

	now := platform.clock_now(s.clock)
	vote := domain.Issue_Vote{
		issue_id      = issue_id,
		voter_id      = voter,
		owner_user_id = owner,
		voter_name    = voter_name,
		created_at    = now,
	}

	saved, save_err := iface.issue_save_vote(s.issues, vote)
	if !saved do return false, save_err

	existing.updated_at = now
	_, _, _ = iface.issue_update(s.issues, existing)

	return true, domain.Domain_Error{}
}

unvote_issue :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID, voter_id: string) -> (bool, domain.Domain_Error) {
	if s == nil || s.issues == nil do return false, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err

	voter := strings.trim_space(voter_id)
	if voter == "" do voter = auth.user_id
	if voter == "" do return false, domain.domain_error(.Validation_Failed, "voter_id is required")

	existing, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return false, get_err

	removed, remove_err := iface.issue_remove_vote(s.issues, issue_id, voter, owner)
	if !removed do return false, remove_err

	now := platform.clock_now(s.clock)
	existing.updated_at = now
	_, _, _ = iface.issue_update(s.issues, existing)

	return true, domain.Domain_Error{}
}

list_votes :: proc(s: ^Issue_Service, auth: contracts.Auth_Context, issue_id: domain.Issue_ID) -> ([]domain.Issue_Vote, domain.Domain_Error) {
	if s == nil || s.issues == nil do return nil, domain.domain_error(.Internal_Error, "issue repository is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	_, found, get_err := iface.issue_get(s.issues, issue_id, owner)
	if !found do return nil, get_err

	return iface.issue_list_votes(s.issues, issue_id)
}
