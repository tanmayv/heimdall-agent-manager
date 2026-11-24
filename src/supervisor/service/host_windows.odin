#+build windows
package service

// Windows children (spec §2, §2.1, §17): one job object per instance, named
// `Local\heimdall-supervisor-job-<instance_id>`, with KILL_ON_JOB_CLOSE (nested in the
// launcher's job, Windows 8+). Every child is created suspended, assigned to the job, then
// resumed: no child ever runs outside it, and everything it starts (PTY sessions, node,
// tools) is in the job too. The supervisor holds the only handle, so the job — and the
// whole runtime tree — dies with the supervisor even if it crashes. Only the standard
// handles (and the lifeline, if enabled) are inherited (PROC_THREAD_ATTRIBUTE_HANDLE_LIST).

import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "../procs"

foreign import sup_kernel32 "system:kernel32.lib"
@(default_calling_convention = "system")
foreign sup_kernel32 {
	CreateJobObjectW :: proc(attributes: rawptr, name: win.wstring) -> win.HANDLE ---
	OpenJobObjectW :: proc(access: u32, inherit: win.BOOL, name: win.wstring) -> win.HANDLE ---
	SetInformationJobObject :: proc(job: win.HANDLE, class: i32, info: rawptr, length: u32) -> win.BOOL ---
	AssignProcessToJobObject :: proc(job: win.HANDLE, process: win.HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(job: win.HANDLE, exit_code: u32) -> win.BOOL ---
	InitializeProcThreadAttributeList :: proc(list: rawptr, count, flags: u32, size: ^uintptr) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: u32, attribute: uintptr, value: rawptr, size: uintptr, previous: rawptr, returned: ^uintptr) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
}

@(private = "file") JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9
@(private = "file") JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
@(private = "file") JOB_OBJECT_TERMINATE :: 0x0008
@(private = "file") PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x20002
JOB_PREFIX :: `Local\heimdall-supervisor-job-`

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
	pid:      u32,
	process:  win.HANDLE,
	lifeline: win.HANDLE, // write end kept by the supervisor
	exited:   bool,
}

Job :: struct {
	handle: win.HANDLE,
	name:   string,
}

job_ensure :: proc(j: ^Job, instance_id: string) -> bool {
	if j.handle != nil do return true
	name := strings.concatenate({JOB_PREFIX, instance_id})
	h := CreateJobObjectW(nil, win.utf8_to_wstring(name, context.temp_allocator))
	if h == nil {
		delete(name)
		return false
	}
	limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(h, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, &limits, size_of(limits)) {
		win.CloseHandle(h)
		delete(name)
		return false
	}
	j.handle = h
	j.name = name
	return true
}

job_name :: proc(j: ^Job) -> string {
	return j.name
}

job_terminate :: proc(j: ^Job) {
	if j.handle != nil do TerminateJobObject(j.handle, 1)
}

job_close :: proc(j: ^Job) {
	if j.handle != nil do win.CloseHandle(j.handle)
	j.handle = nil
	delete(j.name)
	j.name = ""
}

// job_terminate_by_name (J0): a predecessor's job still open (e.g. another handle keeps
// it) is terminated as a whole. Normally KILL_ON_JOB_CLOSE already ended it.
job_terminate_by_name :: proc(name: string) {
	if !strings.has_prefix(name, JOB_PREFIX) do return
	h := OpenJobObjectW(JOB_OBJECT_TERMINATE, false, win.utf8_to_wstring(name, context.temp_allocator))
	if h == nil do return
	TerminateJobObject(h, 1)
	win.CloseHandle(h)
}

@(private = "file")
inheritable_dup :: proc(h: win.HANDLE) -> (out: win.HANDLE, ok: bool) {
	self := win.GetCurrentProcess()
	if !win.DuplicateHandle(self, h, self, &out, 0, true, win.DUPLICATE_SAME_ACCESS) do return nil, false
	return out, true
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

child_spawn :: proc(h: ^Host_Ctx, exe: string, args: []string, log_path: string) -> (child: Child, id: procs.Id, err: string) {
	inherited: [4]win.HANDLE
	count := 0
	defer for i in 0 ..< count do win.CloseHandle(inherited[i])

	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	log := win.CreateFileW(win.utf8_to_wstring(log_path, context.temp_allocator), win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, &sa, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if log == win.INVALID_HANDLE_VALUE do return child, id, fmt.tprintf("open log: %d", win.GetLastError())
	inherited[count] = log
	count += 1
	null := win.CreateFileW(win.L("NUL"), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if null == win.INVALID_HANDLE_VALUE do return child, id, "open NUL failed"
	inherited[count] = null
	count += 1

	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, exe)
	life_w: win.HANDLE
	if h.lifeline {
		r, w: win.HANDLE
		if !win.CreatePipe(&r, &w, nil, 0) do return child, id, "CreatePipe failed"
		rd, ok := inheritable_dup(r)
		win.CloseHandle(r)
		if !ok {
			win.CloseHandle(w)
			return child, id, "DuplicateHandle failed"
		}
		inherited[count] = rd
		count += 1
		life_w = w
		append(&argv, "--lifeline-fd", fmt.tprintf("%d", uintptr(rd)))
	}
	append(&argv, ..args)
	line := strings.builder_make(context.temp_allocator)
	for a, i in argv {
		if i > 0 do strings.write_byte(&line, ' ')
		quote_arg(&line, a)
	}
	command := win.utf8_to_wstring(strings.to_string(line), context.temp_allocator)

	fail :: proc(life_w: win.HANDLE, msg: string) -> (Child, procs.Id, string) {
		if life_w != nil do win.CloseHandle(life_w)
		return {}, {}, msg
	}
	size: uintptr
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	storage := make([]byte, int(size), context.temp_allocator)
	attributes := rawptr(raw_data(storage))
	if !InitializeProcThreadAttributeList(attributes, 1, 0, &size) do return fail(life_w, "InitializeProcThreadAttributeList failed")
	defer DeleteProcThreadAttributeList(attributes)
	if !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherited[0], uintptr(count) * size_of(win.HANDLE), nil, nil) {
		return fail(life_w, "UpdateProcThreadAttribute failed")
	}
	startup := STARTUPINFOEXW_ {
		base = {
			cb = size_of(STARTUPINFOEXW_),
			dwFlags = win.STARTF_USESTDHANDLES | win.STARTF_USESHOWWINDOW,
			wShowWindow = u16(win.SW_HIDE),
			hStdInput = null,
			hStdOutput = log,
			hStdError = log,
		},
		attributes = attributes,
	}
	pi: win.PROCESS_INFORMATION
	cwd := win.utf8_to_wstring(h.instance_root, context.temp_allocator)
	flags := u32(win.CREATE_SUSPENDED) | win.CREATE_NO_WINDOW | win.EXTENDED_STARTUPINFO_PRESENT
	if !win.CreateProcessW(win.utf8_to_wstring(exe, context.temp_allocator), command, nil, nil, true, flags, nil, cwd, &startup.base, &pi) {
		return fail(life_w, fmt.tprintf("CreateProcessW failed: %d", win.GetLastError()))
	}
	if !AssignProcessToJobObject(h.job.handle, pi.hProcess) {
		e := win.GetLastError()
		win.TerminateProcess(pi.hProcess, 1)
		win.WaitForSingleObject(pi.hProcess, 5000)
		win.CloseHandle(pi.hThread)
		win.CloseHandle(pi.hProcess)
		return fail(life_w, fmt.tprintf("AssignProcessToJobObject failed: %d", e))
	}
	// Identity is taken while the child is still suspended, so it cannot have exited.
	ok: bool
	id, ok = procs.identify(int(pi.dwProcessId))
	if !ok do id = procs.Id{pid = int(pi.dwProcessId)}
	win.ResumeThread(pi.hThread)
	win.CloseHandle(pi.hThread)
	child.pid = pi.dwProcessId
	child.process = pi.hProcess
	child.lifeline = life_w
	return child, id, ""
}

child_exited :: proc(c: ^Child) -> bool {
	if c.exited || c.process == nil do return true
	if win.WaitForSingleObject(c.process, 0) == win.WAIT_OBJECT_0 do c.exited = true
	return c.exited
}

child_wait :: proc(c: ^Child, ms: int) {
	if c.exited || c.process == nil do return
	if win.WaitForSingleObject(c.process, u32(ms)) == win.WAIT_OBJECT_0 do c.exited = true
}

child_release :: proc(c: ^Child) {
	if c.lifeline != nil {
		win.CloseHandle(c.lifeline)
		c.lifeline = nil
	}
	if c.process != nil {
		win.CloseHandle(c.process)
		c.process = nil
	}
}
