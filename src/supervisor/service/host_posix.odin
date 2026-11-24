#+build linux, darwin
package service

// POSIX children (spec §2, §2.1, §17): own process group, Linux PR_SET_PDEATHSIG(SIGKILL)
// with the getppid race check, stdout/stderr appended to <data>/logs/<role>.log, optional
// lifeline pipe on fd 3, every other descriptor closed before exec.

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../procs"

LIFELINE_FD :: 3

Child :: struct {
	pid:      posix.pid_t,
	lifeline: posix.FD, // write end kept by the supervisor; EOF in the child = supervisor gone
	exited:   bool,
}

// No job objects on POSIX: process groups (procs.stop) do the same job.
Job :: struct {}
job_ensure :: proc(j: ^Job, instance_id: string) -> bool {return true}
job_name :: proc(j: ^Job) -> string {return ""}
job_close :: proc(j: ^Job) {}
job_terminate :: proc(j: ^Job) {}
job_terminate_by_name :: proc(name: string) {}

when ODIN_OS == .Linux {
	foreign import libc "system:c"
	@(default_calling_convention = "c")
	foreign libc {
		prctl :: proc(option: c.int, #c_vararg args: ..any) -> c.int ---
	}
	PR_SET_PDEATHSIG :: 1
}

@(private = "file")
cloexec :: proc(fd: posix.FD) {
	posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
}

child_spawn :: proc(h: ^Host_Ctx, exe: string, args: []string, log_path: string) -> (child: Child, id: procs.Id, err: string) {
	child.lifeline = -1
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, exe)
	if h.lifeline do append(&argv, "--lifeline-fd", "3")
	append(&argv, ..args)
	c_exe := strings.clone_to_cstring(exe, context.temp_allocator)
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do c_argv[i] = strings.clone_to_cstring(a, context.temp_allocator)

	logfd := posix.open(strings.clone_to_cstring(log_path, context.temp_allocator), {.WRONLY, .CREAT, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
	if logfd == -1 do return child, id, "cannot open log file"
	defer posix.close(logfd)
	nullfd := posix.open("/dev/null", {.CLOEXEC})
	defer if nullfd != -1 do posix.close(nullfd)

	life: [2]posix.FD = {-1, -1}
	if h.lifeline {
		if posix.pipe(&life) != .OK do return child, id, "pipe failed"
		cloexec(life[0])
		cloexec(life[1])
	}
	report: [2]posix.FD
	if posix.pipe(&report) != .OK {
		if h.lifeline {posix.close(life[0]); posix.close(life[1])}
		return child, id, "pipe failed"
	}
	cloexec(report[0])
	cloexec(report[1])

	limit: posix.rlimit
	max_fd: c.int = 1024
	if posix.getrlimit(.NOFILE, &limit) == .OK && limit.rlim_cur > 0 do max_fd = c.int(min(u64(limit.rlim_cur), 65536))
	when ODIN_OS == .Linux do parent := posix.getpid()
	with_lifeline := h.lifeline

	pid := posix.fork()
	switch pid {
	case -1:
		posix.close(report[0]); posix.close(report[1])
		if with_lifeline {posix.close(life[0]); posix.close(life[1])}
		return child, id, "fork failed"
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
		// Keep the report pipe clear of fds 0..3.
		rep := posix.FD(posix.fcntl(report[1], .DUPFD_CLOEXEC, c.int(LIFELINE_FD + 1)))
		if rep == -1 do posix._exit(127)
		lfd := posix.FD(-1)
		if with_lifeline {
			lfd = posix.FD(posix.fcntl(life[0], .DUPFD_CLOEXEC, c.int(LIFELINE_FD + 1)))
			if lfd == -1 do fail(rep)
		}
		if nullfd != -1 && posix.dup2(nullfd, 0) == -1 do fail(rep)
		if posix.dup2(logfd, 1) == -1 do fail(rep)
		if posix.dup2(logfd, 2) == -1 do fail(rep)
		if with_lifeline {
			if posix.dup2(lfd, LIFELINE_FD) == -1 do fail(rep)
		}
		for fd in c.int(LIFELINE_FD if !with_lifeline else LIFELINE_FD + 1) ..< max_fd {
			if posix.FD(fd) != rep do posix.close(posix.FD(fd))
		}
		posix.execve(c_exe, raw_data(c_argv), posix.environ)
		fail(rep)
	}

	posix.close(report[1])
	if with_lifeline do posix.close(life[0])
	defer posix.close(report[0])
	errno: u8
	for {
		n := posix.read(report[0], &errno, 1)
		if n == -1 && posix.errno() == .EINTR do continue
		if n == 1 {
			status: c.int
			for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {}
			if with_lifeline do posix.close(life[1])
			return child, id, "exec failed"
		}
		break
	}
	child.pid = pid
	child.lifeline = life[1] if with_lifeline else -1
	ok: bool
	id, ok = procs.identify(int(pid))
	if !ok {
		// Exited (or zombie) already: record the pid alone so health reports Exited.
		id = procs.Id{pid = int(pid)}
	}
	return child, id, ""
}

child_exited :: proc(ch: ^Child) -> bool {
	if ch.exited || ch.pid <= 0 do return true
	status: c.int
	r := posix.waitpid(ch.pid, &status, {.NOHANG})
	if r == 0 do return false
	if r == -1 && posix.errno() == .EINTR do return false
	ch.exited = true
	return true
}

child_wait :: proc(c: ^Child, ms: int) {
	deadline := time.tick_now()
	for !child_exited(c) {
		if time.duration_milliseconds(time.tick_since(deadline)) >= f64(ms) do return
		time.sleep(10 * time.Millisecond)
	}
}

child_release :: proc(c: ^Child) {
	if c.lifeline >= 0 {
		posix.close(c.lifeline)
		c.lifeline = -1
	}
}
