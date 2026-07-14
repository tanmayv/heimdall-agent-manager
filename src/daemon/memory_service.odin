package main

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

Memory_Service_Result :: struct {
	ok: bool,
	status_code: int,
	message: string,
}

MEMORY_DEPRECATED_TARGET_MESSAGE :: "deprecated memory target fields are not accepted; use target_agent_id, target_team_kind, target_role, and target_project_id"

memory_has_deprecated_target_inputs :: proc(body: string) -> (bool, string) {
	// teams-v2: `agent_instance_id` is no longer blocked — per-agent memory now uses
	// the canonical `target_agent_id` dimension (scoped to the durable agent id).
	legacy_keys := []string{
		"subject_key", "subject-key", "subject_agent", "subject-agent", "agent",
		"scope", "team_id", "team", "template_key", "template",
		"project_id", "project", "project_ids", "role_key", "role_keys",
		"task_chain_type", "task_chain_types", "agent_instance_id",
	}
	for key in legacy_keys {
		if json_has_key(body, key) do return true, MEMORY_DEPRECATED_TARGET_MESSAGE
	}
	return false, ""
}

// teams-v2: validate the per-agent memory target. Empty is allowed (broader
// scopes). When set, it must reference an existing non-archived durable agent_id.
memory_normalize_target_agent_id :: proc(value: string) -> (string, bool, string) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return strings.clone(""), true, ""
	if !agent_id_is_active(trimmed) do return strings.clone(""), false, "unknown or archived target_agent_id"
	return strings.clone(trimmed), true, ""
}

memory_service_propose :: proc(action, body, author: string) -> Memory_Service_Result {
	if deprecated, msg := memory_has_deprecated_target_inputs(body); deprecated do return memory_error(400, msg)

	target_agent_id_present := json_has_key(body, "target_agent_id")
	target_team_kind_present := json_has_key(body, "target_team_kind")
	target_role_present := json_has_key(body, "target_role")
	target_project_id_present := json_has_key(body, "target_project_id")

	target_agent_id_text := extract_json_string(body, "target_agent_id", "")
	defer delete(target_agent_id_text)
	target_team_kind_text := extract_json_string(body, "target_team_kind", "")
	defer delete(target_team_kind_text)
	target_role_text := extract_json_string(body, "target_role", "")
	defer delete(target_role_text)
	target_project_id_text := extract_json_string(body, "target_project_id", "")
	defer delete(target_project_id_text)

	target_team_kind, team_kind_ok, team_kind_err := memory_normalize_target_team_kind(target_team_kind_text)
	defer delete(target_team_kind)
	if !team_kind_ok do return memory_error(400, team_kind_err)
	target_role, target_role_ok, target_role_err := memory_normalize_target_role(target_role_text)
	defer delete(target_role)
	if !target_role_ok do return memory_error(400, target_role_err)
	target_project_id, project_ok, project_err := memory_normalize_target_project_id(target_project_id_text)
	defer delete(target_project_id)
	if !project_ok do return memory_error(400, project_err)
	target_agent_id, agent_ok, agent_err := memory_normalize_target_agent_id(target_agent_id_text)
	defer delete(target_agent_id)
	if !agent_ok do return memory_error(400, agent_err)

	type_text := extract_json_string(body, "type", "")
	defer delete(type_text)
	title := extract_json_string(body, "title", "")
	defer delete(title)
	memory_body := extract_json_string(body, "body", "")
	defer delete(memory_body)
	metadata_json := extract_json_string(body, "metadata_json", "")
	defer delete(metadata_json)
	source_task_id := extract_json_string(body, "source_task_id", "")
	defer delete(source_task_id)
	reason := extract_json_string(body, "reason", "")
	defer delete(reason)
	evidence := extract_json_string(body, "evidence", "")
	defer delete(evidence)
	target_id := extract_json_string(body, "memory_id", extract_json_string(body, "target_memory_id", ""))
	defer delete(target_id)
	expected_version := extract_json_int(body, "expected_version", 0)

	mem_type, type_ok := memory_type_parse(type_text)
	if (action == "edit" || action == "archive" || action == "rollback") && target_id == "" do return memory_error(400, "memory_id required")
	if (action == "edit" || action == "archive" || action == "rollback") && expected_version <= 0 do return memory_error(400, "expected_version required")
	if action == "new" && (title == "" || memory_body == "") do return memory_error(400, "memory propose new requires title and body")
	if action == "edit" && (title == "" || memory_body == "") do return memory_error(400, "memory propose edit requires memory_id, expected_version, title, and body")
	if action != "archive" && !type_ok do return memory_error(400, "invalid memory type")
	if mem_type == .Skill && !memory_skill_valid(memory_body) do return memory_error(400, "malformed skill")

	target := contracts.Memory_Record{}
	defer if action != "new" && target.memory_id != "" do memory_record_free(target)
	if action != "new" {
		found: bool
		target, found = memory_find_record(target_id, true)
		if !found do return memory_error(404, "memory not found")
		if target.version != expected_version do return memory_error(409, "memory version mismatch")

		if !target_team_kind_present {
			delete(target_team_kind)
			target_team_kind = strings.clone(target.target_team_kind)
		}
		if !target_role_present {
			delete(target_role)
			target_role = strings.clone(target.target_role)
		}
		if !target_project_id_present {
			delete(target_project_id)
			target_project_id = strings.clone(target.target_project_id)
		}
		if !target_agent_id_present {
			delete(target_agent_id)
			target_agent_id = strings.clone(target.target_agent_id)
		}

		if action == "archive" || action == "rollback" {
			mem_type = target.type
			delete(title)
			title = strings.clone(target.title)
			delete(memory_body)
			memory_body = strings.clone(target.body)
		} else if type_text == "" {
			mem_type = target.type
		}
	}
	if mem_type == .Skill && !memory_skill_valid(memory_body) do return memory_error(400, "malformed skill")

	metadata_with_action := memory_metadata_with_action(metadata_json, action, target_id)
	defer delete(metadata_with_action)

	proposal_id := memory_generate_id("proposal")
	defer delete(proposal_id)
	memory_id := memory_generate_id("mem")
	defer delete(memory_id)
	proposal_version := 1
	if action != "new" do proposal_version = target.version

	event := contracts.Memory_Event{
		kind = .Memory_Proposed,
		memory_id = memory_id,
		proposal_id = proposal_id,
		target_agent_id = strings.clone(target_agent_id),
		target_team_kind = strings.clone(target_team_kind),
		target_role = strings.clone(target_role),
		target_project_id = strings.clone(target_project_id),
		type = mem_type,
		title = strings.clone(title),
		body = strings.clone(memory_body),
		status = .Pending,
		reason = strings.clone(reason),
		evidence = strings.clone(evidence),
		metadata_json = strings.clone(metadata_with_action),
		author = strings.clone(author),
		source_task_id = strings.clone(source_task_id),
		version = proposal_version,
	}
	resp := memory_append_event(event)
	if !resp.ok do return memory_error(500, resp.message)
	return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json(resp.message, resp.memory_id, resp.proposal_id)}
}

memory_service_decide :: proc(decision, body, author: string) -> Memory_Service_Result {
	proposal_id := extract_json_string(body, "proposal_id", "")
	defer delete(proposal_id)
	if proposal_id == "" do return memory_error(400, "proposal_id required")

	proposal, found := memory_find_proposal(proposal_id)
	if !found do return memory_error(404, "proposal not found")
	defer memory_record_free(proposal)
	if proposal.status != .Pending do return memory_error(400, "proposal is not pending")

	if decision == "reject" {
		resp := memory_append_event(contracts.Memory_Event{kind = .Memory_Rejected, memory_id = strings.clone(proposal.memory_id), proposal_id = strings.clone(proposal_id), author = strings.clone(author)})
		if !resp.ok do return memory_error(500, resp.message)
		return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json("rejected", proposal.memory_id, proposal_id)}
	}
	if decision != "approve" do return memory_error(400, "memory decision must be approve or reject")

	action := memory_metadata_action(proposal.metadata_json)
	defer delete(action)
	target_id := memory_metadata_target(proposal.metadata_json)
	defer delete(target_id)
	if (action == "edit" || action == "archive" || action == "rollback") && target_id == "" do return memory_error(400, "proposal target missing")

	if action == "archive" {
		resp_arch := memory_append_event(contracts.Memory_Event{kind = .Memory_Archived, memory_id = strings.clone(target_id), proposal_id = strings.clone(proposal_id), author = strings.clone(author)})
		if !resp_arch.ok do return memory_error(500, resp_arch.message)
		resp_prop := memory_append_event(contracts.Memory_Event{kind = .Memory_Archived, memory_id = strings.clone(proposal.memory_id), proposal_id = strings.clone(proposal_id), author = strings.clone(author)})
		if !resp_prop.ok do return memory_error(500, resp_prop.message)
		return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json("approved", proposal.memory_id, proposal_id)}
	}

	if action == "edit" || action == "rollback" {
		resp_arch := memory_append_event(contracts.Memory_Event{kind = .Memory_Archived, memory_id = strings.clone(target_id), proposal_id = strings.clone(proposal_id), author = strings.clone(author)})
		if !resp_arch.ok do return memory_error(500, resp_arch.message)
	}

	resp := memory_append_event(contracts.Memory_Event{kind = .Memory_Approved, memory_id = strings.clone(proposal.memory_id), proposal_id = strings.clone(proposal_id), author = strings.clone(author)})
	if !resp.ok do return memory_error(500, resp.message)
	return Memory_Service_Result{ok = true, status_code = 200, message = memory_response_json("approved", proposal.memory_id, proposal_id)}
}

memory_service_list_json :: proc(body: string, calling_agent_id: string = "") -> string {
	if deprecated, msg := memory_has_deprecated_target_inputs(body); deprecated do return memory_error(400, msg).message

	status_text := extract_json_string(body, "status", strings.clone("active"))
	defer delete(status_text)
	status, status_ok := memory_status_parse(status_text)
	include_all := extract_json_bool(body, "include_all_statuses", false) || status_text == "all"
	if !status_ok && !include_all do return `{"ok":false,"message":"invalid memory status"}`

	type_text := extract_json_string(body, "type", "")
	defer delete(type_text)
	if _, ok := memory_type_parse(type_text); type_text != "" && !ok do return `{"ok":false,"message":"invalid memory type"}`

	target_team_kind_filter, team_kind_ok, team_kind_err := memory_normalize_target_team_kind(extract_json_string(body, "target_team_kind", ""))
	defer delete(target_team_kind_filter)
	if !team_kind_ok do return memory_error(400, team_kind_err).message
	target_role_filter, target_role_ok, target_role_err := memory_normalize_target_role(extract_json_string(body, "target_role", ""))
	defer delete(target_role_filter)
	if !target_role_ok do return memory_error(400, target_role_err).message
	target_project_filter, project_ok, project_err := memory_normalize_target_project_id(extract_json_string(body, "target_project_id", ""))
	defer delete(target_project_filter)
	if !project_ok do return memory_error(400, project_err).message
	// teams-v2: optional per-agent filter for the management UI. Unlike propose,
	// filtering does not require the agent to still exist/be active.
	target_agent_filter := strings.trim_space(extract_json_string(body, "target_agent_id", ""))
	defer delete(target_agent_filter)

	records := memory_db_list_records(status, include_all)
	defer {
		for rec in records do memory_record_free(rec)
		delete(records)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	wrote := false
	for rec in records {
		if !memory_record_matches_filters(rec, type_text, target_team_kind_filter, target_role_filter, target_project_filter, target_agent_filter) do continue
		if wrote do strings.write_string(&builder, `,`)
		memory_write_record_json(&builder, rec)
		wrote = true
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

memory_service_applicable_json :: proc(body, calling_agent_id: string) -> Memory_Service_Result {
	if deprecated, msg := memory_has_deprecated_target_inputs(body); deprecated do return memory_error(400, msg)

	target_team_kind, team_kind_ok, team_kind_err := memory_normalize_target_team_kind(extract_json_string(body, "target_team_kind", ""))
	defer delete(target_team_kind)
	if !team_kind_ok do return memory_error(400, team_kind_err)
	target_role, target_role_ok, target_role_err := memory_normalize_target_role(extract_json_string(body, "target_role", ""))
	defer delete(target_role)
	if !target_role_ok do return memory_error(400, target_role_err)
	target_project_id, project_ok, project_err := memory_normalize_target_project_id(extract_json_string(body, "target_project_id", ""))
	defer delete(target_project_id)
	if !project_ok do return memory_error(400, project_err)
	// teams-v2: resolve the requesting agent's durable agent_id so per-agent
	// memories are injected. Prefer explicit body field, else derive from the
	// calling instance id (bootstrap passes the instance's agent_instance_id).
	ctx_agent_id := strings.trim_space(extract_json_string(body, "target_agent_id", ""))
	if ctx_agent_id == "" && calling_agent_id != "" do ctx_agent_id = agent_id_from_instance_id(calling_agent_id)
	defer delete(ctx_agent_id)

	records := memory_db_list_records(.Active, false)
	defer {
		for rec in records do memory_record_free(rec)
		delete(records)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	wrote := false
	for rec in records {
		if !memory_record_applies(rec, ctx_agent_id, target_team_kind, target_role, target_project_id) do continue
		if wrote do strings.write_string(&builder, `,`)
		memory_write_record_json(&builder, rec)
		wrote = true
	}
	strings.write_string(&builder, `]}`)
	return Memory_Service_Result{ok = true, status_code = 200, message = strings.to_string(builder)}
}

memory_service_show_json :: proc(body: string) -> string {
	memory_id := extract_json_string(body, "memory_id", "")
	defer delete(memory_id)
	rec, found := memory_find_record(memory_id, true)
	if !found do return `{"ok":false,"message":"memory not found"}`
	defer memory_record_free(rec)
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"record":`)
	memory_write_record_json(&builder, rec)
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

memory_service_history_json :: proc(body: string) -> string {
	memory_id := extract_json_string(body, "memory_id", "")
	defer delete(memory_id)
	events := memory_db_history(memory_id)
	defer {
		for ev in events do memory_event_free(ev)
		delete(events)
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"events":[`)
	for i in 0..<len(events) {
		if i > 0 do strings.write_string(&builder, `,`)
		memory_write_event_json(&builder, events[i])
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
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
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"message":"`)
	json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	return Memory_Service_Result{ok = false, status_code = status, message = strings.to_string(b)}
}

memory_response_json :: proc(message, memory_id, proposal_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message":"`)
	json_write_string(&b, message)
	strings.write_string(&b, `","memory_id":"`)
	json_write_string(&b, memory_id)
	strings.write_string(&b, `","proposal_id":"`)
	json_write_string(&b, proposal_id)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

memory_type_parse :: proc(value: string) -> (contracts.Memory_Type, bool) {
	switch value {
	case "", "fact": return .Fact, true
	case "habit": return .Habit, true
	case "episode": return .Episode, true
	case "expertise": return .Expertise, true
	case "skill": return .Skill, true
	case "template": return .Template, true
	}
	return .Fact, false
}

memory_status_parse :: proc(value: string) -> (contracts.Memory_Status, bool) {
	switch value {
	case "pending": return .Pending, true
	case "active": return .Active, true
	case "archived": return .Archived, true
	case "rejected": return .Rejected, true
	}
	return .Active, false
}

memory_type_string_service :: proc(kind: contracts.Memory_Type) -> string {
	switch kind {
	case .Fact: return "fact"
	case .Habit: return "habit"
	case .Episode: return "episode"
	case .Expertise: return "expertise"
	case .Skill: return "skill"
	case .Template: return "template"
	}
	return "fact"
}

memory_status_string_service :: proc(status: contracts.Memory_Status) -> string {
	switch status {
	case .Pending: return "pending"
	case .Active: return "active"
	case .Archived: return "archived"
	case .Rejected: return "rejected"
	}
	return "pending"
}

memory_skill_valid :: proc(body: string) -> bool {
	return strings.index(body, "name:") >= 0 && strings.index(body, "description:") >= 0
}

memory_generate_id :: proc(prefix: string) -> string {
	return strings.clone(fmt.tprintf("%s_%d", prefix, router_now_unix_ms()))
}

memory_metadata_with_action :: proc(metadata, action, target: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"action":"`)
	json_write_string(&builder, action)
	strings.write_string(&builder, `","target_memory_id":"`)
	json_write_string(&builder, target)
	strings.write_string(&builder, `","metadata_json":"`)
	json_write_string(&builder, metadata)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}

memory_metadata_action :: proc(metadata: string) -> string { return extract_json_string(metadata, "action", "new") }
memory_metadata_target :: proc(metadata: string) -> string { return extract_json_string(metadata, "target_memory_id", "") }

memory_normalize_target_team_kind :: proc(value: string) -> (string, bool, string) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return strings.clone(""), true, ""
	needle := strings.to_lower(trimmed)
	defer delete(needle)
	for kind in team_kind_list() {
		key_lower := strings.to_lower(kind.key)
		display_lower := strings.to_lower(kind.display_name)
		if needle == key_lower || (kind.display_name != "" && needle == display_lower) {
			delete(key_lower)
			delete(display_lower)
			return strings.clone(kind.key), true, ""
		}
		delete(key_lower)
		delete(display_lower)
	}
	return strings.clone(""), false, "unknown target_team_kind"
}

memory_normalize_target_role :: proc(value: string) -> (string, bool, string) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return strings.clone(""), true, ""
	needle := strings.to_lower(trimmed)
	defer delete(needle)
	for kind in team_kind_list() {
		for role in kind.roles {
			role_lower := strings.to_lower(role.role_key)
			if needle == role_lower {
				delete(role_lower)
				return strings.clone(role.role_key), true, ""
			}
			delete(role_lower)
		}
	}
	return strings.clone(""), false, "unknown target_role"
}

memory_normalize_target_project_id :: proc(value: string) -> (string, bool, string) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return strings.clone(""), true, ""
	if !memory_project_id_known(trimmed) do return strings.clone(""), false, "unknown target_project_id"
	return strings.clone(trimmed), true, ""
}

memory_project_id_known :: proc(value: string) -> bool {
	if value == "" do return false
	return project_index(value) >= 0
}

memory_record_matches_filters :: proc(rec: contracts.Memory_Record, type_filter, target_team_kind_filter, target_role_filter, target_project_filter, target_agent_filter: string) -> bool {
	if type_filter != "" && memory_type_string_service(rec.type) != type_filter do return false
	if target_agent_filter != "" && rec.target_agent_id != target_agent_filter do return false
	if target_team_kind_filter != "" && rec.target_team_kind != target_team_kind_filter do return false
	if target_role_filter != "" && rec.target_role != target_role_filter do return false
	if target_project_filter != "" && rec.target_project_id != target_project_filter do return false
	return true
}

memory_target_dimension_matches :: proc(record_value, context_value: string) -> bool {
	if record_value == "" do return true
	if context_value == "" do return false
	return record_value == context_value
}

memory_record_applies :: proc(rec: contracts.Memory_Record, target_agent_id, target_team_kind, target_role, target_project_id: string) -> bool {
	if rec.status != .Active do return false
	// teams-v2: agent-id is the most specific dimension. A per-agent memory applies
	// only when the requesting instance's durable agent_id matches.
	if !memory_target_dimension_matches(rec.target_agent_id, target_agent_id) do return false
	if !memory_target_dimension_matches(rec.target_team_kind, target_team_kind) do return false
	if !memory_target_dimension_matches(rec.target_role, target_role) do return false
	if !memory_target_dimension_matches(rec.target_project_id, target_project_id) do return false
	return true
}

memory_target_string :: proc(target_agent_id, target_team_kind, target_role, target_project_id: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if target_agent_id != "" do append(&parts, fmt.tprintf("agent %s", target_agent_id))
	if target_team_kind != "" do append(&parts, fmt.tprintf("team kind %s", target_team_kind))
	if target_role != "" do append(&parts, fmt.tprintf("role %s", target_role))
	if target_project_id != "" do append(&parts, fmt.tprintf("project %s", target_project_id))
	if len(parts) == 0 do return strings.clone("global")
	builder := strings.builder_make()
	for part, idx in parts {
		if idx > 0 do strings.write_string(&builder, " · ")
		strings.write_string(&builder, part)
	}
	return strings.to_string(builder)
}

memory_expertise_bucket_key :: proc(rec: contracts.Memory_Record) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, rec.target_agent_id)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, rec.target_team_kind)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, rec.target_role)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, rec.target_project_id)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, teams_v1_slug(rec.title))
	return strings.to_string(builder)
}

memory_write_record_json :: proc(builder: ^strings.Builder, rec: contracts.Memory_Record) {
	target := memory_target_string(rec.target_agent_id, rec.target_team_kind, rec.target_role, rec.target_project_id)
	defer delete(target)
	strings.write_string(builder, `{"memory_id":"`); json_write_string(builder, rec.memory_id)
	strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, rec.proposal_id)
	strings.write_string(builder, `","target_agent_id":"`); json_write_string(builder, rec.target_agent_id)
	strings.write_string(builder, `","target_team_kind":"`); json_write_string(builder, rec.target_team_kind)
	strings.write_string(builder, `","target_role":"`); json_write_string(builder, rec.target_role)
	strings.write_string(builder, `","target_project_id":"`); json_write_string(builder, rec.target_project_id)
	strings.write_string(builder, `","target":"`); json_write_string(builder, target)
	strings.write_string(builder, `","type":"`); json_write_string(builder, memory_type_string_service(rec.type))
	strings.write_string(builder, `","title":"`); json_write_string(builder, rec.title)
	strings.write_string(builder, `","body":"`); json_write_string(builder, rec.body)
	strings.write_string(builder, `","status":"`); json_write_string(builder, memory_status_string_service(rec.status))
	strings.write_string(builder, `","reason":"`); json_write_string(builder, rec.reason)
	strings.write_string(builder, `","evidence":"`); json_write_string(builder, rec.evidence)
	strings.write_string(builder, `","metadata_json":"`); json_write_string(builder, rec.metadata_json)
	strings.write_string(builder, `","source_task_id":"`); json_write_string(builder, rec.source_task_id)
	strings.write_string(builder, `","version":`); strings.write_string(builder, fmt.tprintf("%d", rec.version))
	strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `}`)
}

memory_write_event_json :: proc(builder: ^strings.Builder, ev: contracts.Memory_Event) {
	target := memory_target_string(ev.target_agent_id, ev.target_team_kind, ev.target_role, ev.target_project_id)
	defer delete(target)
	strings.write_string(builder, `{"event_id":"`); json_write_string(builder, ev.event_id)
	strings.write_string(builder, `","memory_id":"`); json_write_string(builder, ev.memory_id)
	strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, ev.proposal_id)
	strings.write_string(builder, `","target_agent_id":"`); json_write_string(builder, ev.target_agent_id)
	strings.write_string(builder, `","target_team_kind":"`); json_write_string(builder, ev.target_team_kind)
	strings.write_string(builder, `","target_role":"`); json_write_string(builder, ev.target_role)
	strings.write_string(builder, `","target_project_id":"`); json_write_string(builder, ev.target_project_id)
	strings.write_string(builder, `","target":"`); json_write_string(builder, target)
	strings.write_string(builder, `","type":"`); json_write_string(builder, memory_type_string_service(ev.type))
	strings.write_string(builder, `","title":"`); json_write_string(builder, ev.title)
	strings.write_string(builder, `","body":"`); json_write_string(builder, ev.body)
	strings.write_string(builder, `","status":"`); json_write_string(builder, memory_status_string_service(ev.status))
	strings.write_string(builder, `","reason":"`); json_write_string(builder, ev.reason)
	strings.write_string(builder, `","evidence":"`); json_write_string(builder, ev.evidence)
	strings.write_string(builder, `","author":"`); json_write_string(builder, ev.author)
	strings.write_string(builder, `","source_task_id":"`); json_write_string(builder, ev.source_task_id)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", ev.created_unix_ms))
	strings.write_string(builder, `}`)
}
