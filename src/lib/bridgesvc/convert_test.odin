package bridgesvc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Conversion core (docs/specs/bridge-supervisor-conversion.md): classification rows
// S10/S10c/greenfield, the crash record, recovery decisions, the step runner with a
// failure injected at every step, the rollback order and the Q3 gate. Pure: identical
// on Linux, macOS and Windows.

@(private = "file")
legacy_facts :: proc() -> Install_Facts {
	return Install_Facts {
		service_registered = true,
		running = true,
		bin_present = true,
		config_present = true,
		ports_present = true,
		bridge_id = "brg_a",
		copy_binaries = true,
		installed_version = "0.5.77",
		bundle_version = "0.5.86",
		legacy = true,
		bundle_capable = true,
	}
}

@(test)
test_convert_s10_legacy_with_capable_bundle_converts :: proc(t: ^testing.T) {
	// v0.5.77's updater: no --reinstall, no flags (spec §2 table, row 1).
	p := classify_install(legacy_facts())
	testing.expect(t, p.convert && !p.greenfield && !p.refuse && !p.noop)
	testing.expect(t, .S10_Convert in p.rows)
	testing.expect(t, !p.replace_binaries, "conversion replaces the Stage/Binaries pair")
	testing.expect(t, p.enroll_rolls_back && p.extensions)
	// Later legacy builds pass --reinstall: still a conversion.
	f := legacy_facts()
	f.reinstall = true
	testing.expect(t, classify_install(f).convert)
	// install.sh re-run with --keep-version: S8a "no change" never applies to a legacy instance.
	f = legacy_facts()
	f.keep_version = true
	f.binaries_match = true
	testing.expect(t, classify_install(f).convert)
	// S8b-from-an-old-updater with identical binaries is still a conversion.
	f = legacy_facts()
	f.binaries_match = true
	f.installed_version = "0.5.86"
	testing.expect(t, classify_install(f).convert)
}

@(test)
test_convert_respects_refusals_before_converting :: proc(t: ^testing.T) {
	// S8c: a downgrade is refused before conversion is considered.
	f := legacy_facts()
	f.requested_version = "0.5.70"
	f.bundle_version = "0.5.70"
	p := classify_install(f)
	testing.expect(t, p.refuse && p.exit_code == EXIT_REFUSED && !p.convert)
	f.allow_downgrade = true
	testing.expect(t, classify_install(f).convert)
	// --version that is not this bundle: usage error, as before.
	f = legacy_facts()
	f.requested_version = "0.5.80"
	p = classify_install(f)
	testing.expect(t, p.refuse && p.exit_code == EXIT_USAGE)
}

@(test)
test_convert_s10b_not_capable_is_plain_legacy_update :: proc(t: ^testing.T) {
	f := legacy_facts()
	f.bundle_capable = false
	p := classify_install(f)
	testing.expect(t, !p.convert && p.replace_binaries && .S8b_Version_Change in p.rows)
}

@(test)
test_convert_s10c_supervisor_managed_refuses_non_capable_bundle :: proc(t: ^testing.T) {
	f := legacy_facts()
	f.legacy = false
	f.supervisor_managed = true
	f.bundle_capable = false
	p := classify_install(f)
	testing.expect(t, p.refuse && p.exit_code == EXIT_REFUSED)
	testing.expect(t, strings.contains(p.message, "supervisor-managed"))
	// A capable bundle on a converted instance never converts and never swaps binaries.
	f.bundle_capable = true
	p = classify_install(f)
	testing.expect(t, !p.refuse && !p.convert && !p.replace_binaries)
}

@(test)
test_convert_greenfield_for_fresh_install_with_capable_bundle :: proc(t: ^testing.T) {
	p := classify_install({copy_binaries = true, bundle_version = "0.5.86", bundle_capable = true})
	testing.expect(t, p.convert && p.greenfield && .S1_Fresh in p.rows && p.enroll)
	testing.expect(t, !p.enroll_rolls_back, "S1a keeps the layout when enrollment is not approved")
	// Not capable: the legacy fresh install, as today.
	p = classify_install({copy_binaries = true, bundle_version = "0.5.75"})
	testing.expect(t, !p.convert && p.replace_binaries)
}

// ---- record -----------------------------------------------------------------

@(test)
test_conversion_record_round_trips_and_validates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rec := Conversion_Record {
		txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, service = "heimdall-bridge-hub-example-com",
		from_version = "0.5.77", to_version = "0.5.86", to_tree = "0.5.86-0123456789ab",
		instance_id = "ins_00112233445566778899aabbccddeeff", op_id = "op_convert_cv_0123456789abcdef",
		backup = ".convert-cv_0123456789abcdef", was_running = true, was_connected = true, started_at = 1795400000,
		force_at = 1795407200, step = "C6", state = "begin", done = []string{"C1", "C2", "C3", "C4", "C5"}, phase = CONVERT_PHASE_FORWARD,
	}
	text := encode_conversion(rec)
	testing.expect(t, strings.has_suffix(text, "\n"))
	got, ok := parse_conversion(text)
	testing.expect(t, ok)
	testing.expect_value(t, got.txn, rec.txn)
	testing.expect_value(t, got.force_at, rec.force_at)
	testing.expect_value(t, len(got.done), 5)
	testing.expect(t, record_done(got, .Quiesce) && !record_done(got, .Cutover))

	bad := []string{
		"", "{}", `{"schema":2}`, strings.concatenate({`{"schema":1,"txn":"nope","mode":"convert","phase":"forward"}`}, context.temp_allocator),
		`{"schema":1,"txn":"cv_0123456789abcdef","mode":"x","phase":"forward"}`,
		`{"schema":1,"txn":"cv_0123456789abcdef","mode":"convert","phase":"forward","done":["C99"]}`,
		`{"schema":1,"txn":"cv_0123456789abcdef","mode":"convert","phase":"forward","step":"Z"}`,
		`{"schema":1,"txn":"cv_0123456789ABCDEF","mode":"convert","phase":"forward"}`,
	}
	for b in bad do testing.expectf(t, !(func_ok(b)), "must reject %q", b)
}

@(private = "file")
func_ok :: proc(text: string) -> bool {
	_, ok := parse_conversion(text)
	return ok
}

@(test)
test_txn_and_instance_ids_are_well_formed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, b := new_txn_id(), new_txn_id()
	testing.expect(t, valid_txn(a) && valid_txn(b) && a != b)
	id := new_instance_id()
	testing.expect(t, len(id) == 36 && strings.has_prefix(id, "ins_"))
}

// ---- recovery decision (spec §6.3) --------------------------------------------

@(test)
test_recovery_decision :: proc(t: ^testing.T) {
	mk :: proc(done: []string, phase: string) -> Conversion_Record {
		return {done = done, phase = phase}
	}
	testing.expect_value(t, recovery_action(mk({"C1"}, CONVERT_PHASE_ROLLING_BACK), true), Recovery_Action.Continue_Rollback)
	testing.expect_value(t, recovery_action(mk({"C1", "C2", "C3", "C4"}, CONVERT_PHASE_FORWARD), true), Recovery_Action.Roll_Back)
	testing.expect_value(t, recovery_action(mk({"C1", "C2", "C3", "C4", "C5", "C6"}, CONVERT_PHASE_FORWARD), true), Recovery_Action.Roll_Forward)
	// C6 recorded but the tree/launcher/instance.json do not verify: back.
	testing.expect_value(t, recovery_action(mk({"C1", "C2", "C3", "C4", "C5", "C6"}, CONVERT_PHASE_FORWARD), false), Recovery_Action.Roll_Back)
	testing.expect_value(t, recovery_action(mk({"C1", "C2", "C3", "C4", "C5", "C6", "C6b", "C6c", "C7", "C8"}, CONVERT_PHASE_FORWARD), false), Recovery_Action.Finalize)
	// A rollback that already started is never turned around, even with C6 done.
	testing.expect_value(t, recovery_action(mk({"C6"}, CONVERT_PHASE_ROLLING_BACK), true), Recovery_Action.Continue_Rollback)
}

// ---- runner with fakes ----------------------------------------------------------

@(private = "file")
Fake :: struct {
	log:           [dynamic]string,
	fail_at:       Maybe(Convert_Step),
	fail_message:  string,
	fail_rollback: Maybe(Rollback_Step),
	fail_persist_at: Maybe(Convert_Step),
	cancel_before: Maybe(Convert_Step),
	records:       [dynamic]Conversion_Record,
	events:        [dynamic]Event,
	current_step:  Convert_Step,
}

@(private = "file")
fake_ops :: proc(f: ^Fake) -> Convert_Ops {
	f.log = make([dynamic]string, context.temp_allocator)
	f.records = make([dynamic]Conversion_Record, context.temp_allocator)
	f.events = make([dynamic]Event, context.temp_allocator)
	return Convert_Ops {
		data = f,
		run = proc(data: rawptr, step: Convert_Step, rec: ^Conversion_Record) -> Step_Result {
			f := (^Fake)(data)
			f.current_step = step
			append(&f.log, fmt.tprintf("run %s", CONVERT_STEP_NAMES[step]))
			if at, ok := f.fail_at.?; ok && at == step do return {failure = .Fatal, message = f.fail_message if f.fail_message != "" else "injected"}
			return {ok = true}
		},
		persist = proc(data: rawptr, rec: Conversion_Record) -> bool {
			f := (^Fake)(data)
			append(&f.records, rec)
			if at, ok := f.fail_persist_at.?; ok && rec.step == CONVERT_STEP_NAMES[at] && rec.state == "begin" do return false
			return true
		},
		rollback = proc(data: rawptr, step: Rollback_Step, rec: Conversion_Record) -> (bool, string) {
			f := (^Fake)(data)
			append(&f.log, fmt.tprintf("rollback %s", ROLLBACK_STEP_NAMES[step]))
			if at, ok := f.fail_rollback.?; ok && at == step do return false, "injected rollback failure"
			return true, ""
		},
		emit = proc(data: rawptr, ev: Event) {
			f := (^Fake)(data)
			append(&f.events, ev)
		},
		cancelled = proc(data: rawptr) -> bool {
			f := (^Fake)(data)
			// The runner polls before each step; the fake counts "before step X".
			return false
		},
	}
}

@(test)
test_convert_runner_happy_path_runs_every_step_in_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Fake
	rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD}
	res := run_conversion(fake_ops(&f), &rec)
	testing.expect(t, res.ok && !res.rolled_back && !res.rollback_failed)
	testing.expect_value(t, len(f.log), len(Convert_Step))
	for step, i in Convert_Step do testing.expect_value(t, f.log[i], fmt.tprintf("run %s", CONVERT_STEP_NAMES[step]))
	testing.expect_value(t, len(rec.done), len(Convert_Step))
	// begin is persisted before each step's side effects, done after.
	testing.expect_value(t, f.records[0].step, "C1")
	testing.expect_value(t, f.records[0].state, "begin")
	testing.expect_value(t, f.records[1].state, "done")
	testing.expect_value(t, len(f.records), 2 * len(Convert_Step))
}

@(test)
test_convert_failure_at_every_step_rolls_back_r1_to_r6 :: proc(t: ^testing.T) {
	// REQ-CONV-2: an injected failure at each transaction step restores the legacy
	// install. C9 is after the commit and rolls forward instead (below).
	for failing in Convert_Step {
		if failing == .Finalize do continue
		defer free_all(context.temp_allocator)
		f: Fake
		f.fail_at = failing
		rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD}
		res := run_conversion(fake_ops(&f), &rec)
		testing.expectf(t, !res.ok && res.rolled_back && !res.rollback_failed, "%v: rolled back", failing)
		testing.expect_value(t, res.failed_step, failing)
		// Steps after the failing one never ran; R1..R6 ran once, in order, at the end.
		ran := 0
		for line in f.log do if strings.has_prefix(line, "run ") do ran += 1
		testing.expect_value(t, ran, int(failing) + 1)
		tail := f.log[len(f.log) - len(Rollback_Step):]
		for rs, i in Rollback_Step do testing.expect_value(t, tail[i], fmt.tprintf("rollback %s", ROLLBACK_STEP_NAMES[rs]))
		testing.expect_value(t, rec.phase, CONVERT_PHASE_ROLLING_BACK)
		// The record handed to rollback lists exactly the steps that completed.
		testing.expect_value(t, len(rec.done), int(failing))
	}
}

@(test)
test_convert_failed_persist_fails_the_step_and_rolls_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Fake
	f.fail_persist_at = Convert_Step.Quiesce
	rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD}
	res := run_conversion(fake_ops(&f), &rec)
	testing.expect(t, !res.ok && res.rolled_back)
	testing.expect_value(t, res.failed_step, Convert_Step.Quiesce)
	// The step's side effects never started: no "run C4".
	for line in f.log do testing.expect(t, line != "run C4")
}

@(test)
test_convert_rollback_failure_stops_and_keeps_the_record :: proc(t: ^testing.T) {
	for failing in ([]Rollback_Step{.Stop_New, .Restore_Service, .Restore_Settings, .Remove_Layout, .Restart_Old, .Close}) {
		defer free_all(context.temp_allocator)
		f: Fake
		f.fail_at = Convert_Step.Verify
		f.fail_rollback = failing
		rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD}
		res := run_conversion(fake_ops(&f), &rec)
		testing.expectf(t, res.rollback_failed && !res.rolled_back && !res.ok, "%v", failing)
		testing.expect(t, strings.has_prefix(res.rollback_message, ROLLBACK_STEP_NAMES[failing]))
		// Nothing after the failed rollback step ran (R1 failing means nothing is deleted).
		last := f.log[len(f.log) - 1]
		testing.expect_value(t, last, fmt.tprintf("rollback %s", ROLLBACK_STEP_NAMES[failing]))
	}
}

@(test)
test_convert_finalize_failure_is_a_warning_not_a_rollback :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Fake
	f.fail_at = Convert_Step.Finalize
	f.fail_message = "cannot delete old task"
	rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD}
	res := run_conversion(fake_ops(&f), &rec)
	testing.expect(t, res.ok && !res.rolled_back)
	testing.expect_value(t, res.finalize_warning, "cannot delete old task")
	for line in f.log do testing.expect(t, !strings.has_prefix(line, "rollback"))
	// C8 is recorded done, so a later recovery finalizes instead of rolling back.
	testing.expect_value(t, recovery_action(rec, false), Recovery_Action.Finalize)
}

@(test)
test_convert_cancel_rolls_back_before_the_next_step :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Cancel :: struct {
		using f: Fake,
		after:   Convert_Step,
	}
	c: Cancel
	c.after = .Backup
	ops := fake_ops(&c.f)
	ops.data = &c
	ops.run = proc(data: rawptr, step: Convert_Step, rec: ^Conversion_Record) -> Step_Result {
		c := (^Cancel)(data)
		c.current_step = step
		append(&c.log, fmt.tprintf("run %s", CONVERT_STEP_NAMES[step]))
		return {ok = true}
	}
	ops.persist = proc(data: rawptr, rec: Conversion_Record) -> bool {return true}
	ops.rollback = proc(data: rawptr, step: Rollback_Step, rec: Conversion_Record) -> (bool, string) {
		c := (^Cancel)(data)
		append(&c.log, fmt.tprintf("rollback %s", ROLLBACK_STEP_NAMES[step]))
		return true, ""
	}
	ops.cancelled = proc(data: rawptr) -> bool {
		c := (^Cancel)(data)
		return c.current_step >= c.after && len(c.log) > 0
	}
	rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD}
	res := run_conversion(ops, &rec)
	testing.expect(t, res.cancelled && res.rolled_back && !res.ok)
	testing.expect_value(t, res.failed_step, Convert_Step.Quiesce)
	for line in c.log do testing.expect(t, line != "run C4")
}

@(test)
test_recover_roll_forward_skips_completed_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Fake
	rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD, done = []string{"C1", "C2", "C3", "C4", "C5", "C6"}}
	action, res := recover_conversion(fake_ops(&f), &rec, true)
	testing.expect_value(t, action, Recovery_Action.Roll_Forward)
	testing.expect(t, res.ok)
	testing.expect_value(t, f.log[0], "run C7")
	testing.expect_value(t, f.log[len(f.log) - 1], "run C9")
}

@(test)
test_recover_without_cutover_rolls_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Fake
	rec := Conversion_Record{txn = "cv_0123456789abcdef", mode = CONVERT_MODE_CONVERT, phase = CONVERT_PHASE_FORWARD, done = []string{"C1", "C2", "C3", "C4"}}
	action, res := recover_conversion(fake_ops(&f), &rec, true)
	testing.expect_value(t, action, Recovery_Action.Roll_Back)
	testing.expect(t, res.rolled_back && !res.ok)
	testing.expect_value(t, len(f.log), len(Rollback_Step))
}

// ---- gate (spec §9) ---------------------------------------------------------------

@(test)
test_gate_decisions :: proc(t: ^testing.T) {
	force_at := i64(1_000_000)
	testing.expect_value(t, gate_decide(100, force_at, 0, false), Gate_Verdict.Proceed)
	testing.expect_value(t, gate_decide(100, force_at, 3, false), Gate_Verdict.Wait)
	testing.expect_value(t, gate_decide(force_at, force_at, 3, false), Gate_Verdict.Force)
	testing.expect_value(t, gate_decide(force_at + 5, force_at, 1, false), Gate_Verdict.Force)
	// Update now interrupts at once; so does an empty daemon.
	testing.expect_value(t, gate_decide(100, force_at, 5, true), Gate_Verdict.Proceed)
	// An uncountable daemon is busy (fail closed): waits, then forces.
	testing.expect_value(t, gate_decide(100, force_at, -1, false), Gate_Verdict.Wait)
	testing.expect_value(t, gate_decide(force_at, force_at, -1, false), Gate_Verdict.Force)
}

@(test)
test_gate_countdown_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, gate_message(4320, 3), "Converting to the supervisor in 1 h 12 min; 3 agents will be stopped")
	testing.expect_value(t, gate_message(600, 1), "Converting to the supervisor in 10 min; 1 agent will be stopped")
	testing.expect_value(t, gate_message(42, 2), "Converting to the supervisor in 42 s; 2 agents will be stopped")
	testing.expect(t, strings.contains(gate_message(10, -1), "not countable"))
	testing.expect_value(t, CONVERT_GATE_WAIT_SECONDS, i64(7200))
}

// ---- backup list and created layout ----------------------------------------------------

@(test)
test_backup_files_never_include_credentials_or_bin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for target in ([]Target_OS{.Linux, .Darwin, .Windows}) {
		host := Host{os = target, home = "/home/u", appdata = "C:/Users/u/AppData/Roaming", local_appdata = "C:/Users/u/AppData/Local", uid = 501}
		l := layout_for(host, "heimdall-bridge-hub-example-com")
		files := convert_backup_files(host, l)
		testing.expect(t, len(files) >= 6)
		for p in files {
			testing.expectf(t, !is_credential_name(pdir_base(p)), "%v: credential in backup list: %s", target, p)
			testing.expectf(t, !strings.has_suffix(p, "/ham-bridge") && !strings.has_suffix(p, "/ham-bridge.exe"), "%v: binary in backup: %s", target, p)
		}
		has_ctl := false
		for p in files do if p == ctl_wrapper_path(host, l) do has_ctl = true
		testing.expectf(t, has_ctl, "%v: the ham-ctl wrapper is backed up", target)
	}
	for name in ([]string{"bridge-token", "bridge-token.bak", "identity_key", "epoch_floor", "keystore.json"}) do testing.expect(t, is_credential_name(name))
	for name in ([]string{"config.toml", "ports.json", "hub-url"}) do testing.expect(t, !is_credential_name(name))
}

@(private = "file")
pdir_base :: proc(p: string) -> string {
	i := strings.last_index_any(p, "/\\")
	return p[i + 1:] if i >= 0 else p
}

@(test)
test_remove_created_layout_removes_only_what_the_conversion_created :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root := fmt.tprintf("%s/ham-convert-layout-%d", os.get_env("TMPDIR", context.temp_allocator) if os.get_env("TMPDIR", context.temp_allocator) != "" else "/tmp", os.get_pid())
	when ODIN_OS == .Windows {
		root = fmt.tprintf("%s\\ham-convert-layout-%d", os.get_env("TEMP", context.temp_allocator), os.get_pid())
	}
	_ = os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(pjoin(root, "releases", "0.5.86-aaaaaaaaaaaa", "bin")) == nil)
	testing.expect(t, os.make_directory_all(pjoin(root, "launcher")) == nil)
	testing.expect(t, os.make_directory_all(pjoin(root, "supervisor", "journal")) == nil)
	testing.expect(t, os.make_directory_all(pjoin(root, "bin")) == nil)
	testing.expect(t, os.make_directory_all(pjoin(root, "extensions")) == nil)
	for name in ([]string{"instance.json", "current.json", "previous.json", "known-good.json", "config-keep.txt"}) {
		testing.expect(t, os.write_entire_file_from_string(pjoin(root, name), "x") == nil)
	}
	testing.expect(t, os.write_entire_file_from_string(pjoin(root, "bin", "ham-bridge"), "legacy") == nil)
	testing.expect_value(t, remove_created_layout(root), "")
	for name in CONVERT_CREATED_ENTRIES do testing.expectf(t, !os.exists(pjoin(root, name)), "%s removed", name)
	// bin/ and unrelated data survive: rollback never touches them (spec §6.1).
	testing.expect(t, os.is_file(pjoin(root, "bin", "ham-bridge")))
	testing.expect(t, os.is_dir(pjoin(root, "extensions")))
	testing.expect(t, os.is_file(pjoin(root, "config-keep.txt")))
}

@(test)
test_instance_record_matches_the_launcher_reader_shape :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := encode_instance_record("ins_00112233445566778899aabbccddeeff", "heimdall-bridge-hub-example-com", "https://hub.example.com", "", `{"uid":1000}`, "/home/u/.local/share/heimdall/bridges/x", "/home/u/.config/heimdall/bridges/x", 1795400000)
	testing.expect(t, strings.contains(text, `"schema":1`))
	testing.expect(t, strings.contains(text, `"owner":{"uid":1000}`))
	testing.expect(t, strings.contains(text, `"data_root":"/home/u/.local/share/heimdall/bridges/x"`))
	// Windows paths are escaped.
	text = encode_instance_record("ins_00112233445566778899aabbccddeeff", "s", "https://h", "p", `{"sid":"S-1-5-21-1"}`, `C:\Users\u\x`, `C:\Users\u\y`, 1)
	testing.expect(t, strings.contains(text, `"data_root":"C:\\Users\\u\\x"`))
}
