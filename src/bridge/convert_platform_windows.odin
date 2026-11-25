#+build windows
package main

import win "core:sys/windows"
import lc "odin_test:launcher/core"

bridge_convert_parent_pid :: proc() -> int {
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE do return 0
	defer win.CloseHandle(snap)
	entry := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	me := win.GetCurrentProcessId()
	if !win.Process32FirstW(snap, &entry) do return 0
	for {
		if entry.th32ProcessID == me do return int(entry.th32ParentProcessID)
		if !win.Process32NextW(snap, &entry) do break
	}
	return 0
}

bridge_convert_owner_json :: proc() -> string {
	sid, ok, _ := lc.current_user_sid()
	if !ok do return `{"sid":""}`
	return win_owner_json(sid)
}

@(private = "file")
win_owner_json :: proc(sid: string) -> string {
	return string(append_sid(sid))
}

@(private = "file")
append_sid :: proc(sid: string) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, `{"sid":"`)
	append(&out, sid)
	append(&out, `"}`)
	return out[:]
}

bridge_convert_windows_sid :: proc() -> string {
	sid, ok, _ := lc.current_user_sid()
	return sid if ok else ""
}

bridge_convert_free_bytes :: proc(dir: string) -> i64 {
	free: win.ULARGE_INTEGER
	if !win.GetDiskFreeSpaceExW(win.utf8_to_wstring(dir, context.temp_allocator), &free, nil, nil) do return -1
	return i64(free)
}

bridge_convert_signalled: bool

@(private = "file")
bridge_convert_ctrl_handler :: proc "system" (ctrl: win.DWORD) -> win.BOOL {
	bridge_convert_signalled = true
	return true
}

bridge_convert_install_signal_handlers :: proc() {
	win.SetConsoleCtrlHandler(bridge_convert_ctrl_handler, true)
}
