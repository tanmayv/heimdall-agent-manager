package main

import "core:strings"
import "core:fmt"
import "core:net"

Route_Context :: struct {
	method:   string,         // "GET", "POST", "PATCH", "DELETE", etc.
	path:     string,         // "/tasks/t-123/comments"
	query:    string,         // "limit=20&cursor=1782113855233"
	segments: []string,       // ["tasks", "t-123", "comments"]
	token:    string,         // Parsed Bearer/Query/Body token
}

parse_route_context :: proc(request: string) -> Route_Context {
	ctx: Route_Context

	// Get first line of HTTP request
	first_line_end := strings.index(request, "\r\n")
	if first_line_end < 0 do return ctx
	first_line := request[:first_line_end]

	// Split by space
	parts := strings.split(first_line, " ")
	if len(parts) < 2 do return ctx

	ctx.method = strings.clone(parts[0])
	full_path := parts[1]

	// Separate path and query
	q_mark := strings.index_byte(full_path, '?')
	if q_mark >= 0 {
		ctx.path = strings.clone(full_path[:q_mark])
		ctx.query = strings.clone(full_path[q_mark + 1:])
	} else {
		ctx.path = strings.clone(full_path)
		ctx.query = ""
	}

	// Split path into segments
	clean_path := ctx.path
	if strings.has_prefix(clean_path, "/") do clean_path = clean_path[1:]
	if strings.has_suffix(clean_path, "/") do clean_path = clean_path[:len(clean_path) - 1]

	if clean_path != "" {
		ctx.segments = strings.split(clean_path, "/")
	} else {
		ctx.segments = make([]string, 0)
	}
	// Clean up split parts slice
	delete(parts)

	// --- Parse and store authentication token ---
	// 1. Try Authorization header
	auth_header := extract_header(request, "Authorization")
	if auth_header != "" {
		if strings.has_prefix(auth_header, "Bearer ") {
			ctx.token = strings.clone(auth_header[7:])
		} else {
			ctx.token = strings.clone(auth_header)
		}
	} else {
		// 2. Try Query parameter
		t := query_param_value(ctx.query, "token")
		if t == "" do t = query_param_value(ctx.query, "agent_token")
		if t != "" {
			ctx.token = t // already cloned by query_param_value
		} else {
			// 3. Try Body
			body := request_body(request)
			if body != "" {
				body_token := extract_json_string(body, "agent_token", "")
				if body_token != "" {
					ctx.token = strings.clone(body_token)
				}
			}
		}
	}

	return ctx
}

route_context_free :: proc(ctx: ^Route_Context) {
	delete(ctx.method)
	delete(ctx.path)
	delete(ctx.query)
	delete(ctx.token)
	delete(ctx.segments)
}

// Helper to get a query parameter value
query_param_value :: proc(query, name: string) -> string {
	if query == "" do return ""
	pattern := fmt.tprintf("%s=", name)
	idx := strings.index(query, pattern)
	if idx < 0 do return ""

	start := idx + len(pattern)
	end := strings.index_byte(query[start:], '&')
	if end < 0 do return strings.clone(query[start:])
	return strings.clone(query[start:start + end])
}

// Authorize agent/user from the request context
rest_authorize :: proc(client: net.TCP_Socket, ctx: ^Route_Context) -> (string, bool) {
	if ctx.token == "" {
		write_response(client, 401, "Unauthorized", `{"error":"unauthorized","message":"missing authorization token"}`)
		return "", false
	}
	author := registry_agent_instance_for_token(ctx.token)
	if author == "" {
		author = user_client_id_for_token(ctx.token)
	}
	if author == "" {
		write_response(client, 401, "Unauthorized", `{"error":"unauthorized","message":"invalid authorization token"}`)
		return "", false
	}
	return author, true
}

// Handle REST routes. Returns true if handled, false if it should fall back to old routes
handle_rest_route :: proc(client: net.TCP_Socket, request: string, ctx: ^Route_Context) -> bool {
	if len(ctx.segments) == 0 do return false

	// GET /chats
	if len(ctx.segments) == 1 && ctx.segments[0] == "chats" && ctx.method == "GET" {
		handle_get_chats(client, ctx)
		return true
	}

	// GET /chats/{agent_id}/messages
	if len(ctx.segments) == 3 && ctx.segments[0] == "chats" && ctx.segments[2] == "messages" && ctx.method == "GET" {
		agent_id := ctx.segments[1]
		handle_get_chat_messages(client, agent_id, ctx)
		return true
	}

	// GET /task-chains
	if len(ctx.segments) == 1 && ctx.segments[0] == "task-chains" && ctx.method == "GET" {
		handle_get_task_chains(client, ctx)
		return true
	}

	// GET /task-chains/{chain_id}/tasks
	if len(ctx.segments) == 3 && ctx.segments[0] == "task-chains" && ctx.segments[2] == "tasks" && ctx.method == "GET" {
		chain_id := ctx.segments[1]
		handle_get_chain_tasks(client, chain_id, ctx)
		return true
	}

	// GET /tasks/{task_id}
	if len(ctx.segments) == 2 && ctx.segments[0] == "tasks" && ctx.method == "GET" {
		task_id := ctx.segments[1]
		handle_get_task(client, task_id, ctx)
		return true
	}

	// GET /tasks/{task_id}/comments
	if len(ctx.segments) == 3 && ctx.segments[0] == "tasks" && ctx.segments[2] == "comments" && ctx.method == "GET" {
		task_id := ctx.segments[1]
		handle_get_task_comments(client, task_id, ctx)
		return true
	}

	return false
}
