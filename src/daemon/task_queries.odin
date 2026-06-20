package main

import "core:fmt"
import "core:strings"

// Returns the first non-archived agent_instance_id whose template role_hint matches.
// If project_id is non-empty, also requires a matching project.
agents_first_by_role_hint :: proc(role_hint, project_id: string) -> string {
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if project_id != "" && rec.project_id != project_id do continue
		tidx := agent_template_index(rec.template_id)
		if tidx < 0 do continue
		if agent_template_records[tidx].role_hint == role_hint do return rec.agent_instance_id
	}
	return ""
}

task_status_complete :: proc(status: string) -> bool {
	return status == "approved" || status == "done" || status == "completed" || status == "validated"
}

task_dependencies_satisfied :: proc(depends_on: string) -> bool {
	return task_dependency_blocking_ids(depends_on) == ""
}

task_state_satisfies_dependency :: proc(state: Task_State) -> bool {
	if state.status == "validated" || state.status == "completed" do return true
	if (state.status == "approved" || state.status == "done") && !task_state_has_reviewer_or_verifier(state) do return true
	return false
}

task_dependency_blocking_ids :: proc(depends_on: string) -> string {
	builder := strings.builder_make()
	first := true
	deps := strings.split(depends_on, ",")
	for dep in deps {
		id := strings.trim_space(dep)
		if id == "" do continue
		blocked := true
		for i in 0..<task_state_count {
			if task_states[i].task_id == id {
				blocked = !task_state_satisfies_dependency(task_states[i])
				break
			}
		}
		if blocked {
			if !first do strings.write_string(&builder, ",")
			first = false
			strings.write_string(&builder, id)
		}
	}
	return strings.to_string(builder)
}

task_auto_unblock_dependents :: proc(completed_task_id, author: string) -> int {
	return task_recompute_promotions(author)
}

task_recompute_promotions :: proc(author: string) -> int {
	changed := 0
	for i in 0..<task_state_count {
		state := task_states[i]
		if !task_promotion_candidate(state) do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		assignee := state.assignee_agent_instance_id
		status := "ready"
		body := "system_block:cleared"
		if assignee != "" {
			active_blocker := task_active_slot_blocker(assignee, state.task_id)
			if active_blocker != "" {
				status = "blocked"
				body = strings.concatenate({"system_block:assignee_active_task:", active_blocker})
			} else {
				best := task_best_promotion_candidate_for_assignee(assignee)
				if best != "" && best != state.task_id {
					status = "blocked"
					body = strings.concatenate({"system_block:assignee_active_task:", best})
				}
			}
		}
		if state.status == status && state.last_comment == body do continue
		event := Task_Event{kind = .Task_Status_Changed, task_id = state.task_id, chain_id = state.chain_id, status = status, body = body, author_agent_instance_id = author}
		if task_store_append_event(event) {
			task_notify_event(event)
			changed += 1
		}
	}
	return changed
}

task_promotion_candidate :: proc(state: Task_State) -> bool {
	if state.status == "pending" do return true
	if state.status != "blocked" do return false
	kind := task_system_block_kind(state)
	return kind == TASK_SYSTEM_BLOCK_DEPENDENCY || kind == TASK_SYSTEM_BLOCK_ASSIGNEE_ACTIVE
}

task_best_promotion_candidate_for_assignee :: proc(assignee: string) -> string {
	best_idx := -1
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.assignee_agent_instance_id != assignee do continue
		if !task_promotion_candidate(state) do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		if best_idx < 0 || task_state_orders_before(state, task_states[best_idx]) do best_idx = i
	}
	if best_idx < 0 do return ""
	return task_states[best_idx].task_id
}

task_state_orders_before :: proc(a, b: Task_State) -> bool {
	ap := task_priority_rank(a.priority)
	bp := task_priority_rank(b.priority)
	if ap != bp do return ap < bp
	if a.created_at_unix_ms != b.created_at_unix_ms do return a.created_at_unix_ms < b.created_at_unix_ms
	return a.task_id < b.task_id
}

task_priority_rank :: proc(priority: string) -> int {
	switch priority {
	case "P0", "p0", "urgent", "critical": return 0
	case "P1", "p1", "high": return 1
	case "P2", "p2", "normal", "": return 2
	case "P3", "p3", "low": return 3
	case: return 4
	}
}

task_depends_on_task :: proc(depends_on, task_id: string) -> bool {
	deps := strings.split(depends_on, ",")
	for dep in deps {
		if strings.trim_space(dep) == task_id do return true
	}
	return false
}

task_claim_next_for_agent :: proc(agent_instance_id: string) -> (Task_State, bool) {
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != "ready" do continue
		if state.assignee_agent_instance_id != "" && state.assignee_agent_instance_id != agent_instance_id do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		excluding := ""
		if state.assignee_agent_instance_id == agent_instance_id do excluding = state.task_id
		if task_active_slot_blocker(agent_instance_id, excluding) != "" do continue
		if state.assignee_agent_instance_id == "" {
			assign_event := Task_Event{kind = .Task_Assigned, task_id = state.task_id, chain_id = state.chain_id, agent_instance_id = agent_instance_id, role = "assignee", author_agent_instance_id = agent_instance_id}
			if !task_store_append_event(assign_event) do continue
		}
		event := Task_Event{kind = .Task_Status_Changed, task_id = state.task_id, chain_id = state.chain_id, status = "claimed", body = "claimed by agent", author_agent_instance_id = agent_instance_id}
		if task_store_append_event(event) {
			return task_states[task_state_index(state.task_id, state.chain_id)], true
		}
	}
	return Task_State{}, false
}

TASK_SYSTEM_BLOCK_DEPENDENCY :: "dependency"
TASK_SYSTEM_BLOCK_ASSIGNEE_ACTIVE :: "assignee_active_task"

task_system_block_kind :: proc(state: Task_State) -> string {
	if state.status != "blocked" do return ""
	if strings.has_prefix(state.last_comment, "system_block:dependency") do return TASK_SYSTEM_BLOCK_DEPENDENCY
	if strings.has_prefix(state.last_comment, "system_block:assignee_active_task") do return TASK_SYSTEM_BLOCK_ASSIGNEE_ACTIVE
	return "manual"
}

task_state_has_reviewer_or_verifier :: proc(state: Task_State) -> bool {
	if state.reviewer_agent_instance_id != "" do return true
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id) do continue
		if p.role == "reviewer" || p.role == "verifier" do return true
	}
	return false
}

task_status_active_for_assignee :: proc(state: Task_State) -> bool {
	switch state.status {
	case "ready", "claimed", "working", "in_progress", "open", "review", "needs_review", "needs_improvements", "rejected":
		return true
	case "approved", "done":
		return task_state_has_reviewer_or_verifier(state)
	case:
		return false
	}
}

task_active_slot_blocker :: proc(assignee, excluding_task_id: string) -> string {
	if assignee == "" do return ""
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.task_id == excluding_task_id do continue
		if state.assignee_agent_instance_id != assignee do continue
		if task_status_active_for_assignee(state) do return state.task_id
	}
	return ""
}

task_state_json :: proc(state: Task_State) -> string {
	builder := strings.builder_make()
	task_write_state_json(&builder, state)
	return strings.to_string(builder)
}

task_chain_state_json :: proc(chain: Task_Chain_State) -> string {
	builder := strings.builder_make()
	task_write_chain_json(&builder, chain)
	return strings.to_string(builder)
}

task_log_json :: proc(task_id: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"events":[`)
	first := true
	for i in 0..<task_event_count {
		event := task_events[i]
		if event.task_id != task_id do continue
		if !first do strings.write_string(&builder, `,`)
		first = false
		strings.write_string(&builder, task_event_json(event))
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

task_write_state_json :: proc(builder: ^strings.Builder, state: Task_State) {
	strings.write_string(builder, `{"task_id":"`); json_write_string(builder, state.task_id)
	strings.write_string(builder, `","chain_id":"`); json_write_string(builder, state.chain_id)
	strings.write_string(builder, `","title":"`); json_write_string(builder, state.title)
	strings.write_string(builder, `","description":"`); json_write_string(builder, state.description)
	strings.write_string(builder, `","acceptance_criteria":"`); json_write_string(builder, state.acceptance_criteria)
	strings.write_string(builder, `","priority":"`); json_write_string(builder, state.priority)
	strings.write_string(builder, `","status":"`); json_write_string(builder, state.status)
	strings.write_string(builder, `","assignee_agent_instance_id":"`); json_write_string(builder, state.assignee_agent_instance_id)
	strings.write_string(builder, `","reviewer_agent_instance_id":"`); json_write_string(builder, state.reviewer_agent_instance_id)
	strings.write_string(builder, `","coordinator_agent_instance_id":"`); json_write_string(builder, state.coordinator_agent_instance_id)
	strings.write_string(builder, `","depends_on":"`); json_write_string(builder, state.depends_on)
	strings.write_string(builder, `","created_by":"`); json_write_string(builder, state.created_by)
	strings.write_string(builder, `","created_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", state.created_at_unix_ms))
	strings.write_string(builder, `,"updated_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", state.updated_at_unix_ms))
	strings.write_string(builder, `}`)
}

task_write_chain_json :: proc(builder: ^strings.Builder, chain: Task_Chain_State) {
	strings.write_string(builder, `{"chain_id":"`); json_write_string(builder, chain.chain_id)
	strings.write_string(builder, `","title":"`); json_write_string(builder, chain.title)
	strings.write_string(builder, `","description":"`); json_write_string(builder, chain.description)
	strings.write_string(builder, `","status":"`); json_write_string(builder, chain.status)
	strings.write_string(builder, `","coordinator_agent_instance_id":"`); json_write_string(builder, chain.coordinator_agent_instance_id)
	strings.write_string(builder, `","default_reviewer_agent_instance_id":"`); json_write_string(builder, chain.default_reviewer_agent_instance_id)
	strings.write_string(builder, `","final_summary":"`); json_write_string(builder, chain.final_summary)
	strings.write_string(builder, `","created_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", chain.created_at_unix_ms))
	strings.write_string(builder, `,"completed_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", chain.completed_at_unix_ms))
	strings.write_string(builder, `,"archive_pending":`); strings.write_string(builder, "true" if chain.archive_pending else "false")
	strings.write_string(builder, `,"archived":`); strings.write_string(builder, "true" if chain.archived else "false")
	strings.write_string(builder, `}`)
}
