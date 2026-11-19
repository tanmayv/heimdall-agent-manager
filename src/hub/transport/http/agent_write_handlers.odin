package http

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"

Agent_Write_Handlers :: struct {
	auth:   ^auth_service.Auth_Service,
	writes: ^iface.Agent_Write_Repository,
}
list_agent_writes_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Write_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp
	limit := query_int(req.query, "limit", 50)
	if limit <= 0 do limit = 50
	if limit > 200 do limit = 200
	before, cursor_valid := strconv.parse_i64(query_value(req.query, "cursor"))
	if !cursor_valid do before = 0
	rows, err := iface.agent_write_list_by_owner(h.writes, auth.user_id, before, limit + 1)
	if err.code != .None do return respond_error(err, req.request_id)
	defer {
		for &row in rows do domain.agent_write_destroy(&row)
		delete(rows)
	}
	has_more := len(rows) > limit
	page_rows := rows[:min(len(rows), limit)]
	// The transport omits owner_user_id: it is the query scope, not public actor metadata.
	Wire_Write :: struct {
		write_id:                                                    string,
		seq:                                                         i64,
		actor_agent_instance_id, actor_agent_id, actor_display_name: string,
		resource_kind, resource_id, action:                          string,
		fields:                                                      []string,
		created_at:                                                  string,
	}
	values := make([]Wire_Write, len(page_rows))
	defer delete(values)
	for w, i in page_rows {
		values[i] = {
			w.write_id,
			w.seq,
			w.actor_agent_instance_id,
			w.actor_agent_id,
			w.actor_display_name,
			w.resource_kind,
			w.resource_id,
			w.action,
			w.fields,
			w.created_at,
		}
		if values[i].fields == nil do values[i].fields = []string{}
	}
	body, marshal_err := json.marshal(values)
	if marshal_err != nil do return respond_error(domain.domain_error(.Internal_Error, "agent writes encoding failed"), req.request_id)
	defer delete(body)
	next := ""
	if has_more do next = fmt.tprintf("%d", page_rows[len(page_rows) - 1].seq)
	return respond_list(
		string(body),
		contracts.API_Page{limit = limit, next_cursor = next, has_more = has_more},
		req.request_id,
		auth_ctx_server_time(req),
	)
}
