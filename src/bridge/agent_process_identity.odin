package main


// The roster proves ownership. OS identity is a second check only when the
// complete roster no longer includes a previously verified daemon child.
Bridge_Agent_Process_Identity :: struct {
	pid: i32,
	start, boot: i64,
}
Bridge_Agent_Process_State :: enum {Unknown, Alive, Gone}
Bridge_Agent_Process_View :: struct {
	state: Bridge_Agent_Process_State,
	identity: Bridge_Agent_Process_Identity,
	group: i32,
}

bridge_agent_process_match :: proc(expected: Bridge_Agent_Process_Identity, view: Bridge_Agent_Process_View) -> Bridge_Agent_Process_State {
	if expected.pid <= 0 || expected.start <= 0 do return .Unknown
	if view.state == .Alive && expected != view.identity do return .Gone
	return view.state
}

bridge_agent_process_after_roster_loss :: proc(id: string, run_count: int, reap: bool) -> (state: Bridge_Agent_Process_State, pid: i32, orphan_reaped: bool) {
	identity := bridge_agent_previous_process(id, run_count)
	if identity.pid <= 0 {
		// No recorded identity (e.g. the instance was stopped cleanly or ran
		// under an earlier Bridge build). Look for any process still carrying
		// this instance id; none means nothing to verify or stop.
		found, found_view, scanned := bridge_agent_process_find_by_instance(id)
		if !scanned do return .Unknown, 0, false
		if !found do return .Gone, 0, false
		identity = found_view.identity
		if !reap do return .Alive, identity.pid, false
		if !bridge_agent_process_kill_orphan(identity) do return .Unknown, identity.pid, false
		return .Gone, identity.pid, true
	}
	view := bridge_agent_process_os_read(identity.pid)
	state = bridge_agent_process_match(identity, view)
	if state != .Alive || !reap do return state, identity.pid, false
	if !bridge_agent_process_kill_orphan(identity) do return .Unknown, identity.pid, false
	return .Gone, identity.pid, true
}

// Called only after a complete owning-daemon roster has omitted this instance.
// A new logical instance has no existing process to stop.
bridge_agent_roster_loss_confirmed :: proc(id: string, run: int, reap := false) -> bool {
	if run <= 0 do return true
	state, _, _ := bridge_agent_process_after_roster_loss(id, run, reap)
	return state == .Gone
}
