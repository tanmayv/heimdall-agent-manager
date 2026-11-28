package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent "odin_test:hub/service/agent"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Leases (plan §2.5). A lease is the ONLY way to work: one instance ⇄ one lease ⇄
// one task. Rows are deleted on release (history is in events/attempts); the two
// DB uniques (holder; task WHERE kind='work') are the backstop against a double
// grant under any bug above them.

// Placement is where a grant lands (plan §4a): task pin → fleet row bridge_id →
// chain directory bridge → coordinator bridge. `directory_id` is the chain
// directory on that bridge (first by created_at), or "" when the chain has no
// directory there — it carries the ≤ 1 live work lease per directory rule.
Placement :: struct {
	runtime_error: domain.Domain_Error,
	provider_profile:string,
	bridge_id:    string,
	directory_id: string,
	provider:     string,
	model:        string,
}

Grant_Request :: struct {
	explicit_identity: bool,
	chain:       domain.Task_Chain,
	task:        domain.Task,
	instance:    domain.Agent_Instance,
	kind:        string, // work | review
	delivery:    string, // wake | inline
	placement:   Placement,
	actor:       Actor,
	trigger:     Trigger,
	// reuse_note: why the agent's existing instance was not reused for this
	// grant (REQ-SCHED-31); recorded in the grant event as `reuse_skipped`.
	reuse_note:  string,
}

// grant_in_uow performs every grant check, writes the lease + events + attempt,
// refolds the task, mirrors the pointer onto the instance, arms timers and (for
// wake delivery) queues the wake effect. Errors are 409 Conflict for every
// precondition that is a race rather than a caller bug.
grant_in_uow :: proc(svc: ^Service, u: ^Uow, req: Grant_Request) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if u == nil || !u.has_tx do return {}, false, domain.domain_error(.Internal_Error, "lease grants require a unit of work")
	// Matcher callers deliberately skip a failed grant and keep their outer
	// transaction. Isolate ALL grant writes, including consumption receipts,
	// so a skipped candidate cannot leave a lease, event or attempt behind.
	// A holder the OUTER unit of work is stopping (its own `lease handoff`,
	// re-granted at once) asked for a fresh context: the grant must launch,
	// never nudge. Read here — the nested unit has its own (empty) effects.
	stopping := effect_has_stop(u, req.instance.bridge_id, string(req.task.chain_id), req.instance.agent_instance_id)
	nested, nok, nerr := begin_uow(svc)
	if !nok do return {}, false, nerr
	lease, ok, err := grant_attempt_in_uow(svc, &nested, req, stopping)
	if !ok {
		_, _ = end_uow(svc, &nested, false)
		return {}, false, err
	}
	committed, cerr := iface.unit_of_work_commit(&nested.tx)
	nested.has_tx = false
	if !committed {
		cancel_reservations(svc, &nested.effects)
		destroy_effects(&nested.effects)
		return {}, false, cerr
	}
	// Transfer ownership directly to the parent, rather than registering a
	// callback whose lifetime could outlast a parent transaction rollback.
	move_effects(&u.effects, &nested.effects)
	return lease, true, domain.Domain_Error{}
}

@(private = "file")
grant_attempt_in_uow :: proc(svc: ^Service, u: ^Uow, req: Grant_Request, stopping: bool) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	req := req
	task := req.task
	if task.workflow_run_id != "" {
		wf, ok, err := workflow_context(svc, task.workflow_run_id, task.owner_user_id)
		if !ok do return {}, false, err
		if wf.execution.execution_no != task.workflow_execution_no || wf.execution.state != "running" {
			return {}, false, domain.domain_error(.Conflict, "workflow execution is no longer running")
		}
	}
	inst := req.instance
	scope, scope_err := iface.fleet_scope_classify(svc.bridges, inst)
	if scope_err.code != .None do return {}, false, scope_err
	if scope != .Excluded {
		if e := iface.fleet_scope_set(svc.bridges, inst, "chain"); e.code != .None do return {}, false, e
	}
	// Inline takes come from the holder. Wake grants need the already observed
	// pty-host state; a miss queued a probe rather than claiming another child.
	fact: agent.Agent_Liveness
	if req.delivery == domain.LEASE_DELIVERY_WAKE {
		fact = match_process_fact(svc, u, inst, task.chain_id, for_launch = true)
		if fact.state == .Unknown && fact.reason != .never_started {
			return {}, false, domain.domain_error(.Bridge_Busy, "waiting for process verification")
		}
		if fact.state == .Alive && (stopping || inst.stop_reason != "") {
			return {}, false, domain.domain_error(.Bridge_Busy, "waiting for current process stop confirmation")
		}
	}
	// Retaining a live child also means retaining its actual runtime config.
	preserve_runtime := req.delivery == domain.LEASE_DELIVERY_INLINE || scope == .Excluded || fact.state == .Alive
	if preserve_runtime {
		req.placement.provider, req.placement.provider_profile, req.placement.model = inst.provider, inst.provider_profile, inst.model
	}
	if svc.agent_service != nil && !preserve_runtime {
		runtime, e := agent.chain_fleet_runtime(svc.agent_service, req.chain.owner_user_id, string(req.chain.chain_id), req.placement.bridge_id, inst.agent_id, {req.placement.provider, req.placement.provider_profile, req.placement.model})
		if e.code != .None do return {}, false, e
		defer domain.fleet_runtime_destroy(runtime)
		req.placement.provider, req.placement.provider_profile, req.placement.model = strings.clone(runtime.provider, context.temp_allocator), strings.clone(runtime.provider_profile, context.temp_allocator), strings.clone(runtime.model, context.temp_allocator)
	}
	// A candidate selected before a competing start must not overwrite it.
	latest, exists, latest_err := iface.agent_get_instance(svc.agents, inst.agent_instance_id)
	if !exists do return {}, false, latest_err
	raced := latest.run_count != inst.run_count || latest.launch_epoch != inst.launch_epoch || latest.configuration_revision != inst.configuration_revision
	domain.agent_instance_destroy(&latest)
	if raced do return {}, false, domain.domain_error(.Conflict, "instance changed before lease start", `{"code":"start_raced"}`)

	if ownership_cleanup_pending(svc,task) || instance_ownership_stop_pending(svc,inst) do return {},false,domain.domain_error(.Conflict,"previous process stop is pending; reconcile its generation before granting work",)
	if busy,err:=iface.agent_runtime_busy(svc.agents,inst.agent_instance_id);err.code!=.None {return {},false,err} else if busy {return {},false,domain.domain_error(.Conflict,"instance has a pending runtime action")}
	// Resolve the actual wake selection once, so lease history, runtime facets
	// and the bridge command agree even when reusing an older warm instance.
	provider, model := strings.clone(inst.provider), strings.clone(inst.model)
	if !preserve_runtime {
		delete(provider); delete(model)
		provider, model = lease_launch_model(svc, req.placement, inst)
	}
	defer delete(provider)
	defer delete(model)
	if task.kind == .Gate do return {}, false, domain.domain_error(.Conflict, "gates are never granted")
	// A held task gets no new lease of any kind until released (REQ-TV2-5).
	if task_is_held(task) do return {}, false, domain.domain_error(.Conflict, "task is held")
	if claims, err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); err.code != .None { return {}, false, err } else {
		for claim in claims {
			if claim.kind == domain.LEASE_KIND_WORK && req.kind == domain.LEASE_KIND_WORK && claim.holder_instance_id != inst.agent_instance_id do return {}, false, domain.domain_error(.Conflict, "task has a durable worker owner")
		}
	}
	if req.kind == domain.LEASE_KIND_WORK && task.state != .Ready do return {}, false, domain.domain_error(.Conflict, "task is not ready")
	if req.kind == domain.LEASE_KIND_WORK && task.stage_key == "" {
		ready, err := work_dependencies_ready_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
		if err.code != .None do return {}, false, err
		if !ready do return {}, false, domain.domain_error(.Conflict, "work prerequisites have not succeeded", `{"code":"prerequisite_unsatisfied"}`)
	}
	if req.kind == domain.LEASE_KIND_REVIEW && task.state != .In_Review do return {}, false, domain.domain_error(.Conflict, "task is not in review")
	if !req.explicit_identity && !instance_in_chain(svc, req.chain, inst) do return {}, false, domain.domain_error(.Conflict, "instance is not a member of the task's chain")
	// The coordinator is an ordinary assignee and reviewer, served only by
	// pulling (`lease next`, inline): the hub never wakes, restarts or stops it
	// for a grant (REQ-SCHED-13).
	if !req.explicit_identity && req.delivery != domain.LEASE_DELIVERY_INLINE && is_coordinator(svc, req.chain, inst.agent_instance_id) {
		return {}, false, domain.domain_error(.Conflict, "the chain coordinator is never woken for a lease; it pulls with `lease next`")
	}
	// Work goes only to the task's assignee agent, a review only to a listed
	// reviewer agent (REQ-SCHED-9). Explicit claims resolve the role themselves,
	// and re-activating the holder's own claim on this task keeps its owner.
	own_claim := false
	if prior, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held && prior.task_id == task.task_id && prior.kind == req.kind do own_claim = true
	if !req.explicit_identity && !own_claim {
		if req.kind == domain.LEASE_KIND_WORK && brief_assignee(task.brief_json) != inst.agent_id {
			return {}, false, domain.domain_error(.Conflict, "task is assigned to another agent", `{"code":"not_assignee"}`)
		}
		if req.kind == domain.LEASE_KIND_REVIEW {
			listed := false
			for id in brief_reviewer_agents(task.brief_json, context.temp_allocator) do if id == inst.agent_id { listed = true; break }
			if !listed do return {}, false, domain.domain_error(.Conflict, "agent is not a listed reviewer of the task", `{"code":"not_reviewer"}`)
		}
	}
	if prior, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held {
		if prior.phase != domain.LEASE_PHASE_WAITING || prior.task_id != task.task_id || prior.kind != req.kind do return {}, false, domain.domain_error(.Conflict, "instance already owns a task")
		if deleted, err := delete_claim(svc, prior); !deleted do return {}, false, err
	}
	if !bridge_online(svc, req.placement.bridge_id) do return {}, false, domain.domain_error(.Bridge_Offline, "placement bridge is offline")
	if req.kind == domain.LEASE_KIND_WORK && req.placement.directory_id != "" {
		if directory_has_work_lease(svc, req.chain, req.placement.directory_id) do return {}, false, domain.domain_error(.Conflict, "another work lease is live on this chain directory")
	}
	now := platform.clock_now(svc.clock)
	lease := domain.Task_Lease{
		lease_id = platform.generate_id(svc.ids, "lease_"),
		task_id = task.task_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		holder_instance_id = inst.agent_instance_id,
		kind = req.kind,
		bridge_id = req.placement.bridge_id,
		provider_profile=domain.profile_effective_id(provider,req.placement.provider_profile),
		provider = strings.clone(provider, context.temp_allocator),
		model = strings.clone(model, context.temp_allocator),
		granted_at = now,
		confirmed_at = now if req.delivery == domain.LEASE_DELIVERY_INLINE else "",
		phase = domain.LEASE_PHASE_ACTIVE,
		last_beat_at = now,
		delivery = req.delivery if req.delivery != "" else domain.LEASE_DELIVERY_WAKE,
	}
	// attempt_no is what the fold will say AFTER the grant event; compute it by
	// folding once (cheap) so the lease and attempt rows carry the right number.
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None do return {}, false, eerr
	pre := fold_task(evs, fold_input_for_task(task, true))
	if req.kind == domain.LEASE_KIND_WORK && !budget_allows_grant(pre, brief_max_attempts(task.brief_json)) {
		return {}, false, domain.domain_error(.Conflict, "attempt budget exhausted; the task waits for a human")
	}
	attempt_no := pre.attempt_no
	if req.kind == domain.LEASE_KIND_WORK && pre.last_release != .Handoff do attempt_no += 1
	lease.attempt_no = attempt_no

 if req.delivery!=domain.LEASE_DELIVERY_INLINE && (domain.profile_effective_id(inst.provider,inst.provider_profile)!=lease.provider_profile || inst.provider!=provider || inst.model!=model) {
  updated:=inst
  updated.provider=provider;updated.provider_profile=lease.provider_profile;updated.model=model
  stored,changed,e:=iface.agent_save_instance(svc.agents,updated)
  if !changed do return {},false,e
  inst=stored
 }
	// Opening a generation joins the grant transaction; the ticket owns the
	// reservation until commit dispatch or rollback. Never take the agent mutex.
	start_ticket: ^agent.Start_Ticket
	if lease.delivery == domain.LEASE_DELIVERY_WAKE {
		if svc.agent_service == nil do return {}, false, domain.domain_error(.Internal_Error, "agent launch service is unavailable")
		current, found, read_err := iface.agent_get_instance(svc.agents, inst.agent_instance_id)
		if !found do return {}, false, read_err
		// Match observed this generation before entering the nested grant UoW.
		// A discarded or unavailable observation cannot open a new generation.
		policy := agent.Start_If_Live.Keep
		if current.run_count != inst.run_count || current.launch_epoch != inst.launch_epoch {
			domain.agent_instance_destroy(&current)
			return {}, false, domain.domain_error(.Conflict, "instance changed before process verification")
		}
		domain.agent_instance_destroy(&current)
		ticket, start_err := agent.start_begin(svc.agent_service, contracts.Auth_Context{user_id=string(task.owner_user_id), kind=.Internal_User}, inst.agent_instance_id, {ref=lease.lease_id, if_live=policy, reason=.Lease_Wake, expected=&inst, process_fact=fact})
		if start_err.code != .None do return {}, false, start_err
		start_ticket = new(agent.Start_Ticket)
		start_ticket^ = ticket
		append(&u.effects.tickets, start_ticket)
	}
	saved, ok, err := iface.taskchain_save_lease(svc.repo, lease)
	if !ok do return {}, false, err
	// New responsibility supersedes the lease system's own stop intent (the
	// wake above relaunched the process); a user stop is never cleared here.
	if lease_stop_reason(inst.stop_reason) {
		if cleared, clear_err := iface.agent_set_stop_reason(svc.agents, inst.agent_instance_id, ""); !cleared do return {}, false, clear_err
	}
	p := json_begin()
	json_str(&p, "lease_id", saved.lease_id)
	json_str(&p, "kind", saved.kind)
	json_str(&p, "instance_id", saved.holder_instance_id)
	json_int(&p, "attempt_no", i64(saved.attempt_no))
	json_str(&p, "bridge_id", saved.bridge_id)
	json_str(&p,"provider_profile",saved.provider_profile)
	json_str(&p, "provider", saved.provider)
	json_str(&p, "model", saved.model)
	json_str(&p, "delivery", saved.delivery)
	json_str(&p, "agent_id", inst.agent_id)
	if req.reuse_note != "" do json_str(&p, "reuse_skipped", req.reuse_note)
	if start_ticket != nil {
	 json_int(&p, "start_run_count", i64(start_ticket.instance.run_count))
	 json_bool(&p, "start_kept_live", start_ticket.kept_live)
	}
	refolded, view, rok, rerr := record_event(svc, u, task, req.actor, EV_LEASE_GRANTED, json_end(&p))
	if !rok do return {}, false, rerr
	if req.kind == domain.LEASE_KIND_WORK {
		counts := true
		#partial switch pre.last_release {
		case .Replaced, .Dep_Added, .Reopened, .User_Stopped, .Released_Noncounting: counts = false
		}
		if pre.last_release != .Handoff {
			_, aok, aerr := iface.taskchain_save_attempt(svc.repo, domain.Task_Attempt{
				task_id = task.task_id, attempt_no = view.attempt_no, chain_id = task.chain_id, owner_user_id = task.owner_user_id,
				started_at = now, holder_instance_id = inst.agent_instance_id, counts_toward_budget = counts,
			})
			if !aok do return {}, false, aerr
		} else if attempts, aerr := iface.taskchain_list_attempts_by_task(svc.repo, task.task_id, task.owner_user_id); aerr.code == .None {
			// handoff continuation: the attempt row stays open, new holder recorded
			for a in attempts {
				if a.attempt_no == view.attempt_no {
					cont := a
					cont.holder_instance_id = inst.agent_instance_id
					cont.ended_at = ""
					cont.outcome = ""
					_, _, _ = iface.taskchain_save_attempt(svc.repo, cont)
				}
			}
		}
		if task.stage_key == "" {
			captured, cerr := work_capture_inputs_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
			if !captured do return {}, false, cerr
		}
		rt := json_begin()
		json_str(&rt, "bridge_id", saved.bridge_id if saved.bridge_id != "" else inst.bridge_id)
		json_str(&rt,"provider_profile",saved.provider_profile)
		json_str(&rt, "provider", saved.provider)
		json_str(&rt, "model", saved.model)
		json_str(&rt, "started_at", now)
		json_str(&rt, "ended_at", "")
		_, _ = save_facet_verbatim(svc, refolded, view.attempt_no, FACET_RUNTIME, json_end(&rt), FACET_WRITER_HUB, u)
	}
	set_instance_pointer(svc, u, inst.agent_instance_id, string(task.task_id), .Work if req.kind == domain.LEASE_KIND_WORK else .Review)
	arm_lease_timers(svc, saved)
	metric_lease_granted(saved.kind)
	if saved.delivery == domain.LEASE_DELIVERY_WAKE do effect_wake_lease(svc, u, saved, refolded, start_ticket)
	// An inline grant (`lease next`) records the placement of the granted task
	// only, not of every task in the chain (spec SCHED 10.1, REQ-SCHED-38).
	if saved.delivery == domain.LEASE_DELIVERY_INLINE {
		if pok, perr := reconcile_placement_for_task_in_uow(svc, u, req.chain, refolded); !pok do return {}, false, perr
	}
	return saved, true, domain.Domain_Error{}
}

// release_in_uow is the SHARED release path for submit / block / handoff (M2 adds
// the verbs on top): delete the lease, append `event_kind`, refold, close the
// attempt row, clear the pointer, arm idle_ttl for the released instance.
// Callers then run match_chain (after_chain_change).
//
// The holder keeps its process by default: a worker is not stopped or
// re-bootstrapped per attempt or review round, only when its task becomes done
// or cancelled (clear_task_claims_in_uow) or its context rolls over on the
// bridge. stop_holder=true is for the agent's own `lease handoff` (it asked for
// a fresh context window) and for a dispatch failure on a live-but-broken child.
release_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, actor: Actor, event_kind: string, payload_json: string, outcome: string, stop_holder := false) -> (domain.Task, bool, domain.Domain_Error) {
	task, tok, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return {}, false, terr
	// Submission and blocking pause execution while preserving responsibility.
	// A coordinator's leases are active-only (REQ-SCHED-14): its submit or block
	// deletes the lease (below) so it can pull its next item at once; rework
	// returns to it as a ready task assigned to its agent.
	coordinator := holder_is_coordinator(svc, task.chain_id, lease.holder_instance_id)
	if (event_kind == EV_SUBMITTED || event_kind == EV_BLOCKED || outcome == "dispatch_failed") && !(coordinator && outcome != "dispatch_failed") {
		waiting := lease; waiting.phase = domain.LEASE_PHASE_WAITING
		if _, saved, err := iface.taskchain_save_lease(svc.repo, waiting); !saved do return {}, false, err
		match_scope_note_claim_freed(lease)
		refolded, _, ok, err := record_event(svc, u, task, actor, event_kind, payload_json)
		if ok do close_attempt(svc, u, lease, outcome)
		return refolded, ok, err
	}
	if deleted, derr := delete_claim(svc, lease); !deleted {
		if derr.code != .None do return {}, false, derr
		return {}, false, domain.domain_error(.Conflict, "lease_lost")
	}
	metric_lease_released(lease.kind)
	refolded, _, rok, rerr := record_event(svc, u, task, actor, event_kind, payload_json)
	if !rok do return {}, false, rerr
	close_attempt(svc, u, lease, outcome)
	now := platform.clock_now(svc.clock)
	mark_instance_idle(svc, u, lease.holder_instance_id, now)
	if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
		// The lease system never stops (or idles out) a chain coordinator: it
		// keeps its process and pulls its next item (REQ-SCHED-17).
		if coordinator do return refolded, true, domain.Domain_Error{}
		if stop_holder {
			if queued, qerr := stop_instance_in_uow(svc, u, inst, string(task.chain_id), STOP_REASON_HANDOFF); !queued do return {}, false, qerr
		}
		arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
	}
	return refolded, true, domain.Domain_Error{}
}

// Explicit invalidation stops the holder, except review rework. Legacy time
// reasons are inert and never authorize stopping a durable claim holder.
expiry_stops_holder :: proc(reason: string) -> bool {
	return reason != EXPIRE_TTL && reason != EXPIRE_HARD_CAP && reason != EXPIRE_IDLE && reason != EXPIRE_CHANGES_REQUESTED
}

// ---- instance lifetime: event-driven stops (spec SCHED 8, REQ-SCHED-19..28) ----
// A worker or reviewer is stopped by the event that ends its responsibility:
// its task becomes done or cancelled (clear_task_claims_in_uow), it approves
// (review_post), or its grace window ends with no lease (fire_idle_ttl, the
// bridge sweep). No stop decision scans the chain: each is a point lookup on
// the instance (instance_stop_managed).

// Stop intents the lease system records (agent_instances.stop_reason). A new
// grant to the instance supersedes them; a user stop is never one of them.
STOP_REASON_TASK_COMPLETED :: agent.STOP_TASK_COMPLETED
STOP_REASON_REVIEW_POSTED :: agent.STOP_REVIEW_POSTED
STOP_REASON_IDLE_TTL :: agent.STOP_IDLE_TTL
STOP_REASON_HANDOFF :: agent.STOP_LEASE_HANDOFF
STOP_REASON_INVALIDATED :: agent.STOP_LEASE_INVALIDATED

lease_stop_reason :: proc(stored: string) -> bool {
	reason := agent.Stop_Reason(stored)
	return reason == STOP_REASON_TASK_COMPLETED || reason == STOP_REASON_REVIEW_POSTED || reason == STOP_REASON_IDLE_TTL || reason == STOP_REASON_CAPACITY_YIELD || reason == STOP_REASON_HANDOFF || reason == STOP_REASON_INVALIDATED
}

// stop_instance_in_uow records the stop intent, then queues the stop effect:
// the intent commits with the unit of work before the bridge sees the stop,
// and a late runtime report cannot authorize a delayed restart (REQ-SCHED-28,
// the LIFE-6 fence). An instance that is not running needs no stop, unless
// `reported_live`: its bridge has just reported it active, which outranks the
// stored status (still `unreachable` from the disconnect during on_bridge_hello).
stop_instance_in_uow :: proc(svc: ^Service, u: ^Uow, inst: domain.Agent_Instance, chain_id: string, reason: agent.Stop_Reason, reported_live := false) -> (bool, domain.Domain_Error) {
	if !reported_live {
		fact := match_process_fact(svc, nil, inst, domain.Task_Chain_ID(chain_id))
		if fact.state == .Exited || fact.reason == .never_started do return true, {}
	}
	if recorded, err := iface.agent_set_stop_reason(svc.agents, inst.agent_instance_id, string(reason)); !recorded {
		if err.code == .None do return false, domain.domain_error(.Internal_Error, "failed to record stop intent")
		return false, err
	}
	effect_stop(u, inst, chain_id, reason)
	return true, {}
}

// sweep_idle_instances_in_uow is the bridge-reconnect orphan sweep. It looks
// ONLY at instances the lease system itself would have launched — on THIS
// bridge, members of an Active ticket/workflow chain, whose agent has a fleet
// row in that chain — and that hold no lease. Human-chat members,
// coordinators, private conversations and other bridges' instances are never
// touched (review S8). Each is decided with point reads (REQ-SCHED-26): inside
// its grace window it is kept and its timer re-armed; past it, it is stopped
// (spec SCHED 8.1 row 19). An instance with no idle_since never had a window
// the hub knows of (REQ-SCHED-27 gives every lease-free instance one), so it
// is an orphan and is stopped. Every id here was reported active by the
// bridge, so the stop is sent whatever the stored runtime status says: after a
// disconnect it still reads `unreachable` while the hello is handled, and an
// Idle_TTL that fired while the bridge was offline was a no-op, so this is
// where that stop is delivered (spec SCHED 12, bridge offline). False when a
// stop intent could not be recorded.
sweep_idle_instances_in_uow :: proc(svc: ^Service, u: ^Uow, bridge_id: string, active_instance_ids: []string) -> bool {
	now := platform.clock_now(svc.clock)
	ok := true
	for id in active_instance_ids {
		if strings.trim_space(id) == "" do continue
		inst, iok, _ := iface.agent_get_instance(svc.agents, id)
		if !iok || inst.chain_id == "" || inst.bridge_id != bridge_id do continue
		chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id))
		if !cok || chain.status != .Active || chain.publish_state != .Published do continue
		if chain.kind != domain.CHAIN_KIND_MIXED_WORK do continue
		ttl, managed := instance_stop_managed(svc, chain, inst)
		if !managed do continue
		if inst.idle_since != "" && to_ms(inst.idle_since) + i64(ttl) * 1000 > to_ms(now) {
			arm_idle_ttl(svc, id, ttl, inst.idle_since)
			continue
		}
		if stopped, _ := stop_instance_in_uow(svc, u, inst, inst.chain_id, STOP_REASON_IDLE_TTL, reported_live = true); !stopped do ok = false
	}
	return ok
}

// instance_stop_managed (REQ-SCHED-26) is the point-lookup part of every idle
// stop decision: the instance holds no lease (active or waiting), is not the
// chain's coordinator, and its agent has a fleet row in the chain. `ttl` is
// that row's grace window. Any failed read answers false: an instance is never
// stopped on doubt (REQ-SCHED-28).
instance_stop_managed :: proc(svc: ^Service, chain: domain.Task_Chain, inst: domain.Agent_Instance) -> (ttl: int, managed: bool) {
	if inst.agent_id == "" do return 0, false
	if _, held, err := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held || (err.code != .None && err.code != .Not_Found) do return 0, false
	if is_coordinator(svc, chain, inst.agent_instance_id) do return 0, false
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return 0, false
	for f in fleets {
		if f.agent_id != inst.agent_id do continue
		return f.idle_ttl_seconds if f.idle_ttl_seconds > 0 else IDLE_TTL_DEFAULT_SECONDS, true
	}
	return 0, false
}

// ensure_idle_timer_in_uow (REQ-SCHED-27): a live, lease-free, managed
// instance always has idle_since and an armed Idle_TTL, including one that
// came up with nothing to do.
ensure_idle_timer_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, instance_id: string) {
	inst, ok, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !ok do return
	fact := match_process_fact(svc, nil, inst, chain.chain_id)
	if fact.state == .Exited || fact.reason == .never_started do return
	ttl, managed := instance_stop_managed(svc, chain, inst)
	if !managed do return
	since := inst.idle_since
	if since == "" {
		since = platform.clock_now(svc.clock)
		mark_instance_idle(svc, u, instance_id, since)
	}
	arm_idle_ttl(svc, instance_id, ttl, since)
}

// expire_lease_in_uow explicitly invalidates a claim for lifecycle recovery.
// Legacy time-driven reasons are inert; review checkpoint release keeps the process.
// Result: Gone = the lease row no longer exists (someone released it first —
// the timer-vs-verb race, a no-op for the caller), Failed = a write failed and
// the caller must ROLL BACK (review S2: never commit "lease gone, no event").
Expire_Result :: enum { Expired, Gone, Failed }

expire_lease_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, reason: string, actor: Actor) -> Expire_Result {
	if reason == EXPIRE_TTL || reason == EXPIRE_HARD_CAP || reason == EXPIRE_IDLE do return .Gone
	if reason == EXPIRE_INSTANCE_LOST do return agent_not_running_in_uow(svc, u, lease, "lease holder is no longer running")
	task, tok, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return .Gone if terr.code == .Not_Found || terr.code == .None else .Failed
	// Event FIRST, then the row: an interrupted sequence leaves an event whose
	// fold says "no lease" and a row the next reconciliation reclaims — never
	// the reverse (a row-less in_progress task).
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "kind", lease.kind)
	json_int(&p, "attempt_no", i64(lease.attempt_no))
	json_str(&p, "reason", reason)
	json_str(&p, "instance_id", lease.holder_instance_id)
	// A coordinator's lapse is not a failed attempt: it is never stopped and
	// simply pulls again (spec SCHED section 15, decision 10). Recorded in the
	// event so the pure fold can tell (it never sees the holder).
	coordinator := holder_is_coordinator(svc, task.chain_id, lease.holder_instance_id)
	if coordinator && lease.kind == domain.LEASE_KIND_WORK do json_bool(&p, "counting", false)
	if _, still, _ := iface.taskchain_get_lease(svc.repo, lease.lease_id); !still do return .Gone
	if _, _, rok, _ := record_event(svc, u, task, actor, EV_LEASE_EXPIRED, json_end(&p)); !rok do return .Failed
	if deleted, derr := delete_claim(svc, lease); !deleted {
		if derr.code != .None do return .Failed
		return .Failed // vanished between the check and the delete: roll back, the other writer owns it
	}
	metric_lease_released(lease.kind)
	metric_lease_expired(reason)
	if lease.kind == domain.LEASE_KIND_WORK do close_attempt(svc, u, lease, fmt.tprintf("expired:%s", reason))
	now := platform.clock_now(svc.clock)
	mark_instance_idle(svc, u, lease.holder_instance_id, now)
	if coordinator do return .Expired // never stopped, may re-pull at once (no recent-expiry window)
	stops := expiry_stops_holder(reason)
	// A holder that keeps its process may pull again at once; only a holder
	// being stopped is refused an inline grant from its old process.
	if stops do note_recent_expiry(svc, lease.holder_instance_id, to_ms(now))
	if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
		if stops {
			if queued, _ := stop_instance_in_uow(svc, u, inst, string(task.chain_id), STOP_REASON_INVALIDATED); !queued do return .Failed
		}
		arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
	}
	// NOTE: no match_chain here (review B3). Every caller runs
	// after_chain_change exactly once at the end of its own UoW, after all of
	// its writes, so the matcher never acts on an intermediate state.
	return .Expired
}

// heartbeat_in_uow records compatibility progress metadata without changing
// ownership. An event is appended only with a note (plan C9).
heartbeat_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, actor: Actor, note: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	now := platform.clock_now(svc.clock)
	next := lease
	next.last_beat_at = now
	saved, ok, err := iface.taskchain_save_lease(svc.repo, next)
	if !ok do return lease, false, err
	if strings.trim_space(note) != "" {
		if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
			p := json_begin()
			json_str(&p, "lease_id", lease.lease_id)
			json_str(&p, "note", note)
			_, _, _ = append_event(svc.repo, svc.clock, task, actor, EV_HEARTBEAT, json_end(&p))
			effect_publish_task(u, task, "heartbeat")
		}
	}
	return saved, true, domain.Domain_Error{}
}

// confirm_in_uow marks a wake-delivered lease confirmed (the holder's own
// start-success arrived). Idempotent.
confirm_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease) -> bool {
	if lease.confirmed_at != "" do return true
	now := platform.clock_now(svc.clock)
	next := lease
	next.confirmed_at = now
	next.last_beat_at = now
	if _, ok, _ := iface.taskchain_save_lease(svc.repo, next); !ok do return false
	arm_lease_stall(svc, next)
	if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
		p := json_begin()
		json_str(&p, "lease_id", lease.lease_id)
		_, _, _ = append_event(svc.repo, svc.clock, task, Actor{kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_LEASE_CONFIRMED, json_end(&p))
		effect_publish_task(u, task, "lease_confirmed")
	}
	return true
}

// on_dep_added_in_uow: a dependency added to a LEASED task expires its work
// lease first (reason dep_added, non-counting), so the holder is not left working
// on a task whose prerequisites just changed.
on_dep_added_in_uow :: proc(svc: ^Service, u: ^Uow, task: domain.Task, actor: Actor) -> (bool, domain.Domain_Error) {
	leases, err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if err.code != .None do return false, err
	for l in leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		if expire_lease_in_uow(svc, u, l, EXPIRE_DEP_ADDED, actor) == .Failed do return false, domain.domain_error(.Internal_Error, "failed to expire lease on dep_added")
	}
	return true, domain.Domain_Error{}
}

// ---- chokepoints ---------------------------------------------------------------------

// Status handlers can run on the Bridge reader that must receive the probe
// reply. Queue a hint, not an exit, and coalesce repeated hints per holder.
queue_instance_terminal_probe :: proc(svc: ^Service, instance_id: string) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id); !held {
		// A transfer fence may outlive its lease. Retry the original fence
		// without touching any lease that may have been acquired meanwhile.
		retry_instance_ownership_stops(svc, instance_id)
		return
	}
	held := state_lock(svc)
	defer state_unlock(svc, held)
	heap := runtime.heap_allocator()
	if svc.pending_terminal_probes == nil do svc.pending_terminal_probes = make(map[string]struct{}, heap)
	if _, pending := svc.pending_terminal_probes[instance_id]; !pending {
		svc.pending_terminal_probes[strings.clone(instance_id, heap)] = {}
	}
}

drain_instance_terminal_probes :: proc(svc: ^Service) {
	held := state_lock(svc)
	pending := svc.pending_terminal_probes
	svc.pending_terminal_probes = nil
	state_unlock(svc, held)
	defer delete(pending)
	for id in pending {
		defer delete(id, runtime.heap_allocator())
		lease, leased, _ := iface.taskchain_get_lease_by_holder(svc.repo, id)
		if !leased || lease.phase == domain.LEASE_PHASE_WAITING do continue
		inst, found, err := iface.agent_get_instance(svc.agents, id)
		if !found || err.code != .None do continue
		// An exit hint invalidates a recently cached alive observation. A
		// timeout, offline bridge or missing record does not authorize revocation.
		fact := agent.agent_liveness(svc.agent_service, inst, force_probe = true, prefer_reported_exit = true)
		if fact.state == .Alive {
			// A reconnect point probe may also prove a legacy terminal
			// projection wrong. Keep the same lease and repair display state.
			if u, opened, _ := begin_uow(svc); opened {
				changed := agent.apply_observed_alive_projection(svc.agent_service, inst, fact)
				if changed do effect_instance_changed(&u, id)
				_, _ = end_uow(svc, &u, changed)
			}
			continue
		}
		if fact.state != .Exited do continue
		// A complete, generation-bound roster rules out a formerly confirmed
		// holder. It cannot cancel a wake that has yet to spawn.
		lost := (fact.reason == .missing_from_pty_roster || fact.reason == .orphan_reaped) && lease.confirmed_at != ""
		exited := fact.reason == .pty_child_exited && fact.pid > 0
		if !lost && !exited do continue
		on_instance_terminal(svc, id, &inst, lease.lease_id, absence = fact.reason if lost else .not_observed)
	}
}

@(private = "file")
retry_instance_ownership_stops :: proc(svc: ^Service, instance_id: string) {
	inst, found, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !found || !instance_ownership_stop_pending(svc, inst) do return
	u, started, _ := begin_uow(svc)
	if !started do return
	reconcile_ownership_stops_in_uow(svc, &u, inst)
	_, _ = end_uow(svc, &u, true)
}

// Runtime callers provide an observed generation and lease. The legacy direct
// entry is used for administrative removal, where there may be no instance row.
on_instance_terminal :: proc(svc: ^Service, instance_id: string, observed: ^domain.Agent_Instance = nil, observed_lease_id := "", absence := agent.Agent_Liveness_Reason.not_observed) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	retry_instance_ownership_stops(svc, instance_id)
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id); !held do return
	u, ok, _ := begin_uow(svc)
	if !ok do return
	if inst, found, _ := iface.agent_get_instance(svc.agents, instance_id); found {
		if observed != nil {
			if inst.bridge_id != observed.bridge_id || inst.launch_epoch != observed.launch_epoch || inst.run_count != observed.run_count ||
			   inst.last_applied_seq != observed.last_applied_seq {
				_, _ = end_uow(svc, &u, false)
				return
			}
		} else {
			fact := match_process_fact(svc, nil, inst, domain.Task_Chain_ID(inst.chain_id))
			if fact.state != .Exited {
				_, _ = end_uow(svc, &u, false)
				return
			}
		}
	}
	acted := false
	chain_id := domain.Task_Chain_ID("")
	owner := domain.User_ID("")
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id); held && lease.phase != domain.LEASE_PHASE_WAITING &&
	   (observed == nil || observed_lease_id == lease.lease_id) {
		if absence != .not_observed && observed != nil && lease.confirmed_at != "" {
			current, present, _ := iface.agent_get_instance(svc.agents, instance_id)
			if !present || !agent.apply_observed_absent_projection(svc.agent_service, current, absence) {
				_, _ = end_uow(svc, &u, false)
				return
			}
			effect_instance_changed(&u, instance_id)
		}
		detail := "lease holder is no longer running"
		if absence == .missing_from_pty_roster do detail = "lease holder is absent from the PTY roster and the verified process is gone"
		if absence == .orphan_reaped do detail = "lease holder's orphaned process group was reaped"
		acted = agent_not_running_in_uow(svc, &u, lease, detail, confirmed_exit = observed != nil) == .Expired
		chain_id, owner = lease.chain_id, lease.owner_user_id
		match_scope_note_instance(chain_id, instance_id)
	}
	if acted do acted, _ = after_chain_change(svc, &u, chain_id, owner, .Instance_Terminal)
	_, _ = end_uow(svc, &u, acted)
}

// on_instance_user_stopped (F4): a person stopped the holder. Called by the
// agent service after it persisted stopped_by="user" and BEFORE it sends the
// stop, so the lease ends as user_stopped (non-counting) and the matcher —
// which never picks a user-stopped instance — hands the task to another
// instance. The later terminal report finds no lease (no-op).
on_instance_user_stopped :: proc(svc: ^Service, instance_id: string) {
	if svc == nil || svc.repo == nil || instance_id == "" do return
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	// Read the phase under the UoW lock: submit may have made it waiting.
	lease, held, err := iface.taskchain_get_lease_by_holder(svc.repo, instance_id)
	if !held || err.code != .None { _, _ = end_uow(svc, &u, false); return }
	if lease.phase == domain.LEASE_PHASE_WAITING {
		task, found, _ := iface.taskchain_get_task(svc.repo, lease.task_id)
		if !found { _, _ = end_uow(svc, &u, false); return }
		deleted, _ := delete_claim(svc, lease)
		if deleted {
			p := json_begin(); json_str(&p, "lease_id", lease.lease_id); json_str(&p, "kind", lease.kind); json_str(&p, "reason", EXPIRE_USER_STOPPED)
			_, saved, _ := append_event(svc.repo, svc.clock, task, Actor{kind = ACTOR_USER}, EV_CLAIM_RELEASED, json_end(&p))
			if !saved { _, _ = end_uow(svc, &u, false); return }
			mark_instance_idle(svc, &u, lease.holder_instance_id, platform.clock_now(svc.clock))
			effect_publish_task(&u, task, EV_CLAIM_RELEASED)
		}
		_, _ = end_uow(svc, &u, deleted)
		return
	}
	acted := expire_lease_in_uow(svc, &u, lease, EXPIRE_USER_STOPPED, Actor{kind = ACTOR_USER}) == .Expired
	if acted do acted, _ = after_chain_change(svc, &u, lease.chain_id, lease.owner_user_id, .Instance_Terminal)
	_, _ = end_uow(svc, &u, acted)
}

// Activity changes never renew or relinquish durable ownership.
on_instance_activity :: proc(svc: ^Service, instance_id, activity_status: string) {
	// Durable claims have no activity-driven renewal or deadline.
}

// touch_instance remains a compatibility hook; API calls do not renew claims.
touch_instance :: proc(svc: ^Service, instance_id: string) {
	// Durable claims have no activity-driven renewal or deadline.
}

// drain_pending_touches discards legacy queued touches without renewing claims.
// Swap the set under state_mutex; release its storage after unlocking.
drain_pending_touches :: proc(svc: ^Service) {
	state_held := state_lock(svc)
	pending := svc.pending_touches
	svc.pending_touches = nil
	state_unlock(svc, state_held)
	if pending == nil do return
	for instance_id in pending {
		if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, instance_id); held do touch_lease(svc, lease)
		delete(instance_id, runtime.heap_allocator())
	}
	delete(pending)
}

// Retained for compatibility with legacy heartbeat callers and tests.
IMPLICIT_HEARTBEAT_MIN_SECONDS :: 30

@(private = "file")
touch_lease :: proc(svc: ^Service, lease: domain.Task_Lease) {
	// Durable claims have no activity-driven renewal or deadline.
}

// on_start_success (the holder's own `ham-ctl agent start-success`): confirm a
// pending wake lease; an instance with no lease triggers match_chain so a fresh
// worker that came up idle gets work (pull).
on_start_success :: proc(svc: ^Service, inst: domain.Agent_Instance) {
	if svc == nil || svc.repo == nil do return
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	// The reporting instance is this UoW's actor: it just (re)started and
	// pulls on bootstrap, so nothing this recovery queues is addressed to it
	// (rules c and g: no "ready for you" right after agent_not_running).
	u.actor_instance_id = inst.agent_instance_id
	// Its agent has a live instance now: re-match that agent's items.
	match_scope_note_instance(domain.Task_Chain_ID(inst.chain_id), inst.agent_instance_id)
	// The ready hook runs after the agent save. A concurrent grant can have
	// replaced that child before this transaction acquired the lease lock.
	current, found, _ := iface.agent_get_instance(svc.agents, inst.agent_instance_id)
	if !found || current.run_count != inst.run_count {
		_, _ = end_uow(svc, &u, false)
		return
	}
	acted := true
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held && lease.phase != domain.LEASE_PHASE_WAITING {
		acted = confirm_in_uow(svc, &u, lease)
	} else if inst.chain_id != "" {
		if chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id)); cok {
			answered: bool
			answered, acted = answer_ready_agent_blocks_in_uow(svc, &u, chain, current)
			if acted && answered {
				acted, _ = after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Start_Success)
			} else if acted {
				acted, _ = match_chain_scoped_in_uow(svc, &u, chain, .Start_Success)
			}
			// Came up with nothing to do: it still gets a grace window (REQ-SCHED-27).
			if acted do ensure_idle_timer_in_uow(svc, &u, chain, inst.agent_instance_id)
		}
	}
	_, _ = end_uow(svc, &u, acted)
	// A (re)started coordinator re-arms its idle timers from its existing
	// stamp; starting is not a user event, so it never resets them.
	arm_coordinator_idle_instance(svc, current)
}

// answer_ready_agent_blocks_in_uow: a lease-free instance proved it is running,
// so its agent is no longer "not running" on that bridge. Answer exactly the
// agent_not_running blocks naming this agent and bridge (work or review); every
// other block, a hold overlay and paused roles are left to their own paths. A
// user stop was already cleared by the explicit start that launched it. Reads
// the projections inside the UoW, so duplicate start-success is a no-op.
answer_ready_agent_blocks_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, inst: domain.Agent_Instance) -> (answered: bool, ok: bool) {
	fact := match_process_fact(svc, nil, inst, chain.chain_id)
	if fact.state == .Exited || (fact.state != .Alive && inst.startup_status != "ready") ||
	   inst.stopped_by != "" || inst.agent_id == "" || inst.bridge_id == "" {
		return false, true
	}
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return false, false
	for task in tasks {
		if !is_agent_not_running_block(task.blocked_on_json) do continue
		if jsonx.extract_string(task.blocked_on_json, "agent_id", "", true, context.temp_allocator) != inst.agent_id do continue
		if jsonx.extract_string(task.blocked_on_json, "bridge_id", "", true, context.temp_allocator) != inst.bridge_id do continue
		p := json_begin()
		json_bool(&p, "auto", true)
		json_str(&p, "reason", "agent_ready")
		json_str(&p, "agent_instance_id", inst.agent_instance_id)
		if _, _, rok, _ := record_event(svc, u, task, hub_actor(), EV_ANSWERED, json_end(&p)); !rok do return answered, false
		answered = true
	}
	return answered, true
}

// Legacy compatibility constant; durable claims need no restart grace.
BOOT_LEASE_GRACE_SECONDS :: 300

// Compatibility hook: restarting the Hub does not change claim ownership.
grant_boot_lease_grace :: proc(svc: ^Service) {
	// Durable claims have no activity-driven renewal or deadline.
}

// on_bridge_hello (plan §2.4): re-send unconfirmed grants on that bridge; stop
// live non-coordinator instances that hold no claim; re-plan every chain
// with a held task.
on_bridge_hello :: proc(svc: ^Service, bridge_id: string, active_instance_ids: []string) {
	if svc == nil || svc.repo == nil || bridge_id == "" do return
	// Runs on the bridge WS upgrade thread (persistent heap): without this scope
	// every bridge (re)connect leaked a full matcher pass over every held chain.
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	// One kind-filtered read per owner, not every task's full history per instance.
	if instances,ierr:=iface.agent_list_instances_by_bridge(svc.agents,bridge_id);ierr.code==.None {reconcile_ownership_stops_for_instances_in_uow(svc,&u,instances)}
	reconnect_probes := make([dynamic]string)
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code == .None {
		for l in leases {
			if l.bridge_id != bridge_id || l.phase == domain.LEASE_PHASE_WAITING do continue
			if l.confirmed_at == "" {
				if l.delivery != domain.LEASE_DELIVERY_WAKE do continue
				if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok do effect_wake_lease(svc, &u, l, task)
				continue
			}
			// F2: a confirmed holder that is still alive may have given up on a
			// ham-ctl call while the hub/bridge link was down. Count the outage
			// as presence and tell it to carry on.
			// Hello also includes local launch records that can outlive a
			// daemon. Verify confirmed holders after leaving the transaction.
			append(&reconnect_probes, l.holder_instance_id)
			live := false
			for id in active_instance_ids do if id == l.holder_instance_id { live = true; break }
			if !live do continue
			if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok {
				effect_nudge_instance(&u, l.holder_instance_id, bridge_id, fmt.tprintf("[taskv2] Hub connection restored: continue lease %s on '%s'. Re-run the ham-ctl command that failed (ham-ctl lease next shows your lease).", l.lease_id, task.title))
			}
		}
	}
	ok_all := sweep_idle_instances_in_uow(svc, &u, bridge_id, active_instance_ids)
	chains, cerr := iface.taskchain_list_published_active_chains(svc.repo)
	requeue_pending_merges(svc, &u, bridge_id)
	if cerr.code == .None {
		for c in chains {
			// Reconnect repairs bridge absence, never provider or deliberate-stop failures.
			tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, c.chain_id, c.owner_user_id)
			if terr.code != .None { ok_all = false; continue }
			for task in tasks {
				if !is_agent_not_running_block(task.blocked_on_json) do continue
				if jsonx.extract_string(task.blocked_on_json, "bridge_id", "", true, context.temp_allocator) != bridge_id do continue
				if jsonx.extract_string(task.blocked_on_json, "cause", "", true, context.temp_allocator) != "bridge_offline" do continue
				if _, _, answered, err := record_event(svc, &u, task, hub_actor(), EV_ANSWERED, "{}"); !answered {
					fmt.eprintfln("[taskv2] bridge hello: answering task %s failed: %s", task.task_id, err.message)
					ok_all = false
				}
			}
			if chain_has_held_task(svc, c) {
				if mok, _ := match_chain_in_uow(svc, &u, c, .Bridge_Hello); !mok do ok_all = false
			}
		}
	}
	_, _ = end_uow(svc, &u, ok_all)
	for instance_id in reconnect_probes do queue_instance_terminal_probe(svc, instance_id)
}

@(private = "file")
chain_has_held_task :: proc(svc: ^Service, chain: domain.Task_Chain) -> bool {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for t in tasks do if t.state == .Ready || t.state == .In_Review do return true
	return false
}

// chain_closed reclaims every lease of the chain (stop[] holders, coordinator
// exempt) and, when the chain was CANCELLED, cancels its open tasks. Completed/
// archived chains keep their task states; their timers become no-ops.
chain_closed :: proc(svc: ^Service, chain: domain.Task_Chain, actor: Actor, cancel_tasks: bool) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	rok := true
	rerr := domain.Domain_Error{}
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain.chain_id)
	if lerr.code != .None { _, _ = end_uow(svc, &u, false); return lerr }
	if lerr.code == .None {
		for l in leases {
			task, found, read_err := iface.taskchain_get_task(svc.repo, l.task_id)
			if !found { rok = false; rerr = read_err; break }
			rok, rerr = revoke_claim_in_uow(svc, &u, task, l, actor, EXPIRE_CHAIN_CLOSED)
			if !rok do break
		}
	}
	if rok && cancel_tasks {
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None {
			rok = false
			rerr = terr
		} else {
			for t in tasks {
				if domain.task_state_is_terminal(t.state) do continue
				payload := json_begin()
				json_str(&payload, "reason", EXPIRE_CHAIN_CLOSED)
				if _, _, eok, eerr := record_event(svc, &u, t, actor, EV_CANCELLED, json_end(&payload)); !eok {
					rok = false
					rerr = eerr
					break
				}
			}
		}
	}
	if rok && cancel_tasks {
		runs, err := iface.taskchain_list_workflow_runs(svc.repo,chain.chain_id,chain.owner_user_id)
		if err.code != .None { rok=false; rerr=err } else {
			for run in runs {
				wf,ok,err := workflow_context(svc,run.run_id,chain.owner_user_id)
				if !ok { rok=false;rerr=err;break }
				if wf.execution.state == "draft" || wf.execution.state == "pending" || wf.execution.state == "running" {
					if err := workflow_set_state(svc,&u,&wf,"cancelled","chain_cancelled"); err.code != .None {rok=false;rerr=err;break}
				}
			}
		}
	}
	if rok do rok, rerr = reconcile_placement_in_uow(svc, &u, chain)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// cancel_task records `cancelled` for one task, reclaims its leases and re-plans
// the chain. Dependents are untouched.
cancel_task :: proc(svc: ^Service, task: domain.Task, actor: Actor, reason: string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	fresh, found, read_err := iface.taskchain_get_task(svc.repo, task.task_id)
	if !found { _, _ = end_uow(svc, &u, false); return read_err }
	if fresh.owner_user_id != task.owner_user_id { _, _ = end_uow(svc, &u, false); return domain.domain_error(.Not_Found, "task not found") }
	if _, allowed, auth_err := work_task_write_chain(svc, fresh.owner_user_id, actor, fresh.chain_id); !allowed { _, _ = end_uow(svc, &u, false); return auth_err }
	if fresh.workflow_run_id != "" { _, _ = end_uow(svc, &u, false); return domain.domain_error(.Conflict, "cancel the owning workflow run", `{"code":"workflow_task_managed"}`) }
	if fresh.state == .Done {
		merge := task_merge_status(svc, fresh)
		if merge.state == "none" || merge.state == "merged" { _, _ = end_uow(svc, &u, false); return domain.domain_error(.Conflict, "task already completed; reopen it explicitly") }
	}
	if fresh.state == .Cancelled { _, _ = end_uow(svc, &u, true); return {} }
	if strings.trim_space(reason) == "" { _, _ = end_uow(svc, &u, false); return domain.domain_error(.Validation_Failed, "cancellation reason is required") }
	rok := true
	rerr := domain.Domain_Error{}
	leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code != .None { _, _ = end_uow(svc, &u, false); return lerr }
	for l in leases {
		rok, rerr = revoke_claim_in_uow(svc, &u, fresh, l, actor, reason)
		if !rok do break
	}
	if rok {
		payload := json_begin()
		json_str(&payload, "reason", reason if reason != "" else "cancelled")
		if latest, exists, _ := iface.taskchain_get_task(svc.repo, task.task_id); exists do fresh = latest
		_, _, rok, rerr = record_event(svc, &u, fresh, actor, EV_CANCELLED, json_end(&payload))
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Cancelled)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// boot (hub start): rebuild the timer heap from the columns, heal in_progress rows
// that have no lease row (the migration's in_progress carry-over, or a crash
// between a lease delete and its event), re-evaluate every in-review gate once
// when a migration asked for it (boot_regate), then match_chain once per Active
// chain and re-send any unconfirmed wake whose bridge is online.
boot :: proc(svc: ^Service) {
	if svc == nil || svc.repo == nil do return
	init_task_metrics()
	grant_boot_lease_grace(svc)
	rebuild_timers(svc)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	in_progress, perr := iface.taskchain_list_tasks_by_state(svc.repo, .In_Progress)
	if perr.code == .None {
		for t in in_progress {
			leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, t.task_id)
			if lerr.code != .None do continue
			has_work := false
			for l in leases do if l.kind == domain.LEASE_KIND_WORK do has_work = true
			if has_work do continue
			p := json_begin()
			json_str(&p, "kind", domain.LEASE_KIND_WORK)
			json_int(&p, "attempt_no", i64(t.attempt_no))
			json_str(&p, "reason", EXPIRE_HUB_RESTART)
			_, _, _, _ = record_event(svc, &u, t, hub_actor(), EV_LEASE_EXPIRED, json_end(&p))
			metric_lease_expired(EXPIRE_HUB_RESTART)
		}
	}
    if converted, conversion_err := convert_legacy_review_claims_in_uow(svc, &u); !converted {
        fmt.eprintfln("[taskv2] legacy claim conversion failed: %s", conversion_err.message)
        _, _ = end_uow(svc, &u, false)
        return
    }
	// SCHED-0a (migration 259): one-shot agent-id mapping; before boot_regate so
	// the regular regate sees the mapped reviewers.
	if mapped, map_err := sched0_migrate_in_uow(svc, &u); !mapped {
		fmt.eprintfln("[taskv2] sched0 agent-id migration failed: %s", map_err.message)
		_, _ = end_uow(svc, &u, false)
		return
	}
	boot_regate(svc, &u)
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code == .None {
		for l in leases {
			if l.phase == domain.LEASE_PHASE_WAITING || l.confirmed_at != "" || l.delivery != domain.LEASE_DELIVERY_WAKE || !bridge_online(svc, l.bridge_id) do continue
			if task, tok, _ := iface.taskchain_get_task(svc.repo, l.task_id); tok do effect_wake_lease(svc, &u, l, task)
		}
	}
    chains, cerr := iface.taskchain_list_published_active_chains(svc.repo)
    all_ok := cerr.code == .None
    if all_ok {
        for chain in chains {
            if ok, err := after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Boot); !ok {
                fmt.eprintfln("[taskv2] mixed-work recovery failed for %s: %s", chain.chain_id, err.message)
                all_ok = false
                break
            }
        }
    }
	_, _ = end_uow(svc, &u, all_ok)
}

// boot_regate (M4, verify removal): a migration that changes what a gate needs
// leaves a one-shot marker; the next boot re-evaluates every in-review gate
// once under the new rules and consumes it. Fresh owed review pairs are then
// leased by the per-chain match that boot runs next. Runs inside the boot UoW,
// so a rollback keeps the marker for the next boot.
boot_regate :: proc(svc: ^Service, u: ^Uow) {
	taken, terr := iface.taskchain_take_boot_regate(svc.repo)
	if terr.code != .None || !taken do return
	tasks, lerr := iface.taskchain_list_tasks_by_state(svc.repo, .In_Review)
	if lerr.code != .None do return
	actor := Actor{kind = ACTOR_HUB, id = "boot_regate"}
	for t in tasks {
		chain, cok, _ := iface.taskchain_get_chain(svc.repo, t.chain_id)
		if !cok do continue
		if _, ok, err := evaluate_gate_in_uow(svc, u, chain, t, actor); !ok {
			fmt.eprintfln("[taskv2] boot gate re-evaluation failed for %s: %s", t.task_id, err.message)
		}
	}
}

// ---- helpers ---------------------------------------------------------------------------

@(private = "file")
close_attempt :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, outcome: string) {
	if lease.kind != domain.LEASE_KIND_WORK do return
	now := platform.clock_now(svc.clock)
	attempts, err := iface.taskchain_list_attempts_by_task(svc.repo, lease.task_id, lease.owner_user_id)
	if err.code != .None do return
	started_at := lease.granted_at
	for a in attempts {
		if a.attempt_no != lease.attempt_no do continue
		closed := a
		if closed.started_at != "" do started_at = closed.started_at
		closed.ended_at = now
		closed.outcome = outcome
		_, _, _ = iface.taskchain_save_attempt(svc.repo, closed)
	}
	if task, tok, _ := iface.taskchain_get_task(svc.repo, lease.task_id); tok {
		provider, model := lease.provider, lease.model
		if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok {
			if provider == "" do provider = inst.provider
			if model == "" && (lease.provider == "" || lease.provider == inst.provider) do model = inst.model
		}
		rt := json_begin()
		json_str(&rt, "bridge_id", lease.bridge_id)
		json_str(&rt, "provider", provider)
		json_str(&rt, "model", model)
		json_str(&rt, "started_at", started_at)
		json_str(&rt, "ended_at", now)
		_, _ = save_facet_verbatim(svc, task, lease.attempt_no, FACET_RUNTIME, json_end(&rt), FACET_WRITER_HUB, u)
	}
}

set_instance_pointer :: proc(svc: ^Service, u: ^Uow, instance_id, task_id: string, role: domain.Current_Task_Role) {
	inst, ok, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !ok do return
	if inst.current_task_id == task_id && inst.current_task_role == role && inst.idle_since == "" do return
	inst.current_task_id = task_id
	inst.current_task_role = role
	inst.idle_since = "" // holding a lease is not idle
	inst.updated_at = platform.clock_now(svc.clock)
	if _, saved, _ := iface.agent_save_instance(svc.agents, inst); saved do effect_instance_changed(u, instance_id)
}

// mark_instance_idle clears the pointer and stamps idle_since = now (the
// column the Idle_TTL timer keys on; review S4).
mark_instance_idle :: proc(svc: ^Service, u: ^Uow, instance_id, now: string) {
	inst, ok, _ := iface.agent_get_instance(svc.agents, instance_id)
	if !ok do return
	// Only the pointer change is user-visible; idle_since alone is a timer key.
	pointer_changed := inst.current_task_id != "" || inst.current_task_role != .None
	inst.current_task_id = ""
	inst.current_task_role = .None
	inst.idle_since = now
	inst.updated_at = now
	if _, saved, _ := iface.agent_save_instance(svc.agents, inst); saved && pointer_changed do effect_instance_changed(u, instance_id)
}

// ---- recently expired holders (lease.next refusal, review S10) ------------------
// An instance whose lease just expired is being stopped and re-woken; a
// `lease.next` from its old process must not hand it a fresh inline lease.
// In-memory (heap-cloned keys under state_mutex); not durable across restarts
// on purpose — after a restart every process is re-bootstrapped anyway.

note_recent_expiry :: proc(svc: ^Service, instance_id: string, at_ms: i64) {
	if instance_id == "" do return
	state_held := state_lock(svc)
	defer state_unlock(svc, state_held)
	if svc.recent_expiries == nil do svc.recent_expiries = make(map[string]i64, runtime.heap_allocator())
	if _, has := svc.recent_expiries[instance_id]; has {
		svc.recent_expiries[instance_id] = at_ms
		return
	}
	svc.recent_expiries[strings.clone(instance_id, runtime.heap_allocator())] = at_ms
}

recently_expired :: proc(svc: ^Service, instance_id: string, now_ms: i64) -> bool {
	state_held := state_lock(svc)
	defer state_unlock(svc, state_held)
	at, has := svc.recent_expiries[instance_id]
	return has && now_ms - at < IDLE_GRACE_SECONDS * 1000
}

// holder_is_coordinator resolves the lease's OWN chain (never a caller's) and
// asks whether the holder is its coordinator.
holder_is_coordinator :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, instance_id: string) -> bool {
	chain, ok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	return ok && is_coordinator(svc, chain, instance_id)
}

// SOLOIST_AGENT_SLUG mirrors user.SOLOIST_AGENT_SLUG (the built-in Soloist
// persona). Only the one-shot SCHED-0a mapping reads it; no scheduling rule
// depends on it (REQ-SCHED-11).
SOLOIST_AGENT_SLUG :: "soloist"

// chain_coordinator_agent_id: the durable agent behind the chain's coordinator
// instance ("" when the chain has none).
chain_coordinator_agent_id :: proc(svc: ^Service, chain: domain.Task_Chain) -> string {
	coord := chain.coordinator_agent_instance_id
	if coord == "" {
		members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if err.code == .None {
			for m in members do if m.role == "coordinator" { coord = m.agent_instance_id; break }
		}
	}
	if coord == "" do return ""
	inst, ok, _ := iface.agent_get_instance(svc.agents, coord)
	return inst.agent_id if ok else ""
}

// is_coordinator (REQ-SCHED-18): one comparison with the chain's
// coordinator_agent_instance_id. The member list (role "coordinator") is read
// only when that column is empty. The coordinator is granted only inline and
// never stopped by the lease system.
is_coordinator :: proc(svc: ^Service, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	if chain.coordinator_agent_instance_id != "" do return chain.coordinator_agent_instance_id == instance_id
	members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members do if m.agent_instance_id == instance_id && m.role == "coordinator" do return true
	return false
}

instance_in_chain :: proc(svc: ^Service, chain: domain.Task_Chain, inst: domain.Agent_Instance) -> bool {
	if inst.owner_user_id != chain.owner_user_id do return false
	if inst.chain_id == string(chain.chain_id) do return true
	members, err := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members do if m.agent_instance_id == inst.agent_instance_id do return true
	return false
}

bridge_online :: proc(svc: ^Service, bridge_id: string) -> bool {
	if bridge_id == "" do return false
	bridge, ok, _ := iface.bridge_get_bridge(svc.bridges, bridge_id)
	if !ok do return false
	return bridge.status == .Online
}

// PER_LEASE_WORKTREES_ENABLED: several work leases may run in one git
// directory, each in its own checkout. A task works in
// `<dir>/.heimdall/worktrees/<task_id>` on branch `heimdall/<task_id>` (the
// pack's placement.workdir/branch; the bridge creates it on lease.next), and
// the branch is merged back into the directory's branch when the task is done
// (merge.odin). A merge conflict blocks the task on a human.
PER_LEASE_WORKTREES_ENABLED :: true

TASK_WORKTREE_DIR :: ".heimdall/worktrees"
TASK_BRANCH_PREFIX :: "heimdall/"

// task_worktree returns the per-task checkout and branch for a task placed in
// directory `dir`, or ("", "") when the directory gets no worktree (not git,
// no path, or the feature is off). Temp-allocated.
task_worktree :: proc(dir: domain.Task_Chain_Directory, task_id: domain.Task_ID) -> (workdir, branch: string) {
	if !PER_LEASE_WORKTREES_ENABLED || dir.vcs_kind != "git" do return "", ""
	root := strings.trim_right(strings.trim_space(dir.path), "/")
	if root == "" || task_id == "" do return "", ""
	return fmt.tprintf("%s/%s/%s", root, TASK_WORKTREE_DIR, task_id), fmt.tprintf("%s%s", TASK_BRANCH_PREFIX, task_id)
}

// directory_has_work_lease: one live work lease per chain directory (VCS
// directories exempt only when PER_LEASE_WORKTREES_ENABLED).
directory_has_work_lease :: proc(svc: ^Service, chain: domain.Task_Chain, directory_id: string) -> bool {
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if derr.code != .None do return false
	if PER_LEASE_WORKTREES_ENABLED {
		for d in dirs {
			if d.directory_id == directory_id {
				if d.vcs_kind == "git" do return false
			}
		}
	}
	bridge_of_dir := ""
	for d in dirs do if d.directory_id == directory_id { bridge_of_dir = d.bridge_id; break }
	if bridge_of_dir == "" do return false
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain.chain_id)
	if lerr.code != .None do return false
	for l in leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		if resolve_directory_for_bridge(dirs, l.bridge_id) == directory_id do return true
	}
	return false
}

// resolve_directory_for_bridge returns the chain directory on `bridge_id` (first
// by created_at), or "" when the chain has none there.
resolve_directory_for_bridge :: proc(dirs: []domain.Task_Chain_Directory, bridge_id: string) -> string {
	for d in dirs do if d.bridge_id == bridge_id do return d.directory_id
	return ""
}

fleet_idle_ttl :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, agent_id: string) -> int {
	fleets, err := iface.taskchain_list_fleets_by_chain(svc.repo, chain_id, owner)
	if err.code != .None do return IDLE_TTL_DEFAULT_SECONDS
	for f in fleets do if f.agent_id == agent_id && f.idle_ttl_seconds > 0 do return f.idle_ttl_seconds
	return IDLE_TTL_DEFAULT_SECONDS
}

lease_lost_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Conflict, "lease_lost: this instance holds no live lease for that task; stop — you will be re-woken with a fresh pack", `{"code":"lease_lost"}`)
}

_ :: fmt

// release_review_to_grace_in_uow (REQ-SCHED-21/23) deletes a review lease
// (a review lease is never parked as waiting) and starts the holder's grace
// window: idle_since = now and an armed Idle_TTL. A re-review inside the
// window is granted to the same live process; when the timer fires with no
// lease, fire_idle_ttl stops it. The coordinator is never timed out.
release_review_to_grace_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease) -> bool {
	if deleted, _ := delete_claim(svc, lease); !deleted do return false
	metric_lease_released(lease.kind)
	now := platform.clock_now(svc.clock)
	mark_instance_idle(svc, u, lease.holder_instance_id, now)
	if holder_is_coordinator(svc, lease.chain_id, lease.holder_instance_id) do return true
	if inst, found, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); found {
		arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, lease.chain_id, lease.owner_user_id, inst.agent_id), now)
	}
	return true
}

// clear_task_claims_in_uow (REQ-SCHED-20): the task is done (merge settled)
// or cancelled. Every claim on it is deleted and every non-coordinator holder
// is stopped in the same unit of work, with no exception for a review its
// agent owes elsewhere: a later review grant relaunches it fresh.
clear_task_claims_in_uow :: proc(svc: ^Service, u: ^Uow, task: domain.Task) -> bool {
	claims, err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if err.code != .None do return false
	now := platform.clock_now(svc.clock)
	for claim in claims {
		if deleted, _ := delete_claim(svc, claim); !deleted do return false
		mark_instance_idle(svc, u, claim.holder_instance_id, now)
		if holder_is_coordinator(svc, task.chain_id, claim.holder_instance_id) do continue
		inst, found, _ := iface.agent_get_instance(svc.agents, claim.holder_instance_id)
		if !found do continue
		if stopped, _ := stop_instance_in_uow(svc, u, inst, string(task.chain_id), STOP_REASON_TASK_COMPLETED); !stopped do return false
		// Should the stop never land, the idle timer stops it again.
		arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
	}
	return true
}
