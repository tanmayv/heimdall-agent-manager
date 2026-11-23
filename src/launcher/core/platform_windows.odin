#+build windows
// Windows side of the launcher (spec §2, §4.2, §7.3, §17): record-file pointers read
// with full sharing and retries, the supervisor in a job object with
// KILL_ON_JOB_CLOSE, the READY pipe as the only inheritable handle besides the
// standard streams, and the graceful stop paths (named stop event, stop-request file,
// session-end notifications through a hidden top-level window and a console control
// handler).
package launcher_core

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import win "core:sys/windows"

foreign import launcher_kernel32 "system:kernel32.lib"
@(default_calling_convention = "system")
foreign launcher_kernel32 {
	CreateJobObjectW :: proc(attributes: rawptr, name: win.wstring) -> win.HANDLE ---
	SetInformationJobObject :: proc(job: win.HANDLE, class: i32, info: rawptr, length: u32) -> win.BOOL ---
	AssignProcessToJobObject :: proc(job: win.HANDLE, process: win.HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(job: win.HANDLE, exit_code: u32) -> win.BOOL ---
	InitializeProcThreadAttributeList :: proc(list: rawptr, count, flags: u32, size: ^uintptr) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: u32, attribute: uintptr, value: rawptr, size: uintptr, previous: rawptr, returned: ^uintptr) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
	ReplaceFileW :: proc(replaced, replacement, backup: win.wstring, flags: u32, exclude, reserved: rawptr) -> win.BOOL ---
}

@(private = "file") JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9
@(private = "file") JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
@(private = "file") PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x20002
@(private = "file") REPLACEFILE_IGNORE_MERGE_ERRORS :: 0x2
@(private = "file") MOVEFILE_REPLACE_EXISTING_ :: 0x1
@(private = "file") MOVEFILE_WRITE_THROUGH_ :: 0x8
@(private = "file") WAIT_OBJECT_0_ :: 0
@(private = "file") ERROR_FILE_NOT_FOUND_ :: 2
@(private = "file") ERROR_PATH_NOT_FOUND_ :: 3
@(private = "file") ERROR_ACCESS_DENIED_ :: 5
@(private = "file") ERROR_SHARING_VIOLATION_ :: 32
@(private = "file") ERROR_LOCK_VIOLATION_ :: 33
@(private = "file") ERROR_BROKEN_PIPE_ :: 109
@(private = "file") WM_QUERYENDSESSION_ :: 0x0011
@(private = "file") WM_ENDSESSION_ :: 0x0016
@(private = "file") CTRL_C_EVENT_ :: 0
@(private = "file") CTRL_BREAK_EVENT_ :: 1
@(private = "file") CTRL_CLOSE_EVENT_ :: 2
@(private = "file") CTRL_LOGOFF_EVENT_ :: 5
@(private = "file") CTRL_SHUTDOWN_EVENT_ :: 6

@(private = "file")
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: i64,
	PerJobUserTimeLimit:     i64,
	LimitFlags:              u32,
	MinimumWorkingSetSize:   uintptr,
	MaximumWorkingSetSize:   uintptr,
	ActiveProcessLimit:      u32,
	Affinity:                uintptr,
	PriorityClass:           u32,
	SchedulingClass:         u32,
}

@(private = "file")
IO_COUNTERS :: struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount: u64,
	ReadTransferCount, WriteTransferCount, OtherTransferCount:    u64,
}

@(private = "file")
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    uintptr,
	JobMemoryLimit:        uintptr,
	PeakProcessMemoryUsed: uintptr,
	PeakJobMemoryUsed:     uintptr,
}

@(private = "file")
STARTUPINFOEXW_ :: struct {
	base:       win.STARTUPINFOW,
	attributes: rawptr,
}

Child :: struct {
	pid:     u32,
	process: win.HANDLE,
	job:     win.HANDLE,
	ready_r: win.HANDLE,
	ready:   bool,
	exited:  bool,
	code:    int,
	signal:  int,
	buf:     Ready_Buffer,
}

// Process-wide state the session-end handlers (which run on OS-created threads and
// have no access to the Launcher) need.
@(private = "file") g_stop: i32
@(private = "file") g_child_alive: i32
@(private = "file") g_session_end_ms: i64
@(private = "file") g_launcher_stop_event: win.HANDLE
@(private = "file") g_supervisor_stop_event: win.HANDLE
@(private = "file") g_window_thread: ^thread.Thread

// Object names (spec §7.3). The supervisor (T13) waits on SUPERVISOR_STOP_EVENT_PREFIX
// + instance_id; ham-bridge setup, the app and the uninstaller set
// LAUNCHER_STOP_EVENT_PREFIX + instance_id (or write the stop-request file when they
// run in another session, e.g. over SSH).
LAUNCHER_STOP_EVENT_PREFIX :: `Local\heimdall-launcher-stop-`
SUPERVISOR_STOP_EVENT_PREFIX :: `Local\heimdall-supervisor-stop-`
SESSION_WINDOW_CLASS :: "HeimdallLauncherSession"
SESSION_WINDOW_TITLE_PREFIX :: "heimdall-launcher-"

platform_init :: proc(l: ^Launcher) -> bool {
	id := l.instance.instance_id
	g_session_end_ms = i64(l.cfg.timeouts.session_end / time.Millisecond)
	g_launcher_stop_event = win.CreateEventW(nil, true, false, win.utf8_to_wstring(fmt.tprintf("%s%s", LAUNCHER_STOP_EVENT_PREFIX, id), context.temp_allocator))
	if g_launcher_stop_event == nil {
		log("CreateEventW(launcher stop) failed: %d", win.GetLastError())
		return false
	}
	g_supervisor_stop_event = win.CreateEventW(nil, true, false, win.utf8_to_wstring(fmt.tprintf("%s%s", SUPERVISOR_STOP_EVENT_PREFIX, id), context.temp_allocator))
	if g_supervisor_stop_event == nil {
		log("CreateEventW(supervisor stop) failed: %d", win.GetLastError())
		return false
	}
	win.SetConsoleCtrlHandler(console_ctrl_handler, true)
	title := strings.clone(fmt.tprintf("%s%s", SESSION_WINDOW_TITLE_PREFIX, id))
	g_window_thread = thread.create_and_start_with_poly_data(title, session_window_thread)
	return true
}

platform_shutdown :: proc(l: ^Launcher) {
	win.SetConsoleCtrlHandler(console_ctrl_handler, false)
	// The window thread blocks in GetMessageW for the life of the process; it is not
	// joined (the process exits right after).
}

platform_stop_signaled :: proc(l: ^Launcher) -> bool {
	if intrinsics.atomic_load(&g_stop) != 0 do return true
	if g_launcher_stop_event != nil && win.WaitForSingleObject(g_launcher_stop_event, 0) == WAIT_OBJECT_0_ {
		log("stop requested through the launcher stop event")
		intrinsics.atomic_store(&g_stop, 1)
		return true
	}
	return false
}

platform_note_stop :: proc(l: ^Launcher) {
	intrinsics.atomic_store(&g_stop, 1)
}

// session_end: ask the supervisor to stop and block up to the session-end budget
// (spec §7.3: 4 s, inside WaitToKillAppTimeout) while the main loop stops it.
@(private = "file")
session_end :: proc "contextless" () {
	intrinsics.atomic_store(&g_stop, 1)
	if g_supervisor_stop_event != nil do win.SetEvent(g_supervisor_stop_event)
	waited: i64
	for intrinsics.atomic_load(&g_child_alive) != 0 && waited < g_session_end_ms {
		win.Sleep(20)
		waited += 20
	}
}

@(private = "file")
console_ctrl_handler :: proc "system" (ctrl: win.DWORD) -> win.BOOL {
	switch ctrl {
	case CTRL_LOGOFF_EVENT_, CTRL_SHUTDOWN_EVENT_:
		session_end()
		return true
	case CTRL_C_EVENT_, CTRL_BREAK_EVENT_, CTRL_CLOSE_EVENT_:
		intrinsics.atomic_store(&g_stop, 1)
		if ctrl == CTRL_CLOSE_EVENT_ do session_end()
		return true
	}
	return false
}

@(private = "file")
session_window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	switch msg {
	case WM_QUERYENDSESSION_:
		return 1
	case WM_ENDSESSION_:
		if wparam != 0 do session_end()
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// A hidden top-level window (not message-only: those receive no session messages).
@(private = "file")
session_window_thread :: proc(title: string) {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name := win.utf8_to_wstring(SESSION_WINDOW_CLASS, context.allocator)
	wc := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		lpfnWndProc   = session_window_proc,
		hInstance     = instance,
		lpszClassName = class_name,
	}
	win.RegisterClassExW(&wc)
	hwnd := win.CreateWindowExW(0, class_name, win.utf8_to_wstring(title, context.allocator), 0, 0, 0, 0, 0, nil, nil, instance, nil)
	if hwnd == nil {
		log("session window not created (%d); logoff/shutdown will not be graceful", win.GetLastError())
		return
	}
	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

owner_matches :: proc(owner: Owner) -> bool {
	if owner.sid == "" do return false
	sid, ok, step := current_user_sid()
	if !ok do log("cannot read the current user SID: %s", step)
	return ok && strings.equal_fold(sid, owner.sid)
}

// current_user_sid returns the token user's SID as "S-1-…", formatted from the binary
// SID (revision, 48-bit big-endian authority, little-endian sub-authorities) so it
// depends on nothing beyond OpenProcessToken and GetTokenInformation. On failure
// `step` names the call that failed (diagnostics).
current_user_sid :: proc() -> (sid: string, ok: bool, step: string) {
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) do return "", false, fmt.tprintf("OpenProcessToken %d", win.GetLastError())
	defer win.CloseHandle(token)
	size: win.DWORD
	win.GetTokenInformation(token, .TokenUser, nil, 0, &size)
	if size == 0 || size > 4096 do return "", false, fmt.tprintf("GetTokenInformation(size) %d size %d", win.GetLastError(), size)
	buf := make([]byte, int(size), context.temp_allocator)
	if !win.GetTokenInformation(token, .TokenUser, raw_data(buf), size, &size) do return "", false, fmt.tprintf("GetTokenInformation %d", win.GetLastError())
	// TOKEN_USER begins with SID_AND_ATTRIBUTES whose first member is the SID pointer.
	raw := (^[^]byte)(raw_data(buf))^
	if raw == nil do return "", false, "null SID"
	count := int(raw[1])
	if raw[0] != 1 || count > 15 do return "", false, fmt.tprintf("bad SID revision %d count %d", raw[0], count)
	authority: u64
	for i in 0 ..< 6 do authority = authority << 8 | u64(raw[2 + i])
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "S-1-%d", authority)
	for i in 0 ..< count {
		o := 8 + 4 * i
		v := u32(raw[o]) | u32(raw[o + 1]) << 8 | u32(raw[o + 2]) << 16 | u32(raw[o + 3]) << 24
		fmt.sbprintf(&b, "-%d", v)
	}
	return strings.to_string(b), true, ""
}

// read_file_shared opens with full sharing and retries sharing violations / access
// denied (antivirus, backup tools) 50 ms -> 1 s for up to 10 s (spec §4.2).
read_file_shared :: proc(path: string, allocator := context.allocator) -> ([]byte, os.Error) {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	delay := 50 * time.Millisecond
	start := time.tick_now()
	for {
		h := win.CreateFileW(wpath, win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
		if h != win.INVALID_HANDLE_VALUE {
			defer win.CloseHandle(h)
			size: win.LARGE_INTEGER
			if !win.GetFileSizeEx(h, &size) do return nil, os.Platform_Error(win.GetLastError())
			if i64(size) > MAX_RECORD_BYTES do return nil, os.General_Error.Invalid_File
			data := make([]byte, int(size), allocator)
			total := 0
			for total < len(data) {
				n: win.DWORD
				if !win.ReadFile(h, &data[total], win.DWORD(len(data) - total), &n, nil) || n == 0 {
					delete(data, allocator)
					return nil, os.Platform_Error(win.GetLastError())
				}
				total += int(n)
			}
			return data, nil
		}
		e := win.GetLastError()
		if (e != ERROR_SHARING_VIOLATION_ && e != ERROR_ACCESS_DENIED_ && e != ERROR_LOCK_VIOLATION_) || time.tick_since(start) >= 10 * time.Second {
			return nil, os.Platform_Error(e)
		}
		time.sleep(delay)
		delay = min(delay * 2, time.Second)
	}
}

// read_pointer reads current.json / previous.json (spec §4.2).
read_pointer :: proc(instance_root, name: string) -> (tree: string, ok: bool) {
	data, err := read_file_shared(join(instance_root, fmt.tprintf("%s.json", name)), context.temp_allocator)
	if err != nil || len(data) > MAX_RECORD_BYTES do return
	t, valid := pointer_record_decode(data)
	if !valid do return
	return strings.clone(t, context.temp_allocator), true
}

// replace_file: ReplaceFileW, else MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH) (spec §4.2).
replace_file :: proc(src, dst: string) -> bool {
	wsrc := win.utf8_to_wstring(src, context.temp_allocator)
	wdst := win.utf8_to_wstring(dst, context.temp_allocator)
	for attempt in 0 ..< 20 {
		if ReplaceFileW(wdst, wsrc, nil, REPLACEFILE_IGNORE_MERGE_ERRORS, nil, nil) do return true
		if win.MoveFileExW(wsrc, wdst, MOVEFILE_REPLACE_EXISTING_ | MOVEFILE_WRITE_THROUGH_) do return true
		e := win.GetLastError()
		if e != ERROR_SHARING_VIOLATION_ && e != ERROR_ACCESS_DENIED_ && e != ERROR_LOCK_VIOLATION_ do return false
		time.sleep(time.Duration(50 * (attempt + 1)) * time.Millisecond)
	}
	return false
}

@(private = "file")
quote_arg :: proc(b: ^strings.Builder, arg: string) {
	strings.write_byte(b, '"')
	slashes := 0
	for c in transmute([]byte)arg {
		if c == '\\' {
			slashes += 1
			continue
		}
		count := slashes * 2 + 1 if c == '"' else slashes
		for _ in 0 ..< count do strings.write_byte(b, '\\')
		slashes = 0
		strings.write_byte(b, c)
	}
	for _ in 0 ..< slashes * 2 do strings.write_byte(b, '\\')
	strings.write_byte(b, '"')
}

@(private = "file")
inheritable_dup :: proc(h: win.HANDLE) -> (out: win.HANDLE, ok: bool) {
	self := win.GetCurrentProcess()
	if !win.DuplicateHandle(self, h, self, &out, 0, true, win.DUPLICATE_SAME_ACCESS) do return nil, false
	return out, true
}

spawn_supervisor :: proc(l: ^Launcher, tree: string, mode: Launch_Mode) -> (child: Child, err: string) {
	exe := join(l.cfg.instance_root, "releases", tree, SUPERVISOR_EXE)
	if !os.is_file(exe) do return child, "supervisor executable missing"

	read_end, write_end: win.HANDLE
	if !win.CreatePipe(&read_end, &write_end, nil, 0) do return child, fmt.tprintf("CreatePipe failed: %d", win.GetLastError())
	ready_w, dup_ok := inheritable_dup(write_end)
	win.CloseHandle(write_end)
	if !dup_ok {
		win.CloseHandle(read_end)
		return child, "DuplicateHandle failed"
	}
	inherited: [4]win.HANDLE
	inherited[0] = ready_w
	count := 1
	defer for i in 0 ..< count do win.CloseHandle(inherited[i])

	null := win.CreateFileW(win.L("NUL"), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	defer if null != win.INVALID_HANDLE_VALUE do win.CloseHandle(null)
	std := [3]win.DWORD{win.STD_INPUT_HANDLE, win.STD_OUTPUT_HANDLE, win.STD_ERROR_HANDLE}
	std_dup: [3]win.HANDLE
	for which, i in std {
		h := win.GetStdHandle(which)
		if h == nil || h == win.INVALID_HANDLE_VALUE || i == 0 do h = null
		d, ok := inheritable_dup(h)
		if !ok {
			d, ok = inheritable_dup(null)
			if !ok {
				win.CloseHandle(read_end)
				return child, "DuplicateHandle(std) failed"
			}
		}
		std_dup[i] = d
		inherited[count] = d
		count += 1
	}

	args := supervisor_args(l, tree, mode, fmt.tprintf("%d", uintptr(ready_w)))
	line := strings.builder_make(context.temp_allocator)
	for a, i in args {
		if i > 0 do strings.write_byte(&line, ' ')
		quote_arg(&line, a)
	}
	command := win.utf8_to_wstring(strings.to_string(line), context.temp_allocator)

	size: uintptr
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	storage := make([]byte, int(size), context.temp_allocator)
	attributes := rawptr(raw_data(storage))
	if !InitializeProcThreadAttributeList(attributes, 1, 0, &size) {
		win.CloseHandle(read_end)
		return child, "InitializeProcThreadAttributeList failed"
	}
	defer DeleteProcThreadAttributeList(attributes)
	if !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherited[0], uintptr(count) * size_of(win.HANDLE), nil, nil) {
		win.CloseHandle(read_end)
		return child, "UpdateProcThreadAttribute failed"
	}
	startup := STARTUPINFOEXW_ {
		base = {
			cb = size_of(STARTUPINFOEXW_),
			dwFlags = win.STARTF_USESTDHANDLES | win.STARTF_USESHOWWINDOW,
			wShowWindow = u16(win.SW_HIDE),
			hStdInput = std_dup[0],
			hStdOutput = std_dup[1],
			hStdError = std_dup[2],
		},
		attributes = attributes,
	}
	if g_supervisor_stop_event != nil do win.ResetEvent(g_supervisor_stop_event)
	job := CreateJobObjectW(nil, nil)
	if job == nil {
		win.CloseHandle(read_end)
		return child, fmt.tprintf("CreateJobObjectW failed: %d", win.GetLastError())
	}
	limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, &limits, size_of(limits)) {
		win.CloseHandle(job)
		win.CloseHandle(read_end)
		return child, fmt.tprintf("SetInformationJobObject failed: %d", win.GetLastError())
	}
	pi: win.PROCESS_INFORMATION
	cwd := win.utf8_to_wstring(l.cfg.instance_root, context.temp_allocator)
	flags := u32(win.CREATE_SUSPENDED) | win.CREATE_NO_WINDOW | win.EXTENDED_STARTUPINFO_PRESENT
	if !win.CreateProcessW(win.utf8_to_wstring(exe, context.temp_allocator), command, nil, nil, true, flags, nil, cwd, &startup.base, &pi) {
		e := win.GetLastError()
		win.CloseHandle(job)
		win.CloseHandle(read_end)
		return child, fmt.tprintf("CreateProcessW failed: %d", e)
	}
	if !AssignProcessToJobObject(job, pi.hProcess) {
		e := win.GetLastError()
		win.TerminateProcess(pi.hProcess, 1)
		win.WaitForSingleObject(pi.hProcess, 5000)
		win.CloseHandle(pi.hThread)
		win.CloseHandle(pi.hProcess)
		win.CloseHandle(job)
		win.CloseHandle(read_end)
		return child, fmt.tprintf("AssignProcessToJobObject failed: %d", e)
	}
	win.ResumeThread(pi.hThread)
	win.CloseHandle(pi.hThread)
	intrinsics.atomic_store(&g_child_alive, 1)
	child.pid = pi.dwProcessId
	child.process = pi.hProcess
	child.job = job
	child.ready_r = read_end
	return child, ""
}

poll_child :: proc(c: ^Child) -> (exited: bool, code: int, sig: int) {
	if c.exited do return true, c.code, 0
	if c.process == nil do return true, 0, 0
	if win.WaitForSingleObject(c.process, 0) != WAIT_OBJECT_0_ do return false, 0, 0
	exit_code: win.DWORD
	win.GetExitCodeProcess(c.process, &exit_code)
	c.exited = true
	c.code = int(exit_code)
	intrinsics.atomic_store(&g_child_alive, 0)
	return true, c.code, 0
}

poll_ready :: proc(c: ^Child, tree: string) -> (line: string, ok: bool) {
	if c.ready_r == nil || c.buf.eof do return
	for c.buf.n < len(c.buf.buf) {
		avail: win.DWORD
		if !win.PeekNamedPipe(c.ready_r, nil, 0, nil, &avail, nil) {
			c.buf.eof = true // ERROR_BROKEN_PIPE: the supervisor closed it or exited
			break
		}
		if avail == 0 do break
		n: win.DWORD
		want := min(avail, win.DWORD(len(c.buf.buf) - c.buf.n))
		if !win.ReadFile(c.ready_r, &c.buf.buf[c.buf.n], want, &n, nil) || n == 0 {
			c.buf.eof = true
			break
		}
		c.buf.n += int(n)
	}
	if l, has := ready_buffer_line(&c.buf); has {
		if check_ready_line(l, tree) do return strings.clone(l, context.temp_allocator), true
		log("ignoring malformed READY line %q", l)
		c.buf.eof = true
	}
	return
}

// request_child_stop sets the supervisor stop event (spec §7.3).
request_child_stop :: proc(l: ^Launcher, c: ^Child) {
	if g_supervisor_stop_event != nil do win.SetEvent(g_supervisor_stop_event)
}

kill_child :: proc(c: ^Child) {
	if c.job != nil do TerminateJobObject(c.job, 1)
}

release_child :: proc(c: ^Child) {
	if !c.exited && c.process != nil {
		kill_child(c)
		win.WaitForSingleObject(c.process, 5000)
		poll_child(c)
	}
	intrinsics.atomic_store(&g_child_alive, 0)
	if c.ready_r != nil do win.CloseHandle(c.ready_r)
	if c.process != nil do win.CloseHandle(c.process)
	if c.job != nil do win.CloseHandle(c.job) // KILL_ON_JOB_CLOSE reaps anything left
	c.ready_r = nil
	c.process = nil
	c.job = nil
}
