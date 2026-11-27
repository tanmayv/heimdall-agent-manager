package main

import "core:encoding/json"
import ws "odin_test:lib/ws"

Bridge_Instance_Probe_Result :: struct {
	agent_instance_id: string,
	state: string,
	pid: i32,
	exit_code: Maybe(i32),
	launch_epoch: string,
	run_count: int,
}

// A failed request or a missing tombstone is not proof that an earlier
// process exited. In particular, never start a daemon just to probe one.
bridge_instance_probe :: proc(id: string) -> Bridge_Instance_Probe_Result {
	roster := bridge_pty_liveness_roster()
	defer pty_host_reply_delete(roster)
	return bridge_instance_probe_from_roster(id, roster)
}

bridge_instance_probe_from_roster :: proc(id: string, roster: Pty_Host_Reply) -> Bridge_Instance_Probe_Result {
	result := Bridge_Instance_Probe_Result{agent_instance_id = id, state = "unknown"}
	if id == "" || roster.kind != .Agent_List do return result
	for child in roster.agents {
		if child.instance_id != id || child.pid <= 0 do continue
		result.pid = child.pid
		if child.alive {
			result.state = "alive"
		} else if child.has_exit_code {
			result.state = "exited"
			result.exit_code = child.exit_code
		}
		return result
	}
	result.state = "absent"
	return result
}

bridge_hub_handle_instance_probe :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	defer delete(command_id)
	id := extract_json_string(text, "agent_instance_id", "")
	defer delete(id)
	if command_id == "" || id == "" do return
	lifecycle := bridge_agent_lifecycle_enter(id)
	probe := bridge_instance_probe(id)
	probe.launch_epoch = bridge_agent_instance_launch_epoch(id)
	probe.run_count = bridge_agent_instance_run_count(id)
	bridge_agent_lifecycle_leave(lifecycle)
	defer delete(probe.launch_epoch)
	response := struct {
		type, command_id: string,
		protocol_version: int,
		ok: bool,
		payload: struct {status: string, result: Bridge_Instance_Probe_Result},
	}{type = "command_result", command_id = command_id, protocol_version = 1, ok = true}
	response.payload.status = "succeeded"
	response.payload.result = probe
	bytes, err := json.marshal(response)
	if err != nil do return
	defer delete(bytes)
	_ = bridge_hub_send(conn, string(bytes))
}
