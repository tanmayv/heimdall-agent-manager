package main

import "core:fmt"
import contracts "odin_test:contracts"
import mp "odin_test:lib/message_provider"

message_service_execute :: proc(command: Command) -> Service_Result {
	switch command.kind {
	case .Send_Message:
		return message_service_send_message(command)
	case .Fetch_Messages:
		return message_service_fetch_messages(command)
	case .Mark_Read:
		return message_queue_submit_command(command)
	}
	return Service_Result{ok = false, message = "unsupported command", status_code = 400, status_text = "Bad Request"}
}

message_service_send_message :: proc(command: Command) -> Service_Result {
	request := command.send_message
	from_agent_instance_id := string(request.from_agent_instance_id)
	target_agent_instance_id := string(request.target_agent_instance_id)
	if target_agent_instance_id == "" {
		fmt.println("send_message failure missing_target from", from_agent_instance_id)
		return Service_Result{ok = false, message = `{"ok":false,"message":"missing target_agent_instance_id"}`, status_code = 400, status_text = "Bad Request"}
	}
	if !valid_agent_instance_id(target_agent_instance_id) {
		fmt.println("send_message failure invalid_target", target_agent_instance_id, "from", from_agent_instance_id)
		return Service_Result{ok = false, message = `{"ok":false,"message":"invalid target_agent_instance_id"}`, status_code = 400, status_text = "Bad Request"}
	}
	if _, _, remote_proxy := agent_remote_proxy_lookup(target_agent_instance_id); remote_proxy {
		return federation_remote_send_message(from_agent_instance_id, target_agent_instance_id, request.payload)
	}
	if !registry_agent_exists(target_agent_instance_id) {
		if routed := federation_remote_route_reply(from_agent_instance_id, target_agent_instance_id, request.payload); routed.ok {
			return routed
		}
		routed := message_bus_emit(Message_Event {
			kind = .Remote_Route_Required,
			from_agent_instance_id = request.from_agent_instance_id,
			target_agent_instance_id = request.target_agent_instance_id,
			body = request.payload,
		})
		if routed {
			return Service_Result{ok = true, status_code = 202, status_text = "Accepted", send_response = contracts.Send_Message_Response{ok = true, message = "remote route queued"}}
		}
		fmt.println("send_message failure unknown_target", target_agent_instance_id, "from", from_agent_instance_id)
		return Service_Result{ok = false, message = `{"ok":false,"message":"unknown target agent instance"}`, status_code = 404, status_text = "Not Found"}
	}

	return message_queue_submit_command(command)
}

message_service_fetch_messages :: proc(command: Command) -> Service_Result {
	return message_queue_submit_command(command)
}

message_service_process_serialized_command :: proc(command: Command) -> Service_Result {
	switch command.kind {
	case .Send_Message:
		return message_service_process_send(command.send_message)
	case .Fetch_Messages:
		return message_service_process_fetch(command.fetch_messages)
	case .Mark_Read:
		return message_service_process_mark_read(command.mark_read)
	}
	return Service_Result{ok = false, message = `{"ok":false,"message":"unsupported command"}`, status_code = 400, status_text = "Bad Request"}
}

message_service_process_send :: proc(command: Send_Message_Command) -> Service_Result {
	conversation_id := contracts.Conversation_ID(registry_conversation_id(string(command.target_agent_instance_id)))
	ctx := Send_Message_Context {
		from_agent_instance_id = command.from_agent_instance_id,
		target_agent_instance_id = command.target_agent_instance_id,
		conversation_id = conversation_id,
		body = command.payload,
	}
	run_pre_send_hooks(&ctx)
	if ctx.rejected {
		fmt.println("send_message failure rejected_by_hook", ctx.rejection_reason, "from", string(ctx.from_agent_instance_id), "target", string(ctx.target_agent_instance_id), "conversation", string(ctx.conversation_id))
		return Service_Result{ok = false, message = `{"ok":false,"message":"message rejected"}`, status_code = 400, status_text = "Bad Request"}
	}

	message_bus_emit(Message_Event {
		kind = .New_Message_Requested,
		conversation_id = ctx.conversation_id,
		from_agent_instance_id = ctx.from_agent_instance_id,
		target_agent_instance_id = ctx.target_agent_instance_id,
		body = ctx.body,
	})

	request := contracts.Send_Message_Request {
		from_agent_instance_id = ctx.from_agent_instance_id,
		target_agent_instance_id = ctx.target_agent_instance_id,
		conversation_id = ctx.conversation_id,
		body = ctx.body,
	}

	response := mp.send_message(&message_provider, request)
	if !response.ok {
		fmt.println("send_message failure provider", response.message, "from", string(request.from_agent_instance_id), "target", string(request.target_agent_instance_id), "conversation", string(request.conversation_id))
		message_bus_emit(Message_Event {
			kind = .Message_Send_Failed,
			conversation_id = request.conversation_id,
			from_agent_instance_id = request.from_agent_instance_id,
			target_agent_instance_id = request.target_agent_instance_id,
			body = request.body,
		})
		return Service_Result{ok = false, message = `{"ok":false,"message":"message provider send failed"}`, status_code = 500, status_text = "Internal Server Error", send_response = response}
	}

	message_bus_emit(Message_Event {
		kind = .Message_Stored,
		message_id = response.message_id,
		conversation_id = response.conversation_id,
		from_agent_instance_id = request.from_agent_instance_id,
		target_agent_instance_id = request.target_agent_instance_id,
		created_unix_ms = response.created_unix_ms,
		body = request.body,
	})

	unread := mp.unread_count(&message_provider, contracts.Unread_Count_Request {
		agent_instance_id = request.target_agent_instance_id,
		conversation_id = request.conversation_id,
	})
	pending_count := unread.unread_count
	if pending_count <= 0 do pending_count = 1
	notified := message_bus_emit(Message_Event {
		kind = .Messages_Available,
		message_id = response.message_id,
		conversation_id = response.conversation_id,
		from_agent_instance_id = request.from_agent_instance_id,
		target_agent_instance_id = request.target_agent_instance_id,
		pending_count = pending_count,
		created_unix_ms = response.created_unix_ms,
	})

	status_code := 202
	status_text := "Accepted"
	if notified {
		status_code = 200
		status_text = "OK"
	}
	return Service_Result{ok = true, status_code = status_code, status_text = status_text, send_response = response, pending_count = pending_count, notified = notified}
}

message_service_process_fetch :: proc(command: Fetch_Messages_Command) -> Service_Result {
	conversation_id := command.conversation_id
	if conversation_id == "" {
		conversation_id = contracts.Conversation_ID(registry_conversation_id(string(command.agent_instance_id)))
		if conversation_id == "" do conversation_id = contracts.Conversation_ID(conversation_id_for_instance(string(command.agent_instance_id)))
	}
	request := contracts.Fetch_Messages_Request {
		agent_instance_id = command.agent_instance_id,
		conversation_id = conversation_id,
		limit = command.limit,
		include_read = command.include_read,
	}

	response := mp.fetch_messages(&message_provider, request)
	remote_response := federation_remote_fetch_messages(request)
	if len(remote_response.messages) > 0 {
		merged := make([dynamic]contracts.Message)
		for msg in response.messages do append(&merged, msg)
		for msg in remote_response.messages do append(&merged, msg)
		response.messages = merged[:]
	}
	for i in 0..<len(response.messages) {
		msg := response.messages[i]
		if msg.target_agent_instance_id != request.agent_instance_id do continue
		if request.include_read do continue // include_read may return old reads; avoid duplicate read receipts.

		read_unix_ms := msg.read_unix_ms
		if read_unix_ms == 0 {
			mark_response := mp.mark_read(&message_provider, contracts.Mark_Read_Request {
				agent_instance_id = request.agent_instance_id,
				conversation_id = msg.conversation_id,
				through_message_id = msg.id,
			})
			if !mark_response.ok do continue
			read_unix_ms = mark_response.read_unix_ms
			response.messages[i].read_unix_ms = read_unix_ms
		}

		message_bus_emit(Message_Event {
			kind = .Message_Read,
			message_id = msg.id,
			conversation_id = msg.conversation_id,
			from_agent_instance_id = msg.from_agent_instance_id,
			target_agent_instance_id = msg.target_agent_instance_id,
			read_by_agent_instance_id = request.agent_instance_id,
			read_unix_ms = read_unix_ms,
		})
	}

	return Service_Result{ok = true, status_code = 200, status_text = "OK", fetch_response = response}
}

message_service_process_mark_read :: proc(command: Mark_Read_Command) -> Service_Result {
	if remote_rec, remote_ok := federation_remote_message_get(string(command.message_id)); remote_ok && remote_rec.local_agent_instance_id == string(command.agent_instance_id) {
		read_unix_ms := router_now_unix_ms()
		_ = federation_remote_message_mark_read(remote_rec.record_key, read_unix_ms)
		payload := federation_callback_read_receipt_json(remote_rec.message_id, remote_rec.remote_agent_instance_id, remote_rec.proxy_agent_instance_id, remote_rec.origin_conversation_id, remote_rec.local_agent_instance_id, read_unix_ms)
		idempotency_key := federation_idempotency_key("read", server_daemon_id, remote_rec.message_id)
		_ = federation_delivery_outbox_insert_pending(remote_rec.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
		bridge_accepted := false
		_, dest_daemon_id, peer_status, found := federation_direct_peer_lookup(remote_rec.owner_peer_id, remote_rec.owner_daemon_id)
		if found && peer_status == PEER_STATUS_LINKED {
			bridge_accepted = dest_daemon_id != "" && bridge_send(dest_daemon_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
		}
		// Bridge acceptance is not destination durable delivery; keep outbox pending until delivery_ack.
		_ = federation_delivery_outbox_mark_attempt(remote_rec.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, false)
		return Service_Result{ok = true, message = `{"ok":true,"message":"mark_read applied"}`, status_code = 200, status_text = "OK"}
	}

	fetch_response := mp.fetch_messages(&message_provider, contracts.Fetch_Messages_Request {
		agent_instance_id = command.agent_instance_id,
		conversation_id = command.conversation_id,
		limit = 100,
		include_read = true,
	})

	found := false
	from_agent_instance_id: contracts.Agent_Instance_ID
	target_agent_instance_id: contracts.Agent_Instance_ID
	for msg in fetch_response.messages {
		if msg.id == command.message_id {
			found = true
			from_agent_instance_id = msg.from_agent_instance_id
			target_agent_instance_id = msg.target_agent_instance_id
			break
		}
	}

	mark_response := mp.mark_read(&message_provider, contracts.Mark_Read_Request {
		agent_instance_id = command.agent_instance_id,
		conversation_id = command.conversation_id,
		through_message_id = command.message_id,
	})
	if !mark_response.ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"mark_read failed"}`, status_code = 500, status_text = "Internal Server Error"}
	}

	read_unix_ms := mark_response.read_unix_ms
	if command.read_unix_ms > 0 do read_unix_ms = command.read_unix_ms
	if found {
		message_bus_emit(Message_Event {
			kind = .Message_Read,
			message_id = command.message_id,
			conversation_id = command.conversation_id,
			from_agent_instance_id = from_agent_instance_id,
			target_agent_instance_id = target_agent_instance_id,
			read_by_agent_instance_id = command.agent_instance_id,
			read_unix_ms = read_unix_ms,
		})
	}
	return Service_Result{ok = true, message = `{"ok":true,"message":"mark_read applied"}`, status_code = 200, status_text = "OK"}
}
