#+build linux, darwin
package launcher_core

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"

test_current_uid :: proc() -> i64 {
	return i64(posix.geteuid())
}

fake_set_pointer :: proc(root, name, tree: string) -> bool {
	tmp := join_alloc(root, fmt.tprintf("%s.tmp-test", name))
	os.remove(tmp)
	if os.symlink(fmt.tprintf("releases/%s", tree), tmp) != nil do return false
	return replace_file(tmp, join_alloc(root, name))
}

set_pointer :: proc(t: ^testing.T, f: ^Fixture, name, tree: string) {
	testing.expect(t, fake_set_pointer(f.data, name, tree), "set pointer")
}

corrupt_pointer :: proc(t: ^testing.T, f: ^Fixture, name, tree: string, escape: bool) {
	path := join_alloc(f.data, name)
	os.remove(path)
	if escape {
		// An absolute target that does resolve to a valid tree is still invalid.
		testing.expect(t, os.symlink(join_alloc(f.data, "releases", tree), path) == nil)
	} else {
		testing.expect(t, os.write_entire_file(path, fmt.tprintf("releases/%s", tree)) == nil)
	}
}

send_os_stop :: proc(t: ^testing.T, f: ^Fixture, p: os.Process) {
	testing.expect(t, posix.kill(posix.pid_t(p.pid), .SIGTERM) == .OK)
}

@(private = "file") g_fake_stop: i32
@(private = "file") g_fake_parent: posix.pid_t

@(private = "file")
fake_on_term :: proc "c" (sig: posix.Signal) {
	intrinsics.atomic_store(&g_fake_stop, 1)
}

fake_install_stop :: proc(id: string) {
	g_fake_parent = posix.getppid()
	act: posix.sigaction_t
	act.sa_handler = fake_on_term
	posix.sigemptyset(&act.sa_mask)
	posix.sigaction(.SIGTERM, &act, nil)
}

fake_stop_requested :: proc() -> bool {
	return intrinsics.atomic_load(&g_fake_stop) != 0
}

// The launcher died (test failure): do not linger.
fake_parent_gone :: proc() -> bool {
	return posix.getppid() != g_fake_parent
}

fake_write_ready :: proc(fd_text: string, line: string) {
	fd, ok := strconv.parse_int(fd_text, 10)
	if !ok do return
	posix.write(posix.FD(fd), raw_data(line), uint(len(line)))
	posix.close(posix.FD(fd))
}

// Spec §2/§2.1: own process group, READY on fd 3, nothing else inherited.
fake_platform_checks :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	if posix.getpgid(0) != posix.getpid() do strings.write_string(&b, "not-group-leader ")
	if posix.fcntl(3, .GETFD) == -1 do strings.write_string(&b, "no-fd3 ")
	for fd in 4 ..< 256 {
		if posix.fcntl(posix.FD(fd), .GETFD) != -1 do fmt.sbprintf(&b, "leaked-fd-%d ", fd)
	}
	return strings.trim_space(strings.to_string(b))
}
