// Package procs: process identity by (pid, start_time) and stopping only the processes of
// one bridge instance (docs/specs/bridge-supervisor-engine.md §2, §2.1 layer 3, §12
// stopping; T14).
//
// A pid alone is not an identity: once a process exits, the OS may hand its pid to an
// unrelated process (another instance's agent, another user's shell). Every process the
// supervisor starts is recorded as an `Id` right after the spawn returns, and every signal
// is preceded by a fresh `identify` of that pid: a process whose start time differs is a
// different process and is never touched.
//
//   Linux    start_time = /proc/<pid>/stat field 22 (clock ticks since boot)
//   macOS    start_time = proc_pidinfo(PROC_PIDTBSDINFO) pbi_start_tvsec * 1e6 + tvusec
//   Windows  start_time = GetProcessTimes creation time (FILETIME, 100 ns units)
//
// POSIX stop: each recorded child leads its own process group (setpgid(0,0) at spawn), so
// SIGTERM / SIGKILL go to the group and reach the helpers it started *in that group*. It
// does not reach PTY agents: the PTY host starts every agent and shell session with
// setsid (portable-pty pre_exec, src/bridge/hub_runtime_client.odin `setsid`), so each one
// leads its own session and group. The caller therefore records every agent as its own
// group target, captured from the runtime before it is asked to end its sessions
// (src/supervisor/runtimectl). A group is signalled only while its leader still has the
// recorded identity, or — leader gone — while no process holds the leader's pid (a pgid
// cannot be reused while its group has members, so that signal can only reach the recorded
// group's survivors).
//
// Windows stop: there is no SIGTERM; the grace period lets processes that the runtime asked
// to end (§12) exit on their own, then TerminateProcess on a handle opened by pid whose
// creation time matched. Job objects (one per instance, KILL_ON_JOB_CLOSE) are the
// supervisor's (T13b); this package works on the recorded processes.
//
// Residual race (documented, not closed): between the identity check and kill() the target
// could exit and its pid be reused by a new process within microseconds. For a group
// signal the pgid cannot be reused while any member lives; for a lone pid the window is
// the cost of a portable API (Linux pidfd_open + pidfd_send_signal would close it for
// single processes, but not for groups before Linux 6.9).
package procs

import "core:mem/virtual"
import "core:time"

// Id: a process identity. start_time units are per OS (see above) and only compared.
Id :: struct {
	pid:        int,
	start_time: u64,
}

// Target: one recorded child. `group` = POSIX: signal the process group it leads.
Target :: struct {
	id:    Id,
	group: bool,
}

// identify: the identity of the live process `pid`. ok = false when there is no such
// process, it is a zombie (exited, not yet reaped), or it cannot be inspected (e.g. another
// user's process) — all cases in which it is not ours to signal.
identify :: proc(pid: int) -> (id: Id, ok: bool) {
	if pid <= 0 do return
	scratch := scratch_begin()
	defer scratch_end(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	st, zombie, found := _stat(pid)
	if !found || zombie do return
	return Id{pid, st}, true
}

// self: this process's identity.
self :: proc() -> (Id, bool) {
	return identify(_self_pid())
}

// alive: `id` still names the same running process.
alive :: proc(id: Id) -> bool {
	cur, ok := identify(id.pid)
	return ok && cur.start_time == id.start_time
}

// running: the target (and, for a POSIX group, any member of its group) still runs.
running :: proc(t: Target) -> bool {
	if alive(t.id) do return true
	scratch := scratch_begin()
	defer scratch_end(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	when ODIN_OS != .Windows {
		if t.group do return _group_orphans_alive(t.id)
	}
	return false
}

Stop_Result :: struct {
	signalled: int, // targets that received a terminate request
	survivors: int, // targets still running after wait (0 = all stopped)
}

DEFAULT_GRACE_MS :: 10_000 // §12: 10 s grace after the runtime was asked to end sessions
DEFAULT_WAIT_MS :: 30_000 // §12: then wait up to 30 s for every recorded process to exit

// stop: terminate the given targets — and nothing else. Targets whose identity no longer
// matches are skipped (already gone, or the pid now belongs to someone else).
//   1. POSIX: SIGTERM to each running target (its group when `group`); Windows: nothing yet.
//   2. Wait up to grace_ms for them to exit.
//   3. Hard stop of the rest: SIGKILL (group) / TerminateProcess.
//   4. Wait up to wait_ms. `survivors` > 0 -> the caller reports stop_timeout.
// An exited target that its parent has not reaped yet (zombie) counts as stopped; this
// package never reaps (the spawning code owns its children's exit statuses).
stop :: proc(targets: []Target, grace_ms := DEFAULT_GRACE_MS, wait_ms := DEFAULT_WAIT_MS) -> (r: Stop_Result) {
	for t in targets {
		if !running(t) do continue
		r.signalled += 1
		_terminate(t, hard = false)
	}
	if r.signalled == 0 do return
	if wait_all(targets, grace_ms) do return
	for t in targets {
		if running(t) do _terminate(t, hard = true)
	}
	wait_all(targets, wait_ms)
	for t in targets do if running(t) do r.survivors += 1
	return
}

// Every inspection runs in its own scratch arena, freed on return: stop() polls every
// 20 ms for up to 40 s and a group scan reads all of /proc, so allocating from the caller's
// temp allocator would grow the supervisor's long-lived temp arena by hundreds of MB. A
// library cannot free_all the caller's temp allocator (it may hold the caller's data).
@(private)
scratch_begin :: proc() -> (a: virtual.Arena) {
	_ = virtual.arena_init_growing(&a, 64 * 1024)
	return
}

@(private)
scratch_end :: proc(a: ^virtual.Arena) {
	virtual.arena_destroy(a)
}

// wait_all polls until no target runs or `ms` elapsed; true = all stopped.
wait_all :: proc(targets: []Target, ms: int) -> bool {
	deadline := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	for {
		any := false
		for t in targets {
			if running(t) {
				any = true
				break
			}
		}
		if !any do return true
		if time.tick_diff(time.tick_now(), deadline) <= 0 do return false
		time.sleep(20 * time.Millisecond)
	}
}
