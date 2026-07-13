package main

import "core:fmt"
import "core:strings"

Task_Notification_Delivery :: struct {
	live_delivered: bool,
	durable_queued: bool,
	failed: bool,
}

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
	// Task notifications can be frequent. Do not force interrupt=true here;
	// wrappers should deliver task-event text without Escape unless a future
	// explicit user-facing control opts in. This prevents task notification
	// storms from aborting active agent generations.

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
					author = HUMAN_RECIPIENT_ID // fallback to resolve preferences
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

// Actionable recipient roles for each task status transition. Kept as
// package-level slices so task_notification_policy_for_status can return them
// safely (Odin refuses to return stack-allocated slice literals).
//
// review_ready is intentionally NOT in this table: it is dispatched separately
// by task_notify_all_lgtm_required so we can enforce one-active-review-at-a-time
// and skip already-voted reviewers.
@(private="file")
TASK_NOTIFY_ROLES_COORDINATOR := [1]string{"coordinator"}
@(private="file")
TASK_NOTIFY_ROLES_ASSIGNEE := [1]string{"assignee"}
@(private="file")
TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR := [2]string{"assignee", "coordinator"}

// task_notification_policy_for_status returns:
//   actionable_roles      — the closed set of roles that need this notification
//   actionable_required   — true when the status has real-world consequences
//                           that must reach someone (never silently dropped).
task_notification_policy_for_status :: proc(status: string) -> (actionable_roles: []string, actionable_required: bool) {
	switch status {
	case "planning":
		return TASK_NOTIFY_ROLES_COORDINATOR[:], true
	case "queued", "in_progress":
		return TASK_NOTIFY_ROLES_ASSIGNEE[:], true
	case "review_ready":
		return nil, false
	case "approved":
		// Assignee must know their task landed; coordinator must know closeout
		// is actionable (chain-19f4b3d0617 RCA fix).
		return TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR[:], true
	case "blocked":
		return TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR[:], true
	case "cancelled":
		return TASK_NOTIFY_ROLES_ASSIGNEE_COORDINATOR[:], true
	case:
		return TASK_NOTIFY_ROLES_COORDINATOR[:], true
	}
}

// Collect the concrete agent_instance_id set for a task-role, honoring:
//   - the primary role holder (state.assignee_agent_instance_id, chain coordinator)
//   - every task participant with that role
// The returned slice is caller-owned and must be delete()d.
task_recipients_for_role :: proc(state: Task_State, role: string) -> [dynamic]string {
	out := make([dynamic]string)
	switch role {
	case "assignee":
		if state.assignee_agent_instance_id != "" do append(&out, state.assignee_agent_instance_id)
	case "coordinator":
		c := task_coordinator_agent_instance_id(state)
		if c != "" do append(&out, c)
	}
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != state.task_id do continue
		if p.role != role do continue
		if p.agent_instance_id == "" do continue
		append(&out, p.agent_instance_id)
	}
	return out
}

// Central recipient-set builder for a task status transition.
// Guarantees the returned set contains no duplicates and no empty ids.
// The author is NOT removed here; callers apply that skip at send time so we
// can log per-agent decisions and still emit a fallback when the set collapses.
task_actionable_recipients :: proc(state: Task_State, status: string) -> (recipients: [dynamic]string, reasons: map[string]string, required: bool) {
	roles, needs := task_notification_policy_for_status(status)
	required = needs
	recipients = make([dynamic]string)
	reasons = make(map[string]string)
	seen := make(map[string]bool); defer delete(seen)

	for role in roles {
		role_recips := task_recipients_for_role(state, role)
		defer delete(role_recips)
		for r in role_recips {
			if r == "" do continue
			if seen[r] do continue
			seen[r] = true
			append(&recipients, r)
			reasons[r] = role
		}
	}

	// Subscribers are always included but reason=subscriber so we can filter later.
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != state.task_id do continue
		if p.role != "subscriber" do continue
		if p.agent_instance_id == "" do continue
		if seen[p.agent_instance_id] do continue
		seen[p.agent_instance_id] = true
		append(&recipients, p.agent_instance_id)
		reasons[p.agent_instance_id] = "subscriber"
	}
	return
}

// Fallback used when the actionable set is empty after skipping the author.
// Order: chain default reviewer, chain coordinator, operator@local. The first
// non-empty, non-author id wins. If no live recipient exists we still queue to
// operator@local via the durable outbox so the event is never lost.
task_notify_fallback :: proc(state: Task_State, payload, author: string) -> (recipient: string, ok: bool) {
	candidates := []string{
		task_runtime_agent_target(task_chain_default_reviewer_agent_instance_id(state.chain_id)),
		task_runtime_agent_target(task_coordinator_agent_instance_id(state)),
		HUMAN_RECIPIENT_ID,
	}
	for c in candidates {
		if c == "" || c == author do continue
		_ = task_notify_recipient(c, payload)
		return c, true
	}
	// Last resort: durable-queue to the human inbox so the event has an audit trail.
	_ = notification_outbox_insert_pending(HUMAN_RECIPIENT_ID, payload)
	return HUMAN_RECIPIENT_ID, false
}

task_notify_by_status :: proc(state: Task_State, status, author_agent_instance_id, payload: string) -> bool {
	recipients, reasons, required := task_actionable_recipients(state, status)
	defer {
		delete(recipients)
		delete(reasons)
	}

	sent_actionable   := 0
	sent_subscribers  := 0
	skipped_self      := 0

	for r in recipients {
		if r == author_agent_instance_id {
			skipped_self += 1
			continue
		}
		if task_notify_recipient(r, payload) {
			if reasons[r] == "subscriber" {
				sent_subscribers += 1
			} else {
				sent_actionable += 1
			}
		} else {
			// Failure to send live is not a routing failure: the durable outbox
			// already captured the event inside task_notify_recipient. Count it
			// as actionable-covered so the fallback does not double-notify.
			if reasons[r] == "subscriber" {
				sent_subscribers += 1
			} else {
				sent_actionable += 1
			}
		}
	}

	if required && sent_actionable == 0 {
		fallback_recipient, fallback_live := task_notify_fallback(state, payload, author_agent_instance_id)
		fmt.printfln(
			"NOTIFY: task=%s chain=%s status=%s actionable_empty=true fallback=%s fallback_live=%t author=%s",
			state.task_id, state.chain_id, status, fallback_recipient, fallback_live, author_agent_instance_id,
		)
		return true
	}

	fmt.printfln(
		"NOTIFY: task=%s chain=%s status=%s actionable_sent=%d subscribers_sent=%d skipped_self=%d author=%s",
		state.task_id, state.chain_id, status, sent_actionable, sent_subscribers, skipped_self, author_agent_instance_id,
	)
	return sent_actionable + sent_subscribers > 0
}

// Notify all lgtm_required participants for a task that just became review_ready.
// Guarantees at least one recipient will hear about the transition:
//   1. Every unblocked lgtm_required participant.
//   2. If none of them is unblocked (all voted/slot-blocked), the chain's
//      default_reviewer.
//   3. If that too is empty or already-voted, the chain coordinator.
//   4. Failing all of the above, durable-queue to operator@local so the event
//      is never silently dropped.
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
	has_required   := false
	notified_count := 0
	user_proxy_required := false
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != task_id do continue
		if p.role != "lgtm_required" do continue
		has_required = true
		if task_reviewer_is_user_review(state, p.agent_instance_id) {
			user_proxy_required = true
			continue
		}
		if task_reviewer_has_voted(task_id, p.agent_instance_id) do continue
		if task_reviewer_active_slot_blocker(p.agent_instance_id, task_id) != "" do continue
		task_notify_review_ready_agent(state, p.agent_instance_id)
		task_notify_recipient(p.agent_instance_id, payload)
		notified_count += 1
	}
	if notified_count > 0 {
		fmt.printfln("NOTIFY: task=%s chain=%s status=review_ready lgtm_required_notified=%d", task_id, chain_id, notified_count)
		return
	}
	if user_proxy_required || (!has_required && task_requires_user_review(state)) {
		fmt.printfln("NOTIFY: task=%s chain=%s status=review_ready user_proxy_routed_to_operator=true", task_id, chain_id)
		return
	}
	// Fallback chain: default reviewer → coordinator → operator@local (durable).
	default_reviewer := task_concrete_reviewer_agent_instance_id(state)
	if default_reviewer != "" {
		if !task_reviewer_has_voted(task_id, default_reviewer) && task_reviewer_active_slot_blocker(default_reviewer, task_id) == "" {
			task_notify_review_ready_agent(state, default_reviewer)
			task_notify_recipient(default_reviewer, payload)
			fmt.printfln("NOTIFY: task=%s chain=%s status=review_ready fallback=default_reviewer=%s has_required=%t", task_id, chain_id, default_reviewer, has_required)
			return
		}
	}
	coord := task_runtime_agent_target(task_coordinator_agent_instance_id(state))
	if coord != "" {
		task_notify_recipient(coord, payload)
		fmt.printfln("NOTIFY: task=%s chain=%s status=review_ready fallback=coordinator=%s has_required=%t", task_id, chain_id, coord, has_required)
		return
	}
	_ = notification_outbox_insert_pending(HUMAN_RECIPIENT_ID, payload)
	fmt.printfln("NOTIFY: task=%s chain=%s status=review_ready fallback=operator_durable has_required=%t", task_id, chain_id, has_required)
}

task_notify_review_ready_agent :: proc(state: Task_State, reviewer_agent_instance_id: string) {
	if reviewer_agent_instance_id == "" do return
	chain, found := store_get_chain(state.chain_id)
	if !found do return
	if chain.status != "in_progress" do return
	_ = task_autoscaler_ensure_agent(chain, reviewer_agent_instance_id, state.task_id, "high", router_now_unix_ms(), "review_ready")
}

// After a reviewer submits a vote, nudge them about their next pending review_ready task.
task_notify_reviewer_rotation :: proc(reviewer: string) {
	if reviewer == "" do return
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .Review_Ready do continue
		is_required := task_actor_has_role(state, reviewer, "lgtm_required")
		if !is_required {
			is_required = task_concrete_reviewer_agent_instance_id(state) == reviewer
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
		if task_store_append_event(event) {
			_ = task_runtime_reconcile_task(state.task_id, "review_rotation", "high")
			task_notify_event(event)
		}
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
		if p.task_id != task_id do continue
		sent = task_notify_recipient(p.agent_instance_id, payload) || sent
	}
	return sent
}

task_notify_recipient_except :: proc(agent_instance_id, payload, skip_agent_instance_id: string) -> bool {
	if agent_instance_id == skip_agent_instance_id do return false
	return task_notify_recipient(agent_instance_id, payload)
}

task_notify_recipient_delivery_except :: proc(agent_instance_id, payload, skip_agent_instance_id: string) -> Task_Notification_Delivery {
	if agent_instance_id == skip_agent_instance_id do return Task_Notification_Delivery{}
	return task_notify_recipient_delivery(agent_instance_id, payload)
}

task_notify_recipient :: proc(agent_instance_id, payload: string) -> bool {
	return task_notify_recipient_delivery(agent_instance_id, payload).live_delivered
}

task_notify_recipient_delivery :: proc(agent_instance_id, payload: string) -> Task_Notification_Delivery {
	if agent_instance_id == "" do return Task_Notification_Delivery{failed = true}
	event_id := notification_outbox_insert_pending(agent_instance_id, payload)
	ok := registry_send_ws_text(agent_instance_id, payload)
	if event_id != "" {
		_ = notification_outbox_mark_attempt(agent_instance_id, event_id, ok)
	}
	queued := false
	if !ok && event_id != "" {
		queued = notification_outbox_pending_exists(agent_instance_id, event_id)
	}
	if !ok {
		if queued {
			fmt.printf("WARNING: failed to send WS to agent '%s'. Queued durable notification.\n", agent_instance_id)
		} else {
			fmt.printf("ERROR: failed to send WS to agent '%s' and durable queue is unavailable.\n", agent_instance_id)
		}
	}
	return Task_Notification_Delivery{live_delivered = ok, durable_queued = queued, failed = !ok && !queued}
}

task_notifications_flush_queue :: proc(agent_instance_id: string) {
	if agent_instance_id == "" do return
	delivered := notification_outbox_replay_pending(agent_instance_id)
	if delivered > 0 {
		fmt.printf("INFO: replayed %d durable task notifications to agent '%s'.\n", delivered, agent_instance_id)
	}
}

task_notify_nudge_delivery :: proc(event: Task_Event) -> Task_Notification_Delivery {
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
	// Manual/scheduled nudges are still task notifications; keep them
	// non-interrupting by default to avoid aborting active agent work.

	status := ev.status
	if ev.task_id != "" {
		idx   := task_state_index(ev.task_id, ev.chain_id)
		state := task_states[idx]
		if status == "" do status = task_status_to_string(state.status)
		payload := task_notification_json(ev, status)
		agent_payload := task_notification_agent_json(ev, status)
		user_client_fanout_all_ws_text(payload)
		return task_notify_recipient_delivery_except(ev.agent_instance_id, agent_payload, ev.author_agent_instance_id)
	}
	return Task_Notification_Delivery{failed = true}
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
		if chain, found := store_get_chain(event.chain_id); found {
			strings.write_string(&b, `,"chain":`)
			task_write_chain_json(&b, chain)
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
