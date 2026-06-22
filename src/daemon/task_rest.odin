package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:strconv"

// GET /task-chains
handle_get_task_chains :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return

	limit_str := query_param_value(ctx.query, "limit")
	offset_str := query_param_value(ctx.query, "offset")
	
	limit := 20
	offset := 0

	if limit_str != "" {
		if val, parse_ok := strconv.parse_int(limit_str); parse_ok do limit = int(val)
	}
	if offset_str != "" {
		if val, parse_ok := strconv.parse_int(offset_str); parse_ok do offset = int(val)
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"chains":[`)
	count := 0
	start := min(offset, task_chain_count)
	end := min(task_chain_count, start + limit)
	for i in start..<end {
		if count > 0 do strings.write_string(&b, `,`)
		task_write_chain_json(&b, task_chains[i])
		count += 1
	}
	strings.write_string(&b, `],"total_count":`)
	strings.write_string(&b, fmt.tprintf("%d", task_chain_count))
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// GET /task-chains/{chain_id}/tasks
handle_get_chain_tasks :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	b := strings.builder_make()
	strings.write_string(&b, `{"chain_id":"`)
	json_write_string(&b, chain_id)
	strings.write_string(&b, `","tasks":[`)
	first := true
	for i in 0..<task_state_count {
		if task_states[i].chain_id != chain_id do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		task_write_state_json(&b, task_states[i])
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// GET /tasks/{task_id}
handle_get_task :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return

	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id {
			b := strings.builder_make()
			strings.write_string(&b, `{"task":`)
			task_write_state_json(&b, task_states[i])
			strings.write_string(&b, `}`)
			write_response(client, 200, "OK", strings.to_string(b))
			return
		}
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
