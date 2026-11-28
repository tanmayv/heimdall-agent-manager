package agent

import "core:encoding/json"
import "core:crypto/hash"
import "core:fmt"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import iface "odin_test:hub/repository/iface"

Instance_Probe_State :: enum {Unknown, Absent, Alive, Exited}

Instance_Probe :: struct {
	state: Instance_Probe_State,
	pid: int,
	exit_code: i32,
	orphan_reaped: bool,
	launch_absence: bool,
	ready: bool,
}

Agent_Liveness_State :: enum {Unknown, Alive, Exited}
Agent_Liveness_Reason :: enum {not_observed, never_started, retired, stop_confirmed, previous_exit_confirmed, bridge_unavailable, probe_timed_out, invalid_probe, stale_process_generation, missing_from_pty_roster, orphan_reaped, pty_child_alive, pty_child_exited, launch_absence_verified}
Agent_Liveness :: struct {
	state: Agent_Liveness_State,
	reason: Agent_Liveness_Reason,
	pid: int,
	exit_code: i32,
	ready: bool,
}

Agent_Liveness_Cache_Row :: struct {
	key: [32]byte,
	at: time.Tick,
	fact: Agent_Liveness,
	from_exit_frame: bool,
}

Agent_Liveness_Cache :: struct {
	mutex: sync.Mutex,
	rows: [64]Agent_Liveness_Cache_Row,
	// Weak launch-only evidence and negative replies must not replace or leak
	// into the cache used by terminal reconciliation and claim recovery.
	launch_rows: [64]Agent_Liveness_Cache_Row,
}

AGENT_LIVENESS_CACHE_TTL :: 2 * time.Second

agent_liveness_key :: proc(inst: domain.Agent_Instance) -> (key: [32]byte) {
	// A later runtime observation for the same generation (for example a
	// recovery start) must not reuse an older process result.
	identity := fmt.tprintf("%q/%q/%q/%d/%d", inst.bridge_id, inst.agent_instance_id, inst.launch_epoch, inst.run_count, inst.last_applied_seq)
	hash.hash_string_to_buffer(.SHA256, identity, key[:])
	return
}

// The cache is bounded and fenced by the durable generation and owning bridge.
// runtime_status is deliberately not an input. A miss authorizes no state
// mutation and may perform one bounded RPC, so call outside the UoW and reader.
agent_liveness :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, force_probe := false, prefer_reported_exit := false, cache_only := false, for_launch := false) -> Agent_Liveness {
	// A new durable generation starts at run_count = 1. An explicit
	// acknowledged close is durable until the next generation clears its
	// reason. Neither case needs another RPC to rule out a current child.
	when ODIN_TEST {
		if service != nil && service.fixture_start_fact != nil do return service.fixture_start_fact(inst)
	}
	// A legacy terminated tombstone is not a process report, and cannot
	// authorize either wake or physical exit.
	if inst.runtime_status == "terminated" do return {reason = .retired}
	if inst.run_count == 0 do return {reason = .never_started}
	if inst.status_message == "pty_stop_confirmed" && inst.stopped_at != "" do return {state = .Exited, reason = .stop_confirmed}
	if service == nil do return {}
	key := agent_liveness_key(inst)
	index := int(key[0]) % len(service.liveness_cache.rows)
	cache := &service.liveness_cache
	sync.mutex_lock(&cache.mutex)
	slot := cache.rows[index]
	launch_slot := cache.launch_rows[index] if for_launch else Agent_Liveness_Cache_Row{}
	sync.mutex_unlock(&cache.mutex)
	if slot.key == key && time.tick_since(slot.at) < AGENT_LIVENESS_CACHE_TTL &&
	   (!for_launch || slot.fact.state != .Unknown) &&
	   (!force_probe || (prefer_reported_exit && slot.from_exit_frame)) {
		return slot.fact
	}

	// Transactions only read already-observed facts, never wait for a
	// network response. The scheduler asks for refresh after the UoW.
	if cache_only {
		// Only the terminal report writer can set this reserved reason.
		// It remains a valid launch fence after PID/code cache expiry,
		// but is not a fresh child exit receipt for claim revocation.
		if inst.status_message == "pty_child_exited" && inst.stopped_at != "" {
			return {state = .Exited, reason = .previous_exit_confirmed}
		}
		if inst.stopped_at != "" {
			if inst.status_message == "missing_from_pty_roster" do return {state = .Exited, reason = .missing_from_pty_roster}
			if inst.status_message == "orphan_reaped" do return {state = .Exited, reason = .orphan_reaped}
		}
	}
	if for_launch && !force_probe && launch_slot.key == key && time.tick_since(launch_slot.at) < AGENT_LIVENESS_CACHE_TTL {
		return launch_slot.fact
	}
	if cache_only do return {reason = .not_observed}
	at := time.tick_now()
	observation, reason := probe_instance(service, inst, for_launch = for_launch)
	fact := Agent_Liveness{reason = reason, pid = observation.pid, exit_code = observation.exit_code, ready = observation.ready}
	#partial switch observation.state {
	case .Alive: fact.state = .Alive
	case .Absent, .Exited: fact.state = .Exited
	}
	sync.mutex_lock(&cache.mutex)
	target := &cache.rows[index]
	if for_launch && (fact.state == .Unknown || reason == .launch_absence_verified) do target = &cache.launch_rows[index]
	if target.at._nsec <= at._nsec do target^ = {key = key, at = time.tick_now(), fact = fact}
	sync.mutex_unlock(&cache.mutex)
	return fact
}

// Run outside a Hub UoW and off the Bridge websocket read loop. Otherwise the
// caller can prevent its own response from being read.
@(private = "file")
probe_instance :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, for_launch := false) -> (Instance_Probe, Agent_Liveness_Reason) {
	if service == nil || service.ids == nil || inst.bridge_id == "" || inst.agent_instance_id == "" do return {}, .bridge_unavailable
	id := platform.generate_id(service.ids, "cmd_instance_probe_")
	command, err := json.marshal(contracts.Instance_Probe_Command{contracts.INSTANCE_PROBE_COMMAND, id, inst.agent_instance_id, for_launch})
	if err != nil do return {}, .invalid_probe
	defer delete(command)
	reply, got, wait_err := project.bridge_command_send_runtime_wait(service.bridge_command_sink, {bridge_id = inst.bridge_id, command_id = id, body_json = string(command)}, 3000)
	defer delete(reply)
	if !got do return {}, .probe_timed_out if wait_err.code == .Bridge_Timeout else .bridge_unavailable
	observation := parse_instance_probe(reply, id, inst.agent_instance_id, inst.run_count, inst.launch_epoch, for_launch = for_launch)
	switch observation.state {
	case .Unknown: return observation, .stale_process_generation if observation.pid > 0 else .invalid_probe
	case .Absent: return observation, .launch_absence_verified if observation.launch_absence else .missing_from_pty_roster
	case .Alive: return observation, .pty_child_alive
	case .Exited: return observation, .orphan_reaped if observation.orphan_reaped else .pty_child_exited
	}
	return {}, .invalid_probe
}

parse_instance_probe :: proc(reply, command_id, instance_id: string, expected_run_count := -1, expected_launch_epoch := "", for_launch := false) -> Instance_Probe {
	if !jsonx.extract_bool(reply, "ok", false, true) ||
	   jsonx.extract_string(reply, "command_id", "", true, context.temp_allocator) != command_id {
		return {}
	}
	payload, has_payload := jsonx.extract_raw_object(reply, "payload", true, context.temp_allocator)
	if !has_payload do return {}
	result, has_result := jsonx.extract_raw_object(payload, "result", true, context.temp_allocator)
	if !has_result do return {}
	report: struct {agent_instance_id, state, launch_epoch, source: string, pid: i32, exit_code: Maybe(i32), run_count: Maybe(int), ready: bool}
	if json.unmarshal_string(result, &report, allocator = context.temp_allocator) != nil || report.agent_instance_id != instance_id do return {}
	if expected_run_count >= 0 {
		count, present := report.run_count.?
		if !present || count <= 0 || count != expected_run_count || report.launch_epoch != expected_launch_epoch do return {pid = int(report.pid)}
	}
	switch report.state {
	case "absent":
		if report.pid != 0 || report.exit_code != nil || report.ready do return {}
		if report.source == "os_identity_gone" do return {state = .Absent}
		if for_launch && expected_run_count > 0 && report.source == contracts.INSTANCE_PROBE_LAUNCH_ABSENCE {
			return {state = .Absent, launch_absence = true}
		}
	case "alive", "exited":
		if report.pid <= 0 do return {}
		if report.state == "alive" do return {state = .Alive, pid = int(report.pid), ready = report.ready}
		if report.source == "orphan_reaped" && report.exit_code == nil && !report.ready do return {state = .Exited, pid = int(report.pid), orphan_reaped = true}
		if code, has_code := report.exit_code.?; has_code && report.source == "" do return {state = .Exited, pid = int(report.pid), exit_code = code}
	}
	return {}
}

// The operation ID is supplied by the caller so retries reuse the same
// Bridge command receipt. Call outside the lifecycle lock and WS reader.
confirm_stop_observed_process :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, fact: Agent_Liveness, operation_id: string, reason: Stop_Reason, force := false) -> domain.Domain_Error {
	if service == nil || operation_id == "" || fact.state != .Alive || fact.pid <= 0 do return domain.domain_error(.Conflict, "stop needs a verified live process")
	body := stop_command_json(operation_id, inst.agent_instance_id, reason, force = force, expected_pid = fact.pid, expected_run_count = inst.run_count)
	defer delete(body)
	reply, got, err := project.bridge_command_send_runtime_wait(service.bridge_command_sink, {bridge_id = inst.bridge_id, command_id = operation_id, body_json = body}, 15_000)
	defer delete(reply)
	if !got do return err
	if ok, refusal := project.bridge_reply_refusal(reply, inst.bridge_id); !ok do return refusal
	if !confirmed_stop_receipt(reply, operation_id, inst.agent_instance_id, fact.pid, inst.run_count) do return domain.domain_error(.Conflict, "bridge did not confirm the selected process exited")
	return {}
}

confirmed_stop_receipt :: proc(reply, operation_id, instance_id: string, pid: int, run_count := -1) -> bool {
	if !jsonx.extract_bool(reply, "ok", false, true) ||
	   jsonx.extract_string(reply, "command_id", "", true, context.temp_allocator) != operation_id {
		return false
	}
	payload, ok := jsonx.extract_raw_object(reply, "payload", true, context.temp_allocator)
	if !ok || jsonx.extract_string(payload, "status", "", true, context.temp_allocator) != "succeeded" do return false
	result, has_result := jsonx.extract_raw_object(payload, "result", true, context.temp_allocator)
	return has_result &&
		jsonx.extract_string(result, "runtime_status", "", true, context.temp_allocator) == "stopped" &&
		jsonx.extract_string(result, "agent_instance_id", "", true, context.temp_allocator) == instance_id &&
		jsonx.extract_int(result, "expected_process_pid", 0, true) == pid &&
		(run_count < 0 || jsonx.extract_int(result, "expected_run_count", -1, true) == run_count)
}

// A confirmed Start reply was fenced by command, instance and generation,
// and came after start-success. Publish it for the next scheduling decision.
record_confirmed_start_process :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, pid: int) {
	if service == nil || inst.run_count <= 0 || pid <= 0 do return
	key := agent_liveness_key(inst)
	cache := &service.liveness_cache
	index := int(key[0]) % len(cache.rows)
	sync.mutex_lock(&cache.mutex)
	defer sync.mutex_unlock(&cache.mutex)
	if cache.rows[index].key == key && cache.rows[index].from_exit_frame do return
	cache.rows[index] = {key = key, at = time.tick_now(), fact = {
		state = .Alive, reason = .pty_child_alive, pid = pid, ready = true,
	}}
}

// The outer status frame already supplies the launch epoch. A typed exit code
// distinguishes a normal exit with code 0 from an unpopulated report.
Process_Exit_Evidence :: struct {
	pid: i32,
	exit_code: Maybe(i32),
	run_count: int,
}

parse_process_exit_evidence :: proc(frame: string) -> Process_Exit_Evidence {
	raw, present := jsonx.extract_raw_object(frame, "process_exit", true, context.temp_allocator)
	if !present do return {}
	evidence: Process_Exit_Evidence
	if json.unmarshal_string(raw, &evidence, allocator = context.temp_allocator) != nil do return {}
	return evidence
}

// Only call after committing a validated Bridge terminal frame. A late
// in-flight probe cannot overwrite this evidence with an older observation.
record_committed_process_exit :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, evidence: Process_Exit_Evidence) {
	code, has_code := evidence.exit_code.?
	if service == nil || !has_code || evidence.pid <= 0 || evidence.run_count <= 0 || evidence.run_count != inst.run_count do return
	key := agent_liveness_key(inst)
	cache := &service.liveness_cache
	index := int(key[0]) % len(cache.rows)
	sync.mutex_lock(&cache.mutex)
	cache.rows[index] = {key = key, at = time.tick_now(), from_exit_frame = true, fact = {
		state = .Exited, reason = .pty_child_exited, pid = int(evidence.pid), exit_code = code,
	}}
	sync.mutex_unlock(&cache.mutex)
}


// Only call in the caller's UoW after a bound live observation. This heals
// legacy false terminal projections without confusing process existence with
// the independent startup acknowledgement.
apply_observed_alive_projection :: proc(service: ^Agent_Service, observed: domain.Agent_Instance, fact: Agent_Liveness) -> bool {
	if service == nil || fact.state != .Alive || fact.pid <= 0 do return false
	current, present, _ := iface.agent_get_instance(service.agents, observed.agent_instance_id)
	if !present do return false
	defer domain.agent_instance_destroy(&current)
	if current.bridge_id != observed.bridge_id || current.run_count != observed.run_count ||
	   current.launch_epoch != observed.launch_epoch || current.last_applied_seq != observed.last_applied_seq ||
	   current.stopped_by != "" || current.stop_reason != "" || !instance_runtime_is_terminal(current.runtime_status) {
		return false
	}
	projected := current
	projected.runtime_status = "running" if fact.ready else "starting"
	projected.startup_status = "ready" if fact.ready else "starting"
	projected.status_message = "pty_child_alive"
	projected.stopped_at = ""
	projected.last_error_json = ""
	projected.updated_at = platform.clock_now(service.clock)
	projected.last_seen_at = projected.updated_at
	saved, applied, _ := iface.agent_save_instance_guarded(service.agents, projected, observed.run_count, observed.launch_epoch, observed.configuration_revision)
	if applied && saved.runtime_transport != current.runtime_transport do delete(saved.runtime_transport)
	return applied
}

// Persist a scoped terminal observation without inventing a wait status. The
// caller owns the UoW and has already checked the lease that required the probe.
apply_observed_absent_projection :: proc(service: ^Agent_Service, current: domain.Agent_Instance, reason: Agent_Liveness_Reason) -> bool {
	if service == nil || (reason != .missing_from_pty_roster && reason != .orphan_reaped) do return false
	status_reason := "orphan_reaped" if reason == .orphan_reaped else "missing_from_pty_roster"
	next := current
	next.runtime_status = "stopped"
	next.startup_status = "stopped"
	next.activity_status = "idle"
	next.status_message = status_reason
	next.stopped_at = platform.clock_now(service.clock)
	next.updated_at = next.stopped_at
	saved, applied, _ := iface.agent_save_instance_guarded(service.agents, next, current.run_count, current.launch_epoch, current.configuration_revision)
	if applied {
		log_runtime_terminal_transition(saved, current.runtime_status, "apply_observed_absent_projection", status_reason)
		if saved.runtime_transport != current.runtime_transport do delete(saved.runtime_transport)
	}
	return applied
}
