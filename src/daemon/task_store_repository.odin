package main

// Task Store Repository (Phase 0 of docs/plans/task-store-repository.md)
//
// This module introduces the intention-revealing query/mutation API that will
// eventually be the SOLE owner of the six task-store arrays and their manual
// `_count` variables (task_events, task_states, task_participants, task_chains,
// task_comments, task_lgtm_votes).
//
// Phase 0 intentionally makes these thin wrappers over the existing globals so
// the surface can be introduced and tested with ZERO behavior change and ZERO
// call-site churn. Later phases migrate call sites onto these accessors and then
// make each underlying array/count private to this module.
//
// Invariant (enforced incrementally): only the mutation functions here touch the
// arrays/counts; readers get copies (or existence booleans), never a raw index
// held across a mutation.

import "core:strings"

// --- Lifecycle / Reset ----------------------------------------------------

task_store_reset :: proc() {
	task_event_count       = 0
	task_state_count       = 0
	task_participant_count = 0
	task_chain_count       = 0
	task_comment_count     = 0
	task_lgtm_vote_count   = 0
}

// --- Event queries --------------------------------------------------------

store_all_events :: proc() -> []Task_Event {
	return task_events[:task_event_count]
}

store_event_count :: proc() -> int {
	return task_event_count
}

store_last_event :: proc() -> (Task_Event, bool) {
	if task_event_count == 0 do return Task_Event{}, false
	return task_events[task_event_count - 1], true
}

store_events_in_chain :: proc(chain_id: string) -> []Task_Event {
	result := make([dynamic]Task_Event)
	for i in 0..<task_event_count {
		if task_events[i].chain_id == chain_id {
			append(&result, task_events[i])
		}
	}
	return result[:]
}

// --- Task (state) queries -------------------------------------------------

// store_get_task returns a COPY of the task with the given id, or ok=false.
store_get_task :: proc(task_id: string) -> (Task_State, bool) {
	idx := task_state_index_of(task_id)
	if idx < 0 do return Task_State{}, false
	return task_states[idx], true
}

// store_get_task_in_chain replaces the removed find-then-index task lookup pattern
// with a single-call value accessor. When chain_id is "", any chain matches.
store_get_task_in_chain :: proc(task_id, chain_id: string) -> (Task_State, bool) {
	for i in 0..<task_state_count {
		if task_states[i].task_id == task_id && (chain_id == "" || task_states[i].chain_id == chain_id) {
			return task_states[i], true
		}
	}
	return Task_State{}, false
}

store_task_exists :: proc(task_id: string) -> bool {
	return task_state_index_of(task_id) >= 0
}

store_task_count :: proc() -> int {
	return task_state_count
}

// store_get_or_create_task_in_chain preserves task_state_index semantics for the
// few legacy notification paths that auto-materialize a projection row when a
// task event references an unknown task. Prefer store_get_task* or
// store_upsert_task in new code.
store_get_or_create_task_in_chain :: proc(task_id, chain_id: string) -> (Task_State, bool) {
	idx := task_state_index(task_id, chain_id)
	if idx < 0 || idx >= task_state_count do return Task_State{}, false
	return task_states[idx], true
}

// store_tasks_in_chain returns copies of every task in the chain. Caller owns the
// returned slice (dynamic array backing) but must not retain it across a mutation
// that could invalidate the underlying values.
store_tasks_in_chain :: proc(chain_id: string, allocator := context.allocator) -> []Task_State {
	out := make([dynamic]Task_State, 0, 0, allocator)
	for i in 0..<task_state_count {
		if task_states[i].chain_id == chain_id do append(&out, task_states[i])
	}
	return out[:]
}

// store_all_tasks returns copies of every task-state row in insertion order.
// Prefer a more specific accessor when possible; this exists for the handful of
// callers that genuinely need a full sweep.
store_all_tasks :: proc(allocator := context.allocator) -> []Task_State {
	out := make([dynamic]Task_State, 0, task_state_count, allocator)
	for i in 0..<task_state_count {
		append(&out, task_states[i])
	}
	return out[:]
}

store_tasks_for_assignee :: proc(agent_instance_id: string, allocator := context.allocator) -> []Task_State {
	out := make([dynamic]Task_State, 0, 0, allocator)
	for i in 0..<task_state_count {
		if task_states[i].assignee_agent_instance_id == agent_instance_id do append(&out, task_states[i])
	}
	return out[:]
}

// --- Chain queries --------------------------------------------------------

// store_get_chain replaces the removed find-then-index chain lookup pattern.
store_get_chain :: proc(chain_id: string) -> (Task_Chain_State, bool) {
	idx := task_chain_index_of(chain_id)
	if idx < 0 do return Task_Chain_State{}, false
	return task_chains[idx], true
}

store_chain_exists :: proc(chain_id: string) -> bool {
	return task_chain_index_of(chain_id) >= 0
}

store_chain_count :: proc() -> int {
	return task_chain_count
}

store_chains_for_project :: proc(project_id: string, allocator := context.allocator) -> []Task_Chain_State {
	out := make([dynamic]Task_Chain_State, 0, 0, allocator)
	for i in 0..<task_chain_count {
		if task_chains[i].project_id == project_id do append(&out, task_chains[i])
	}
	return out[:]
}

// store_all_chains returns copies of every chain in insertion order. Prefer a
// more specific accessor when possible; this exists for the handful of callers
// that genuinely need a full sweep.
store_all_chains :: proc(allocator := context.allocator) -> []Task_Chain_State {
	out := make([dynamic]Task_Chain_State, 0, task_chain_count, allocator)
	for i in 0..<task_chain_count {
		append(&out, task_chains[i])
	}
	return out[:]
}

// --- Participant / comment / vote queries ---------------------------------

store_participants_of :: proc(task_id: string, allocator := context.allocator) -> []Task_Participant {
	out := make([dynamic]Task_Participant, 0, 0, allocator)
	for i in 0..<task_participant_count {
		if task_participants[i].task_id == task_id do append(&out, task_participants[i])
	}
	return out[:]
}

store_actor_has_role :: proc(task_id, agent_instance_id, role: string) -> bool {
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.task_id == task_id && p.agent_instance_id == agent_instance_id && p.role == role do return true
	}
	return false
}

store_comments_of :: proc(task_id: string, allocator := context.allocator) -> []Task_Comment_State {
	out := make([dynamic]Task_Comment_State, 0, 0, allocator)
	for i in 0..<task_comment_count {
		if task_comments[i].task_id == task_id do append(&out, task_comments[i])
	}
	return out[:]
}

store_votes_for :: proc(task_id: string, allocator := context.allocator) -> []Task_LGTM_Vote_State {
	out := make([dynamic]Task_LGTM_Vote_State, 0, 0, allocator)
	for i in 0..<task_lgtm_vote_count {
		if task_lgtm_votes[i].task_id == task_id do append(&out, task_lgtm_votes[i])
	}
	return out[:]
}

store_reviewer_has_voted :: proc(task_id, reviewer: string) -> bool {
	for i in 0..<task_lgtm_vote_count {
		v := task_lgtm_votes[i]
		if v.task_id == task_id && v.reviewer_agent_instance_id == reviewer do return true
	}
	return false
}

store_all_participants :: proc() -> []Task_Participant {
	return task_participants[:task_participant_count]
}

store_participant_count :: proc() -> int {
	return task_participant_count
}

store_all_comments :: proc() -> []Task_Comment_State {
	return task_comments[:task_comment_count]
}

store_comment_count :: proc() -> int {
	return task_comment_count
}

store_all_votes :: proc() -> []Task_LGTM_Vote_State {
	return task_lgtm_votes[:task_lgtm_vote_count]
}

store_vote_count :: proc() -> int {
	return task_lgtm_vote_count
}

store_participants_in_chain :: proc(chain_id: string, allocator := context.allocator) -> []Task_Participant {
	out := make([dynamic]Task_Participant, 0, 0, allocator)
	for i in 0..<task_participant_count {
		if task_participants[i].chain_id == chain_id do append(&out, task_participants[i])
	}
	return out[:]
}

store_reviewer_has_approved_vote :: proc(task_id, reviewer: string) -> bool {
	for i in 0..<task_lgtm_vote_count {
		v := task_lgtm_votes[i]
		if v.task_id == task_id && v.reviewer_agent_instance_id == reviewer && v.approved do return true
	}
	return false
}

store_comment_exists :: proc(task_id, comment_id: string) -> bool {
	for i in 0..<task_comment_count {
		c := task_comments[i]
		if c.task_id == task_id && c.comment_id == comment_id do return true
	}
	return false
}

// --- Mutations (destined to be the ONLY writers of the arrays + counts) ----

// store_append_event is the write funnel; it delegates to the existing entry so
// event journaling/persistence semantics are preserved exactly.
store_append_event :: proc(event: Task_Event) -> bool {
	return task_store_append_event(event)
}

// store_upsert_task inserts or replaces a task-state row by task_id, enforcing
// capacity in one place. Behavior mirrors the open-coded upsert used by the
// projection, but centralizes the array/count invariant.
store_upsert_task :: proc(state: Task_State) -> bool {
	idx := task_state_index_of(state.task_id)
	if idx < 0 {
		if task_state_count >= TASK_MAX_TASKS do return false
		idx = task_state_count
		task_state_count += 1
	}
	task_states[idx] = state
	return true
}

store_upsert_chain :: proc(chain: Task_Chain_State) -> bool {
	idx := task_chain_index_of(chain.chain_id)
	if idx < 0 {
		if task_chain_count >= TASK_MAX_CHAINS do return false
		idx = task_chain_count
		task_chain_count += 1
	}
	task_chains[idx] = chain
	return true
}

store_add_participant :: proc(p: Task_Participant) -> bool {
	if p.agent_instance_id == "" do return false
	if store_actor_has_role(p.task_id, p.agent_instance_id, p.role) do return true
	if task_participant_count >= TASK_MAX_PARTICIPANTS do return false
	task_participants[task_participant_count] = Task_Participant{
		task_id           = strings.clone(p.task_id),
		chain_id          = strings.clone(p.chain_id),
		agent_instance_id = strings.clone(p.agent_instance_id),
		role              = strings.clone(p.role),
	}
	task_participant_count += 1
	return true
}

store_remove_participant :: proc(task_id, agent_instance_id, role: string) -> bool {
	before := task_participant_count
	task_store_remove_participant(task_id, agent_instance_id, role)
	return task_participant_count < before
}

store_add_comment :: proc(c: Task_Comment_State) -> bool {
	if task_comment_count >= TASK_MAX_COMMENTS do return false
	task_store_append_comment(c)
	return true
}

store_record_vote :: proc(v: Task_LGTM_Vote_State) -> bool {
	task_store_upsert_lgtm_vote(v)
	return true
}

store_clear_votes_for_task :: proc(task_id: string) -> bool {
	task_store_clear_task_votes(task_id)
	return true
}
