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
}

new_search_service :: proc(repo: ^iface.Search_Repository) -> Search_Service {
	return Search_Service{search_repo = repo}
}

search_resources :: proc(service: ^Search_Service, auth: contracts.Auth_Context, input: Search_Input) -> (iface.Search_Result, bool, domain.Domain_Error) {
	owner, owner_ok, owner_err := ownership.owner_from_auth(auth)
	if !owner_ok do return iface.Search_Result{}, false, owner_err
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
	result, err := iface.search_resources(service.search_repo, iface.Search_Query{owner_user_id = owner, q = q, types_csv = input.types_csv, response_limit = response_limit, hard_scan_cap = hard_scan_cap, cursor = input.cursor})
	if err.code != .None do return iface.Search_Result{}, false, err
	return result, true, domain.Domain_Error{}
}
