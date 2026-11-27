package main

import "core:encoding/json"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

Bridge_Instance_Probe_Result :: struct {
	agent_instance_id: string,
	state: string,
	pid: i32,
	exit_code: Maybe(i32),
	launch_epoch: string,
	source: string,
	run_count: int,
	ready: bool,
}

// Unavailable inventory is inconclusive. A complete snapshot with no row
// is distinct from an unavailable daemon and never fabricates an exit code.
bridge_instance_probe :: proc(id: string) -> Bridge_Instance_Probe_Result {
	roster := bridge_pty_liveness_roster()
	defer pty_host_reply_delete(roster)
	return bridge_instance_probe_from_roster(id, roster)
}

bridge_instance_probe_from_roster :: proc(id: string, roster: Pty_Host_Reply) -> Bridge_Instance_Probe_Result {
	result := Bridge_Instance_Probe_Result{agent_instance_id = id, state = "unknown"}
	if id == "" || roster.kind != .Agent_List do return result
	for child in roster.agents {
		if child.instance_id != id do continue
		if child.pid <= 0 do return result
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

// The roster is keyed by instance id, not launch generation. A retained
// tombstone can belong to the previous child even after its replacement was
// assigned credentials. Only bind an exit to the PID confirmed at spawn or
// adoption for those credentials. Missing binding is deliberately unknown.
bridge_instance_probe_bind :: proc(probe: ^Bridge_Instance_Probe_Result, pid: i32, run_count: int, launch_epoch: string) {
	if probe.state == "absent" {
		if run_count <= 0 {
			probe.state = "unknown"
			return
		}
		probe.run_count = run_count
		probe.launch_epoch = launch_epoch
		return
	}
	if probe.state != "exited" && probe.state != "alive" do return
	if pid <= 0 || probe.pid != pid || run_count <= 0 {
		probe.state = "unknown"
		probe.exit_code = nil
		return
	}
	probe.run_count = run_count
	probe.launch_epoch = launch_epoch
}

// Qualify only a complete roster's absence. A launch check cannot invent a
// wait status or reap an unverified process. The spawn path repeats its own
// absence check under the same lifecycle lock before replacing the child.
bridge_instance_probe_qualify_absence :: proc(
	probe: ^Bridge_Instance_Probe_Result, run: int, for_launch: bool,
	observe := bridge_agent_process_after_roster_loss,
	confirm_launch_absent := bridge_agent_launch_absent_confirmed,
) {
	if probe.state != "absent" do return
	probe.state = "unknown"
	if run <= 0 do return
	observation, previous_pid, reaped := observe(probe.agent_instance_id, run, true)
	if observation == .Gone {
		probe.state = "absent"
		probe.source = "os_identity_gone"
		if reaped {
			probe.state = "exited"
			probe.pid = previous_pid
			probe.source = "orphan_reaped"
		}
	} else if observation == .Unknown && previous_pid == 0 && for_launch &&
	          confirm_launch_absent(probe.agent_instance_id, run, false) {
		probe.state = "absent"
		probe.source = contracts.INSTANCE_PROBE_LAUNCH_ABSENCE
	}
}

bridge_instance_probe_for_hub :: proc(id: string, for_launch := false) -> Bridge_Instance_Probe_Result {
	lifecycle := bridge_agent_lifecycle_enter(id)
	defer bridge_agent_lifecycle_leave(lifecycle)
	probe := bridge_instance_probe(id)
	if probe.state == "absent" {
		run := bridge_agent_instance_run_count(id)
		bridge_instance_probe_qualify_absence(&probe, run, for_launch)
		if probe.state != "unknown" {
			probe.run_count = run
			probe.launch_epoch = bridge_agent_instance_launch_epoch(id)
			if probe.source == "orphan_reaped" do bridge_runtime_set_pty_process_alive(id, false)
		}
	} else if probe.state == "exited" || probe.state == "alive" {
		epoch := bridge_agent_instance_launch_epoch(id)
		defer delete(epoch)
		run_count := bridge_agent_instance_run_count(id)
		pid: i32
		sync.mutex_lock(&bridge_runtime_mutex)
		for &inst in bridge_runtime_instances {
			if inst.agent_instance_id == id && inst.startup.rec.run_count == run_count {
				pid = inst.startup.pty_pid
				probe.ready = inst.start_success_seen && probe.state == "alive" && probe.pid == pid
				break
			}
		}
		sync.mutex_unlock(&bridge_runtime_mutex)
		if probe.state == "alive" && pid != probe.pid {
			// Bridge restart may have discarded the launch record. Verify the
			// local token against the immutable child spec without starting or
			// nudging the daemon to check its identity.
			socket := bridge_pty_liveness_socket()
			defer delete(socket)
			rec := bridge_agent_instance_token_hash(id, run_count)
			defer delete(rec)
			if rec != "" {
				if observed_pid, verified := bridge_pty_host_startup_launch(socket, id, rec); verified && observed_pid == probe.pid {
					pid = observed_pid
					bridge_agent_remember_process(id, rec, pid)
				}
			}
		}
		bridge_instance_probe_bind(&probe, pid, run_count, epoch)
		probe.launch_epoch = strings.clone(probe.launch_epoch)
	}
	return probe
}

bridge_hub_handle_instance_probe :: proc(conn: ^ws.Connection, text: string) {
	command: contracts.Instance_Probe_Command
	if json.unmarshal_string(text, &command, allocator = context.temp_allocator) != nil ||
	   command.type != contracts.INSTANCE_PROBE_COMMAND || command.command_id == "" || command.agent_instance_id == "" {
		return
	}
	probe := bridge_instance_probe_for_hub(command.agent_instance_id, command.for_launch)
	defer delete(probe.launch_epoch)
	response := struct {
		type, command_id: string,
		protocol_version: int,
		ok: bool,
		payload: struct {status: string, result: Bridge_Instance_Probe_Result},
	}{type = "command_result", command_id = command.command_id, protocol_version = 1, ok = true}
	response.payload.status = "succeeded"
	response.payload.result = probe
	bytes, err := json.marshal(response)
	if err != nil do return
	defer delete(bytes)
	_ = bridge_hub_send(conn, string(bytes))
}

@(private = "file")
bridge_agent_instance_token_hash :: proc(id: string, run_count: int) -> string {
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for i := len(bridge_local_token_records) - 1; i >= 0; i -= 1 {
		rec := bridge_local_token_records[i]
		if rec.agent_instance_id == id && rec.role == .Agent && rec.invalidated_at_unix_ms == 0 && rec.run_count == run_count {
			return strings.clone(rec.token_hash)
		}
	}
	return ""
}
