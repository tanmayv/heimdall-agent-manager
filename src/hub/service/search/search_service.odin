package search

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"

DEFAULT_SEARCH_LIMIT :: 20
MAX_SEARCH_LIMIT :: 50
MAX_SEARCH_SCAN_CAP :: 200

Search_Service :: struct {
	search_repo: ^iface.Search_Repository,
}

Search_Input :: struct {
	q: string,
	types_csv: string,
	limit: int,
	cursor: string,
	// Typed per-parent id filters (SEARCH-8); each a CSV, empty = no constraint.
	// AND-ed with owner in the repo. Bounded to task/chain/project/conversation.
	task_ids: string,
	chain_ids: string,
	project_ids: string,
	conversation_ids: string,
	not_in_task_ids: string,
	not_in_chain_ids: string,
	not_in_project_ids: string,
	not_in_conversation_ids: string,
	exclude: string,   // substring; empty = no exclusion.
}

new_search_service :: proc(repo: ^iface.Search_Repository) -> Search_Service {
	return Search_Service{search_repo = repo}
}

// validate_types_csv rejects a scope token that does not name a real search type
// (REQ-CLI-5). Before this, an unrecognized scope simply matched no per-type query
// and the search returned ok + zero hits — a typo turned a populated Hub into an
// apparently empty one, which is a FALSE NEGATIVE that looks exactly like a
// correct "no results" answer.
//
// Membership is checked AFTER normalization, via domain.search_type_is_valid:
// domain.normalize_search_type returns unknown input UNCHANGED, so leaning on
// normalization to reject would reproduce the defect being fixed here.
//
// An empty/absent csv still means "all scopes" — no behavior change. The `all`
// wildcard is still accepted, but it excuses only ITSELF: `all,bogusscope` is
// rejected rather than silently succeeding, so a typo is reported wherever it
// appears instead of being masked by a wildcard next to it. The result set is
// unaffected either way, so no caller loses hits.
validate_types_csv :: proc(types_csv: string) -> (bool, domain.Domain_Error) {
	trimmed := strings.trim_space(types_csv)
	if trimmed == "" do return true, domain.Domain_Error{}
	parts := strings.split(trimmed, ",")
	defer delete(parts)
	for raw in parts {
		token := strings.trim_space(raw)
		if token == "all" do continue
		if domain.search_type_is_valid(token) do continue
		valid := domain.search_type_names_csv()
		defer delete(valid)
		msg := strings.concatenate({"unknown search scope \"", token, "\"; valid scopes are: ", valid})
		return false, domain.domain_error(.Validation_Failed, msg)
	}
	return true, domain.Domain_Error{}
}

search_resources :: proc(service: ^Search_Service, auth: contracts.Auth_Context, input: Search_Input) -> (iface.Search_Result, bool, domain.Domain_Error) {
	owner, owner_ok, owner_err := ownership.owner_from_auth(auth)
	if !owner_ok do return iface.Search_Result{}, false, owner_err
	if types_ok, types_err := validate_types_csv(input.types_csv); !types_ok {
		return iface.Search_Result{}, false, types_err
	}
	q := strings.trim_space(input.q)
	response_limit := input.limit
	if response_limit <= 0 do response_limit = DEFAULT_SEARCH_LIMIT
	if response_limit > MAX_SEARCH_LIMIT do response_limit = MAX_SEARCH_LIMIT
	hard_scan_cap := response_limit * 4
	if hard_scan_cap < response_limit do hard_scan_cap = response_limit
	if hard_scan_cap > MAX_SEARCH_SCAN_CAP do hard_scan_cap = MAX_SEARCH_SCAN_CAP
	if q == "" {
		return iface.Search_Result{hits = make([]iface.Search_Hit, 0), has_more = false}, true, domain.Domain_Error{}
	}
	result, err := iface.search_resources(service.search_repo, iface.Search_Query{
		owner_user_id = owner, q = q, types_csv = input.types_csv,
		response_limit = response_limit, hard_scan_cap = hard_scan_cap, cursor = input.cursor,
		task_ids = input.task_ids, chain_ids = input.chain_ids, project_ids = input.project_ids, conversation_ids = input.conversation_ids,
		not_in_task_ids = input.not_in_task_ids, not_in_chain_ids = input.not_in_chain_ids, not_in_project_ids = input.not_in_project_ids, not_in_conversation_ids = input.not_in_conversation_ids,
		exclude = input.exclude,
	})
	if err.code != .None do return iface.Search_Result{}, false, err
	return result, true, domain.Domain_Error{}
}
