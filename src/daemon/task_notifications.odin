package main

import "core:fmt"
import "core:strings"

task_notify_event :: proc(event: Task_Event) -> bool {
	// Metadata-only WS notifications routed by task role, never through MessageProvider.
	if event.task_id == "" do return true
	idx := task_state_index(event.task_id, event.chain_id)
	state := task_states[idx]
	payload := task_notification_json(event)
	sent := false
	status := event.status
	switch status {
	case "ready":
		sent = task_notify_recipient(state.assignee_agent_instance_id, payload) || sent
	case "needs_review":
		sent = task_notify_recipient(state.reviewer_agent_instance_id, payload) || sent
	case "needs_improvements":
		sent = task_notify_recipient(state.assignee_agent_instance_id, payload) || sent
	case "blocked":
		sent = task_notify_recipient(state.coordinator_agent_instance_id, payload) || sent
	case "approved":
		sent = task_notify_recipient(state.coordinator_agent_instance_id, payload) || sent
		sent = task_notify_recipient(state.assignee_agent_instance_id, payload) || sent
	case "done":
		sent = task_notify_recipient(state.coordinator_agent_instance_id, payload) || sent
	case:
		// For non-status/comment/assignment events, notify task participants only.
		for i in 0..<task_participant_count {
			p := task_participants[i]
			if p.task_id == event.task_id || (event.chain_id != "" && p.chain_id == event.chain_id) {
				sent = task_notify_recipient(p.agent_instance_id, payload) || sent
			}
		}
	}
	return sent
}

task_notify_recipient :: proc(agent_instance_id, payload: string) -> bool {
	if agent_instance_id == "" do return false
	return registry_send_ws_text(agent_instance_id, payload)
}

task_notification_json :: proc(event: Task_Event) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"task_event","event":"`)
	json_write_string(&builder, fmt.tprintf("%v", event.kind))
	strings.write_string(&builder, `","task_id":"`)
	json_write_string(&builder, event.task_id)
	strings.write_string(&builder, `","chain_id":"`)
	json_write_string(&builder, event.chain_id)
	strings.write_string(&builder, `","status":"`)
	json_write_string(&builder, event.status)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}
