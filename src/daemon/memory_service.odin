package main

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

Memory_Service_Result :: struct {
	ok: bool,
	status_code: int,
	message: string,
}

memory_service_propose :: proc(action, body, author: string) -> Memory_Service_Result {
	subject := extract_json_string(body, "subject_agent", extract_json_string(body, "agent", ""))
	scope := extract_json_string(body, "scope", "")
	type_text := extract_json_string(body, "type", "")
	title := extract_json_string(body, "title", "")
	memory_body := extract_json_string(body, "body", "")
	target_id := extract_json_string(body, "memory_id", extract_json_string(body, "target_memory_id", ""))
	expected_version := extract_json_int(body, "expected_version", 0)
	reason := extract_json_string(body, "reason", "")
	evidence := extract_json_string(body, "evidence", "")
	source_task_id := extract_json_string(body, "source_task_id", "")
	metadata_json := extract_json_string(body, "metadata_json", "")

	mem_type, type_ok := memory_type_parse(type_text)
	if (action == "edit" || action == "archive") && target_id == "" do return memory_error(400, "memory_id required")
	if (action == "edit" || action == "archive" || action == "rollback") && expected_version <= 0 do return memory_error(400, "expected_version required")
	if action == "new" && (subject == "" || title == "" || memory_body == "") do return memory_error(400, "memory propose new requires subject_agent, title, and body")
	if action == "new" && agent_record_index_by_instance(subject) < 0 do return memory_error(400, "subject_agent is not a known agent instance")
	if !type_ok do return memory_error(400, "invalid memory type")
	if action == "edit" && (title == "" || memory_body == "") do return memory_error(400, "memory propose edit requires memory_id, expected_version, title, and body")
	if action == "rollback" && target_id == "" do return memory_error(400, "memory_id required")

	target := contracts.Memory_Record{}
	if action != "new" {
		found: bool
		target, found = memory_find_record(target_id, true)
		if !found do return memory_error(404, "memory not found")
		defer memory_record_free(target)
		if target.version != expected_version do return memory_error(409, "memory version mismatch")
		if action != "archive" {
			if action == "rollback" {
				title = target.title
				memory_body = target.body
				type_text = memory_type_string_service(target.type)
				mem_type = target.type
				type_ok = true
			} else if type_text == "" {
				mem_type = target.type
				type_ok = true
			}
		}
	}
	if !type_ok && action != "archive" do return memory_error(400, "invalid memory type")
	if mem_type == .Skill && !memory_skill_valid(memory_body) do return memory_error(400, "malformed skill")

	proposal_id := memory_generate_id("proposal")
	memory_id := memory_generate_id("mem")
	proposal_version := 1
	if action != "new" do proposal_version = target.version
	if action == "new" do target_id = memory_id
	if action == "new" do metadata_json = memory_metadata_with_action(metadata_json, action, "")
	if action != "new" {
		subject = target.subject_agent
		scope = target.scope
		if action == "archive" {
			mem_type = target.type; title = target.title; memory_body = target.body
		}
		metadata_json = memory_metadata_with_action(metadata_json, action, target.memory_id)
	}
	event := contracts.Memory_Event{kind = .Memory_Proposed, memory_id = memory_id, proposal_id = proposal_id, subject_agent = subject, scope = scope, type = mem_type, title = title, body = memory_body, status = .Pending, reason = reason, evidence = evidence, metadata_json = metadata_json, author = author, source_task_id = source_task_id, version = proposal_version}
	resp := memory_append_event(event)
	if !resp.ok do return memory_error(500, resp.message)
	return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json(resp.message, resp.memory_id, resp.proposal_id)}
}

memory_service_decide :: proc(decision, body, author: string) -> Memory_Service_Result {
	proposal_id := extract_json_string(body, "proposal_id", "")
	if proposal_id == "" do return memory_error(400, "proposal_id required")
	proposal, found := memory_find_proposal(proposal_id)
	if !found do return memory_error(404, "proposal not found")
	defer memory_record_free(proposal)
	if proposal.status != .Pending do return memory_error(400, "proposal is not pending")
	if decision == "reject" {
		resp := memory_append_event(contracts.Memory_Event{kind = .Memory_Rejected, memory_id = proposal.memory_id, proposal_id = proposal_id, author = author})
		if !resp.ok do return memory_error(500, resp.message)
		return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json("rejected", proposal.memory_id, proposal_id)}
	}
	if decision != "approve" do return memory_error(400, "memory decision must be approve or reject")
	action := memory_metadata_action(proposal.metadata_json)
	target_id := memory_metadata_target(proposal.metadata_json)
	if (action == "edit" || action == "archive" || action == "rollback") && target_id == "" do return memory_error(400, "proposal target missing")
	if action == "archive" {
		resp_arch := memory_append_event(contracts.Memory_Event{kind = .Memory_Archived, memory_id = target_id, proposal_id = proposal_id, author = author})
		if !resp_arch.ok do return memory_error(500, resp_arch.message)
		resp_prop := memory_append_event(contracts.Memory_Event{kind = .Memory_Archived, memory_id = proposal.memory_id, proposal_id = proposal_id, author = author})
		if !resp_prop.ok do return memory_error(500, resp_prop.message)
		return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json("approved", proposal.memory_id, proposal_id)}
	}
	if action == "edit" || action == "rollback" {
		resp_arch := memory_append_event(contracts.Memory_Event{kind = .Memory_Archived, memory_id = target_id, proposal_id = proposal_id, author = author})
		if !resp_arch.ok do return memory_error(500, resp_arch.message)
	}
	resp := memory_append_event(contracts.Memory_Event{kind = .Memory_Approved, memory_id = proposal.memory_id, proposal_id = proposal_id, author = author})
	if !resp.ok do return memory_error(500, resp.message)
	return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json("approved", proposal.memory_id, proposal_id)}
}

memory_service_list_json :: proc(body: string, calling_agent_id: string = "") -> string {
	status_text := extract_json_string(body, "status", "active")
	status, status_ok := memory_status_parse(status_text)
	include_all := extract_json_bool(body, "include_all_statuses", false) || status_text == "all"
	if !status_ok && !include_all do return `{"ok":false,"message":"invalid memory status"}`
	explicit_subject := extract_json_string(body, "subject_agent", extract_json_string(body, "agent", ""))
	subject := explicit_subject if explicit_subject != "" else calling_agent_id
	
	records := memory_db_list_records(subject, extract_json_string(body, "scope", ""), status, include_all)
	defer {
		for rec in records do memory_record_free(rec)
		delete(records)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	for i in 0..<len(records) {
		if i > 0 do strings.write_string(&builder, `,`)
		memory_write_record_json(&builder, records[i])
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

memory_service_show_json :: proc(body: string) -> string {
	memory_id := extract_json_string(body, "memory_id", "")
	rec, found := memory_find_record(memory_id, true)
	if !found do return `{"ok":false,"message":"memory not found"}`
	defer memory_record_free(rec)
	builder := strings.builder_make(); strings.write_string(&builder, `{"ok":true,"record":`); memory_write_record_json(&builder, rec); strings.write_string(&builder, `}`); return strings.to_string(builder)
}

memory_service_history_json :: proc(body: string) -> string {
	memory_id := extract_json_string(body, "memory_id", "")
	events := memory_db_history(memory_id)
	defer {
		for ev in events do memory_event_free(ev)
		delete(events)
	}
	builder := strings.builder_make(); strings.write_string(&builder, `{"ok":true,"events":[`)
	for i in 0..<len(events) { if i > 0 do strings.write_string(&builder, `,`); memory_write_event_json(&builder, events[i]) }
	strings.write_string(&builder, `]}`); return strings.to_string(builder)
}

memory_find_record :: proc(memory_id: string, include_all: bool) -> (contracts.Memory_Record, bool) {
	rec, found := memory_db_get_record(memory_id)
	if !found do return {}, false
	if include_all || rec.status == .Active do return rec, true
	memory_record_free(rec)
	return {}, false
}

memory_find_proposal :: proc(proposal_id: string) -> (contracts.Memory_Record, bool) {
	return memory_db_get_proposal(proposal_id)
}

memory_error :: proc(status: int, message: string) -> Memory_Service_Result {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":false,"message":"`); json_write_string(&b, message); strings.write_string(&b, `"}`)
	return Memory_Service_Result{ok = false, status_code = status, message = strings.to_string(b)}
}

memory_response_json :: proc(message, memory_id, proposal_id: string) -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"message":"`); json_write_string(&b, message); strings.write_string(&b, `","memory_id":"`); json_write_string(&b, memory_id); strings.write_string(&b, `","proposal_id":"`); json_write_string(&b, proposal_id); strings.write_string(&b, `"}`); return strings.to_string(b)
}

memory_type_parse :: proc(value: string) -> (contracts.Memory_Type, bool) { switch value { case "", "fact": return .Fact, true; case "habit": return .Habit, true; case "episode": return .Episode, true; case "expertise": return .Expertise, true; case "skill": return .Skill, true; case "template": return .Template, true } return .Fact, false }
memory_status_parse :: proc(value: string) -> (contracts.Memory_Status, bool) { switch value { case "pending": return .Pending, true; case "active": return .Active, true; case "archived": return .Archived, true; case "rejected": return .Rejected, true } return .Active, false }
memory_type_string_service :: proc(kind: contracts.Memory_Type) -> string { switch kind { case .Fact: return "fact"; case .Habit: return "habit"; case .Episode: return "episode"; case .Expertise: return "expertise"; case .Skill: return "skill"; case .Template: return "template" } return "fact" }
memory_status_string_service :: proc(status: contracts.Memory_Status) -> string { switch status { case .Pending: return "pending"; case .Active: return "active"; case .Archived: return "archived"; case .Rejected: return "rejected" } return "pending" }

memory_skill_valid :: proc(body: string) -> bool { return strings.index(body, "name:") >= 0 && strings.index(body, "description:") >= 0 }
memory_generate_id :: proc(prefix: string) -> string { return strings.clone(fmt.tprintf("%s_%d", prefix, router_now_unix_ms())) }
memory_metadata_with_action :: proc(metadata, action, target: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"action":"`); json_write_string(&builder, action)
	strings.write_string(&builder, `","target_memory_id":"`); json_write_string(&builder, target)
	strings.write_string(&builder, `","metadata_json":"`); json_write_string(&builder, metadata)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}
memory_metadata_action :: proc(metadata: string) -> string { return extract_json_string(metadata, "action", "new") }
memory_metadata_target :: proc(metadata: string) -> string { return extract_json_string(metadata, "target_memory_id", "") }

memory_write_record_json :: proc(builder: ^strings.Builder, rec: contracts.Memory_Record) {
	strings.write_string(builder, `{"memory_id":"`); json_write_string(builder, rec.memory_id); strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, rec.proposal_id); strings.write_string(builder, `","subject_agent":"`); json_write_string(builder, rec.subject_agent); strings.write_string(builder, `","scope":"`); json_write_string(builder, rec.scope); strings.write_string(builder, `","type":"`); json_write_string(builder, memory_type_string_service(rec.type)); strings.write_string(builder, `","title":"`); json_write_string(builder, rec.title); strings.write_string(builder, `","body":"`); json_write_string(builder, rec.body); strings.write_string(builder, `","status":"`); json_write_string(builder, memory_status_string_service(rec.status)); strings.write_string(builder, `","reason":"`); json_write_string(builder, rec.reason); strings.write_string(builder, `","evidence":"`); json_write_string(builder, rec.evidence); strings.write_string(builder, `","metadata_json":"`); json_write_string(builder, rec.metadata_json); strings.write_string(builder, `","source_task_id":"`); json_write_string(builder, rec.source_task_id); strings.write_string(builder, `","version":`); strings.write_string(builder, fmt.tprintf("%d", rec.version)); strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms)); strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms)); strings.write_string(builder, `}`)
}

memory_write_event_json :: proc(builder: ^strings.Builder, ev: contracts.Memory_Event) {
	strings.write_string(builder, `{"event_id":"`); json_write_string(builder, ev.event_id); strings.write_string(builder, `","memory_id":"`); json_write_string(builder, ev.memory_id); strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, ev.proposal_id); strings.write_string(builder, `","reason":"`); json_write_string(builder, ev.reason); strings.write_string(builder, `","evidence":"`); json_write_string(builder, ev.evidence); strings.write_string(builder, `","author":"`); json_write_string(builder, ev.author); strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", ev.created_unix_ms)); strings.write_string(builder, `}`)
}
