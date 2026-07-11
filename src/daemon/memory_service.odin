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
	subject := extract_json_string(body, "subject_agent", "")
	if subject == "" {
		delete(subject)
		subject = extract_json_string(body, "agent", "")
	}
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
		resolved_subject, resolved_scope, resolved_subject_key, ok, err := memory_resolve_new_subject(author, body, subject, scope, subject_key, title, mem_type)
		if !ok do return memory_error(400, err)
		delete(subject)
		subject = resolved_subject
		delete(scope)
		scope = resolved_scope
		delete(subject_key)
		subject_key = resolved_subject_key
		new_metadata_json := memory_metadata_with_action(metadata_json, action, "")
		delete(metadata_json)
		metadata_json = new_metadata_json
	}
	if action != "new" {
		delete(subject)
		subject = strings.clone(target.subject_agent)
		delete(scope)
		scope = strings.clone(target.scope)
		delete(subject_key)
		subject_key = strings.clone(target.subject_key)
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
	event := contracts.Memory_Event{kind = .Memory_Proposed, memory_id = memory_id, proposal_id = proposal_id, subject_agent = subject, scope = scope, subject_key = subject_key, type = mem_type, title = title, body = memory_body, status = .Pending, reason = reason, evidence = evidence, metadata_json = metadata_json, author = author, source_task_id = source_task_id, version = proposal_version}
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
	subject := extract_json_string(body, "subject_agent", extract_json_string(body, "agent", ""))
	defer delete(subject)
	scope := memory_scope_normalize(extract_json_string(body, "scope", ""))
	defer delete(scope)
	subject_key := memory_subject_key_from_request(body, scope, subject)
	defer delete(subject_key)
	if scope == "Template" {
		delete(subject)
		subject = strings.clone("")
		delete(subject_key)
		subject_key = strings.clone("")
	}
	if scope == "Personal" && subject == "" {
		delete(subject)
		subject = strings.clone(calling_agent_id)
	}
	if scope == "Personal" && !memory_personal_visible_to(calling_agent_id) do return `{"ok":true,"records":[]}`

	records := memory_db_list_records(subject, scope, subject_key, status, include_all)
	defer {
		for rec in records do memory_record_free(rec)
		delete(records)
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"records":[`)
	wrote := false
	for rec in records {
		if rec.scope == "Personal" && !memory_personal_visible_to(calling_agent_id) do continue
		if wrote do strings.write_string(&builder, `,`)
		memory_write_record_json(&builder, rec)
		wrote = true
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

memory_resolve_new_subject :: proc(author, body, subject, scope, subject_key, title: string, mem_type: contracts.Memory_Type) -> (string, string, string, bool, string) {
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
			resolved_scope = strings.clone("Team_Project")
		}
	}

	switch resolved_scope {
	case "Team_Project":
		if project_id == "" {
			if idx := agent_record_index_by_instance(resolved_subject); idx >= 0 && agent_instance_records[idx].project_id != "" do project_id = strings.clone(agent_instance_records[idx].project_id)
		}
		if team_id == "" && resolved_subject != "" do team_id = memory_team_id_for_agent(resolved_subject)
		if project_id == "" do project_id = strings.clone("_orphan")
		if team_id == "" do return "", "", "", false, "team_project memories require --team and --project (or a known subject agent)"
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

memory_write_record_json :: proc(builder: ^strings.Builder, rec: contracts.Memory_Record) {
	strings.write_string(builder, `{"memory_id":"`); json_write_string(builder, rec.memory_id); strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, rec.proposal_id); strings.write_string(builder, `","subject_agent":"`); json_write_string(builder, rec.subject_agent); strings.write_string(builder, `","scope":"`); json_write_string(builder, rec.scope); strings.write_string(builder, `","subject_key":"`); json_write_string(builder, rec.subject_key); strings.write_string(builder, `","type":"`); json_write_string(builder, memory_type_string_service(rec.type)); strings.write_string(builder, `","title":"`); json_write_string(builder, rec.title); strings.write_string(builder, `","body":"`); json_write_string(builder, rec.body); strings.write_string(builder, `","status":"`); json_write_string(builder, memory_status_string_service(rec.status)); strings.write_string(builder, `","reason":"`); json_write_string(builder, rec.reason); strings.write_string(builder, `","evidence":"`); json_write_string(builder, rec.evidence); strings.write_string(builder, `","metadata_json":"`); json_write_string(builder, rec.metadata_json); strings.write_string(builder, `","source_task_id":"`); json_write_string(builder, rec.source_task_id); strings.write_string(builder, `","version":`); strings.write_string(builder, fmt.tprintf("%d", rec.version)); strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms)); strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms)); strings.write_string(builder, `}`)
}

memory_write_event_json :: proc(builder: ^strings.Builder, ev: contracts.Memory_Event) {
	strings.write_string(builder, `{"event_id":"`); json_write_string(builder, ev.event_id); strings.write_string(builder, `","memory_id":"`); json_write_string(builder, ev.memory_id); strings.write_string(builder, `","proposal_id":"`); json_write_string(builder, ev.proposal_id); strings.write_string(builder, `","subject_key":"`); json_write_string(builder, ev.subject_key); strings.write_string(builder, `","reason":"`); json_write_string(builder, ev.reason); strings.write_string(builder, `","evidence":"`); json_write_string(builder, ev.evidence); strings.write_string(builder, `","author":"`); json_write_string(builder, ev.author); strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", ev.created_unix_ms)); strings.write_string(builder, `}`)
}
