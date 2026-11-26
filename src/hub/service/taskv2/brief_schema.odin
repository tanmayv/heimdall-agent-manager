package taskv2

// Brief schema and reviewer identity (REQ-TV2-4). One contract for every path
// that stores a brief: taskchain create/update, chain.propose (pending and
// auto-approved) and proposal approval, and rendered workflow stages.

import "core:slice"
import "core:strings"
import json "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// BRIEF_KEYS is the brief schema. The removed verification keys
// (REMOVED_VERIFY_BRIEF_KEYS) are accepted and dropped separately.
BRIEF_KEYS := [?]string{"goal", "acceptance", "inputs", "assignee", "reviewers", "review_focus", "budget", "output", "on_output", "requires_user_approval", "approver", "gate"}

brief_key_known :: proc(key: string) -> bool {
	for k in BRIEF_KEYS do if k == key do return true
	for k in REMOVED_VERIFY_BRIEF_KEYS do if k == key do return true
	return false
}

// brief_unknown_fields lists the top-level brief keys outside the schema,
// sorted. A brief that is not a JSON object yields nil (the caller reports that).
brief_unknown_fields :: proc(brief: string) -> []string {
	if strings.trim_space(brief) == "" do return nil
	parsed, err := json.parse_string(brief, allocator = context.temp_allocator)
	if err != nil do return nil
	obj, ok := parsed.(json.Object)
	if !ok do return nil
	out := make([dynamic]string, context.temp_allocator)
	for key in obj do if !brief_key_known(key) do append(&out, key)
	slice.sort(out[:])
	return out[:]
}

write_json_string_array :: proc(b: ^strings.Builder, items: []string) {
	strings.write_byte(b, '[')
	for s, i in items {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"'); contracts.write_json_string(b, s); strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}

// unknown_brief_fields_error rejects a brief with keys outside the schema
// instead of dropping them silently.
unknown_brief_fields_error :: proc(fields: []string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"unknown_brief_fields","unknown_brief_fields":`)
	write_json_string_array(&b, fields)
	strings.write_string(&b, `,"allowed":`)
	write_json_string_array(&b, BRIEF_KEYS[:])
	strings.write_byte(&b, '}')
	return domain.domain_error(.Validation_Failed, strings.concatenate({"unknown_brief_fields: ", strings.join(fields, ", ", context.temp_allocator)}, context.temp_allocator), strings.to_string(b))
}

// validate_brief_schema: a non-empty brief must be a JSON object with only
// schema keys.
validate_brief_schema :: proc(brief: string) -> domain.Domain_Error {
	if strings.trim_space(brief) == "" do return domain.Domain_Error{}
	parsed, err := json.parse_string(brief, allocator = context.temp_allocator)
	if err != nil do return domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	obj, ok := parsed.(json.Object)
	if !ok do return domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	// Review roles are gone (REQ-SCHED-8): name the replacement, never ignore.
	if _, has := obj["review_roles"]; has do return review_roles_removed_error()
	if unknown := brief_unknown_fields(brief); len(unknown) > 0 do return unknown_brief_fields_error(unknown)
	// review_focus: {agent id: what that reviewer should check}.
	if value, has := obj["review_focus"]; has {
		if _, is_null := value.(json.Null); !is_null {
			focus, valid := value.(json.Object)
			if !valid do return domain.domain_error(.Validation_Failed, "brief.review_focus must be an object of agent id → text")
			for _, v in focus do if _, is_str := v.(json.String); !is_str do return domain.domain_error(.Validation_Failed, "brief.review_focus must be an object of agent id → text")
		}
	}
	// acceptance: an array of strings, or null to clear it on update.
	if value, has := obj["acceptance"]; has {
		if _, is_null := value.(json.Null); !is_null {
			items, valid := value.(json.Array)
			if !valid do return domain.domain_error(.Validation_Failed, "brief.acceptance must be an array of strings")
			for item in items do if _, is_str := item.(json.String); !is_str do return domain.domain_error(.Validation_Failed, "brief.acceptance must be an array of strings")
		}
	}
	return domain.Domain_Error{}
}

// reviewer_must_be_agent_id_error: brief.reviewers names durable agent
// templates (agt_…), never instances or unknown ids.
reviewer_must_be_agent_id_error :: proc(id: string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"reviewer_must_be_agent_id","reviewer":"`)
	contracts.write_json_string(&b, id)
	strings.write_string(&b, `"}`)
	why := "an instance id" if strings.has_prefix(id, "inst_") else "not a known agent template"
	return domain.domain_error(.Validation_Failed, strings.concatenate({"reviewer_must_be_agent_id: ", id, " is ", why, "; brief.reviewers takes durable agent ids (agt_…)"}, context.temp_allocator), strings.to_string(b))
}

// validate_reviewer_agent_ids checks every named reviewer is a durable agent id
// (never an inst_… instance id) that resolves to an agent template. Without an
// agent repository (unit fakes) only the instance-id rule applies.
validate_reviewer_agent_ids :: proc(agents: ^iface.Agent_Repository, reviewers: []string) -> domain.Domain_Error {
	for raw in reviewers {
		id := strings.trim_space(raw)
		if id == "" || id == REVIEWER_USER do continue
		if strings.has_prefix(id, "inst_") do return reviewer_must_be_agent_id_error(id)
		if agents != nil {
			if _, ok, _ := iface.agent_get(agents, id); !ok do return reviewer_must_be_agent_id_error(id)
		}
	}
	return domain.Domain_Error{}
}

// review_roles_removed_error (REQ-SCHED-8): a brief still sending review_roles.
review_roles_removed_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Validation_Failed, "brief.review_roles was removed: list reviewer agent ids (agt_…) or `user` in brief.reviewers, and say what each should check in brief.review_focus", `{"code":"review_roles_removed","replacement":"reviewers"}`)
}

// assignee_required_error (REQ-SCHED-3): every task names its assignee agent.
assignee_required_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Validation_Failed, "assignee is required: name the agent (agt_…) that works this task", `{"code":"assignee_required"}`)
}

// reviewer_is_assignee_error (REQ-SCHED-4): nobody reviews their own work.
reviewer_is_assignee_error :: proc(id: string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"reviewer_is_assignee","reviewer":"`)
	contracts.write_json_string(&b, id)
	strings.write_string(&b, `"}`)
	return domain.domain_error(.Validation_Failed, strings.concatenate({"the assignee cannot also be a reviewer: ", id}, context.temp_allocator), strings.to_string(b))
}

// validate_brief_assignment (REQ-SCHED-3/4): the brief names an assignee, its
// reviewers are agent ids or `user`, and the assignee is not a reviewer.
validate_brief_assignment :: proc(agents: ^iface.Agent_Repository, brief: string) -> domain.Domain_Error {
	assignee := brief_assignee(brief)
	if assignee == "" do return assignee_required_error()
	if rerr := validate_reviewer_agent_ids(agents, brief_reviewer_entries(brief, context.temp_allocator)[:]); rerr.code != .None do return rerr
	for id in brief_reviewer_agents(brief, context.temp_allocator) do if id == assignee do return reviewer_is_assignee_error(id)
	return domain.Domain_Error{}
}

// brief_requires_user: the brief asks for the user's approval —
// requires_user_approval: true, or `user` listed in reviewers (6.2). No other
// default: a task without either is not waiting for the user.
brief_requires_user :: proc(brief: string) -> bool {
	if v, present := jsonx.extract_bool_literal(brief, "requires_user_approval", true); present && v do return true
	return brief_lists_user(brief)
}
