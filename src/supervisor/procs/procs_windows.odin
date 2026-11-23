#+build windows
package procs

import win "core:sys/windows"

SYNCHRONIZE_ :: 0x0010_0000
WAIT_TIMEOUT_ :: 0x0000_0102

@(private)
_self_pid :: proc() -> int {
	return int(win.GetCurrentProcessId())
}

// _open: a handle to `pid`, with `access`, only while it is running.
@(private)
_open :: proc(pid: int, access: win.DWORD) -> (win.HANDLE, bool) {
	h := win.OpenProcess(access | win.PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE_, win.FALSE, win.DWORD(pid))
	if h == nil do return nil, false
	// Signalled = exited (the object lives on while handles to it are open). Not
	// GetExitCodeProcess: a process that exited with 259 would look like STILL_ACTIVE.
	if win.WaitForSingleObject(h, 0) != WAIT_TIMEOUT_ {
		win.CloseHandle(h)
		return nil, false
	}
	return h, true
}

@(private)
_creation :: proc(h: win.HANDLE) -> (u64, bool) {
	created, exited, kernel, user: win.FILETIME
	if !win.GetProcessTimes(h, &created, &exited, &kernel, &user) do return 0, false
	return u64(created.dwHighDateTime) << 32 | u64(created.dwLowDateTime), true
}

// _stat: GetProcessTimes creation time (100 ns units since 1601) of a running process.
// An exited process is reported not found (Windows has no group signal to protect).
@(private)
_stat :: proc(pid: int) -> (start_time: u64, zombie: bool, found: bool) {
	h, ok := _open(pid, 0)
	if !ok do return
	defer win.CloseHandle(h)
	start_time, found = _creation(h)
	return
}

// _terminate: no soft signal on Windows (the runtime asked the agents to end, §12); the
// hard stop opens the pid and terminates it only if the handle's creation time matches,
// so the check and the kill act on the same process object.
@(private)
_terminate :: proc(t: Target, hard: bool) {
	if !hard do return
	h, ok := _open(t.id.pid, win.PROCESS_TERMINATE)
	if !ok do return
	defer win.CloseHandle(h)
	st, got := _creation(h)
	if !got || st != t.id.start_time do return
	win.TerminateProcess(h, 1)
}
