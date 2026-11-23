#+build linux, darwin
// POSIX side of the launcher (spec §2, §2.1, §4.1, §7.3, §17): symlink pointers, the
// supervisor in its own process group with the READY pipe on fd 3 and no other
// inherited descriptor, SIGTERM forwarding with a 20 s grace.
package launcher_core

import "base:intrinsics"
import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

READY_FD :: 3

Child :: struct {
	pid:      posix.pid_t,
	ready_r:  posix.FD,
	ready:    bool,
	exited:   bool,
	code:     int,
	signal:   int,
	buf:      Ready_Buffer,
}

@(private = "file")
g_stop_signal: i32 // set from the signal handler

@(private = "file")
on_stop_signal :: proc "c" (sig: posix.Signal) {
	intrinsics.atomic_store(&g_stop_signal, 1)
}

platform_init :: proc(l: ^Launcher) -> bool {
	act: posix.sigaction_t
	act.sa_handler = on_stop_signal
	posix.sigemptyset(&act.sa_mask)
	if posix.sigaction(.SIGTERM, &act, nil) != .OK do return false
	if posix.sigaction(.SIGINT, &act, nil) != .OK do return false
	ign: posix.sigaction_t
	ign.sa_handler = auto_cast posix.SIG_IGN
	posix.sigemptyset(&ign.sa_mask)
	posix.sigaction(.SIGPIPE, &ign, nil)
	return true
}

platform_shutdown :: proc(l: ^Launcher) {}

platform_stop_signaled :: proc(l: ^Launcher) -> bool {
	return intrinsics.atomic_load(&g_stop_signal) != 0
}

platform_note_stop :: proc(l: ^Launcher) {
	intrinsics.atomic_store(&g_stop_signal, 1)
}

owner_matches :: proc(owner: Owner) -> bool {
	return owner.uid >= 0 && i64(posix.geteuid()) == owner.uid
}

read_file_shared :: proc(path: string, allocator := context.allocator) -> ([]byte, os.Error) {
	return os.read_entire_file(path, allocator)
}

// read_pointer reads the current/previous symlink (spec §4.1). Anything that is not a
// symlink to "releases/<name>" is invalid.
read_pointer :: proc(instance_root, name: string) -> (tree: string, ok: bool) {
	path := join(instance_root, name)
	info, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	if err != nil || info.type != .Symlink do return
	target, rerr := os.read_link(path, context.temp_allocator)
	if rerr != nil do return
	return symlink_target_tree(target)
}

// replace_file atomically replaces dst with src (rename(2)) and fsyncs the directory.
replace_file :: proc(src, dst: string) -> bool {
	if os.rename(src, dst) != nil do return false
	dir, _ := os.split_path(dst)
	if f, err := os.open(dir); err == nil {
		os.sync(f)
		os.close(f)
	}
	return true
}

when ODIN_OS == .Linux {
	foreign import libc "system:c"
	@(default_calling_convention = "c")
	foreign libc {
		prctl :: proc(option: c.int, #c_vararg args: ..any) -> c.int ---
	}
	PR_SET_PDEATHSIG :: 1
}

@(private = "file")
set_cloexec :: proc(fd: posix.FD) -> bool {
	return posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC)) != -1
}

spawn_supervisor :: proc(l: ^Launcher, tree: string, mode: Launch_Mode) -> (child: Child, err: string) {
	args := supervisor_args(l, tree, mode, "3")
	exe := args[0]
	if !os.is_file(exe) do return child, "supervisor executable missing"
	c_exe := strings.clone_to_cstring(exe, context.temp_allocator)
	c_argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args do c_argv[i] = strings.clone_to_cstring(a, context.temp_allocator)

	ready: [2]posix.FD
	if posix.pipe(&ready) != .OK do return child, "pipe failed"
	report: [2]posix.FD
	if posix.pipe(&report) != .OK {
		posix.close(ready[0]); posix.close(ready[1])
		return child, "pipe failed"
	}
	for fd in ([4]posix.FD{ready[0], ready[1], report[0], report[1]}) do set_cloexec(fd)

	limit: posix.rlimit
	max_fd: c.int = 1024
	if posix.getrlimit(.NOFILE, &limit) == .OK && limit.rlim_cur > 0 {
		max_fd = c.int(min(u64(limit.rlim_cur), 65536))
	}
	when ODIN_OS == .Linux do parent := posix.getpid()

	pid := posix.fork()
	switch pid {
	case -1:
		for fd in ([4]posix.FD{ready[0], ready[1], report[0], report[1]}) do posix.close(fd)
		return child, "fork failed"
	case 0:
		// Child: async-signal-safe calls only.
		fail :: proc "c" (fd: posix.FD) -> ! {
			errno := u8(posix.errno())
			posix.write(fd, &errno, 1)
			posix._exit(127)
		}
		if posix.setpgid(0, 0) != .OK do fail(report[1])
		when ODIN_OS == .Linux {
			if prctl(PR_SET_PDEATHSIG, c.ulong(posix.Signal.SIGKILL)) != 0 do fail(report[1])
			if posix.getppid() != parent do posix._exit(127)
		}
		dfl: posix.sigaction_t
		dfl.sa_handler = auto_cast posix.SIG_DFL
		posix.sigemptyset(&dfl.sa_mask)
		posix.sigaction(.SIGPIPE, &dfl, nil)
		posix.sigaction(.SIGTERM, &dfl, nil)
		posix.sigaction(.SIGINT, &dfl, nil)
		// Move the report pipe above the READY slot, then put READY on fd 3.
		rep := report[1]
		if rep == READY_FD {
			rep = posix.FD(posix.fcntl(report[1], .DUPFD_CLOEXEC, c.int(READY_FD + 1)))
			if rep == -1 do posix._exit(127)
		}
		if ready[1] == READY_FD {
			if posix.fcntl(READY_FD, .SETFD, c.int(0)) == -1 do fail(rep)
		} else if posix.dup2(ready[1], READY_FD) == -1 {
			fail(rep)
		}
		// Every other descriptor is CLOEXEC; close explicitly as well so a descriptor
		// inherited by the launcher without CLOEXEC cannot leak into the supervisor.
		for fd in c.int(READY_FD + 1) ..< max_fd {
			if posix.FD(fd) != rep do posix.close(posix.FD(fd))
		}
		posix.execve(c_exe, raw_data(c_argv), posix.environ)
		fail(rep)
	}

	posix.close(ready[1])
	posix.close(report[1])
	defer posix.close(report[0])
	errno: u8
	for {
		n := posix.read(report[0], &errno, 1)
		if n == -1 && posix.errno() == .EINTR do continue
		if n == 1 {
			status: c.int
			for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {}
			posix.close(ready[0])
			return child, "exec failed"
		}
		break
	}
	flags := posix.fcntl(ready[0], .GETFL)
	posix.fcntl(ready[0], .SETFL, flags | c.int(posix.O_NONBLOCK))
	child.pid = pid
	child.ready_r = ready[0]
	return child, ""
}

poll_child :: proc(c: ^Child) -> (exited: bool, code: int, sig: int) {
	if c.exited do return true, c.code, c.signal
	if c.pid <= 0 do return true, 0, 0
	status: i32
	r := posix.waitpid(c.pid, &status, {.NOHANG})
	if r == 0 do return false, 0, 0
	if r == -1 {
		if posix.errno() == .EINTR do return false, 0, 0
		c.exited = true
		c.code = -1
		return true, c.code, 0
	}
	c.exited = true
	if posix.WIFEXITED(status) do c.code = int(posix.WEXITSTATUS(status))
	else if posix.WIFSIGNALED(status) do c.signal = int(posix.WTERMSIG(status))
	return true, c.code, c.signal
}

poll_ready :: proc(c: ^Child, tree: string) -> (line: string, ok: bool) {
	if c.ready_r < 0 || c.buf.eof do return
	for c.buf.n < len(c.buf.buf) {
		n := posix.read(c.ready_r, &c.buf.buf[c.buf.n], uint(len(c.buf.buf) - c.buf.n))
		if n > 0 {
			c.buf.n += int(n)
			continue
		}
		if n == 0 do c.buf.eof = true
		break
	}
	if l, has := ready_buffer_line(&c.buf); has {
		if check_ready_line(l, tree) do return strings.clone(l, context.temp_allocator), true
		log("ignoring malformed READY line %q", l)
		c.buf.eof = true // only the first line counts
	}
	return
}

// request_child_stop forwards SIGTERM to the supervisor's process group (spec §7.3).
request_child_stop :: proc(l: ^Launcher, c: ^Child) {
	if c.pid > 0 && !c.exited do posix.kill(-c.pid, .SIGTERM)
}

// kill_child SIGKILLs the supervisor's process group. After the leader was reaped the
// group id is still reserved while any member lives, so this reaches only leftovers
// of this supervisor.
kill_child :: proc(c: ^Child) {
	if c.pid > 0 do posix.kill(-c.pid, .SIGKILL)
}

release_child :: proc(c: ^Child) {
	if !c.exited && c.pid > 0 {
		kill_child(c)
		start := time.tick_now()
		for time.tick_since(start) < 5 * time.Second {
			if exited, _, _ := poll_child(c); exited do break
			time.sleep(10 * time.Millisecond)
		}
	}
	if c.ready_r >= 0 {
		posix.close(c.ready_r)
		c.ready_r = -1
	}
}
