package main

import "core:fmt"
import "core:strings"
import re "odin_test:lib/router_envelope"

TASK_ARCHIVE_PAYLOAD_TYPE :: "task.chain_archive"

task_archive_chain_to_hub :: proc(chain_id: string) -> bool {
	if !hub_adapter_config.enabled {
		task_store_mark_archive_pending(chain_id, "hub disabled")
		return false
	}
	idx := task_chain_index(chain_id)
	chain := task_chains[idx]
	if chain.final_summary == "" {
		return false
	}
	payload := task_chain_archive_snapshot_json(chain_id)
	crypto := re.encrypt_payload_for_router(payload, hub_adapter_config.user_token)
	if !crypto.ok {
		task_store_mark_archive_pending(chain_id, "encrypt failed")
		return false
	}
	_, ok := central_hub_append(Hub_Record{record_id = fmt.tprintf("task_archive_%s_%d", chain_id, router_now_unix_ms()), message_id = fmt.tprintf("task_archive_%s", chain_id), kind = .Status, user_id = hub_adapter_config.user_id, namespace = hub_adapter_config.namespace, source_daemon_id = hub_adapter_config.local_daemon_id, payload_type = TASK_ARCHIVE_PAYLOAD_TYPE, payload_version = 1, encrypted_payload_json = crypto.encrypted_payload_json})
	if !ok {
		task_store_mark_archive_pending(chain_id, "hub append failed")
		return false
	}
	task_store_append_event(Task_Event{kind = .Chain_Archived, chain_id = chain_id, body = "archived to hub"})
	return true
}

task_chain_archive_snapshot_json :: proc(chain_id: string) -> string {
	chain_idx := task_chain_index(chain_id)
	chain := task_chains[chain_idx]
	builder := strings.builder_make()
	strings.write_string(&builder, `{"chain_id":"`); json_write_string(&builder, chain_id)
	strings.write_string(&builder, `","title":"`); json_write_string(&builder, chain.title)
	strings.write_string(&builder, `","description":"`); json_write_string(&builder, chain.description)
	strings.write_string(&builder, `","status":"`); json_write_string(&builder, chain.status)
	strings.write_string(&builder, `","coordinator_agent_instance_id":"`); json_write_string(&builder, chain.coordinator_agent_instance_id)
	strings.write_string(&builder, `","project_id":"`); json_write_string(&builder, chain.project_id)
	strings.write_string(&builder, `","created_at_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", chain.created_at_unix_ms))
	strings.write_string(&builder, `,"completed_at_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", chain.completed_at_unix_ms))
	strings.write_string(&builder, `,"final_summary":"`); json_write_string(&builder, chain.final_summary)
	strings.write_string(&builder, `","tasks":[`)
	first := true
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.chain_id != chain_id do continue
		if !first do strings.write_string(&builder, `,`)
		first = false
		strings.write_string(&builder, `{"task_id":"`); json_write_string(&builder, state.task_id)
		strings.write_string(&builder, `","title":"`); json_write_string(&builder, state.title)
		strings.write_string(&builder, `","status":"`); json_write_string(&builder, state.status)
		strings.write_string(&builder, `","assignee_agent_instance_id":"`); json_write_string(&builder, state.assignee_agent_instance_id)
		strings.write_string(&builder, `","coordinator_agent_instance_id":"`); json_write_string(&builder, state.coordinator_agent_instance_id)
		strings.write_string(&builder, `"}`)
	}
	strings.write_string(&builder, `],"participants":[`)
	first = true
	for i in 0..<task_participant_count {
		p := task_participants[i]
		if p.chain_id != chain_id do continue
		if !first do strings.write_string(&builder, `,`)
		first = false
		strings.write_string(&builder, `{"task_id":"`); json_write_string(&builder, p.task_id)
		strings.write_string(&builder, `","agent_instance_id":"`); json_write_string(&builder, p.agent_instance_id)
		strings.write_string(&builder, `","role":"`); json_write_string(&builder, p.role)
		strings.write_string(&builder, `"}`)
	}
	strings.write_string(&builder, `],"events":[`)
	first = true
	for i in 0..<task_event_count {
		event := task_events[i]
		if event.chain_id != chain_id do continue
		if !first do strings.write_string(&builder, `,`)
		first = false
		strings.write_string(&builder, task_event_json(event))
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}
