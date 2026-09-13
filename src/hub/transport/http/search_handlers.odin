package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import search_service "odin_test:hub/service/search"
import iface "odin_test:hub/repository/iface"

Search_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	search: ^search_service.Search_Service,
}

search_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Search_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	// All non-standard filters must be allowlisted: parse_api_query rejects any
	// unknown filter key as a validation error (see parse.odin), so an
	// un-allowlisted param would fail the whole request rather than be ignored.
	allowed_filters := [?]string{
		"types", "exclude",
		"task_ids", "chain_ids", "project_ids", "conversation_ids",
		"not_in_task_ids", "not_in_chain_ids", "not_in_project_ids", "not_in_conversation_ids",
	}
	parsed := parse_api_query(req.query, allowed_filters[:], nil, nil)
	defer parsed_query_free(&parsed)
	if len(parsed.errors) > 0 do return respond_error(domain.domain_error(.Validation_Failed, parsed.errors[0]), req.request_id)
	input := search_service.Search_Input{q = parsed.search, limit = search_limit_from_query(req.query, parsed.limit), cursor = parsed.cursor}
	for f in parsed.filters {
		switch f.name {
		case "types": input.types_csv = f.value
		case "exclude": input.exclude = f.value
		case "task_ids": input.task_ids = f.value
		case "chain_ids": input.chain_ids = f.value
		case "project_ids": input.project_ids = f.value
		case "conversation_ids": input.conversation_ids = f.value
		case "not_in_task_ids": input.not_in_task_ids = f.value
		case "not_in_chain_ids": input.not_in_chain_ids = f.value
		case "not_in_project_ids": input.not_in_project_ids = f.value
		case "not_in_conversation_ids": input.not_in_conversation_ids = f.value
		}
	}
	result, searched, err := search_service.search_resources(h.search, auth_ctx, input)
	if !searched do return respond_error(err, req.request_id)
	page_limit := input.limit
	if page_limit <= 0 do page_limit = search_service.DEFAULT_SEARCH_LIMIT
	if page_limit > search_service.MAX_SEARCH_LIMIT do page_limit = search_service.MAX_SEARCH_LIMIT
	data_json := search_groups_json(result.hits)
	return respond_search(data_json, contracts.API_Page{limit = page_limit, next_cursor = result.next_cursor, has_more = result.has_more}, req.request_id, auth_ctx_server_time(req))
}

search_groups_json :: proc(hits: []iface.Search_Hit) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"groups\":[")
	group_written := 0
	for resource_type in SEARCH_RESPONSE_TYPE_ORDER {
		count := count_hits_for_type(hits, resource_type)
		if count == 0 do continue
		if group_written > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"type\":\""); write_handler_json_string(&b, resource_type); strings.write_string(&b, "\",\"hits\":[")
		written := 0
		for hit in hits {
			if hit.resource_type != resource_type do continue
			if written > 0 do strings.write_byte(&b, ',')
			write_search_hit_json(&b, hit)
			written += 1
		}
		strings.write_string(&b, "]}")
		group_written += 1
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

SEARCH_RESPONSE_TYPE_ORDER :: [?]string{"conversation", "agent", "agent_instance", "task-chain", "task", "comment", "project", "artifact", "memory", "skill"}

search_limit_from_query :: proc(query: string, parsed_limit: int) -> int {
	if !query_has_key(query, "limit") do return search_service.DEFAULT_SEARCH_LIMIT
	return parsed_limit
}

query_has_key :: proc(query, key: string) -> bool {
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		candidate := pair
		if eq >= 0 do candidate = pair[:eq]
		if candidate == key do return true
	}
	return false
}

count_hits_for_type :: proc(hits: []iface.Search_Hit, resource_type: string) -> int {
	count := 0
	for hit in hits { if hit.resource_type == resource_type do count += 1 }
	return count
}

write_search_hit_json :: proc(b: ^strings.Builder, hit: iface.Search_Hit) {
	strings.write_string(b, "{\"id\":\""); write_handler_json_string(b, hit.id)
	strings.write_string(b, "\",\"label\":\""); write_handler_json_string(b, hit.label)
	strings.write_string(b, "\",\"sublabel\":\""); write_handler_json_string(b, hit.sublabel)
	strings.write_string(b, "\",\"score\":"); strings.write_string(b, score_json(hit.score))
	strings.write_string(b, ",\"route\":\""); write_handler_json_string(b, hit.route)
	// Clean nested shape (SEARCH-2 rework): parent is an object {id,type} for child
	// results (e.g. a comment's task) and null for top-level entities; preview is the
	// matched-text snippet; matched_field names the column that matched.
	strings.write_string(b, "\",\"parent\":")
	if hit.parent_id == "" && hit.parent_type == "" {
		strings.write_string(b, "null")
	} else {
		strings.write_string(b, "{\"id\":\""); write_handler_json_string(b, hit.parent_id)
		strings.write_string(b, "\",\"type\":\""); write_handler_json_string(b, hit.parent_type)
		strings.write_string(b, "\"}")
	}
	strings.write_string(b, ",\"preview\":\""); write_handler_json_string(b, hit.preview)
	strings.write_string(b, "\",\"matched_field\":\""); write_handler_json_string(b, hit.matched_field)
	strings.write_string(b, "\"}")
}

score_json :: proc(score: int) -> string {
	if score >= 100 do return "1.00"
	if score <= 0 do return "0.00"
	return fmt.tprintf("0.%02d", score)
}

respond_search :: proc(data_json: string, page: contracts.API_Page, request_id, server_time: string) -> Response {
	b := strings.builder_make()
	strings.write_string(&b, "{\"data\":")
	strings.write_string(&b, strings.trim_space(data_json))
	strings.write_string(&b, ",\"page\":{\"limit\":")
	strings.write_string(&b, fmt.tprintf("%d", page.limit))
	strings.write_string(&b, ",\"next_cursor\":")
	if page.next_cursor == "" { strings.write_string(&b, "null") } else { strings.write_string(&b, "\""); write_handler_json_string(&b, page.next_cursor); strings.write_string(&b, "\"") }
	strings.write_string(&b, ",\"has_more\":")
	strings.write_string(&b, "true" if page.has_more else "false")
	strings.write_string(&b, "},\"meta\":{\"request_id\":\"")
	write_handler_json_string(&b, request_id)
	strings.write_string(&b, "\",\"server_time\":\"")
	write_handler_json_string(&b, server_time)
	strings.write_string(&b, "\"}}")
	return Response{status = 200, content_type = "application/json", body = strings.to_string(b)}
}
