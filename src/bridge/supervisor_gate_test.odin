package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import procs "odin_test:supervisor/procs"

// Supervisor agent gate, runtime half (supervisor_gate.odin; spec §12.2).

@(private = "file")
gate_test_lock :: proc() {
	sync.mutex_lock(&bridge_test_config_mutex)
	// auto_update tests share the admission state (reserved_until, launches).
	sync.mutex_lock(&auto_test_mutex)
}

@(private = "file")
gate_test_unlock :: proc() {
	bridge_gate_admission_open()
	sync.mutex_unlock(&auto_test_mutex)
	sync.mutex_unlock(&bridge_test_config_mutex)
}

@(private = "file")
gate_test_roster :: proc(allocator := context.allocator) -> ([]Bridge_Gate_Session, bool) {
	out := make([]Bridge_Gate_Session, 3, allocator)
	out[0] = {instance_id = "inst_a", pid = os.get_pid()}
	out[1] = {instance_id = "inst_b", pid = os.get_pid()}
	out[2] = {instance_id = "sh_1", pid = os.get_pid(), helper = true}
	return out, true
}

@(private = "file")
gate_test_roster_down :: proc(allocator := context.allocator) -> ([]Bridge_Gate_Session, bool) {
	return nil, false
}

gate_test_signalled: [dynamic]string

@(private = "file")
gate_test_signal :: proc(instance_id: string) -> bool {
	append(&gate_test_signalled, strings.clone(instance_id, context.temp_allocator))
	return true
}

@(private = "file")
gate_test_parse :: proc(t: ^testing.T, resp: string) -> json.Object {
	v, err := json.parse(transmute([]byte)resp, json.Specification.JSON, true, context.temp_allocator)
	testing.expectf(t, err == nil, "response is JSON: %s", resp)
	o, _ := v.(json.Object)
	return o
}

// Acceptance: a launch is refused while admission is closed, and admitted again once open.
@(test)
test_gate_admission_closed_refuses_launch :: proc(t: ^testing.T) {
	gate_test_lock()
	defer gate_test_unlock()
	testing.expect_value(t, bridge_gate_admission_close(), 0)
	testing.expect(t, bridge_gate_admission_is_closed())
	testing.expect(t, !bridge_auto_update_launch_enter(), "closed admission refuses the admission point")
	launched, detail, err := bridge_runtime_launch_agent("gate-test", `{"agent_instance_id":"gate-test"}`)
	testing.expect(t, !launched, "launch refused while admission is closed")
	testing.expect(t, strings.contains(detail, "applying an update"), detail)
	// Retriable: the hub re-wakes the agent after the update (report §6.6).
	testing.expect_value(t, err.class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, err.retry_after_ms, i64(30_000))
	bridge_gate_admission_open()
	testing.expect(t, bridge_auto_update_launch_enter(), "open admission admits again")
	bridge_auto_update_launch_leave()
}

// A launch admitted before the close is counted; none can slip in after it.
@(test)
test_gate_close_counts_launch_in_flight :: proc(t: ^testing.T) {
	gate_test_lock()
	defer gate_test_unlock()
	testing.expect(t, bridge_auto_update_launch_enter())
	testing.expect_value(t, bridge_gate_admission_close(), 1)
	c := bridge_gate_count(gate_test_roster)
	testing.expect(t, c.counted && c.closed)
	testing.expect_value(t, c.launches, 1)
	bridge_auto_update_launch_leave()
	c = bridge_gate_count(gate_test_roster)
	testing.expect_value(t, c.launches, 0)
}

@(test)
test_gate_count_splits_agents_and_helpers :: proc(t: ^testing.T) {
	gate_test_lock()
	defer gate_test_unlock()
	c := bridge_gate_count(gate_test_roster)
	testing.expect(t, c.counted && !c.closed)
	testing.expect_value(t, c.pty_sessions, 2)
	testing.expect_value(t, c.helpers, 1)
	testing.expect_value(t, c.launches, 0)
	// A PTY host that does not answer: not counted (the engine treats it as busy).
	c = bridge_gate_count(gate_test_roster_down)
	testing.expect(t, !c.counted, "unavailable roster is not counted")
	o := gate_test_parse(t, bridge_gate_count_json(c))
	testing.expect(t, o["counted"].(json.Boolean) == false)
}

// sessions.end captures every session's (pid, start_time) before signalling each one.
@(test)
test_gate_end_sessions_returns_identities :: proc(t: ^testing.T) {
	gate_test_lock()
	defer gate_test_unlock()
	gate_test_signalled = make([dynamic]string, context.temp_allocator)
	targets, signalled, ok := bridge_gate_end_sessions(gate_test_roster, gate_test_signal, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, signalled, 3)
	testing.expect_value(t, len(gate_test_signalled), 3)
	testing.expect_value(t, len(targets), 3)
	me, me_ok := procs.self()
	testing.expect(t, me_ok)
	for tg in targets {
		testing.expect(t, tg.group, "each PTY session leads its own group (setsid)")
		testing.expect_value(t, tg.id, me)
	}
	_, _, ok = bridge_gate_end_sessions(gate_test_roster_down, gate_test_signal, context.temp_allocator)
	testing.expect(t, !ok, "unavailable roster: nothing to report")
}

// The control methods need the control token; an agent token or no token is refused, and
// the JSONL router sends supervisor.* there before agent-token auth.
@(test)
test_gate_control_endpoint_auth_and_methods :: proc(t: ^testing.T) {
	gate_test_lock()
	defer gate_test_unlock()
	dir := fmt.tprintf("%s/gate-control-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	testing.expect(t, os.make_directory(dir) == nil)
	defer os.remove_all(dir)
	testing.expect(t, bridge_supervisor_control_publish(dir, "unix:/tmp/x.sock"))
	path := bridge_supervisor_control_path(dir)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	f := gate_test_parse(t, string(data))
	token := string(f["token"].(json.String))
	testing.expect_value(t, len(token), 2 * SUPERVISOR_CONTROL_TOKEN_BYTES)
	testing.expect_value(t, string(f["endpoint"].(json.String)), "unix:/tmp/x.sock")
	when ODIN_OS != .Windows {
		fi, serr := os.stat(path, context.temp_allocator)
		testing.expect(t, serr == nil && transmute(u32)fi.mode & 0o077 == 0, "control file is owner-only")
	}
	// Republish keeps the token (one per process).
	testing.expect(t, bridge_supervisor_control_publish(dir, "unix:/tmp/x.sock"))
	testing.expect_value(t, bridge_supervisor_control_token, token)

	bad := bridge_supervisor_control_handle("r1", "supervisor.admission.close", "nope")
	defer delete(bad)
	testing.expect(t, strings.contains(bad, `"unauthenticated"`), bad)
	testing.expect(t, !bridge_gate_admission_is_closed(), "a bad token changes nothing")

	line := fmt.tprintf(`{{"v":1,"id":"r2","token":"%s","method":"supervisor.admission.close","params":{{}}}}`, token)
	resp := bridge_local_endpoint_handle_jsonl_line(line)
	defer delete(resp)
	o := gate_test_parse(t, resp)
	testing.expect(t, o["ok"].(json.Boolean) == true, resp)
	testing.expect(t, bridge_gate_admission_is_closed(), "closed over the endpoint")

	cnt := bridge_supervisor_control_handle("r3", "supervisor.gate.count", token, gate_test_roster)
	defer delete(cnt)
	d := gate_test_parse(t, cnt)["data"].(json.Object)
	testing.expect_value(t, string(d["admission"].(json.String)), "closed")
	testing.expect_value(t, i64(d["pty_sessions"].(json.Integer)), i64(2))
	testing.expect_value(t, i64(d["helpers"].(json.Integer)), i64(1))

	gate_test_signalled = make([dynamic]string, context.temp_allocator)
	end := bridge_supervisor_control_handle("r4", "supervisor.sessions.end", token, gate_test_roster, gate_test_signal)
	defer delete(end)
	e := gate_test_parse(t, end)["data"].(json.Object)
	testing.expect_value(t, i64(e["signalled"].(json.Integer)), i64(3))
	testing.expect_value(t, len(e["targets"].(json.Array)), 3)

	line = fmt.tprintf(`{{"v":1,"id":"r5","token":"%s","method":"supervisor.admission.open","params":{{}}}}`, token)
	resp2 := bridge_local_endpoint_handle_jsonl_line(line)
	defer delete(resp2)
	testing.expect(t, !bridge_gate_admission_is_closed(), "reopened over the endpoint")

	unknown := bridge_supervisor_control_handle("r6", "supervisor.nope", token)
	defer delete(unknown)
	testing.expect(t, strings.contains(unknown, `"forbidden"`), unknown)
}
