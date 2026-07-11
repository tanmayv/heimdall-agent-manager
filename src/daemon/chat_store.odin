package main

import "core:fmt"
import "core:strings"

Chat_Event_Kind :: enum { Message_Appended, Delivered_Marked, Read_Marked, Delivery_Failed }

Chat_Event :: struct {
	event_id: string,
	kind: Chat_Event_Kind,
	message_id: string,
	user_id: string,
	agent_instance_id: string,
	direction: string,
	body: string,
	chain_id: string,
	delivered_unix_ms: i64,
	read_unix_ms: i64,
	delivery_failed_unix_ms: i64,
	delivery_error: string,
	created_unix_ms: i64,
	interrupt: bool,
}

Chat_Message :: struct {
	message_id: string,
	user_id: string,
	agent_instance_id: string,
	direction: string,
	body: string,
	chain_id: string,
	delivered_unix_ms: i64,
	read_unix_ms: i64,
	delivery_failed_unix_ms: i64,
	delivery_error: string,
	created_unix_ms: i64,
	interrupt: bool,
}

chat_store_init :: proc(data_dir: string) {
	if !message_db_init(data_dir) {
		fmt.println("chat_store_init: failed to initialize message database")
	}
	if !chat_approval_db_init() {
		fmt.println("chat_store_init: failed to initialize chat approvals table")
	}
}

chat_store_append_event :: proc(event: Chat_Event) -> bool {
	ev := event
	if ev.event_id == "" do ev.event_id = fmt.tprintf("chatevt_%d", router_now_unix_ms())
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	if ev.message_id == "" && ev.kind == .Message_Appended do ev.message_id = fmt.tprintf("chatmsg_%d", ev.created_unix_ms)

	switch ev.kind {
	case .Message_Appended:
		msg := Chat_Message{
			message_id = ev.message_id,
			user_id = ev.user_id,
			agent_instance_id = ev.agent_instance_id,
			direction = ev.direction,
			body = ev.body,
			chain_id = ev.chain_id,
			delivered_unix_ms = ev.delivered_unix_ms,
			read_unix_ms = ev.read_unix_ms,
			delivery_failed_unix_ms = ev.delivery_failed_unix_ms,
			delivery_error = ev.delivery_error,
			created_unix_ms = ev.created_unix_ms,
			interrupt = ev.interrupt,
		}
		if !message_db_insert(msg) {
			fmt.println("chat_store_append_event: failed to insert message", ev.message_id)
			return false
		}

	case .Read_Marked:
		if !message_db_mark_conversation_read(ev.user_id, ev.agent_instance_id, ev.direction, ev.read_unix_ms) {
			fmt.println("chat_store_append_event: failed to mark conversation read", ev.user_id, ev.agent_instance_id)
			return false
		}

	case .Delivered_Marked:
		if !message_db_update_delivered(ev.message_id, ev.delivered_unix_ms) {
			fmt.println("chat_store_append_event: failed to update delivered status", ev.message_id)
			return false
		}

	case .Delivery_Failed:
		if !message_db_update_delivery_failed(ev.message_id, ev.delivery_failed_unix_ms, ev.delivery_error) {
			fmt.println("chat_store_append_event: failed to update delivery failed status", ev.message_id)
			return false
		}
	}

	return true
}

chat_unread_count :: proc(user_id, agent_instance_id: string) -> int {
	return message_db_count_unread(user_id, agent_instance_id)
}

chat_has_unread_direction :: proc(user_id, agent_instance_id, direction: string) -> bool {
	return message_db_has_unread(user_id, agent_instance_id, direction)
}

chat_message_created :: proc(message_id: string) -> i64 {
	return message_db_get_created_time(message_id)
}

chat_store_append_message :: proc(user_id, agent_instance_id, direction, body: string, interrupt: bool) -> (string, bool) {
	return chat_store_append_message_with_chain(user_id, agent_instance_id, direction, body, interrupt, "")
}

chat_store_append_message_with_chain :: proc(user_id, agent_instance_id, direction, body: string, interrupt: bool, chain_id: string) -> (string, bool) {
	event := Chat_Event{
		kind = .Message_Appended,
		user_id = user_id,
		agent_instance_id = agent_instance_id,
		direction = direction,
		body = body,
		chain_id = chain_id,
		created_unix_ms = router_now_unix_ms(),
		interrupt = interrupt,
	}

	if event.created_unix_ms == 0 do event.created_unix_ms = router_now_unix_ms()
	event.message_id = fmt.tprintf("chatmsg_%d", event.created_unix_ms)

	if !chat_store_append_event(event) {
		return "", false
	}

	return event.message_id, true
}
