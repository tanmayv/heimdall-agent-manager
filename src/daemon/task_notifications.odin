package main

import "core:fmt"
import "core:strings"

task_notify_event :: proc(event: Task_Event) -> bool {
	status := event.status
	if event.task_id != "" {
		idx   := task_state_index(event.task_id, event.chain_id)
		state := task_states[idx]
		if status == "" do status = state.status
		payload := task_notification_json(event, status)
		user_client_fanout_all_ws_text(payload)
		
		// E2E Cognitive Memory Audit Hooks
		if strings.has_prefix(event.chain_id, "chain-audit-") {
			if status == "approved" {
				audit_id := event.chain_id[len("chain-audit-"):]
				memory_auditor_conclude_audit(audit_id, "completed", "")
			} else if status == "review_ready" {
				system_project_id := "heimdall-system"
				author := event.author_agent_instance_id
				if author == "" || author == "system" || author == "system-review-vote" || author == "system-auto-approve" {
					author = "operator@local" // fallback to resolve preferences
				}
				reviewer_agent_id := memory_auditor_resolve_pref(author, "memory_reviewer_agent_id")
				reviewer_model_tier := memory_auditor_resolve_pref(author, "memory_reviewer_model_tier")
				reviewer_provider_profile := memory_auditor_resolve_pref(author, "memory_reviewer_provider_profile")
				defer delete(reviewer_agent_id)
				defer delete(reviewer_model_tier)
				defer delete(reviewer_provider_profile)
				
				memory_auditor_start_agent(reviewer_agent_id, "memory_reviewer", reviewer_provider_profile, reviewer_model_tier, system_project_id)
			}
		}
		if event.kind == .Task_Nudged {
			return task_notify_recipient_except(event.agent_instance_id, payload, event.author_agent_instance_id)
		}
		return task_notify_by_status(state, status, event.author_agent_instance_id, payload)
	}
	payload := task_notification_json(event, status)
	user_client_fanout_all_ws_text(payload)
	return true
}

task_notify_by_status :: proc(state: Task_State, status, author_agent_instance_id, payload: string) -> bool {
	sent := false
	switch status {
	case "planning":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "ready", "in_progress":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
	case "review_ready":
		// Notify all lgtm_required participants
		for i in 0..<task_participant_count {
			p := task_participants[i]
			if p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id) do continue
			if p.role != "lgtm_required" do continue
			if p.agent_instance_id == author_agent_instance_id do continue
			sent = task_notify_recipient(p.agent_instance_id, payload) || sent
		}
	case "approved":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "blocked":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "cancelled":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case:
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	}
	// Fan out to all subscribers regardless of status
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id) do continue
		if p.role != "subscriber" do continue
		if p.agent_instance_id == author_agent_instance_id do continue
		sent = task_notify_recipient(p.agent_instance_id, payload) || sent
	}
	return sent
}

// Notify all lgtm_required participants for a task that just became review_ready.
task_notify_all_lgtm_required :: proc(task_id, chain_id: string) {
	idx, found := task_existing_state_index(task_id, chain_id)
	if !found do return
	state   := task_states[idx]
	payload := task_notification_json(Task_Event{
		kind     = .Task_Status_Changed,
		task_id  = task_id,
		chain_id = chain_id,
		status   = "review_ready",
		body     = "task is ready for your review",
	}, "review_ready")
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != task_id && (chain_id == "" || p.chain_id != chain_id) do continue
		if p.role != "lgtm_required" do continue
		if task_reviewer_has_voted(task_id, p.agent_instance_id) do continue
		if task_reviewer_active_slot_blocker(p.agent_instance_id, task_id) != "" do continue
		task_notify_recipient(p.agent_instance_id, payload)
	}
	_ = state
}

// After a reviewer submits a vote, nudge them about their next pending review_ready task.
task_notify_reviewer_rotation :: proc(reviewer: string) {
	if reviewer == "" do return
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != "review_ready" do continue
		if !task_actor_has_role(state, reviewer, "lgtm_required") do continue
		if task_reviewer_has_voted(state.task_id, reviewer) do continue
		if task_reviewer_active_slot_blocker(reviewer, state.task_id) != "" do continue
		event := Task_Event{
			kind              = .Task_Nudged,
			task_id           = state.task_id,
			chain_id          = state.chain_id,
			status            = "review_ready",
			agent_instance_id = reviewer,
			body              = fmt.tprintf("You have a pending review on task %s", state.task_id),
		}
		task_store_append_event(event)
		task_notify_event(event)
		return
	}
}

task_notify_role :: proc(state: Task_State, role, payload, author_agent_instance_id: string) -> bool {
	primary := ""
	switch role {
	case "assignee":    primary = state.assignee_agent_instance_id
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
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"task_event","event":"`)
	json_write_string(&b, fmt.tprintf("%v", event.kind))
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, event.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, event.chain_id)
	strings.write_string(&b, `","status":"`)
	json_write_string(&b, status)
	strings.write_string(&b, `","changed_by":"`)
	json_write_string(&b, event.author_agent_instance_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, event.agent_instance_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, task_notification_summary(event))
	strings.write_string(&b, `"`)
	
	if event.kind == .Task_Nudged {
		strings.write_string(&b, `,"delivery_method":"`)
		json_write_string(&b, task_nudge_delivery_method(event.body))
		strings.write_string(&b, `","send_escape_prefix":`)
		strings.write_string(&b, "true" if strings.index(event.body, "delivery=escape_prefixed_pane_or_ws") >= 0 else "false")
	}

	// Augment with full task payload if task_id is present
	if event.task_id != "" {
		if idx, found := task_existing_state_index(event.task_id, event.chain_id); found {
			strings.write_string(&b, `,"task":`)
			task_write_state_json(&b, task_states[idx])
		}
	}

	// Augment with full task chain payload if chain_id is present
	if event.chain_id != "" {
		if idx := task_chain_index_of(event.chain_id); idx >= 0 {
			strings.write_string(&b, `,"chain":`)
			task_write_chain_json(&b, task_chains[idx])
		}
	}

	strings.write_string(&b, `}`)
	return strings.to_string(b)
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
