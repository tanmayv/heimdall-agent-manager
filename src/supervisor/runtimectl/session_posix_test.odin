#+build linux, darwin, freebsd, openbsd, netbsd
package runtimectl

import "core:sys/posix"
import "core:testing"
import "../procs"

Session :: struct {
	ok:  bool,
	id:  procs.Id,
	pid: posix.pid_t,
}

// spawn_session forks a session leader (setsid, like a PTY agent) running `sleep 300`. The
// child waits on a pipe until the parent recorded its identity.
spawn_session :: proc(t: ^testing.T) -> (s: Session) {
	argv := []cstring{"sleep", "300", nil}
	gate: [2]posix.FD
	if posix.pipe(&gate) != .OK do testing.fail_now(t, "pipe")
	pid := posix.fork()
	if pid == 0 {
		posix.setsid()
		posix.close(gate[1])
		b: [1]byte
		posix.read(gate[0], &b[0], 1)
		posix.close(gate[0])
		posix.execvp("sleep", raw_data(argv))
		posix._exit(127)
	}
	posix.close(gate[0])
	if pid < 0 {
		posix.close(gate[1])
		testing.fail_now(t, "fork")
	}
	s.pid = pid
	s.id, s.ok = procs.identify(int(pid))
	release := [1]byte{1}
	posix.write(gate[1], &release[0], 1)
	posix.close(gate[1])
	testing.expect(t, s.ok, "identify session")
	return
}

cleanup_session :: proc(s: ^Session) {
	if s.pid <= 0 do return
	if procs.alive(s.id) do posix.kill(-s.pid, .SIGKILL)
	status: i32
	posix.waitpid(s.pid, &status, {})
	s^ = {}
}
