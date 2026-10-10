package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

@(test)
bridge_unix_socket_long_paths_bind_and_stay_distinct :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	save := pty_host_socket_test_snapshot()
	defer pty_host_socket_test_restore(save)

	base := strings.repeat("/very-long-runtime-directory", 8)
	defer delete(base)
	bridge_config.local_endpoint_run_dir = base
	bridge_config.daemon_id = "brg_one"
	pty := pty_host_socket_path()
	defer delete(pty)
	endpoint := bridge_local_endpoint_config_default(base, 49325)
	defer delete(endpoint.unix_socket_path)
	testing.expect(t, len(pty) <= 103 && len(endpoint.unix_socket_path) <= 103)
	testing.expect(t, pty != endpoint.unix_socket_path, "socket roles must remain distinct")
	bridge_config.daemon_id = "brg_two"
	other := pty_host_socket_path()
	defer delete(other)
	testing.expect(t, pty != other, "bridges sharing a directory must remain distinct")

	paths := []string{pty, endpoint.unix_socket_path}
	for path in paths {
		testing.expect(t, bridge_unix_socket_prepare_parent(path))
		fd := posix.socket(.UNIX, .STREAM)
		testing.expect(t, fd >= 0)
		if fd < 0 do continue
		addr: posix.sockaddr_un
		when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
			addr.sun_len = c.uchar(size_of(addr))
		}
		addr.sun_family = .UNIX
		for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
		cpath := strings.clone_to_cstring(path)
		_ = posix.unlink(cpath)
		testing.expect(t, posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK)
		_ = posix.close(fd)
		_ = posix.unlink(cpath)
		delete(cpath)
	}
}

@(test)
bridge_unix_socket_byte_limit_and_shared_hash_vector :: proc(t: ^testing.T) {
	boundary := strings.repeat("a", 103)
	defer delete(boundary)
	short := bridge_unix_socket_bounded_path(boundary)
	defer delete(short)
	testing.expect_value(t, short, boundary)
	unicode := strings.repeat("é", 52)
	defer delete(unicode)
	p := bridge_unix_socket_bounded_path(unicode)
	defer delete(p)
	testing.expect(t, len(p) <= 103 && strings.has_prefix(p, "/tmp/heimdall-"), "limit counts UTF-8 bytes")
	long := strings.repeat("a", 104)
	defer delete(long)
	vector := bridge_unix_socket_bounded_path(long)
	defer delete(vector)
	expected := fmt.aprintf("/tmp/heimdall-%d/ddf64bd8caea7ded.sock", posix.geteuid())
	defer delete(expected)
	testing.expect_value(t, vector, expected)
}

@(test)
bridge_unix_socket_existing_parent_is_ready :: proc(t: ^testing.T) {
	testing.expect(t, bridge_unix_socket_prepare_parent("/tmp/bridge-parent-regression.sock"))
	testing.expect(t, bridge_unix_socket_prepare_parent("/tmp/bridge-parent-regression.sock"))
}
