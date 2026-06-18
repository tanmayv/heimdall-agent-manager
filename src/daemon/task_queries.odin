package main

import "core:fmt"
import "core:strings"

task_status_complete :: proc(status: string) -> bool {
	return status == "approved" || status == "done" || status == "completed"
}

task_dependencies_satisfied :: proc(depends_on: string) -> bool {
	deps := strings.split(depends_on, ",")
	for dep in deps {
		id := strings.trim_space(dep)
		if id == "" do continue
		found := false
		for i in 0..<task_state_count {
			if task_states[i].task_id == id {
				found = true
				if !task_status_complete(task_states[i].status) do return false
				break
			}
		}
		if !found do return false
	}
	return true
}

task_auto_unblock_dependents :: proc(completed_task_id, author: string) -> int {
	changed := 0
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != "pending" do continue
		if state.depends_on == "" do continue
		if !task_depends_on_task(state.depends_on, completed_task_id) do continue
		if task_dependencies_satisfied(state.depends_on) {
			event := Task_Event{kind = .Task_Status_Changed, task_id = state.task_id, chain_id = state.chain_id, status = "ready", body = "dependencies satisfied", author_agent_instance_id = author}
			if task_store_append_event(event) {
				task_notify_event(event)
				changed += 1
			}
		}
	}
	return changed
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
		event := Task_Event{kind = .Task_Status_Changed, task_id = state.task_id, chain_id = state.chain_id, status = "claimed", body = "claimed by agent", author_agent_instance_id = agent_instance_id}
		if task_store_append_event(event) {
			return task_states[task_state_index(state.task_id, state.chain_id)], true
		}
	}
	return Task_State{}, false
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
