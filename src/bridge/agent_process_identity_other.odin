#+build !linux
package main

bridge_agent_process_os_read :: proc(pid: i32) -> Bridge_Agent_Process_View {
	if pid <= 0 do return {}
	if !bridge_os_pid_alive(int(pid)) do return {state = .Gone}
	when ODIN_OS != .Windows {
		if bridge_os_pid_is_zombie(int(pid)) do return {state = .Gone}
	}
	stamp, _, known := bridge_os_process_lstart_and_command(int(pid))
	if !known || stamp <= 0 do return {}
	return {state = .Alive, identity = {pid, stamp, 0}}
}

// No equivalent process-group capability. Leave an independently live
// process inconclusive instead of sending a signal to a recycled PID.
bridge_agent_process_kill_orphan :: proc(_: Bridge_Agent_Process_Identity) -> bool { return false }

// No portable environment scan: stay inconclusive.
bridge_agent_process_find_by_instance :: proc(_: string) -> (found: bool, view: Bridge_Agent_Process_View, scanned: bool) { return false, {}, false }
