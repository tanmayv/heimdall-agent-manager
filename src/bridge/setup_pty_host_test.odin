package main

import "core:fmt"
import "core:os"
import "core:testing"
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
	n, live := bridge_pty_host_agent_count(sock)
	testing.expect(t, !live && n == 0)
	ok, detail := bridge_pty_host_shutdown_at(sock, 0)
	testing.expect(t, ok, detail)
}
