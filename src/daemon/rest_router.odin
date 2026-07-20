package main

import "core:strings"
import "core:fmt"
import "core:net"
import contracts "odin_test:contracts"

Route_Context :: struct {
	method:   string,         // "GET", "POST", "PATCH", "DELETE", etc.
	path:     string,         // "/tasks/t-123/comments"
	query:    string,         // "limit=20&cursor=1782113855233"
	segments: []string,       // ["tasks", "t-123", "comments"]
	token:    string,         // Parsed Bearer/Query/Body token
	bridge_source_daemon_id: string, // Set only for authenticated local bridge deliveries.
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
		raw_segments := strings.split(clean_path, "/")
		ctx.segments = make([]string, len(raw_segments))
		for seg, idx in raw_segments {
			ctx.segments[idx] = url_decode(seg)
		}
		delete(raw_segments)
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

	if strings.trim_space(server_config.daemon.bridge_token) != "" && ctx.token == server_config.daemon.bridge_token {
		source_daemon := strings.trim_space(extract_header(request, contracts.BRIDGE_SOURCE_DAEMON_HEADER))
		if source_daemon != "" {
			ctx.bridge_source_daemon_id = strings.clone(source_daemon)
		}
	}

	return ctx
}

route_context_free :: proc(ctx: ^Route_Context) {
	delete(ctx.method)
	delete(ctx.path)
	delete(ctx.query)
	delete(ctx.token)
	delete(ctx.bridge_source_daemon_id)
	for seg in ctx.segments {
		delete(seg)
	}
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

rest_authorize_user :: proc(client: net.TCP_Socket, ctx: ^Route_Context) -> (string, bool) {
	if ctx.token == "" {
		write_response(client, 401, "Unauthorized", `{"error":"unauthorized","message":"missing authorization token"}`)
		return "", false
	}
	user_id := user_client_id_for_token(ctx.token)
	if user_id == "" {
		write_response(client, 401, "Unauthorized", `{"error":"unauthorized","message":"user client token required"}`)
		return "", false
	}
	return user_id, true
}

// Handle REST routes. Returns true if handled, false if it should fall back to old routes
handle_rest_route :: proc(client: net.TCP_Socket, request: string, ctx: ^Route_Context) -> bool {
	if len(ctx.segments) == 0 do return false

	// GET /agents/defaults
	if len(ctx.segments) == 2 && ctx.segments[0] == "agents" && ctx.segments[1] == "defaults" && ctx.method == "GET" {
		handle_agents_defaults_get(client, ctx)
		return true
	}

	// POST /agents/defaults
	if len(ctx.segments) == 2 && ctx.segments[0] == "agents" && ctx.segments[1] == "defaults" && ctx.method == "POST" {
		handle_agents_defaults_set(client, request_body(request), ctx)
		return true
	}

	// GET /preferences
	if len(ctx.segments) == 1 && ctx.segments[0] == "preferences" && ctx.method == "GET" {
		handle_get_preferences(client, ctx)
		return true
	}

	// POST /preferences
	if len(ctx.segments) == 1 && ctx.segments[0] == "preferences" && ctx.method == "POST" {
		handle_post_preference(client, request_body(request), ctx)
		return true
	}

	// DELETE /preferences/{key}
	if len(ctx.segments) == 2 && ctx.segments[0] == "preferences" && ctx.method == "DELETE" {
		key := ctx.segments[1]
		handle_delete_preference(client, key, ctx)
		return true
	}

	// POST /artifacts/create
	if len(ctx.segments) == 2 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "create" && ctx.method == "POST" {
		handle_post_artifact_create(client, request_body(request), ctx)
		return true
	}

	// GET /artifacts
	if len(ctx.segments) == 1 && ctx.segments[0] == "artifacts" && ctx.method == "GET" {
		handle_get_artifacts(client, ctx)
		return true
	}

	// GET /artifacts/{artifact_id}/content
	if len(ctx.segments) == 3 && ctx.segments[0] == "artifacts" && ctx.segments[2] == "content" && ctx.method == "GET" {
		artifact_id := ctx.segments[1]
		handle_get_artifact_content(client, artifact_id, ctx)
		return true
	}

	// GET /artifacts/{artifact_id}/versions
	if len(ctx.segments) == 3 && ctx.segments[0] == "artifacts" && ctx.segments[2] == "versions" && ctx.method == "GET" {
		artifact_id := ctx.segments[1]
		handle_get_artifact_versions(client, artifact_id, ctx)
		return true
	}

	// GET /artifacts/{artifact_id}/annotations
	if len(ctx.segments) == 3 && ctx.segments[0] == "artifacts" && ctx.segments[2] == "annotations" && ctx.method == "GET" {
		artifact_id := ctx.segments[1]
		handle_get_artifact_annotations(client, artifact_id, ctx)
		return true
	}

	// POST /artifacts/update
	if len(ctx.segments) == 2 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "update" && ctx.method == "POST" {
		handle_post_artifact_update(client, request_body(request), ctx)
		return true
	}

	// POST /artifacts/delete
	if len(ctx.segments) == 2 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "delete" && ctx.method == "POST" {
		handle_post_artifact_delete(client, request_body(request), ctx)
		return true
	}

	// POST /artifacts/rollback
	if len(ctx.segments) == 2 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "rollback" && ctx.method == "POST" {
		handle_post_artifact_rollback(client, request_body(request), ctx)
		return true
	}

	// POST /artifacts/annotations/create
	if len(ctx.segments) == 3 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "annotations" && ctx.segments[2] == "create" && ctx.method == "POST" {
		handle_post_artifact_annotation_create(client, request_body(request), ctx)
		return true
	}

	// POST /artifacts/annotations/update
	if len(ctx.segments) == 3 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "annotations" && ctx.segments[2] == "update" && ctx.method == "POST" {
		handle_post_artifact_annotation_update(client, request_body(request), ctx)
		return true
	}

	// POST /artifacts/annotations/delete
	if len(ctx.segments) == 3 && ctx.segments[0] == "artifacts" && ctx.segments[1] == "annotations" && ctx.segments[2] == "delete" && ctx.method == "POST" {
		handle_post_artifact_annotation_delete(client, request_body(request), ctx)
		return true
	}

	// GET /artifacts/{artifact_id}
	if len(ctx.segments) == 2 && ctx.segments[0] == "artifacts" && ctx.method == "GET" {
		artifact_id := ctx.segments[1]
		handle_get_artifact(client, artifact_id, ctx)
		return true
	}

	// GET /chats
	if len(ctx.segments) == 1 && ctx.segments[0] == "chats" && ctx.method == "GET" {
		handle_get_chats(client, ctx)
		return true
	}

	// GET /chats/messages/{message_id}
	if len(ctx.segments) == 3 && ctx.segments[0] == "chats" && ctx.segments[1] == "messages" && ctx.method == "GET" {
		message_id := ctx.segments[2]
		handle_get_chat_message(client, message_id, ctx)
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

	// GET /task-chains/{chain_id}
	if len(ctx.segments) == 2 && ctx.segments[0] == "task-chains" && ctx.method == "GET" {
		chain_id := ctx.segments[1]
		handle_get_task_chain(client, chain_id, ctx)
		return true
	}

	// POST /task-chains/audit
	if len(ctx.segments) == 2 && ctx.segments[0] == "task-chains" && ctx.segments[1] == "audit" && ctx.method == "POST" {
		handle_post_task_chain_audit(client, request_body(request), ctx)
		return true
	}

	// GET /task-chains/{chain_id}/tasks
	if len(ctx.segments) == 3 && ctx.segments[0] == "task-chains" && ctx.segments[2] == "tasks" && ctx.method == "GET" {
		chain_id := ctx.segments[1]
		handle_get_chain_tasks(client, chain_id, ctx)
		return true
	}

	// GET /tasks
	if len(ctx.segments) == 1 && ctx.segments[0] == "tasks" && ctx.method == "GET" {
		handle_get_tasks(client, ctx)
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

	// GET /federation/agents?peer_token=...
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "agents" && ctx.method == "GET" {
		handle_get_federation_agents(client, ctx)
		return true
	}

	// GET /federation/peers
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "peers" && ctx.method == "GET" {
		handle_get_federation_peers(client, ctx)
		return true
	}

	// POST /federation/proxies/bind
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "proxies" && ctx.segments[2] == "bind" && ctx.method == "POST" {
		handle_post_federation_proxy_bind(client, request_body(request), ctx)
		return true
	}

	// POST /federation/inbox
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "inbox" && ctx.method == "POST" {
		handle_post_federation_inbox(client, request_body(request), ctx)
		return true
	}

	// POST /federation/callback
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "callback" && ctx.method == "POST" {
		handle_post_federation_callback(client, request_body(request), ctx)
		return true
	}

	// POST /federation/start (owner starts the real agent for a peer's remote_proxy)
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "start" && ctx.method == "POST" {
		handle_post_federation_start(client, request_body(request), ctx)
		return true
	}

	// POST /federation/stop (owner stops the real agent for a peer's remote_proxy)
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "stop" && ctx.method == "POST" {
		handle_post_federation_stop(client, request_body(request), ctx)
		return true
	}

	// POST /federation/reachability (local bridge pushes secret-free WS reachability changes)
	if len(ctx.segments) == 2 && ctx.segments[0] == "federation" && ctx.segments[1] == "reachability" && ctx.method == "POST" {
		handle_post_federation_reachability(client, request_body(request), ctx)
		return true
	}

	// POST /federation/peers/link
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "peers" && ctx.segments[2] == "link" && ctx.method == "POST" {
		handle_post_federation_peer_link(client, request_body(request), ctx)
		return true
	}

	// POST /federation/peers/reconnect
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "peers" && ctx.segments[2] == "reconnect" && ctx.method == "POST" {
		handle_post_federation_peer_reconnect(client, request_body(request), ctx)
		return true
	}

	// POST /federation/peers/remove
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "peers" && ctx.segments[2] == "remove" && ctx.method == "POST" {
		handle_post_federation_peer_remove(client, request_body(request), ctx)
		return true
	}

	// GET /federation/peers/{peer_id}/agents
	if len(ctx.segments) == 4 && ctx.segments[0] == "federation" && ctx.segments[1] == "peers" && ctx.segments[3] == "agents" && ctx.method == "GET" {
		handle_get_federation_peer_agents(client, ctx.segments[2], ctx)
		return true
	}

	// GET /federation/messages/{message_id}
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "messages" && ctx.method == "GET" {
		handle_get_federation_message(client, ctx.segments[2], ctx)
		return true
	}

	// GET /federation/artifacts/{artifact_id}
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "artifacts" && ctx.method == "GET" {
		handle_get_federation_artifact_content(client, ctx.segments[2], ctx)
		return true
	}

	// GET /federation/tasks/{task_id}
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "tasks" && ctx.method == "GET" {
		handle_get_federation_task(client, ctx.segments[2], ctx)
		return true
	}

	// GET /federation/tasks/{task_id}/comments
	if len(ctx.segments) == 4 && ctx.segments[0] == "federation" && ctx.segments[1] == "tasks" && ctx.segments[3] == "comments" && ctx.method == "GET" {
		handle_get_federation_task_comments(client, ctx.segments[2], ctx)
		return true
	}

	// GET /federation/task-chains/{chain_id}
	if len(ctx.segments) == 3 && ctx.segments[0] == "federation" && ctx.segments[1] == "task-chains" && ctx.method == "GET" {
		handle_get_federation_task_chain(client, ctx.segments[2], ctx)
		return true
	}

	// GET /federation/task-chains/{chain_id}/tasks
	if len(ctx.segments) == 4 && ctx.segments[0] == "federation" && ctx.segments[1] == "task-chains" && ctx.segments[3] == "tasks" && ctx.method == "GET" {
		handle_get_federation_task_chain_tasks(client, ctx.segments[2], ctx)
		return true
	}

	// GET /chat-approvals/pending
	if len(ctx.segments) == 2 && ctx.segments[0] == "chat-approvals" && ctx.segments[1] == "pending" && ctx.method == "GET" {
		handle_chat_approvals_pending(client, ctx)
		return true
	}
	// POST /chat-approvals/answer
	if len(ctx.segments) == 2 && ctx.segments[0] == "chat-approvals" && ctx.segments[1] == "answer" && ctx.method == "POST" {
		handle_chat_approvals_answer(client, request_body(request), ctx)
		return true
	}
	// POST /chat-approvals/dismiss
	if len(ctx.segments) == 2 && ctx.segments[0] == "chat-approvals" && ctx.segments[1] == "dismiss" && ctx.method == "POST" {
		handle_chat_approvals_dismiss(client, request_body(request), ctx)
		return true
	}
	// POST /chat-approvals/cancel
	if len(ctx.segments) == 2 && ctx.segments[0] == "chat-approvals" && ctx.segments[1] == "cancel" && ctx.method == "POST" {
		handle_chat_approvals_cancel(client, request_body(request), ctx)
		return true
	}


	return false
}

url_decode :: proc(s: string) -> string {
	builder := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			hex := s[i+1 : i+3]
			val, ok := parse_hex_byte(hex)
			if ok {
				strings.write_byte(&builder, val)
				i += 3
				continue
			}
		}
		strings.write_byte(&builder, s[i])
		i += 1
	}
	return strings.to_string(builder)
}

parse_hex_byte :: proc(hex: string) -> (val: byte, ok: bool) {
	if len(hex) != 2 do return 0, false
	
	h1 := hex_char_to_val(hex[0]) or_return
	h2 := hex_char_to_val(hex[1]) or_return
	
	return byte((h1 << 4) | h2), true
}

hex_char_to_val :: proc(ch: byte) -> (int, bool) {
	switch ch {
	case '0'..='9': return int(ch - '0'), true
	case 'a'..='f': return int(ch - 'a' + 10), true
	case 'A'..='F': return int(ch - 'A' + 10), true
	}
	return 0, false
}
