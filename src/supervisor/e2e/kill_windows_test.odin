#+build windows
package e2e

import win "core:sys/windows"

// hard_kill: TerminateProcess (os.process_open asks for no terminate access).
hard_kill :: proc(pid: int) -> bool {
	PROCESS_TERMINATE :: 0x0001
	h := win.OpenProcess(PROCESS_TERMINATE, false, win.DWORD(pid))
	if h == nil do return false
	defer win.CloseHandle(h)
	return bool(win.TerminateProcess(h, 9))
}
