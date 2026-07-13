package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:strconv"

// GET /task-chains
handle_get_task_chains :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return

	created_after_str := query_param_value(ctx.query, "created_after")
	created_before_str := query_param_value(ctx.query, "created_before")
	status_filter := query_param_value(ctx.query, "status")
	evaluation_filter := query_param_value(ctx.query, "evaluation")
	limit_str := query_param_value(ctx.query, "limit")
	offset_str := query_param_value(ctx.query, "offset")
	
	created_after := i64(0)
	created_before := i64(0)
	limit := 20
	offset := 0

	if created_after_str != "" {
		if val, parse_ok := strconv.parse_i64(created_after_str); parse_ok do created_after = val
	}
	if created_before_str != "" {
		if val, parse_ok := strconv.parse_i64(created_before_str); parse_ok do created_before = val
	}
	if limit_str != "" {
		if val, parse_ok := strconv.parse_int(limit_str); parse_ok do limit = int(val)
	}
	if offset_str != "" {
		if val, parse_ok := strconv.parse_int(offset_str); parse_ok do offset = int(val)
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"chains":[`)
	
	first := true
	count := 0
	matched_count := 0

	for chain in store_all_chains() {
		// Apply filters
		if created_after > 0 && chain.created_at_unix_ms < created_after do continue
		if created_before > 0 && chain.created_at_unix_ms > created_before do continue
		if status_filter != "" && chain.status != status_filter do continue
		if evaluation_filter != "" && chain.evaluation != evaluation_filter do continue
		
		matched_count += 1
		
		// Apply limit/offset
		if matched_count - 1 < offset do continue
		if count >= limit do continue
		
		if !first do strings.write_string(&b, `,`)
		first = false
		task_write_chain_json(&b, chain)
		count += 1
	}

	strings.write_string(&b, `],"total_count":`)
	strings.write_string(&b, fmt.tprintf("%d", matched_count))
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// GET /task-chains/{chain_id}
handle_get_task_chain :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	chain, found := store_get_chain(chain_id)
	if !found {
		write_response(client, 404, "Not Found", `{"error":"not_found","message":"task chain not found"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"chain":`)
	task_write_chain_json(&b, chain)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// GET /task-chains/{chain_id}/tasks
handle_get_chain_tasks :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	created_after_str := query_param_value(ctx.query, "created_after")
	created_before_str := query_param_value(ctx.query, "created_before")
	updated_after_str := query_param_value(ctx.query, "updated_after")
	updated_before_str := query_param_value(ctx.query, "updated_before")

	created_after := i64(0)
	created_before := i64(0)
	updated_after := i64(0)
	updated_before := i64(0)

	if created_after_str != "" {
		if val, parse_ok := strconv.parse_i64(created_after_str); parse_ok do created_after = val
	}
	if created_before_str != "" {
		if val, parse_ok := strconv.parse_i64(created_before_str); parse_ok do created_before = val
	}
	if updated_after_str != "" {
		if val, parse_ok := strconv.parse_i64(updated_after_str); parse_ok do updated_after = val
	}
	if updated_before_str != "" {
		if val, parse_ok := strconv.parse_i64(updated_before_str); parse_ok do updated_before = val
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"chain_id":"`)
	json_write_string(&b, chain_id)
	strings.write_string(&b, `","tasks":[`)
	first := true
	for state in store_tasks_in_chain(chain_id) {
		// Apply filters
		if created_after > 0 && state.created_at_unix_ms < created_after do continue
		if created_before > 0 && state.created_at_unix_ms > created_before do continue
		if updated_after > 0 && state.updated_at_unix_ms < updated_after do continue
		if updated_before > 0 && state.updated_at_unix_ms > updated_before do continue

		if !first do strings.write_string(&b, `,`)
		first = false
		task_write_state_json(&b, state)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// GET /tasks/{task_id}
handle_get_task :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	if state, ok := store_get_task(task_id); ok {
		b := strings.builder_make()
		strings.write_string(&b, `{"task":`)
		task_write_state_json(&b, state)
		strings.write_string(&b, `}`)
		write_response(client, 200, "OK", strings.to_string(b))
		return
	}
	write_response(client, 404, "Not Found", `{"error":"not_found","message":"task not found"}`)
}

// GET /tasks/{task_id}/comments
handle_get_task_comments :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	unresolved_str := query_param_value(ctx.query, "unresolved")
	unresolved_only := unresolved_str == "true"

	b := strings.builder_make()
	strings.write_string(&b, `{"comments":[`)
	first := true
	for i in 0..<task_comment_count {
		c := task_comments[i]
		if c.task_id != task_id do continue
		if unresolved_only && c.resolved do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, `{"comment_id":"`);              json_write_string(&b, c.comment_id)
		strings.write_string(&b, `","body":"`);                   json_write_string(&b, c.body)
		strings.write_string(&b, `","author_agent_instance_id":"`); json_write_string(&b, c.author_agent_instance_id)
		strings.write_string(&b, `","resolved":`);                strings.write_string(&b, "true" if c.resolved else "false")
		strings.write_string(&b, `,"created_unix_ms":`);          strings.write_string(&b, fmt.tprintf("%d", c.created_unix_ms))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// GET /tasks
handle_get_tasks :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	chain_id := query_param_value(ctx.query, "chain_id")
	created_after_str := query_param_value(ctx.query, "created_after")
	created_before_str := query_param_value(ctx.query, "created_before")
	updated_after_str := query_param_value(ctx.query, "updated_after")
	updated_before_str := query_param_value(ctx.query, "updated_before")
	limit_str := query_param_value(ctx.query, "limit")
	offset_str := query_param_value(ctx.query, "offset")

	created_after := i64(0)
	created_before := i64(0)
	updated_after := i64(0)
	updated_before := i64(0)
	limit := 50
	offset := 0

	if created_after_str != "" {
		if val, parse_ok := strconv.parse_i64(created_after_str); parse_ok do created_after = val
	}
	if created_before_str != "" {
		if val, parse_ok := strconv.parse_i64(created_before_str); parse_ok do created_before = val
	}
	if updated_after_str != "" {
		if val, parse_ok := strconv.parse_i64(updated_after_str); parse_ok do updated_after = val
	}
	if updated_before_str != "" {
		if val, parse_ok := strconv.parse_i64(updated_before_str); parse_ok do updated_before = val
	}
	if limit_str != "" {
		if val, parse_ok := strconv.parse_int(limit_str); parse_ok do limit = int(val)
	}
	if offset_str != "" {
		if val, parse_ok := strconv.parse_int(offset_str); parse_ok do offset = int(val)
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"tasks":[`)
	
	first := true
	count := 0
	matched_count := 0
	
	for state in store_all_tasks() {
		if chain_id != "" && state.chain_id != chain_id do continue
		
		// Apply filters
		if created_after > 0 && state.created_at_unix_ms < created_after do continue
		if created_before > 0 && state.created_at_unix_ms > created_before do continue
		if updated_after > 0 && state.updated_at_unix_ms < updated_after do continue
		if updated_before > 0 && state.updated_at_unix_ms > updated_before do continue
		
		matched_count += 1
		
		// Apply limit/offset
		if matched_count - 1 < offset do continue
		if count >= limit do continue
		
		if !first do strings.write_string(&b, `,`)
		first = false
		task_write_state_json(&b, state)
		count += 1
	}
	
	strings.write_string(&b, `],"total_count":`)
	strings.write_string(&b, fmt.tprintf("%d", matched_count))
	strings.write_string(&b, `}`)
	
	write_response(client, 200, "OK", strings.to_string(b))
}

