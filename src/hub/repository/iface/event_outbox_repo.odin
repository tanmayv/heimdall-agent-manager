package iface

import domain "odin_test:hub/domain"

// All operations run inside a Unit_Of_Work. append borrows row; next returns
// caller-owned strings (destroy with domain.event_outbox_row_destroy).
// headers_json is a JSON object of string header names to string values.
Event_Outbox_Repository :: struct {
	ctx: rawptr,
	append: proc(ctx: rawptr, row: domain.Event_Outbox_Row) -> domain.Domain_Error,
	next: proc(ctx: rawptr) -> (domain.Event_Outbox_Row, bool, domain.Domain_Error),
	mark_published: proc(ctx: rawptr, seq: i64, published_at: string) -> domain.Domain_Error,
	backlog: proc(ctx: rawptr) -> (i64, domain.Domain_Error),
	prune: proc(ctx: rawptr, before: string) -> domain.Domain_Error,
}
