package taskv2

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent "odin_test:hub/service/agent"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// Dispatch is infrastructure failure, before work starts. Retain the attempt
// and runtime history for diagnosis, but refund its budget and park the task.
dispatch_failed_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, failure: string) -> Expire_Result {
	return agent_not_running_in_uow(svc, u, lease, failure, true)
}

// A confirmed holder that exits or loses its heartbeat is infrastructure loss
// too. Only send-failure callbacks require an unconfirmed wake (a late error
// must never revoke an already confirmed lease).
agent_not_running_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, failure: string, unconfirmed_only := false, confirmed_exit := false) -> Expire_Result {
	if inst,found,_:=iface.agent_get_instance(svc.agents,lease.holder_instance_id);found {
		if protected,_:=fleet_runtime_operation(svc,inst);protected do return .Gone
	}
	detail := failure
	current, held, err := iface.taskchain_get_lease(svc.repo, lease.lease_id)
	if !held do return .Gone if err.code == .None || err.code == .Not_Found else .Failed
	if err.code != .None do return .Failed
	if current.phase == domain.LEASE_PHASE_WAITING do return .Gone
	if unconfirmed_only && (current.confirmed_at != "" || current.delivery != domain.LEASE_DELIVERY_WAKE) do return .Gone
	// A failed wake of a handoff continuation did not create a new attempt.
	// Keep the earlier worker's budget charge and resume that same attempt.
	continuation := false
	if lease.kind == domain.LEASE_KIND_WORK {
		evs, eerr := iface.taskchain_list_events_by_task(svc.repo, lease.task_id, lease.owner_user_id)
		if eerr.code != .None do return .Failed
		for ev, i in evs {
			if ev.kind != EV_LEASE_GRANTED || jsonx.extract_string(ev.payload_json, "lease_id", "", true, context.temp_allocator) != lease.lease_id do continue
			pre := fold_task(evs[:i], Fold_Input{deps_done = true})
			continuation = pre.last_release == .Handoff
			break
		}
	}
	provider, model, bridge, agent_id, cause := lease.provider, lease.model, lease.bridge_id, "", ""
	if inst, ok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); ok {
		agent_id = inst.agent_id
		// Only bridge absence: no failure report, error or user stop explains
		// the loss. The bridge hello then answers this block and rematches.
		if !confirmed_exit && !bridge_online(svc, inst.bridge_id) && inst.stopped_by == "" && jsonx.extract_string(inst.last_error_json, "message", "", true, context.temp_allocator) == "" {
			cause = "bridge_offline"
		}
		if provider == "" do provider = inst.provider
		if model == "" && (lease.provider == "" || lease.provider == inst.provider) do model = inst.model
		if bridge == "" do bridge = inst.bridge_id
		if message := jsonx.extract_string(inst.last_error_json, "message", "", true, context.temp_allocator); message != "" {
			detail = fmt.tprintf("%s (%s)", message, inst.runtime_status)
		} else if inst.runtime_status == "failed" || inst.runtime_status == "stopped" || inst.runtime_status == "unreachable" {
			detail = fmt.tprintf("%s (%s)", detail, inst.runtime_status)
		}
	}
	if strings.trim_space(detail) == "" do detail = "launch failed before startup confirmation"
	waiting := json_begin()
	json_str(&waiting, "kind", "agent_not_running")
	json_str(&waiting, "agent_id", agent_id)
	json_str(&waiting, "bridge_id", bridge)
	if cause != "" do json_str(&waiting, "cause", cause)
	json_str(&waiting, "provider", provider)
	json_str(&waiting, "model", model)
	json_str(&waiting, "reason", fmt.tprintf("Agent %s (%s/%s) on bridge %s is not running: %s", agent_id, provider, model, bridge, detail))
	json_int(&waiting, "since_ms", now_ms(svc.clock))
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "kind", lease.kind)
	json_int(&p, "attempt_no", i64(lease.attempt_no))
	json_bool(&p, "dispatch_failed", true)
	json_bool(&p, "continuation", continuation)
	json_raw(&p, "waiting_on", json_end(&waiting))
	// A failed dispatch never proves the child needs stopping, and a
	// confirmed exit has already stopped it. Keep the parked claim without
	// enqueueing an unfenced command against a possibly live process.
	if _, ok, _ := release_in_uow(svc, u, lease, hub_actor(), EV_BLOCKED, json_end(&p), "dispatch_failed", false); !ok do return .Failed
	if lease.kind == domain.LEASE_KIND_WORK && !continuation {
		attempts, aerr := iface.taskchain_list_attempts_by_task(svc.repo, lease.task_id, lease.owner_user_id)
		if aerr.code != .None do return .Failed
		for a in attempts {
			if a.attempt_no != lease.attempt_no do continue
			refunded := a
			refunded.counts_toward_budget = false
			if _, ok, _ := iface.taskchain_save_attempt(svc.repo, refunded); !ok do return .Failed
		}
	}
	return .Expired
}

// Read legacy dispatch blocks as the same recoverable infrastructure block.
is_agent_not_running_block :: proc(raw: string) -> bool {
	kind := jsonx.extract_string(raw, "kind", "", true, context.temp_allocator)
	return kind == "agent_not_running" || kind == "dispatch"
}

block_ready_agent_in_uow :: proc(svc: ^Service, u: ^Uow, task: domain.Task, agent_id: string, placement_in: Placement, failure: string, cause := "") -> bool {
	placement := placement_in
	if instances, err := iface.agent_list_instances_by_chain(svc.agents, task.owner_user_id, string(task.chain_id)); err.code == .None {
		for inst in instances {
			if inst.agent_id != agent_id || inst.bridge_id != placement.bridge_id do continue
			if placement.provider == "" do placement.provider = inst.provider
			if placement.model == "" && placement.provider == inst.provider do placement.model = inst.model
			break
		}
	}
	if placement.provider == "" do placement.provider = "unresolved"
	if placement.model == "" do placement.model = "unresolved"
	waiting := json_begin()
	json_str(&waiting, "kind", "agent_not_running")
	json_str(&waiting, "agent_id", agent_id)
	json_str(&waiting, "bridge_id", placement.bridge_id)
	if cause != "" do json_str(&waiting, "cause", cause)
	json_str(&waiting, "provider", placement.provider)
	json_str(&waiting, "model", placement.model)
	json_str(&waiting, "reason", fmt.tprintf("Agent %s (%s/%s) on bridge %s is not running: %s", agent_id, placement.provider, placement.model, placement.bridge_id, failure))
	json_int(&waiting, "since_ms", now_ms(svc.clock))
	p := json_begin()
	json_raw(&p, "waiting_on", json_end(&waiting))
	// No lease or attempt was created; do not refund an earlier attempt.
	json_bool(&p, "infrastructure", true)
	_, _, ok, _ := record_event(svc, u, task, hub_actor(), EV_BLOCKED, json_end(&p))
	return ok
}

// An explicit user retry makes failed/stopped instances eligible for the normal
// wake path again. No bridge I/O occurs under the UoW; the matcher dispatches
// after commit. Re-read afterwards so synchronous launch/send failures are
// returned to the card as well as persisted in its newly projected reason.
start_task_agent :: proc(svc: ^Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, expected_waiting_on := "") -> (bool, domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return false, domain.domain_error(.Forbidden, "only the user may start a task agent")
	u, ok, err := begin_uow(svc)
	if !ok do return false, err
	task, found, _ := iface.taskchain_get_task(svc.repo, task_id)
	if !found || string(task.owner_user_id) != auth.user_id {
		_, _ = end_uow(svc, &u, false)
		return false, domain.domain_error(.Not_Found, "task not found")
	}
	// Card validation happens before this transaction; this second read closes
	// the race with a newly recorded failure between the two reads.
	if expected_waiting_on != "" && expected_waiting_on != task.blocked_on_json {
		_, _ = end_uow(svc, &u, false)
		return false, domain.domain_error(.Conflict, "the agent failure changed; reload the card")
	}
	if !is_agent_not_running_block(task.blocked_on_json) {
		_, _ = end_uow(svc, &u, false)
		return false, domain.domain_error(.Conflict, "task is no longer waiting for its agent")
	}
	agent_id := jsonx.extract_string(task.blocked_on_json, "agent_id", "", true, context.temp_allocator)
	// An item for the coordinator's agent is pulled by the coordinator itself
	// (REQ-SCHED-13): Start agent restarts that instance, never a fleet copy.
	if chain, chain_found, _ := iface.taskchain_get_chain(svc.repo, task.chain_id); chain_found && chain.coordinator_agent_instance_id != "" {
		if coord, coord_found, _ := iface.agent_get_instance(svc.agents, chain.coordinator_agent_instance_id); coord_found && coord.agent_id == agent_id {
			_, cerr := end_uow(svc, &u, true)
			if cerr.code != .None do return false, cerr
			return start_blocked_task_instance(svc, auth, task, coord)
		}
	}
	bridge_id := jsonx.extract_string(task.blocked_on_json, "bridge_id", "", true, context.temp_allocator)
	// A retained claim identifies exactly which instance the user's Start agent
	// action belongs to. Do not synthesize a stopped projection so a matcher
	// can dispatch it as an automatic wake.
	claims, claim_err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if claim_err.code != .None {
		_, _ = end_uow(svc, &u, false)
		return false, claim_err
	}
	for claim in claims {
		if claim.phase != domain.LEASE_PHASE_WAITING do continue
		inst, present, _ := iface.agent_get_instance(svc.agents, claim.holder_instance_id)
		if !present do continue
		defer domain.agent_instance_destroy(&inst)
		if inst.agent_id != agent_id || (bridge_id != "" && inst.bridge_id != bridge_id) do continue
		_, cerr := end_uow(svc, &u, true)
		if cerr.code != .None do return false, cerr
		return start_blocked_task_instance(svc, auth, task, inst)
	}
	if reset, reset_err := reset_idle_agent_instances(svc, &u, task.owner_user_id, task.chain_id, agent_id, bridge_id, true, task.task_id); !reset {
		_, _ = end_uow(svc, &u, false)
		return false, reset_err
	}
	_, _, acted, aerr := record_event(svc, &u, task, actor_from_auth(auth), EV_ANSWERED, `{}`)
	// The agent's instances were reset: its other waiting items may run too.
	match_scope_note_agent(task.chain_id, agent_id)
	if acted do acted, aerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Fleet_Changed)
	_, cerr := end_uow(svc, &u, acted)
	if !acted do return false, aerr
	if cerr.code != .None do return false, cerr
	fresh, fresh_found, fresh_err := iface.taskchain_get_task(svc.repo, task_id)
	if !fresh_found || fresh_err.code != .None do return false, fresh_err
	if is_agent_not_running_block(fresh.blocked_on_json) {
		return false, domain.domain_error(.Conflict, jsonx.extract_string(fresh.blocked_on_json, "reason", "Agent failed to start", true, context.temp_allocator))
	}
	return true, domain.Domain_Error{}
}

// Called after commit when the wake command could not even be sent. Re-read
// the lease inside the transaction: a racing start-success wins over failure.
on_dispatch_failed :: proc(svc: ^Service, lease_id, detail: string) {
	u, ok, _ := begin_uow(svc)
	if !ok do return
	lease, held, err := iface.taskchain_get_lease(svc.repo, lease_id)
	if err.code != .None || !held { _, _ = end_uow(svc, &u, false); return }
	result := dispatch_failed_in_uow(svc, &u, lease, detail)
	acted := result != .Failed
	if result == .Expired do acted, _ = after_chain_change(svc, &u, lease.chain_id, lease.owner_user_id, .Instance_Terminal)
	_, _ = end_uow(svc, &u, acted)
}

// Explicit recovery of the exact blocked holder, including the pull-only
// coordinator. Await readiness outside the transaction before clearing the card.
start_blocked_task_instance :: proc(svc: ^Service, auth: contracts.Auth_Context, task: domain.Task, coord: domain.Agent_Instance) -> (bool, domain.Domain_Error) {
	started := false
	start_err: domain.Domain_Error
	if svc.agent_service == nil {
		start_err = domain.domain_error(.Internal_Error, "agent launch service is unavailable")
	} else {
		row: domain.Agent_Instance
		row, started, start_err = agent.start_instance_confirmed(svc.agent_service, auth, coord.agent_instance_id)
		domain.agent_instance_destroy(&row)
	}
	u, ok, err := begin_uow(svc)
	if !ok do return false, err
	current, found, read_err := iface.taskchain_get_task(svc.repo, task.task_id)
	if !found { _, _ = end_uow(svc, &u, false); return false, read_err }
	// The confirmed readiness hook can answer this block before the
	// command reply arrives. Do not reapply the card in that case.
	if started && blocked_on_without_hold(current.blocked_on_json) == "" {
		_, _ = end_uow(svc, &u, false)
		return true, {}
	}
	// A hold or release since the card was read leaves the failure itself unchanged.
	if blocked_on_without_hold(current.blocked_on_json) != blocked_on_without_hold(task.blocked_on_json) {
		_, _ = end_uow(svc, &u, false)
		return false, domain.domain_error(.Conflict, "the agent failure changed; reload the card")
	}
	acted := false
	if !started {
		acted = block_ready_agent_in_uow(svc, &u, current, coord.agent_id, Placement{bridge_id = coord.bridge_id, provider = coord.provider, model = coord.model}, start_err.message)
	} else {
		_, _, acted, err = record_event(svc, &u, current, actor_from_auth(auth), EV_ANSWERED, "{}")
		match_scope_note_agent(task.chain_id, coord.agent_id)
		if acted do acted, err = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Fleet_Changed)
	}
	_, cerr := end_uow(svc, &u, acted)
	if !acted do return false, err
	if cerr.code != .None do return false, cerr
	if !started do return false, start_err
	return true, domain.Domain_Error{}
}

// A fleet edit retries infrastructure failures using its new launch selection.
// Instances holding another lease and deliberate user stops remain protected.
reset_idle_agent_instances :: proc(svc: ^Service, u: ^Uow, owner: domain.User_ID, chain_id: domain.Task_Chain_ID, agent_id: string, bridge_id := "", clear_user_stop := false, recovery_task_id: domain.Task_ID = "") -> (bool, domain.Domain_Error) {
	instances, ierr := iface.agent_list_instances_by_chain(svc.agents, owner, string(chain_id))
	if ierr.code != .None do return false, ierr
	// Only explicit recovery may reset this task's retained waiting holder.
	// When responsibility is retained, leave other warm instances alone too.
	retained := false
	if clear_user_stop && recovery_task_id != "" {
		claims, err := iface.taskchain_list_leases_by_task(svc.repo, recovery_task_id)
		if err.code != .None do return false, err
		for claim in claims do if claim.phase == domain.LEASE_PHASE_WAITING { retained = true; break }
	}
	for inst in instances {
		if inst.agent_id != agent_id || (bridge_id != "" && inst.bridge_id != bridge_id) do continue
		claim, held, claim_err := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id)
		if claim_err.code != .None && claim_err.code != .Not_Found do return false, claim_err
		own_waiting := clear_user_stop && recovery_task_id != "" && held && claim.task_id == recovery_task_id && claim.phase == domain.LEASE_PHASE_WAITING
		if (held && !own_waiting) || (retained && !own_waiting) do continue
		fact := match_process_fact(svc, u, inst, chain_id)
		if fact.state != .Exited && fact.reason != .never_started do continue
		if !clear_user_stop && inst.stopped_by != "" do continue
		next := inst
		next.stopped_by = ""
		next.last_error_json = ""
		if _, saved, serr := iface.agent_save_instance(svc.agents, next); !saved do return false, serr
	}
	return true, domain.Domain_Error{}
}
