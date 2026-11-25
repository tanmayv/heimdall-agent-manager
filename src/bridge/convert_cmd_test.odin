package main

// The whole conversion transaction (convert_cmd.odin) on a temp layout with fake service
// control: the happy path, an injected failure after every step (REQ-CONV-2: the legacy
// service definition, bin/, settings, state stores come back and the old bridge runs), a
// crash at every step followed by recovery by the next run (spec §6.3), rollback failure
// (exit 7), the Q3 agent gate and the parent-process discriminator. Fixture directories
// live under $HOME/.cache/heimdall-tests, derived per test so tests never share state.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import lc "odin_test:launcher/core"
import bridgesvc "odin_test:lib/bridgesvc"
import "odin_test:supervisor/engine"

LEGACY_UNIT :: "[Service]\nExecStart=legacy\nKillMode=process\n"
LEGACY_BIN :: "legacy-ham-bridge-0.5.77"
NEW_BIN :: "new-ham-bridge-0.5.86"
TREE_NAME :: "0.5.86-0123456789ab"
OLD_STORE :: `{"provider":"old"}`

Fake_World :: struct {
	root:          string,
	running:       bool,
	connected:     bool,
	log:           [dynamic]string,
	now:           i64,
	agents:        int,
	worker_parent: bool,
	fetch_code:    string,
	commit:        bool, // the fake supervisor commits when the converted service starts
	fail_step:     Maybe(bridgesvc.Convert_Step),
	crash_step:    Maybe(bridgesvc.Convert_Step),
	crashed:       bool,
	restart_ok:    bool, // the old bridge can be restarted
	agents_after:  proc(w: ^Fake_World), // runs on every agent_count, to script the gate
	sleeps:        int,
	enrolled_halt: bool,
	layout:        bridgesvc.Layout,
	seen:          bool,
	ms:            int,
}

// Each test owns its world; the setup's conv carries the pointer (tests run in parallel).
@(private = "file")
world_of :: proc(s: ^Bridge_Setup) -> ^Fake_World {
	return (^Fake_World)(s.conv.test_user)
}

@(private = "file")
fresh_conv :: proc(s: ^Bridge_Setup, w: ^Fake_World) {
	s.conv = new(Convert_State)
	s.conv.seams = fake_seams()
	s.conv.test_user = w
}

@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> (s: ^Bridge_Setup, w: ^Fake_World) {
	root := fmt.aprintf("%s/.cache/heimdall-tests/convert-%s-%d", os.get_env("HOME", context.temp_allocator), name, os.get_pid())
	_ = os.remove_all(root)
	w = new(Fake_World)
	w^ = Fake_World{root = root, running = true, connected = true, commit = true, restart_ok = true, now = 1_800_000_000, log = make([dynamic]string)}
	host := bridgesvc.Host{os = .Linux, home = root, uid = 1000}
	profile, _ := bridgesvc.profile_from("https://hub.example.com", "", context.temp_allocator)
	l := bridgesvc.layout_for(host, profile.service_name)
	// A legacy instance: unit, bin/, config, ports, credential and a state store.
	must :: proc(ok: bool) {assert(ok, "fixture write failed")}
	must(os.make_directory_all(bridgesvc.pdir(l.service_file)) == nil)
	must(os.write_entire_file_from_string(l.service_file, LEGACY_UNIT) == nil)
	must(os.make_directory_all(l.bin_dir) == nil)
	must(os.write_entire_file_from_string(bridgesvc.pjoin(l.bin_dir, "ham-bridge"), LEGACY_BIN) == nil)
	must(os.write_entire_file_from_string(bridgesvc.ctl_wrapper_path(host, l), "#!/bin/sh\nexec legacy-ctl\n") == nil)
	must(os.make_directory_all(l.state_dir) == nil)
	must(os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE), "[bridge]\nauto_update_enabled = false\n") == nil)
	must(os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE), "https://hub.example.com\n") == nil)
	must(os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE), `{"bridge_port":49323,"endpoint_port":49324}`) == nil)
	must(os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE), strings.concatenate({bridgesvc.CREDENTIAL_HEADER, "secret brg_a\n"}, context.temp_allocator)) == nil)
	must(os.make_directory_all(bridgesvc.pjoin(l.data_dir, "bridge")) == nil)
	must(os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "bridge", "provider_x.json"), OLD_STORE) == nil)
	bundle := bridgesvc.pjoin(root, "bundle", "bin")
	must(os.make_directory_all(bundle) == nil)
	for base in ([]string{"ham-bridge", "ham-launcher", "ham-supervisor", "ham-pty-host", "ham-ctl"}) {
		must(os.write_entire_file_from_string(bridgesvc.pjoin(bundle, base), NEW_BIN) == nil)
	}
	s = new(Bridge_Setup)
	s^ = Bridge_Setup {
		host = host, profile = profile, layout = l, bundle_dir = bundle, copy_binaries = true, pid = os.get_pid(),
		args = []string{"setup", "--hub", "https://hub.example.com", "--headless"},
		lock_path = bridgesvc.pjoin(l.state_dir, bridgesvc.LOCK_FILE),
		backups = make(map[string]Maybe(string), context.temp_allocator), recovered = make([dynamic]string, context.temp_allocator),
		facts = bridgesvc.Install_Facts{service_registered = true, running = true, bin_present = true, installed_version = "0.5.77", bundle_version = "0.5.86", legacy = true, bundle_capable = true, copy_binaries = true, bridge_id = "brg_a"},
	}
	s.plan = bridgesvc.classify_install(s.facts)
	testing.expect(t, s.plan.convert)
	fresh_conv(s, w)
	w.layout = l
	return
}

@(private = "file")
destroy :: proc(s: ^Bridge_Setup, w: ^Fake_World) {
	_ = os.remove_all(w.root)
	delete(w.log)
	delete(w.root)
	free(w)
	free(s.conv)
	free(s)
}

@(private = "file")
note :: proc(w: ^Fake_World, line: string) {
	append(&w.log, strings.clone(line, context.temp_allocator))
}

@(private = "file")
fake_seams :: proc() -> Convert_Seams {
	return Convert_Seams {
		now = proc(s: ^Bridge_Setup) -> i64 {return world_of(s).now},
		sleep_ms = proc(s: ^Bridge_Setup, ms: int) {
			// Sub-second sleeps accumulate, or a 200 ms poll loop would never see time pass.
			w := world_of(s)
			w.ms += ms
			w.now += i64(w.ms / 1000)
			w.ms %= 1000
		},
		agent_count = proc(s: ^Bridge_Setup) -> int {
			w := world_of(s)
			if w.agents_after != nil do w.agents_after(w)
			return w.agents
		},
		parent_is_worker = proc(s: ^Bridge_Setup) -> bool {return world_of(s).worker_parent},
		fetch = proc(s: ^Bridge_Setup, rec: ^Conversion_Record) -> (Convert_Release, string) {
			w := world_of(s)
			if w.fetch_code != "" do return {}, w.fetch_code
			dir := bridgesvc.convert_download_dir(s.layout, rec.txn)
			_ = os.make_directory_all(dir)
			_ = os.write_entire_file_from_string(bridgesvc.pjoin(dir, "bundle.tar.gz"), "archive")
			return Convert_Release{tag = "v0.5.86", version = "0.5.86", asset = "bundle.tar.gz", archive = bridgesvc.pjoin(dir, "bundle.tar.gz"), manifest = "m", signature = "sig"}, ""
		},
		service_stop = proc(s: ^Bridge_Setup) -> (bool, string) {
			w := world_of(s)
			note(w, "stop")
			w.running = false
			return true, ""
		},
		service_start = proc(s: ^Bridge_Setup) -> (bool, string) {
			w := world_of(s)
			converted := os.is_file(bridgesvc.pjoin(s.layout.data_dir, "instance.json"))
			note(w, "start converted" if converted else "start legacy")
			if !converted && !w.restart_ok do return false, "old bridge would not start"
			w.running = true
			if converted && w.commit do fake_commit(s)
			return true, ""
		},
		service_running = proc(s: ^Bridge_Setup) -> bool {return world_of(s).running},
		service_connected = proc(s: ^Bridge_Setup) -> bool {w := world_of(s); return w.running && w.connected},
		pty_stop = proc(s: ^Bridge_Setup) -> (bool, string) {note(world_of(s), "pty-stop"); return true, ""},
		repair = proc(s: ^Bridge_Setup, rel: Convert_Release, rec: Conversion_Record) -> (int, string) {
			// What `ham-supervisor repair` leaves: the tree and the pointers (journal op not committed).
			l := s.layout
			tree := bridgesvc.pjoin(l.data_dir, "releases", TREE_NAME)
			_ = os.make_directory_all(bridgesvc.pjoin(tree, "bin"))
			for base in ([]string{"ham-bridge", "ham-launcher", "ham-supervisor", "ham-pty-host", "ham-ctl"}) {
				_ = os.write_entire_file_from_string(bridgesvc.pjoin(tree, "bin", base), NEW_BIN)
			}
			digest := "0123456789ab" + "0123456789abcdef0123456789abcdef0123456789abcdef0123"
			release := fmt.tprintf(`{{"version":"0.5.86","targets":{{"%s":{{"sha256":"%s"}}}}}}`, lc.TARGET, digest)
			_ = os.write_entire_file_from_string(bridgesvc.pjoin(tree, "release.json"), release)
			_ = os.write_entire_file_from_string(bridgesvc.pjoin(tree, ".complete"), "")
			_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "supervisor", "journal"))
			when ODIN_OS == .Windows {
				for name in ([]string{"current", "previous"}) {
					rec_text := lc.pointer_record_encode(lc.Pointer_Record{tree = TREE_NAME, op_id = rec.op_id, seq = 1}, context.temp_allocator)
					_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, strings.concatenate({name, ".json"}, context.temp_allocator)), rec_text)
				}
			} else {
				target := strings.concatenate({"releases/", TREE_NAME}, context.temp_allocator)
				_ = os.symlink(target, bridgesvc.pjoin(l.data_dir, "current"))
				_ = os.symlink(target, bridgesvc.pjoin(l.data_dir, "previous"))
			}
			note(world_of(s), "repair")
			return 0, ""
		},
		register = proc(s: ^Bridge_Setup, rec: Conversion_Record, converting: bool) -> Step_Result {
			in_ := bridge_convert_render_input(s, rec, converting)
			_ = os.write_entire_file_from_string(s.layout.service_file, bridgesvc.render_service_file(s.host, s.layout, in_))
			note(world_of(s), "register")
			return {ok = true, message = "rendered"}
		},
		enroll = proc(s: ^Bridge_Setup) -> Step_Result {
			note(world_of(s), strings.concatenate({"enroll with ", s.enroll_exe}, context.temp_allocator))
			if world_of(s).enrolled_halt do return {halt = true, message = "not enrolled"}
			return {ok = true, message = "skipped"}
		},
		extensions = proc(s: ^Bridge_Setup) -> Step_Result {return {ok = true, message = "skipped"}},
		spawn_rescuer = proc(s: ^Bridge_Setup, rec: Conversion_Record) -> bool {note(world_of(s), "rescuer"); return true},
		stop_rescuer = proc(s: ^Bridge_Setup, rec: Conversion_Record) {},
		old_version = proc(s: ^Bridge_Setup) -> string {return "0.5.77"},
		os_restore_service = proc(s: ^Bridge_Setup, rec: Conversion_Record) -> (bool, string) {note(world_of(s), "restore-service"); return true, ""},
		os_finalize = proc(s: ^Bridge_Setup, rec: Conversion_Record) -> (bool, string) {note(world_of(s), "finalize"); return true, ""},
		free_bytes = proc(dir: string) -> i64 {return -1},
		self_sha256 = proc(s: ^Bridge_Setup) -> string {return bridge_convert_file_sha256(bridgesvc.pjoin(s.bundle_dir, "ham-bridge"))},
		owner_json = bridge_convert_owner_json,
		windows_sid = bridge_convert_windows_sid,
	}
}

// fake_commit stands in for the supervisor of the new tree: journal op committed and
// known-good.json written (engine §3, J15/J16).
@(private = "file")
fake_commit :: proc(s: ^Bridge_Setup) {
	l := s.layout
	op := fmt.tprintf("op_convert_%s", s.conv.rec.txn)
	line := engine.encode_line(engine.Line{js = 1, seq = 1, ts = 1, op_id = op, action = "repair", actor = "installer", state = "committed"})
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "supervisor", "journal"))
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "supervisor", "journal", "ops.jsonl"), strings.concatenate({line, "\n"}, context.temp_allocator))
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "known-good.json"), fmt.tprintf(`{{"tree":"%s","committed_op":"%s","at":1}}`, TREE_NAME, op))
}

@(private = "file")
read :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data) if err == nil else "<missing>"
}

// legacy_intact: everything REQ-CONV-2 names is back, byte for byte.
@(private = "file")
expect_legacy_restored :: proc(t: ^testing.T, s: ^Bridge_Setup, w: ^Fake_World, label: string) {
	l := s.layout
	testing.expectf(t, read(l.service_file) == LEGACY_UNIT, "%s: service definition restored", label)
	testing.expectf(t, read(bridgesvc.pjoin(l.bin_dir, "ham-bridge")) == LEGACY_BIN, "%s: bin/ham-bridge untouched", label)
	testing.expectf(t, read(bridgesvc.ctl_wrapper_path(s.host, l)) == "#!/bin/sh\nexec legacy-ctl\n", "%s: ctl wrapper restored", label)
	testing.expectf(t, read(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)) == "[bridge]\nauto_update_enabled = false\n", "%s: config.toml restored", label)
	testing.expectf(t, read(bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE)) == `{"bridge_port":49323,"endpoint_port":49324}`, "%s: ports.json restored", label)
	testing.expectf(t, read(bridgesvc.pjoin(l.data_dir, "bridge", "provider_x.json")) == OLD_STORE, "%s: state store restored", label)
	testing.expectf(t, strings.contains(read(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)), "secret brg_a"), "%s: credential never touched", label)
	for name in bridgesvc.CONVERT_CREATED_ENTRIES do testing.expectf(t, !path_exists(bridgesvc.pjoin(l.data_dir, name)), "%s: %s removed", label, name)
	testing.expectf(t, !os.exists(bridgesvc.pjoin(l.state_dir, bridgesvc.UPDATE_FILE_NAME)), "%s: update.json removed", label)
	testing.expectf(t, !os.exists(bridgesvc.conversion_path(l)), "%s: conversion.json removed", label)
	entries, _ := os.read_directory_by_path(l.data_dir, -1, context.temp_allocator)
	for e in entries do testing.expectf(t, !strings.has_prefix(e.name, bridgesvc.CONVERT_BACKUP_PREFIX), "%s: backup dir removed (%s)", label, e.name)
	testing.expectf(t, w.running, "%s: the old bridge runs again", label)
}

@(private = "file")
path_exists :: proc(p: string) -> bool {
	_, err := os.lstat(p, context.temp_allocator)
	return err == nil
}

@(test)
test_convert_happy_path_ends_converted :: proc(t: ^testing.T) {
	s, w := fixture(t, "happy")
	defer destroy(s, w)
	r := bridge_convert_run(s)
	testing.expectf(t, r.ok && r.finished, "converted: %v", r)
	l := s.layout
	testing.expect(t, os.is_file(bridgesvc.pjoin(l.data_dir, "instance.json")))
	testing.expect(t, os.is_file(bridgesvc.launcher_path(s.host, l)))
	testing.expect(t, os.is_file(bridgesvc.pjoin(l.data_dir, "launcher", "launcher.json")))
	testing.expect(t, strings.contains(read(l.service_file), "launcher"), "the unit starts the launcher")
	testing.expect(t, strings.contains(read(l.service_file), "KillMode=process"), "KillMode=process until C9")
	testing.expect_value(t, read(bridgesvc.pjoin(l.bin_dir, "ham-bridge")), LEGACY_BIN) // bin/ is kept
	// update.json keeps the legacy opt-out (spec §11.3).
	st := read(bridgesvc.pjoin(l.state_dir, bridgesvc.UPDATE_FILE_NAME))
	testing.expect(t, strings.contains(st, `"auto_update":false`) && strings.contains(st, `"actor":"conversion"`), st)
	// C9 ran: transaction files gone.
	testing.expect(t, !os.exists(bridgesvc.conversion_path(l)))
	entries, _ := os.read_directory_by_path(l.data_dir, -1, context.temp_allocator)
	for e in entries do testing.expect(t, !strings.has_prefix(e.name, bridgesvc.CONVERT_BACKUP_PREFIX))
	// Order: rescuer before the stop, stop before the tree, converted start last.
	steps := make([dynamic]string, context.temp_allocator)
	for line in w.log do if !strings.has_prefix(line, "enroll with ") do append(&steps, line)
	joined := strings.join(steps[:], ",", context.temp_allocator)
	testing.expect_value(t, joined, "rescuer,stop,pty-stop,repair,register,start converted,finalize")
	testing.expect_value(t, s.conv.rec.to_tree, TREE_NAME)
	testing.expect_value(t, s.enroll_exe, bridgesvc.pjoin(l.data_dir, "releases", TREE_NAME, "bin", "ham-bridge"))
	testing.expect(t, bridge_convert_supervisor_managed(s.host, l))
}

@(test)
test_convert_failure_after_every_step_restores_the_legacy_install :: proc(t: ^testing.T) {
	for failing in bridgesvc.Convert_Step {
		if failing == .Finalize do continue // after the commit: rolls forward (separate test)
		s, w := fixture(t, fmt.tprintf("fail-%v", failing))
		defer destroy(s, w)
		w.fail_step = failing
		s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
			if at, ok := world_of(s).fail_step.?; ok && at == step do return "injected failure"
			return ""
		}
		r := bridge_convert_run(s)
		label := fmt.tprintf("failure after %v", failing)
		testing.expectf(t, !r.ok, "%s: step fails", label)
		testing.expectf(t, s.exit_code == bridgesvc.EXIT_FAILED && !s.rollback_failed, "%s: exit 1, rollback complete (%d)", label, s.exit_code)
		testing.expectf(t, strings.contains(s.fail_line, "the previous install was restored"), "%s: final line %q", label, s.fail_line)
		expect_legacy_restored(t, s, w, label)
	}
}

@(test)
test_convert_fetch_refusal_changes_nothing :: proc(t: ^testing.T) {
	for code in ([]string{"signature_invalid", "key_unpinned", "manifest_expired", "manifest_incomplete", "download_failed", "manifest_mismatch"}) {
		s, w := fixture(t, "refuse")
		defer destroy(s, w)
		w.fetch_code = code
		r := bridge_convert_run(s)
		testing.expect(t, !r.ok)
		testing.expectf(t, strings.contains(s.refusal, fmt.tprintf("refused: %s; the previous install was not touched", code)), "%q", s.refusal)
		expect_legacy_restored(t, s, w, code)
		// Nothing was stopped (the gate and fetch come first) and no rescuer was started.
		testing.expect_value(t, len(w.log), 0)
	}
}

@(test)
test_convert_rollback_failure_exits_7_and_keeps_the_record :: proc(t: ^testing.T) {
	s, w := fixture(t, "r5")
	defer destroy(s, w)
	w.restart_ok = false
	s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
		return "injected failure" if step == .Verify else ""
	}
	r := bridge_convert_run(s)
	testing.expect(t, !r.ok)
	testing.expect_value(t, s.exit_code, bridgesvc.EXIT_ROLLBACK_INCOMPLETE)
	testing.expect(t, s.rollback_failed)
	testing.expect(t, strings.contains(s.fail_line, "rollback incomplete") && strings.contains(s.fail_line, "R5"), s.fail_line)
	// The record and backup stay so a later run can finish (spec §6.2 R6).
	testing.expect(t, os.exists(bridgesvc.conversion_path(s.layout)))
	rec, present, readable := bridge_convert_read_record(s.layout)
	testing.expect(t, present && readable && rec.phase == bridgesvc.CONVERT_PHASE_ROLLING_BACK)
	testing.expect(t, os.is_dir(bridgesvc.convert_backup_dir(s.layout, rec.txn)))
	// The next run finishes the rollback once the old bridge can start.
	w.restart_ok = true
	fresh_conv(s, w)
	note_text, ok := bridge_convert_recover(s)
	testing.expectf(t, ok, "recovery: %s", note_text)
	expect_legacy_restored(t, s, w, "after the retry")
}

@(test)
test_convert_cancel_by_signal_rolls_back :: proc(t: ^testing.T) {
	s, w := fixture(t, "signal")
	defer destroy(s, w)
	s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
		if step == .Tree do s.conv.cancel = true // SIGTERM arrives during C5
		return ""
	}
	r := bridge_convert_run(s)
	testing.expect(t, !r.ok)
	expect_legacy_restored(t, s, w, "cancelled")
}

// ---- crash at every step, then recovery by the next run ----------------------------------

@(private = "file")
crash_ops :: proc(s: ^Bridge_Setup) -> bridgesvc.Convert_Ops {
	ops := bridge_convert_ops(s)
	// A killed process runs no rollback and writes no further record.
	ops.persist = proc(data: rawptr, rec: Conversion_Record) -> bool {
		s := (^Bridge_Setup)(data)
		if world_of(s).crashed do return true
		return bridge_convert_persist(data, rec)
	}
	ops.rollback = proc(data: rawptr, step: bridgesvc.Rollback_Step, rec: Conversion_Record) -> (bool, string) {return true, "dead"}
	return ops
}

@(test)
test_convert_crash_at_every_step_is_recovered_by_the_next_run :: proc(t: ^testing.T) {
	for crash in bridgesvc.Convert_Step {
		if crash == .Gate || crash == .Fetch do continue // no record yet: nothing to recover
		if crash == .Finalize do continue // after the commit: its own test below
		s, w := fixture(t, fmt.tprintf("crash-%v", crash))
		defer destroy(s, w)
		w.crash_step = crash
		s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
			w := world_of(s)
			if at, ok := w.crash_step.?; ok && at == step {
				w.crashed = true
				return "killed"
			}
			return ""
		}
		s.conv.rec = bridge_convert_init_record(s)
		res := bridgesvc.run_conversion(crash_ops(s), &s.conv.rec)
		label := fmt.tprintf("crash at %v", crash)
		testing.expectf(t, !res.ok, "%s: the run died", label)
		testing.expectf(t, os.exists(bridgesvc.conversion_path(s.layout)), "%s: conversion.json is left", label)
		// "Next run": a fresh setup of the same instance under the lock recovers it.
		w.crashed = false
		w.fail_step, w.crash_step = nil, nil
		s2 := new(Bridge_Setup)
		s2^ = s^
		fresh_conv(s2, w)
		s2.backups = make(map[string]Maybe(string), context.temp_allocator)
		s2.recovered = make([dynamic]string, context.temp_allocator)
		note_text, ok := bridge_convert_recover(s2)
		testing.expectf(t, ok, "%s: recovered (%s)", label, note_text)
		rolled_forward := int(crash) > int(bridgesvc.Convert_Step.Cutover) // C6 was recorded done (a crash at C6b or later)
		if rolled_forward {
			// Roll forward: the supervisor commits, C9 cleans up, the instance is converted.
			testing.expectf(t, strings.contains(note_text, "completed"), "%s: %s", label, note_text)
			testing.expectf(t, bridge_convert_supervisor_managed(s.host, s.layout), "%s: converted", label)
			testing.expectf(t, !os.exists(bridgesvc.conversion_path(s.layout)), "%s: record removed", label)
		} else {
			testing.expectf(t, strings.contains(note_text, "rolled back"), "%s: %s", label, note_text)
			expect_legacy_restored(t, s, w, label)
		}
		free(s2.conv)
		free(s2)
	}
}

@(test)
test_convert_crash_after_the_commit_finalizes_without_setup :: proc(t: ^testing.T) {
	// Kill setup after C8 (record lists C8 done): the next run finalizes, never rolls back.
	s, w := fixture(t, "after-c8")
	defer destroy(s, w)
	s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
		w := world_of(s)
		if step == .Verify {
			w.crashed = true
			return ""
		}
		return ""
	}
	s.conv.rec = bridge_convert_init_record(s)
	ops := crash_ops(s)
	// persist stops after the crash flag: the "done C8" record is the last one on disk.
	ops.persist = proc(data: rawptr, rec: Conversion_Record) -> bool {
		s := (^Bridge_Setup)(data)
		if world_of(s).crashed && rec.step == bridgesvc.CONVERT_STEP_NAMES[.Finalize] do return true
		return bridge_convert_persist(data, rec)
	}
	ops.run = proc(data: rawptr, step: bridgesvc.Convert_Step, rec: ^Conversion_Record) -> Step_Result {
		if step == .Finalize do return {failure = .Fatal, message = "killed"}
		return bridge_convert_run_step(data, step, rec)
	}
	res := bridgesvc.run_conversion(ops, &s.conv.rec)
	testing.expect(t, res.ok && res.finalize_warning == "killed", "the commit happened; C9 died")
	rec, present, readable := bridge_convert_read_record(s.layout)
	testing.expect(t, present && readable && bridgesvc.record_done(rec, .Verify))
	testing.expect_value(t, bridgesvc.recovery_action(rec, true), bridgesvc.Recovery_Action.Finalize)
	fresh_conv(s, w)
	note_text, ok := bridge_convert_recover(s)
	testing.expectf(t, ok && strings.contains(note_text, "completed"), "%s", note_text)
	testing.expect(t, bridge_convert_supervisor_managed(s.host, s.layout))
	testing.expect(t, !os.exists(bridgesvc.conversion_path(s.layout)))
	free(s.conv)
	s.conv = nil
}

@(test)
test_convert_unreadable_record_is_recovered_from_the_backup_dir :: proc(t: ^testing.T) {
	s, w := fixture(t, "garbled")
	defer destroy(s, w)
	s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
		w := world_of(s)
		if step == .Tree {
			w.crashed = true
			return "killed"
		}
		return ""
	}
	s.conv.rec = bridge_convert_init_record(s)
	_ = bridgesvc.run_conversion(crash_ops(s), &s.conv.rec)
	// Torn write of conversion.json.
	testing.expect(t, os.write_entire_file_from_string(bridgesvc.conversion_path(s.layout), `{"schema":1,"txn":`) == nil)
	w.crashed = false
	fresh_conv(s, w)
	note_text, ok := bridge_convert_recover(s)
	testing.expectf(t, ok, "%s", note_text)
	expect_legacy_restored(t, s, w, "garbled record")
	free(s.conv)
	s.conv = nil
}

// ---- greenfield --------------------------------------------------------------------------

@(test)
test_convert_greenfield_installs_the_layout_and_rolls_back_to_nothing :: proc(t: ^testing.T) {
	for fail in ([]bool{false, true}) {
		s, w := fixture(t, "greenfield")
		defer destroy(s, w)
		l := s.layout
		// Nothing installed: remove the legacy fixture.
		_ = os.remove_all(l.bin_dir)
		_ = os.remove(l.service_file)
		_ = os.remove_all(l.state_dir)
		_ = os.remove_all(bridgesvc.pjoin(l.data_dir, "bridge"))
		_ = os.make_directory_all(l.state_dir)
		s.facts = bridgesvc.Install_Facts{copy_binaries = true, bundle_version = "0.5.86", bundle_capable = true}
		s.plan = bridgesvc.classify_install(s.facts)
		testing.expect(t, s.plan.convert && s.plan.greenfield)
		w.running = false
		if fail {
			s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
				return "injected failure" if step == .Start else ""
			}
		}
		r := bridge_convert_run(s)
		if !fail {
			testing.expect(t, r.ok)
			testing.expect(t, os.is_file(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)), "config written for a fresh install")
			testing.expect(t, os.is_file(bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE)))
			testing.expect(t, !os.exists(bridgesvc.pjoin(l.bin_dir, "ham-bridge")), "bin/ham-bridge is never created")
			testing.expect(t, bridge_convert_supervisor_managed(s.host, l))
			// Nothing was stopped, no agent gate, no rescuer for an empty machine.
			for line in w.log do testing.expect(t, line != "stop" && line != "rescuer", line)
		} else {
			testing.expect(t, !r.ok && !s.rollback_failed)
			for name in bridgesvc.CONVERT_CREATED_ENTRIES do testing.expectf(t, !path_exists(bridgesvc.pjoin(l.data_dir, name)), "%s removed", name)
			testing.expect(t, !os.exists(l.service_file), "service definition removed")
			testing.expect(t, !os.exists(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)), "config removed")
			testing.expect(t, !os.exists(bridgesvc.conversion_path(l)))
		}
	}
}

@(test)
test_convert_greenfield_not_enrolled_keeps_the_layout_stopped :: proc(t: ^testing.T) {
	s, w := fixture(t, "s1a")
	defer destroy(s, w)
	l := s.layout
	_ = os.remove_all(l.bin_dir)
	_ = os.remove(l.service_file)
	s.facts = bridgesvc.Install_Facts{copy_binaries = true, bundle_version = "0.5.86", bundle_capable = true}
	s.plan = bridgesvc.classify_install(s.facts)
	w.running, w.enrolled_halt = false, true
	r := bridge_convert_run(s)
	testing.expect(t, r.halt && !r.ok, "S1a: halt, no rollback")
	testing.expect(t, s.not_enrolled != "")
	testing.expect(t, bridge_convert_supervisor_managed(s.host, l), "the layout stays installed")
	testing.expect(t, !w.running, "and is not started")
	testing.expect(t, !os.exists(bridgesvc.conversion_path(l)))
}

// ---- Q3 agent gate (spec §9) ----------------------------------------------------------------

@(private = "file")
gate_world :: proc(t: ^testing.T, name: string, agents: int, worker: bool) -> (s: ^Bridge_Setup, w: ^Fake_World) {
	s, w = fixture(t, name)
	w.agents, w.worker_parent = agents, worker
	return
}

@(test)
test_gate_user_started_interrupts_at_once :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-user", 3, false)
	defer destroy(s, w)
	rec := bridge_convert_init_record(s)
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok)
	testing.expect(t, s.conv.forced, "agents are stopped by C4")
	testing.expect_value(t, w.now, i64(1_800_000_000))
	testing.expect_value(t, rec.force_at, i64(0))
}

@(test)
test_gate_timer_started_waits_two_hours_then_forces :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-timer", 3, true)
	defer destroy(s, w)
	rec := bridge_convert_init_record(s)
	start := w.now
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok && s.conv.forced)
	testing.expect_value(t, rec.force_at, start + bridgesvc.CONVERT_GATE_WAIT_SECONDS)
	testing.expect(t, w.now >= start + bridgesvc.CONVERT_GATE_WAIT_SECONDS, "waited the full 2 h on the fake clock")
	testing.expect(t, strings.contains(r.message, "3 agent"), r.message)
}

@(test)
test_gate_proceeds_when_agents_finish :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-idle", 2, true)
	defer destroy(s, w)
	w.agents_after = proc(w: ^Fake_World) {
		if w.now >= 1_800_000_000 + 600 do w.agents = 0
	}
	rec := bridge_convert_init_record(s)
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok && !s.conv.forced)
	testing.expect(t, w.now >= 1_800_000_600 && w.now < 1_800_000_700, "left as soon as the count hit 0")
	testing.expect(t, !os.exists(bridgesvc.convert_status_path(s.layout)), "status file removed when the gate closes")
}

@(test)
test_gate_countdown_is_in_the_status_file :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-status", 3, true)
	defer destroy(s, w)
	// Read the status file the way `ham-bridge status` would, from inside the wait loop.
	w.agents_after = proc(w: ^Fake_World) {
		data, err := os.read_entire_file_from_path(bridgesvc.convert_status_path(w.layout), context.temp_allocator)
		if err == nil {
			st: bridgesvc.Gate_Status
			if json.unmarshal(data, &st, .JSON, context.temp_allocator) == nil && st.state == "waiting" && st.agents == 3 && st.force_at == 1_800_000_000 + bridgesvc.CONVERT_GATE_WAIT_SECONDS && strings.has_prefix(st.message, "Converting to the supervisor in") {
				w.seen = true
			}
		}
		if w.now >= 1_800_000_000 + 120 do w.agents = 0
	}
	rec := bridge_convert_init_record(s)
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok)
	testing.expect(t, w.seen, "waiting status with force_at, agents and the countdown line was written")
}

@(test)
test_gate_convert_now_interrupts_the_wait :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-now", 4, true)
	defer destroy(s, w)
	w.agents_after = proc(w: ^Fake_World) {
		// "Update now" arrives after 5 minutes (written by `ham-bridge setup --convert-now`).
		if w.now == 1_800_000_000 + 300 {
			req := fmt.tprintf(`{{"requested_at":%d}}`, w.now)
			_ = os.write_entire_file_from_string(bridgesvc.convert_now_path(w.layout), req)
		}
	}
	rec := bridge_convert_init_record(s)
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok && !s.conv.forced)
	testing.expect(t, w.now < 1_800_000_000 + 400, "stopped waiting right after the request")
	testing.expect(t, !os.exists(bridgesvc.convert_now_path(s.layout)), "the request is consumed")
	// A request older than the gate's own start is ignored.
	_ = os.write_entire_file_from_string(bridgesvc.convert_now_path(s.layout), `{"requested_at":5}`)
	testing.expect(t, !bridge_convert_now_requested(s, 1_800_000_000))
}

@(test)
test_gate_force_at_survives_a_rerun_and_never_resets :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-keep", 2, true)
	defer destroy(s, w)
	// A first run opened the gate 90 min ago and crashed; its status file keeps force_at.
	first := w.now - 90 * 60
	st := bridgesvc.Gate_Status{state = "waiting", force_at = first + bridgesvc.CONVERT_GATE_WAIT_SECONDS, agents = 2}
	bridge_convert_status_write(s, st)
	rec := bridge_convert_init_record(s)
	start := w.now
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok && s.conv.forced)
	testing.expect_value(t, rec.force_at, first + bridgesvc.CONVERT_GATE_WAIT_SECONDS)
	testing.expect(t, w.now - start <= 30 * 60 + 5, "only the remaining 30 min were waited, not a fresh 2 h")
	// A status file with an absurd deadline is not trusted.
	bridge_convert_status_write(s, bridgesvc.Gate_Status{state = "waiting", force_at = w.now + 10 * 3600})
	testing.expect_value(t, bridge_convert_persisted_force_at(s.layout, w.now), i64(0))
}

@(test)
test_gate_uncountable_daemon_waits :: proc(t: ^testing.T) {
	s, w := gate_world(t, "gate-unknown", -1, true)
	defer destroy(s, w)
	rec := bridge_convert_init_record(s)
	start := w.now
	r := bridge_convert_gate(s, &rec)
	testing.expect(t, r.ok && s.conv.forced)
	testing.expect(t, w.now - start >= bridgesvc.CONVERT_GATE_WAIT_SECONDS, "fail closed: busy until force_at")
}

@(test)
test_gate_forced_flags :: proc(t: ^testing.T) {
	// --convert-gate now/wait override the parent-process discriminator.
	s, w := gate_world(t, "gate-flag", 1, true)
	defer destroy(s, w)
	s.args = []string{"setup", "--convert-gate", "now"}
	testing.expect(t, !bridge_convert_gate_wait(s))
	s.args = []string{"setup", "--convert-gate", "wait"}
	w.worker_parent = false
	testing.expect(t, bridge_convert_gate_wait(s))
	s.args = []string{"setup"}
	testing.expect(t, !bridge_convert_gate_wait(s), "parent is not the worker: user-started")
	w.worker_parent = true
	testing.expect(t, bridge_convert_gate_wait(s))
}

@(test)
test_gate_worker_parent_command_is_recognised :: proc(t: ^testing.T) {
	bin := "/home/u/.local/share/heimdall/bridges/svc/bin/ham-bridge"
	cmd := strings.concatenate({bin, " update --version v0.5.86 --service svc --auto-worker"}, context.temp_allocator)
	testing.expect(t, bridge_convert_is_worker_command(cmd, bin, "svc"))
	// Another profile's worker, a manual update, and an unrelated command are not.
	testing.expect(t, !bridge_convert_is_worker_command(cmd, bin, "other"))
	testing.expect(t, !bridge_convert_is_worker_command(strings.concatenate({bin, " update --service svc"}, context.temp_allocator), bin, "svc"))
	testing.expect(t, !bridge_convert_is_worker_command("/bin/sh install.sh --auto-worker", bin, "svc"))
	testing.expect(t, !bridge_convert_is_worker_command(strings.concatenate({"/other/bin/ham-bridge update --service svc --auto-worker"}, context.temp_allocator), bin, "svc"))
}

// ---- state snapshot / restore -------------------------------------------------------------------

@(test)
test_state_snapshot_restores_files_and_removes_new_ones :: proc(t: ^testing.T) {
	s, w := fixture(t, "snapshot")
	defer destroy(s, w)
	l := s.layout
	backup := bridgesvc.convert_backup_dir(l, "cv_0123456789abcdef")
	ok, msg := bridge_convert_snapshot(l, backup)
	testing.expectf(t, ok, "%s", msg)
	testing.expect(t, os.is_file(bridgesvc.pjoin(backup, "state", engine.SNAPSHOT_JSON)), "snapshot.json written last")
	// The new runtime migrates a store, adds one and rewrites config.
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "bridge", "provider_x.json"), `{"provider":"migrated"}`)
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "bridge", "provider_new.json"), "{}")
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE), "changed")
	ok, msg = bridge_convert_restore_state(l, backup, "cv_0123456789abcdef")
	testing.expectf(t, ok, "%s", msg)
	testing.expect_value(t, read(bridgesvc.pjoin(l.data_dir, "bridge", "provider_x.json")), OLD_STORE)
	testing.expect(t, !os.exists(bridgesvc.pjoin(l.data_dir, "bridge", "provider_new.json")), "a store file the new runtime added is removed")
	testing.expect_value(t, read(bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)), "[bridge]\nauto_update_enabled = false\n")
	testing.expect(t, strings.contains(read(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)), "secret"), "credentials are never touched")
	// Without snapshot.json the stores were never touched: nothing is restored.
	_ = os.remove(bridgesvc.pjoin(backup, "state", engine.SNAPSHOT_JSON))
	_ = os.write_entire_file_from_string(bridgesvc.pjoin(l.data_dir, "bridge", "provider_x.json"), "keep")
	ok, _ = bridge_convert_restore_state(l, backup, "cv_0123456789abcdef")
	testing.expect(t, ok)
	testing.expect_value(t, read(bridgesvc.pjoin(l.data_dir, "bridge", "provider_x.json")), "keep")
}

@(test)
test_state_restore_refuses_a_corrupt_snapshot_copy :: proc(t: ^testing.T) {
	s, w := fixture(t, "corrupt")
	defer destroy(s, w)
	l := s.layout
	backup := bridgesvc.convert_backup_dir(l, "cv_0123456789abcdef")
	ok, _ := bridge_convert_snapshot(l, backup)
	testing.expect(t, ok)
	entries, _ := os.read_directory_by_path(bridgesvc.pjoin(backup, "state", "files"), -1, context.temp_allocator)
	for e in entries do _ = os.write_entire_file_from_string(bridgesvc.pjoin(backup, "state", "files", e.name), "tampered")
	ok, _ = bridge_convert_restore_state(l, backup, "cv_0123456789abcdef")
	testing.expect(t, !ok, "a snapshot copy whose digest changed is never restored")
}

@(test)
test_recovery_roll_forward_enrolls_with_the_trees_binary :: proc(t: ^testing.T) {
	// Crash at C6b: C6 is recorded done; a fresh process must enroll with the tree's
	// ham-bridge, not bin/'s (review finding).
	s, w := fixture(t, "enroll-exe")
	defer destroy(s, w)
	s.conv.fail_after = proc(s: ^Bridge_Setup, step: bridgesvc.Convert_Step) -> string {
		w := world_of(s)
		if step == .Enroll {
			w.crashed = true
			return "killed"
		}
		return ""
	}
	s.conv.rec = bridge_convert_init_record(s)
	_ = bridgesvc.run_conversion(crash_ops(s), &s.conv.rec)
	w.crashed = false
	clear(&w.log)
	s2 := new(Bridge_Setup)
	s2^ = s^
	s2.enroll_exe = "" // a new process knows nothing
	fresh_conv(s2, w)
	_, ok := bridge_convert_recover(s2)
	testing.expect(t, ok)
	// Spec 6.3: roll-forward continues at C7, so C6b is not re-run; were it ever run, it must
	// use the tree's binary, which recovery now sets before running any step.
	tree_exe := bridgesvc.pjoin(s.layout.data_dir, "releases", TREE_NAME, "bin", "ham-bridge")
	testing.expect_value(t, s2.enroll_exe, tree_exe)
	for line in w.log do if strings.has_prefix(line, "enroll with ") do testing.expect_value(t, line, strings.concatenate({"enroll with ", tree_exe}, context.temp_allocator))
	free(s2.conv)
	free(s2)
}

@(test)
test_win_restore_reports_a_failed_reenable :: proc(t: ^testing.T) {
	// Single-threaded use of a package var: the proc has no context to carry state.
	exec_ok :: proc(argv: []string) -> (bool, string) {return true, ""}
	exec_enable_fails :: proc(argv: []string) -> (bool, string) {
		if argv[1] == "/Change" do return false, "Access is denied"
		return true, ""
	}
	exec_delete_fails_task_exists :: proc(argv: []string) -> (bool, string) {
		if argv[1] == "/Delete" do return false, "busy"
		return true, "" // /Query succeeds: the new task exists
	}
	exec_delete_fails_no_task :: proc(argv: []string) -> (bool, string) {
		if argv[1] == "/Delete" || argv[1] == "/Query" do return false, "not found"
		return true, ""
	}
	ok, msg := bridge_convert_win_restore(exec_ok, `\new`, `\old`, false)
	testing.expect(t, ok)
	ok, msg = bridge_convert_win_restore(exec_enable_fails, `\new`, `\old`, false)
	testing.expect(t, !ok && strings.contains(msg, "re-enable"), msg)
	ok, _ = bridge_convert_win_restore(exec_delete_fails_task_exists, `\new`, `\old`, false)
	testing.expect(t, !ok, "the new task survives: step fails")
	ok, _ = bridge_convert_win_restore(exec_delete_fails_no_task, `\new`, `\old`, false)
	testing.expect(t, ok, "never created: fine")
	// Greenfield has no old task to enable.
	ok, _ = bridge_convert_win_restore(exec_enable_fails, `\new`, `\old`, true)
	testing.expect(t, ok)
}

@(test)
test_finalize_without_conversion_state_does_not_crash :: proc(t: ^testing.T) {
	s, w := fixture(t, "finalize-nil")
	defer destroy(s, w)
	free(s.conv)
	s.conv = nil
	r := bridge_convert_finalize(s, Conversion_Record{txn = "cv_0123456789abcdef", to_version = "0.5.86"})
	testing.expect(t, r.ok)
}
