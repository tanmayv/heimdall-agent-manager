package agent

import "core:strings"
import jsonx "odin_test:lib/jsonx"
import "core:mem"
import virtual "core:mem/virtual"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import placement "odin_test:hub/service/placement"
import project_service "odin_test:hub/service/project"
import dbt "odin_test:hub/platform/dbtelemetry"

START_REF_MAX_BYTES :: 128

Start_If_Live :: enum { Refuse, Relaunch, Keep }

Start_Request :: struct {
	if_live: Start_If_Live,
	ref: string,
	provider, model, profile: string,
	expected: ^domain.Agent_Instance,
	expected_run_count: ^int,
	require_live: bool,
	process_fact: Maybe(Agent_Liveness),
	guard: proc(ctx: rawptr) -> domain.Domain_Error,
	guard_ctx: rawptr,
}

Start_Ticket :: struct {
	instance: domain.Agent_Instance,
	command_id: string,
	reservation: int,
	reserved, kept_live, reused: bool,
	allocator: mem.Allocator,
}

start_ticket_destroy :: proc(t: ^Start_Ticket) {
	if t == nil do return
	saved_context := context
	defer context = saved_context
	if t.allocator.procedure != nil do context.allocator = t.allocator
	domain.agent_instance_destroy(&t.instance)
	delete(t.command_id)
	t^ = {}
}

// start_process_fact is the in-transaction view of the authoritative service.
start_process_fact :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> Agent_Liveness {
	return agent_liveness(service, inst, cache_only = true)
}

// No mutex and no network: this joins a transaction already open on this thread.
start_begin :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, req: Start_Request, allocator := context.allocator) -> (t: Start_Ticket, err: domain.Domain_Error) {
	// Guards run in the caller's context and their errors are returned unchanged.
	if req.guard != nil {
		if guard_err := req.guard(req.guard_ctx); guard_err.code != .None do return {}, guard_err
	}
	req := req
	req.guard = nil
	saved_context := context
	defer context = saved_context
	// Legacy validation helpers return request-scoped borrowed values and retain
	// intermediate repository reads. Bound that scratch storage to this call;
	// the ticket and error are the only values that leave it.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return {}, domain.domain_error(.Internal_Error, "cannot allocate start scratch space")
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	scratch, begin_err := start_begin_impl(service, auth, instance_id, req)
	context.allocator = allocator
	if begin_err.code != .None {
		begin_err.message = strings.clone(begin_err.message)
		begin_err.details_json = strings.clone(begin_err.details_json)
		return {}, begin_err
	}
	t = scratch
	t.allocator = allocator
	t.instance = domain.agent_instance_clone(scratch.instance)
	t.command_id = strings.clone(scratch.command_id)
	return t, {}
}

start_begin_impl :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, req: Start_Request) -> (t: Start_Ticket, err: domain.Domain_Error) {
	if req.guard != nil {
		if guard_err := req.guard(req.guard_ctx); guard_err.code != .None do return {}, guard_err
	}
	inst, found, read_err := get_instance(service, auth, instance_id)
	if !found do return {}, read_err
	defer domain.agent_instance_destroy(&inst)
	// Automatic self-restarts cannot revive a completed/user-stopped process.
	// Check before ref reuse and admission (manual start lock or task transaction).
	if req.expected_run_count != nil && inst.run_count != req.expected_run_count^ do return {}, domain.domain_error(.Conflict, "superseded restart generation", `{"code":"start_raced"}`)
	fact, observed := req.process_fact.?
	if !observed do fact = start_process_fact(service, inst)
	if req.require_live && (inst.stopped_by != "" || inst.stop_reason != "" || fact.state != .Alive) do return {}, domain.domain_error(.Conflict, "instance stop superseded restart", `{"code":"start_raced"}`)
	if req.ref != "" && inst.start_ref == req.ref && fact.state != .Exited && inst.stop_reason == "" {
		return start_ticket_for_row(service, inst, req.ref, false, true), {}
	}
	if req.expected != nil {
		e := req.expected
		if inst.run_count != e.run_count || inst.configuration_revision != e.configuration_revision || inst.launch_epoch != e.launch_epoch || inst.bridge_id != e.bridge_id || inst.stopped_by != e.stopped_by || inst.stop_reason != e.stop_reason do return {}, domain.domain_error(.Conflict, "instance changed before runtime action", `{"code":"start_raced"}`)
	}
	if req.if_live != .Relaunch {
		if fact.state == .Alive {
			if req.if_live == .Keep do return start_ticket_for_row(service, inst, req.ref, true, false), {}
			return {}, domain.domain_error(.Conflict, "instance is already running", `{"code":"already_running"}`)
		}
		if fact.state == .Unknown && fact.reason != .never_started {
			return {}, domain.domain_error(.Bridge_Busy, "could not confirm previous process exited")
		}
	}
	if idle, idle_err := reconfiguration_require_idle(service, instance_id); !idle do return {}, idle_err

	next := inst
	if req.provider != "" {
		if next.provider != req.provider do next.provider_profile = req.provider
		next.provider = req.provider
	}
	if req.model != "" do next.model = req.model
	if req.profile != "" do next.provider_profile = req.profile
	managed, scope_err := iface.fleet_scope_get(service.bridges, inst)
	if scope_err.code != .None do return {}, scope_err
	if managed {
		runtime, e := chain_fleet_runtime(service, inst.owner_user_id, inst.chain_id, inst.bridge_id, inst.agent_id, {next.provider, next.provider_profile, next.model})
		if e.code != .None do return {}, e
		defer domain.fleet_runtime_destroy(runtime)
		next.provider, next.provider_profile, next.model = strings.clone(runtime.provider, context.temp_allocator), strings.clone(runtime.provider_profile, context.temp_allocator), strings.clone(runtime.model, context.temp_allocator)
	}
	_, valid, validation_err := validate_pinned_provider_model(service, auth, next, next.provider, next.model)
	if !valid do return {}, validation_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !bridge_ok do return {}, bridge_err
	defer domain.bridge_destroy(&bridge)
	if bridge.owner_user_id != inst.owner_user_id do return {}, domain.domain_error(.Not_Found, "bridge not found")
	ps := agent_placement(service)
	if eligible, reason := placement.bridge_eligible(&ps, bridge, {owner=string(bridge.owner_user_id)}); !eligible do return {}, agent_placement_error(&ps, bridge, reason, "pinned bridge is offline")
	next.stopped_by = ""
	next.status_message = ""
	next.runtime_status = "launching"
	next.startup_status = "starting"
	next.activity_status = "unknown"
	if freeze_err := freeze_runtime_transport(service, &next); freeze_err.code != .None do return {}, freeze_err
	defer delete(next.runtime_transport)
	if transport_err := validate_frozen_runtime_transport(service, next); transport_err.code != .None do return {}, transport_err
	next.launch_epoch = runtime_launch_epoch(service, next.runtime_transport, next.launch_epoch)
	next.run_count += 1
	now := platform.clock_now(service.clock)
	next.started_at = now
	next.stopped_at = ""
	next.updated_at = now
	next.last_seen_at = now
	next.start_ref = req.ref
	generation, admitted, quota_err := reserve_runtime_launch(service, next)
	if !admitted do return {}, quota_err
	saved, updated, save_err := iface.agent_save_instance_guarded(service.agents, next, inst.run_count, inst.launch_epoch, inst.configuration_revision)
	if !updated {
		project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, next.bridge_id, generation, next.agent_instance_id)
		if save_err.code != .None do return {}, save_err
		return {}, domain.domain_error(.Conflict, "instance changed before start", `{"code":"start_raced"}`)
	}
	t = start_ticket_for_row(service, saved, req.ref, false, false)
	t.reservation = generation
	t.reserved = true
	return t, {}
}

start_ticket_for_row :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, ref: string, kept_live, reused: bool) -> Start_Ticket {
	command_id := ""
	if ref != "" {
		command_id = strings.concatenate({"sb_", ref})
	} else {
		command_id = strings.concatenate({platform.generate_id(service.ids, "cmd_launch_"), "_", inst.agent_instance_id})
	}
	return {instance=domain.agent_instance_clone(inst), command_id=command_id, kept_live=kept_live, reused=reused, allocator=context.allocator}
}

start_reuse :: proc(service: ^Agent_Service, instance_id, ref: string, allocator := context.allocator) -> (t: Start_Ticket, ok: bool, ended: bool, err: domain.Domain_Error) {
	context.allocator = allocator
	inst, found, read_err := iface.agent_get_instance(service.agents, instance_id)
	if !found do return {}, false, true, read_err
	defer domain.agent_instance_destroy(&inst)
	if ref != "" && inst.start_ref == ref && inst.stop_reason == "" && start_process_fact(service, inst).state != .Exited {
		return start_ticket_for_row(service, inst, ref, false, true), true, false, {}
	}
	return {}, false, true, {}
}

start_launch_json :: proc(service: ^Agent_Service, t: Start_Ticket, lease: ^Start_Lease = nil, allocator := context.allocator) -> string {
	saved_context := context
	defer context = saved_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return ""
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	text := launch_command_json_full(service, t.command_id, t.instance, lease)
	return strings.clone(text, allocator)
}

start_cancel :: proc(service: ^Agent_Service, t: ^Start_Ticket) {
	if !t.reserved do return
	project_service.bridge_runtime_instance_cancel_reservation(service.bridge_runtime_registry, t.instance.bridge_id, t.reservation, t.instance.agent_instance_id)
	t.reserved = false
}

start_settle :: proc(service: ^Agent_Service, t: ^Start_Ticket, sent: bool) {
	if t.kept_live || t.reused do return
	// A send error does not prove the Bridge missed the request or that its
	// child exited. Don't overwrite status, including a concurrent ready report.
	if !sent { start_cancel(service, t) } else { t.reserved = false }
}

start_send :: proc(service: ^Agent_Service, t: ^Start_Ticket) -> domain.Domain_Error {
	if t.kept_live || t.reused do return {}
	err := validate_frozen_runtime_transport(service, t.instance)
	sent := false
	if err.code == .None {
		body := start_launch_json(service, t^)
		entry := Start_Run_Entry{bridge_id=t.instance.bridge_id,deliver=contracts.START_DELIVER_LAUNCH,launch_json=body}
		sent, err = start_command_send(service, t.instance.bridge_id, t.command_id, t.instance.chain_id, {entry}, nil)
		delete(body)
	}
	if !sent {
		start_settle(service, t, false)
		return err
	}
	t.reserved = false // The registry holds it until status/expiry; the ticket is settled.
	return {}
}

start :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, req: Start_Request) -> (inst: domain.Agent_Instance, kept_live: bool, ok: bool, err: domain.Domain_Error) {
	req := req
	obs_row: domain.Agent_Instance
	defer domain.agent_instance_destroy(&obs_row)
	if (req.require_live || req.if_live != .Relaunch) && (req.process_fact == nil || req.expected == nil) {
		current, found, err := get_instance(service, auth, instance_id)
		if !found do return {}, false, false, err
		obs_row = current
		fact := start_process_fact(service, current)
		if fact.reason == .not_observed do fact = agent_liveness(service, current)
		req.process_fact = fact
		if req.expected == nil do req.expected = &obs_row
	}
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	ticket, begin_err := start_begin(service, auth, instance_id, req)
	if begin_err.code != .None do return {}, false, false, begin_err
	defer start_ticket_destroy(&ticket)
	if send_err := start_send(service, &ticket); send_err.code != .None do return {}, false, false, send_err
	inst = ticket.instance
	ticket.instance = {}
	return inst, ticket.kept_live, true, {}
}

// Manual start is a relaunch when a child already exists. The Bridge holds
// its per-instance lock across closing the old child and spawning the new
// one. Release the Hub lifecycle lock before waiting: start-success needs it.
start_instance_confirmed :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, guard_ctx: rawptr = nil, guard: proc(ctx: rawptr) -> domain.Domain_Error = nil) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	ticket, begin_err := start_begin(service, auth, instance_id, {if_live = .Relaunch, guard = guard, guard_ctx = guard_ctx})
	dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	if begin_err.code != .None do return {}, false, begin_err
	defer start_ticket_destroy(&ticket)
	body := start_launch_json(service, ticket)
	defer delete(body)
	if len(body) == 0 || body[len(body)-1] != '}' {
		start_settle(service, &ticket, false)
		return {}, false, domain.domain_error(.Internal_Error, "could not encode start command")
	}
	confirmed_body := strings.concatenate({body[:len(body)-1], `,"confirm_start":true}`})
	defer delete(confirmed_body)
	reply, got, err := project_service.bridge_command_send_runtime_wait(service.bridge_command_sink, {bridge_id = ticket.instance.bridge_id, command_id = ticket.command_id, body_json = confirmed_body}, 32_000)
	defer delete(reply)
	if !got {
		start_settle(service, &ticket, false)
		return {}, false, err
	}
	if ok, refusal := project_service.bridge_reply_refusal(reply, ticket.instance.bridge_id); !ok {
		start_settle(service, &ticket, false)
		return {}, false, refusal
	}
	process_pid := confirmed_start_pid(reply, ticket.command_id, instance_id, ticket.instance.run_count)
	if process_pid <= 0 {
		start_settle(service, &ticket, false)
		return {}, false, domain.domain_error(.Conflict, "bridge did not confirm start-success for the new process")
	}
	start_settle(service, &ticket, true)
	fresh, found, read_err := get_instance(service, auth, instance_id)
	if !found do return {}, false, read_err
	if fresh.run_count != ticket.instance.run_count || fresh.launch_epoch != ticket.instance.launch_epoch || fresh.bridge_id != ticket.instance.bridge_id {
		domain.agent_instance_destroy(&fresh)
		return {}, false, domain.domain_error(.Conflict, "start operation was superseded")
	}
	if fresh.startup_status != "ready" {
		domain.agent_instance_destroy(&fresh)
		return {}, false, domain.domain_error(.Conflict, "new process is no longer ready")
	}
	record_confirmed_start_process(service, fresh, process_pid)
	return fresh, true, {}
}

confirmed_start_pid :: proc(reply, op, instance_id: string, run_count: int) -> int {
	if !jsonx.extract_bool(reply, "ok", false, true) || jsonx.extract_string(reply, "command_id", "", true, context.temp_allocator) != op do return 0
	payload, ok := jsonx.extract_raw_object(reply, "payload", true, context.temp_allocator)
	if !ok || jsonx.extract_string(payload, "status", "", true, context.temp_allocator) != "succeeded" do return 0
	result, has_result := jsonx.extract_raw_object(payload, "result", true, context.temp_allocator)
	if !has_result || jsonx.extract_string(result, "runtime_status", "", true, context.temp_allocator) != "running" ||
	   jsonx.extract_string(result, "agent_instance_id", "", true, context.temp_allocator) != instance_id ||
	   jsonx.extract_int(result, "expected_run_count", -1, true) != run_count {
		return 0
	}
	return jsonx.extract_int(result, "process_pid", 0, true)
}

start_begin_for_bridge :: proc(service: ^Agent_Service, owner: domain.User_ID, bridge_id, instance_id, ref: string) -> (launch_json: string, run_count: int, reused: bool, ok: bool, err: domain.Domain_Error) {
	if strings.trim_space(ref) == "" do return "", 0, false, false, domain.domain_error(.Validation_Failed, "ref is required")
	if len(ref) > START_REF_MAX_BYTES do return "", 0, false, false, domain.domain_error(.Validation_Failed, "ref exceeds 128 bytes")
	inst, found, read_err := iface.agent_get_instance(service.agents, instance_id)
	if !found do return "", 0, false, false, read_err
	defer domain.agent_instance_destroy(&inst)
	if inst.owner_user_id != owner || inst.bridge_id != bridge_id do return "", 0, false, false, domain.domain_error(.Not_Found, "agent instance not found")
	// A Bridge-triggered wake is also a demand for process evidence. Probe
	// before taking the mutex, then fence the result against this generation.
	fact := start_process_fact(service, inst)
	if fact.reason == .not_observed do fact = agent_liveness(service, inst)
	lock_tok := dbt.timed_lock(&service.reconfiguration_mutex, .Reconfig)
	defer dbt.timed_unlock(&service.reconfiguration_mutex, .Reconfig, lock_tok)
	auth := contracts.Auth_Context{kind=.Session, user_id=string(owner)}
	ticket, begin_err := start_begin(service, auth, instance_id, {if_live=.Refuse, ref=ref, process_fact=fact, expected=&inst})
	if begin_err.code != .None do return "", 0, false, false, begin_err
	defer start_ticket_destroy(&ticket)
	return start_launch_json(service, ticket), ticket.instance.run_count, ticket.reused, true, {}
}

create_instance_stopped :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Instance_Input, default_title_override: string = "") -> (inst: domain.Agent_Instance, ok: bool, err: domain.Domain_Error) {
	allocator := context.allocator
	saved_context := context
	defer context = saved_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return {}, false, domain.domain_error(.Internal_Error, "cannot allocate instance scratch space")
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	prepared, _, prepared_ok, prepare_err := prepare_instance(service, auth, input, default_title_override)
	context.allocator = allocator
	if !prepared_ok {
		prepare_err.message = strings.clone(prepare_err.message)
		prepare_err.details_json = strings.clone(prepare_err.details_json)
		return {}, false, prepare_err
	}
	return domain.agent_instance_clone(prepared), true, {}
}
