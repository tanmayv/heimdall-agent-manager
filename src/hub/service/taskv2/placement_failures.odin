package taskv2

import "core:crypto/hash"
import "core:encoding/json"
import jsonx "odin_test:lib/jsonx"
import "core:encoding/hex"
import "core:slice"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"

// Hub-owned snapshot, independent of blocked_on and the business event fold.
// Attempt zero is valid: placement can fail before the first work grant.
FACET_PLACEMENT :: "placement"

Placement_Failure :: struct {
	phase:            string,
	agent_id:         string,
	bridge_id:        string,
	directory_id:     string,
	source:           string,
	reason:           string,
	message:          string,
	provider:         string,
	model:            string,
	provider_profile: string,
	configuration:    string,
	fingerprint:      string,
}

// Match dispatch and diagnosis share this check. Queue checks belong BEFORE it.
placement_problem :: proc(svc: ^Service, ctx: ^Match_Context, placement: Placement, resolved: bool, agent_id := "") -> (string, string) {
	if !resolved do return "placement_missing", "no bridge placement can be resolved"
	bridge, found, err := iface.bridge_get_bridge(svc.bridges, placement.bridge_id)
	if err.code != .None || !found do return "bridge_missing", "placement bridge is missing"
	if bridge.owner_user_id != ctx.chain.owner_user_id do return "bridge_ineligible", "placement bridge is not owned by the chain owner"
	if bridge.revoked_at != "" || bridge.status == .Revoked || bridge.enrollment_pending_until != "" do return "bridge_ineligible", "placement bridge is not enrolled and active"
	if bridge.plan_disabled_at != "" do return "bridge_ineligible", "placement bridge is disabled"
	if bridge.status != .Online do return "bridge_offline", "placement bridge is offline"
	if agent_id != "" {
		if support, supported, _ := iface.agent_get_support(svc.agents, agent_id, placement.bridge_id); supported && (!support.enabled || support.owner_user_id != ctx.chain.owner_user_id) {
			return "bridge_ineligible", "agent is disabled on the placement bridge"
		}
	}
	if len(ctx.dirs) > 0 && placement.directory_id == "" {
		if _, count := unmapped_workspace(ctx.dirs); count > 1 do return "workspace_missing", "more than one workspace is unmapped; choose a workspace to map explicitly"
		return "workspace_missing", "no chain workspace is mapped on the placement bridge"
	}
	if placement.runtime_error.code != .None do return "provider_ineligible", placement.runtime_error.message
	if svc.agent_service != nil && svc.agent_service.providers != nil {
		provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model, placement.provider_profile)
		defer delete(provider)
		defer delete(model)
		if _, valid, perr := agent.validate_provider_model_intersection(svc.agent_service, placement.bridge_id, provider, model, placement.provider_profile); !valid {
			return "provider_ineligible", perr.message
		}
	}
	return "", ""
}

placement_source :: proc(ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, worker: bool) -> string {
	if worker && strings.trim_space(task.bridge_id) != "" do return "task"
	if strings.trim_space(fleet.bridge_id) != "" do return "fleet"
	if len(ctx.dirs) > 0 do return "directory"
	if ctx.has_coordinator && ctx.coordinator.bridge_id != "" do return "coordinator"
	return "unresolved"
}

placement_failure_json :: proc(f: Placement_Failure, include_fingerprint := true) -> string {
	o := json_begin()
	json_str(&o, "phase", f.phase)
	json_str(&o, "agent_id", f.agent_id)
	json_str(&o, "bridge_id", f.bridge_id)
	json_str(&o, "directory_id", f.directory_id)
	json_str(&o, "source", f.source)
	json_str(&o, "reason", f.reason)
	json_str(&o, "message", f.message)
	json_str(&o, "provider", f.provider)
	json_str(&o, "model", f.model)
	json_str(&o, "provider_profile", f.provider_profile)
	json_str(&o, "configuration", f.configuration)
	if include_fingerprint do json_str(&o, "fingerprint", f.fingerprint)
	return json_end(&o)
}

append_placement_failure :: proc(out: ^[dynamic]Placement_Failure, ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, placement: Placement, phase, reason, message: string, source := "") {
	// Hash relevant configuration rather than task.updated_at (heartbeats and
	// unrelated business events must not invalidate a placement operation).
	c := json_begin()
	json_str(&c, "phase", phase)
	json_str(&c, "agent_id", fleet.agent_id)
	json_str(&c, "bridge_id", placement.bridge_id)
	json_str(&c, "directory_id", placement.directory_id)
	json_str(&c, "provider", placement.provider)
	json_str(&c, "model", placement.model)
	json_str(&c, "provider_profile", placement.provider_profile)
	json_str(&c, "source", source if source != "" else placement_source(ctx, task, fleet, phase == "work"))
	json_str(&c, "task_id", string(task.task_id))
	json_int(&c, "attempt_no", i64(task.attempt_no))
	json_str(&c, "brief", task.brief_json)
	json_str(&c, "task_bridge", task.bridge_id)
	json_str(&c, "fleet_bridge", fleet.bridge_id)
	json_int(&c, "fleet_capacity", i64(fleet.capacity))
	json_bool(&c, "fleet_paused", fleet.paused)
	json_str(&c, "fleet_models", fleet.bridge_models_json)
	json_str(&c, "fleet_provider", fleet.provider)
	json_str(&c, "fleet_model", fleet.model)
	json_str(&c, "fleet_profile", fleet.provider_profile)
	json_str(&c, "fleet_updated_at", fleet.updated_at)
	for d in ctx.dirs {
		if d.directory_id != placement.directory_id do continue
		json_str(&c, "directory_path", d.path)
		json_str(&c, "directory_updated_at", d.updated_at)
	}
	if reason == "workspace_missing" {
		d, count := unmapped_workspace(ctx.dirs)
		json_int(&c, "unmapped_count", i64(count))
		if count == 1 {
			json_str(&c, "unmapped_directory_id", d.directory_id)
			json_str(&c, "unmapped_path", d.path)
			json_str(&c, "unmapped_vcs", d.vcs_kind)
			json_str(&c, "unmapped_updated_at", d.updated_at)
		}
	}
	f := Placement_Failure{
		phase = phase, agent_id = fleet.agent_id,
		bridge_id = placement.bridge_id, directory_id = placement.directory_id,
		source = source if source != "" else placement_source(ctx, task, fleet, phase == "work"),
		reason = reason, message = message, provider = placement.provider, model = placement.model,
		provider_profile = placement.provider_profile, configuration = placement_hash(json_end(&c)),
	}
	f.fingerprint = placement_hash(placement_failure_json(f, false))
	append(out, f)
}

// Read-only collection: never launches, resets instances, changes requirements,
// releases leases or appends task business events.
collect_placement_failures :: proc(svc: ^Service, ctx: ^Match_Context, task: domain.Task) -> ([]Placement_Failure, domain.Domain_Error) {
	out := make([dynamic]Placement_Failure, context.temp_allocator)
	if ctx.chain.publish_state != .Published || ctx.chain.status != .Active || task.kind == .Gate || task_is_held(task) do return out[:], {}
	if task.state == .Ready {
		if task_has_live_lease(ctx, task.task_id, domain.LEASE_KIND_WORK) do return out[:], {}
		if task.stage_key == "" {
			ready, err := work_dependencies_ready_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
			if err.code != .None do return nil, err
			if !ready do return out[:], {}
		} else {
			caps := make(map[string]map[string]int, context.temp_allocator)
			if cap := workflow_task_max_parallel_cached(svc, &caps, task); cap > 0 && stage_live_work_lease_count(ctx, task.workflow_run_id, task.workflow_execution_no, task.stage_key) >= cap do return out[:], {}
		}
		assignee := brief_assignee(task.brief_json)
		if assignee == "" {
			append_placement_failure(&out, ctx, task, domain.Task_Chain_Fleet{}, {}, "work", "assignee_missing", "the task has no assignee", "unresolved")
		} else if ctx.has_coordinator && assignee == ctx.coordinator.agent_id {
			// The coordinator pulls its own work; only its bridge can be a problem.
			if !ctx.held[ctx.coordinator.agent_instance_id] {
				p := Placement{bridge_id = ctx.coordinator.bridge_id, directory_id = resolve_directory_for_bridge(ctx.dirs, ctx.coordinator.bridge_id), provider = ctx.coordinator.provider, model = ctx.coordinator.model}
				if reason, message := placement_problem(svc, ctx, p, p.bridge_id != "", ctx.coordinator.agent_id); reason != "" {
					append_placement_failure(&out, ctx, task, domain.Task_Chain_Fleet{agent_id = ctx.coordinator.agent_id}, p, "work", reason, message, "coordinator")
				}
			}
		} else if f, has_row := fleet_row_for_agent(ctx.fleets, assignee); !has_row {
			append_placement_failure(&out, ctx, task, domain.Task_Chain_Fleet{agent_id = assignee}, {}, "work", "worker_missing", "the assignee has no row in the chain fleet", "unresolved")
		} else if !f.paused {
			p, resolved := resolve_placement(ctx, task, f, true)
			queued := (!fleet_owns_task(ctx, task, f.agent_id) && placement_target_queued(svc, ctx, f, p)) || (p.directory_id != "" && directory_has_work_lease_ctx(ctx, p.directory_id))
			// An instance on another bridge can take it (REQ-SCHED-31): the
			// base placement's problems do not stop the task.
			if !queued do queued = reuse_scan_has_candidate(reuse_scan(svc, nil, ctx, task, f, placement_restriction(task, f, true), p.bridge_id, domain.LEASE_KIND_WORK, ""))
			if !queued {
				if reason, message := placement_problem(svc, ctx, p, resolved, f.agent_id); reason != "" {
					append_placement_failure(&out, ctx, task, f, p, "work", reason, message)
				}
			}
		}
	} else if task.state == .In_Review && !requirements_stale_review(svc, task) {
		reviews, err := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
		if err.code != .None do return nil, err
		for id in required_reviewers(task, task_author_agent(svc, task)) {
			if !agent_review_owed(reviews, task, id) do continue
			if review_lease_live_for(ctx, svc, task.task_id, id) do continue
			if ctx.has_coordinator && id == ctx.coordinator.agent_id do continue // pulled by the coordinator
			f, has_row := fleet_row_for_agent(ctx.fleets, id)
			if !has_row do f.agent_id = id
			if has_row && f.paused do continue
			p, resolved := resolve_placement(ctx, task, f, false)
			if has_row && placement_target_queued(svc, ctx, f, p) do continue
			if has_row && reuse_scan_has_candidate(reuse_scan(svc, nil, ctx, task, f, placement_restriction(task, f, false), p.bridge_id, domain.LEASE_KIND_REVIEW, "")) do continue
			reason, message := placement_problem(svc, ctx, p, resolved, f.agent_id)
			if !has_row { p = {}; reason, message = "reviewer_missing", "the reviewer has no row in the chain fleet" }
			if reason == "" do continue
			append_placement_failure(&out, ctx, task, f, p, "review", reason, message, "unresolved" if !has_row else "")
		}
	}
	slice.sort_by(out[:], proc(a, b: Placement_Failure) -> bool {
		if a.phase != b.phase do return a.phase < b.phase
		return a.agent_id < b.agent_id
	})
	return out[:], {}
}

placement_snapshot_json :: proc(failures: []Placement_Failure) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for f, i in failures {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, placement_failure_json(f))
	}
	strings.write_byte(&b, ']')
	o := json_begin()
	json_int(&o, "schema_version", 1)
	json_raw(&o, "failures", strings.to_string(b))
	return json_end(&o)
}

// Fresh context is required: grants in this UoW may have changed both attempt
// and state since the matcher's initial load. Failures roll back with the UoW.
reconcile_placement_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, grant_failures: []Grant_Placement_Failure = nil, matcher_pass := false) -> (bool, domain.Domain_Error) {
	ctx, ok, err := load_match_context(svc, chain)
	if !ok do return false, err
	defer destroy_match_context(&ctx)
	for task in ctx.tasks {
		if rok, rerr := reconcile_task_placement_in_uow(svc, u, &ctx, task, grant_failures, matcher_pass); !rok do return false, rerr
	}
	return true, {}
}

// reconcile_placement_for_tasks_in_uow: the placement snapshots of the tasks
// an incremental match considered (match_chain_scoped_in_uow), re-read after
// its grants. It reads the chain's fleet, directories, leases and instances
// and those tasks, never the chain's tasks.
reconcile_placement_for_tasks_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, task_ids: []domain.Task_ID, grant_failures: []Grant_Placement_Failure) -> (bool, domain.Domain_Error) {
	if len(task_ids) == 0 do return true, {}
	ctx, ok, err := load_match_context(svc, chain, with_tasks = false)
	if !ok do return false, err
	defer destroy_match_context(&ctx)
	for id in task_ids {
		task, found, _ := iface.taskchain_get_task(svc.repo, id)
		if !found do continue
		if rok, rerr := reconcile_task_placement_in_uow(svc, u, &ctx, task, grant_failures, true); !rok do return false, rerr
	}
	return true, {}
}

// reconcile_placement_for_task_in_uow: the placement snapshot of ONE task, for
// an inline grant (`lease next`, spec SCHED 10.1). It reads the chain's fleet,
// directories, leases and instances, never its tasks (REQ-SCHED-38).
reconcile_placement_for_task_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, task: domain.Task) -> (bool, domain.Domain_Error) {
	ctx, ok, err := load_match_context(svc, chain, with_tasks = false)
	if !ok do return false, err
	defer destroy_match_context(&ctx)
	return reconcile_task_placement_in_uow(svc, u, &ctx, task, nil, false)
}

@(private = "package")
reconcile_task_placement_in_uow :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, grant_failures: []Grant_Placement_Failure, matcher_pass: bool, workspace_message := "") -> (bool, domain.Domain_Error) {
	{
		failures, perr := collect_placement_failures(svc, ctx, task)
		if perr.code != .None do return false, perr
		facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
		if ferr.code != .None do return false, ferr
		old: domain.Task_Attempt_Facet
		exists := false
		for f in facets {
			if f.attempt_no == task.attempt_no && f.kind == FACET_PLACEMENT { old = f; exists = true; break }
		}
		// Keep the last preflight error until another reply or a different
		// workspace/placement invalidates it. Routine matches do not validate.
		saved_workspace_failures: []Placement_Failure
		if exists do saved_workspace_failures = placement_saved_failures(old.body_json)
		for &failure in failures {
			if failure.phase != "work" || failure.reason != "workspace_missing" do continue
			message := workspace_message
			if message == "" {
				for previous in saved_workspace_failures {
					if previous.reason == failure.reason && previous.configuration == failure.configuration {
						message = previous.message
						break
					}
				}
			}
			if message != "" && message != failure.message {
				failure.message = message
				failure.fingerprint = placement_hash(placement_failure_json(failure, false))
			}
		}
		// Grant errors are known only after attempting start_begin. Merge them
		// into this pass's normal diagnostics; a later pass recomputes afresh.
		merged := make([dynamic]Placement_Failure, context.temp_allocator)
		append(&merged, ..failures)
		for refusal in grant_failures {
		 if refusal.task_id != task.task_id do continue
		 if task.state == .Ready {
		  if task_has_live_lease(ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
		 } else if task.state == .In_Review {
		  if review_lease_live_for(ctx, svc, task.task_id, refusal.failure.agent_id) do continue
		 } else do continue
		 append(&merged, refusal.failure)
		}
		// A disconnect/recheck did not retry the grant. Keep its durable
		// diagnostic until a matching pass replaces it, avoiding attention churn.
		if !matcher_pass && exists {
		 for previous in placement_saved_grant_failures(old.body_json) {
		  if task.state == .Ready {
		   if task_has_live_lease(ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
		  } else if task.state == .In_Review {
		   if review_lease_live_for(ctx, svc, task.task_id, previous.agent_id) do continue
		  } else do continue
		  append(&merged, previous)
		 }
		}
		failures = merged[:]
		if len(failures) == 0 && !exists do return true, {}
		body := placement_snapshot_json(failures)
		if exists && old.body_json == body do return true, {}
		if saved, serr := save_facet_verbatim(svc, task, task.attempt_no, FACET_PLACEMENT, body, FACET_WRITER_HUB, u); !saved do return false, serr
		effect_attention(u, task)
	}
	return true, {}
}

// A bridge can disconnect without any running instance, so instance-terminal
// callbacks alone cannot diagnose its queued workers/reviewers.
on_bridge_placement_changed :: proc(svc: ^Service) {
	if svc == nil || svc.repo == nil do return
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	chains, err := iface.taskchain_list_published_active_chains(svc.repo)
	ok = err.code == .None
	for chain in chains {
		if rok, _ := reconcile_placement_in_uow(svc, &u, chain); !rok { ok = false; break }
	}
	_, _ = end_uow(svc, &u, ok)
}

placement_hash :: proc(raw: string) -> string {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, raw, buf[:])
	return string(hex.encode(buf[:], context.temp_allocator))
}

// Pending runtime operations and transient provider retry windows are queueing,
// including on a bridge that is temporarily away. Match pick_instance capacity,
// which counts the agent's instances on every bridge (REQ-SCHED-33).
placement_target_queued :: proc(svc: ^Service, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, p: Placement) -> bool {
	if fleet_row_full(ctx, fleet, p) do return true
	waiting := 0
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id do continue
		if ctx.held[inst.agent_instance_id] { waiting += 1; continue }
		if busy, err := iface.agent_runtime_busy(svc.agents, inst.agent_instance_id); busy || err.code != .None { waiting += 1; continue }
		if inst.stopped_by == agent.STOPPED_BY_USER do continue
		if agent.failed_instance_disposition(inst, ctx.now_ms) == .Hold {
			if werr, typed := agent.instance_last_error(inst); typed && werr.class == .retriable do waiting += 1
		}
	}
	return waiting >= max(1, fleet.capacity)
}

// Parsed strings live only through this reconciliation's scratch scope.
placement_saved_failures :: proc(body: string) -> []Placement_Failure {
	context.allocator = context.temp_allocator
	raw, found := jsonx.extract_raw_array(body, "failures", true)
	if !found do return nil
	entries: []Placement_Failure
	if json.unmarshal_string(raw, &entries) != nil do return nil
	return entries
}

placement_saved_grant_failures :: proc(body: string) -> []Placement_Failure {
	out := make([dynamic]Placement_Failure, context.temp_allocator)
	for entry in placement_saved_failures(body) do if entry.source == "grant" do append(&out, entry)
	return out[:]
}
