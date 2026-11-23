package bridgesvc

// Install-state classification for `ham-bridge setup` (installer contract,
// docs/specs/bridge-installer-contract.md §3). After the install lock is held and
// before anything is mutated, setup reads Install_Facts from disk and the service
// manager, and classify_install folds them into one Install_Plan: which rows of the
// state table apply (S1-S8) and the minimal action. The function is pure, so every
// row is unit tested the same way on Linux, macOS and Windows; only the gathering
// of facts (setup_cmd.odin) touches the OS.
//
// Version policy (user decision, 2026-11-23): by default setup installs the
// bundle it ships in, so `ham-bridge update`, auto-update and hub-started updates,
// which all run the NEW bundle's `setup --hub H [--profile P] --headless`
// (update_setup_argv), keep working. --keep-version (passed by install.sh and
// install.ps1) keeps a working instance's binaries whatever version the bundle is
// (row S8a). An explicit --version always means "install this version" (S8b) and
// refuses a downgrade without --allow-downgrade (S8c). --reinstall (passed by
// `ham-bridge update` through update_setup_argv) runs the whole transaction even
// when the bundle is byte-identical to bin/: a forced same-version update re-copies
// the binaries, re-registers the service and restarts it, as every setup did
// before the state table existed.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

KEEP_VERSION_FLAG :: "--keep-version"
REINSTALL_FLAG :: "--reinstall"
ALLOW_DOWNGRADE_FLAG :: "--allow-downgrade"

// Exit codes shared by ham-bridge setup and the installer scripts (contract §4).
EXIT_OK :: 0
EXIT_FAILED :: 1 // failed; the previous state was restored
EXIT_USAGE :: 2
EXIT_BOOTSTRAP :: 3 // scripts only
EXIT_NOT_ENROLLED :: 4 // installed but not enrolled; re-run continues at S3
EXIT_REFUSED :: 5 // needs an operator decision (named flag)
EXIT_BUSY :: 6 // another setup/update holds the instance lock
EXIT_ROLLBACK_INCOMPLETE :: 7

// Install_Row names the state-table rows classify_install can report. S5a/S5c
// (another hub / another profile) are S1 for a different service name, S5b
// (name collision) is refused by the owner check, S5d is the separate-account
// choice, S7a (busy) is the lock, S1a/S9 are outcomes: none needs a row here.
Install_Row :: enum {
	S1_Fresh, // nothing installed
	S2_Healthy, // installed, enrolled, running: nothing to do
	S3_Not_Enrolled, // no credential
	S4_Enrollment_Invalid, // credential refused by the hub (marker) or --reenroll
	S6_Service, // service file missing/unregistered, or not running
	S7_Partial, // leftover staging, bin/ham-bridge missing, config/ports missing
	S8a_Version_Kept, // --keep-version and the bundle is another version
	S8b_Version_Change, // binaries replaced by the bundle's (update / --version)
	S8c_Downgrade_Refused,
}
Install_Rows :: bit_set[Install_Row]

INSTALL_ROW_LABELS := [Install_Row]string {
	.S1_Fresh              = "S1 not installed",
	.S2_Healthy            = "S2 installed, enrolled and running",
	.S3_Not_Enrolled       = "S3 installed, not enrolled",
	.S4_Enrollment_Invalid = "S4 enrollment invalid",
	.S6_Service            = "S6 service missing or stopped",
	.S7_Partial            = "S7 interrupted install",
	.S8a_Version_Kept      = "S8a version kept",
	.S8b_Version_Change    = "S8b version change",
	.S8c_Downgrade_Refused = "S8c downgrade refused",
}

// Install_Facts is everything classify_install needs, read after Lock.
Install_Facts :: struct {
	service_registered: bool,
	running:            bool,
	bin_present:        bool, // bin/ham-bridge(.exe) exists
	staging_left:       bool, // <data>/.staging from an interrupted setup
	config_present:     bool, // config.toml and the saved hub
	ports_present:      bool,
	bridge_id:          string, // from the credential; "" = no credential
	marker:             Reenroll_Marker,
	marker_present:     bool, // a needs-reenrollment.json that applies to the credential
	copy_binaries:      bool, // setup runs from a bundle, not from the installed bin/
	binaries_match:     bool, // the bundle's ham-bridge is byte-identical to bin/'s
	installed_version:  string, // "" = unknown
	bundle_version:     string,
	requested_version:  string, // --version, "" or "latest" = none
	keep_version:       bool,
	allow_downgrade:    bool,
	reinstall:          bool, // --reinstall (ham-bridge update): full transaction
	reenroll:           bool, // --reenroll
	new_bridge:         bool, // --new-bridge
	reuse_bridge:       string, // --reuse-bridge
}

Install_Plan :: struct {
	rows:             Install_Rows,
	// Nothing to do (S2/S8a on a healthy instance): no stop, no write, no restart;
	// Verify only waits, read-only, and a missing hub connection is a warning.
	noop:             bool,
	replace_binaries: bool,
	reinstall:        bool, // re-register the service and restart even if unchanged
	enroll:           bool,
	// A failed enrollment rolls the run back (update path) instead of halting with
	// the install kept and the service not started (S1a, exit 4).
	enroll_rolls_back: bool,
	reuse_bridge:     string, // passed to enroll as --reuse-bridge
	clear_marker:     bool, // remove needs-reenrollment.json once enrolled
	reenroll_reason:  string,
	extensions:       bool, // copy and sync provider extensions
	refuse:           bool,
	exit_code:        int, // with refuse
	message:          string, // with refuse
}

// normalize_version: "v0.5.74" -> "0.5.74"; "latest" and "" -> "".
normalize_version :: proc(v: string) -> string {
	t := strings.trim_space(v)
	if t == "latest" do return ""
	if strings.has_prefix(t, "v") || strings.has_prefix(t, "V") do t = t[1:]
	return t
}

// version_compare compares dotted numeric versions (SemVer core); a pre-release or
// build suffix and missing parts count as 0. -1, 0 or 1.
version_compare :: proc(a, b: string) -> int {
	next_part :: proc(rest: ^string) -> int {
		if len(rest^) == 0 do return 0
		part := rest^
		if dot := strings.index_byte(part, '.'); dot >= 0 {
			rest^ = part[dot + 1:]
			part = part[:dot]
		} else {
			rest^ = ""
		}
		digits := 0
		for digits < len(part) && part[digits] >= '0' && part[digits] <= '9' do digits += 1
		value, _ := strconv.parse_int(part[:digits])
		return value
	}
	core :: proc(v: string) -> string {
		t := normalize_version(v)
		if cut := strings.index_any(t, "-+ "); cut >= 0 do t = t[:cut]
		return t
	}
	ra, rb := core(a), core(b)
	for len(ra) > 0 || len(rb) > 0 {
		pa, pb := next_part(&ra), next_part(&rb)
		if pa < pb do return -1
		if pa > pb do return 1
	}
	return 0
}

// parse_version_output: "ham-bridge 0.5.74 (abc)" -> "0.5.74"; "" when absent.
parse_version_output :: proc(out: string) -> string {
	for field in strings.fields(out, context.temp_allocator) {
		v := normalize_version(field)
		if len(v) > 0 && v[0] >= '0' && v[0] <= '9' && strings.contains_rune(v, '.') do return strings.clone(v, context.temp_allocator)
	}
	return ""
}

// classify_install chooses the minimal action for one instance (contract §3).
classify_install :: proc(f: Install_Facts) -> Install_Plan {
	p: Install_Plan
	requested := normalize_version(f.requested_version)
	installed := normalize_version(f.installed_version)
	bundle := normalize_version(f.bundle_version)
	fresh := !f.bin_present && !f.service_registered && f.bridge_id == "" && !f.marker_present

	// --version names the release the caller bootstrapped from; it must be this bundle.
	if requested != "" && bundle != "" && f.copy_binaries && version_compare(requested, bundle) != 0 {
		p.refuse, p.exit_code = true, EXIT_USAGE
		p.message = fmt.tprintf("--version %s does not match this bundle (v%s)", requested, bundle)
		return p
	}
	if requested != "" && f.bin_present && installed != "" && version_compare(requested, installed) < 0 && !f.allow_downgrade {
		p.rows += {.S8c_Downgrade_Refused}
		p.refuse, p.exit_code = true, EXIT_REFUSED
		p.message = fmt.tprintf("runs v%s, newer than requested v%s; pass %s to downgrade", installed, requested, ALLOW_DOWNGRADE_FLAG)
		return p
	}

	// Binaries.
	if f.copy_binaries {
		switch {
		case fresh:
			p.replace_binaries = true
		case !f.bin_present:
			// bin/ missing: install from the bundle; a bin.bak* is never trusted as
			// the source. A leftover .staging with an intact bin/ is only discarded
			// (Stage) and the normal version policy below applies, so --keep-version
			// never replaces a working bin/ with a possibly older bundle.
			p.replace_binaries = true
			p.rows += {.S7_Partial}
		case requested != "":
			// Explicit version: replace unless it is already installed.
			already := f.binaries_match || (installed != "" && version_compare(requested, installed) == 0)
			if !already {
				p.replace_binaries = true
				p.rows += {.S8b_Version_Change}
			}
		case f.reinstall:
			p.replace_binaries = true
			p.rows += {.S8b_Version_Change}
		case f.binaries_match:
		case f.keep_version:
			p.rows += {.S8a_Version_Kept}
		case:
			p.replace_binaries = true
			p.rows += {.S8b_Version_Change}
		}
	}
	if f.staging_left do p.rows += {.S7_Partial}
	if fresh do p.rows += {.S1_Fresh}

	// Enrollment. The update path (--reinstall: ham-bridge update, auto and hub
	// updates, often detached with nobody watching) keeps the pre-T2 contract: a
	// re-enroll marker never starts an enrollment there; only an instance with no
	// credential enrolls, and a failed enrollment rolls back (enroll_rolls_back).
	marker := f.marker_present && !f.reinstall
	p.enroll_rolls_back = f.reinstall
	switch {
	case f.bridge_id == "":
		p.enroll = true
		if !fresh do p.rows += {.S3_Not_Enrolled}
		// Enrolled but tokenless (marker credential_missing): keep the identity.
		if marker && f.marker.bridge_id != "" {
			p.reuse_bridge = f.marker.bridge_id
			p.clear_marker = true
			p.reenroll_reason = f.marker.reason
		}
	case marker:
		p.enroll = true
		p.rows += {.S4_Enrollment_Invalid}
		p.reuse_bridge = f.bridge_id
		p.clear_marker = true
		p.reenroll_reason = f.marker.reason
	case f.new_bridge:
		p.enroll = true
	case f.reenroll:
		p.enroll = true
		p.rows += {.S4_Enrollment_Invalid}
		p.reuse_bridge = f.bridge_id
		p.reenroll_reason = "requested"
	case f.reuse_bridge != "" && f.reuse_bridge != f.bridge_id:
		p.enroll = true
	}
	// Explicit enroll flags win over the derived identity.
	if f.new_bridge do p.reuse_bridge = ""
	if f.reuse_bridge != "" do p.reuse_bridge = f.reuse_bridge

	// Service, config and ports.
	if !fresh && (!f.service_registered || !f.running) do p.rows += {.S6_Service}
	if !fresh && f.bin_present && (!f.config_present || !f.ports_present) do p.rows += {.S7_Partial}

	p.reinstall = f.reinstall
	p.extensions = fresh || p.replace_binaries || f.reinstall
	p.noop = !f.reinstall && !p.replace_binaries && !p.enroll && f.service_registered && f.running && f.bin_present && f.config_present && f.ports_present && !f.staging_left
	if p.noop do p.rows += {.S2_Healthy}
	return p
}

// install_rows_label: "S4 enrollment invalid + S6 service missing or stopped".
install_rows_label :: proc(rows: Install_Rows) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for r in Install_Row do if r in rows do append(&parts, INSTALL_ROW_LABELS[r])
	if len(parts) == 0 do return "no change needed"
	return strings.join(parts[:], " + ", context.temp_allocator)
}

// files_identical: same size and the same bytes. Missing or unreadable -> false.
files_identical :: proc(a, b: string) -> bool {
	da, ea := os.read_entire_file_from_path(a, context.temp_allocator)
	if ea != nil do return false
	db, eb := os.read_entire_file_from_path(b, context.temp_allocator)
	if eb != nil do return false
	return string(da) == string(db)
}
