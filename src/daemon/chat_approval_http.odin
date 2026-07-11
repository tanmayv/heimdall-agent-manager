package main

import "core:net"
import "core:strings"

handle_chat_approvals_pending :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	user_id, ok := rest_authorize(client, ctx)
	if !ok do return
	// Only user tokens can list pending approvals for a user.
	if registry_agent_instance_for_token(ctx.token) != "" {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"agent tokens cannot list user approvals"}`)
		return
	}
	write_response(client, 200, "OK", chat_approval_list_pending_json(user_id))
}

handle_chat_approvals_answer :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return
	is_user := registry_agent_instance_for_token(ctx.token) == ""
	if !is_user {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"only user tokens can answer approvals"}`)
		return
	}
	approval_id := extract_json_string(body, "approval_id", "")
	reply := extract_json_string(body, "reply", "")
	if approval_id == "" || strings.trim_space(reply) == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"answer requires approval_id and reply"}`)
		return
	}
	rec, found := chat_approval_db_get(approval_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"approval not found"}`)
		return
	}
	if rec.user_id != author {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"approval belongs to another user"}`)
		return
	}
	if rec.state != "open" {
		write_response(client, 409, "Conflict", `{"ok":false,"message":"approval is no longer open"}`)
		return
	}
	if rec.expires_at_unix_ms <= router_now_unix_ms() {
		_ = chat_approval_service_terminal(approval_id, "expired", "", "system-sweeper", "ttl_reached", "")
		write_response(client, 409, "Conflict", `{"ok":false,"message":"approval expired"}`)
		return
	}
	if !rec.free_form {
		if !strings.contains(rec.options_json, strings.trim_space(reply)) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"reply does not match any suggested reply"}`)
			return
		}
	}
	// Send the reply as a normal user->agent chat message on the same chain so
	// agents don't need any new receive channel. This must happen before the
	// terminal transition so the message_id is known if we later want to record
	// it as answered_reply metadata.
	message_id, msg_ok := chat_store_append_message_with_chain(rec.user_id, rec.agent_instance_id, "user_to_agent", reply, false, rec.chain_id)
	if !msg_ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"append reply message failed"}`)
		return
	}
	chat_event_fanout(rec.user_id, rec.agent_instance_id, message_id, "user_to_agent", rec.chain_id)
	_ = agent_chat_notify_user_message(rec.agent_instance_id, rec.user_id, message_id)
	result := chat_approval_service_terminal(approval_id, "answered", reply, author, "", "")
	write_response(client, result.status_code, "OK" if result.ok else "Conflict", result.message)
}

handle_chat_approvals_dismiss :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return
	is_user := registry_agent_instance_for_token(ctx.token) == ""
	if !is_user {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"only user tokens can dismiss approvals"}`)
		return
	}
	approval_id := extract_json_string(body, "approval_id", "")
	reason := extract_json_string(body, "reason", "user_dismissed")
	notify := extract_json_bool(body, "notify", false)
	if approval_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"dismiss requires approval_id"}`)
		return
	}
	rec, found := chat_approval_db_get(approval_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"approval not found"}`)
		return
	}
	if rec.user_id != author {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"approval belongs to another user"}`)
		return
	}
	result := chat_approval_service_terminal(approval_id, "dismissed", "", author, reason, "")
	if result.ok && notify {
		note := "User dismissed your approval request."
		if reason != "" && reason != "user_dismissed" {
			note = strings.concatenate({note, " reason=", reason})
		}
		message_id, msg_ok := chat_store_append_message_with_chain(rec.user_id, rec.agent_instance_id, "user_to_agent", note, false, rec.chain_id)
		if msg_ok {
			chat_event_fanout(rec.user_id, rec.agent_instance_id, message_id, "user_to_agent", rec.chain_id)
			_ = agent_chat_notify_user_message(rec.agent_instance_id, rec.user_id, message_id)
		}
	}
	write_response(client, result.status_code, "OK" if result.ok else "Conflict", result.message)
}

handle_chat_approvals_cancel :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := rest_authorize(client, ctx)
	if !ok do return
	sending_agent := registry_agent_instance_for_token(ctx.token)
	if sending_agent == "" {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"only the sending agent can cancel approvals"}`)
		return
	}
	approval_id := extract_json_string(body, "approval_id", "")
	reason := extract_json_string(body, "reason", "agent_cancelled")
	if approval_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"cancel requires approval_id"}`)
		return
	}
	rec, found := chat_approval_db_get(approval_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"approval not found"}`)
		return
	}
	if rec.agent_instance_id != sending_agent {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"approval belongs to another agent"}`)
		return
	}
	result := chat_approval_service_terminal(approval_id, "cancelled", "", sending_agent, reason, "")
	write_response(client, result.status_code, "OK" if result.ok else "Conflict", result.message)
}
