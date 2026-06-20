package main

import "core:fmt"
import "core:os"
import "core:strings"

CHAT_MAX_EVENTS :: 20000
CHAT_MAX_MESSAGES :: 10000

Chat_Event_Kind :: enum { Message_Appended, Delivered_Marked, Read_Marked, Delivery_Failed }

Chat_Event :: struct {
	event_id: string,
	kind: Chat_Event_Kind,
	message_id: string,
	user_id: string,
	agent_instance_id: string,
	direction: string,
	body: string,
	delivered_unix_ms: i64,
	read_unix_ms: i64,
	delivery_failed_unix_ms: i64,
	delivery_error: string,
	created_unix_ms: i64,
}

Chat_Message :: struct {
	message_id: string,
	user_id: string,
	agent_instance_id: string,
	direction: string,
	body: string,
	delivered_unix_ms: i64,
	read_unix_ms: i64,
	delivery_failed_unix_ms: i64,
	delivery_error: string,
	created_unix_ms: i64,
}

chat_events: [CHAT_MAX_EVENTS]Chat_Event
chat_event_count: int
chat_messages: [CHAT_MAX_MESSAGES]Chat_Message
chat_message_count: int
chat_store_dir: string
chat_events_path: string

chat_store_init :: proc(data_dir: string) {
	chat_event_count = 0
	chat_message_count = 0
	chat_store_dir = strings.clone(fmt.tprintf("%s/chat", data_dir))
	chat_events_path = strings.clone(fmt.tprintf("%s/events.jsonl", chat_store_dir))
	_ = os.make_directory_all(chat_store_dir)
	chat_store_replay()
}

chat_store_append_event :: proc(event: Chat_Event) -> bool {
	ev := event
	if ev.event_id == "" do ev.event_id = fmt.tprintf("chatevt_%d", router_now_unix_ms())
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	if ev.message_id == "" && ev.kind == .Message_Appended do ev.message_id = fmt.tprintf("chatmsg_%d", ev.created_unix_ms)
	if !chat_store_apply_event(ev) do return false
	file, err := os.open(chat_events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return false
	defer os.close(file)
	os.write_string(file, chat_event_json(ev))
	os.write_string(file, "\n")
	return true
}

chat_store_apply_event :: proc(event: Chat_Event) -> bool {
	if chat_event_count < CHAT_MAX_EVENTS {
		chat_events[chat_event_count] = event
		chat_event_count += 1
	}
	#partial switch event.kind {
	case .Message_Appended:
		if chat_message_count < CHAT_MAX_MESSAGES {
			chat_messages[chat_message_count] = Chat_Message{message_id = strings.clone(event.message_id), user_id = strings.clone(event.user_id), agent_instance_id = strings.clone(event.agent_instance_id), direction = strings.clone(event.direction), body = strings.clone(event.body), delivered_unix_ms = event.delivered_unix_ms, read_unix_ms = event.read_unix_ms, delivery_failed_unix_ms = event.delivery_failed_unix_ms, delivery_error = strings.clone(event.delivery_error), created_unix_ms = event.created_unix_ms}
			chat_message_count += 1
		}
	case .Delivered_Marked:
		for i in 0..<chat_message_count {
			msg := &chat_messages[i]
			if msg.user_id != event.user_id || msg.agent_instance_id != event.agent_instance_id do continue
			if event.message_id != "" && msg.message_id != event.message_id do continue
			if msg.delivered_unix_ms == 0 || msg.delivered_unix_ms < event.delivered_unix_ms do msg.delivered_unix_ms = event.delivered_unix_ms
		}
	case .Read_Marked:
		read_direction := event.direction
		if read_direction == "" do read_direction = "agent_to_user"
		for i in 0..<chat_message_count {
			msg := &chat_messages[i]
			if msg.user_id != event.user_id || msg.agent_instance_id != event.agent_instance_id do continue
			if msg.direction != read_direction do continue
			if event.message_id != "" && msg.message_id != event.message_id && msg.created_unix_ms > chat_message_created(event.message_id) do continue
			if msg.read_unix_ms == 0 || msg.read_unix_ms < event.read_unix_ms do msg.read_unix_ms = event.read_unix_ms
		}
	case .Delivery_Failed:
		for i in 0..<chat_message_count {
			msg := &chat_messages[i]
			if msg.user_id != event.user_id || msg.agent_instance_id != event.agent_instance_id do continue
			if event.message_id != "" && msg.message_id != event.message_id do continue
			if msg.delivery_failed_unix_ms == 0 || msg.delivery_failed_unix_ms < event.delivery_failed_unix_ms {
				msg.delivery_failed_unix_ms = event.delivery_failed_unix_ms
				msg.delivery_error = strings.clone(event.delivery_error)
			}
		}
	}
	return true
}

chat_message_created :: proc(message_id: string) -> i64 {
	for i in 0..<chat_message_count {
		if chat_messages[i].message_id == message_id do return chat_messages[i].created_unix_ms
	}
	return 0
}

chat_store_replay :: proc() {
	data, err := os.read_entire_file(chat_events_path, context.allocator)
	if err != nil do return
	lines := strings.split(string(data), "\n")
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		event, ok := chat_event_from_json(trimmed)
		if ok do chat_store_apply_event(event)
	}
}

chat_unread_count :: proc(user_id, agent_instance_id: string) -> int {
	count := 0
	for i in 0..<chat_message_count {
		msg := chat_messages[i]
		if msg.user_id == user_id && msg.agent_instance_id == agent_instance_id && msg.direction == "agent_to_user" && msg.read_unix_ms == 0 do count += 1
	}
	return count
}

chat_has_unread_direction :: proc(user_id, agent_instance_id, direction: string) -> bool {
	for i in 0..<chat_message_count {
		msg := chat_messages[i]
		if msg.user_id == user_id && msg.agent_instance_id == agent_instance_id && msg.direction == direction && msg.read_unix_ms == 0 do return true
	}
	return false
}

chat_event_json :: proc(event: Chat_Event) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"event_id":"`); json_write_string(&builder, event.event_id)
	strings.write_string(&builder, `","kind":"`); json_write_string(&builder, fmt.tprintf("%v", event.kind))
	strings.write_string(&builder, `","message_id":"`); json_write_string(&builder, event.message_id)
	strings.write_string(&builder, `","user_id":"`); json_write_string(&builder, event.user_id)
	strings.write_string(&builder, `","agent_instance_id":"`); json_write_string(&builder, event.agent_instance_id)
	strings.write_string(&builder, `","direction":"`); json_write_string(&builder, event.direction)
	strings.write_string(&builder, `","body":"`); json_write_string(&builder, event.body)
	strings.write_string(&builder, `","delivered_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", event.delivered_unix_ms))
	strings.write_string(&builder, `,"read_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", event.read_unix_ms))
	strings.write_string(&builder, `,"delivery_failed_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", event.delivery_failed_unix_ms))
	strings.write_string(&builder, `,"delivery_error":"`); json_write_string(&builder, event.delivery_error)
	strings.write_string(&builder, `","created_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", event.created_unix_ms)); strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

chat_event_from_json :: proc(line: string) -> (Chat_Event, bool) {
	kind_text := extract_json_string(line, "kind", "")
	kind := Chat_Event_Kind.Message_Appended
	if kind_text == "Delivered_Marked" do kind = .Delivered_Marked
	if kind_text == "Read_Marked" do kind = .Read_Marked
	if kind_text == "Delivery_Failed" do kind = .Delivery_Failed
	event := Chat_Event{event_id = extract_json_string(line, "event_id", ""), kind = kind, message_id = extract_json_string(line, "message_id", ""), user_id = extract_json_string(line, "user_id", ""), agent_instance_id = extract_json_string(line, "agent_instance_id", ""), direction = extract_json_string(line, "direction", ""), body = extract_json_string(line, "body", ""), delivered_unix_ms = i64(extract_json_int(line, "delivered_unix_ms", 0)), read_unix_ms = i64(extract_json_int(line, "read_unix_ms", 0)), delivery_failed_unix_ms = i64(extract_json_int(line, "delivery_failed_unix_ms", 0)), delivery_error = extract_json_string(line, "delivery_error", ""), created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0))}
	return event, kind_text != ""
}
