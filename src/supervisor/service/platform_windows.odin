#+build windows
package service

// Windows process plumbing of ham-supervisor (spec §7.1, §7.3): the launcher's graceful
// stop arrives on the manual-reset event `Local\heimdall-supervisor-stop-<instance_id>`
// (created and reset by the launcher before every start; opened here with SYNCHRONIZE), and
// a console control event (Ctrl-C/Break/Close, logoff, shutdown) is a stop too. A watcher
// thread turns the event into the stop flag so a transfer in flight is aborted at once.
// READY is written to the inherited pipe handle given as `--ready-fd` (decimal value).

import "base:intrinsics"
import "core:strconv"
import "core:thread"
import win "core:sys/windows"

SUPERVISOR_STOP_EVENT_PREFIX :: `Local\heimdall-supervisor-stop-`
@(private = "file") SYNCHRONIZE_ :: 0x00100000

foreign import sup_platform_kernel32 "system:kernel32.lib"
@(default_calling_convention = "system")
foreign sup_platform_kernel32 {
	OpenEventW :: proc(access: u32, inherit: win.BOOL, name: win.wstring) -> win.HANDLE ---
}

@(private = "file") g_stop: i32
@(private = "file") g_event: win.HANDLE

@(private = "file")
console_handler :: proc "system" (ctrl: win.DWORD) -> win.BOOL {
	intrinsics.atomic_store(&g_stop, 1)
	intrinsics.atomic_store(&g_net_cancel, true)
	return true
}

stop_init :: proc(instance_id: string) -> bool {
	win.SetConsoleCtrlHandler(console_handler, true)
	if instance_id == "" do return true
	full :=win.utf8_to_wstring(concat(SUPERVISOR_STOP_EVENT_PREFIX, instance_id), context.temp_allocator)
	g_event = OpenEventW(SYNCHRONIZE_, false, full)
	if g_event == nil do return true // not started by a launcher (tests, manual runs)
	t := thread.create_and_start(proc() {
		if win.WaitForSingleObject(g_event, win.INFINITE) == win.WAIT_OBJECT_0 {
			intrinsics.atomic_store(&g_stop, 1)
			intrinsics.atomic_store(&g_net_cancel, true)
		}
	})
	_ = t
	return true
}

@(private = "file")
concat :: proc(a, b: string) -> string {
	buf := make([]byte, len(a) + len(b), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

stop_requested_flag :: proc() -> bool {
	return intrinsics.atomic_load(&g_stop) != 0
}

note_stop :: proc() {
	intrinsics.atomic_store(&g_stop, 1)
	intrinsics.atomic_store(&g_net_cancel, true)
}

@(private = "file")
handle_of :: proc(fd_text: string) -> (win.HANDLE, bool) {
	v, ok := strconv.parse_u64(fd_text, 10)
	if !ok || v == 0 do return nil, false
	return win.HANDLE(uintptr(v)), true
}

write_ready :: proc(fd_text, line: string) -> bool {
	h, ok := handle_of(fd_text)
	if !ok do return false
	data := transmute([]byte)line
	for len(data) > 0 {
		written: win.DWORD
		if !win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &written, nil) || written == 0 {
			win.CloseHandle(h)
			return false
		}
		data = data[written:]
	}
	win.CloseHandle(h)
	return true
}

close_ready_fd :: proc(fd_text: string) {
	if h, ok := handle_of(fd_text); ok do win.CloseHandle(h)
}

// The READY handle was inherited; make sure no child of ours inherits it again.
mark_ready_fd_cloexec :: proc(fd_text: string) {
	if h, ok := handle_of(fd_text); ok do win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, 0)
}
