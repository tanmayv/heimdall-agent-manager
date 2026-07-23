package iface

PAGE_DEFAULT_LIMIT :: 50
PAGE_MAX_LIMIT :: 200

Page_Params :: struct {
	limit:  int,
	cursor: string,
}

Page_Result :: struct {
	limit:       int,
	next_cursor: string,
	has_more:    bool,
}

Filter_Param :: struct {
	name:  string,
	value: string,
}

Sort_Direction :: enum {
	Asc,
	Desc,
}

Sort_Param :: struct {
	field:     string,
	direction: Sort_Direction,
}

Query_Params :: struct {
	page:    Page_Params,
	search:  string,
	filters: []Filter_Param,
	sort:    []Sort_Param,
	expand:  []string,
}

page_params :: proc(limit: int, cursor: string) -> Page_Params {
	clamped := limit
	if clamped <= 0 do clamped = PAGE_DEFAULT_LIMIT
	if clamped > PAGE_MAX_LIMIT do clamped = PAGE_MAX_LIMIT
	return Page_Params{limit = clamped, cursor = cursor}
}
