package main

import "core:fmt"
import "core:strings"

task_notify_event :: proc(event: Task_Event) -> bool {
	// Metadata-only WS notifications: user clients receive board refresh metadata;
	// agent wrappers still receive role-routed next-action notifications for task events.
	status := event.status
	if event.task_id != "" {
		idx := task_state_index(event.task_id, event.chain_id)
		state := task_states[idx]
		if status == "" do status = state.status
		payload := task_notification_json(event, status)
		user_client_fanout_all_ws_text(payload)
		if event.kind == .Task_Nudged do return task_notify_recipient_except(event.agent_instance_id, payload, event.author_agent_instance_id)
		return task_notify_by_status(state, status, event.author_agent_instance_id, payload)
	}
	payload := task_notification_json(event, status)
	user_client_fanout_all_ws_text(payload)
	return true
}

task_notify_by_status :: proc(state: Task_State, status, author_agent_instance_id, payload: string) -> bool {
	sent := false
	switch status {
	case "ready":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
	case "claimed", "working", "in_progress", "open":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "review", "needs_review":
		sent = task_notify_role(state, "reviewer", payload, author_agent_instance_id) || sent
	case "needs_improvements", "rejected":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
	case "blocked":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "approved", "done":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "archived", "cancelled":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case:
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	}
	return sent
}

task_notify_role :: proc(state: Task_State, role, payload, author_agent_instance_id: string) -> bool {
	primary := ""
	switch role {
	case "assignee": primary = state.assignee_agent_instance_id
	case "reviewer": primary = state.reviewer_agent_instance_id
	case "coordinator": primary = state.coordinator_agent_instance_id
	case:
	}
	sent := task_notify_recipient_except(primary, payload, author_agent_instance_id)
	return task_notify_participants_by_role(state.task_id, state.chain_id, role, payload, primary, author_agent_instance_id) || sent
}

task_notify_participants_by_role :: proc(task_id, chain_id, role, payload, skip_agent_instance_id, author_agent_instance_id: string) -> bool {
	sent := false
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.role != role do continue
		if p.agent_instance_id == skip_agent_instance_id do continue
		if p.agent_instance_id == author_agent_instance_id do continue
		if p.task_id != task_id && (chain_id == "" || p.chain_id != chain_id) do continue
		sent = task_notify_recipient(p.agent_instance_id, payload) || sent
	}
	return sent
}

task_notify_recipient_except :: proc(agent_instance_id, payload, skip_agent_instance_id: string) -> bool {
	if agent_instance_id == skip_agent_instance_id do return false
	return task_notify_recipient(agent_instance_id, payload)
}

task_notify_recipient :: proc(agent_instance_id, payload: string) -> bool {
	if agent_instance_id == "" do return false
	return registry_send_ws_text(agent_instance_id, payload)
}

task_notification_json :: proc(event: Task_Event, status: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"task_event","event":"`)
	json_write_string(&builder, fmt.tprintf("%v", event.kind))
	strings.write_string(&builder, `","task_id":"`)
	json_write_string(&builder, event.task_id)
	strings.write_string(&builder, `","chain_id":"`)
	json_write_string(&builder, event.chain_id)
	strings.write_string(&builder, `","status":"`)
	json_write_string(&builder, status)
	strings.write_string(&builder, `","changed_by":"`)
	json_write_string(&builder, event.author_agent_instance_id)
	strings.write_string(&builder, `","requested_by":"`)
	json_write_string(&builder, event.author_agent_instance_id)
	strings.write_string(&builder, `","target_agent_instance_id":"`)
	json_write_string(&builder, event.agent_instance_id)
	strings.write_string(&builder, `","body":"`)
	json_write_string(&builder, task_notification_summary(event))
	strings.write_string(&builder, `"`)
	if event.kind == .Task_Nudged {
		strings.write_string(&builder, `","delivery_method":"`)
		json_write_string(&builder, task_nudge_delivery_method(event.body))
		strings.write_string(&builder, `","send_escape_prefix":`)
		strings.write_string(&builder, "true" if strings.index(event.body, "delivery=escape_prefixed_pane_or_ws") >= 0 else "false")
	}
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

task_notification_summary :: proc(event: Task_Event) -> string {
	body := strings.trim_space(event.body)
	if body == "" {
		#partial switch event.kind {
		case .Task_Assigned:
			body = fmt.tprintf("assigned %s", event.agent_instance_id)
		case .Task_Participant_Added:
			body = fmt.tprintf("added %s as %s", event.agent_instance_id, event.role)
		case .Task_Created:
			body = event.title
		case:
			body = fmt.tprintf("%v", event.kind)
		}
	}
	if len(body) > 240 do return body[:240]
	return body
}
