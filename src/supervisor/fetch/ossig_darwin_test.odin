#+build darwin
package fetch

import "core:os"
import "core:testing"

// A Mach-O to play with: the test binary itself (arm64 binaries are
// linker-signed ad hoc, so codesign --verify passes and there is no Team ID).
copy_self_to :: proc(t: ^testing.T, dst: string) -> bool {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return false
	data, ok := read_file(self)
	if !ok do return false
	testing.expect(t, write_file(dst, data), "copy test binary")
	return true
}

@(test)
test_macos_codesign_states :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := make_test_dir(t)
	defer os.remove_all(dir)
	os.make_directory(pj(dir, "bin"))
	signed := pj(dir, "bin", "ham-bridge")
	if !copy_self_to(t, signed) do return
	_, _, _, ran := run_process({CODESIGN, "-s", "-", "-f", signed}, 30_000) // make sure it carries an ad-hoc signature
	testing.expect(t, ran, "codesign -s -")
	files := []Extracted_File{{path = "bin/ham-bridge"}}

	state, team, detail := os_signature_state(signed, "bin/ham-bridge")
	testing.expectf(t, state == .Valid && team == "", "ad-hoc: %v %q %s", state, team, detail)
	testing.expect(t, check_os_signatures(dir, files, {require = false}) == nil, "ad-hoc passes when not required")
	expect_code(t, check_os_signatures(dir, files, {require = true}), .Os_Signature_Invalid) // no Team ID

	// Tampered after signing: fails even when signatures are not required.
	data, _ := read_file(signed)
	data[16384 + 100] ~= 0xff
	write_file(signed, data)
	state, _, detail = os_signature_state(signed, "bin/ham-bridge")
	testing.expectf(t, state == .Invalid, "tampered: %v %s", state, detail)
	expect_code(t, check_os_signatures(dir, files, {require = false}), .Os_Signature_Invalid)

	// Unsigned: passes only when not required.
	copy_self_to(t, signed)
	_, _, _, ran = run_process({CODESIGN, "--remove-signature", signed}, 30_000)
	testing.expect(t, ran, "codesign --remove-signature")
	state, _, detail = os_signature_state(signed, "bin/ham-bridge")
	testing.expectf(t, state == .Unsigned, "unsigned: %v %s", state, detail)
	testing.expect(t, check_os_signatures(dir, files, {require = false}) == nil, "unsigned passes when not required")
	expect_code(t, check_os_signatures(dir, files, {require = true}), .Os_Signature_Invalid)

	// Not Mach-O: ignored.
	write_file(pj(dir, "README.md"), transmute([]byte)string("# not code"))
	state, _, _ = os_signature_state(pj(dir, "README.md"), "README.md")
	testing.expect_value(t, state, Signature_State.Not_Applicable)
	// Apple's own platform binaries verify (Team ID not set).
	state, _, detail = os_signature_state(CODESIGN, "codesign")
	testing.expectf(t, state == .Valid, "/usr/bin/codesign: %v %s", state, detail)
}

@(test)
test_macos_quarantine_hypothesis_and_removal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Spec §14 step 8 HYPOTHESIS: files this process writes do not get
	// com.apple.quarantine. Checked on a real extraction.
	dir, out, err := extract_bytes(t, FIXTURE_GNU_TGZ, .Tar_Gz)
	defer os.remove_all(dir)
	testing.expectf(t, err == nil, "extract: %v", err)
	staging := pj(dir, "staging")
	for f in out.files {
		testing.expectf(t, !has_quarantine(native_join(staging, f.path)), "%s got com.apple.quarantine", f.path)
	}
	// If one is present anyway, it survives a failed signature check and is
	// removed only after the check passes.
	os.make_directory(pj(staging, "bin2"))
	exe := pj(staging, "bin2", "tool")
	if !copy_self_to(t, exe) do return
	run_process({CODESIGN, "--remove-signature", exe}, 30_000)
	testing.expect(t, set_quarantine(exe), "setxattr")
	files := make([dynamic]Extracted_File, context.temp_allocator)
	append(&files, ..out.files[:])
	append(&files, Extracted_File{path = "bin2/tool"})
	expect_code(t, check_os_signatures(staging, files[:], {require = true}), .Os_Signature_Invalid)
	testing.expect(t, has_quarantine(exe), "kept after a failed check")
	testing.expect(t, check_os_signatures(staging, files[:], {require = false}) == nil, "passes unsigned when not required")
	testing.expect(t, !has_quarantine(exe), "removed after the check passed")
}
