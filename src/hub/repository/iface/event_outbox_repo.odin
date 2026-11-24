package iface

import domain "odin_test:hub/domain"

// All operations run inside a Unit_Of_Work. append borrows row; next returns
// caller-owned strings (destroy with domain.event_outbox_row_destroy).
// headers_json is a JSON object of string header names to string values.
Event_Outbox_Repository :: struct {
 contains: proc(ctx:rawptr,event_id:string)->(bool,domain.Domain_Error),
 append_if_absent: proc(ctx:rawptr,row:domain.Event_Outbox_Row)->(bool,domain.Domain_Error),
	backlog_owner: proc(ctx: rawptr, owner: string) -> (i64, domain.Domain_Error),
	ctx:            rawptr,
	set_state_head: proc(ctx: rawptr, owner, kind, id, event_type, event_id: string, version: i64) -> domain.Domain_Error,
	state_head_matches: proc(ctx: rawptr, owner, kind, id, event_type, event_id: string) -> (bool, domain.Domain_Error),
	next_version:   proc(ctx: rawptr, owner, kind, id: string) -> (i64, domain.Domain_Error),
	open_topic:     proc(
		ctx: rawptr,
		owner, topic, event_id: string,
		replace_open: bool,
	) -> (
		i64,
		bool,
		domain.Domain_Error,
	),
	resolve_topic:  proc(ctx: rawptr, owner, topic, at, event_id: string) -> domain.Domain_Error,
	append:         proc(ctx: rawptr, row: domain.Event_Outbox_Row) -> domain.Domain_Error,
	next:           proc(ctx: rawptr) -> (domain.Event_Outbox_Row, bool, domain.Domain_Error),
	mark_published: proc(ctx: rawptr, seq: i64, published_at: string) -> domain.Domain_Error,
	backlog:        proc(ctx: rawptr) -> (i64, domain.Domain_Error),
	prune:          proc(ctx: rawptr, before: string) -> domain.Domain_Error,
}
