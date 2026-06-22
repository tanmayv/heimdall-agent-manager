package main

import "core:fmt"
import "core:strings"

task_projection_reset :: proc() {
	task_state_count       = 0
	task_participant_count = 0
	task_chain_count       = 0
	task_comment_count     = 0
	task_lgtm_vote_count   = 0
}

task_projection_apply_event :: proc(event: Task_Event) -> bool {
	#partial switch event.kind {
	case .Task_Created:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].title                       = strings.clone(event.title)
		task_states[idx].description                 = strings.clone(event.description)
		task_states[idx].acceptance_criteria         = strings.clone(event.acceptance_criteria)
		task_states[idx].priority                    = strings.clone(event.priority)
		if event.status != "" do task_states[idx].status = strings.clone(event.status)
		task_states[idx].assignee_agent_instance_id  = strings.clone(event.assignee_agent_instance_id)
		task_states[idx].coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id)
		task_states[idx].depends_on                  = strings.clone(event.depends_on)
		task_states[idx].created_by                  = strings.clone(event.created_by)
		task_states[idx].created_at_unix_ms          = event.created_unix_ms
		task_states[idx].updated_at_unix_ms          = event.created_unix_ms
		if event.assignee_agent_instance_id != "" {
			task_store_upsert_participant(event.task_id, event.chain_id, event.assignee_agent_instance_id, "assignee")
		}
		if event.coordinator_agent_instance_id != "" {
			task_store_upsert_participant(event.task_id, event.chain_id, event.coordinator_agent_instance_id, "coordinator")
		}

	case .Task_Comment:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms
		comment_id := event.comment_id
		if comment_id == "" do comment_id = event.event_id
		task_store_append_comment(Task_Comment_State{
			comment_id               = strings.clone(comment_id),
			task_id                  = strings.clone(event.task_id),
			chain_id                 = strings.clone(event.chain_id),
			body                     = strings.clone(event.body),
			author_agent_instance_id = strings.clone(event.author_agent_instance_id),
			resolved                 = false,
			created_unix_ms          = event.created_unix_ms,
		})

	case .Task_Comment_Resolved:
		for i in 0..<task_comment_count {
			if task_comments[i].comment_id == event.comment_id && task_comments[i].task_id == event.task_id {
				task_comments[i].resolved = true
				break
			}
		}

	case .Task_Status_Changed:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].status             = strings.clone(event.status)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms

	case .Task_Assigned:
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].assignee_agent_instance_id = strings.clone(event.agent_instance_id)
		task_states[idx].updated_at_unix_ms         = event.created_unix_ms
		task_store_upsert_participant(event.task_id, event.chain_id, event.agent_instance_id, "assignee")

	case .Task_Participant_Added:
		task_store_upsert_participant(event.task_id, event.chain_id, event.agent_instance_id, event.role)

	case .Task_Review_Vote:
		task_store_upsert_lgtm_vote(Task_LGTM_Vote_State{
			task_id                    = strings.clone(event.task_id),
			chain_id                   = strings.clone(event.chain_id),
			reviewer_agent_instance_id = strings.clone(event.author_agent_instance_id),
			approved                   = event.vote_approved == "true",
			role                       = strings.clone(event.role),
			comment                    = strings.clone(event.body),
			created_unix_ms            = event.created_unix_ms,
		})
		idx := task_state_index(event.task_id, event.chain_id)
		task_states[idx].updated_at_unix_ms = event.created_unix_ms

	case .Chain_Created:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].project_id                    = strings.clone(event.project_id)
		task_chains[idx].title                         = strings.clone(event.title)
		task_chains[idx].description                   = strings.clone(event.description)
		if event.status != "" do task_chains[idx].status = strings.clone(event.status)
		task_chains[idx].coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id)
		task_chains[idx].created_at_unix_ms            = event.created_unix_ms

	case .Chain_Metadata_Updated:
		idx := task_chain_index(event.chain_id)
		if event.title != "" do task_chains[idx].title = strings.clone(event.title)
		if event.description != "" do task_chains[idx].description = strings.clone(event.description)
		if event.coordinator_agent_instance_id != "" {
			task_chains[idx].coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id)
		}

	case .Chain_Status_Changed:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].status = strings.clone(event.status)

	case .Chain_Final_Summary_Set:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].final_summary = strings.clone(event.body)

	case .Chain_Completed:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].status               = "completed"
		task_chains[idx].final_summary        = strings.clone(event.body)
		task_chains[idx].completed_at_unix_ms = event.created_unix_ms

	case .Chain_Archive_Pending:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].archive_pending = true

	case .Chain_Archived:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].status          = "archived"
		task_chains[idx].archived        = true
		task_chains[idx].archive_pending = false
		if task_chains[idx].completed_at_unix_ms == 0 {
			task_chains[idx].completed_at_unix_ms = event.created_unix_ms
		}

	case .Chain_Evaluated:
		idx := task_chain_index(event.chain_id)
		task_chains[idx].evaluation = strings.clone(event.body)
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
	task_participants[task_participant_count] = Task_Participant{
		task_id           = strings.clone(task_id),
		chain_id          = strings.clone(chain_id),
		agent_instance_id = strings.clone(agent_instance_id),
		role              = strings.clone(role),
	}
	task_participant_count += 1
}

task_store_append_comment :: proc(c: Task_Comment_State) {
	if task_comment_count >= TASK_MAX_COMMENTS do return
	task_comments[task_comment_count] = c
	task_comment_count += 1
}

task_store_upsert_lgtm_vote :: proc(vote: Task_LGTM_Vote_State) {
	for i in 0..<task_lgtm_vote_count {
		v := &task_lgtm_votes[i]
		if v.task_id == vote.task_id && v.reviewer_agent_instance_id == vote.reviewer_agent_instance_id {
			v.approved         = vote.approved
			v.comment          = strings.clone(vote.comment)
			v.created_unix_ms  = vote.created_unix_ms
			return
		}
	}
	if task_lgtm_vote_count >= TASK_MAX_VOTES do return
	task_lgtm_votes[task_lgtm_vote_count] = Task_LGTM_Vote_State{
		task_id                    = strings.clone(vote.task_id),
		chain_id                   = strings.clone(vote.chain_id),
		reviewer_agent_instance_id = strings.clone(vote.reviewer_agent_instance_id),
		approved                   = vote.approved,
		role                       = strings.clone(vote.role),
		comment                    = strings.clone(vote.comment),
		created_unix_ms            = vote.created_unix_ms,
	}
	task_lgtm_vote_count += 1
}

task_state_index :: proc(task_id, chain_id: string) -> int {
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id do return i
	}
	idx := task_state_count
	if idx >= TASK_MAX_TASKS do return TASK_MAX_TASKS - 1
	task_state_count += 1
	task_states[idx] = Task_State{task_id = strings.clone(task_id), chain_id = strings.clone(chain_id), status = "planning"}
	return idx
}

task_chain_index :: proc(chain_id: string) -> int {
	for i in 0..<task_chain_count {
		if task_chains[i].chain_id == chain_id do return i
	}
	idx := task_chain_count
	if idx >= TASK_MAX_CHAINS do return TASK_MAX_CHAINS - 1
	task_chain_count += 1
	task_chains[idx] = Task_Chain_State{chain_id = strings.clone(chain_id), status = "planning", evaluation = strings.clone("unreviewed")}
	return idx
}

task_write_chain_json :: proc(builder: ^strings.Builder, chain: Task_Chain_State) {
	strings.write_string(builder, `{"chain_id":"`);      json_write_string(builder, chain.chain_id)
	strings.write_string(builder, `","project_id":"`);   json_write_string(builder, chain.project_id)
	strings.write_string(builder, `","title":"`);        json_write_string(builder, chain.title)
	strings.write_string(builder, `","description":"`);  json_write_string(builder, chain.description)
	strings.write_string(builder, `","status":"`);       json_write_string(builder, chain.status)
	strings.write_string(builder, `","coordinator_agent_instance_id":"`); json_write_string(builder, chain.coordinator_agent_instance_id)
	strings.write_string(builder, `","final_summary":"`); json_write_string(builder, chain.final_summary)
	strings.write_string(builder, `","created_at_unix_ms":`);   strings.write_string(builder, fmt.tprintf("%d", chain.created_at_unix_ms))
	strings.write_string(builder, `,"completed_at_unix_ms":`);  strings.write_string(builder, fmt.tprintf("%d", chain.completed_at_unix_ms))
	strings.write_string(builder, `,"archive_pending":`); strings.write_string(builder, "true" if chain.archive_pending else "false")
	strings.write_string(builder, `,"archived":`);        strings.write_string(builder, "true" if chain.archived else "false")
	strings.write_string(builder, `,"evaluation":"`);     json_write_string(builder, chain.evaluation)
	strings.write_string(builder, `","last_audit_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", chain.last_audit_at_unix_ms))
	strings.write_string(builder, `}`)
}
