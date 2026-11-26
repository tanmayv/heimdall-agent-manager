package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// Review gate (plan §2.5, spec SCHED 6.3). Evaluated inside the UoW after every
// review post, reviewer/fleet change, and once at boot after a gate-affecting
// migration, for a task in `in_review`:
//
//   needed = required_reviewers: the agents in brief.reviewers, minus the
//            attempt's author agent
//   gate   = every needed agent has an `approve` on THIS attempt
//            ∧ no `request_changes` on this attempt
//            ∧ (user approved on this attempt, if requires_user_approval or
//               `user` is listed in brief.reviewers)
//
// A verdict is the reviewer's judgment; no command evidence is required
// (REQ-TV2-2). Strict AND per reviewer agent. Any request_changes →
// EV_CHANGES_REQUESTED (task → ready, other review leases deleted); the
// oscillation guard (fold) parks the task after 3 rounds. A new attempt
// invalidates prior reviews because reviews are keyed by attempt_no.

// Rejected: a request_changes on a GATE task (it is cancelled). Explicit-verdict
// callers (review_post, user_review) then run gate_replan_in_uow; the fleet
// change and boot paths keep the plain cancel (F1).
Gate_Result :: enum { Waiting, Approved, Changes_Requested, Rejected }

gate_approver_policy :: proc(task: domain.Task) -> string {
	approver := jsonx.extract_string(task.brief_json, "approver", "user_or_coordinator", true, context.temp_allocator)
	if gate_obj, gok := jsonx.extract_raw_object(task.brief_json, "gate", true, context.temp_allocator); gok {
		if a := jsonx.extract_string(gate_obj, "approver", "", true, context.temp_allocator); a != "" do approver = a
	}
	if task.requires_user_approval do return "user"
	return approver
}

evaluate_gate_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, task_in: domain.Task, actor: Actor) -> (Gate_Result, bool, domain.Domain_Error) {
	task := task_in
	if task.state != .In_Review do return .Waiting, true, domain.Domain_Error{}
	if requirements_stale_review(svc, task) do return .Waiting, true, domain.Domain_Error{}
	// A held task is a repair window (REQ-TV2-5): verdicts are recorded but the
	// gate does not move until task_release re-evaluates it.
	if task_is_held(task) do return .Waiting, true, domain.Domain_Error{}
	if err := workflow_require_current_task(svc, task); err.code != .None do return .Waiting, false, err
	reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if rerr.code != .None do return .Waiting, false, rerr
	// 1. any request_changes on this attempt wins
	for r in reviews {
		if r.attempt_no != task.attempt_no || r.verdict != "request_changes" do continue
		p := json_begin()
		json_int(&p, "attempt_no", i64(task.attempt_no))
		json_str(&p, "reviewer", r.reviewer_agent_id if r.reviewer_kind == "agent" else "user")
		json_str(&p, "reviewer_agent_id", r.reviewer_agent_id)
		json_str(&p, "reviewer_instance_id", r.reviewer_instance_id)
		if _, _, ok, err := record_event(svc, u, task, actor, EV_CHANGES_REQUESTED, json_end(&p)); !ok do return .Waiting, false, err
		if task.kind == .Gate {
			cp := json_begin()
			json_str(&cp, "reason", "gate_rejected")
			if fresh, fok, _ := iface.taskchain_get_task(svc.repo, task.task_id); fok do task = fresh
			if _, _, ok, err := record_event(svc, u, task, actor, EV_CANCELLED, json_end(&cp)); !ok do return .Waiting, false, err
		}
		// Every other review lease on the task is deleted and its holder kept
		// for the grace window (REQ-SCHED-21/23); none is parked as waiting.
		if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code == .None {
			for l in leases {
				if l.kind != domain.LEASE_KIND_REVIEW do continue
				if !release_review_to_grace_in_uow(svc, u, l) do return .Waiting, false, domain.domain_error(.Internal_Error, "failed to drop a review lease")
			}
		} else {
			return .Waiting, false, lerr
		}
		if task.kind == .Gate {
			metric_gate_evaluated(.Rejected)
			return .Rejected, true, domain.Domain_Error{}
		}
		metric_gate_evaluated(.Changes_Requested)
		return .Changes_Requested, true, domain.Domain_Error{}
	}
	if task.kind == .Gate {
		approver := gate_approver_policy(task)
		gate_approved := false
		for r in reviews {
			if r.attempt_no != task.attempt_no || r.verdict != "approve" do continue
			if approver == "user" {
				if r.reviewer_kind == "user" && r.reviewer_instance_id == "" { gate_approved = true; break }
			} else {
				if r.reviewer_kind == "user" || r.role == "coordinator" { gate_approved = true; break }
			}
		}
		if !gate_approved {
			metric_gate_evaluated(.Waiting)
			return .Waiting, true, domain.Domain_Error{}
		}
		p := json_begin()
		json_int(&p, "attempt_no", i64(task.attempt_no))
		if _, _, ok, err := record_event(svc, u, task, actor, EV_APPROVED, json_end(&p)); !ok do return .Waiting, false, err
		metric_gate_evaluated(.Approved)
		return .Approved, true, domain.Domain_Error{}
	}
	// 2. every required reviewer agent approved — shared with
	//    awaits_user_review (attention deck).
	if sat, serr := agent_review_satisfied(svc, chain.chain_id, chain.owner_user_id, task, reviews); serr.code != .None {
		return .Waiting, false, serr
	} else if !sat {
		metric_gate_evaluated(.Waiting)
		return .Waiting, true, domain.Domain_Error{}
	}
	if task_requires_user(task) {
		user_ok := false
		for r in reviews do if r.attempt_no == task.attempt_no && r.verdict == "approve" && r.reviewer_kind == "user" { user_ok = true; break }
		if !user_ok {
			if err := catalog_review_request(svc, task); err.code != .None do return .Waiting, false, err
			notify_user_review_requested(svc, u, task, fmt.tprintf("[taskv2] review_requested_from_user: task %s (%s) passed review gate and awaits user approval", task.task_id, task.title))
			metric_gate_evaluated(.Waiting)
			return .Waiting, true, domain.Domain_Error{}
		}
	}
	p := json_begin()
	json_int(&p, "attempt_no", i64(task.attempt_no))
	if _, _, ok, err := record_event(svc, u, task, actor, EV_APPROVED, json_end(&p)); !ok do return .Waiting, false, err
	if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code == .None {
		for l in leases {
			if l.kind != domain.LEASE_KIND_REVIEW do continue
			if expire_lease_in_uow(svc, u, l, EXPIRE_REPLACED, actor) == .Failed do return .Waiting, false, domain.domain_error(.Internal_Error, "failed to drop a review lease")
		}
	}
	metric_gate_evaluated(.Approved)
	return .Approved, true, domain.Domain_Error{}
}

// agent_review_satisfied: step 2 of the gate for a non-gate task — every
// required reviewer agent approved this attempt. Read-only.
agent_review_satisfied :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, task: domain.Task, reviews: []domain.Task_Review) -> (bool, domain.Domain_Error) {
	for agent_id in required_reviewers(task, task_author_agent(svc, task)) {
		if !agent_approved(reviews, task, agent_id) do return false, domain.Domain_Error{}
	}
	return true, domain.Domain_Error{}
}

// ---- attention deck: does this task await the USER? ---------------------------------

// notify_user_review_requested (rule d): tell the coordinator once per gate
// pass — once per (task, attempt) — that the task now waits on the user. The
// gate is re-evaluated by every recheck, fleet change and reviewer edit; the
// audit event user_review_requested makes repeats a no-op. When the
// coordinator's own agent authored the attempt it may not approve it
// (REQ-SCHED-16) and the user's attention deck already shows the review, so no
// agent is told (and nothing is recorded) — except a workflow gate only the
// coordinator may approve, which no deck shows.
notify_user_review_requested :: proc(svc: ^Service, u: ^Uow, task: domain.Task, line: string) {
	if svc == nil || u == nil do return
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok do return
	coordinator_only_gate := task.kind == .Gate && gate_approver_policy(task) == "coordinator"
	if !coordinator_only_gate {
		if coord_agent := chain_coordinator_agent_id(svc, chain); coord_agent != "" && coord_agent == task_author_agent(svc, task) do return
	}
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None do return
	for e in evs {
		if e.kind == EV_USER_REVIEW_REQUESTED && jsonx.extract_int(e.payload_json, "attempt_no", -1, true) == task.attempt_no do return
	}
	p := json_begin()
	json_int(&p, "attempt_no", i64(task.attempt_no))
	if _, ok, _ := append_event(svc.repo, svc.clock, task, hub_actor(), EV_USER_REVIEW_REQUESTED, json_end(&p)); !ok do return
	effect_notify_coordinator(svc, u, task.chain_id, task.owner_user_id, "review_requested_from_user", line, string(task.task_id), domain.task_state_string(domain.Task_State.In_Review))
}

User_Attention :: enum { None, Review, Blocked }

// user_attention is the single rule behind the user's attention card for a
// task (card projector, accept guard, reconcile). Read-only.
//
//   Review   — in_review and it is the user's turn: a gate the user may approve
//              (approver user | user_or_coordinator) with no decision yet, or a
//              task that needs the user (requires_user_approval or `user` in
//              brief.reviewers) whose agent reviews have passed
//              (the moment the coordinator is told
//              review_requested_from_user) and the user has not approved this
//              attempt.
//   Blocked  — blocked_on set and the user can resolve it: every system block
//              (kind human, reason merge_conflict | budget_exhausted |
//              oscillation | blocked) and any agent block except kind "task"
//              (cleared automatically, C3-2) and the v2 backfill of legacy
//              paused tasks (reason paused_before_v2). `badge` is the reason for
//              the three system ones, else "question". A held task is never
//              Blocked except for a nested agent_not_running block; a held
//              Review card stays (verdicts are still recorded) and the card
//              marks it held.
user_attention :: proc(svc: ^Service, task: domain.Task) -> (kind: User_Attention, badge: string) {
	if svc == nil || domain.task_state_is_terminal(task.state) do return .None, ""
	if task.state == .In_Review && awaits_user_review(svc, task) {
		return .Review, ("gate" if task.kind == .Gate else "review")
	}
	if ok, b := blocked_on_user(task); ok do return .Blocked, b
	return .None, ""
}

awaits_user_review :: proc(svc: ^Service, task: domain.Task) -> bool {
	if svc == nil || task.state != .In_Review do return false
	reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if rerr.code != .None do return false
	for r in reviews {
		if r.attempt_no != task.attempt_no do continue
		// A decision on this attempt is already in: request_changes moves the
		// task on; the user's approve is waiting only on agents (or done).
		if r.verdict == "request_changes" do return false
		if r.verdict == "approve" && r.reviewer_kind == "user" do return false
	}
	if task.kind == .Gate {
		policy := gate_approver_policy(task)
		return policy == "user" || policy == "user_or_coordinator"
	}
	if !task_requires_user(task) do return false
	sat, serr := agent_review_satisfied(svc, task.chain_id, task.owner_user_id, task, reviews)
	return serr.code == .None && sat
}

blocked_on_user :: proc(task: domain.Task) -> (bool, string) {
	raw := task.blocked_on_json
	if len(raw) == 0 || domain.task_state_is_terminal(task.state) do return false, ""
	if jsonx.extract_string(raw, "kind", "", true, context.temp_allocator) == "task" do return false, ""
	if is_agent_not_running_block(raw) do return true, "agent_not_running"
	// A hold is an operator pause (coordinator/owner), not a question for the
	// user, and task_answer refuses a held task: only a nested
	// agent_not_running block (above; Start agent does not answer) stays
	// actionable. Matches the attention candidate query, which skips holds.
	if task_is_held(task) do return false, ""
	reason := jsonx.extract_string(raw, "reason", "", true, context.temp_allocator)
	switch reason {
	case "paused_before_v2": return false, ""
	case "merge_conflict", "budget_exhausted", "oscillation": return true, reason
	}
	return true, "question"
}

// reevaluate_gates_in_uow runs the gate for every in_review task of the chain
// (fleet_upserted/deleted trigger row).
reevaluate_gates_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) -> (bool, domain.Domain_Error) {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false, err
	for t in tasks {
		if t.state != .In_Review do continue
		if _, ok, gerr := evaluate_gate_in_uow(svc, u, chain, t, hub_actor()); !ok do return false, gerr
	}
	return true, domain.Domain_Error{}
}

// regate_after_reviewer_change (F3): the task's reviewers changed while it
// awaits review. Review leases whose agent no longer owes a review are expired
// (`replaced`; expire stops the live holder, and a late `review post` gets
// lease_lost). Then the gate is re-run: removing the last owed reviewer can
// satisfy it, which nothing else would notice (no lease left to post a
// verdict). The caller runs after_chain_change once afterwards.
regate_after_reviewer_change :: proc(svc: ^Service, u: ^Uow, task_in: domain.Task, actor: Actor) -> (bool, domain.Domain_Error) {
	task, tok, terr := iface.taskchain_get_task(svc.repo, task_in.task_id)
	if !tok do return false, terr
	// Dropping every reviewer can fold the task straight to done (a submit with
	// nothing owed is done); its review leases are still stale and end here as
	// `replaced` rather than later as `chain_closed`.
	if task.state != .In_Review && task.state != .Done do return true, domain.Domain_Error{}
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok do return false, cerr
	needed := required_reviewers(task, task_author_agent(svc, task))
	leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code != .None do return false, lerr
	for l in leases {
		if l.kind != domain.LEASE_KIND_REVIEW do continue
		agent_id := ""
		if inst, iok, _ := iface.agent_get_instance(svc.agents, l.holder_instance_id); iok do agent_id = inst.agent_id
		owed := false
		for id in needed do if id == agent_id { owed = true; break }
		if owed do continue
		if expire_lease_in_uow(svc, u, l, EXPIRE_REPLACED, actor) == .Failed {
			return false, domain.domain_error(.Internal_Error, "failed to expire a stale review lease")
		}
	}
	fresh, fok, ferr2 := iface.taskchain_get_task(svc.repo, task.task_id)
	if !fok do return false, ferr2
	if fresh.state != .In_Review do return true, domain.Domain_Error{}
	if _, gok, gerr := evaluate_gate_in_uow(svc, u, chain, fresh, actor); !gok do return false, gerr
	return true, domain.Domain_Error{}
}

// Gate_Unmet: one missing component of a `.Waiting` gate (REQ-TV2-3a).
// kind is "review" (agent_id owes an approve on this attempt) or
// "user_approval" (the user — or, for a gate task, its approver policy in
// `approver` — has not approved this attempt).
Gate_Unmet :: struct {
	kind:     string,
	agent_id: string,
	approver: string,
}

// gate_unmet_components lists why an in_review task's gate is still waiting.
// Read-only; empty when the task is not in review or nothing is missing.
gate_unmet_components :: proc(svc: ^Service, task: domain.Task) -> ([]Gate_Unmet, domain.Domain_Error) {
	out := make([dynamic]Gate_Unmet, context.temp_allocator)
	if svc == nil || task.state != .In_Review do return out[:], domain.Domain_Error{}
	reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if rerr.code != .None do return out[:], rerr
	user_approved := false
	for r in reviews do if r.attempt_no == task.attempt_no && r.verdict == "approve" && r.reviewer_kind == "user" { user_approved = true; break }
	if task.kind == .Gate {
		if !user_approved do append(&out, Gate_Unmet{kind = "user_approval", approver = gate_approver_policy(task)})
		return out[:], domain.Domain_Error{}
	}
	for agent_id in required_reviewers(task, task_author_agent(svc, task)) {
		if !agent_approved(reviews, task, agent_id) do append(&out, Gate_Unmet{kind = "review", agent_id = agent_id})
	}
	if task_requires_user(task) && !user_approved do append(&out, Gate_Unmet{kind = "user_approval"})
	return out[:], domain.Domain_Error{}
}

// gate_unmet_json renders unmet components as a JSON array.
gate_unmet_json :: proc(unmet: []Gate_Unmet) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for m, i in unmet {
		if i > 0 do strings.write_byte(&b, ',')
		p := json_begin()
		json_str(&p, "kind", m.kind)
		if m.agent_id != "" do json_str(&p, "agent_id", m.agent_id)
		if m.approver != "" do json_str(&p, "approver", m.approver)
		strings.write_string(&b, json_end(&p))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
