package main

import "core:strings"

task_projection_reset :: proc() {
	task_state_count = 0
	task_participant_count = 0
	task_chain_count = 0
}

task_projection_apply_event :: proc(event: Task_Event) -> bool {
	#partial switch event.kind {
	case .Task_Created:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].title = strings.clone(event.title)
		task_states[idx].description = strings.clone(event.description)
		task_states[idx].acceptance_criteria = strings.clone(event.acceptance_criteria)
		task_states[idx].priority = strings.clone(event.priority)
		if event.status != "" do task_states[idx].status = strings.clone(event.status)
		task_states[idx].assignee_agent_instance_id = strings.clone(event.assignee_agent_instance_id)
		task_states[idx].assigned_agent_instance_id = strings.clone(event.assignee_agent_instance_id)
		task_states[idx].reviewer_agent_instance_id = strings.clone(event.reviewer_agent_instance_id)
		task_states[idx].coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id)
		task_states[idx].depends_on = strings.clone(event.depends_on)
		task_states[idx].created_by = strings.clone(event.created_by)
		task_states[idx].created_at_unix_ms = event.created_unix_ms
		task_states[idx].updated_at_unix_ms = event.created_unix_ms
		if event.assignee_agent_instance_id != "" do task_store_upsert_participant(event.task_id, event.chain_id, event.assignee_agent_instance_id, "assignee")
		if event.reviewer_agent_instance_id != "" do task_store_upsert_participant(event.task_id, event.chain_id, event.reviewer_agent_instance_id, "reviewer")
		if event.coordinator_agent_instance_id != "" do task_store_upsert_participant(event.task_id, event.chain_id, event.coordinator_agent_instance_id, "coordinator")
	case .Task_Comment:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].last_comment = strings.clone(event.body)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms
	case .Task_Status_Changed:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].status = strings.clone(event.status)
		task_states[idx].last_comment = strings.clone(event.body)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms
	case .Task_Assigned:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].assignee_agent_instance_id = strings.clone(event.agent_instance_id)
		task_states[idx].assigned_agent_instance_id = strings.clone(event.agent_instance_id)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms
		task_store_upsert_participant(event.task_id, event.chain_id, event.agent_instance_id, "assignee")
	case .Task_Participant_Added:
		task_store_upsert_participant(event.task_id, event.chain_id, event.agent_instance_id, event.role)
	case .Task_Review_Submitted:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].status = strings.clone(event.status)
		task_states[idx].last_comment = strings.clone(event.body)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms
	case .Chain_Created:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].title = strings.clone(event.title)
		task_chains[idx].description = strings.clone(event.description)
		if event.status != "" do task_chains[idx].status = strings.clone(event.status)
		task_chains[idx].coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id)
		task_chains[idx].default_reviewer_agent_instance_id = strings.clone(event.default_reviewer_agent_instance_id)
		task_chains[idx].created_at_unix_ms = event.created_unix_ms
	case .Chain_Status_Changed:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].status = strings.clone(event.status)
	case .Chain_Final_Summary_Set:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].final_summary = strings.clone(event.body)
	case .Chain_Completed:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].status = "completed"
		task_chains[idx].final_summary = strings.clone(event.body)
		task_chains[idx].completed_at_unix_ms = event.created_unix_ms
	case .Chain_Archive_Pending:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].archive_pending = true
	case .Chain_Archived:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].status = "archived"
		task_chains[idx].archived = true
		task_chains[idx].archive_pending = false
		if task_chains[idx].completed_at_unix_ms == 0 do task_chains[idx].completed_at_unix_ms = event.created_unix_ms
	}
	return true
}

task_store_retry_pending_archives :: proc() -> int {
	retried := 0
	for i in 0..<task_chain_count {
		chain := task_chains[i]
		if chain.archive_pending && hub_adapter_config.enabled {
			if task_archive_chain_to_hub(chain.chain_id) do retried += 1
		}
	}
	return retried
}

task_store_mark_archive_pending :: proc(chain_id, reason: string) -> bool {
	idx := task_chain_index(chain_id)
	if task_chains[idx].archive_pending do return true
	return task_store_append_event(Task_Event{kind = .Chain_Archive_Pending, chain_id = chain_id, body = reason})
}

task_store_upsert_participant :: proc(task_id, chain_id, agent_instance_id, role: string) {
	if agent_instance_id == "" do return
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id == task_id && p.agent_instance_id == agent_instance_id && p.role == role do return
	}
	if task_participant_count >= TASK_MAX_PARTICIPANTS do return
	task_participants[task_participant_count] = Task_Participant{task_id = strings.clone(task_id), chain_id = strings.clone(chain_id), agent_instance_id = strings.clone(agent_instance_id), role = strings.clone(role)}
	task_participant_count += 1
}

task_state_index :: proc(task_id, chain_id: string) -> int {
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id do return i
	}
	idx := task_state_count
	if idx >= TASK_MAX_TASKS do return TASK_MAX_TASKS - 1
	task_state_count += 1
	task_states[idx] = Task_State{task_id = strings.clone(task_id), chain_id = strings.clone(chain_id), status = "pending"}
	return idx
}

task_chain_index :: proc(chain_id: string) -> int {
	for i in 0..<task_chain_count {
		if task_chains[i].chain_id == chain_id do return i
	}
	idx := task_chain_count
	if idx >= TASK_MAX_CHAINS do return TASK_MAX_CHAINS - 1
	task_chain_count += 1
	task_chains[idx] = Task_Chain_State{chain_id = strings.clone(chain_id), status = "active"}
	return idx
}
