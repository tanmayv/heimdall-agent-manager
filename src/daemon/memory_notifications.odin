package main

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

memory_append_event :: proc(event: contracts.Memory_Event) -> contracts.Memory_Append_Response {
	ev := event
	now := router_now_unix_ms()
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("memory_evt_%d", now))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = now
	if ev.memory_id == "" do ev.memory_id = strings.clone(fmt.tprintf("mem_%d", ev.created_unix_ms))
	if ev.proposal_id == "" && ev.kind == .Memory_Proposed do ev.proposal_id = strings.clone(fmt.tprintf("proposal_%d", ev.created_unix_ms))
	if ev.version == 0 do ev.version = 1

	// Save the event to database first
	if !memory_db_save_event(ev) {
		return contracts.Memory_Append_Response{ok = false, message = "save memory event failed", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
	}

	// Apply projection logic to update active 'memories' record
	rec, found := memory_db_get_record(ev.memory_id)
	if !found {
		rec = contracts.Memory_Record{
			memory_id = strings.clone(ev.memory_id),
			proposal_id = strings.clone(ev.proposal_id),
			status = .Pending,
			version = ev.version,
			created_unix_ms = ev.created_unix_ms,
		}
	}

	#partial switch ev.kind {
	case .Memory_Proposed:
		rec.proposal_id = strings.clone(ev.proposal_id)
		rec.subject_agent = strings.clone(ev.subject_agent)
		rec.scope = strings.clone(ev.scope)
		rec.type = ev.type
		rec.title = strings.clone(ev.title)
		rec.body = strings.clone(ev.body)
		rec.status = .Pending
		rec.reason = strings.clone(ev.reason)
		rec.evidence = strings.clone(ev.evidence)
		rec.metadata_json = strings.clone(ev.metadata_json)
		rec.source_task_id = strings.clone(ev.source_task_id)
		rec.version = ev.version
		rec.updated_unix_ms = ev.created_unix_ms
	case .Memory_Approved:
		if rec.type == .Expertise {
			memory_db_archive_active_expertise(rec.subject_agent, rec.scope, rec.memory_id, ev.created_unix_ms)
		}
		rec.status = .Active
		rec.version += 1
		rec.updated_unix_ms = ev.created_unix_ms
	case .Memory_Rejected:
		rec.status = .Rejected
		rec.updated_unix_ms = ev.created_unix_ms
	case .Memory_Archived:
		rec.status = .Archived
		rec.version += 1
		rec.updated_unix_ms = ev.created_unix_ms
	}

	if !memory_db_save_record(rec) {
		memory_record_free(rec)
		return contracts.Memory_Append_Response{ok = false, message = "save memory record failed", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
	}

	memory_record_free(rec)

	// Broadcast notifications
	memory_notify_event(ev)

	return contracts.Memory_Append_Response{ok = true, message = "appended", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
}

memory_notify_event :: proc(event: contracts.Memory_Event) -> bool {
	rec, found := memory_find_record(event.memory_id, true)
	if found do defer memory_record_free(rec)

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
			coord := task_coordinator_agent_instance_id(state)
			sent = task_notify_recipient_except(coord, payload, event.author) || sent
			sent = task_notify_participants_by_role(state.task_id, state.chain_id, "coordinator", payload, coord, event.author) || sent
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
