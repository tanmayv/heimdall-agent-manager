package main

import "core:fmt"
import "core:strings"

task_notify_event :: proc(event: Task_Event) -> bool {
	ev := event
	if task_event_count > 0 {
		last_ev := task_events[task_event_count - 1]
		if last_ev.kind == ev.kind && last_ev.task_id == ev.task_id && last_ev.chain_id == ev.chain_id {
			ev.event_id = last_ev.event_id
			ev.created_unix_ms = last_ev.created_unix_ms
			ev.interrupt = last_ev.interrupt
		}
	}
	if ev.event_id == "" {
		ev.event_id = strings.clone(fmt.tprintf("taskevt_%d", router_now_unix_ms()))
	}
	if ev.created_unix_ms == 0 {
		ev.created_unix_ms = router_now_unix_ms()
	}
	if !ev.interrupt && (ev.kind == .Task_Status_Changed || ev.kind == .Task_Nudged) {
		ev.interrupt = true
	}

	status := ev.status
	if ev.task_id != "" {
		idx   := task_state_index(ev.task_id, ev.chain_id)
		state := task_states[idx]
		if status == "" do status = task_status_to_string(state.status)
		payload := task_notification_json(ev, status)
		agent_payload := task_notification_agent_json(ev, status)
		user_client_fanout_all_ws_text(payload)
		
		// E2E Cognitive Memory Audit Hooks
		if strings.has_prefix(ev.chain_id, "chain-audit-") {
			if status == "approved" && strings.has_prefix(state.title, "5.") {
				// The final audit task is approved! Auto-complete the task chain!
				fmt.printfln("SYSTEM: Final audit task in chain '%s' approved. Auto-completing the audit chain...", ev.chain_id)
				_ = task_service_complete_chain(ev.chain_id, "Cognitive memory audit completed and curated successfully.", "system-auto-complete")
			} else if status == "review_ready" {
				system_project_id := "heimdall-system"
				author := ev.author_agent_instance_id
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
		if ev.kind == .Task_Nudged {
			return task_notify_recipient_except(ev.agent_instance_id, agent_payload, ev.author_agent_instance_id)
		}
		return task_notify_by_status(state, status, ev.author_agent_instance_id, agent_payload)
	}
	payload := task_notification_json(ev, status)
	user_client_fanout_all_ws_text(payload)

	// E2E Cognitive Memory Audit Hooks on Chain Completion
	if ev.kind == .Chain_Completed && strings.has_prefix(ev.chain_id, "chain-audit-") {
		audit_id := ev.chain_id[len("chain-audit-"):]
		fmt.printfln("SYSTEM: Audit chain '%s' completed. Concluding the memory audit...", ev.chain_id)
		memory_auditor_conclude_audit(audit_id, "completed", "")
	}
	return true
}

task_notify_by_status :: proc(state: Task_State, status, author_agent_instance_id, payload: string) -> bool {
	sent := false
	switch status {
	case "planning":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "queued", "in_progress":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
	case "review_ready":
		// Agent review notifications are dispatched explicitly by
		// task_notify_all_lgtm_required so we can enforce one-active-review-at-a-time
		// without duplicating or prematurely sending review work.
	case "approved":
		sent = task_notify_role(state, "coordinator", payload, author_agent_instance_id) || sent
	case "blocked":
		sent = task_notify_role(state, "assignee", payload, author_agent_instance_id) || sent
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
	payload := task_notification_agent_json(Task_Event{
		kind     = .Task_Status_Changed,
		task_id  = task_id,
		chain_id = chain_id,
		status   = "review_ready",
		body     = "task is ready for your review",
	}, "review_ready")
	has_required := false
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != task_id && (chain_id == "" || p.chain_id != chain_id) do continue
		if p.role != "lgtm_required" do continue
		has_required = true
		if task_reviewer_has_voted(task_id, p.agent_instance_id) do continue
		if task_reviewer_active_slot_blocker(p.agent_instance_id, task_id) != "" do continue
		task_notify_recipient(p.agent_instance_id, payload)
	}
	if !has_required {
		default_reviewer := task_reviewer_agent_instance_id(state)
		if default_reviewer != "" && default_reviewer != "operator@local" {
			if !task_reviewer_has_voted(task_id, default_reviewer) && task_reviewer_active_slot_blocker(default_reviewer, task_id) == "" {
				task_notify_recipient(default_reviewer, payload)
			}
		}
	}
}

// After a reviewer submits a vote, nudge them about their next pending review_ready task.
task_notify_reviewer_rotation :: proc(reviewer: string) {
	if reviewer == "" do return
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .Review_Ready do continue
		is_required := task_actor_has_role(state, reviewer, "lgtm_required")
		if !is_required {
			is_required = task_reviewer_agent_instance_id(state) == reviewer
		}
		if !is_required do continue
		if task_reviewer_has_voted(state.task_id, reviewer) do continue
		if task_reviewer_active_slot_blocker(reviewer, state.task_id) != "" do continue
		event := Task_Event{
			kind              = .Task_Nudged,
			task_id           = state.task_id,
			chain_id          = state.chain_id,
			status            = "review_ready",
			agent_instance_id = reviewer,
			body              = fmt.tprintf("You have a pending review on task %s", state.task_id),
			interrupt         = true,
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
	case "coordinator": primary = task_coordinator_agent_instance_id(state)
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
	event_id := notification_outbox_insert_pending(agent_instance_id, payload)
	ok := registry_send_ws_text(agent_instance_id, payload)
	if event_id != "" {
		_ = notification_outbox_mark_attempt(agent_instance_id, event_id, ok)
	}
	if !ok {
		fmt.printf("WARNING: failed to send WS to agent '%s'. Queued durable notification.\n", agent_instance_id)
	}
	return ok
}

task_notifications_flush_queue :: proc(agent_instance_id: string) {
	if agent_instance_id == "" do return
	delivered := notification_outbox_replay_pending(agent_instance_id)
	if delivered > 0 {
		fmt.printf("INFO: replayed %d durable task notifications to agent '%s'.\n", delivered, agent_instance_id)
	}
}

task_notification_write_base_json :: proc(b: ^strings.Builder, event: Task_Event, status: string) {
	strings.write_string(b, `{"type":"task_event","event":"`)
	json_write_string(b, fmt.tprintf("%v", event.kind))
	strings.write_string(b, `","task_id":"`)
	json_write_string(b, event.task_id)
	strings.write_string(b, `","chain_id":"`)
	json_write_string(b, event.chain_id)
	strings.write_string(b, `","status":"`)
	json_write_string(b, status)
	strings.write_string(b, `","changed_by":"`)
	json_write_string(b, event.author_agent_instance_id)
	strings.write_string(b, `","target_agent_instance_id":"`)
	json_write_string(b, event.agent_instance_id)
	strings.write_string(b, `","body":"`)
	json_write_string(b, task_notification_summary(event))
	strings.write_string(b, `","event_id":"`)
	json_write_string(b, event.event_id)
	strings.write_string(b, `","created_unix_ms":`)
	strings.write_string(b, fmt.tprintf("%d", event.created_unix_ms))
	
	if event.kind == .Task_Nudged {
		strings.write_string(b, `,"delivery_method":"`)
		json_write_string(b, task_nudge_delivery_method(event.body))
		strings.write_string(b, `"`)
	}
	strings.write_string(b, `,"interrupt":`)
	strings.write_string(b, "true" if event.interrupt else "false")
	strings.write_string(b, `,"send_escape_prefix":`)
	strings.write_string(b, "true" if event.interrupt else "false")
}

task_notification_agent_json :: proc(event: Task_Event, status: string) -> string {
	b := strings.builder_make()
	task_notification_write_base_json(&b, event, status)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

task_notification_json :: proc(event: Task_Event, status: string) -> string {
	b := strings.builder_make()
	task_notification_write_base_json(&b, event, status)

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
	if strings.has_prefix(body, "system_auto:chain_paused") {
		body = "Chain paused. Stop active work on this task; it has been moved back to queued."
	} else if strings.has_prefix(body, "system_auto:chain_moved_to_planning") {
		body = "Chain moved to planning. Stop active work on this task; it has been moved back to queued."
	} else if strings.has_prefix(body, "system_queue:assignee_busy:") {
		blocker := body[len("system_queue:assignee_busy:"):]
		if blocker == "pending_reviews_exist" {
			body = "Queued for later because you still owe a review on another task."
		} else if blocker != "" {
			body = fmt.tprintf("Queued for later because another task currently has priority: %s", blocker)
		} else {
			body = "Queued for later because another task currently has priority."
		}
	} else if strings.has_prefix(body, "system_auto:deps_cleared") {
		body = "Task is queued and ready to be picked up when you are free."
	} else if strings.has_prefix(body, "system_auto:auto_claimed") {
		body = "Task auto-claimed. This is now your current active task."
	} else if strings.has_prefix(body, "ngtm by ") {
		body = fmt.tprintf("Review requested changes: %s", body)
	} else if strings.has_prefix(body, "system_auto:all_lgtm_required_approved") {
		body = "Task approved by all required reviewers."
	} else if strings.has_prefix(body, "task is ready for your review") {
		body = "A task is ready for your review. Review it now if you are free."
	}
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
