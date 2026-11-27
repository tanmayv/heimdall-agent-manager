package agent

import "core:encoding/json"
import "core:crypto/hash"
import "core:fmt"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

Instance_Probe_State :: enum {Unknown, Absent, Alive, Exited}

Instance_Probe :: struct {
	state: Instance_Probe_State,
	pid: int,
	exit_code: i32,
}

Agent_Liveness_State :: enum {Unknown, Alive, Exited}
Agent_Liveness_Reason :: enum {bridge_unavailable, invalid_probe, missing_from_pty_roster, pty_child_alive, pty_child_exited}
Agent_Liveness :: struct {
	state: Agent_Liveness_State,
	reason: Agent_Liveness_Reason,
	pid: int,
	exit_code: i32,
}

Agent_Liveness_Cache :: struct {
	mutex: sync.Mutex,
	rows: [64]struct {
		key: [32]byte,
		at: time.Tick,
		fact: Agent_Liveness,
	},
}

AGENT_LIVENESS_CACHE_TTL :: 2 * time.Second

// The cache is bounded and fenced by the durable generation and owning bridge.
// runtime_status is deliberately not an input. A miss authorizes no state
// mutation and may perform one bounded RPC, so call outside the UoW and reader.
agent_liveness :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> Agent_Liveness {
	if service == nil do return {}
	identity := fmt.tprintf("%q/%q/%q/%d", inst.bridge_id, inst.agent_instance_id, inst.launch_epoch, inst.run_count)
	key: [32]byte
	hash.hash_string_to_buffer(.SHA256, identity, key[:])
	index := int(key[0]) % len(service.liveness_cache.rows)
	cache := &service.liveness_cache
	sync.mutex_lock(&cache.mutex)
	slot := cache.rows[index]
	sync.mutex_unlock(&cache.mutex)
	if slot.key == key && time.tick_since(slot.at) < AGENT_LIVENESS_CACHE_TTL do return slot.fact

	at := time.tick_now()
	observation, reason := probe_instance(service, inst)
	fact := Agent_Liveness{reason = reason, pid = observation.pid, exit_code = observation.exit_code}
	#partial switch observation.state {
	case .Alive: fact.state = .Alive
	case .Exited: fact.state = .Exited
	}
	if time.tick_since(at) < AGENT_LIVENESS_CACHE_TTL {
		sync.mutex_lock(&cache.mutex)
		if cache.rows[index].at._nsec <= at._nsec do cache.rows[index] = {key = key, at = at, fact = fact}
		sync.mutex_unlock(&cache.mutex)
	}
	return fact
}

// Run outside a Hub UoW and off the Bridge websocket read loop. Otherwise the
// caller can prevent its own response from being read.
@(private = "file")
probe_instance :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> (Instance_Probe, Agent_Liveness_Reason) {
	if service == nil || service.ids == nil || inst.bridge_id == "" || inst.agent_instance_id == "" do return {}, .bridge_unavailable
	id := platform.generate_id(service.ids, "cmd_instance_probe_")
	defer delete(id)
	command, err := json.marshal(struct {type, command_id, agent_instance_id: string}{"instance.probe", id, inst.agent_instance_id})
	if err != nil do return {}, .invalid_probe
	defer delete(command)
	reply, got, _ := project.bridge_command_send_runtime_wait(service.bridge_command_sink, {bridge_id = inst.bridge_id, command_id = id, body_json = string(command)}, 3000)
	defer delete(reply)
	if !got do return {}, .bridge_unavailable
	observation := parse_instance_probe(reply, id, inst.agent_instance_id)
	switch observation.state {
	case .Unknown: return observation, .invalid_probe
	case .Absent: return observation, .missing_from_pty_roster
	case .Alive: return observation, .pty_child_alive
	case .Exited: return observation, .pty_child_exited
	}
	return {}, .invalid_probe
}

parse_instance_probe :: proc(reply, command_id, instance_id: string) -> Instance_Probe {
	if !jsonx.extract_bool(reply, "ok", false, true) ||
	   jsonx.extract_string(reply, "command_id", "", true, context.temp_allocator) != command_id {
		return {}
	}
	payload, has_payload := jsonx.extract_raw_object(reply, "payload", true, context.temp_allocator)
	if !has_payload do return {}
	result, has_result := jsonx.extract_raw_object(payload, "result", true, context.temp_allocator)
	if !has_result do return {}
	report: struct {agent_instance_id, state: string, pid: i32, exit_code: Maybe(i32)}
	if json.unmarshal_string(result, &report, allocator = context.temp_allocator) != nil || report.agent_instance_id != instance_id do return {}
	switch report.state {
	case "absent":
		if report.pid == 0 do return {state = .Absent}
	case "alive":
		if report.pid > 0 do return {state = .Alive, pid = int(report.pid)}
	case "exited":
		if code, has_code := report.exit_code.?; report.pid > 0 && has_code do return {state = .Exited, pid = int(report.pid), exit_code = code}
	}
	return {}
}
