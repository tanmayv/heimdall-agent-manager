#+build windows
package launcher_core

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"
import "core:time"
import win "core:sys/windows"

foreign import fixture_kernel32 "system:kernel32.lib"
@(default_calling_convention = "system")
foreign fixture_kernel32 {
	OpenEventW :: proc(access: u32, inherit: win.BOOL, name: win.wstring) -> win.HANDLE ---
	IsProcessInJob :: proc(process: win.HANDLE, job: win.HANDLE, result: ^win.BOOL) -> win.BOOL ---
}

@(private = "file") SYNCHRONIZE_ :: 0x00100000
@(private = "file") EVENT_MODIFY_STATE_ :: 0x0002

test_current_uid :: proc() -> i64 {
	return -1
}

fake_set_pointer :: proc(root, name, tree: string) -> bool {
	tmp := join_alloc(root, fmt.tprintf("%s.json.tmp-test", name))
	body := pointer_record_encode({tree = tree, op_id = "op_test", seq = time.time_to_unix_nano(time.now())}, context.temp_allocator)
	if os.write_entire_file(tmp, body) != nil do return false
	return replace_file(tmp, join_alloc(root, fmt.tprintf("%s.json", name)))
}

set_pointer :: proc(t: ^testing.T, f: ^Fixture, name, tree: string) {
	testing.expect(t, fake_set_pointer(f.data, name, tree), "set pointer")
}

corrupt_pointer :: proc(t: ^testing.T, f: ^Fixture, name, tree: string, crc_mismatch: bool) {
	path := join_alloc(f.data, fmt.tprintf("%s.json", name))
	if crc_mismatch {
		body := fmt.tprintf(`{{"tree":"%s","op_id":"op_test","seq":1,"crc32":"00000000"}}`, tree)
		testing.expect(t, os.write_entire_file(path, body) == nil)
	} else {
		testing.expect(t, os.write_entire_file(path, fmt.tprintf(`{{"tree":"%s"`, tree)) == nil)
	}
}

send_os_stop :: proc(t: ^testing.T, f: ^Fixture, p: os.Process) {
	name := win.utf8_to_wstring(fmt.tprintf("%s%s", LAUNCHER_STOP_EVENT_PREFIX, f.id), context.temp_allocator)
	h := OpenEventW(EVENT_MODIFY_STATE_, false, name)
	testing.expectf(t, h != nil, "OpenEventW(launcher stop): %d", win.GetLastError())
	if h == nil do return
	win.SetEvent(h)
	win.CloseHandle(h)
}

@(private = "file") g_fake_stop_event: win.HANDLE

fake_install_stop :: proc(id: string) {
	name := win.utf8_to_wstring(fmt.tprintf("%s%s", SUPERVISOR_STOP_EVENT_PREFIX, id), context.temp_allocator)
	g_fake_stop_event = OpenEventW(SYNCHRONIZE_, false, name)
}

// fake_stop_event_ok: the launcher created the supervisor stop event before the start.
fake_stop_event_ok :: proc() -> bool {
	return g_fake_stop_event != nil
}

fake_stop_requested :: proc() -> bool {
	return g_fake_stop_event != nil && win.WaitForSingleObject(g_fake_stop_event, 0) == 0
}

// The job object (KILL_ON_JOB_CLOSE) ends the fake when the launcher dies.
fake_parent_gone :: proc() -> bool {
	return false
}

fake_write_ready :: proc(fd_text: string, line: string) {
	v, ok := strconv.parse_u64(fd_text, 10)
	if !ok do return
	h := win.HANDLE(uintptr(v))
	n: win.DWORD
	win.WriteFile(h, raw_data(line), win.DWORD(len(line)), &n, nil)
	win.CloseHandle(h)
}

// Spec §2: the supervisor runs inside the launcher's job object.
fake_platform_checks :: proc() -> string {
	in_job: win.BOOL
	if !IsProcessInJob(win.GetCurrentProcess(), nil, &in_job) || !in_job do return "not-in-job"
	return ""
}

// A synthetic WM_QUERYENDSESSION / WM_ENDSESSION sent to the launcher's hidden window
// must stop the supervisor gracefully and end the launcher with 0. This checks the
// handler; delivery of real session-end messages to a launcher started by the
// Scheduled Task is not reproducible on a hosted runner (spec §7.3 HYPOTHESIS).
@(test)
test_windows_session_end_is_graceful :: proc(t: ^testing.T) {
	f := fixture_new(t, "session-end")
	defer dump_on_failure(t, &f)
	A := add_tree(t, &f, "0.5.74", "ready")
	set_pointer(t, &f, POINTER_CURRENT, A)
	set_known_good(t, &f, A)
	l := launch(t, &f)
	testing.expect(t, wait_lines(&f, cat("ready ", A), 1, 20 * time.Second))
	class := win.utf8_to_wstring(SESSION_WINDOW_CLASS, context.temp_allocator)
	title := win.utf8_to_wstring(fmt.tprintf("%s%s", SESSION_WINDOW_TITLE_PREFIX, f.id), context.temp_allocator)
	hwnd: win.HWND
	for _ in 0 ..< 100 {
		hwnd = win.FindWindowW(class, title)
		if hwnd != nil do break
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, hwnd != nil, "session window not found")
	if hwnd != nil {
		testing.expect_value(t, win.SendMessageW(hwnd, 0x0011, 0, 0), 1) // WM_QUERYENDSESSION
		win.SendMessageW(hwnd, 0x0016, 1, 0) // WM_ENDSESSION(TRUE)
	}
	testing.expect_value(t, finish(t, &f, &l, 20 * time.Second), 0)
	testing.expect_value(t, count_lines(fake_log(&f), cat("graceful ", A)), 1)
}
