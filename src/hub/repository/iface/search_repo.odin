package iface

import domain "odin_test:hub/domain"

Search_Hit :: struct {
	resource_type: string,
	id: string,
	label: string,
	sublabel: string,
	route: string,
	score: int,
	// Additive fields (SEARCH-2). For the id/name entity providers parent_id/
	// parent_type are empty (emitted as JSON null) and preview is empty; matched_field
	// records which column matched. Child providers (comments/skills, SEARCH-3) set
	// parent_* to the owning entity and preview to a snippet.
	parent_id: string,
	parent_type: string,
	preview: string,
	matched_field: string,
}

Search_Query :: struct {
	owner_user_id: domain.User_ID,
	q: string,
	types_csv: string,
	response_limit: int,
	hard_scan_cap: int,
	cursor: string,
	// Typed per-parent id filters (SEARCH-8). Each is a CSV of ids; empty = no
	// constraint for that dimension. A positive filter keeps only rows whose
	// matching parent column is in the set; a not_in_* filter drops rows whose
	// column is in the set. Bounded to the 4 containment parents
	// (task/chain/project/conversation). Every typed filter is AND-ed with
	// owner_user_id in the repository, so a caller can never read another owner's
	// rows by naming their ids.
	task_ids: string,
	chain_ids: string,
	project_ids: string,
	conversation_ids: string,
	not_in_task_ids: string,
	not_in_chain_ids: string,
	not_in_project_ids: string,
	not_in_conversation_ids: string,
	// exclude drops any hit whose display text contains this substring
	// (case-insensitive). Empty = no exclusion.
	exclude: string,
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
