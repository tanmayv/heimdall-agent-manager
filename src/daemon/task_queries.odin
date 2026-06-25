package main

import "core:fmt"
import "core:strings"

// Returns the first non-archived agent_instance_id whose template role_hint matches.
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

// --- Status predicates ---

task_status_allowed :: proc(status: string) -> bool {
	_, ok := task_status_from_string(status)
	return ok
}

task_status_terminal :: proc(status: Task_Status) -> bool {
	return status == .Approved || status == .Cancelled
}

task_status_active_for_assignee :: proc(state: Task_State) -> bool {
	#partial switch state.status {
	case .In_Progress, .Review_Ready:
		return true
	case:
		return false
	}
}

task_status_complete :: proc(status: Task_Status) -> bool {
	return status == .Approved
}

task_state_satisfies_dependency :: proc(state: Task_State) -> bool {
	return state.status == .Approved
}

// --- Dependency helpers ---

task_dependencies_satisfied :: proc(depends_on: string) -> bool {
	return task_dependency_blocking_ids(depends_on) == ""
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

task_depends_on_task :: proc(depends_on, task_id: string) -> bool {
	deps := strings.split(depends_on, ",")
	for dep in deps {
		if strings.trim_space(dep) == task_id do return true
	}
	return false
}

task_coordinator_agent_instance_id :: proc(state: Task_State) -> string {
	if state.chain_id == "" do return ""
	idx, found := task_existing_chain_index(state.chain_id)
	if !found do return ""
	return task_chains[idx].coordinator_agent_instance_id
}

task_chain_default_reviewer_agent_instance_id :: proc(chain_id: string) -> string {
	if chain_id == "" do return ""
	idx, found := task_existing_chain_index(chain_id)
	if !found do return ""
	return task_chains[idx].default_reviewer_agent_instance_id
}

task_reviewer_agent_instance_id :: proc(state: Task_State) -> string {
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id == state.task_id && p.role == "lgtm_required" {
			return p.agent_instance_id
		}
	}
	default_rev := task_chain_default_reviewer_agent_instance_id(state.chain_id)
	if default_rev != "" && default_rev != state.assignee_agent_instance_id {
		return default_rev
	}
	return "operator@local"
}

// --- Active slot checks ---

// Returns the task_id that blocks the assignee from taking another task (excludes excluding_task_id).
task_active_slot_blocker :: proc(assignee, excluding_task_id: string) -> string {
	if assignee == "" do return ""

	// Reviewer gating constraint: pending reviews block new tasks
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .Review_Ready do continue
		if !task_actor_has_role(state, assignee, "lgtm_required") do continue
		if task_reviewer_has_voted(state.task_id, assignee) do continue
		return "pending_reviews_exist"
	}

	for i in 0..<task_state_count {
		state := task_states[i]
		if state.task_id == excluding_task_id do continue
		if state.assignee_agent_instance_id != assignee do continue
		if task_status_active_for_assignee(state) do return state.task_id
	}
	return ""
}

// Returns the task_id that is currently in review_ready and the reviewer hasn't voted on yet
// (excluding excluding_task_id). Used to enforce one-active-review constraint.
task_reviewer_active_slot_blocker :: proc(reviewer, excluding_task_id: string) -> string {
	if reviewer == "" do return ""
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.task_id == excluding_task_id do continue
		if state.status != .Review_Ready do continue
		if !task_actor_has_role(state, reviewer, "lgtm_required") && !task_actor_has_role(state, reviewer, "lgtm_optional") do continue
		if task_reviewer_has_voted(state.task_id, reviewer) do continue
		return state.task_id
	}
	return ""
}

task_reviewer_has_voted :: proc(task_id, reviewer: string) -> bool {
	for i in 0..<task_lgtm_vote_count {
		v := task_lgtm_votes[i]
		if v.task_id == task_id && v.reviewer_agent_instance_id == reviewer do return true
	}
	return false
}

// --- LGTM checks ---

task_all_required_lgtms_approved :: proc(task_id: string) -> bool {
	required_count := 0
	approved_count := 0
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id != task_id || p.role != "lgtm_required" do continue
		required_count += 1
		for j in 0..<task_lgtm_vote_count {
			v := task_lgtm_votes[j]
			if v.task_id == task_id && v.reviewer_agent_instance_id == p.agent_instance_id && v.approved {
				approved_count += 1
				break
			}
		}
	}
	if required_count == 0 {
		idx, found := task_existing_state_index(task_id, "")
		if found {
			default_rev := task_reviewer_agent_instance_id(task_states[idx])
			if default_rev != "" {
				required_count = 1
				for j in 0..<task_lgtm_vote_count {
					v := task_lgtm_votes[j]
					if v.task_id == task_id && v.reviewer_agent_instance_id == default_rev && v.approved {
						approved_count = 1
						break
					}
				}
			}
		}
	}
	return required_count > 0 && approved_count == required_count
}

// --- Chain queries ---

task_chain_allows_execution :: proc(chain_id: string) -> bool {
	if chain_id == "" do return true
	idx, found := task_existing_chain_index(chain_id)
	if !found do return true
	return task_chains[idx].status == "in_progress"
}

task_active_chain_for_project :: proc(project_id: string) -> string {
	if project_id == "" do return ""
	for i in 0..<task_chain_count {
		c := task_chains[i]
		if c.project_id != project_id do continue
		if c.status == "planning" || c.status == "in_progress" || c.status == "blocked" || c.status == "paused" {
			return c.chain_id
		}
	}
	return ""
}

task_all_chain_tasks_terminal :: proc(chain_id: string) -> bool {
	found_any := false
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.chain_id != chain_id do continue
		found_any = true
		if !task_status_terminal(state.status) do return false
	}
	return found_any
}

// --- Role / authorization helpers ---

task_actor_is_user :: proc(actor: string) -> bool {
	return actor != "" && !registry_agent_exists(actor)
}

task_actor_has_role :: proc(state: Task_State, actor, role: string) -> bool {
	if actor == "" do return false
	switch role {
	case "assignee":
		if state.assignee_agent_instance_id == actor do return true
	case "coordinator":
		if task_coordinator_agent_instance_id(state) == actor do return true
	case:
	}
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.role != role || p.agent_instance_id != actor do continue
		if p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id) do continue
		return true
	}
	return false
}

task_actor_can_override :: proc(state: Task_State, actor: string) -> bool {
	return task_actor_is_user(actor) || task_actor_has_role(state, actor, "coordinator")
}

task_status_change_authorized :: proc(state: Task_State, next_status: Task_Status, actor: string) -> bool {
	if task_actor_can_override(state, actor) do return true
	switch next_status {
	case .Queued, .In_Progress, .Review_Ready, .Blocked:
		return task_actor_has_role(state, actor, "assignee")
	case .Cancelled, .Approved, .Planning:
		return false
	}
	return false
}

// --- Target routing ---

task_nudge_target_for_status :: proc(state: Task_State, status: Task_Status) -> string {
	#partial switch status {
	case .Queued, .In_Progress, .Blocked:
		return task_target_for_role(state, "assignee")
	case .Review_Ready:
		reviewer := task_reviewer_agent_instance_id(state)
		if reviewer != "operator@local" do return reviewer
		return task_target_for_role(state, "lgtm_required")
	case .Approved:
		return task_target_for_role(state, "coordinator")
	case:
		target := task_target_for_role(state, "assignee")
		if target != "" do return target
		return task_target_for_role(state, "coordinator")
	}
}

task_target_for_role :: proc(state: Task_State, role: string) -> string {
	switch role {
	case "assignee":
		if state.assignee_agent_instance_id != "" do return state.assignee_agent_instance_id
	case "coordinator":
		coord := task_coordinator_agent_instance_id(state)
		if coord != "" do return coord
	case:
	}
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.role != role do continue
		if p.task_id != state.task_id && (state.chain_id == "" || p.chain_id != state.chain_id) do continue
		return p.agent_instance_id
	}
	return ""
}

// --- Auto-promotion ---

task_recompute_promotions :: proc(author: string) -> int {
	changed := 0
	for i in 0..<task_state_count {
		state := task_states[i]
		if !task_promotion_candidate(state) do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		if !task_chain_allows_execution(state.chain_id) do continue
		assignee := state.assignee_agent_instance_id
		status := "queued"
		body := "system_auto:deps_cleared"
		if assignee != "" {
			active_blocker := task_active_slot_blocker(assignee, state.task_id)
			if active_blocker != "" {
				body = strings.concatenate({"system_queue:assignee_busy:", active_blocker})
			} else {
				best := task_best_promotion_candidate_for_assignee(assignee)
				if best != "" && best != state.task_id {
					body = strings.concatenate({"system_queue:assignee_busy:", best})
				}
			}
		}
		status_val, _ := task_status_from_string(status)
		if state.status == status_val do continue
		event := Task_Event{
			kind                     = .Task_Status_Changed,
			task_id                  = state.task_id,
			chain_id                 = state.chain_id,
			status                   = status,
			body                     = body,
			author_agent_instance_id = author,
		}
		if task_store_append_event(event) {
			task_notify_event(event)
			changed += 1
			if status == "queued" {
				task_service_auto_claim(state.task_id)
			}
		}
	}

	// Trigger auto-claim for Ready tasks if the assignee's slot became free
	for i in 0..<task_state_count {
		assignee := task_states[i].assignee_agent_instance_id
		if assignee == "" do continue
		active := task_active_slot_blocker(assignee, "")
		if active == "" {
			best_ready := task_best_ready_task_for_assignee(assignee)
			if best_ready != "" {
				task_service_auto_claim(best_ready)
			}
		}
	}

	return changed
}

task_promotion_candidate :: proc(state: Task_State) -> bool {
	if state.status == .Planning do return true
	if state.status != .Blocked do return false
	return task_system_block_kind(state) == TASK_SYSTEM_BLOCK_DEPENDENCY ||
	       task_system_block_kind(state) == TASK_SYSTEM_BLOCK_ASSIGNEE_ACTIVE
}

task_best_promotion_candidate_for_assignee :: proc(assignee: string) -> string {
	best_idx := -1
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.assignee_agent_instance_id != assignee do continue
		if !task_promotion_candidate(state) do continue
		if !task_dependencies_satisfied(state.depends_on) do continue
		if !task_chain_allows_execution(state.chain_id) do continue
		if best_idx < 0 || task_state_orders_before(state, task_states[best_idx]) do best_idx = i
	}
	if best_idx < 0 do return ""
	return task_states[best_idx].task_id
}

task_best_ready_task_for_assignee :: proc(assignee: string) -> string {
	best_idx := -1
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.assignee_agent_instance_id != assignee do continue
		if state.status != .Queued do continue
		if !task_chain_allows_execution(state.chain_id) do continue
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
	case "P1", "p1", "high":               return 1
	case "P2", "p2", "normal", "":         return 2
	case "P3", "p3", "low":                return 3
	case:                                   return 4
	}
}

TASK_SYSTEM_BLOCK_DEPENDENCY     :: "dependency"
TASK_SYSTEM_BLOCK_ASSIGNEE_ACTIVE :: "assignee_active_task"

task_system_block_kind :: proc(state: Task_State) -> string {
	if state.status != .Blocked do return ""
	// The block kind is stored in the last status-change comment body
	for i := task_event_count - 1; i >= 0; i -= 1 {
		ev := task_events[i]
		if ev.task_id != state.task_id || ev.kind != .Task_Status_Changed || ev.status != "blocked" do continue
		if strings.has_prefix(ev.body, "system_block:dependency") do return TASK_SYSTEM_BLOCK_DEPENDENCY
		if strings.has_prefix(ev.body, "system_block:assignee_active_task") do return TASK_SYSTEM_BLOCK_ASSIGNEE_ACTIVE
		return "manual"
	}
	return "manual"
}

task_latest_status_body :: proc(task_id: string) -> string {
	for i := task_event_count - 1; i >= 0; i -= 1 {
		ev := task_events[i]
		if ev.task_id != task_id || ev.kind != .Task_Status_Changed do continue
		return ev.body
	}
	return ""
}

task_chain_status_for_task :: proc(state: Task_State) -> string {
	if state.chain_id == "" do return ""
	idx, found := task_existing_chain_index(state.chain_id)
	if !found do return ""
	return task_chains[idx].status
}

task_not_actionable_reason :: proc(state: Task_State) -> string {
	chain_status := task_chain_status_for_task(state)
	if chain_status != "" && chain_status != "in_progress" {
		return strings.concatenate({"chain_", chain_status})
	}
	#partial switch state.status {
	case .Planning:
		return "waiting_for_promotion"
	case .Queued:
		if dep := task_dependency_blocking_ids(state.depends_on); dep != "" {
			return strings.concatenate({"deps_unmet:", dep})
		}
		if state.assignee_agent_instance_id == "" do return "unassigned"
		if blocker := task_active_slot_blocker(state.assignee_agent_instance_id, state.task_id); blocker != "" {
			if blocker == "pending_reviews_exist" do return "assignee_pending_review"
			return strings.concatenate({"assignee_busy:", blocker})
		}
		if best := task_best_promotion_candidate_for_assignee(state.assignee_agent_instance_id); best != "" && best != state.task_id {
			return strings.concatenate({"queued_behind:", best})
		}
		return "queued"
	case .In_Progress:
		return ""
	case .Review_Ready:
		reviewer := task_reviewer_agent_instance_id(state)
		if reviewer == "operator@local" do return "awaiting_user_review"
		if blocker := task_reviewer_active_slot_blocker(reviewer, state.task_id); blocker != "" {
			return strings.concatenate({"reviewer_busy:", blocker})
		}
		return strings.concatenate({"awaiting_review:", reviewer})
	case .Blocked:
		if dep := task_dependency_blocking_ids(state.depends_on); dep != "" {
			return strings.concatenate({"deps_unmet:", dep})
		}
		body := task_latest_status_body(state.task_id)
		if body != "" do return body
		return "manual_block"
	case .Approved:
		return "approved"
	case .Cancelled:
		return "cancelled"
	case:
		return ""
	}
}

// --- Comment queries ---

task_unresolved_comments :: proc(task_id: string) -> []Task_Comment_State {
	result := make([dynamic]Task_Comment_State)
	for i in 0..<task_comment_count {
		c := task_comments[i]
		if c.task_id == task_id && !c.resolved do append(&result, c)
	}
	return result[:]
}

// --- JSON serialization ---

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
	unresolved := task_unresolved_comments(state.task_id)
	defer delete(unresolved)
	strings.write_string(builder, `{"task_id":"`);            json_write_string(builder, state.task_id)
	strings.write_string(builder, `","chain_id":"`);          json_write_string(builder, state.chain_id)
	strings.write_string(builder, `","title":"`);             json_write_string(builder, state.title)
	strings.write_string(builder, `","description":"`);       json_write_string(builder, state.description)
	strings.write_string(builder, `","acceptance_criteria":"`); json_write_string(builder, state.acceptance_criteria)
	strings.write_string(builder, `","priority":"`);          json_write_string(builder, state.priority)
	strings.write_string(builder, `","status":"`);            json_write_string(builder, task_status_to_string(state.status))
	strings.write_string(builder, `","assignee_agent_instance_id":"`); json_write_string(builder, state.assignee_agent_instance_id)
	strings.write_string(builder, `","coordinator_agent_instance_id":"`); json_write_string(builder, task_coordinator_agent_instance_id(state))
	strings.write_string(builder, `","reviewer_agent_instance_id":"`); json_write_string(builder, task_reviewer_agent_instance_id(state))
	strings.write_string(builder, `","depends_on":"`);        json_write_string(builder, state.depends_on)
	strings.write_string(builder, `","created_by":"`);        json_write_string(builder, state.created_by)
	strings.write_string(builder, `","created_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", state.created_at_unix_ms))
	strings.write_string(builder, `,"updated_at_unix_ms":`);  strings.write_string(builder, fmt.tprintf("%d", state.updated_at_unix_ms))
	strings.write_string(builder, `,"not_actionable_reason":"`); json_write_string(builder, task_not_actionable_reason(state))
	strings.write_string(builder, `","unresolved_comment_count":`); strings.write_string(builder, fmt.tprintf("%d", len(unresolved)))
	
	strings.write_string(builder, `,"unresolved_comments":[`)
	for c, idx in unresolved {
		if idx > 0 do strings.write_string(builder, `,`)
		strings.write_string(builder, `{"comment_id":"`)
		json_write_string(builder, c.comment_id)
		strings.write_string(builder, `","body":"`)
		json_write_string(builder, c.body)
		strings.write_string(builder, `","author_agent_instance_id":"`)
		json_write_string(builder, c.author_agent_instance_id)
		strings.write_string(builder, `"}`)
	}
	strings.write_string(builder, `]`)

	// Serialize participants list
	strings.write_string(builder, `,"participants":[`)
	first_part := true
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id == state.task_id {
			if !first_part do strings.write_string(builder, `,`)
			first_part = false
			strings.write_string(builder, `{"agent_instance_id":"`)
			json_write_string(builder, p.agent_instance_id)
			strings.write_string(builder, `","role":"`)
			json_write_string(builder, p.role)
			strings.write_string(builder, `"}`)
		}
	}
	strings.write_string(builder, `]`)

	strings.write_string(builder, `,"votes":[`)
	first_vote := true
	for i in 0..<task_lgtm_vote_count {
		v := task_lgtm_votes[i]
		if v.task_id == state.task_id {
			if !first_vote do strings.write_string(builder, `,`)
			first_vote = false
			strings.write_string(builder, `{"reviewer_agent_instance_id":"`)
			json_write_string(builder, v.reviewer_agent_instance_id)
			strings.write_string(builder, `","approved":`)
			strings.write_string(builder, "true" if v.approved else "false")
			strings.write_string(builder, `,"comment":"`)
			json_write_string(builder, v.comment)
			strings.write_string(builder, `"}`)
		}
	}
	strings.write_string(builder, `]}`)
}

task_existing_state_index :: proc(task_id, chain_id: string) -> (int, bool) {
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id && (chain_id == "" || task_states[i].chain_id == chain_id) {
			return i, true
		}
	}
	return -1, false
}

task_existing_chain_index :: proc(chain_id: string) -> (int, bool) {
	for i in 0..<task_chain_count {
		if task_chains[i].chain_id == chain_id do return i, true
	}
	return -1, false
}

task_id_exists :: proc(task_id: string) -> bool {
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id do return true
	}
	return false
}

task_chain_id_exists :: proc(chain_id: string) -> bool {
	for i in 0..<task_chain_count {
		if task_chains[i].chain_id == chain_id do return true
	}
	return false
}

task_generate_id :: proc() -> string {
	base := router_now_unix_ms()
	for i in 0..<1000 {
		candidate := fmt.tprintf("task-%x", base + i64(i))
		if !task_id_exists(candidate) do return candidate
	}
	return fmt.tprintf("task-%x", router_now_unix_ms())
}

task_generate_chain_id :: proc() -> string {
	base := router_now_unix_ms()
	for i in 0..<1000 {
		candidate := fmt.tprintf("chain-%x", base + i64(i))
		if !task_chain_id_exists(candidate) do return candidate
	}
	return fmt.tprintf("chain-%x", router_now_unix_ms())
}

task_chain_id_for_root :: proc(task_id: string) -> string {
	if strings.has_prefix(task_id, "task-") do return fmt.tprintf("chain-%s", task_id[len("task-"):])
	return fmt.tprintf("chain-%s", task_id)
}

task_root_id_for_response :: proc(chain_id, task_id: string, created_chain: bool) -> string {
	if chain_id == "" do return ""
	if created_chain do return task_id
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.chain_id == chain_id do return state.task_id
	}
	return ""
}
