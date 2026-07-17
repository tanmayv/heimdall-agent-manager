package message_provider

import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

// TODO: In-memory provider is process-global and not thread-safe yet; daemon request handlers run in threads.
MAX_MESSAGES :: 200_000

Memory_State :: struct {
	messages: [MAX_MESSAGES]contracts.Message,
	message_count: int,
	next_id: int,
	// Per-boot epoch mixed into message ids. The counter alone resets to 1 on
	// every restart, so bare "msg_<n>" ids collide across restarts. Those ids feed
	// federation idempotency keys (msg:<daemon>:<message_id>), so a collision made
	// a fresh message look like an already-delivered duplicate and get silently
	// deduped. The boot epoch makes ids unique across restarts.
	boot_epoch: i64,
}

memory_capabilities := [?]contracts.Message_Provider_Capability {
	.Send_Message,
	.Fetch_Messages,
	.Unread_Count,
	.Mark_Read,
}

memory_state: Memory_State

new_memory_provider :: proc() -> Message_Provider {
	// NOTE: keep any function call OUT of the Memory_State compound literal. This
	// struct embeds a huge fixed array, and a call inside the literal forces the
	// compiler to materialize the whole struct as a STACK temporary before the
	// assignment -> stack overflow / segfault at init. Zero-init in place, then set
	// the boot epoch on the global directly.
	memory_state = Memory_State{next_id = 1}
	memory_state.boot_epoch = now_unix_ms()
	return Message_Provider {
		name = "memory",
		capabilities = memory_capabilities[:],
		state = rawptr(&memory_state),
		send_message = memory_send_message,
		fetch_messages = memory_fetch_messages,
		unread_count = memory_unread_count,
		mark_read = memory_mark_read,
	}
}

memory_send_message :: proc(state: rawptr, request: contracts.Send_Message_Request) -> contracts.Send_Message_Response {
	st := transmute(^Memory_State)state
	if st.message_count >= MAX_MESSAGES {
		fmt.println("message_provider memory send failure store_full", "conversation", string(request.conversation_id), "from", string(request.from_agent_instance_id), "target", string(request.target_agent_instance_id), "count", st.message_count)
		return contracts.Send_Message_Response{ok = false, message = "message store full", conversation_id = request.conversation_id}
	}

	now := now_unix_ms()
	// Include the per-boot epoch so ids stay unique across daemon restarts (see
	// Memory_State.boot_epoch). Format: msg_<boot_epoch>_<counter>.
	message_id := contracts.Message_ID(strings.clone(fmt.tprintf("msg_%d_%d", st.boot_epoch, st.next_id)))
	st.next_id += 1

	st.messages[st.message_count] = contracts.Message {
		id = message_id,
		conversation_id = contracts.Conversation_ID(strings.clone(string(request.conversation_id))),
		from_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(string(request.from_agent_instance_id))),
		target_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(string(request.target_agent_instance_id))),
		direction = .Inbound,
		status = .Sent,
		body = strings.clone(request.body),
		created_unix_ms = now,
		updated_unix_ms = now,
		read_unix_ms = 0,
	}
	st.message_count += 1
	memory_debug_check_race_symptoms(st, message_id, request)

	return contracts.Send_Message_Response {
		ok = true,
		message = "stored",
		message_id = message_id,
		conversation_id = request.conversation_id,
		created_unix_ms = now,
	}
}

memory_debug_check_race_symptoms :: proc(st: ^Memory_State, message_id: contracts.Message_ID, request: contracts.Send_Message_Request) {
	// Diagnostic only: without locks this can report symptoms, but cannot reliably catch every lost overwrite.
	if st.next_id - 1 != st.message_count {
		fmt.println("message_provider race_suspected counter_mismatch", "next_id", st.next_id, "message_count", st.message_count)
	}

	duplicate_ids := 0
	for i in 0..<st.message_count {
		if st.messages[i].id == message_id do duplicate_ids += 1
	}
	if duplicate_ids > 1 {
		fmt.println("message_provider race_suspected duplicate_message_id", string(message_id), "count", duplicate_ids, "conversation", string(request.conversation_id), "from", string(request.from_agent_instance_id), "target", string(request.target_agent_instance_id))
	}
}

memory_fetch_messages :: proc(state: rawptr, request: contracts.Fetch_Messages_Request) -> contracts.Fetch_Messages_Response {
	st := transmute(^Memory_State)state
	limit := request.limit
	if limit <= 0 || limit > 100 do limit = 100

	result := make([dynamic]contracts.Message, 0, limit)
	now := now_unix_ms()

	seen_after := request.after_message_id == ""
	for i in 0..<st.message_count {
		msg := st.messages[i]
		if msg.conversation_id != request.conversation_id do continue
		if msg.target_agent_instance_id != request.agent_instance_id && msg.from_agent_instance_id != request.agent_instance_id do continue
		if !seen_after {
			if msg.id == request.after_message_id do seen_after = true
			continue
		}
		if !request.include_read && msg.target_agent_instance_id == request.agent_instance_id && msg.read_unix_ms > 0 do continue
		if len(result) >= limit {
			return contracts.Fetch_Messages_Response{ok = true, message = "fetched", messages = result[:], has_more = true}
		}

		append(&result, msg)
	}

	return contracts.Fetch_Messages_Response{ok = true, message = "fetched", messages = result[:], has_more = false}
}

memory_unread_count :: proc(state: rawptr, request: contracts.Unread_Count_Request) -> contracts.Unread_Count_Response {
	st := transmute(^Memory_State)state
	count := 0
	for i in 0..<st.message_count {
		msg := st.messages[i]
		if msg.conversation_id == request.conversation_id && msg.target_agent_instance_id == request.agent_instance_id && msg.read_unix_ms == 0 {
			count += 1
		}
	}
	return contracts.Unread_Count_Response{ok = true, message = "counted", conversation_id = request.conversation_id, unread_count = count}
}

memory_mark_read :: proc(state: rawptr, request: contracts.Mark_Read_Request) -> contracts.Mark_Read_Response {
	st := transmute(^Memory_State)state
	now := now_unix_ms()
	marked := 0
	for i in 0..<st.message_count {
		if st.messages[i].conversation_id != request.conversation_id do continue
		if st.messages[i].target_agent_instance_id != request.agent_instance_id do continue
		if st.messages[i].read_unix_ms > 0 do continue
		st.messages[i].read_unix_ms = now
		st.messages[i].status = .Read
		st.messages[i].updated_unix_ms = now
		marked += 1
		if request.through_message_id != "" && st.messages[i].id == request.through_message_id do break
	}
	return contracts.Mark_Read_Response{ok = true, message = "marked", conversation_id = request.conversation_id, marked_count = marked, read_unix_ms = now}
}

now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
