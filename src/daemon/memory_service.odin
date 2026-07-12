package main

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

Memory_Service_Result :: struct {
	ok: bool,
	status_code: int,
	message: string,
}

MEMORY_DEPRECATED_SUBJECT_MESSAGE :: "deprecated memory subject fields are not accepted; use canonical target fields (agent_instance_id, team_id, project_id, template_key, project_ids, role_keys, task_chain_types)"

memory_deprecated_subject_inputs :: proc(body: string) -> (bool, string) {
	if json_has_key(body, "subject_key") || json_has_key(body, "subject-key") || json_has_key(body, "subject_agent") || json_has_key(body, "subject-agent") || json_has_key(body, "agent") {
		return true, MEMORY_DEPRECATED_SUBJECT_MESSAGE
	}
	return false, ""
}

memory_service_propose :: proc(action, body, author: string) -> Memory_Service_Result {
	if deprecated, msg := memory_deprecated_subject_inputs(body); deprecated do return memory_error(400, msg)
	subject := extract_json_string(body, "agent_instance_id", "")
	defer delete(subject)

	scope := memory_scope_normalize(extract_json_string(body, "scope", ""))
	defer delete(scope)
	subject_key := extract_json_string(body, "subject_key", "")
	defer delete(subject_key)
	type_text := extract_json_string(body, "type", "")
	defer delete(type_text)
	title := extract_json_string(body, "title", "")
	defer delete(title)
	memory_body := extract_json_string(body, "body", "")
	defer delete(memory_body)
	project_ids_text := extract_json_string(body, "project_ids", extract_json_string(body, "project_id", ""))
	defer delete(project_ids_text)
	role_keys_text := extract_json_string(body, "role_keys", extract_json_string(body, "role_key", ""))
	defer delete(role_keys_text)
	task_chain_types_text := extract_json_string(body, "task_chain_types", extract_json_string(body, "task_chain_type", ""))
	defer delete(task_chain_types_text)

	target_id := extract_json_string(body, "memory_id", "")
	if target_id == "" {
		delete(target_id)
		target_id = extract_json_string(body, "target_memory_id", "")
	}
	defer delete(target_id)

	expected_version := extract_json_int(body, "expected_version", 0)
	reason := extract_json_string(body, "reason", "")
	defer delete(reason)
	evidence := extract_json_string(body, "evidence", "")
	defer delete(evidence)
	source_task_id := extract_json_string(body, "source_task_id", "")
	defer delete(source_task_id)
	metadata_json := extract_json_string(body, "metadata_json", "")
	defer delete(metadata_json)

	proposal_id: string
	defer delete(proposal_id)
	memory_id: string
	defer delete(memory_id)

	project_ids, role_keys, task_chain_types, targets_ok, targets_err := memory_prepare_targets(project_ids_text, role_keys_text, task_chain_types_text)
	defer delete(project_ids)
	defer delete(role_keys)
	defer delete(task_chain_types)
	if !targets_ok do return memory_error(400, targets_err)

	mem_type, type_ok := memory_type_parse(type_text)
	if (action == "edit" || action == "archive") && target_id == "" do return memory_error(400, "memory_id required")
	if (action == "edit" || action == "archive" || action == "rollback") && expected_version <= 0 do return memory_error(400, "expected_version required")
	if action == "new" && (title == "" || memory_body == "") do return memory_error(400, "memory propose new requires title and body")
	if !type_ok do return memory_error(400, "invalid memory type")
	if action == "edit" && (title == "" || memory_body == "") do return memory_error(400, "memory propose edit requires memory_id, expected_version, title, and body")
	if action == "rollback" && target_id == "" do return memory_error(400, "memory_id required")

	target := contracts.Memory_Record{}
	defer if action != "new" && target.memory_id != "" do memory_record_free(target)
	if action != "new" {
		found: bool
		target, found = memory_find_record(target_id, true)
		if !found do return memory_error(404, "memory not found")
		if target.version != expected_version do return memory_error(409, "memory version mismatch")
		if action != "archive" {
			if action == "rollback" {
				delete(title)
				title = strings.clone(target.title)
				delete(memory_body)
				memory_body = strings.clone(target.body)
				delete(type_text)
				type_text = strings.clone(memory_type_string_service(target.type))
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

	proposal_id = memory_generate_id("proposal")
	memory_id = memory_generate_id("mem")
	proposal_version := 1
	if action != "new" do proposal_version = target.version
	if action == "new" {
		delete(target_id)
		target_id = strings.clone(memory_id)
	}
	if action == "new" {
		resolved_subject, resolved_scope, resolved_subject_key, ok, err := memory_resolve_new_subject(author, body, subject, scope, subject_key, title, mem_type, project_ids != "" || role_keys != "" || task_chain_types != "")
		if !ok do return memory_error(400, err)
		delete(subject)
		subject = resolved_subject
		delete(scope)
		scope = resolved_scope
		delete(subject_key)
		subject_key = resolved_subject_key
		if ok_scope, scope_err := memory_validate_scope_targets(scope, subject_key, project_ids, role_keys, task_chain_types); !ok_scope do return memory_error(400, scope_err)
		new_metadata_json := memory_metadata_with_action(metadata_json, action, "")
		delete(metadata_json)
		metadata_json = new_metadata_json
	}
	if action != "new" {
		if changed, change_err := memory_edit_targeting_changed(body, subject, scope, subject_key, project_ids, role_keys, task_chain_types, target); changed {
			return memory_error(400, change_err)
		}
		delete(subject)
		subject = strings.clone(target.legacy_subject_agent)
		delete(scope)
		scope = strings.clone(target.scope)
		delete(subject_key)
		subject_key = strings.clone(target.legacy_subject_key)
		delete(project_ids)
		project_ids = strings.clone(target.project_ids)
		delete(role_keys)
		role_keys = strings.clone(target.role_keys)
		delete(task_chain_types)
		task_chain_types = strings.clone(target.task_chain_types)
		if action == "archive" {
			mem_type = target.type
			delete(title)
			title = strings.clone(target.title)
			delete(memory_body)
			memory_body = strings.clone(target.body)
		}
		new_metadata_json := memory_metadata_with_action(metadata_json, action, target.memory_id)
		delete(metadata_json)
		metadata_json = new_metadata_json
	}
	agent_instance_id := memory_agent_instance_id_from_subject(scope, subject, subject_key)
	defer delete(agent_instance_id)
	team_id := memory_team_id_from_subject(scope, subject_key)
	defer delete(team_id)
	template_key := memory_template_key_from_subject(scope, subject_key)
	defer delete(template_key)
	event := contracts.Memory_Event{
		kind = .Memory_Proposed,
		memory_id = memory_id,
		proposal_id = proposal_id,
		legacy_subject_agent = subject,
		scope = scope,
		legacy_subject_key = subject_key,
		agent_instance_id = agent_instance_id,
		team_id = team_id,
		template_key = template_key,
		project_ids = project_ids,
		role_keys = role_keys,
		task_chain_types = task_chain_types,
		type = mem_type,
		title = title,
		body = memory_body,
		status = .Pending,
		reason = reason,
		evidence = evidence,
		metadata_json = metadata_json,
		author = author,
		source_task_id = source_task_id,
		version = proposal_version,
	}
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
	if deprecated, msg := memory_deprecated_subject_inputs(body); deprecated do return memory_error(400, msg).message
	status_text := extract_json_string(body, "status", "active")
	status, status_ok := memory_status_parse(status_text)
	include_all := extract_json_bool(body, "include_all_statuses", false) || status_text == "all"
	if !status_ok && !include_all do return `{"ok":false,"message":"invalid memory status"}`
	type_text := extract_json_string(body, "type", "")
	defer delete(type_text)
	if _, ok := memory_type_parse(type_text); type_text != "" && !ok do return `{"ok":false,"message":"invalid memory type"}`
	project_ids_filter_text := extract_json_string(body, "project_ids", extract_json_string(body, "project_id", ""))
	defer delete(project_ids_filter_text)
	role_keys_filter_text := extract_json_string(body, "role_keys", extract_json_string(body, "role_key", ""))
	defer delete(role_keys_filter_text)
	task_chain_types_filter_text := extract_json_string(body, "task_chain_types", extract_json_string(body, "task_chain_type", ""))
	defer delete(task_chain_types_filter_text)
	project_ids_filter, role_keys_filter, task_chain_types_filter, filters_ok, filters_err := memory_prepare_targets(project_ids_filter_text, role_keys_filter_text, task_chain_types_filter_text)
	defer delete(project_ids_filter)
	defer delete(role_keys_filter)
	defer delete(task_chain_types_filter)
	if !filters_ok do return memory_error(400, filters_err).message

	agent_instance_id_filter := extract_json_string(body, "agent_instance_id", "")
	defer delete(agent_instance_id_filter)
	team_id_filter := extract_json_string(body, "team_id", extract_json_string(body, "team", ""))
	defer delete(team_id_filter)
	template_key_filter := extract_json_string(body, "template_key", extract_json_string(body, "template", ""))
	defer delete(template_key_filter)
	scope := memory_scope_normalize(extract_json_string(body, "scope", ""))
	defer delete(scope)
	if scope == "Personal" && agent_instance_id_filter == "" {
		delete(agent_instance_id_filter)
		agent_instance_id_filter = strings.clone(calling_agent_id)
	}
	if scope == "Personal" && !memory_personal_visible_to(calling_agent_id) do return `{"ok":true,"records":[]}`

	records := memory_db_list_records(scope, status, include_all)
	defer {
		for rec in records do memory_record_free(rec)
		delete(records)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	wrote := false
	for rec in records {
		if !memory_record_matches_filters(rec, type_text, agent_instance_id_filter, team_id_filter, template_key_filter, project_ids_filter, role_keys_filter, task_chain_types_filter, calling_agent_id) do continue
		if wrote do strings.write_string(&builder, `,`)
		memory_write_record_json(&builder, rec)
		wrote = true
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

memory_service_applicable_json :: proc(body, calling_agent_id: string) -> Memory_Service_Result {
	if deprecated, msg := memory_deprecated_subject_inputs(body); deprecated do return memory_error(400, msg)
	target_agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if target_agent_instance_id == "" do target_agent_instance_id = strings.clone(calling_agent_id)
	defer delete(target_agent_instance_id)
	team_id := extract_json_string(body, "team_id", extract_json_string(body, "team", ""))
	defer delete(team_id)
	project_id := extract_json_string(body, "project_id", "")
	defer delete(project_id)
	role_key := extract_json_string(body, "role_key", "")
	defer delete(role_key)
	task_chain_type := extract_json_string(body, "task_chain_type", "")
	defer delete(task_chain_type)

	if project_id != "" && !memory_project_id_known(project_id) do return memory_error(400, "unknown project_id target")
	if role_key != "" && !memory_role_key_known(role_key) do return memory_error(400, "unknown role_key target")
	if task_chain_type != "" && !memory_task_chain_type_known(task_chain_type) do return memory_error(400, "unknown task_chain_type target")

	records := memory_db_list_records("", .Active, false)
	defer {
		for rec in records do memory_record_free(rec)
		delete(records)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	wrote := false
	for rec in records {
		if !memory_record_applies(rec, calling_agent_id, target_agent_instance_id, team_id, project_id, role_key, task_chain_type) do continue
		if wrote do strings.write_string(&builder, `,`)
		memory_write_record_json(&builder, rec)
		wrote = true
	}
	strings.write_string(&builder, `]}`)
	return Memory_Service_Result{ok = true, status_code = 200, message = strings.to_string(builder)}
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

memory_scope_normalize :: proc(value: string) -> string {
	switch value {
	case "": return strings.clone("")
	case "team_project", "team-project", "Team_Project": return strings.clone("Team_Project")
	case "project", "Project": return strings.clone("Project")
	case "template", "Template", "global", "Global": return strings.clone("Template")
	case "personal", "Personal": return strings.clone("Personal")
	}
	return strings.clone(value)
}

memory_resolve_new_subject :: proc(author, body, subject, scope, subject_key, title: string, mem_type: contracts.Memory_Type, has_targets: bool) -> (string, string, string, bool, string) {
	resolved_scope := strings.clone(scope)
	resolved_subject := strings.clone(subject)
	resolved_subject_key := strings.clone(subject_key)
	team_id := extract_json_string(body, "team_id", extract_json_string(body, "team", ""))
	defer delete(team_id)
	project_id := extract_json_string(body, "project_id", extract_json_string(body, "project", ""))
	defer delete(project_id)
	template_key := extract_json_string(body, "template_key", extract_json_string(body, "template", ""))
	defer delete(template_key)

	if resolved_scope == "" {
		if resolved_subject_key != "" {
			if strings.has_prefix(resolved_subject_key, "tp:") do resolved_scope = strings.clone("Team_Project")
			if strings.has_prefix(resolved_subject_key, "pr:") do resolved_scope = strings.clone("Project")
			if strings.has_prefix(resolved_subject_key, "tmpl:") do resolved_scope = strings.clone("Template")
			if strings.has_prefix(resolved_subject_key, "agent:") do resolved_scope = strings.clone("Personal")
		} else if team_id != "" {
			resolved_scope = strings.clone("Team_Project")
		} else if project_id != "" {
			resolved_scope = strings.clone("Project")
		} else if template_key != "" || mem_type == .Template {
			resolved_scope = strings.clone("Template")
		} else if resolved_subject != "" {
			resolved_scope = strings.clone("Personal")
		} else if has_targets {
			return resolved_subject, resolved_scope, resolved_subject_key, true, ""
		}
	}

	switch resolved_scope {
	case "":
		if has_targets do return resolved_subject, resolved_scope, resolved_subject_key, true, ""
		return "", "", "", false, "memory proposals require a legacy scope or canonical targets"
	case "Team_Project":
		if project_id == "" {
			if idx := agent_record_index_by_instance(resolved_subject); idx >= 0 && agent_instance_records[idx].project_id != "" do project_id = strings.clone(agent_instance_records[idx].project_id)
		}
		if team_id == "" && resolved_subject != "" do team_id = memory_team_id_for_agent(resolved_subject)
		if project_id == "" do project_id = strings.clone("_orphan")
		if team_id == "" do return "", "", "", false, "team_project memories require --team and --project"
		if resolved_subject == "" do resolved_subject = strings.clone(fmt.tprintf("team:%s", team_id))
		derived := fmt.tprintf("tp:%s:%s", team_id, project_id)
		if resolved_subject_key != "" && resolved_subject_key != derived do return "", "", "", false, "subject_key does not match derived team_project target"
		delete(resolved_subject_key)
		resolved_subject_key = strings.clone(derived)
	case "Project":
		if project_id == "" {
			if idx := agent_record_index_by_instance(resolved_subject); idx >= 0 && agent_instance_records[idx].project_id != "" do project_id = strings.clone(agent_instance_records[idx].project_id)
		}
		if project_id == "" do return "", "", "", false, "project memories require --project"
		if resolved_subject == "" do resolved_subject = strings.clone(fmt.tprintf("project:%s", project_id))
		derived := fmt.tprintf("pr:%s", project_id)
		if resolved_subject_key != "" && resolved_subject_key != derived do return "", "", "", false, "subject_key does not match derived project target"
		delete(resolved_subject_key)
		resolved_subject_key = strings.clone(derived)
	case "Template":
		if template_key == "" do template_key = strings.clone(teams_v1_slug(title))
		if resolved_subject == "" do resolved_subject = strings.clone(fmt.tprintf("template:%s", template_key))
		derived := fmt.tprintf("tmpl:%s", template_key)
		if resolved_subject_key != "" && resolved_subject_key != derived do return "", "", "", false, "subject_key does not match derived template target"
		delete(resolved_subject_key)
		resolved_subject_key = strings.clone(derived)
	case "Personal":
		if !memory_personal_visible_to(author) do return "", "", "", false, "personal memories are internal-only"
		if resolved_subject == "" do resolved_subject = strings.clone(author)
		derived := fmt.tprintf("agent:%s", resolved_subject)
		if resolved_subject_key != "" && resolved_subject_key != derived do return "", "", "", false, "subject_key does not match derived personal target"
		delete(resolved_subject_key)
		resolved_subject_key = strings.clone(derived)
	case:
		return "", "", "", false, "invalid memory scope"
	}
	return resolved_subject, resolved_scope, resolved_subject_key, true, ""
}

memory_prepare_targets :: proc(project_ids, role_keys, task_chain_types: string) -> (string, string, string, bool, string) {
	project_ids_value := memory_normalize_csv(project_ids)
	role_keys_value := memory_normalize_csv(role_keys)
	task_chain_types_value := memory_normalize_csv(task_chain_types)
	if !memory_validate_project_ids(project_ids_value) do return "", "", "", false, "unknown project_id target"
	if !memory_validate_role_keys(role_keys_value) do return "", "", "", false, "unknown role_key target"
	if !memory_validate_task_chain_types(task_chain_types_value) do return "", "", "", false, "unknown task_chain_type target"
	return project_ids_value, role_keys_value, task_chain_types_value, true, ""
}

memory_validate_scope_targets :: proc(scope, subject_key, project_ids, role_keys, task_chain_types: string) -> (bool, string) {
	has_targets := project_ids != "" || role_keys != "" || task_chain_types != ""
	switch scope {
	case "":
		if !has_targets do return false, "memory proposals require a legacy scope or canonical targets"
		return true, ""
	case "Template":
		if has_targets do return false, "template memories stay separate in v1; targeting fields are not allowed"
		return true, ""
	case "Personal":
		if has_targets do return false, "personal memories cannot use project/role/task-chain targeting"
		return true, ""
	case "Project", "Team_Project":
		legacy_project := memory_project_id_from_subject(scope, subject_key)
		if legacy_project != "" && project_ids != "" && !memory_csv_contains(project_ids, legacy_project) {
			return false, "project_ids must include the legacy project target"
		}
		return true, ""
	case:
		return false, "invalid memory scope"
	}
}

memory_edit_targeting_changed :: proc(body, subject, scope, subject_key, project_ids, role_keys, task_chain_types: string, target: contracts.Memory_Record) -> (bool, string) {
	if subject != "" && subject != target.legacy_subject_agent do return true, "material retargets require archive+new in v1"
	if scope != "" && scope != target.scope do return true, "material retargets require archive+new in v1"
	if subject_key != "" && subject_key != target.legacy_subject_key do return true, "material retargets require archive+new in v1"
	if project_ids != "" && project_ids != target.project_ids do return true, "material retargets require archive+new in v1"
	if role_keys != "" && role_keys != target.role_keys do return true, "material retargets require archive+new in v1"
	if task_chain_types != "" && task_chain_types != target.task_chain_types do return true, "material retargets require archive+new in v1"
	if json_has_key(body, "team_id") || json_has_key(body, "team") || json_has_key(body, "project") || json_has_key(body, "template_key") || json_has_key(body, "template") {
		return true, "material retargets require archive+new in v1"
	}
	return false, ""
}

memory_team_id_for_agent :: proc(agent_instance_id: string) -> string {
	if strings.has_suffix(agent_instance_id, "@swe-team") do return strings.clone("swe-team-legacy")
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		agent_record_id := agent_instance_records[idx].agent_record_id
		teams := team_db_list_teams(team_service_db, "", "")
		defer {
			for team in teams {
				delete(team.team_id)
				delete(team.project_id)
				delete(team.kind)
				delete(team.status)
				delete(team.chain_id)
			}
			delete(teams)
		}
		for team in teams {
			members := team_db_list_members(team_service_db, team.team_id)
			for member in members {
				if member.agent_record_id == agent_record_id {
					for other in members {
						delete(other.team_id)
						delete(other.role_key)
						delete(other.agent_record_id)
						delete(other.route_to)
					}
					delete(members)
					return strings.clone(team.team_id)
				}
				delete(member.team_id)
				delete(member.role_key)
				delete(member.agent_record_id)
				delete(member.route_to)
			}
			delete(members)
		}
	}
	return strings.clone(fmt.tprintf("legacy-%s", agent_instance_id))
}

memory_subject_key_from_request :: proc(body, scope, subject: string) -> string {
	explicit := extract_json_string(body, "subject_key", "")
	if explicit != "" do return explicit
	team_id := extract_json_string(body, "team_id", extract_json_string(body, "team", ""))
	defer delete(team_id)
	project_id := extract_json_string(body, "project_id", extract_json_string(body, "project", ""))
	defer delete(project_id)
	template_key := extract_json_string(body, "template_key", extract_json_string(body, "template", ""))
	defer delete(template_key)
	switch scope {
	case "Team_Project":
		if team_id == "" && subject != "" do team_id = memory_team_id_for_agent(subject)
		if project_id == "" {
			if idx := agent_record_index_by_instance(subject); idx >= 0 && agent_instance_records[idx].project_id != "" do project_id = strings.clone(agent_instance_records[idx].project_id)
		}
		if team_id != "" && project_id != "" do return strings.clone(fmt.tprintf("tp:%s:%s", team_id, project_id))
	case "Project":
		if project_id == "" {
			if idx := agent_record_index_by_instance(subject); idx >= 0 && agent_instance_records[idx].project_id != "" do project_id = strings.clone(agent_instance_records[idx].project_id)
		}
		if project_id != "" do return strings.clone(fmt.tprintf("pr:%s", project_id))
	case "Template":
		if template_key != "" do return strings.clone(fmt.tprintf("tmpl:%s", template_key))
	case "Personal":
		if subject != "" do return strings.clone(fmt.tprintf("agent:%s", subject))
	}
	return strings.clone("")
}

memory_personal_visible_to :: proc(calling_agent_id: string) -> bool {
	if calling_agent_id == "" do return false
	return strings.has_suffix(calling_agent_id, "@heimdall-system")
}

memory_project_id_known :: proc(value: string) -> bool {
	if value == "" do return false
	return project_index(value) >= 0
}

memory_role_key_known :: proc(value: string) -> bool {
	if value == "" do return false
	for kind in team_kind_list() {
		for role in kind.roles {
			if role.role_key == value do return true
		}
	}
	return false
}

memory_task_chain_type_known :: proc(value: string) -> bool {
	if value == "" do return false
	return team_kind_get(value) != nil
}

memory_validate_project_ids :: proc(csv: string) -> bool {
	entries := memory_csv_entries(csv)
	defer delete(entries)
	for entry in entries {
		if !memory_project_id_known(entry) do return false
	}
	return true
}

memory_validate_role_keys :: proc(csv: string) -> bool {
	entries := memory_csv_entries(csv)
	defer delete(entries)
	for entry in entries {
		if !memory_role_key_known(entry) do return false
	}
	return true
}

memory_validate_task_chain_types :: proc(csv: string) -> bool {
	entries := memory_csv_entries(csv)
	defer delete(entries)
	for entry in entries {
		if !memory_task_chain_type_known(entry) do return false
	}
	return true
}

memory_csv_entries :: proc(value: string) -> [dynamic]string {
	result := make([dynamic]string)
	parts := strings.split(value, ",")
	for part in parts {
		trimmed := strings.trim_space(part)
		if trimmed == "" do continue
		seen := false
		for existing in result {
			if existing == trimmed {
				seen = true
				break
			}
		}
		if !seen do append(&result, strings.clone(trimmed))
	}
	return result
}

memory_normalize_csv :: proc(value: string) -> string {
	entries := memory_csv_entries(value)
	defer {
		for entry in entries do delete(entry)
		delete(entries)
	}
	return memory_join_csv(entries[:])
}

memory_sort_strings :: proc(values: []string) {
	for i in 1..<len(values) {
		j := i
		for j > 0 && strings.compare(values[j-1], values[j]) > 0 {
			values[j-1], values[j] = values[j], values[j-1]
			j -= 1
		}
	}
}

memory_canonical_csv :: proc(value: string) -> string {
	entries := memory_csv_entries(value)
	defer {
		for entry in entries do delete(entry)
		delete(entries)
	}
	memory_sort_strings(entries[:])
	return memory_join_csv(entries[:])
}

memory_join_csv :: proc(values: []string) -> string {
	builder := strings.builder_make()
	first := true
	for value in values {
		trimmed := strings.trim_space(value)
		if trimmed == "" do continue
		if !first do strings.write_string(&builder, ",")
		first = false
		strings.write_string(&builder, trimmed)
	}
	return strings.to_string(builder)
}

memory_csv_contains :: proc(csv, value: string) -> bool {
	entries := memory_csv_entries(csv)
	defer {
		for entry in entries do delete(entry)
		delete(entries)
	}
	for entry in entries {
		if entry == value do return true
	}
	return false
}

memory_dimension_matches :: proc(csv, value: string) -> bool {
	if csv == "" do return true
	if value == "" do return false
	return memory_csv_contains(csv, value)
}

memory_dimension_filter_matches :: proc(record_csv, filter_csv: string) -> bool {
	if filter_csv == "" do return true
	if record_csv == "" do return true
	return memory_csv_overlaps(record_csv, filter_csv)
}

memory_csv_overlaps :: proc(left_csv, right_csv: string) -> bool {
	left_entries := memory_csv_entries(left_csv)
	defer {
		for entry in left_entries do delete(entry)
		delete(left_entries)
	}
	for entry in left_entries {
		if memory_csv_contains(right_csv, entry) do return true
	}
	return false
}

memory_project_id_from_subject :: proc(scope, legacy_subject_key: string) -> string {
	if legacy_subject_key == "" do return ""
	switch scope {
	case "Project":
		if strings.has_prefix(legacy_subject_key, "pr:") && len(legacy_subject_key) > 3 do return strings.clone(legacy_subject_key[3:])
	case "Team_Project":
		if !strings.has_prefix(legacy_subject_key, "tp:") do return ""
		rest := legacy_subject_key[3:]
		sep := strings.index_byte(rest, ':')
		if sep >= 0 && sep < len(rest)-1 do return strings.clone(rest[sep+1:])
	}
	return ""
}

memory_team_id_from_subject :: proc(scope, legacy_subject_key: string) -> string {
	if scope != "Team_Project" || !strings.has_prefix(legacy_subject_key, "tp:") do return ""
	rest := legacy_subject_key[3:]
	sep := strings.index_byte(rest, ':')
	if sep > 0 do return strings.clone(rest[:sep])
	return ""
}

memory_template_key_from_subject :: proc(scope, legacy_subject_key: string) -> string {
	if scope != "Template" || !strings.has_prefix(legacy_subject_key, "tmpl:") do return ""
	if len(legacy_subject_key) <= 5 do return ""
	return strings.clone(legacy_subject_key[5:])
}

memory_agent_instance_id_from_subject :: proc(scope, legacy_subject_agent, legacy_subject_key: string) -> string {
	if scope == "Personal" {
		if strings.has_prefix(legacy_subject_key, "agent:") && len(legacy_subject_key) > 6 do return strings.clone(legacy_subject_key[6:])
		if legacy_subject_agent != "" do return strings.clone(legacy_subject_agent)
	}
	return ""
}

memory_primary_csv_value :: proc(csv: string) -> string {
	entries := memory_csv_entries(csv)
	defer {
		for entry in entries do delete(entry)
		delete(entries)
	}
	if len(entries) > 0 do return strings.clone(entries[0])
	return ""
}

memory_record_normalize_legacy :: proc(rec: ^contracts.Memory_Record) {
	if rec.scope == "Project" || rec.scope == "Team_Project" {
		legacy_project := memory_project_id_from_subject(rec.scope, rec.legacy_subject_key)
		defer delete(legacy_project)
		if rec.project_ids == "" && legacy_project != "" do rec.project_ids = strings.clone(legacy_project)
	}
	if rec.team_id == "" {
		team_id := memory_team_id_from_subject(rec.scope, rec.legacy_subject_key)
		if team_id != "" {
			rec.team_id = team_id
		} else {
			delete(team_id)
		}
	}
	if rec.template_key == "" {
		template_key := memory_template_key_from_subject(rec.scope, rec.legacy_subject_key)
		if template_key != "" {
			rec.template_key = template_key
		} else {
			delete(template_key)
		}
	}
	if rec.agent_instance_id == "" {
		agent_instance_id := memory_agent_instance_id_from_subject(rec.scope, rec.legacy_subject_agent, rec.legacy_subject_key)
		if agent_instance_id != "" {
			rec.agent_instance_id = agent_instance_id
		} else {
			delete(agent_instance_id)
		}
	}
}

memory_target_string :: proc(scope, agent_instance_id, team_id, template_key, project_ids: string) -> string {
	switch scope {
	case "Personal":
		if agent_instance_id != "" do return strings.clone(fmt.tprintf("agent:%s", agent_instance_id))
	case "Team_Project":
		project_id := memory_primary_csv_value(project_ids)
		defer delete(project_id)
		if team_id != "" && project_id != "" do return strings.clone(fmt.tprintf("team:%s project:%s", team_id, project_id))
		if team_id != "" do return strings.clone(fmt.tprintf("team:%s", team_id))
	case "Project":
		project_id := memory_primary_csv_value(project_ids)
		defer delete(project_id)
		if project_id != "" do return strings.clone(fmt.tprintf("project:%s", project_id))
	case "Template":
		if template_key != "" do return strings.clone(fmt.tprintf("template:%s", template_key))
	}
	if project_ids != "" do return strings.clone(project_ids)
	if scope != "" do return strings.clone(scope)
	return strings.clone("")
}

memory_expertise_bucket_key :: proc(rec: contracts.Memory_Record) -> string {
	canonical_project_ids := memory_canonical_csv(rec.project_ids)
	defer delete(canonical_project_ids)
	canonical_role_keys := memory_canonical_csv(rec.role_keys)
	defer delete(canonical_role_keys)
	canonical_task_chain_types := memory_canonical_csv(rec.task_chain_types)
	defer delete(canonical_task_chain_types)
	builder := strings.builder_make()
	strings.write_string(&builder, strings.to_lower(rec.scope))
	strings.write_string(&builder, "|")
	strings.write_string(&builder, rec.agent_instance_id)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, rec.team_id)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, rec.template_key)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, canonical_project_ids)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, canonical_role_keys)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, canonical_task_chain_types)
	strings.write_string(&builder, "|")
	strings.write_string(&builder, teams_v1_slug(rec.title))
	return strings.to_string(builder)
}

memory_canonical_scope_applies :: proc(rec: contracts.Memory_Record, calling_agent_id, target_agent_instance_id, team_id, project_id: string) -> bool {
	switch rec.scope {
	case "":
		return true
	case "Project":
		if project_id == "" do return false
		return memory_dimension_matches(rec.project_ids, project_id)
	case "Team_Project":
		if team_id == "" || project_id == "" do return false
		if rec.team_id != team_id do return false
		return memory_dimension_matches(rec.project_ids, project_id)
	case "Personal":
		if !memory_personal_visible_to(calling_agent_id) do return false
		return rec.agent_instance_id != "" && rec.agent_instance_id == target_agent_instance_id
	case "Template":
		return false
	case:
		return false
	}
}

memory_record_applies :: proc(rec: contracts.Memory_Record, calling_agent_id, target_agent_instance_id, team_id, project_id, role_key, task_chain_type: string) -> bool {
	if rec.status != .Active do return false
	if rec.scope == "Template" || rec.type == .Template do return false
	if !memory_canonical_scope_applies(rec, calling_agent_id, target_agent_instance_id, team_id, project_id) do return false
	if !memory_dimension_matches(rec.role_keys, role_key) do return false
	if !memory_dimension_matches(rec.task_chain_types, task_chain_type) do return false
	return true
}

memory_record_matches_filters :: proc(rec: contracts.Memory_Record, type_filter, agent_instance_id_filter, team_id_filter, template_key_filter, project_ids_filter, role_keys_filter, task_chain_types_filter, calling_agent_id: string) -> bool {
	if rec.scope == "Personal" && !memory_personal_visible_to(calling_agent_id) do return false
	if type_filter != "" && memory_type_string_service(rec.type) != type_filter do return false
	if agent_instance_id_filter != "" && rec.agent_instance_id != agent_instance_id_filter do return false
	if team_id_filter != "" && rec.team_id != team_id_filter do return false
	if template_key_filter != "" && rec.template_key != template_key_filter do return false
	if !memory_dimension_filter_matches(rec.project_ids, project_ids_filter) do return false
	if !memory_dimension_filter_matches(rec.role_keys, role_keys_filter) do return false
	if !memory_dimension_filter_matches(rec.task_chain_types, task_chain_types_filter) do return false
	if rec.scope == "Template" || rec.type == .Template {
		return project_ids_filter == "" && role_keys_filter == "" && task_chain_types_filter == ""
	}
	if rec.scope == "Personal" {
		return project_ids_filter == "" && role_keys_filter == "" && task_chain_types_filter == ""
	}
	return true
}

memory_write_csv_json_array :: proc(builder: ^strings.Builder, csv: string) {
	entries := memory_csv_entries(csv)
	defer {
		for entry in entries do delete(entry)
		delete(entries)
	}
	strings.write_string(builder, `[`) 
	for entry, i in entries {
		if i > 0 do strings.write_string(builder, `,`)
		strings.write_string(builder, `"`)
		json_write_string(builder, entry)
		strings.write_string(builder, `"`)
	}
	strings.write_string(builder, `]`)
}

memory_write_record_json :: proc(builder: ^strings.Builder, rec: contracts.Memory_Record) {
	strings.write_string(builder, `{"memory_id":"`); json_write_string(builder, rec.memory_id)
	strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, rec.proposal_id)
	strings.write_string(builder, `","scope":"`); json_write_string(builder, rec.scope)
	strings.write_string(builder, `","agent_instance_id":"`); json_write_string(builder, rec.agent_instance_id)
	strings.write_string(builder, `","team_id":"`); json_write_string(builder, rec.team_id)
	strings.write_string(builder, `","template_key":"`); json_write_string(builder, rec.template_key)
	strings.write_string(builder, `","project_ids":`); memory_write_csv_json_array(builder, rec.project_ids)
	strings.write_string(builder, `,"role_keys":`); memory_write_csv_json_array(builder, rec.role_keys)
	strings.write_string(builder, `,"task_chain_types":`); memory_write_csv_json_array(builder, rec.task_chain_types)
	strings.write_string(builder, `,"type":"`); json_write_string(builder, memory_type_string_service(rec.type))
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
	strings.write_string(builder, `{"event_id":"`); json_write_string(builder, ev.event_id)
	strings.write_string(builder, `","memory_id":"`); json_write_string(builder, ev.memory_id)
	strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, ev.proposal_id)
	strings.write_string(builder, `","scope":"`); json_write_string(builder, ev.scope)
	strings.write_string(builder, `","agent_instance_id":"`); json_write_string(builder, ev.agent_instance_id)
	strings.write_string(builder, `","team_id":"`); json_write_string(builder, ev.team_id)
	strings.write_string(builder, `","template_key":"`); json_write_string(builder, ev.template_key)
	strings.write_string(builder, `","project_ids":`); memory_write_csv_json_array(builder, ev.project_ids)
	strings.write_string(builder, `,"role_keys":`); memory_write_csv_json_array(builder, ev.role_keys)
	strings.write_string(builder, `,"task_chain_types":`); memory_write_csv_json_array(builder, ev.task_chain_types)
	strings.write_string(builder, `,"reason":"`); json_write_string(builder, ev.reason)
	strings.write_string(builder, `","evidence":"`); json_write_string(builder, ev.evidence)
	strings.write_string(builder, `","author":"`); json_write_string(builder, ev.author)
	strings.write_string(builder, `","source_task_id":"`); json_write_string(builder, ev.source_task_id)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", ev.created_unix_ms))
	strings.write_string(builder, `}`)
}
