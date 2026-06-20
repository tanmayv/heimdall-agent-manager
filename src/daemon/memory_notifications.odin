package main

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import memp "odin_test:lib/memory_provider"

memory_append_event :: proc(event: contracts.Memory_Event) -> contracts.Memory_Append_Response {
	resp := memp.append_event(&memory_provider, event)
	if resp.ok do memory_notify_event(event)
	return resp
}

memory_notify_event :: proc(event: contracts.Memory_Event) -> bool {
	rec, found := memory_find_record(event.memory_id, true)
	payload := memory_notification_json(event, rec, found)
	user_client_fanout_all_ws_text(payload)
	sent := false
	subject := event.subject_agent
	if subject == "" && found do subject = rec.subject_agent
	sent = task_notify_recipient_except(subject, payload, event.author) || sent
	source_task := event.source_task_id
	if source_task == "" && found do source_task = rec.source_task_id
	if source_task != "" {
		if idx, ok := task_existing_state_index(source_task, ""); ok {
			state := task_states[idx]
			sent = task_notify_recipient_except(state.coordinator_agent_instance_id, payload, event.author) || sent
			sent = task_notify_participants_by_role(state.task_id, state.chain_id, "coordinator", payload, state.coordinator_agent_instance_id, event.author) || sent
		}
	}
	return sent
}

memory_notification_json :: proc(event: contracts.Memory_Event, rec: contracts.Memory_Record, found: bool) -> string {
	subject := event.subject_agent
	scope := event.scope
	type_text := memory_type_string_service(event.type)
	status := memory_status_string_service(event.status)
	source_task := event.source_task_id
	metadata_json := event.metadata_json
	if found {
		if subject == "" do subject = rec.subject_agent
		if scope == "" do scope = rec.scope
		type_text = memory_type_string_service(rec.type)
		status = memory_status_string_service(rec.status)
		if source_task == "" do source_task = rec.source_task_id
		if metadata_json == "" do metadata_json = rec.metadata_json
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"memory_event","event":"`); json_write_string(&builder, fmt.tprintf("%v", event.kind))
	strings.write_string(&builder, `","memory_id":"`); json_write_string(&builder, event.memory_id)
	strings.write_string(&builder, `","proposal_id":"`); json_write_string(&builder, event.proposal_id)
	strings.write_string(&builder, `","subject_agent":"`); json_write_string(&builder, subject)
	strings.write_string(&builder, `","scope":"`); json_write_string(&builder, scope)
	strings.write_string(&builder, `","memory_type":"`); json_write_string(&builder, type_text)
	strings.write_string(&builder, `","status":"`); json_write_string(&builder, status)
	strings.write_string(&builder, `","changed_by":"`); json_write_string(&builder, event.author)
	strings.write_string(&builder, `","source_task_id":"`); json_write_string(&builder, source_task)
	strings.write_string(&builder, `","action":"`); json_write_string(&builder, memory_metadata_action(metadata_json))
	strings.write_string(&builder, `","target_memory_id":"`); json_write_string(&builder, memory_metadata_target(metadata_json))
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}
