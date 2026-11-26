package taskv2

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// Who must review a task (spec SCHED, section 6.2 / 6.3): brief.reviewers lists
// agent ids and, optionally, the literal `user`. Every listed agent owes one
// review of the current attempt, recorded as an agent verdict
// (domain.REVIEW_ROLE_AGENT); `user` is the same as requires_user_approval. One
// review lease per (task, reviewer agent) and no roles (REQ-SCHED-4..6). Nobody
// reviews their own work: the attempt's author agent never owes a review.

// REVIEWER_USER is the brief.reviewers entry for the human user.
REVIEWER_USER :: "user"

// brief_reviewer_entries: brief.reviewers trimmed, no blanks, no duplicates,
// `user` included.
brief_reviewer_entries :: proc(brief_json: string, allocator := context.allocator) -> [dynamic]string {
	raw := jsonx.extract_string_array(brief_json, "reviewers", true, context.temp_allocator)
	out := make([dynamic]string, allocator)
	for r in raw {
		id := strings.trim_space(r)
		if id == "" do continue
		dup := false
		for o in out do if o == id { dup = true; break }
		if !dup do append(&out, strings.clone(id, allocator))
	}
	return out
}

// brief_reviewer_agents: the agent ids in brief.reviewers (without `user`).
brief_reviewer_agents :: proc(brief_json: string, allocator := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	for id in brief_reviewer_entries(brief_json, context.temp_allocator) {
		if id == REVIEWER_USER do continue
		append(&out, strings.clone(id, allocator))
	}
	return out
}

// brief_lists_user: brief.reviewers names the user.
brief_lists_user :: proc(brief_json: string) -> bool {
	for id in brief_reviewer_entries(brief_json, context.temp_allocator) do if id == REVIEWER_USER do return true
	return false
}

// task_requires_user: the user must approve the task's current attempt —
// requires_user_approval, or `user` listed in brief.reviewers (6.2).
task_requires_user :: proc(task: domain.Task) -> bool {
	return task.requires_user_approval || brief_lists_user(task.brief_json)
}

// required_reviewers: the reviewer agents that must approve the task's current
// attempt — brief.reviewers without `user` and without the attempt's author
// agent. Temp-allocated.
required_reviewers :: proc(task: domain.Task, author_agent: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for id in brief_reviewer_agents(task.brief_json, context.temp_allocator) {
		if author_agent != "" && id == author_agent do continue
		append(&out, id)
	}
	return out[:]
}

// agent_approved: `agent_id` posted an approve on the task's current attempt.
agent_approved :: proc(reviews: []domain.Task_Review, task: domain.Task, agent_id: string) -> bool {
	for r in reviews {
		if r.attempt_no == task.attempt_no && r.verdict == "approve" && r.reviewer_kind == "agent" && agent_verdict_role(r.role) && r.reviewer_agent_id == agent_id do return true
	}
	return false
}

// agent_review_owed: `agent_id` has posted no verdict on the current attempt.
agent_review_owed :: proc(reviews: []domain.Task_Review, task: domain.Task, agent_id: string) -> bool {
	for r in reviews {
		if r.attempt_no == task.attempt_no && r.reviewer_kind == "agent" && agent_verdict_role(r.role) && r.reviewer_agent_id == agent_id do return false
	}
	return true
}

// agent_verdict_role: a review row written by a reviewer agent, not a gate
// approval ("coordinator"), a proxy for the user ("user") or an audit row kept
// by migration 129 ("legacy-verify:<role>"), which never counts.
agent_verdict_role :: proc(role: string) -> bool {
	return role != "coordinator" && role != "user" && !strings.has_prefix(role, "legacy-verify:")
}

// task_author_agent: the agent of the current attempt's holder ("" when unknown).
task_author_agent :: proc(svc: ^Service, task: domain.Task) -> string {
	holder := last_attempt_holder(svc, task)
	if holder == "" do return ""
	if inst, ok, _ := iface.agent_get_instance(svc.agents, holder); ok do return inst.agent_id
	return ""
}

// fleet_row_for_agent: the agent's fleet row in the chain.
fleet_row_for_agent :: proc(fleets: []domain.Task_Chain_Fleet, agent_id: string) -> (domain.Task_Chain_Fleet, bool) {
	for f in fleets do if f.agent_id == agent_id do return f, true
	return {}, false
}

// review_focus_for: brief.review_focus[agent_id] — what that reviewer should
// check (replaces review-role descriptions, 6.2). "" when unset.
review_focus_for :: proc(brief_json, agent_id: string) -> string {
	obj, ok := jsonx.extract_raw_object(brief_json, "review_focus", true, context.temp_allocator)
	if !ok do return ""
	return strings.trim_space(jsonx.extract_string(obj, agent_id, "", true, context.temp_allocator))
}
