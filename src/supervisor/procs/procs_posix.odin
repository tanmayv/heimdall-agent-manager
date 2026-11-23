#+build linux, darwin, freebsd, openbsd, netbsd
package procs

import "core:mem/virtual"
import "core:sys/posix"

@(private)
_self_pid :: proc() -> int {
	return int(posix.getpid())
}

// _terminate signals one target. The identity is re-checked right before the signal, so a
// pid that was reused since the target was recorded is never signalled.
@(private)
_terminate :: proc(t: Target, hard: bool) {
	sig := posix.Signal.SIGKILL if hard else posix.Signal.SIGTERM
	pid := posix.pid_t(t.id.pid)
	if alive(t.id) {
		if t.group && posix.getpgid(pid) == pid {
			posix.kill(-pid, sig)
		} else {
			posix.kill(pid, sig)
		}
		return
	}
	if t.group && _group_orphans_alive(t.id) do posix.kill(-pid, sig)
}

// _group_orphans_alive: the leader with this identity no longer runs, but members of its
// group may. The group is ours while the leader's pid is still held by the recorded leader
// (a zombie with the same start time) or by nobody: while the group exists its pgid (= the
// leader's pid) cannot be given to a new process or group. A pid held by a different
// process means the group is gone and the pid was reused. Zombie members (including the
// leader itself) do not count: kill(-pgid, 0) succeeds for them, so members are listed.
@(private)
_group_orphans_alive :: proc(leader: Id) -> bool {
	scratch := scratch_begin()
	defer scratch_end(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	pid := posix.pid_t(leader.pid)
	st, _, found := _stat(leader.pid)
	if found {
		if st != leader.start_time do return false // pid reused: not ours
	} else if posix.kill(pid, posix.Signal(0)) == .OK || posix.errno() != .ESRCH {
		return false // a process we cannot inspect holds the pid: not ours to judge
	}
	return _group_has_running_member(leader.pid)
}
