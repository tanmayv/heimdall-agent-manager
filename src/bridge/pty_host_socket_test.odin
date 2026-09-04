package main

import "core:strings"
import "core:sync"
import "core:testing"

// BR-2a tests: the pty-host daemon socket must be BRIDGE-UNIQUE so two bridges on
// one host (even with the DEFAULT run dir) get distinct sockets => distinct
// daemons => disjoint agent sets. These drive pty_host_socket_path/identity by
// mutating bridge_config (restoring it after) — no daemon needed.

// These tests mutate the global bridge_config, so they must not run concurrently
// with each other (the default test runner is multi-threaded). A shared mutex
// serializes them; each test also snapshots+restores the fields it touches.
pty_host_socket_test_mutex: sync.Mutex

// pty_host_socket_test_save snapshots the config fields these tests mutate.
Pty_Host_Socket_Test_Save :: struct {
	run_dir: string,
	daemon:  string,
	port:    u16,
}

pty_host_socket_test_snapshot :: proc() -> Pty_Host_Socket_Test_Save {
	return {bridge_config.local_endpoint_run_dir, bridge_config.daemon_id, bridge_config.local_endpoint_port}
}
pty_host_socket_test_restore :: proc(s: Pty_Host_Socket_Test_Save) {
	bridge_config.local_endpoint_run_dir = s.run_dir
	bridge_config.daemon_id = s.daemon
	bridge_config.local_endpoint_port = s.port
}

@(test)
pty_host_socket_differs_by_bridge_id_same_run_dir :: proc(t: ^testing.T) {
	sync.mutex_lock(&pty_host_socket_test_mutex)
	defer sync.mutex_unlock(&pty_host_socket_test_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	// Both bridges use the DEFAULT run dir; only the bridge (daemon) id differs.
	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"
	bridge_config.local_endpoint_port = 0

	bridge_config.daemon_id = "brg_aaa"
	a := pty_host_socket_path()
	defer delete(a)

	bridge_config.daemon_id = "brg_bbb"
	b := pty_host_socket_path()
	defer delete(b)

	testing.expect(t, a != b, "different bridge ids must yield different sockets on the same run dir")
	testing.expect(t, strings.contains(a, "brg_aaa"), "socket embeds bridge id a")
	testing.expect(t, strings.contains(b, "brg_bbb"), "socket embeds bridge id b")
	testing.expect(t, strings.has_suffix(a, ".sock"), "socket path ends .sock")
}

@(test)
pty_host_socket_stable_for_same_bridge_id :: proc(t: ^testing.T) {
	sync.mutex_lock(&pty_host_socket_test_mutex)
	defer sync.mutex_unlock(&pty_host_socket_test_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"
	bridge_config.daemon_id = "brg_stable"
	bridge_config.local_endpoint_port = 0

	a := pty_host_socket_path()
	defer delete(a)
	b := pty_host_socket_path()
	defer delete(b)
	testing.expect_value(t, a, b) // deterministic for the same identity
}

@(test)
pty_host_socket_falls_back_to_port_then_default :: proc(t: ^testing.T) {
	sync.mutex_lock(&pty_host_socket_test_mutex)
	defer sync.mutex_unlock(&pty_host_socket_test_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"

	// No real bridge id (default "local-daemon") + a port => port discriminates,
	// so two default-id bridges on different ports still differ.
	bridge_config.daemon_id = "local-daemon"
	bridge_config.local_endpoint_port = 49324
	p1 := pty_host_socket_path()
	defer delete(p1)
	testing.expect(t, strings.contains(p1, "port-49324"), "falls back to port discriminator")

	bridge_config.local_endpoint_port = 49325
	p2 := pty_host_socket_path()
	defer delete(p2)
	testing.expect(t, p1 != p2, "different ports => different sockets under default id")

	// No id and no port => a stable default (single unconfigured bridge).
	bridge_config.daemon_id = ""
	bridge_config.local_endpoint_port = 0
	d := pty_host_socket_path()
	defer delete(d)
	testing.expect(t, strings.contains(d, "pty-host-default.sock"), "last-resort default socket name")
}

@(test)
pty_host_socket_respects_custom_run_dir :: proc(t: ^testing.T) {
	sync.mutex_lock(&pty_host_socket_test_mutex)
	defer sync.mutex_unlock(&pty_host_socket_test_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	bridge_config.local_endpoint_run_dir = "/var/run/heimdall-b1/"
	bridge_config.daemon_id = "brg_x"
	bridge_config.local_endpoint_port = 0
	p := pty_host_socket_path()
	defer delete(p)
	testing.expect_value(t, p, "/var/run/heimdall-b1/pty-host-brg_x.sock")
}
