package iface

import domain "odin_test:hub/domain"

Search_Hit :: struct {
	resource_type: string,
	id: string,
	label: string,
	sublabel: string,
	route: string,
	score: int,
}

Search_Query :: struct {
	owner_user_id: domain.User_ID,
	q: string,
	types_csv: string,
	response_limit: int,
	hard_scan_cap: int,
	cursor: string,
}

Search_Result :: struct {
	hits: []Search_Hit,
	has_more: bool,
	next_cursor: string,
}

Search_Proc :: proc(ctx: rawptr, query: Search_Query) -> (Search_Result, domain.Domain_Error)

Search_Repository :: struct {
	ctx: rawptr,
	search: Search_Proc,
}

search_resources :: proc(repo: ^Search_Repository, query: Search_Query) -> (Search_Result, domain.Domain_Error) {
	if repo == nil || repo.search == nil do return Search_Result{}, domain.domain_error(.Internal_Error, "search repository is not configured")
	return repo.search(repo.ctx, query)
}
