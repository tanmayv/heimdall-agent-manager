package agent

import "core:encoding/json"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import placement "odin_test:hub/service/placement"
import provider_service "odin_test:hub/service/provider"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

Reconfigure_Operation_Input :: struct {
	bridge_id, project_id, provider, model, idempotency_key, provider_profile: string,
	expected_revision: int,
	// permission_mode optionally overrides the instance's permission mode
	// ("yolo" | "ask"); "" keeps the instance's current override. A change that
	// touches only this field is a valid operation and restarts the instance.
	permission_mode: string,
	// runtime_transport optionally pins this one instance to "pty" | "acp",
	// winning over the bridge-wide provider setting on this and every later
	// launch. "" keeps the instance's current choice (for most instances: none,
	// i.e. bridge-provider override, then catalog default). A transport-only
	// change is a valid operation and restarts the instance.
	runtime_transport: string,
	// apply: "now" (default; "" means now) starts the stop/launch flow at once.
	// "after_turn" queues the operation in Waiting_For_Idle when the instance is
	// mid-turn (see reconfiguration_instance_idle) and fires it on the next idle
	// report; an instance that is already idle starts at once.
	// Restart now: an explicit apply "now" request with a NEW idempotency key
	// supersedes a queued operation atomically (it ends Failed/"superseded" in
	// the same transaction that begins the new one). Retrying the queued key
	// returns the queued operation unchanged; an omitted apply never supersedes.
	apply: string,
}

// reconfiguration_apply_mode validates and normalizes a requested apply mode to a
// static literal.
reconfiguration_apply_mode :: proc(requested: string) -> (string, bool, domain.Domain_Error) {
	switch strings.trim_space(requested) {
	case "", domain.RECONFIGURATION_APPLY_NOW: return domain.RECONFIGURATION_APPLY_NOW, true, {}
	case domain.RECONFIGURATION_APPLY_AFTER_TURN: return domain.RECONFIGURATION_APPLY_AFTER_TURN, true, {}
	}
	return "", false, domain.domain_error(.Validation_Failed, "apply must be 'now' or 'after_turn'")
}

// reconfiguration_runtime_stopped: no runtime runs, so no turn can be interrupted.
// At create time an after_turn request then starts at once (like Apply and start).
// While queued it CANCELS the operation instead: a Stop (or crash) must never be
// undone by a queued restart (see reconfiguration_fire_waiting_locked).
reconfiguration_runtime_stopped :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> bool {
	fact := agent_liveness(service, inst, cache_only = true)
	return fact.state == .Exited || fact.reason == .never_started
}

// reconfiguration_instance_idle reports whether a queued (after_turn) operation
// may fire now: a running agent whose turn has ended.
//   - The source bridge must be live. A disconnected source keeps the operation
//     waiting (it is never fenced mid-turn); it fires after the bridge reconnects
//     and reports idle. "Restart now" uses the immediate path, which fences.
//   - The current child must be verified alive and ready and report idle.
//     For ACP it also cannot have input held behind the current turn.
//   - Unknown evidence keeps the request queued. Callers under the operation
//     mutex or on the bridge reader only consult the cache.
reconfiguration_instance_idle :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> bool {
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return false
	if inst.activity_status != "idle" || inst.stopped_by != "" || inst.stop_reason != "" do return false
	fact := agent_liveness(service, inst, cache_only = true)
	if fact.state != .Alive || !fact.ready do return false
	return !reconfiguration_acp_turn_active(service, inst)
}

// reconfiguration_acp_turn_active mirrors content.acp_delivery_turn_held (the
// content package imports this one): an ACP input queued or dispatching behind an
// active turn of the current launch means the turn has not finished.
reconfiguration_acp_turn_active :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> bool {
	if inst.runtime_transport != "acp" || service.content == nil || service.content.list_open_input_deliveries == nil do return false
	context.allocator = context.temp_allocator
	rows, err := iface.content_list_open_input_deliveries(service.content, "", inst.agent_instance_id)
	if err.code != .None do return true // unknown: keep waiting, the sweep retries
	for row in rows {
		if row.launch_epoch != inst.launch_epoch do continue
		if (row.state == "queued" || row.state == "dispatching") && row.hold_reason == "turn_active" && row.agent_read_at == "" do return true
	}
	return false
}

// reconfiguration_destination_transport_override resolves the destination's
// explicit transport choice: the requested value when given (validated), else the
// instance's current choice. Always returns a static literal ("" | "pty" | "acp").
// Catalog support and ACP readiness are checked when the destination is frozen.
reconfiguration_destination_transport_override :: proc(inst: domain.Agent_Instance, requested: string) -> (string, bool, domain.Domain_Error) {
	transport := strings.trim_space(requested)
	if transport == "" do return domain.runtime_transport_override_normalize(inst.runtime_transport_override), true, {}
	if !contracts.runtime_transport_valid(transport) do return "", false, domain.domain_error(.Invalid_Transport, "runtime_transport must be 'pty' or 'acp'")
	return domain.runtime_transport_override_normalize(transport), true, {}
}

// reconfiguration_destination_permission_mode resolves the destination override
// for a request: the requested value when given (validated), else the current
// instance override. Always returns a static literal ("" | "yolo" | "ask").
// Only a person may change it: an agent cannot lift its own permission gate.
reconfiguration_destination_permission_mode :: proc(auth: contracts.Auth_Context, inst: domain.Agent_Instance, requested: string) -> (string, bool, domain.Domain_Error) {
	mode := strings.trim_space(requested)
	if mode == "" do return domain.agent_instance_permission_mode_normalize(inst.permission_mode), true, {}
	if auth.kind == .Instance_Token || auth.kind == .Bridge_Token || auth.kind == .Enrollment_Token do return "", false, domain.domain_error(.Forbidden, "only a user can change an instance's permission mode")
	if !domain.agent_permission_mode_valid(mode) do return "", false, domain.domain_error(.Validation_Failed, "permission_mode must be 'yolo' or 'ask'")
	return domain.agent_instance_permission_mode_normalize(mode), true, {}
}

// reconfiguration_same_destination reports whether an existing operation (same
// idempotency key) targets exactly the requested destination.
reconfiguration_same_destination :: proc(existing: domain.Instance_Reconfiguration, input: Reconfigure_Operation_Input, permission_mode: string, transport_override: string) -> bool {
	return domain.runtime_transport_override_normalize(existing.destination.runtime_transport_override) == transport_override && existing.destination.bridge_id == input.bridge_id && existing.destination.project_id == input.project_id && existing.destination.provider == input.provider && domain.profile_effective_id(existing.destination.provider,existing.destination.provider_profile)==domain.profile_effective_id(input.provider,input.provider_profile) && existing.destination.model == input.model && domain.agent_instance_permission_mode_normalize(existing.destination.permission_mode) == permission_mode
}

instance_assertion_token :: proc(inst: domain.Agent_Instance) -> string {
	if inst.launch_epoch == "" do return strings.concatenate({"hit_", inst.agent_instance_id})
	return strings.concatenate({"hit_", inst.agent_instance_id, "~", inst.launch_epoch})
}
instance_id_from_assertion :: proc(token: string) -> string {
	if !strings.has_prefix(token, "hit_") do return ""
	value := token[len("hit_"):]
	if separator := strings.index(value, "~"); separator >= 0 do return value[:separator]
	return value
}

reconfiguration_bridge_supported :: proc(bridge: domain.Bridge) -> bool {
	return placement.bridge_has_feature(bridge, "instance_reconfiguration_v1")
}

configuration_snapshot :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> domain.Instance_Configuration {
	config := domain.Instance_Configuration{runtime_transport=inst.runtime_transport,runtime_transport_override=domain.runtime_transport_override_normalize(inst.runtime_transport_override),bridge_id = inst.bridge_id, project_id = string(inst.project_id), project_path = inst.project_path, provider = inst.provider, provider_profile=inst.provider_profile, model = inst.model, permission_mode = domain.agent_instance_permission_mode_normalize(inst.permission_mode)}
	if bridge, found, _ := iface.bridge_get_bridge(service.bridges, inst.bridge_id); found {
		config.bridge_label = bridge.label
		if config.bridge_label == "" do config.bridge_label = bridge.machine_hostname
	}
	if inst.project_id != "" && service.projects != nil {
		if project, found, _ := iface.project_get(service.projects, inst.project_id); found do config.project_label = project.name
	}
	return config
}

reconfiguration_require_idle :: proc(service: ^Agent_Service, instance_id: string) -> (bool, domain.Domain_Error) {
	// Legacy fake repositories do not implement this additive surface.
	if service.agents == nil || service.agents.reconfiguration_list == nil do return true, {}
	ops, err := iface.instance_reconfiguration_list(service.agents, "", instance_id, true)
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	if err.code != .None do return false, err
	if len(ops) > 0 do return false, domain.domain_error(.Conflict, "instance configuration is changing or requires recovery; messages and runtime actions are temporarily disabled")
	return true, {}
}

begin_instance_reconfiguration :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, input: Reconfigure_Operation_Input, guard_ctx:rawptr=nil, guard:proc(ctx:rawptr)->domain.Domain_Error=nil, guard_factory: ^iface.Unit_Of_Work_Factory = nil) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, false, err
	defer domain.agent_instance_destroy(&inst)
	if strings.trim_space(input.idempotency_key) == "" || len(input.idempotency_key) > 128 || input.bridge_id == "" || input.provider == "" || input.model == "" do return {}, false, domain.domain_error(.Validation_Failed, "idempotency key, bridge, provider and model are required")
	permission_mode, mode_ok, mode_err := reconfiguration_destination_permission_mode(auth, inst, input.permission_mode)
	if !mode_ok do return {}, false, mode_err
	transport_override, transport_ok, transport_err := reconfiguration_destination_transport_override(inst, input.runtime_transport)
	if !transport_ok do return {}, false, transport_err
	apply, apply_ok, apply_err := reconfiguration_apply_mode(input.apply)
	if !apply_ok do return {}, false, apply_err
	if existing, exists, _ := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, input.idempotency_key); exists {
		if !reconfiguration_same_destination(existing, input, permission_mode, transport_override) {
			domain.instance_reconfiguration_destroy(&existing)
			return {}, false, domain.domain_error(.Conflict, "idempotency key already belongs to another configuration")
		}
		return existing, true, {}
	}
	if input.expected_revision != inst.configuration_revision do return {}, false, domain.domain_error(.Conflict, "configuration changed; refresh before applying")
	if idle, idle_err := reconfiguration_require_idle(service, instance_id); !idle do return {}, false, idle_err
	agent, agent_ok, agent_err := get_agent(service, auth, inst.agent_id)
	if !agent_ok do return {}, false, agent_err
	if agent.state != .Active do return {}, false, domain.domain_error(.Conflict, "agent is archived")
	source_bridge, source_ok, source_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !source_ok do return {}, false, source_err
	if source_bridge.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "source bridge not found")
	destination_bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, input.bridge_id)
	if !bridge_ok do return {}, false, bridge_err
	if destination_bridge.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "destination bridge not found")
	ps:=agent_placement(service)
 if eligible,reason:=placement.bridge_eligible(&ps,destination_bridge,{owner=string(inst.owner_user_id),features={"instance_reconfiguration_v1"}}); !eligible do return {},false,agent_placement_error(&ps,destination_bridge,reason,"destination bridge must be online","update source and destination bridges before applying configuration changes")
 if !reconfiguration_bridge_supported(source_bridge) do return {},false,domain.domain_error(.Conflict,"update source and destination bridges before applying configuration changes")

	next := inst
	next.bridge_id = input.bridge_id; next.project_id = domain.Project_ID(input.project_id)
	next.provider_profile=domain.profile_effective_id(input.provider,input.provider_profile); next.provider = input.provider; next.model = input.model; next.project_path = ""
	next.permission_mode = permission_mode
	next.runtime_transport_override = transport_override
	_, provider_ok, provider_err := validate_pinned_provider_model(service, auth, next, input.provider, input.model)
	if !provider_ok do return {}, false, provider_err
	if err:=freeze_runtime_transport(service,&next);err.code!=.None do return {},false,err
	if input.project_id != "" {
		project, project_ok, project_err := iface.project_get(service.projects, next.project_id)
		if !project_ok do return {}, false, project_err
		if project.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "destination project not found")
		if project.state != .Active do return {}, false, domain.domain_error(.Conflict, "destination project is archived")
		path, path_ok, path_err := resolve_project_path_for_launch(service, inst.owner_user_id, next.project_id, next.bridge_id)
		if !path_ok do return {}, false, path_err
		explicit_path, explicit_path_ok, explicit_path_err := iface.project_get_bridge_path(service.projects, next.project_id, next.bridge_id)
		if !explicit_path_ok && explicit_path_err.code != .Not_Found do return {}, false, explicit_path_err
		// REQ-PROJ-FALLBACK-1: only an explicit, non-empty per-Bridge override
		// requires a remote preflight. With no override, the project default is
		// optional launch context and managed instance directories still own cwd.
		if explicit_path_ok && strings.trim_space(explicit_path.path) != "" {
			validation, validation_ok, validation_err := project_service.bridge_command_validate_project_path(service.bridge_command_sink, project_service.Validate_Project_Path_Command{type = "validate_project_path", command_id = platform.generate_id(service.ids, "cmd_preflight_"), project_id = next.project_id, bridge_id = next.bridge_id, path = path, vcs_kind = project.vcs_kind, repo_url = project.repo_url})
			if !validation_ok do return {}, false, validation_err
			if !validation.ok do return {}, false, domain.domain_error(.Validation_Failed, "destination project path is not available on selected bridge")
		}
		next.project_path = path
	}
	if inst.chain_id != "" && service.taskchains != nil {
		chain, chain_ok, chain_err := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id))
		if !chain_ok do return {}, false, chain_err
		if chain.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "task chain not found")
		// Chain membership/kind does not bind this instance to a checkout. Chain
		// directory records are context references, not owned runtime workspaces.
		// Moving the instance preserves the chain and its directory references.
		// Destination project/path validation above is the execution-location guard.
	}
	// Check and reserve destination capacity before stopping source. Reservations
	// are a runtime projection and are rechecked when committing after stop.
	generation, admitted, quota_err := reserve_runtime_launch(service, next)
	if !admitted do return {}, false, quota_err
	// Resolve process evidence before joining any operation lock or acceptance
	// transaction. A different generation/status sequence will miss this cache.
	if apply == domain.RECONFIGURATION_APPLY_AFTER_TURN &&
	   project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) {
		_ = agent_liveness(service, inst)
	}
	// Path preflight above can wait for a WS reply. Only acquire this lock after
	// preflight completes; the reader must remain free to deliver that reply.
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	defer project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
	// Fleet binds its live authority, captured claim and generation check to the
	// native reservation write. Commit before any lifecycle event or command.
	acceptance: iface.Unit_Of_Work
	accepting := false
	if guard_factory != nil {
		acceptance, accepting, err = iface.unit_of_work_begin(guard_factory)
		if !accepting do return {}, false, err
	}
	defer if accepting do iface.unit_of_work_rollback(&acceptance)
	if accepting && acceptance.nested do return {},false,domain.domain_error(.Conflict,"native Fleet acceptance requires its own transaction")
	// Delegated callers may revoke authorization while remote path preflight is
	// waiting. Recheck at the native acceptance boundary before persisting/sending.
	if guard!=nil {if err:=guard(guard_ctx);err.code!=.None do return {},false,err}
	if existing, exists, _ := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, input.idempotency_key); exists {
		if !reconfiguration_same_destination(existing, input, permission_mode, transport_override) {
			domain.instance_reconfiguration_destroy(&existing)
			return {}, false, domain.domain_error(.Conflict, "idempotency key already belongs to another configuration")
		}
		return existing, true, {}
	}
	// Preflight can wait for a bridge reply; recheck connectivity before stopping source.
	if eligible,reason:=placement.bridge_eligible(&ps,destination_bridge,{owner=string(inst.owner_user_id),features={"instance_reconfiguration_v1"}}); !eligible do return {},false,agent_placement_error(&ps,destination_bridge,reason,"destination bridge disconnected during preflight; reconnect it before Apply","update source and destination bridges before applying configuration changes")
	// One active operation per instance: a queued one is superseded only by an
	// explicit apply "now" (Restart now). Read under the operation mutex so a
	// concurrent fire cannot move it between this check and the insert.
	queued, queued_found, queued_err := reconfiguration_waiting_for_instance(service, string(inst.owner_user_id), instance_id)
	if queued_err.code != .None do return {}, false, queued_err
	defer if queued_found do domain.instance_reconfiguration_destroy(&queued)
	if queued_found && strings.trim_space(input.apply) != domain.RECONFIGURATION_APPLY_NOW do return {}, false, domain.domain_error(.Conflict, "a configuration change is already queued after this turn; cancel it or restart now")
	// Decide the phase from fresh runtime state: an idle instance starts at once.
	waiting := false
	if apply == domain.RECONFIGURATION_APPLY_AFTER_TURN {
		current, current_found, _ := iface.agent_get_instance(service.agents, instance_id)
		waiting = !current_found || !(reconfiguration_runtime_stopped(service, current) || reconfiguration_instance_idle(service, current))
		if current_found do domain.agent_instance_destroy(&current)
	}
	now := platform.clock_now(service.clock)
	op := domain.Instance_Reconfiguration{operation_id = platform.generate_id(service.ids, "reconfig_"), owner_user_id = string(inst.owner_user_id), agent_instance_id = inst.agent_instance_id, conversation_id = inst.conversation_id, actor_user_id = auth.user_id, idempotency_key = input.idempotency_key, expected_revision = input.expected_revision, revision = 1, phase = .Prepared, source = configuration_snapshot(service, inst), destination = configuration_snapshot(service, next), stop_command_id = platform.generate_id(service.ids, "cmd_reconfig_stop_"), launch_command_id = platform.generate_id(service.ids, "cmd_reconfig_launch_"), launch_epoch = platform.generate_id(service.ids, "launch_"), created_at = now, updated_at = now}
	op.source_launch_epoch = inst.launch_epoch; op.source_run_count = inst.run_count
	op.apply = apply
	if waiting { op.phase = .Waiting_For_Idle; op.waiting_since = now }
	stored: domain.Instance_Reconfiguration
	saved: bool
	save_err: domain.Domain_Error
	superseded_key := ""
	if queued_found {
		ended := queued
		ended.phase = .Failed; ended.revision += 1; ended.updated_at = now
		ended.failure_code = domain.RECONFIGURATION_SUPERSEDED; ended.failure_message = "Replaced by Restart now."
		stored, saved, save_err = iface.instance_reconfiguration_begin_superseding(service.agents, op, ended, queued.revision)
		superseded_key = queued.idempotency_key
	} else {
		stored, saved, save_err = iface.instance_reconfiguration_begin(service.agents, op)
	}
	if !saved do return {}, false, save_err
	if accepting {
		accepting = false
		committed, commit_err := iface.unit_of_work_commit(&acceptance)
		if !committed {domain.instance_reconfiguration_destroy(&stored); return {}, false, commit_err}
	}
	if superseded_key != "" {
		if ended, found, _ := iface.instance_reconfiguration_get(service.agents, stored.owner_user_id, instance_id, superseded_key); found {
			reconfiguration_notify(service, ended, reconfiguration_change_name(ended), false)
			domain.instance_reconfiguration_destroy(&ended)
		}
	}
	reconfiguration_notify(service, stored, "created", false)
	if stored.phase == .Waiting_For_Idle do return stored, true, {}
	defer domain.instance_reconfiguration_destroy(&stored)
	// Check the runtime registry at the last possible point because project-path
	// preflight may have waited while the source disconnected.
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, stored.source.bridge_id) do return reconfiguration_fence_source_and_launch(service, stored)
	return reconfiguration_start_stop(service, stored)
}

reconfiguration_advance :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration, phase: domain.Instance_Reconfiguration_Phase, stopped, committed: bool, failure_code: string = "", failure_message: string = "", notify := true) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	next := op; next.phase = phase; next.revision += 1; next.updated_at = platform.clock_now(service.clock)
	next.source_stopped = stopped; next.destination_committed = committed; next.failure_code = failure_code; next.failure_message = failure_message
	advanced, accepted, err := iface.instance_reconfiguration_advance(service.agents, next, op.revision)
	if accepted && notify do reconfiguration_notify(service, advanced, reconfiguration_change_name(advanced), committed && !op.destination_committed)
	return advanced, accepted, err
}

// reconfiguration_change_name maps a persisted operation to the stable event
// change. A queued operation that ended without firing (cancel, Restart now) is
// "cancelled"; the summary's phase and error_code carry the detail.
reconfiguration_change_name :: proc(op: domain.Instance_Reconfiguration) -> string {
	#partial switch op.phase {
	case .Ready:             return "succeeded"
	case .Failed:
		if op.failure_code == domain.RECONFIGURATION_CANCELLED || op.failure_code == domain.RECONFIGURATION_SUPERSEDED do return "cancelled"
		return "failed"
	case .Recovery_Required: return "error"
	}
	return "progress"
}

// reconfiguration_notify runs after a successful compare-and-set write, so a
// lost race (accepted=false) or a failed write never produces an event.
reconfiguration_notify :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration, change: string, config_committed: bool) {
	if service == nil do return
	// Rebind subscribed viewers after the destination commit, independently of
	// optional UI event hooks. Ready retries a baseline if attach preceded launch.
	if config_committed || change == "succeeded" do tool_live_clear(service, op.agent_instance_id)
	if service.resource_events.on_reconfiguration_changed == nil do return
	service.resource_events.on_reconfiguration_changed(service.resource_events.ctx, op, change, config_committed)
}
reconfiguration_start_stop :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	stopping, accepted, err := reconfiguration_advance(service, op, .Stopping, false, false)
	if !accepted do return {}, false, err
	return reconfiguration_send_stop(service, stopping)
}

// Takes ownership of an already committed Stopping record. Explicit Fleet
// retries bind authorization and this transition in one acceptance transaction.
reconfiguration_send_stop :: proc(service: ^Agent_Service, stopping: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	stopping := stopping
	op := stopping
	command := project_service.Runtime_Command{bridge_id = op.source.bridge_id, command_id = op.stop_command_id, body_json = stop_command_json(op.stop_command_id, op.agent_instance_id, "configuration_change")}
	if sent, _ := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent {
		defer domain.instance_reconfiguration_destroy(&stopping)
		// Close the disconnect race between the live-registry check and command
		// dispatch. A genuinely disconnected source can be fenced safely; another
		// dispatch failure on a live source still requires operator recovery.
		if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, op.source.bridge_id) do return reconfiguration_fence_source_and_launch(service, stopping)
		return reconfiguration_advance(service, stopping, .Recovery_Required, false, false, "stop_unconfirmed", "Source stop could not be confirmed. No destination launch was requested.")
	}
	return stopping, true, {}
}

// REQ-RELOC-OFFLINE-1: a disconnected source cannot acknowledge a stop, but it
// must not pin the durable instance forever. Persisting this fence before the
// destination commit changes canonical ownership. The source Bridge's next
// inventory heartbeat then receives the instance as superseded and terminates
// any stale local runtime.
reconfiguration_fence_source_and_launch :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	fenced, fenced_ok, fence_err := reconfiguration_advance(service, op, .Source_Stopped, true, false)
	if !fenced_ok do return {}, false, fence_err
	defer domain.instance_reconfiguration_destroy(&fenced)
	reconfiguration_launch_destination(service, fenced)
	return iface.instance_reconfiguration_get(service.agents, op.owner_user_id, op.agent_instance_id, op.idempotency_key)
}

reconfiguration_launch_destination :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) {
	if valid, validity_err := reconfiguration_validate_live_destination(service, op); !valid {
		failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, false, "destination_invalid", validity_err.message)
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id)
	if !found do return
	defer domain.agent_instance_destroy(&inst)
	next := inst; next.bridge_id = op.destination.bridge_id; next.project_id = domain.Project_ID(op.destination.project_id); next.project_path = op.destination.project_path
	next.provider_profile=domain.profile_effective_id(op.destination.provider,op.destination.provider_profile);next.provider = op.destination.provider; next.model = op.destination.model
	// The commit trigger applies the destination override; launch with it now.
	next.permission_mode = domain.agent_instance_permission_mode_normalize(op.destination.permission_mode)
	next.runtime_transport=op.destination.runtime_transport
	next.runtime_transport_override=domain.runtime_transport_override_normalize(op.destination.runtime_transport_override)
	generation, admitted, _ := reserve_runtime_launch(service, next)
	if !admitted {
		failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, false, "destination_capacity", "Source is stopped; destination capacity is unavailable.")
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	launching, committed, _ := reconfiguration_advance(service, op, .Launching, true, true)
	if !committed {
		project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
		return
	}
	defer domain.instance_reconfiguration_destroy(&launching)
	if sent, _ := send_reconfiguration_launch(service, launching); !sent {
		fresh,found,_:=iface.instance_reconfiguration_get(service.agents,op.owner_user_id,op.agent_instance_id,op.idempotency_key)
		if found {
			failed, _, _ := reconfiguration_advance(service, fresh, .Recovery_Required, true, true, "launch_unconfirmed", "Source is stopped; destination launch could not be confirmed.")
			domain.instance_reconfiguration_destroy(&failed);domain.instance_reconfiguration_destroy(&fresh)
		}
	}
}

// Called after transport has stored command results. Never waits or joins on the
// WS reader; it only persists progress and sends the next command.
apply_reconfiguration_command_result :: proc(service: ^Agent_Service, bridge_id, command_id, result: string) {
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	ops, err := iface.instance_reconfiguration_list(service.agents, "", "", true)
	if err.code != .None do return
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	for op in ops {
		if op.phase == .Recovery_Required && op.failure_code == "force_stopping" {
			target := op.destination.bridge_id if op.destination_committed else op.source.bridge_id
			if target != bridge_id || op.stop_command_id != command_id do continue
			status := jsonx.extract_string(result, "status"); defer delete(status)
			if status == "accepted" do return
			if status == "succeeded" {
				stopped, applied, _ := reconfiguration_advance(service, op, .Failed, true, op.destination_committed, "recovery_stopped", "Agent stopped. Choose a model or bridge and Apply to start again.")
				defer domain.instance_reconfiguration_destroy(&stopped)
				if applied {
					// The migration's guarded operation transition writes the
					// stopped projection. Preserve the receipt reason and audit
					// the actual transition from this force-stop operation.
					row, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id)
					defer domain.agent_instance_destroy(&row)
					if found && row.launch_epoch == strings.concatenate({"stopped_", op.operation_id}, context.temp_allocator) {
						next := row
						next.status_message = "pty_stop_confirmed"
						_, _, _ = iface.agent_save_instance_guarded(service.agents, next, row.run_count, row.launch_epoch, row.configuration_revision)
						log_runtime_terminal_transition(row, "stopping", "reconfiguration_force_stop", "pty_stop_confirmed", command_id)
					}
				}
			} else {
				failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, op.source_stopped, op.destination_committed, "force_stopping", "Force stop was not confirmed. Reconnect the current bridge and retry Force stop.")
				domain.instance_reconfiguration_destroy(&failed)
			}
			return
		}
		is_stop := op.source.bridge_id == bridge_id && op.stop_command_id == command_id
		is_launch := op.destination.bridge_id == bridge_id && op.launch_command_id == command_id
		if !is_stop && !is_launch do continue
		status := jsonx.extract_string(result, "status"); defer delete(status)
		if status == "accepted" do return
		if is_stop && (op.phase == .Stopping || (op.phase == .Recovery_Required && !op.source_stopped)) {
			if status != "succeeded" {
				if op.phase == .Recovery_Required do return
				failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, false, false, "stop_failed", "Could not confirm source termination. Destination has not started.")
				domain.instance_reconfiguration_destroy(&failed); return
			}
			stopped, changed, _ := reconfiguration_advance(service, op, .Source_Stopped, true, false)
			if changed { reconfiguration_launch_destination(service, stopped); domain.instance_reconfiguration_destroy(&stopped) }
			return
		}
		if is_launch && op.phase == .Launching && status != "succeeded" {
			failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, true, "launch_failed", "Source is stopped; destination agent failed to start.")
			domain.instance_reconfiguration_destroy(&failed)
		}
	}
}

// reconcile_active_reconfigurations is the autonomous pass (hub reaper, once at
// startup and every sweep, and start-success): it advances every non-terminal
// operation on every bridge it touches - timeouts, Prepared/Source_Stopped
// continuation and Ready/startup-failure detection - without resending stop or
// launch commands, which stay on bridge connect/hello transitions. Idempotent:
// every advance is a revision compare-and-set.
reconcile_active_reconfigurations :: proc(service: ^Agent_Service) -> int {
	if service == nil || service.agents == nil do return 0
	ops, err := iface.instance_reconfiguration_list(service.agents, "", "", true)
	if err.code != .None do return 0
	bridges := make([dynamic]string, context.temp_allocator)
	for op in ops {
		for id in ([]string{op.source.bridge_id, op.destination.bridge_id}) {
			if id == "" do continue
			seen := false
			for b in bridges do if b == id { seen = true; break }
			if !seen do append(&bridges, strings.clone(id, context.temp_allocator))
		}
	}
	count := len(ops)
	for &op in ops do domain.instance_reconfiguration_destroy(&op)
	delete(ops)
	for id in bridges do reconcile_instance_reconfigurations(service, id, resend = false)
	// Queued operations: the idle-report path is the primary trigger; this sweep
	// catches a missed edge (an idle report before the queue, or a reconnect).
	count += reconfiguration_fire_waiting(service, "", refresh = true)
	return count
}

// reconfiguration_waiting_for_instance returns the instance's queued operation.
reconfiguration_waiting_for_instance :: proc(service: ^Agent_Service, owner, instance_id: string) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	ops, err := iface.instance_reconfiguration_list_waiting(service.agents, owner, instance_id)
	if err.code != .None do return {}, false, err
	defer delete(ops)
	if len(ops) == 0 do return {}, false, {}
	for &op in ops[1:] do domain.instance_reconfiguration_destroy(&op)
	return ops[0], true, {}
}

// reconfiguration_fire_waiting evaluates queued operations ("" = every instance)
// and fires each whose instance is idle. Called after an instance reports idle
// (notify_instance_activity, outside DB transactions and connection locks) and
// by the reaper sweep. Returns how many queued operations it evaluated.
reconfiguration_fire_waiting :: proc(service: ^Agent_Service, instance_id: string, refresh := false) -> int {
	if service == nil || service.agents == nil || service.agents.reconfiguration_list_waiting == nil do return 0
	// Idle reports arrive with every liveness refresh: skip the operation mutex
	// unless something is queued. The locked re-read below is authoritative.
	if probe, probe_err := iface.instance_reconfiguration_list_waiting(service.agents, "", instance_id); probe_err.code != .None || len(probe) == 0 {
		delete(probe)
		return 0
	} else {
		for &op in probe {
			if refresh {
				inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id)
				if found && project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) {
					_ = agent_liveness(service, inst)
				}
				domain.agent_instance_destroy(&inst)
			}
			domain.instance_reconfiguration_destroy(&op)
		}
		delete(probe)
	}
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	ops, err := iface.instance_reconfiguration_list_waiting(service.agents, "", instance_id)
	if err.code != .None do return 0
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	for op in ops do reconfiguration_fire_waiting_locked(service, op)
	return len(ops)
}

// Called with the operation mutex held. Every outcome is a revision
// compare-and-set, so a concurrent cancel or Restart now simply wins.
reconfiguration_fire_waiting_locked :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) {
	inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id)
	if !found {
		failed, _, _ := reconfiguration_advance(service, op, .Failed, false, false, domain.RECONFIGURATION_CONFLICT, "The agent instance no longer exists.")
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	defer domain.agent_instance_destroy(&inst)
	// Fire-time revision check: anything that changed the configuration while
	// this waited (another apply, a legacy PATCH) invalidates the frozen plan.
	if inst.configuration_revision != op.expected_revision || inst.bridge_id != op.source.bridge_id || string(inst.project_id) != op.source.project_id || inst.provider != op.source.provider || inst.model != op.source.model {
		failed, _, _ := reconfiguration_advance(service, op, .Failed, false, false, domain.RECONFIGURATION_CONFLICT, "Configuration changed while the restart was queued; refresh before applying.")
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	// A user Stop, or a crash, while queued cancels the change: never relaunch an
	// agent that stopped. (stop_instance also cancels at once; this covers stops
	// that did not go through it, e.g. a bridge-side exit, and the race.)
	if reconfiguration_runtime_stopped(service, inst) {
		cancelled, _, _ := reconfiguration_advance(service, op, .Failed, false, false, domain.RECONFIGURATION_CANCELLED, RECONFIGURATION_STOPPED_MESSAGE)
		domain.instance_reconfiguration_destroy(&cancelled)
		return
	}
	if !reconfiguration_instance_idle(service, inst) do return
	if valid, validity_err := reconfiguration_validate_live_destination(service, op); !valid {
		failed, _, _ := reconfiguration_advance(service, op, .Failed, false, false, domain.error_code_string(validity_err.code), validity_err.message)
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	next := inst
	next.bridge_id = op.destination.bridge_id; next.project_id = domain.Project_ID(op.destination.project_id); next.project_path = op.destination.project_path
	next.provider_profile = domain.profile_effective_id(op.destination.provider, op.destination.provider_profile); next.provider = op.destination.provider; next.model = op.destination.model
	next.permission_mode = domain.agent_instance_permission_mode_normalize(op.destination.permission_mode)
	next.runtime_transport = op.destination.runtime_transport
	next.runtime_transport_override = domain.runtime_transport_override_normalize(op.destination.runtime_transport_override)
	generation, admitted, _ := reserve_runtime_launch(service, next)
	if !admitted {
		failed, _, _ := reconfiguration_advance(service, op, .Failed, false, false, "destination_capacity", "Destination capacity is unavailable; the agent keeps running with its current settings.")
		domain.instance_reconfiguration_destroy(&failed)
		return
	}
	defer project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
	// Same continuation as an immediate apply: idle implies a live source.
	started, _, _ := reconfiguration_start_stop(service, op)
	domain.instance_reconfiguration_destroy(&started)
}

RECONFIGURATION_STOPPED_MESSAGE :: "Agent stopped; the queued change was cancelled."

// reconfiguration_cancel_waiting_locked cancels the instance's queued operation,
// if any (operation mutex held). Used when the agent is explicitly stopped.
reconfiguration_cancel_waiting_locked :: proc(service: ^Agent_Service, owner, instance_id: string) {
	queued, found, _ := reconfiguration_waiting_for_instance(service, owner, instance_id)
	if !found do return
	defer domain.instance_reconfiguration_destroy(&queued)
	cancelled, _, _ := reconfiguration_advance(service, queued, .Failed, false, false, domain.RECONFIGURATION_CANCELLED, RECONFIGURATION_STOPPED_MESSAGE)
	domain.instance_reconfiguration_destroy(&cancelled)
}

// cancel_instance_reconfiguration ends a queued (Waiting_For_Idle) operation.
// Any other phase is a conflict: a running change is never cancelled here.
cancel_instance_reconfiguration :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id, key: string, expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	if strings.trim_space(key) == "" || expected_revision < 1 do return {}, false, domain.domain_error(.Validation_Failed, "idempotency_key and expected_operation_revision are required")
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, false, err
	defer domain.agent_instance_destroy(&inst)
	op, exists, op_err := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, key)
	if !exists do return {}, false, op_err
	defer domain.instance_reconfiguration_destroy(&op)
	if op.phase != .Waiting_For_Idle do return {}, false, domain.domain_error(.Conflict, "only a configuration change queued after the current turn can be cancelled")
	if op.revision != expected_revision do return {}, false, domain.domain_error(.Conflict, "operation changed; refresh before cancelling")
	return reconfiguration_advance(service, op, .Failed, false, false, domain.RECONFIGURATION_CANCELLED, "Queued configuration change cancelled.")
}

reconcile_instance_reconfigurations :: proc(service: ^Agent_Service, bridge_id: string, resend := true) {
	if service == nil || service.agents == nil do return
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	ops, err := iface.instance_reconfiguration_list(service.agents, "", "", true)
	if err.code != .None do return
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	for op in ops {
		if op.source.bridge_id != bridge_id && op.destination.bridge_id != bridge_id do continue
		created_ms, created_ok := platform.rfc3339_to_unix_ms(op.updated_at)
		now_ms, now_ok := platform.rfc3339_to_unix_ms(platform.clock_now(service.clock))
		if created_ok && now_ok && now_ms - created_ms > 180_000 && (op.phase == .Stopping || op.phase == .Launching) {
			failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, op.source_stopped, op.destination_committed, "confirmation_timeout", "Runtime confirmation timed out. Apply can retry safely; messages remain disabled.")
			domain.instance_reconfiguration_destroy(&failed)
			continue
		}
		switch op.phase {
		case .Prepared:
			started, _, _ := reconfiguration_start_stop(service, op); domain.instance_reconfiguration_destroy(&started)
		case .Source_Stopped:
			reconfiguration_launch_destination(service, op)
		case .Launching:
			if inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id); found {
				if inst.launch_epoch == op.launch_epoch && inst.startup_status == "ready" {
					ready, _, _ := reconfiguration_advance(service, op, .Ready, true, true); domain.instance_reconfiguration_destroy(&ready)
				} else if inst.runtime_status == "failed" || inst.runtime_status == "blocked" {
					failed, _, _ := reconfiguration_advance(service, op, .Recovery_Required, true, true, "startup_failed", "Destination startup needs attention; conversation remains read-only."); domain.instance_reconfiguration_destroy(&failed)
				}
				if resend && bridge_id == op.destination.bridge_id && inst.launch_epoch == op.launch_epoch && (inst.runtime_status == "launching" || inst.runtime_status == "unreachable") {
					_, _ = send_reconfiguration_launch(service, op)
				}
				domain.agent_instance_destroy(&inst)
			}
		case .Stopping:
			// Idempotent source-only stop is safe to resend after Hub restart: no
			// destination can launch until the acknowledged phase was persisted.
			if resend && bridge_id == op.source.bridge_id {
				_, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = bridge_id, command_id = op.stop_command_id, body_json = stop_command_json(op.stop_command_id, op.agent_instance_id, "configuration_change")})
			}
		case .Recovery_Required:
			if op.failure_code == "force_stopping" {
				target := op.destination.bridge_id if op.destination_committed else op.source.bridge_id
				if resend && bridge_id == target { _, _ = project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = target, command_id = op.stop_command_id, body_json = stop_command_json(op.stop_command_id, op.agent_instance_id, "recovery_force_stop", force = true)}) }
				continue
			}
			if op.destination_committed {
				if inst, found, _ := iface.agent_get_instance(service.agents, op.agent_instance_id); found {
					if inst.launch_epoch == op.launch_epoch && inst.startup_status == "ready" {
						ready, _, _ := reconfiguration_advance(service, op, .Ready, true, true); domain.instance_reconfiguration_destroy(&ready)
					}
					domain.agent_instance_destroy(&inst)
				}
			}
		case .Ready, .Failed:
		case .Waiting_For_Idle: // not listed here (blocks_input=0): see reconfiguration_fire_waiting
		}
	}
	// A reconnect or hello on the source bridge may have made a queued
	// operation's instance idle without a fresh activity transition.
	waiting, waiting_err := iface.instance_reconfiguration_list_waiting(service.agents, "", "")
	if waiting_err.code != .None do return
	defer { for &op in waiting do domain.instance_reconfiguration_destroy(&op); delete(waiting) }
	for op in waiting do if op.source.bridge_id == bridge_id do reconfiguration_fire_waiting_locked(service, op)
}

reconfiguration_json :: proc(op: domain.Instance_Reconfiguration) -> string {
	data, err := json.marshal(op)
	if err != nil do return "{}"
	return string(data)
}

retry_instance_reconfiguration :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id, key: string, expected_revision: int, guard_ctx:rawptr=nil, guard:proc(ctx:rawptr)->domain.Domain_Error=nil, guard_factory:^iface.Unit_Of_Work_Factory=nil) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	acceptance: iface.Unit_Of_Work
	accepting := false
	if guard_factory != nil {
		begun: bool; e: domain.Domain_Error
		acceptance, begun, e = iface.unit_of_work_begin(guard_factory)
		if !begun do return {},false,e
		accepting = true
	}
	defer if accepting do iface.unit_of_work_rollback(&acceptance)
	if accepting && acceptance.nested do return {},false,domain.domain_error(.Conflict,"native Fleet retry requires its own transaction")
	if guard!=nil {if err:=guard(guard_ctx);err.code!=.None do return {},false,err}
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, false, err
	defer domain.agent_instance_destroy(&inst)
	op, exists, op_err := iface.instance_reconfiguration_get(service.agents, string(inst.owner_user_id), instance_id, key)
	if !exists do return {}, false, op_err
	defer domain.instance_reconfiguration_destroy(&op)
	if op.failure_code == "force_stopping" do return {}, false, domain.domain_error(.Conflict, "Force stop must be confirmed before retrying")
	if op.phase != .Recovery_Required || op.revision != expected_revision do return {}, false, domain.domain_error(.Conflict, "operation changed; refresh before retrying")
	if valid, validity_err := reconfiguration_validate_live_destination(service, op); !valid do return {}, false, validity_err
	destination := inst; destination.bridge_id = op.destination.bridge_id; destination.provider_profile=domain.profile_effective_id(op.destination.provider,op.destination.provider_profile); destination.provider = op.destination.provider; destination.model = op.destination.model
	_, valid, validation_err := validate_pinned_provider_model(service, auth, destination, destination.provider, destination.model)
	if !valid do return {}, false, validation_err
	if !op.source_stopped {
		next := op; next.stop_command_id = platform.generate_id(service.ids, "cmd_reconfig_stop_retry_")
		// Reuse the same disconnect-aware path as a new request. A source that
		// vanished while the operation awaited recovery is fenced and superseded.
		stopping, saved, se := reconfiguration_advance(service, next, .Stopping, false, false, notify=!accepting)
		if !saved do return {},false,se
		if e:=reconfiguration_commit_acceptance(&acceptance,&accepting);e.code!=.None {domain.instance_reconfiguration_destroy(&stopping);return {},false,e}
		if guard_factory!=nil do reconfiguration_notify(service,stopping,"progress",false)
		return reconfiguration_send_stop(service, stopping)
	}
	if !op.destination_committed {
		stopped, saved, save_err := reconfiguration_advance(service, op, .Source_Stopped, true, false, notify=!accepting)
		if !saved do return {}, false, save_err
		defer domain.instance_reconfiguration_destroy(&stopped)
		if e:=reconfiguration_commit_acceptance(&acceptance,&accepting);e.code!=.None do return {},false,e
		if guard_factory!=nil do reconfiguration_notify(service,stopped,"progress",false)
		reconfiguration_launch_destination(service, stopped)
		return iface.instance_reconfiguration_get(service.agents, op.owner_user_id, instance_id, key)
	}
	// Keep the launch epoch: an alive destination with that assertion is reused,
	// not restarted. A new command id lets an earlier failed result be retried.
	next := op; next.launch_command_id = platform.generate_id(service.ids, "cmd_reconfig_launch_retry_")
	next.launch_json = ""
	launching, saved, save_err := reconfiguration_advance(service, next, .Launching, true, true, notify=!accepting)
	if !saved do return {}, false, save_err
	if e:=reconfiguration_commit_acceptance(&acceptance,&accepting);e.code!=.None {domain.instance_reconfiguration_destroy(&launching);return {},false,e}
	if guard_factory!=nil do reconfiguration_notify(service,launching,"progress",false)
	_, _ = send_reconfiguration_launch(service, launching)
	domain.instance_reconfiguration_destroy(&launching)
	return iface.instance_reconfiguration_get(service.agents,op.owner_user_id,instance_id,key)
}

reconfiguration_commit_acceptance :: proc(u:^iface.Unit_Of_Work, active:^bool)->domain.Domain_Error {
	if !active^ do return {}
	active^=false
	committed, err:=iface.unit_of_work_commit(u)
	if !committed && err.code==.None do return domain.domain_error(.Internal_Error,"native Fleet acceptance commit failed")
	return err
}

// The commit trigger owns the generation increment. Read its committed row,
// freeze one complete frame durably, then use the existing command transport.
send_reconfiguration_launch :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) -> (bool, domain.Domain_Error) {
	inst, found, err := iface.agent_get_instance(service.agents,op.agent_instance_id)
	if !found do return false,err
	defer domain.agent_instance_destroy(&inst)
	if inst.launch_epoch!=op.launch_epoch || inst.configuration_revision!=op.expected_revision+1 do return false,domain.domain_error(.Conflict,"reconfiguration launch generation changed")
	if transport_err := validate_frozen_runtime_transport(service, inst); transport_err.code != .None do return false, transport_err
	frame := op.launch_json
	if frame=="" {
		lease: Start_Lease
		has_lease := false
		if service.hooks.launch_context!=nil {
			lease,has_lease,err=service.hooks.launch_context(service.hooks.ctx,inst)
			if err.code!=.None do return false,err
		}
		defer {delete(lease.task_id);delete(lease.role);delete(lease.lease_id);delete(lease.pack_json);delete(lease.permission_mode)}
		ptr: ^Start_Lease
		if has_lease do ptr=&lease
		frame=start_launch_json(service,{instance=inst,command_id=op.launch_command_id},ptr)
		defer delete(frame)
		next:=op;next.launch_json=frame;next.revision+=1
		stored, saved, se:=iface.instance_reconfiguration_advance(service.agents,next,op.revision)
		if !saved do return false,se
		domain.instance_reconfiguration_destroy(&stored)
		return start_command_send(service,inst.bridge_id,op.launch_command_id,inst.chain_id,{{bridge_id=inst.bridge_id,deliver=contracts.START_DELIVER_LAUNCH,launch_json=frame}},nil)
	}
	return start_command_send(service,inst.bridge_id,op.launch_command_id,inst.chain_id,{{bridge_id=inst.bridge_id,deliver=contracts.START_DELIVER_LAUNCH,launch_json=frame}},nil)
}

validate_instance_message_configuration :: proc(service: ^Agent_Service, owner: domain.User_ID, instance_id: string) -> (bool, domain.Domain_Error) {
	inst, found, err := iface.agent_get_instance(service.agents, instance_id)
	if !found do return false, err
	defer domain.agent_instance_destroy(&inst)
	if inst.owner_user_id != owner do return false, domain.domain_error(.Not_Found, "agent instance not found")
	if idle, idle_err := reconfiguration_require_idle(service, instance_id); !idle do return false, idle_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !bridge_ok do return false, bridge_err
	defer domain.bridge_destroy(&bridge)
	// Messaging an existing runtime is not a launch: disabled, revoked and
	// pending enrollment flags do not make a connected conversation read-only.
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return false, domain.domain_error(.Bridge_Offline, "conversation is read-only: reconnect the bridge or choose an online bridge")
	if inst.project_id != "" {
		project, project_ok, project_err := iface.project_get(service.projects, inst.project_id)
		if !project_ok do return false, project_err
		if project.owner_user_id != owner || project.state != .Active do return false, domain.domain_error(.Conflict, "conversation is read-only: choose an accessible active project or clear the project")
	}
	_, valid, validation_err := validate_pinned_provider_model(service, contracts.Auth_Context{kind = .Internal_User, user_id = string(owner)}, inst, inst.provider, inst.model)
	return valid, validation_err
}

// DB/runtime-projection checks only: safe on the WS reader after stop confirmation.
reconfiguration_validate_live_destination :: proc(service: ^Agent_Service, op: domain.Instance_Reconfiguration) -> (bool, domain.Domain_Error) {
	bridge, found, err := iface.bridge_get_bridge(service.bridges, op.destination.bridge_id)
	if !found do return false, err
	defer domain.bridge_destroy(&bridge)
	if string(bridge.owner_user_id) != op.owner_user_id do return false, domain.domain_error(.Not_Found, "destination bridge not found")
	ps:=agent_placement(service)
 if eligible,reason:=placement.bridge_eligible(&ps,bridge,{owner=op.owner_user_id,features={"instance_reconfiguration_v1"}}); !eligible do return false,agent_placement_error(&ps,bridge,reason,"destination bridge is offline; reconnect it before Apply","destination bridge must be updated before Apply")

	if op.destination.project_id != "" {
		project, project_found, project_err := iface.project_get(service.projects, domain.Project_ID(op.destination.project_id))
		if !project_found do return false, project_err
		if string(project.owner_user_id) != op.owner_user_id || project.state != .Active do return false, domain.domain_error(.Conflict, "destination project is unavailable or archived")
		path, path_found, path_err := resolve_project_path_for_launch(service, domain.User_ID(op.owner_user_id), domain.Project_ID(op.destination.project_id), op.destination.bridge_id)
		if !path_found do return false, path_err
		if path != op.destination.project_path do return false, domain.domain_error(.Conflict, "destination project path changed after preflight; recovery needs the original validated path")
	}
	if op.destination.runtime_transport=="acp" {
		ps:=provider_service.Provider_Service{repo=service.providers,bridges=service.bridges,redetector=service.acp_redetector}
		entry,found,err:=iface.provider_catalog_get(service.providers,op.destination.provider)
		if err.code!=.None do return false,err
		if !found do return false,domain.domain_error(.ACP_Unavailable,"ACP provider is unavailable")
		defer domain.provider_catalog_entry_destroy(entry)
		if e:=provider_service.require_acp_ready(&ps,op.destination.bridge_id,entry);e.code!=.None do return false,e
	}
	inst,inst_ok,inst_err:=iface.agent_get_instance(service.agents,op.agent_instance_id)
 if !inst_ok do return false,inst_err
 defer domain.agent_instance_destroy(&inst)
 _,valid,validation_err:=agent_launchable(&ps,inst.agent_id,op.destination.bridge_id,op.destination.provider,op.destination.model,op.destination.provider_profile)
 return valid,validation_err
}

// Called with the operation mutex held. A force stop targets the current routing
// owner, never both bridges; the original move snapshots remain immutable.
force_stop_instance_reconfiguration_locked :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, found, err := get_instance(service, auth, instance_id)
	if !found do return {}, true, err
	ops, list_err := iface.instance_reconfiguration_list(service.agents, string(inst.owner_user_id), instance_id, true)
	if list_err.code != .None { domain.agent_instance_destroy(&inst); return {}, true, list_err }
	defer { for &op in ops do domain.instance_reconfiguration_destroy(&op); delete(ops) }
	if len(ops) == 0 { domain.agent_instance_destroy(&inst); return {}, false, {} }
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) { domain.agent_instance_destroy(&inst); return {}, true, domain.domain_error(.Bridge_Offline, "reconnect the current bridge to confirm Force stop") }
	op := ops[0]
	next := op
	if op.failure_code != "force_stopping" do next.stop_command_id = platform.generate_id(service.ids, "cmd_recovery_force_stop_")
	stopping, saved, save_err := reconfiguration_advance(service, next, .Recovery_Required, op.source_stopped, op.destination_committed, "force_stopping", "Force stopping the current runtime. Settings unlock after termination is confirmed.")
	if !saved { domain.agent_instance_destroy(&inst); return {}, true, save_err }
	defer domain.instance_reconfiguration_destroy(&stopping)
	command := project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = stopping.stop_command_id, body_json = stop_command_json(stopping.stop_command_id, instance_id, "recovery_force_stop", force = true)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent { domain.agent_instance_destroy(&inst); return {}, true, send_err }
	inst.runtime_status = "stopping"; inst.updated_at = platform.clock_now(service.clock)
	result, ok, persist_err := iface.agent_save_instance(service.agents, inst)
	return result, true, persist_err if !ok else domain.Domain_Error{}
}
