package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:strconv"

// GET /chats
handle_get_chats :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return

	// Only users can list their chats (active agent sessions)
	is_user := user_client_id_for_token(ctx.token) != ""
	if !is_user {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"only users can list chats"}`)
		return
	}

	write_response(client, 200, "OK", chat_list_json(author))
}

// GET /chats/{agent_id}/messages
handle_get_chat_messages :: proc(client: net.TCP_Socket, agent_id: string, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return

	// Determine user_id and agent_instance_id
	user_id := ""
	agent_instance_id := ""

	is_user := user_client_id_for_token(ctx.token) != ""
	if is_user {
		user_id = author
		agent_instance_id = agent_id
	} else {
		agent_instance_id = author
		user_id = query_param_value(ctx.query, "user_id")
		if user_id == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"missing user_id query parameter"}`)
			return
		}
	}

	// Parse limit and cursor
	limit_str := query_param_value(ctx.query, "limit")
	cursor_str := query_param_value(ctx.query, "cursor")

	limit := 50
	cursor := i64(0)

	if limit_str != "" {
		if val, parse_ok := strconv.parse_int(limit_str); parse_ok do limit = int(val)
	}
	if cursor_str != "" {
		if val, parse_ok := strconv.parse_i64(cursor_str); parse_ok do cursor = val
	}

	messages := message_db_fetch_cursor_paginated(user_id, agent_instance_id, limit, cursor)
	defer free_chat_messages(messages)

	// Calculate next_cursor
	next_cursor := i64(0)
	// If we returned a full page, set the cursor to the timestamp of the oldest message in the page
	if len(messages) == limit && len(messages) > 0 {
		next_cursor = messages[len(messages) - 1].created_unix_ms
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"user_id":"`)
	json_write_string(&b, user_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	json_write_string(&b, agent_instance_id)
	strings.write_string(&b, `","messages":[`)

	first := true
	for msg in messages {
		if !first do strings.write_string(&b, `,`)
		first = false
		chat_write_message_json(&b, msg)
	}
	strings.write_string(&b, `]`)
	
	if next_cursor > 0 {
		strings.write_string(&b, `,"next_cursor":`)
		strings.write_string(&b, fmt.tprintf("%d", next_cursor))
	}
	strings.write_string(&b, `}`)

	write_response(client, 200, "OK", strings.to_string(b))
}

free_chat_messages :: proc(messages: [dynamic]Chat_Message) {
	for msg in messages {
		delete(msg.message_id)
		delete(msg.user_id)
		delete(msg.agent_instance_id)
		delete(msg.direction)
		delete(msg.body)
		delete(msg.delivery_error)
	}
	delete(messages)
}
