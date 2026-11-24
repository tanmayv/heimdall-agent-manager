#+build windows
package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import win "core:sys/windows"

Other_Proc :: struct {
	h: win.HANDLE,
}

other_prepare :: proc(b: ^Other) -> bool {
	return true
}

other_owner_json :: proc(b: ^Other) -> string {
	return fmt.tprintf(`{{"sid":"%s"}}`, os.get_env("HEIMDALL_E2E_OTHER_SID", context.temp_allocator))
}

// other_make_instance: the shared root grants everyone full control by inheritance (CI),
// so the administrator runner writes B's roots directly.
other_make_instance :: proc(b: ^Other, body: string) -> bool {
	_ = os.make_directory_all(pj(b.inst.data, "supervisor"))
	_ = os.make_directory_all(b.inst.state)
	other_write(b, b.inst.data, "instance.json", body)
	return testing.expect(b.s.t, os.exists(pj(b.inst.data, "instance.json")), "B's instance.json")
}

other_write :: proc(b: ^Other, dir, name, body: string) {
	_ = os.make_directory_all(dir)
	tmp := pj(dir, fmt.tprintf("%s.tmp", name))
	_ = os.write_entire_file(tmp, transmute([]byte)body)
	_ = os.rename(tmp, pj(dir, name))
}

other_view_inst :: proc(b: ^Other) -> ^Inst {
	return b.inst
}

other_refresh :: proc(b: ^Other) {}

@(private = "file")
quote_arg :: proc(a: string) -> string {
	if a != "" && !strings.contains_any(a, " \t\"") do return a
	out := strings.builder_make(context.temp_allocator)
	strings.write_byte(&out, '"')
	for c in transmute([]byte)a {
		if c == '"' do strings.write_byte(&out, '\\')
		strings.write_byte(&out, c)
	}
	strings.write_byte(&out, '"')
	return strings.to_string(out)
}

// other_spawn: CreateProcessWithLogonW as B (LOGON_WITH_PROFILE). Its output is not
// captured (std handles do not cross the secondary logon reliably); the launcher's
// launcher-status.json and the journal are the diagnostics.
other_spawn :: proc(b: ^Other, command: []string, env: []string, log_path: string) -> (Other_Proc, bool) {
	_ = os.write_entire_file(log_path, transmute([]byte)string("(output not captured for the other user on Windows)\n"))
	parts := make([dynamic]string, context.temp_allocator)
	for a in command do append(&parts, quote_arg(a))
	cmdline := strings.join(parts[:], " ", context.temp_allocator)
	tmpdir := pj(b.root, "tmp")
	_ = os.make_directory_all(tmpdir)
	eb := strings.builder_make(context.temp_allocator)
	for name in ([]string{"SystemRoot", "windir", "PATH", "COMSPEC", "PATHEXT"}) {
		v := os.get_env(name, context.temp_allocator)
		if v != "" do fmt.sbprintf(&eb, "%s=%s\x00", name, v)
	}
	fmt.sbprintf(&eb, "TEMP=%s\x00TMP=%s\x00", tmpdir, tmpdir)
	for v in env do fmt.sbprintf(&eb, "%s\x00", v)
	strings.write_byte(&eb, 0)
	block := win.utf8_to_utf16(strings.to_string(eb), context.temp_allocator)
	blk := make([]u16, len(block) + 2, context.temp_allocator)
	copy(blk, block)

	si: win.STARTUPINFOW
	si.cb = size_of(si)
	pi: win.PROCESS_INFORMATION
	LOGON_WITH_PROFILE :: 0x1
	CREATE_UNICODE_ENVIRONMENT :: 0x400
	CREATE_NO_WINDOW :: 0x08000000
	ok := win.CreateProcessWithLogonW(
		win.utf8_to_wstring(b.user, context.temp_allocator),
		win.utf8_to_wstring(".", context.temp_allocator),
		win.utf8_to_wstring(os.get_env("HEIMDALL_E2E_OTHER_PASSWORD", context.temp_allocator), context.temp_allocator),
		LOGON_WITH_PROFILE,
		nil,
		win.utf8_to_wstring(cmdline, context.temp_allocator),
		CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
		raw_data(blk),
		win.utf8_to_wstring(b.root, context.temp_allocator),
		&si,
		&pi,
	)
	if !ok {
		testing.expectf(b.s.t, false, "CreateProcessWithLogonW %s: error %d", cmdline, win.GetLastError())
		return {}, false
	}
	win.CloseHandle(pi.hThread)
	return {h = pi.hProcess}, true
}

other_wait :: proc(p: ^Other_Proc, timeout: time.Duration) -> (exited: bool, code: int) {
	if p.h == nil do return false, -1
	if win.WaitForSingleObject(p.h, win.DWORD(time.duration_milliseconds(timeout))) != win.WAIT_OBJECT_0 do return false, -1
	c: win.DWORD
	win.GetExitCodeProcess(p.h, &c)
	win.CloseHandle(p.h)
	p.h = nil
	return true, int(c)
}

other_kill :: proc(p: ^Other_Proc) {
	if p.h == nil do return
	win.TerminateProcess(p.h, 9)
	win.WaitForSingleObject(p.h, 5000)
	win.CloseHandle(p.h)
	p.h = nil
}

other_cleanup :: proc(b: ^Other) {
	if b.root != "" && !testing.failed(b.s.t) do _ = os.remove_all(b.root)
}
