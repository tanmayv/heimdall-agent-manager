#+build windows
package fetch

import "core:log"
import "core:os"
import "core:testing"

// An Authenticode-signed executable present on GitHub's Windows runners
// (PowerShell 7, embedded signature by Microsoft Corporation).
SIGNED_EXE_CANDIDATES := [?]string{`C:\Program Files\PowerShell\7\pwsh.exe`, `C:\Program Files\Git\cmd\git.exe`}

@(test)
test_windows_authenticode_states :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := make_test_dir(t)
	defer os.remove_all(dir)
	os.make_directory(pj(dir, "bin"))

	// Unsigned: the test binary itself (Odin output is not signed).
	self, _ := os.get_executable_path(context.temp_allocator)
	data, ok := read_file(self)
	testing.expect(t, ok, "read self")
	write_file(pj(dir, "bin", "ham-bridge.exe"), data)
	files := []Extracted_File{{path = "bin/ham-bridge.exe"}}
	state, _, detail := os_signature_state(pj(dir, "bin", "ham-bridge.exe"), "bin/ham-bridge.exe")
	testing.expectf(t, state == .Unsigned, "unsigned: %v %s", state, detail)
	testing.expect(t, check_os_signatures(dir, files, {require = false}) == nil, "unsigned passes when not required (default)")
	expect_code(t, check_os_signatures(dir, files, {require = true}), .Os_Signature_Invalid)
	// Only .exe/.dll are checked.
	state, _, _ = os_signature_state(pj(dir, "bin", "ham-bridge.exe"), "bin/ham-bridge")
	testing.expect_value(t, state, Signature_State.Not_Applicable)

	signed_src := ""
	for c in SIGNED_EXE_CANDIDATES do if os.exists(c) {
		signed_src = c
		break
	}
	if signed_src == "" {
		log.warn("no signed executable found on this machine; signed paths skipped")
		return
	}
	signed, _ := read_file(signed_src)
	write_file(pj(dir, "bin", "signed.exe"), signed)
	sfiles := []Extracted_File{{path = "bin/signed.exe"}}
	who, detail2: string
	state, who, detail2 = os_signature_state(pj(dir, "bin", "signed.exe"), "bin/signed.exe")
	testing.expectf(t, state == .Valid && who != "", "signed: %v %q %s", state, who, detail2)
	testing.expect(t, check_os_signatures(dir, sfiles, {require = true}) == nil, "signed passes when required")
	testing.expect(t, check_os_signatures(dir, sfiles, {require = true, publisher = who}) == nil, "publisher matches")
	expect_code(t, check_os_signatures(dir, sfiles, {require = true, publisher = "Someone Else Ltd"}), .Os_Signature_Invalid)

	// Tampered after signing: fails even when not required.
	evil := make([]byte, len(signed), context.temp_allocator)
	copy(evil, signed)
	evil[len(evil) / 3] ~= 0xff
	write_file(pj(dir, "bin", "signed.exe"), evil)
	state, _, detail2 = os_signature_state(pj(dir, "bin", "signed.exe"), "bin/signed.exe")
	testing.expectf(t, state == .Invalid, "tampered: %v %s", state, detail2)
	expect_code(t, check_os_signatures(dir, sfiles, {require = false}), .Os_Signature_Invalid)
}

@(test)
test_windows_open_file_blocks_rename_then_succeeds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// W3 with a real sharing violation: a file held open inside a directory
	// makes renaming the directory fail; the retry gives up with fs_busy and
	// the directory stays; once the handle is closed the rename works.
	dir := make_test_dir(t)
	defer os.remove_all(dir)
	staging := pj(dir, ".staging-op")
	os.make_directory(staging)
	f, err := os.open(pj(staging, "held.exe"), {.Write, .Create})
	testing.expect(t, err == nil, "open")
	policy := Retry_Policy{budget_ms = 300, first_ms = 50, max_ms = 100}
	rerr := rename_with_retry(staging, pj(dir, "tree"), policy)
	expect_code(t, rerr, .Fs_Busy)
	testing.expect(t, os.exists(staging), "staging stays (W3)")
	os.close(f)
	testing.expect(t, rename_with_retry(staging, pj(dir, "tree"), policy) == nil, "rename after close")
}
