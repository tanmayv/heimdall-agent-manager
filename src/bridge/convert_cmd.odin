package main

// Legacy -> supervisor conversion, the side-effect half (docs/specs/bridge-supervisor-conversion.md).
// The step order, the crash record, rollback order and recovery decision live in
// bridgesvc/convert.odin (pure, unit tested). This file supplies the real step
// implementations behind Convert_Seams, so tests (convert_cmd_test.odin) drive the whole
// transaction on a temp layout with fake service control and inject a failure at every
// step, on any OS.
//
//   C1 gate        Q3 agent gate (§9)                        bridge_convert_gate
//   C2 fetch       signed manifest + archive (§3.2)          bridge_convert_fetch
//   C3 backup      service def + settings, never credentials bridge_convert_backup
//   C4 quiesce     rescuer, stop old bridge + PTY, snapshot  bridge_convert_quiesce
//   C5 tree        instance.json, repair, launcher, update   bridge_convert_tree
//   C6 cutover     render the launcher service definition    bridge_convert_cutover
//   C7 start / C8 verify = journal committed (+ connected)
//   C9 finalize    idempotent, runnable without setup        bridge_convert_finalize
//   R1-R6          rollback                                  bridge_convert_rollback

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import lc "odin_test:launcher/core"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"
import httpc "odin_test:lib/httpc"
import "odin_test:supervisor/engine"
import "odin_test:supervisor/fetch"
import "odin_test:supervisor/service"

Conversion_Record :: bridgesvc.Conversion_Record
Step_Result :: bridgesvc.Step_Result

BRIDGE_CONVERT_STOP_WAIT :: 25 * time.Second
BRIDGE_CONVERT_ARCHIVE_SLACK :: i64(512) << 20 // extraction cap (fetch.MAX_UNPACKED_BYTES)
BRIDGE_CONVERT_DOWNLOAD_TIMEOUT_MS :: 30 * 60_000
BRIDGE_CONVERT_STALL_MS :: 60_000
BRIDGE_CONVERT_MAX_BUNDLE :: i64(1) << 30
BRIDGE_CONVERT_TEST_ORIGIN_ENV :: "HEIMDALL_SUPERVISOR_TEST_ORIGIN"
BRIDGE_CONVERT_TEST_GATE_ENV :: "HEIMDALL_CONVERT_GATE_SECONDS"
// Test builds only (P2-7): HEIMDALL_CONVERT_FAIL_AFTER=C<n> fails that step after its effects
// (rollback must undo them); HEIMDALL_CONVERT_KILL_AFTER=C<n> makes setup exit abruptly there
// (no rollback code runs; recovery is the rescuer / next run / finalize_conversion).
BRIDGE_CONVERT_TEST_FAIL_ENV :: "HEIMDALL_CONVERT_FAIL_AFTER"
BRIDGE_CONVERT_TEST_KILL_ENV :: "HEIMDALL_CONVERT_KILL_AFTER"

// Test builds only (-define:HEIMDALL_SUPERVISOR_TEST=true): one extra trusted signing key,
// as ham-supervisor's TEST_PINNED_KEY. A release build has neither define.
BRIDGE_CONVERT_TEST_PINNED_KEY :: #config(HEIMDALL_TEST_PINNED_KEY, "")
#assert(BRIDGE_CONVERT_TEST_PINNED_KEY == "" || service.TEST_BUILD, "HEIMDALL_TEST_PINNED_KEY needs -define:HEIMDALL_SUPERVISOR_TEST=true")

// Convert_Release is what C2 verified and downloaded.
Convert_Release :: struct {
	tag:       string,
	version:   string,
	asset:     string,
	sha256:    string,
	archive:   string, // local path; "" = none
	manifest:  string, // local path of the signed manifest bytes
	signature: string,
}

// Convert_Seams are the OS-touching calls. Zero fields use the real implementation
// (bridge_convert_seams); tests replace them.
Convert_Seams :: struct {
	now:               proc(s: ^Bridge_Setup) -> i64,
	sleep_ms:          proc(s: ^Bridge_Setup, ms: int),
	// Agents on this profile's PTY daemon(s); -1 = a daemon did not answer (busy).
	agent_count:       proc(s: ^Bridge_Setup) -> int,
	// True when the parent process is this service's legacy `update --auto-worker` (§9.1).
	parent_is_worker:  proc(s: ^Bridge_Setup) -> bool,
	// C2: verified release; the string is the failure code ("" on success).
	fetch:             proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> (Convert_Release, string),
	service_stop:      proc(s: ^Bridge_Setup) -> (bool, string),
	service_start:     proc(s: ^Bridge_Setup) -> (bool, string),
	service_running:   proc(s: ^Bridge_Setup) -> bool,
	service_connected: proc(s: ^Bridge_Setup) -> bool,
	pty_stop:          proc(s: ^Bridge_Setup) -> (bool, string),
	// C5(b): runs `<bundle>/bin/ham-supervisor repair`; returns its exit code.
	repair:            proc(s: ^Bridge_Setup, rel: Convert_Release, rec: Conversion_Record) -> (int, string),
	// C6: renders and registers the launcher service definition.
	register:          proc(s: ^Bridge_Setup, rec: Conversion_Record, converting: bool) -> Step_Result,
	enroll:            proc(s: ^Bridge_Setup) -> Step_Result,
	extensions:        proc(s: ^Bridge_Setup) -> Step_Result,
	spawn_rescuer:     proc(s: ^Bridge_Setup, rec: Conversion_Record) -> bool,
	stop_rescuer:      proc(s: ^Bridge_Setup, rec: Conversion_Record),
	old_version:       proc(s: ^Bridge_Setup) -> string, // `bin/ham-bridge --version`
	// OS part of the service-definition restore/finalize.
	os_restore_service: proc(s: ^Bridge_Setup, rec: Conversion_Record) -> (bool, string),
	os_finalize:       proc(s: ^Bridge_Setup, rec: Conversion_Record) -> (bool, string),
	free_bytes:        proc(dir: string) -> i64, // -1 = unknown
	// The setup exe's own SHA-256 and the tree's, for the bundle_mismatch check (C5(c)).
	self_sha256:       proc(s: ^Bridge_Setup) -> string,
	owner_json:        proc() -> string,
	windows_sid:       proc() -> string,
}

// Convert_State is a conversion's working data, kept on Bridge_Setup.conv.
Convert_State :: struct {
	seams:        Convert_Seams,
	rec:          Conversion_Record,
	release:      Convert_Release,
	cancel:       bool, // set by the signal handler
	forced:       bool, // the gate ran out: stop agents
	gate_started: i64,
	logged:       [dynamic]string, // diagnostics for the final message
	// Test-only failure injection: called after a step's side effects succeeded; a
	// non-empty return fails the step (so rollback must undo those effects). nil in setup.
	fail_after:   proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string,
	test_user:    rawptr, // test fakes' world
	update_json_existed: bool,
}

// ---- small helpers ----------------------------------------------------------------

bridge_convert_now_unix :: proc(s: ^Bridge_Setup) -> i64 {
	if s.conv != nil && s.conv.seams.now != nil do return s.conv.seams.now(s)
	return time.to_unix_seconds(time.now())
}

bridge_convert_sleep :: proc(s: ^Bridge_Setup, ms: int) {
	if s.conv != nil && s.conv.seams.sleep_ms != nil {
		s.conv.seams.sleep_ms(s, ms)
		return
	}
	time.sleep(time.Duration(ms) * time.Millisecond)
}

bridge_convert_write_file :: proc(path, text: string, mode := os.Permissions{.Read_User, .Write_User}) -> bool {
	// Atomic replace: temp file in the same directory, then rename.
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	_ = os.make_directory_all(bridgesvc.pdir(path))
	f, oerr := os.open(tmp, {.Write, .Create, .Trunc}, mode)
	if oerr != nil do return false
	_, werr := os.write_string(f, text)
	// fsync before the rename: the record and restored service files must survive power loss.
	serr := os.sync(f)
	_ = os.close(f)
	if werr != nil || serr != nil {
		_ = os.remove(tmp)
		return false
	}
	// core:os rename replaces an existing file on every OS (MoveFileEx REPLACE_EXISTING on
	// Windows), so the old file is never removed first: a crash leaves old or new, not neither.
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

bridge_convert_file_sha256 :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return ""
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], context.temp_allocator))
}

bridge_convert_copy_tree :: proc(src, dst: string) -> bool {
	if os.is_dir(src) {
		if os.make_directory_all(dst) != nil && !os.is_dir(dst) do return false
		entries, err := os.read_directory_by_path(src, -1, context.temp_allocator)
		if err != nil do return false
		for e in entries do if !bridge_convert_copy_tree(bridgesvc.pjoin(src, e.name), bridgesvc.pjoin(dst, e.name)) do return false
		return true
	}
	_ = os.make_directory_all(bridgesvc.pdir(dst))
	return os.copy_file(dst, src) == nil
}

// ---- backup index (C3) ------------------------------------------------------------------

Backup_Entry :: struct {
	path:    string `json:"path"`,
	existed: bool   `json:"existed"`,
	index:   int    `json:"index"`,
}

Backup_Index :: struct {
	files: []Backup_Entry `json:"files"`,
}

bridge_convert_backup_index_path :: proc(dir: string) -> string {return bridgesvc.pjoin(dir, "backup.json")}

bridge_convert_read_backup_index :: proc(dir: string) -> (idx: Backup_Index, ok: bool) {
	data, err := os.read_entire_file_from_path(bridge_convert_backup_index_path(dir), context.temp_allocator)
	if err != nil do return {}, false
	// Unmarshal first: a return list evaluates `idx` before the call fills it.
	parsed := json.unmarshal(data, &idx, .JSON, context.temp_allocator) == nil
	return idx, parsed
}

// ---- C0 helpers: facts, recovery, init --------------------------------------------------

// bridge_convert_supervisor_managed: valid instance.json (schema 1, owner, roots) and
// launcher/ham-launcher present (conversion spec §12.2).
bridge_convert_supervisor_managed :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> bool {
	rec, reason := lc.read_instance_record(l.data_dir, context.temp_allocator)
	if reason != "" do return false
	if lc.check_instance_record(rec, l.data_dir, l.state_dir) != "" do return false
	return os.is_file(bridgesvc.launcher_path(host, l))
}

// bridge_convert_bundle_capable: the bundle ships every engine binary (§3.1). The manifest
// itself is verified in C2; a malformed one is a refusal there, not S10b.
bridge_convert_bundle_capable :: proc(host: bridgesvc.Host, bundle_dir: string) -> bool {
	for base in ([]string{"ham-bridge", "ham-pty-host", "ham-ctl", "ham-supervisor", "ham-launcher"}) {
		if !os.is_file(bridgesvc.pjoin(bundle_dir, bridgesvc.exe_name(host, base))) do return false
	}
	return true
}

// bridge_convert_layout_ok: the cheap C5(c) checks used by recovery: instance.json valid,
// launcher present and a valid tree behind `current`.
bridge_convert_layout_ok :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> bool {
	if !bridge_convert_supervisor_managed(host, l) do return false
	tree, ok := lc.read_pointer(l.data_dir, lc.POINTER_CURRENT)
	if !ok || tree == "" do return false
	valid, _ := lc.tree_valid(l.data_dir, tree)
	return valid
}

bridge_convert_read_record :: proc(l: bridgesvc.Layout) -> (rec: Conversion_Record, present: bool, readable: bool) {
	path := bridgesvc.conversion_path(l)
	if !os.exists(path) do return {}, false, false
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return {}, true, false
	rec, readable = bridgesvc.parse_conversion(string(data))
	return rec, true, readable
}

bridge_convert_persist :: proc(data: rawptr, rec: Conversion_Record) -> bool {
	s := (^Bridge_Setup)(data)
	// Before C3 there is nothing on disk for a rollback to read (the gate and fetch only
	// leave a download dir): the record starts at the backup step.
	if bridgesvc.record_done(rec, .Backup) || rec.step == bridgesvc.CONVERT_STEP_NAMES[.Backup] || rec.step == bridgesvc.CONVERT_STEP_NAMES[.Quiesce] || int(rec_step_index(rec)) >= int(bridgesvc.Convert_Step.Backup) {
		return bridge_convert_write_file(bridgesvc.conversion_path(s.layout), bridgesvc.encode_conversion(rec))
	}
	return true
}

@(private = "file")
rec_step_index :: proc(rec: Conversion_Record) -> bridgesvc.Convert_Step {
	step, _ := bridgesvc.convert_step_from_name(rec.step)
	return step
}

// ---- C1: the agent gate ---------------------------------------------------------------------

// bridge_convert_gate_wait: should this run wait (timer-started) or interrupt at once?
bridge_convert_gate_wait :: proc(s: ^Bridge_Setup) -> bool {
	switch strings.trim_space(option_value(s.args, "--convert-gate", "")) {
	case "wait": return true
	case "now": return false
	}
	return s.conv.seams.parent_is_worker(s)
}

// bridge_convert_gate_seconds is the Q3 wait (2 h). Test builds only: HEIMDALL_CONVERT_GATE_SECONDS
// shortens it so CI can reach the forced path (P2-7); a release build ignores the variable.
bridge_convert_gate_seconds :: proc() -> i64 {
	when service.TEST_BUILD {
		if n, ok := strconv.parse_i64(service.test_env(BRIDGE_CONVERT_TEST_GATE_ENV)); ok && n > 0 do return n
	}
	return bridgesvc.CONVERT_GATE_WAIT_SECONDS
}

bridge_convert_status_write :: proc(s: ^Bridge_Setup, st: bridgesvc.Gate_Status) {
	data, err := json.marshal(st, {spec = .JSON}, context.temp_allocator)
	if err == nil do _ = bridge_convert_write_file(bridgesvc.convert_status_path(s.layout), string(data))
}

// bridge_convert_persisted_force_at: the deadline a crashed or re-run setup must keep
// (the 2 h never reset). Only a status file written for a still-open gate counts.
bridge_convert_persisted_force_at :: proc(l: bridgesvc.Layout, now: i64) -> i64 {
	data, err := os.read_entire_file_from_path(bridgesvc.convert_status_path(l), context.temp_allocator)
	if err != nil do return 0
	st: bridgesvc.Gate_Status
	if json.unmarshal(data, &st, .JSON, context.temp_allocator) != nil do return 0
	if st.force_at <= 0 || st.force_at > now + bridgesvc.CONVERT_GATE_WAIT_SECONDS do return 0
	return st.force_at
}

bridge_convert_now_requested :: proc(s: ^Bridge_Setup, since: i64) -> bool {
	path := bridgesvc.convert_now_path(s.layout)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return false
	req: struct {
		requested_at: i64 `json:"requested_at"`,
	}
	if json.unmarshal(data, &req, .JSON, context.temp_allocator) != nil do return false
	if req.requested_at < since do return false
	_ = os.remove(path)
	return true
}

bridge_convert_gate :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	c := s.conv
	if rec.mode == bridgesvc.CONVERT_MODE_GREENFIELD do return {ok = true, message = "skipped"}
	start := bridge_convert_now_unix(s)
	c.gate_started = start
	if !bridge_convert_gate_wait(s) {
		// User-started: interrupt at once. C4 stops the profile's agents.
		if c.seams.agent_count(s) != 0 do c.forced = true
		return {ok = true, message = "agents (if any) are stopped now"}
	}
	force_at := bridge_convert_persisted_force_at(s.layout, start)
	if force_at == 0 do force_at = start + bridge_convert_gate_seconds()
	rec.force_at = force_at
	last_count, last_emit := -2, i64(0)
	for {
		if bridge_convert_is_cancelled(s) do return {failure = .Fatal, message = "cancelled while waiting for agents"}
		now := bridge_convert_now_unix(s)
		count := c.seams.agent_count(s)
		verdict := bridgesvc.gate_decide(now, force_at, count, bridge_convert_now_requested(s, start))
		switch verdict {
		case .Proceed:
			_ = os.remove(bridgesvc.convert_status_path(s.layout))
			return {ok = true, message = "no agents running" if count == 0 else "update now requested"}
		case .Force:
			c.forced = true
			_ = os.remove(bridgesvc.convert_status_path(s.layout))
			return {ok = true, message = fmt.tprintf("waited 2 h; stopping %d agent(s)", max(count, 0))}
		case .Wait:
			if count != last_count || now - last_emit >= 60 {
				st := bridgesvc.Gate_Status{state = "waiting", message = bridgesvc.gate_message(force_at - now, count), force_at = force_at, remaining_s = max(force_at - now, 0), agents = max(count, 0)}
				bridge_convert_status_write(s, st)
				bridge_setup_emit(s, bridgesvc.Event{step = "convert_gate", state = "progress", pct = bridgesvc.convert_pct(.Gate, false), message = st.message, attempt = 1})
				if s.json_progress do fmt.println(gate_event_json(st))
				last_count, last_emit = count, now
			}
			bridge_convert_sleep(s, 1000)
		}
	}
}

// gate_event_json is the countdown event with its machine fields (spec §9.2 item 3).
gate_event_json :: proc(st: bridgesvc.Gate_Status) -> string {
	return fmt.tprintf(`{{"step":"convert_gate","state":"waiting","message":%s,"force_at":%d,"remaining_s":%d,"agents":%d}}`, bridgesvc.json_quote(st.message), st.force_at, st.remaining_s, st.agents)
}

// ---- C2: fetch and verify -----------------------------------------------------------------------

bridge_convert_pins :: proc() -> []fetch.Public_Key {
	when BRIDGE_CONVERT_TEST_PINNED_KEY == "" {
		return nil // the embedded pins
	} else {
		embedded, err := fetch.pinned_keys()
		if err != nil do return nil
		out := make([dynamic]fetch.Public_Key, context.temp_allocator)
		for k in embedded do append(&out, k)
		k, kerr := fetch.parse_public_key(strings.concatenate({"untrusted comment: test key\n", BRIDGE_CONVERT_TEST_PINNED_KEY, "\n"}, context.temp_allocator))
		if kerr == nil do append(&out, k)
		return out[:]
	}
}

bridge_convert_rewrite_url :: proc(url: string) -> string {
	when service.TEST_BUILD {
		origin := service.test_env(BRIDGE_CONVERT_TEST_ORIGIN_ENV)
		if origin != "" {
			for len(origin) > 0 && origin[len(origin) - 1] == '/' do origin = origin[:len(origin) - 1]
			if strings.has_prefix(url, "https://github.com/") do return fmt.tprintf("%s/gh/%s", origin, url[len("https://github.com/"):])
		}
	}
	return url
}

// bridge_convert_download: GET into a scratch file (bounded), then hand it to the sink.
bridge_convert_download :: proc(user: rawptr, url: string, sink: fetch.Sink) -> (status: int) {
	scratch := (^string)(user)^
	u, uerr := httpc.parse_url(bridge_convert_rewrite_url(url))
	if uerr != .None do return 0
	_ = os.make_directory_all(scratch)
	tmp := fmt.tprintf("%s/net-%d.tmp", scratch, os.get_pid())
	defer os.remove(tmp)
	st, err := httpc.download_to_file({method = .GET, url = u, headers = {httpc.user_agent("ham-bridge-setup")}, timeout_ms = BRIDGE_CONVERT_DOWNLOAD_TIMEOUT_MS, stall_timeout_ms = BRIDGE_CONVERT_STALL_MS, max_response_bytes = int(BRIDGE_CONVERT_MAX_BUNDLE), max_redirects = 5}, tmp)
	if err != .None || st != 200 do return st if err == .None else 0
	f, ferr := os.open(tmp)
	if ferr != nil do return 0
	defer os.close(f)
	buf := make([]byte, 64 * 1024, context.temp_allocator)
	for {
		n, rerr := os.read(f, buf)
		if n > 0 && !sink.write(sink.user, buf[:n]) do return 0
		if rerr != nil || n == 0 do break
	}
	return st
}

// bridge_convert_fetch_real: spec §3.2. Manifest + signature from the siblings of the bundle
// (`<bundle>/../heimdall-release-manifest.json[.minisig]`), else the GitHub release
// download of this exact tag; verified with the pins compiled into this binary; the
// archive is downloaded to updates/convert-<txn>/ (or --bundle FILE is checked against
// the manifest). Nothing is changed outside the download dir.
bridge_convert_fetch_real :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> (rel: Convert_Release, code: string) {
	l := s.layout
	dir := bridgesvc.convert_download_dir(l, rec.txn)
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && !os.is_dir(dir) do return {}, "fs_error"
	scratch := strings.clone(dir, context.temp_allocator)
	d := fetch.Downloader{get = bridge_convert_download, user = &scratch}
	tag := strings.concatenate({"v", contracts.APP_VERSION}, context.temp_allocator)

	manifest_bytes, sig_bytes: []byte
	sibling_root := bridgesvc.pdir(bridgesvc.pdir(s.bundle_dir))
	sm, sm_err := os.read_entire_file_from_path(bridgesvc.pjoin(sibling_root, fetch.MANIFEST_ASSET), context.temp_allocator)
	ss, ss_err := os.read_entire_file_from_path(bridgesvc.pjoin(sibling_root, fetch.SIGNATURE_ASSET), context.temp_allocator)
	if sm_err == nil && ss_err == nil {
		manifest_bytes, sig_bytes = sm, ss
	} else {
		murl, e1 := fetch.asset_url(tag, fetch.MANIFEST_ASSET)
		surl, e2 := fetch.asset_url(tag, fetch.SIGNATURE_ASSET)
		if e1 != nil || e2 != nil do return {}, "manifest_mismatch"
		mb, e3 := fetch.download_small(d, murl, fetch.MAX_MANIFEST_BYTES)
		if e3 != nil do return {}, fetch.code_name(fetch.error_code(e3))
		sb, e4 := fetch.download_small(d, surl, fetch.MAX_SIGNATURE_BYTES)
		if e4 != nil do return {}, fetch.code_name(fetch.error_code(e4))
		manifest_bytes, sig_bytes = mb, sb
	}
	opts := fetch.Verify_Options{expected_tag = tag, now = time.to_unix_seconds(time.now()), check_expiry = true, pins = bridge_convert_pins()}
	m, verr := fetch.verify_manifest(manifest_bytes, sig_bytes, opts, context.temp_allocator)
	if verr != nil do return {}, fetch.code_name(fetch.error_code(verr))
	// min_engine_version of the manifest: manifests that claim an engine must carry every
	// field (engine §13.4); verify_manifest enforces the shape.
	if m.version != contracts.APP_VERSION do return {}, "manifest_mismatch"
	if m.min_engine < 1 || m.min_engine > engine.ENGINE_VERSION || m.min_launcher_abi < 0 || m.min_launcher_abi > lc.ABI {
		return {}, "manifest_incomplete" if m.min_engine < 1 else "engine_too_old"
	}
	if version_older(s.facts.installed_version, m.version) == false && !has_flag(s.args, bridgesvc.ALLOW_DOWNGRADE_FLAG) && s.facts.installed_version != "" {
		return {}, "downgrade_refused"
	}
	// Disk: the archive, its extraction cap and the legacy bin/ staying (spec §15.4).
	if s.conv.seams.free_bytes != nil {
		need := m.size + BRIDGE_CONVERT_ARCHIVE_SLACK
		if free := s.conv.seams.free_bytes(l.data_dir); free >= 0 && free < need do return {}, "disk_full"
	}
	mpath := bridgesvc.pjoin(dir, fetch.MANIFEST_ASSET)
	spath := bridgesvc.pjoin(dir, fetch.SIGNATURE_ASSET)
	if os.write_entire_file(mpath, manifest_bytes) != nil || os.write_entire_file(spath, sig_bytes) != nil do return {}, "fs_error"
	archive := strings.trim_space(option_value(s.args, "--bundle", ""))
	if archive != "" {
		if verr := fetch.verify_bundle_file(archive, &m); verr != nil do return {}, fetch.code_name(fetch.error_code(verr))
	} else {
		path, derr := fetch.download_bundle(d, &m, dir)
		if derr != nil do return {}, fetch.code_name(fetch.error_code(derr))
		archive = path
	}
	return Convert_Release{tag = tag, version = m.version, asset = m.asset, sha256 = m.sha256, archive = archive, manifest = mpath, signature = spath}, ""
}

@(private = "file")
version_older :: proc(installed, bundle: string) -> bool {
	if installed == "" do return true
	return bridgesvc.version_compare(installed, bundle) <= 0
}

bridge_convert_fetch :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	rel, code := s.conv.seams.fetch(s, rec)
	if code != "" {
		s.refusal = fmt.tprintf("Conversion of %s refused: %s; the previous install was not touched.", s.layout.service_name, code)
		s.exit_code = bridgesvc.EXIT_FAILED
		return {failure = .Fatal, message = fmt.tprintf("refused: %s", code)}
	}
	s.conv.release = rel
	rec.to_version = rel.version
	return {ok = true, message = fmt.tprintf("verified v%s (%s)", rel.version, rel.asset)}
}

// ---- C3: backup ---------------------------------------------------------------------------------------

bridge_convert_backup :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	l := s.layout
	dir := bridgesvc.convert_backup_dir(l, rec.txn)
	rec.backup = bridgesvc.pbase(dir)
	if err := os.make_directory_all(bridgesvc.pjoin(dir, "files"), {.Read_User, .Write_User, .Execute_User}); err != nil && !os.is_dir(dir) {
		return {failure = .Fatal, message = fmt.tprintf("cannot create %s: %v", dir, err)}
	}
	paths := bridgesvc.convert_backup_files(s.host, l)
	extra := bridgesvc.pjoin(l.state_dir, bridgesvc.UPDATE_FILE_NAME)
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..paths)
	append(&all, extra) // update.json: C5(e) seeds it; rollback deletes it unless it existed
	entries := make([dynamic]Backup_Entry, context.temp_allocator)
	for p, i in all {
		if bridgesvc.is_credential_name(bridgesvc.pbase(p)) do return {failure = .Fatal, message = fmt.tprintf("refusing to back up credential %s", p)}
		existed := os.is_file(p)
		if existed && os.copy_file(bridgesvc.pjoin(dir, "files", fmt.tprintf("%d", i)), p) != nil do return {failure = .Fatal, message = fmt.tprintf("cannot back up %s", p)}
		append(&entries, Backup_Entry{path = p, existed = existed, index = i})
	}
	s.conv.update_json_existed = os.is_file(extra)
	idx_data, err := json.marshal(Backup_Index{files = entries[:]}, {spec = .JSON}, context.temp_allocator)
	if err != nil || !bridge_convert_write_file(bridge_convert_backup_index_path(dir), string(idx_data)) do return {failure = .Fatal, message = "cannot write backup.json"}
	return {ok = true, message = fmt.tprintf("%d files", len(entries))}
}

// ---- C4: quiesce (rescuer, stop, state snapshot) ----------------------------------------------------------

Snapshot_File :: struct {
	root:    string `json:"root"`, // "data" | "state"
	path:    string `json:"path"`,
	present: bool   `json:"present"`,
	size:    i64    `json:"size"`,
	sha256:  string `json:"sha256"`,
	index:   int    `json:"index"`,
}

Snapshot_Index :: struct {
	files: []Snapshot_File `json:"files"`,
}

bridge_convert_store_root :: proc(l: bridgesvc.Layout, root: engine.State_Root) -> (string, string) {
	if root == .Data do return l.data_dir, "data"
	return l.state_dir, "state"
}

// bridge_convert_snapshot copies every store of the engine's registry (state_stores, engine
// §11.1) into <backup>/state/ with snapshot.json written last. Credentials never.
bridge_convert_snapshot :: proc(l: bridgesvc.Layout, backup_dir: string) -> (ok: bool, msg: string) {
	state_dir := bridgesvc.pjoin(backup_dir, "state")
	_ = os.remove(bridgesvc.pjoin(state_dir, engine.SNAPSHOT_JSON))
	files := make([dynamic]Snapshot_File, context.temp_allocator)
	total: i64
	collect :: proc(l: bridgesvc.Layout, root_name, base, rel: string, limit: i64, files: ^[dynamic]Snapshot_File, total: ^i64) -> (ok: bool, bytes: i64) {
		full := bridgesvc.pjoin(base, rel)
		if !os.exists(full) {
			append(files, Snapshot_File{root = root_name, path = rel, present = false})
			return true, 0
		}
		if !os.is_dir(full) {
			if bridgesvc.is_credential_name(bridgesvc.pbase(full)) do return true, 0
			info, err := os.stat(full, context.temp_allocator)
			if err != nil do return false, 0
			append(files, Snapshot_File{root = root_name, path = rel, present = true, size = info.size})
			return true, info.size
		}
		entries, err := os.read_directory_by_path(full, -1, context.temp_allocator)
		if err != nil do return false, 0
		sum: i64
		for e in entries {
			if e.type != .Directory && e.type != .Regular do continue
			ok2, n := collect(l, root_name, base, strings.concatenate({rel, "/", e.name}, context.temp_allocator), limit, files, total)
			if !ok2 do return false, 0
			sum += n
		}
		return true, sum
	}
	for st in engine.DEFAULT_STATE_STORES {
		base, root_name := bridge_convert_store_root(l, st.root)
		ok2, n := collect(l, root_name, base, st.path, st.max_bytes, &files, &total)
		if !ok2 do return false, fmt.tprintf("cannot read store %s", st.path)
		if n > st.max_bytes do return false, fmt.tprintf("store %s is %d bytes, over its limit %d", st.path, n, st.max_bytes)
		total += n
	}
	if total > engine.SNAPSHOT_TOTAL_CAP do return false, fmt.tprintf("state is %d bytes, over %d", total, engine.SNAPSHOT_TOTAL_CAP)
	_ = os.make_directory_all(bridgesvc.pjoin(state_dir, "files"))
	for &f, i in files {
		f.index = i
		if !f.present do continue
		base := l.data_dir if f.root == "data" else l.state_dir
		src := bridgesvc.pjoin(base, f.path)
		dst := bridgesvc.pjoin(state_dir, "files", fmt.tprintf("%d", i))
		if os.copy_file(dst, src) != nil do return false, fmt.tprintf("cannot copy %s", f.path)
		f.sha256 = bridge_convert_file_sha256(dst)
	}
	data, err := json.marshal(Snapshot_Index{files = files[:]}, {spec = .JSON}, context.temp_allocator)
	if err != nil do return false, "cannot encode snapshot.json"
	// Written last: without it the stores were never touched by the new runtime.
	if !bridge_convert_write_file(bridgesvc.pjoin(state_dir, engine.SNAPSHOT_JSON), string(data)) do return false, "cannot write snapshot.json"
	return true, fmt.tprintf("%d store files", len(files))
}

bridge_convert_quiesce :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	c := s.conv
	l := s.layout
	if rec.mode == bridgesvc.CONVERT_MODE_GREENFIELD do return {ok = true, message = "skipped"}
	// C4a: the rescuer first, so a killed setup never leaves the bridge down.
	if !c.seams.spawn_rescuer(s, rec^) do bridge_setup_emit(s, bridgesvc.Event{step = "convert_quiesce", state = "warning", message = "the rescuer did not start; a killed setup is only recovered by the next run", attempt = 1})
	if rec.was_running {
		s.stopped_for_setup = true
		if ok, msg := c.seams.service_stop(s); !ok do return {failure = .Fatal, message = fmt.tprintf("cannot stop the previous Bridge: %s", msg)}
	}
	if ok, msg := c.seams.pty_stop(s); !ok do return {failure = .Fatal, message = fmt.tprintf("PTY host not stopped: %s", msg)}
	// The tray keeps running from bin/ in Phase 2 (spec §4.2); Windows setup stops it as before.
	if s.host.os == .Windows && bridge_tray_stop(s.host, l) do s.tray_stopped = true
	ok, msg := bridge_convert_snapshot(l, bridgesvc.convert_backup_dir(l, rec.txn))
	if !ok do return {failure = .Fatal, message = msg}
	return {ok = true, message = fmt.tprintf("stopped; state snapshot: %s", msg)}
}

// ---- C5: instance record, tree, launcher ----------------------------------------------------------------

bridge_convert_tree :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	c := s.conv
	l := s.layout
	rel := c.release
	// (a) instance.json: textual layout strings, fresh id (or the id of an earlier try).
	if rec.instance_id == "" do rec.instance_id = bridgesvc.new_instance_id()
	text := bridgesvc.encode_instance_record(rec.instance_id, l.service_name, s.profile.hub_url, s.profile.profile, c.seams.owner_json(), l.data_dir, l.state_dir, bridge_convert_now_unix(s))
	if !bridge_convert_write_file(bridgesvc.pjoin(l.data_dir, "instance.json"), text) do return {failure = .Fatal, message = "cannot write instance.json"}
	// (b) the bundle's own repair.
	code, out := c.seams.repair(s, rel, rec^)
	if code != 0 do return {failure = .Fatal, message = fmt.tprintf("ham-supervisor repair exited %d: %s", code, out)}
	tree, ok := lc.read_pointer(l.data_dir, lc.POINTER_CURRENT)
	if !ok || tree == "" do return {failure = .Fatal, message = "repair did not set the current pointer"}
	rec.to_tree = strings.clone(tree, context.temp_allocator)
	s.enroll_exe = bridgesvc.pjoin(l.data_dir, "releases", tree, lc.TREE_BIN_DIR, bridgesvc.exe_name(s.host, "ham-bridge"))
	// (c) the setup that converts is the setup that was signed.
	tree_bridge := bridgesvc.pjoin(l.data_dir, "releases", tree, lc.TREE_BIN_DIR, bridgesvc.exe_name(s.host, "ham-bridge"))
	if mine := c.seams.self_sha256(s); mine == "" || mine != bridge_convert_file_sha256(tree_bridge) {
		return {failure = .Fatal, message = "bundle_mismatch: this ham-bridge is not the tree's ham-bridge"}
	}
	// (d) the launcher: only setup writes it (engine D8).
	src := bridgesvc.pjoin(l.data_dir, "releases", tree, lc.TREE_BIN_DIR, bridgesvc.exe_name(s.host, "ham-launcher"))
	dst := bridgesvc.launcher_path(s.host, l)
	_ = os.make_directory_all(bridgesvc.pdir(dst))
	if os.copy_file(dst, src) != nil do return {failure = .Fatal, message = "cannot install launcher/ham-launcher"}
	_ = os.chmod(dst, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	lj := fmt.tprintf(`{{"abi":%d,"version":%s,"sha256":%s}}`+"\n", lc.ABI, bridgesvc.json_quote(rel.version), bridgesvc.json_quote(bridge_convert_file_sha256(dst)))
	if !bridge_convert_write_file(bridgesvc.pjoin(l.data_dir, "launcher", "launcher.json"), lj) do return {failure = .Fatal, message = "cannot write launcher.json"}
	// (e) update.json from the legacy opt-out (spec §11.3).
	if !bridge_convert_seed_settings(s, rec^) do return {failure = .Fatal, message = "cannot write update.json"}
	return {ok = true, message = fmt.tprintf("tree %s", tree)}
}

bridge_convert_legacy_auto_update :: proc(l: bridgesvc.Layout) -> bool {
	data, err := os.read_entire_file_from_path(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE), context.temp_allocator)
	if err != nil do return true
	in_bridge := false
	for line in strings.split_lines(string(data), context.temp_allocator) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") do in_bridge = t == "[bridge]"
		if in_bridge && strings.has_prefix(t, "auto_update_enabled") {
			eq := strings.index_byte(t, '=')
			if eq >= 0 do return strings.trim_space(t[eq + 1:]) != "false"
		}
	}
	return true
}

bridge_convert_seed_settings :: proc(s: ^Bridge_Setup, rec: Conversion_Record) -> bool {
	st := service.Settings{channel = "stable", auto_update = bridge_convert_legacy_auto_update(s.layout), revision = 1, actor = "conversion", updated_at = bridge_convert_now_unix(s), last_op = rec.op_id}
	return bridge_convert_write_file(bridgesvc.pjoin(s.layout.state_dir, service.UPDATE_FILE), service.encode_settings(st))
}

// ---- C6: service cut-over ------------------------------------------------------------------------------------

bridge_convert_render_input :: proc(s: ^Bridge_Setup, rec: Conversion_Record, converting: bool) -> bridgesvc.Render_Input {
	in_ := bridge_setup_render_input(s)
	in_.converted = true
	in_.converting = converting
	in_.instance_id = rec.instance_id
	if s.host.os == .Windows && s.conv != nil do in_.windows_sid = s.conv.seams.windows_sid()
	return in_
}

bridge_convert_cutover :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	// Greenfield has no legacy files: config.toml, hub-url, profile and ports.json are
	// written here (kept as they are for a conversion), backed up as "did not exist".
	if r := bridge_setup_run(s, .Config); !r.ok do return r
	if r := bridge_setup_run(s, .Ports); !r.ok do return r
	return s.conv.seams.register(s, rec^, rec.mode != bridgesvc.CONVERT_MODE_GREENFIELD)
}

bridge_convert_register_real :: proc(s: ^Bridge_Setup, rec: Conversion_Record, converting: bool) -> bridgesvc.Step_Result {
	l := s.layout
	in_ := bridge_convert_render_input(s, rec, converting)
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "logs"))
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "run"))
	// The ctl wrapper execs the tree's ham-ctl (spec §8.3); the supervisor keeps it current.
	if tree := rec.to_tree; tree != "" {
		wrapper := bridgesvc.ctl_wrapper_path(s.host, l)
		text := bridgesvc.render_ctl_wrapper_for_tree(s.host, l, in_, bridgesvc.pjoin(l.data_dir, "releases", tree, lc.TREE_BIN_DIR, bridgesvc.exe_name(s.host, "ham-ctl")))
		_ = os.make_directory_all(l.bin_dir)
		if !bridge_convert_write_file(wrapper, text, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) do return {failure = .Fatal, message = "cannot write the ham-ctl wrapper"}
		_ = os.chmod(wrapper, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	}
	#partial switch l.backend {
	case .Systemd, .Launchd:
		_ = os.make_directory_all(bridgesvc.pdir(l.service_file))
		if !bridge_convert_write_file(l.service_file, bridgesvc.render_service_file(s.host, l, in_), {.Read_User, .Write_User, .Read_Group, .Read_Other}) {
			return {failure = .Fatal, message = fmt.tprintf("cannot write %s", l.service_file)}
		}
		if l.backend == .Systemd {
			if ok, out := bridge_service_exec({"systemctl", "--user", "daemon-reload"}); !ok do return {failure = .Fatal, message = fmt.tprintf("systemctl daemon-reload: %s", out)}
			_, _ = bridge_service_exec({"systemctl", "--user", "enable", strings.concatenate({l.service_name, ".service"}, context.temp_allocator)})
		}
	case .Schtasks:
		cmd := bridgesvc.windows_launcher_cmd_path(l)
		vbs := bridgesvc.windows_launcher_vbs_path(l)
		xml := bridgesvc.windows_launcher_task_xml_path(l)
		if !bridge_convert_write_file(cmd, bridgesvc.render_windows_run_cmd(s.host, l, in_)) || !bridge_convert_write_file(vbs, bridgesvc.render_windows_launcher_converted(l)) || !bridge_convert_write_file(xml, bridgesvc.render_service_file(s.host, l, in_)) {
			return {failure = .Fatal, message = "cannot write the launcher task files"}
		}
		new_tn := strings.concatenate({"\\", bridgesvc.windows_task_name(l.service_name, in_.windows_sid, rec.instance_id)}, context.temp_allocator)
		if ok, out := bridge_service_exec({"schtasks", "/Create", "/TN", new_tn, "/XML", xml, "/F"}); !ok do return {failure = .Fatal, message = fmt.tprintf("schtasks /Create: %s", out)}
		// Disabled, never ended: the legacy worker and this setup live in that task's job.
		_, _ = bridge_service_exec({"schtasks", "/Change", "/TN", strings.concatenate({"\\", l.service_name}, context.temp_allocator), "/DISABLE"})
	case:
		return {failure = .Fatal, message = "no supported service manager"}
	}
	s.service_action = "registered"
	return {ok = true, message = fmt.tprintf("%s rendered for the launcher", bridgesvc.backend_name(l.backend))}
}

// ---- C7/C8: start and verify ---------------------------------------------------------------------------------------

bridge_convert_start :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	l := s.layout
	s.stale_pid = 0
	if rt, ok := bridgesvc.read_runtime_status(l.state_dir); ok do s.stale_pid = rt.pid
	s.restart_at = bridge_convert_now_unix(s)
	if ok, msg := s.conv.seams.service_start(s); !ok do return {failure = .Fatal, message = fmt.tprintf("service %s failed: %s", bridgesvc.backend_name(l.backend), msg)}
	return {ok = true}
}

// bridge_convert_journal_state: the last journaled state of op_id ("" = none).
bridge_convert_journal_state :: proc(l: bridgesvc.Layout, op_id: string) -> (state, note: string) {
	r := engine.read_journal_file(bridgesvc.pjoin(l.data_dir, "supervisor", engine.JOURNAL_DIR, engine.JOURNAL_FILE), context.temp_allocator)
	for line in r.lines {
		if line.op_id == op_id {
			state, note = line.state, line.note
			if state == "failed" || state == "rollback_failed" do note = line.error
		}
	}
	return
}

bridge_convert_committed :: proc(l: bridgesvc.Layout, op_id: string) -> bool {
	state, _ := bridge_convert_journal_state(l, op_id)
	if state != "committed" do return false
	data, err := os.read_entire_file_from_path(bridgesvc.pjoin(l.data_dir, "known-good.json"), context.temp_allocator)
	if err != nil do return false
	kg: struct {
		committed_op: string `json:"committed_op"`,
	}
	return json.unmarshal(data, &kg, .JSON, context.temp_allocator) == nil && kg.committed_op == op_id
}

bridge_convert_verify :: proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	c := s.conv
	l := s.layout
	deadline := bridge_convert_now_unix(s) + bridgesvc.CONVERT_COMMIT_TIMEOUT_SECONDS
	last_state := ""
	for {
		if bridge_convert_is_cancelled(s) do return {failure = .Fatal, message = "cancelled while waiting for the commit"}
		if bridge_convert_committed(l, rec.op_id) do break
		state, note := bridge_convert_journal_state(l, rec.op_id)
		if state != last_state && state != "" {
			last_state = state
			bridge_setup_emit(s, bridgesvc.Event{step = "convert_commit", state = "progress", pct = bridgesvc.convert_pct(.Verify, false), message = state, attempt = 1})
		}
		if state == "failed" || state == "rolling_back" || state == "rollback_failed" {
			return {failure = .Fatal, message = fmt.tprintf("the supervisor's journal says %s %s", state, note), log = bridgesvc.pjoin(l.data_dir, "supervisor", "journal")}
		}
		if bridge_convert_launcher_refused(l) do return {failure = .Fatal, message = "the launcher refused to start the supervisor (launcher-status.json)"}
		if !c.seams.service_running(s) && bridge_convert_now_unix(s) - s.restart_at > 5 do return {failure = .Fatal, message = "the service is not running"}
		if bridge_convert_now_unix(s) >= deadline do return {failure = .Fatal, message = fmt.tprintf("the supervisor did not commit within %d s (journal: %s)", bridgesvc.CONVERT_COMMIT_TIMEOUT_SECONDS, last_state if last_state != "" else "no entry")}
		bridge_convert_sleep(s, 500)
	}
	if !rec.was_connected do return {ok = true, message = "committed (the bridge was offline before; the hub connection is not required)"}
	until := bridge_convert_now_unix(s) + i64(BRIDGE_SETUP_VERIFY_TIMEOUT / time.Second)
	for bridge_convert_now_unix(s) < until {
		if c.seams.service_connected(s) do return {ok = true, message = "committed and connected"}
		bridge_convert_sleep(s, 500)
	}
	return {failure = .Fatal, message = "committed, but the bridge did not connect to the hub in time", log = bridgesvc.pjoin(l.data_dir, "logs", "bridge.err.log")}
}

bridge_convert_launcher_refused :: proc(l: bridgesvc.Layout) -> bool {
	data, err := os.read_entire_file_from_path(bridgesvc.pjoin(l.data_dir, "launcher-status.json"), context.temp_allocator)
	if err != nil do return false
	st: struct {
		state: string `json:"state"`,
	}
	return json.unmarshal(data, &st, .JSON, context.temp_allocator) == nil && st.state == "refused"
}

// ---- C9: finalize (idempotent, runnable without setup) --------------------------------------------------------------------

bridge_convert_finalize :: proc(s: ^Bridge_Setup, rec: Conversion_Record) -> bridgesvc.Step_Result {
	l := s.layout
	if s.conv != nil && s.conv.seams.os_finalize != nil {
		if ok, msg := s.conv.seams.os_finalize(s, rec); !ok do return {failure = .Fatal, message = msg}
	}
	if s.conv != nil && s.conv.seams.stop_rescuer != nil do s.conv.seams.stop_rescuer(s, rec)
	_ = os.remove_all(bridgesvc.convert_download_dir(l, rec.txn))
	_ = os.remove_all(bridgesvc.convert_backup_dir(l, rec.txn))
	_ = os.remove(bridgesvc.convert_status_path(l))
	_ = os.remove(bridgesvc.conversion_path(l))
	return {ok = true, message = fmt.tprintf("converted to v%s", rec.to_version)}
}

// bridge_convert_os_finalize_real: Linux flips KillMode to control-group (no restart);
// Windows deletes the old, disabled task; macOS has nothing to do.
bridge_convert_os_finalize_real :: proc(s: ^Bridge_Setup, rec: Conversion_Record) -> (bool, string) {
	l := s.layout
	#partial switch l.backend {
	case .Systemd:
		in_ := bridge_convert_render_input(s, rec, false)
		if ports, ok := bridgesvc.read_ports(l.state_dir); ok do s.ports = ports
		in_.bridge_port, in_.endpoint_port = s.ports[0], s.ports[1]
		if !bridge_convert_write_file(l.service_file, bridgesvc.render_service_file(s.host, l, in_), {.Read_User, .Write_User, .Read_Group, .Read_Other}) do return false, "cannot rewrite the unit"
		if ok, out := bridge_service_exec({"systemctl", "--user", "daemon-reload"}); !ok do return false, fmt.tprintf("systemctl daemon-reload: %s", out)
	case .Schtasks:
		_, _ = bridge_service_exec({"schtasks", "/Delete", "/TN", strings.concatenate({"\\", l.service_name}, context.temp_allocator), "/F"})
	}
	return true, ""
}

// ---- rollback R1-R6 ----------------------------------------------------------------------------------------------------------

bridge_convert_wait_stopped :: proc(s: ^Bridge_Setup, timeout: time.Duration) -> bool {
	deadline := bridge_convert_now_unix(s) + i64(timeout / time.Second)
	for {
		if !s.conv.seams.service_running(s) do return true
		if bridge_convert_now_unix(s) >= deadline do return false
		bridge_convert_sleep(s, 200)
	}
}

bridge_convert_rollback :: proc(data: rawptr, step: bridgesvc.Rollback_Step, rec: Conversion_Record) -> (ok: bool, msg: string) {
	s := (^Bridge_Setup)(data)
	c := s.conv
	l := s.layout
	backup := bridgesvc.convert_backup_dir(l, rec.txn)
	switch step {
	case .Stop_New:
		// Only when a new service could be running: cut-over done or begun.
		started := bridgesvc.record_done(rec, .Cutover) || rec.step == bridgesvc.CONVERT_STEP_NAMES[.Cutover] || int(rec_step_index(rec)) > int(bridgesvc.Convert_Step.Cutover)
		if !started do return true, "never started"
		stop_file := bridgesvc.launcher_stop_request_path(l)
		_ = os.make_directory_all(bridgesvc.pdir(stop_file))
		_ = bridge_convert_write_file(stop_file, bridgesvc.render_launcher_stop_request(rec.instance_id, bridge_convert_now_unix(s)))
		if !bridge_convert_wait_stopped(s, BRIDGE_CONVERT_STOP_WAIT) {
			if sok, smsg := c.seams.service_stop(s); !sok do return false, smsg
			if !bridge_convert_wait_stopped(s, BRIDGE_CONVERT_STOP_WAIT) do return false, "the new service did not stop"
		}
		return true, "stopped"
	case .Restore_Service:
		if !bridgesvc.record_done(rec, .Backup) && !os.is_dir(backup) do return true, "nothing backed up"
		idx, have := bridge_convert_read_backup_index(backup)
		if !have do return true, "no backup index"
		for e in idx.files {
			if !strings.has_prefix(e.path, l.service_file) && e.path != l.service_file && !bridge_convert_is_service_path(s, e.path) do continue
			if bridge_convert_restore_one(backup, e) == false do return false, fmt.tprintf("cannot restore %s", e.path)
		}
		return c.seams.os_restore_service(s, rec)
	case .Restore_Settings:
		idx, have := bridge_convert_read_backup_index(backup)
		if have {
			for e in idx.files {
				if bridge_convert_is_service_path(s, e.path) do continue
				if !bridge_convert_restore_one(backup, e) do return false, fmt.tprintf("cannot restore %s", e.path)
			}
		}
		if ok2, m := bridge_convert_restore_state(l, backup, rec.txn); !ok2 do return false, m
		bridge_extensions_restore(l.data_dir)
		return true, "restored"
	case .Remove_Layout:
		// Keep the supervisor's journal for diagnosis (one, the older is deleted).
		if os.is_dir(bridgesvc.pjoin(l.data_dir, "supervisor")) {
			kept := bridgesvc.pjoin(l.data_dir, strings.concatenate({"conversion-failed-", rec.txn}, context.temp_allocator))
			_ = bridge_convert_copy_tree(bridgesvc.pjoin(l.data_dir, "supervisor", engine.JOURNAL_DIR), bridgesvc.pjoin(kept, "journal"))
			_ = bridge_convert_copy_file_if(bridgesvc.pjoin(l.data_dir, "launcher-status.json"), bridgesvc.pjoin(kept, "launcher-status.json"))
			bridge_convert_prune_failed(l, rec.txn)
		}
		if failed := bridgesvc.remove_created_layout(l.data_dir); failed != "" {
			// Windows: an open file; rename aside and leave it to GC.
			aside := strings.concatenate({failed, ".stale-", rec.txn}, context.temp_allocator)
			if os.rename(failed, aside) != nil do return false, fmt.tprintf("cannot remove %s", failed)
			if failed2 := bridgesvc.remove_created_layout(l.data_dir); failed2 != "" do return false, fmt.tprintf("cannot remove %s", failed2)
		}
		return true, "removed"
	case .Restart_Old:
		if !rec.was_running do return true, "was not running"
		if !c.seams.service_running(s) {
			if sok, smsg := c.seams.service_start(s); !sok do return false, fmt.tprintf("previous Bridge could not be restarted: %s", smsg)
		}
		if got := c.seams.old_version(s); rec.from_version != "" && got != "" && bridgesvc.version_compare(got, rec.from_version) != 0 {
			return false, fmt.tprintf("bin/ham-bridge reports v%s, expected v%s", got, rec.from_version)
		}
		if !c.seams.service_running(s) do return false, "the previous Bridge is not running"
		if rec.was_connected {
			until := bridge_convert_now_unix(s) + i64(BRIDGE_SETUP_VERIFY_TIMEOUT / time.Second)
			for !c.seams.service_connected(s) {
				if bridge_convert_now_unix(s) >= until do return false, "the previous Bridge did not reconnect"
				bridge_convert_sleep(s, 500)
			}
		}
		return true, "restarted"
	case .Close:
		c.seams.stop_rescuer(s, rec)
		_ = os.remove_all(backup)
		_ = os.remove_all(bridgesvc.convert_download_dir(l, rec.txn))
		_ = os.remove(bridgesvc.convert_status_path(l))
		_ = os.remove(bridgesvc.conversion_path(l))
		return true, "closed"
	}
	return true, ""
}

bridge_convert_is_service_path :: proc(s: ^Bridge_Setup, path: string) -> bool {
	l := s.layout
	if l.backend == .Schtasks {
		return path == bridgesvc.windows_run_cmd_path(l) || path == bridgesvc.windows_launcher_path(l) || path == bridgesvc.pjoin(l.data_dir, "task.xml")
	}
	return path == l.service_file
}

// bridge_convert_restore_one: put a backed-up file back (atomic replace) or delete a
// file that did not exist before the transaction.
bridge_convert_restore_one :: proc(backup_dir: string, e: Backup_Entry) -> bool {
	if !e.existed {
		_ = os.remove(e.path)
		return !os.exists(e.path)
	}
	data, err := os.read_entire_file_from_path(bridgesvc.pjoin(backup_dir, "files", fmt.tprintf("%d", e.index)), context.temp_allocator)
	if err != nil do return false
	mode := os.Permissions{.Read_User, .Write_User}
	if strings.contains(e.path, "ham-ctl-") do mode += {.Execute_User, .Execute_Group, .Execute_Other, .Read_Group, .Read_Other}
	if !bridge_convert_write_file(e.path, string(data), mode) do return false
	if strings.contains(e.path, "ham-ctl-") do _ = os.chmod(e.path, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	return true
}

bridge_convert_copy_file_if :: proc(src, dst: string) -> bool {
	if !os.is_file(src) do return false
	_ = os.make_directory_all(bridgesvc.pdir(dst))
	return os.copy_file(dst, src) == nil
}

bridge_convert_prune_failed :: proc(l: bridgesvc.Layout, keep_txn: string) {
	entries, err := os.read_directory_by_path(l.data_dir, -1, context.temp_allocator)
	if err != nil do return
	for e in entries {
		if strings.has_prefix(e.name, "conversion-failed-") && e.name != strings.concatenate({"conversion-failed-", keep_txn}, context.temp_allocator) {
			_ = os.remove_all(bridgesvc.pjoin(l.data_dir, e.name))
		}
	}
}

// bridge_convert_restore_state (R3): every store of the C4b snapshot back by atomic
// replace, whether or not the new runtime ran; files the new runtime added to a store
// directory are deleted. Never credentials.
bridge_convert_restore_state :: proc(l: bridgesvc.Layout, backup_dir, txn: string) -> (ok: bool, msg: string) {
	snap_dir := bridgesvc.pjoin(backup_dir, "state")
	data, err := os.read_entire_file_from_path(bridgesvc.pjoin(snap_dir, engine.SNAPSHOT_JSON), context.temp_allocator)
	if err != nil do return true, "no complete snapshot: the stores were never touched by the new runtime"
	idx: Snapshot_Index
	if json.unmarshal(data, &idx, .JSON, context.temp_allocator) != nil do return false, "snapshot.json is unreadable"
	wanted := make(map[string]bool, context.temp_allocator)
	for f in idx.files {
		base := l.data_dir if f.root == "data" else l.state_dir
		dst := bridgesvc.pjoin(base, f.path)
		if !f.present do continue
		src := bridgesvc.pjoin(snap_dir, "files", fmt.tprintf("%d", f.index))
		if bridge_convert_file_sha256(src) != f.sha256 do return false, fmt.tprintf("snapshot copy of %s is corrupt", f.path)
		wanted[bridgesvc.path_key(dst)] = true
		tmp := strings.concatenate({dst, ".restore-", txn}, context.temp_allocator)
		_ = os.make_directory_all(bridgesvc.pdir(dst))
		if os.copy_file(tmp, src) != nil do return false, fmt.tprintf("cannot restore %s", f.path)
		if os.rename(tmp, dst) != nil {
			_ = os.remove(dst)
			if os.rename(tmp, dst) != nil do return false, fmt.tprintf("cannot replace %s", f.path)
		}
	}
	for st in engine.DEFAULT_STATE_STORES {
		base, _ := bridge_convert_store_root(l, st.root)
		full := bridgesvc.pjoin(base, st.path)
		// A store that was absent, or files the new runtime added, are removed.
		absent := true
		for f in idx.files do if f.path == st.path && f.present do absent = false
		if os.is_dir(full) || os.is_file(full) {
			bridge_convert_remove_extras(full, wanted, absent)
		}
	}
	return true, "restored"
}

bridge_convert_remove_extras :: proc(path: string, wanted: map[string]bool, remove_all_if_unwanted: bool) {
	if os.is_dir(path) {
		entries, err := os.read_directory_by_path(path, -1, context.temp_allocator)
		if err != nil do return
		for e in entries do bridge_convert_remove_extras(bridgesvc.pjoin(path, e.name), wanted, remove_all_if_unwanted)
		return
	}
	if bridgesvc.is_credential_name(bridgesvc.pbase(path)) do return
	if !(bridgesvc.path_key(path) in wanted) do _ = os.remove(path)
}

// ---- the driver: setup's Lock step runs the transaction ----------------------------------------------------------------------

bridge_convert_run_step :: proc(data: rawptr, step: bridgesvc.Convert_Step, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	s := (^Bridge_Setup)(data)
	r := bridge_convert_run_step_inner(s, step, rec)
	when service.TEST_BUILD {
		if r.ok do r = bridge_convert_test_inject(step, r)
	}
	if r.ok && s.conv.fail_after != nil {
		if msg := s.conv.fail_after(s, step); msg != "" do return {failure = .Fatal, message = msg}
	}
	return r
}

bridge_convert_run_step_inner :: proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step, rec: ^Conversion_Record) -> bridgesvc.Step_Result {
	c := s.conv
	switch step {
	case .Gate: return bridge_convert_gate(s, rec)
	case .Fetch: return bridge_convert_fetch(s, rec)
	case .Backup: return bridge_convert_backup(s, rec)
	case .Quiesce: return bridge_convert_quiesce(s, rec)
	case .Tree: return bridge_convert_tree(s, rec)
	case .Cutover: return bridge_convert_cutover(s, rec)
	case .Enroll: return c.seams.enroll(s)
	case .Extensions: return c.seams.extensions(s)
	case .Start: return bridge_convert_start(s, rec)
	case .Verify: return bridge_convert_verify(s, rec)
	case .Finalize: return bridge_convert_finalize(s, rec^)
	}
	return {failure = .Fatal, message = "unknown step"}
}

bridge_convert_emit :: proc(data: rawptr, ev: bridgesvc.Event) {
	bridge_setup_emit(data, ev)
}

bridge_convert_cancelled :: proc(data: rawptr) -> bool {
	return bridge_convert_is_cancelled((^Bridge_Setup)(data))
}

bridge_convert_is_cancelled :: proc(s: ^Bridge_Setup) -> bool {
	return s.conv.cancel || bridge_convert_signalled
}

bridge_convert_ops :: proc(s: ^Bridge_Setup) -> bridgesvc.Convert_Ops {
	return {data = s, run = bridge_convert_run_step, persist = bridge_convert_persist, rollback = bridge_convert_rollback, emit = bridge_convert_emit, cancelled = bridge_convert_cancelled}
}

bridge_convert_init_record :: proc(s: ^Bridge_Setup) -> Conversion_Record {
	l := s.layout
	txn := bridgesvc.new_txn_id()
	rec := bridgesvc.Conversion_Record {
		txn           = txn,
		mode          = bridgesvc.CONVERT_MODE_GREENFIELD if s.plan.greenfield else bridgesvc.CONVERT_MODE_CONVERT,
		service       = l.service_name,
		from_version  = bridgesvc.normalize_version(s.facts.installed_version),
		to_version    = bridgesvc.normalize_version(s.facts.bundle_version),
		op_id         = strings.concatenate({"op_convert_", txn}, context.temp_allocator),
		backup        = bridgesvc.pbase(bridgesvc.convert_backup_dir(l, txn)),
		was_running   = s.facts.running && !s.plan.greenfield,
		was_connected = false,
		started_at    = bridge_convert_now_unix(s),
		step          = "",
		state         = "",
		phase         = bridgesvc.CONVERT_PHASE_FORWARD,
	}
	if !s.plan.greenfield && rec.was_running {
		st := bridge_service_status(s.host, l.service_name)
		rec.was_connected = st.connected
	}
	return rec
}

// bridge_convert_run runs the whole transaction (C1-C9) from setup's Lock step. It owns its
// own rollback; the outcome lands in s.exit_code / s.refusal / s.rollback_failed.
bridge_convert_run :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	c := s.conv
	c.rec = bridge_convert_init_record(s)
	ops := bridge_convert_ops(s)
	res := bridgesvc.run_conversion(ops, &c.rec)
	return bridge_convert_result(s, res)
}

bridge_convert_result :: proc(s: ^Bridge_Setup, res: bridgesvc.Convert_Result) -> bridgesvc.Step_Result {
	c := s.conv
	switch {
	case res.ok:
		if res.finalize_warning != "" do append(&s.recovered, fmt.tprintf("C9 will finish at the next start (%s)", res.finalize_warning))
		return {ok = true, finished = true, message = fmt.tprintf("converted to v%s", c.rec.to_version)}
	case res.halted:
		// Greenfield S1a: installed, not enrolled, not started (exit 4 on a re-run path).
		s.not_enrolled = "enrollment was not approved or did not complete"
		_ = os.remove_all(bridgesvc.convert_download_dir(s.layout, c.rec.txn))
		_ = os.remove_all(bridgesvc.convert_backup_dir(s.layout, c.rec.txn))
		_ = os.remove(bridgesvc.conversion_path(s.layout))
		return {halt = true, message = fmt.tprintf("not enrolled: %s", s.not_enrolled)}
	case res.rollback_failed:
		bridge_setup_rollback_fail(s, res.rollback_message)
		s.fail_line = fmt.tprintf("ham-bridge setup FAILED at step %q; rollback incomplete: %s.", bridgesvc.CONVERT_STEP_EVENT[res.failed_step], res.rollback_message)
		s.exit_code = bridgesvc.EXIT_ROLLBACK_INCOMPLETE
		return {failure = .Fatal, message = fmt.tprintf("%s; rollback incomplete: %s", res.message, res.rollback_message)}
	}
	if s.exit_code == 0 do s.exit_code = bridgesvc.EXIT_FAILED
	if s.refusal == "" && res.rolled_back {
		s.fail_line = fmt.tprintf("ham-bridge setup FAILED at step %q; the previous install was restored%s.", bridgesvc.CONVERT_STEP_EVENT[res.failed_step], " and restarted" if c.rec.was_running else "")
	}
	return {failure = .Fatal, message = res.message}
}

// bridge_convert_recover handles a leftover conversion.json under the install lock (§6.3).
// Returns the recovery note; `ok` false = the rollback is incomplete (exit 7).
bridge_convert_recover :: proc(s: ^Bridge_Setup) -> (note: string, ok: bool) {
	l := s.layout
	rec, present, readable := bridge_convert_read_record(l)
	if !present do return "", true
	if s.conv == nil do s.conv = bridge_convert_new_state()
	if !readable {
		// Case 4: unreadable record. Without it only the backup dir can say what to restore.
		rec = bridge_convert_record_from_disk(s)
	}
	s.conv.rec = rec
	// Roll-forward may run C6b (enroll) with the tree's binary, never bin/'s.
	if rec.to_tree != "" do s.enroll_exe = bridgesvc.pjoin(l.data_dir, "releases", rec.to_tree, lc.TREE_BIN_DIR, bridgesvc.exe_name(s.host, "ham-bridge"))
	ops := bridge_convert_ops(s)
	action, res := bridgesvc.recover_conversion(ops, &s.conv.rec, bridge_convert_layout_ok(s.host, l))
	switch {
	case res.rollback_failed:
		return fmt.tprintf("recovery of an interrupted conversion failed: %s", res.rollback_message), false
	case res.ok:
		return "completed an interrupted conversion", true
	case res.rolled_back:
		return "rolled back an interrupted conversion to the legacy install", true
	}
	_ = action
	return fmt.tprintf("an interrupted conversion could not be completed: %s", res.message), false
}

// bridge_convert_record_from_disk rebuilds the minimum rollback needs from the layout
// when conversion.json is unreadable: the backup dir names the txn.
bridge_convert_record_from_disk :: proc(s: ^Bridge_Setup) -> Conversion_Record {
	l := s.layout
	rec := Conversion_Record{mode = bridgesvc.CONVERT_MODE_CONVERT, phase = bridgesvc.CONVERT_PHASE_ROLLING_BACK, service = l.service_name, done = []string{"C1", "C2", "C3", "C4", "C5", "C6"}}
	entries, _ := os.read_directory_by_path(l.data_dir, -1, context.temp_allocator)
	for e in entries {
		if strings.has_prefix(e.name, bridgesvc.CONVERT_BACKUP_PREFIX) && bridgesvc.valid_txn(e.name[len(bridgesvc.CONVERT_BACKUP_PREFIX):]) {
			rec.txn = strings.clone(e.name[len(bridgesvc.CONVERT_BACKUP_PREFIX):], context.temp_allocator)
			rec.backup = e.name
		}
	}
	rec.was_running = true
	if r, ok := lc.read_instance_record(l.data_dir, context.temp_allocator); ok == "" do rec.instance_id = r.instance_id
	if rec.txn == "" do rec.txn = bridgesvc.new_txn_id()
	return rec
}

// bridge_convert_test_inject: the real-process failure hooks (see BRIDGE_CONVERT_TEST_FAIL_ENV).
when service.TEST_BUILD {
	bridge_convert_test_inject :: proc(step: bridgesvc.Convert_Step, r: bridgesvc.Step_Result) -> bridgesvc.Step_Result {
		name := bridgesvc.CONVERT_STEP_NAMES[step]
		if service.test_env(BRIDGE_CONVERT_TEST_KILL_ENV) == name {
			fmt.eprintfln("ham-bridge setup: test hook: abrupt exit after %s", name)
			os.exit(137)
		}
		if service.test_env(BRIDGE_CONVERT_TEST_FAIL_ENV) == name {
			return {failure = .Fatal, message = fmt.tprintf("test hook: injected failure after %s", name)}
		}
		return r
	}
}
