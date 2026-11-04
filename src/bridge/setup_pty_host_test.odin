package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

// No daemon answers: nothing is retired, kept or reported, and Shutdown at a dead
// socket is already-stopped (ok), so an update of a profile with no PTY host is a no-op.
@(test)
test_setup_retire_idle_pty_hosts_without_a_daemon_is_a_noop :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/ham-setup-pty-%d", os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)
	host := bridgesvc.Host{os = .Linux, home = root}
	l := bridgesvc.layout_for(host, "heimdall-bridge-test")
	testing.expect(t, os.make_directory_all(bridgesvc.pjoin(l.data_dir, "run")) == nil)
	sock := bridgesvc.pjoin(l.data_dir, "run", "pty-host-brg_x.sock")
	testing.expect(t, os.write_entire_file(sock, transmute([]byte)string("")) == nil) // stale entry, nobody serving
	testing.expect_value(t, bridge_setup_retire_idle_pty_hosts(host, l), "")
	ok, detail := bridge_pty_host_shutdown_at(sock, 0)
	testing.expect(t, ok, detail)
}

// CI (run 41854017926): a shell that ended stays in the daemon's list with
// alive=false; counting it kept an idle daemon on the old binary.
@(test)
test_setup_counts_only_live_pty_agents :: proc(t: ^testing.T) {
	agents := []Pty_Host_Agent_Info{{instance_id = "sh_done", alive = false}, {instance_id = "sh_live", alive = true}, {instance_id = "sh_gone", alive = false, has_exit_code = true}}
	testing.expect_value(t, bridge_pty_host_live_agents(agents), 1)
	testing.expect_value(t, bridge_pty_host_live_agents(agents[:1]), 0)
	testing.expect_value(t, bridge_pty_host_live_agents(nil), 0)
}

// Fake daemons, keyed by socket name: "idle" lists only exited sessions, "busy"
// lists a live one, "garbled" answers ping but its list fails (e.g. an old
// daemon's reply the new decoder cannot read), "dead" answers nothing, "stuck" is
// idle but never stops.
@(private = "file") retire_test_lock: sync.Mutex
@(private = "file") retire_test_shutdowns: [dynamic]string

@(private = "file")
retire_fake_list :: proc(socket: string) -> (Pty_Host_Reply, bool) {
	switch {
	case strings.has_suffix(socket, "idle"), strings.has_suffix(socket, "stuck"):
		agents := make([]Pty_Host_Agent_Info, 1)
		agents[0] = {instance_id = strings.clone("sh_done"), alive = false}
		return {kind = .Agent_List, agents = agents}, true
	case strings.has_suffix(socket, "busy"):
		agents := make([]Pty_Host_Agent_Info, 2)
		agents[0] = {instance_id = strings.clone("sh_done"), alive = false}
		agents[1] = {instance_id = strings.clone("sh_live"), alive = true}
		return {kind = .Agent_List, agents = agents}, true
	}
	return {}, false
}

@(private = "file")
retire_fake_ping :: proc(socket: string) -> bool {
	return !strings.has_suffix(socket, "dead")
}

@(private = "file")
retire_fake_shutdown :: proc(socket: string, wait: time.Duration) -> (bool, string) {
	sync.mutex_lock(&retire_test_lock)
	defer sync.mutex_unlock(&retire_test_lock)
	append(&retire_test_shutdowns, strings.clone(socket))
	return !strings.has_suffix(socket, "stuck"), "still running"
}

@(test)
test_setup_retires_only_a_listed_idle_pty_host :: proc(t: ^testing.T) {
	ops := Bridge_Pty_Retire_Ops{list = retire_fake_list, ping = retire_fake_ping, shutdown = retire_fake_shutdown}
	defer {
		sync.mutex_lock(&retire_test_lock)
		for s in retire_test_shutdowns do delete(s)
		delete(retire_test_shutdowns)
		retire_test_shutdowns = nil
		sync.mutex_unlock(&retire_test_lock)
	}
	shutdowns :: proc() -> []string {
		sync.mutex_lock(&retire_test_lock)
		defer sync.mutex_unlock(&retire_test_lock)
		return retire_test_shutdowns[:]
	}

	// list ok, 0 alive -> shut down
	r := bridge_setup_retire_idle_with({"/run/a-idle"}, ops)
	testing.expect_value(t, r, Bridge_Pty_Retire_Result{retired = 1})
	testing.expect_value(t, len(shutdowns()), 1)

	// list ok, >=1 alive -> kept, no shutdown
	r = bridge_setup_retire_idle_with({"/run/b-busy"}, ops)
	testing.expect_value(t, r, Bridge_Pty_Retire_Result{kept = 1})
	testing.expect_value(t, len(shutdowns()), 1)

	// list fails, ping ok -> kept as unknown (fail safe), no shutdown
	r = bridge_setup_retire_idle_with({"/run/c-garbled"}, ops)
	testing.expect_value(t, r, Bridge_Pty_Retire_Result{unknown = 1})
	testing.expect_value(t, len(shutdowns()), 1)

	// nothing answers -> skipped
	r = bridge_setup_retire_idle_with({"/run/d-dead"}, ops)
	testing.expect_value(t, r, Bridge_Pty_Retire_Result{})
	testing.expect_value(t, len(shutdowns()), 1)

	// idle but does not stop -> failed (reported, never forced)
	r = bridge_setup_retire_idle_with({"/run/e-stuck"}, ops)
	testing.expect_value(t, r, Bridge_Pty_Retire_Result{failed = 1})

	// mixed, and the summary names every outcome
	r = bridge_setup_retire_idle_with({"/run/a-idle", "/run/b-busy", "/run/c-garbled", "/run/d-dead"}, ops)
	testing.expect_value(t, r, Bridge_Pty_Retire_Result{retired = 1, kept = 1, unknown = 1})
	got := shutdowns()
	testing.expect_value(t, got[len(got) - 1], "/run/a-idle")
	sum := bridge_setup_retire_summary(r)
	testing.expect(t, strings.contains(sum, "replaced 1 idle PTY host(s)"), sum)
	testing.expect(t, strings.contains(sum, "kept 1 PTY host(s) with live agents"), sum)
	testing.expect(t, strings.contains(sum, "kept 1 PTY host(s) whose agent list could not be read"), sum)
}
