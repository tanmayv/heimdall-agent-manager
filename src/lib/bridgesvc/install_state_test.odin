package bridgesvc

import "core:fmt"
import "core:os"
import "core:testing"

// One test per row of the installer contract's state table (§3). The classifier is
// pure, so these run identically on Linux, macOS and Windows.

@(private = "file")
healthy :: proc() -> Install_Facts {
	return Install_Facts {
		service_registered = true,
		running = true,
		bin_present = true,
		config_present = true,
		ports_present = true,
		bridge_id = "brg_a",
		copy_binaries = true,
		binaries_match = true,
		installed_version = "0.5.75",
		bundle_version = "0.5.75",
	}
}

@(test)
test_install_s1_nothing_installed_full_install :: proc(t: ^testing.T) {
	p := classify_install({copy_binaries = true, bundle_version = "0.5.75"})
	testing.expect_value(t, p.rows, Install_Rows{.S1_Fresh})
	testing.expect(t, p.replace_binaries && p.enroll && p.extensions && !p.noop && !p.refuse)
	testing.expect_value(t, p.reuse_bridge, "")
}

@(test)
test_install_s2_healthy_changes_nothing :: proc(t: ^testing.T) {
	p := classify_install(healthy())
	testing.expect_value(t, p.rows, Install_Rows{.S2_Healthy})
	testing.expect(t, p.noop && !p.replace_binaries && !p.enroll && !p.extensions && !p.refuse)
	// Run from the installed bin/ (tray "repair", a user re-running setup): same.
	f := healthy()
	f.copy_binaries = false
	testing.expect(t, classify_install(f).noop)
	// Explicit --version equal to the installed one: nothing.
	f = healthy()
	f.requested_version = "v0.5.75"
	testing.expect(t, classify_install(f).noop)
	// "latest" is no explicit version.
	f = healthy()
	f.requested_version = "latest"
	f.keep_version = true
	testing.expect(t, classify_install(f).noop)
}

@(test)
test_install_s3_not_enrolled_keeps_binaries :: proc(t: ^testing.T) {
	f := healthy()
	f.bridge_id = ""
	f.running = false
	p := classify_install(f)
	testing.expect(t, .S3_Not_Enrolled in p.rows)
	testing.expect(t, p.enroll && !p.replace_binaries && !p.extensions && !p.noop)
	testing.expect_value(t, p.reuse_bridge, "")
	// credential_missing marker (enrolled but tokenless) lands in S3, keeps the id.
	f.marker_present = true
	f.marker = {bridge_id = "brg_old", reason = "credential_missing"}
	p = classify_install(f)
	testing.expect(t, .S3_Not_Enrolled in p.rows && .S4_Enrollment_Invalid not_in p.rows)
	testing.expect_value(t, p.reuse_bridge, "brg_old")
	testing.expect(t, p.clear_marker)
}

@(test)
test_install_s4_refused_credential_reenrolls_in_place :: proc(t: ^testing.T) {
	for reason in ([]string{"revoked", "refresh_rejected", "vault_key_timeout"}) {
		f := healthy()
		f.marker_present = true
		f.marker = {bridge_id = "brg_a", reason = reason}
		p := classify_install(f)
		testing.expectf(t, .S4_Enrollment_Invalid in p.rows, "%s: S4", reason)
		testing.expect(t, p.enroll && p.clear_marker && !p.replace_binaries && !p.noop)
		testing.expect_value(t, p.reuse_bridge, "brg_a")
		testing.expect_value(t, p.reenroll_reason, reason)
	}
	// --reenroll forces the same path on a healthy instance (no marker to clear).
	f := healthy()
	f.reenroll = true
	p := classify_install(f)
	testing.expect(t, .S4_Enrollment_Invalid in p.rows && p.enroll && !p.clear_marker)
	testing.expect_value(t, p.reuse_bridge, "brg_a")
	// Explicit enroll flags win over the derived identity.
	f = healthy()
	f.new_bridge = true
	p = classify_install(f)
	testing.expect(t, p.enroll)
	testing.expect_value(t, p.reuse_bridge, "")
	f = healthy()
	f.reuse_bridge = "brg_other"
	testing.expect_value(t, classify_install(f).reuse_bridge, "brg_other")
	f = healthy()
	f.reuse_bridge = "brg_a"
	testing.expect(t, classify_install(f).noop, "reuse of the current bridge is no enrollment")
}

// S5a / S5c: another hub or another profile is another service name, so its
// instance has no facts yet: S1 for it. (The collision S5b is the owner check in
// setup_cmd; S5d the separate-account choice, both tested there.)
@(test)
test_install_s5_other_hub_or_profile_is_a_new_instance :: proc(t: ^testing.T) {
	a, _ := profile_from("https://hub-a.example.com", "", context.temp_allocator)
	b, _ := profile_from("https://hub-b.example.com", "", context.temp_allocator)
	c, _ := profile_from("https://hub-a.example.com", "work", context.temp_allocator)
	testing.expect(t, a.service_name != b.service_name && a.service_name != c.service_name)
	testing.expect_value(t, classify_install({copy_binaries = true}).rows, Install_Rows{.S1_Fresh})
}

@(test)
test_install_s6_service_missing_or_stopped :: proc(t: ^testing.T) {
	f := healthy()
	f.running = false
	p := classify_install(f)
	testing.expect_value(t, p.rows, Install_Rows{.S6_Service})
	testing.expect(t, !p.noop && !p.enroll && !p.replace_binaries)
	f.service_registered = false
	p = classify_install(f)
	testing.expect_value(t, p.rows, Install_Rows{.S6_Service})
	testing.expect(t, !p.enroll, "a missing service is never a reason to re-enroll")
	// Combined with a refused credential: S4 + S6 in one run.
	f.marker_present = true
	f.marker = {bridge_id = "brg_a", reason = "revoked"}
	testing.expect_value(t, classify_install(f).rows, Install_Rows{.S4_Enrollment_Invalid, .S6_Service})
}

@(test)
test_install_s7_interrupted_install_is_finished :: proc(t: ^testing.T) {
	// bin/ missing (with or without bin.bak*), service registered: install from the bundle.
	f := healthy()
	f.bin_present = false
	f.running = false
	f.binaries_match = false
	f.installed_version = ""
	p := classify_install(f)
	testing.expect(t, .S7_Partial in p.rows && p.replace_binaries && !p.enroll && p.extensions)
	// Leftover staging, bin/ intact: binaries replaced from the bundle.
	f = healthy()
	f.staging_left = true
	p = classify_install(f)
	testing.expect(t, .S7_Partial in p.rows && p.replace_binaries && !p.noop)
	// Run from bin/ with leftover staging: staging is discarded, nothing copied.
	f.copy_binaries = false
	p = classify_install(f)
	testing.expect(t, .S7_Partial in p.rows && !p.replace_binaries && !p.noop)
	// Config or ports missing: repaired, credential kept.
	f = healthy()
	f.ports_present = false
	p = classify_install(f)
	testing.expect(t, .S7_Partial in p.rows && !p.enroll && !p.noop)
	f = healthy()
	f.config_present = false
	testing.expect(t, .S7_Partial in classify_install(f).rows)
}

@(test)
test_install_s8a_keep_version_never_changes_a_healthy_bridge :: proc(t: ^testing.T) {
	for installed in ([]string{"0.5.74", "0.5.80"}) {
		f := healthy()
		f.binaries_match = false
		f.installed_version = installed
		f.keep_version = true
		p := classify_install(f)
		testing.expectf(t, p.noop && !p.replace_binaries, "installed %s: nothing changes", installed)
		testing.expect_value(t, p.rows, Install_Rows{.S8a_Version_Kept, .S2_Healthy})
	}
	// --keep-version repairs (S4) but still keeps the binaries.
	f := healthy()
	f.binaries_match = false
	f.installed_version = "0.5.74"
	f.keep_version = true
	f.marker_present = true
	f.marker = {bridge_id = "brg_a", reason = "revoked"}
	p := classify_install(f)
	testing.expect(t, !p.replace_binaries && p.enroll)
}

// Default (no --keep-version): the bundle's binaries replace different installed
// ones. This is what `ham-bridge update`, auto-update and hub updates run.
@(test)
test_install_s8b_update_path_installs_the_bundle :: proc(t: ^testing.T) {
	f := healthy()
	f.binaries_match = false
	f.installed_version = "0.5.74"
	p := classify_install(f)
	testing.expect_value(t, p.rows, Install_Rows{.S8b_Version_Change})
	testing.expect(t, p.replace_binaries && p.extensions && !p.enroll && !p.noop)
	// Same version, different bytes (a rebuilt bundle): today's update path replaces.
	f.installed_version = "0.5.75"
	testing.expect(t, classify_install(f).replace_binaries)
	// Explicit --version newer than installed, even with --keep-version.
	f = healthy()
	f.binaries_match = false
	f.installed_version = "0.5.74"
	f.requested_version = "v0.5.75"
	f.keep_version = true
	p = classify_install(f)
	testing.expect(t, .S8b_Version_Change in p.rows && p.replace_binaries)
	// Combined with a repair: S8b + S4 in one run.
	f.marker_present = true
	f.marker = {bridge_id = "brg_a", reason = "revoked"}
	p = classify_install(f)
	testing.expect(t, p.replace_binaries && p.enroll)
}

@(test)
test_install_s8c_downgrade_needs_allow_downgrade :: proc(t: ^testing.T) {
	f := healthy()
	f.binaries_match = false
	f.installed_version = "0.5.80"
	f.bundle_version = "0.5.75"
	f.requested_version = "v0.5.75"
	p := classify_install(f)
	testing.expect(t, p.refuse && .S8c_Downgrade_Refused in p.rows)
	testing.expect_value(t, p.exit_code, EXIT_REFUSED)
	f.allow_downgrade = true
	p = classify_install(f)
	testing.expect(t, !p.refuse && p.replace_binaries && .S8b_Version_Change in p.rows)
	// --version that is not this bundle: usage error, nothing touched.
	f = healthy()
	f.requested_version = "0.6.0"
	p = classify_install(f)
	testing.expect(t, p.refuse)
	testing.expect_value(t, p.exit_code, EXIT_USAGE)
}

@(test)
test_install_version_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, version_compare("v0.5.10", "0.5.9"), 1)
	testing.expect_value(t, version_compare("0.5.74", "v0.5.74"), 0)
	testing.expect_value(t, version_compare("0.5", "0.5.1"), -1)
	testing.expect_value(t, version_compare("0.5.75-rc.1", "0.5.75"), 0)
	testing.expect_value(t, normalize_version("latest"), "")
	testing.expect_value(t, parse_version_output("ham-bridge 0.5.74 (60c3af8b)\n"), "0.5.74")
	testing.expect_value(t, parse_version_output("ham-bridge v0.5.74"), "0.5.74")
	testing.expect_value(t, parse_version_output("garbage"), "")
	testing.expect_value(t, install_rows_label({.S4_Enrollment_Invalid, .S6_Service}), "S4 enrollment invalid + S6 service missing or stopped")
	testing.expect_value(t, install_rows_label({}), "no change needed")
}

@(test)
test_install_files_identical :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/.cache/heimdall-tests/install-identical-%d", os.get_env("HOME", context.temp_allocator), os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	a, b, c := pjoin(dir, "a"), pjoin(dir, "b"), pjoin(dir, "c")
	_ = os.write_entire_file_from_string(a, "same")
	_ = os.write_entire_file_from_string(b, "same")
	_ = os.write_entire_file_from_string(c, "diff")
	testing.expect(t, files_identical(a, b))
	testing.expect(t, !files_identical(a, c))
	testing.expect(t, !files_identical(a, pjoin(dir, "missing")))
}

// `ham-bridge update` passes --reinstall: an identical bundle still re-runs the
// whole transaction (today's forced same-version update, e2e step 5/5b).
@(test)
test_install_reinstall_runs_the_full_transaction :: proc(t: ^testing.T) {
	f := healthy()
	f.reinstall = true
	p := classify_install(f)
	testing.expect(t, !p.noop && p.replace_binaries && p.reinstall && p.extensions && !p.enroll)
	testing.expect(t, .S8b_Version_Change in p.rows)
	// From the installed bin/: nothing to copy, but still a full pass.
	f.copy_binaries = false
	p = classify_install(f)
	testing.expect(t, !p.noop && !p.replace_binaries && p.reinstall)
}
