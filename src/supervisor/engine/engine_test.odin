package engine

// Targeted tests of the T13 engine rows (spec §6.3 J0, J14–J25, J28, J32, J33; §7.5; §7.6;
// §9; §11.3; §14 hub rule; W3). The exhaustive crash matrix is in inject_test.odin.

import "core:os"
import "core:strings"
import "core:testing"
import lc "../../launcher/core"

@(private = "file")
two_trees :: proc(w: ^World) -> (from, to: Ref) {
	from = make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a'})
	to = make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b'})
	w.fake.behaviour[from.tree] = .Good
	w.fake.behaviour[to.tree] = .Good
	install(w, from)
	return
}

@(private = "file")
journal_lines :: proc(w: ^World) -> []Line {
	r := read_journal_file(join(w.root, "supervisor", "journal", "ops.jsonl"), context.temp_allocator)
	return r.lines[:]
}

@(private = "file")
last_line :: proc(w: ^World) -> Line {
	ls := journal_lines(w)
	if len(ls) == 0 do return {}
	return ls[len(ls) - 1]
}

// tick_until runs the open engine until the predicate holds (5 s per tick).
@(private = "file")
tick_until :: proc(w: ^World, pred: proc(w: ^World) -> bool, max_ticks := 200) -> bool {
	for _ in 0 ..< max_ticks {
		if pred(w) do return true
		if !w.open {
			x, err := launch(w)
			if !handle(w, x, err) do continue
		}
		w.fake.clock += 5
		x, err := tick(&w.e)
		handle(w, x, err)
	}
	return pred(w)
}

@(private = "file")
settled :: proc(w: ^World) -> bool {
	return w.open && w.e.active == nil && (w.e.phase == .Idle || w.e.phase == .Rollback_Failed)
}

// ---- journal (§6.1) ----

@(test)
test_journal_line_roundtrip_and_crc :: proc(t: ^testing.T) {
	l := Line {
		js                = 1,
		seq               = 7,
		ts                = 1800000000,
		op_id             = "op_x",
		action            = "update_now",
		actor             = "app:usr_1",
		state             = "activating",
		sub               = "pointers_begin",
		from              = Ref{"0.6.0", "aa", "0.6.0-aaaaaaaaaaaa"},
		to                = Ref{"0.6.1", "bb", "0.6.1-bbbbbbbbbbbb"},
		probation_attempt = 2,
		hub               = true,
		error             = "quote \" backslash \\ newline \n ctl \x01",
	}
	text := encode_line(l)
	testing.expect(t, strings.has_suffix(text, "\n"))
	got, ok := decode_line(text[:len(text) - 1], context.temp_allocator)
	testing.expect(t, ok, "decode")
	testing.expect_value(t, got.error, l.error)
	testing.expect_value(t, got.to.tree, l.to.tree)
	testing.expect_value(t, got.sub, "pointers_begin")
	testing.expect_value(t, got.probation_attempt, 2)
	testing.expect(t, got.hub)
	// Any changed byte breaks the crc.
	bad := transmute([]byte)strings.clone(text[:len(text) - 1], context.temp_allocator)
	bad[20] = bad[20] == '1' ? '2' : '1'
	_, ok2 := decode_line(string(bad), context.temp_allocator)
	testing.expect(t, !ok2, "a flipped byte must fail the crc")
}

@(test)
test_torn_journal_tail_is_truncated :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-torn")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	path := join(w.root, "supervisor", "journal", "ops.jsonl")
	good := encode_line(Line{js = 1, seq = 1, ts = w.fake.clock, op_id = "op_a", action = "update_now", actor = "cli", state = "requested"})
	torn := encode_line(Line{js = 1, seq = 2, ts = w.fake.clock, op_id = "op_a", action = "update_now", actor = "cli", state = "verified", to = to})
	write_text(path, strings.concatenate({good, torn[:len(torn) / 2]}, context.temp_allocator))
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, read_text(path), good)
	op, has := w.e.active.?
	testing.expect(t, has && op.state == "requested", "the torn line is ignored; the op is still requested")
	_ = from
}

@(test)
test_corrupt_journal_is_set_aside :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-corrupt")
	defer world_destroy(&w)
	two_trees(&w)
	dir := join(w.root, "supervisor", "journal")
	a := encode_line(Line{js = 1, seq = 1, ts = w.fake.clock, op_id = "op_a", action = "check_now", actor = "cli", state = "noop"})
	write_text(join(dir, "ops.jsonl"), strings.concatenate({a, "garbage line\n", a}, context.temp_allocator))
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	entries, _ := os.read_directory_by_path(dir, -1, context.temp_allocator)
	found := false
	for ent in entries do if strings.has_prefix(ent.name, "ops.corrupt-") do found = true
	testing.expect(t, found, "corrupt journal kept as ops.corrupt-<ts>.jsonl")
	l := last_line(&w)
	testing.expect_value(t, l.state, "failed")
	testing.expect_value(t, l.error, "journal_corrupt")
}

@(test)
test_rotation_and_interrupted_rotation :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-rotate")
	defer world_destroy(&w)
	two_trees(&w)
	dir := join(w.root, "supervisor", "journal")
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for strings.builder_len(b) <= ROTATE_BYTES + 1000 {
		n += 1
		id := strings.concatenate({"op_", strings.repeat("x", 20, context.temp_allocator), "_", itoa(n)}, context.temp_allocator)
		strings.write_string(&b, encode_line(Line{js = 1, seq = i64(2 * n), ts = w.fake.clock - 100, op_id = id, action = "check_now", actor = "timer", state = "requested"}))
		strings.write_string(&b, encode_line(Line{js = 1, seq = i64(2 * n + 1), ts = w.fake.clock - 100, op_id = id, action = "check_now", actor = "timer", state = "noop"}))
	}
	write_text(join(dir, "ops.jsonl"), strings.to_string(b))
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, os.exists(join(dir, "ops.1.jsonl")), "rotated generation")
	cur := read_journal_file(join(dir, "ops.jsonl"), context.temp_allocator)
	testing.expect_value(t, len(cur.lines), n) // final line of every op within 31 days
	idx, ok := read_op_index(join(dir, "op-index.json"), context.temp_allocator)
	testing.expect(t, ok && len(idx) == n, "op index holds every terminal op")
	// J33: crash between step 2 and 3 (ops.jsonl gone, .new present) -> finished at start.
	close(&w.e)
	w.open = false
	os.rename(join(dir, "ops.jsonl"), join(dir, "ops.jsonl.new"))
	x, err = launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, os.exists(join(dir, "ops.jsonl")) && !os.exists(join(dir, "ops.jsonl.new")), "J33 finished the rename")
}

@(private = "file")
itoa :: proc(n: int) -> string {
	buf: [24]byte
	i := len(buf)
	v := n
	for {
		i -= 1
		buf[i] = byte('0' + v % 10)
		v /= 10
		if v == 0 do break
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// ---- J0 / §9 ----

@(test)
test_instance_lock_is_exclusive :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-lock")
	defer world_destroy(&w)
	two_trees(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	e2: Engine
	testing.expect_value(t, open(&e2, world_config(&w), fake_host(w.fake)), Exit.Refuse)
	testing.expect_value(t, e2.refuse_reason, "lock_held")
	close(&e2)
	close(&w.e)
	w.open = false
	e3: Engine
	testing.expect_value(t, open(&e3, world_config(&w), fake_host(w.fake)), Exit.Run)
	close(&e3)
	// The lock is per instance: the user-wide ~/.heimdall-auto-update.lock is never used.
	testing.expect(t, os.exists(join(w.root, "supervisor", "engine.lock")))
}

@(test)
test_orphan_survivor_refuses :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-orphan")
	defer world_destroy(&w)
	two_trees(&w)
	w.fake.reap_ok = false
	e: Engine
	testing.expect_value(t, open(&e, world_config(&w), fake_host(w.fake)), Exit.Refuse)
	testing.expect_value(t, e.refuse_reason, "orphan_unkillable")
	close(&e)
}

@(test)
test_pointer_tmp_leftovers_removed_at_start :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-tmp")
	defer world_destroy(&w)
	two_trees(&w)
	write_text(join(w.root, "known-good.json.tmp-op_dead"), "x")
	write_text(join(w.root, "current.json.tmp-op_dead"), "x")
	write_text(join(w.root, "supervisor", "pins.json.tmp-op_dead"), "x")
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, !os.exists(join(w.root, "known-good.json.tmp-op_dead")))
	testing.expect(t, !os.exists(join(w.root, "current.json.tmp-op_dead")))
	testing.expect(t, !os.exists(join(w.root, "supervisor", "pins.json.tmp-op_dead")))
}

// ---- §7.6 launch / record mismatch (J32) ----

@(test)
test_normal_launch_of_stale_tree_hands_over :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-stale")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	e: Engine
	open(&e, world_config(&w), fake_host(w.fake))
	write_pointer(&e, POINTER_CURRENT, to.tree, "op_other")
	x, err := start(&e, from.tree, .Normal)
	testing.expect(t, err == nil && x == .Handover, "normal launch of L != C exits 75")
	testing.expect_value(t, w.fake.running, "")
	close(&e)
}

@(test)
test_fallback_after_commit_hands_over :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-fbc")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	e: Engine
	open(&e, world_config(&w), fake_host(w.fake))
	write_pointer(&e, POINTER_PREVIOUS, from.tree, "op_c")
	write_pointer(&e, POINTER_CURRENT, to.tree, "op_c")
	write_known_good(&e, to.tree, "op_c")
	x, err := start(&e, from.tree, .Fallback)
	testing.expect(t, err == nil && x == .Handover, "fallback with C == K != L exits 75")
	close(&e)
}

@(test)
test_fallback_without_journal_rolls_back_synthetically :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-fbn")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	e: Engine
	open(&e, world_config(&w), fake_host(w.fake))
	write_pointer(&e, POINTER_PREVIOUS, from.tree, "op_lost")
	write_pointer(&e, POINTER_CURRENT, to.tree, "op_lost")
	close(&e)
	w.fallback_flag = true
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.state, "rolled_back")
	testing.expect_value(t, l.error, "launcher_fallback")
	testing.expect_value(t, l.action, "rollback_to_previous")
	testing.expect(t, strings.has_prefix(l.op_id, "op_fallback_"))
	rec := lc.read_records(w.root)
	testing.expect_value(t, rec.current, from.tree)
	testing.expect(t, is_pinned(&w.e, to.version, to.sha256), "C pinned")
}

@(test)
test_fallback_from_mismatch_rolls_back_to_launched_tree :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-fbm")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	other := make_tree(w.root, Tree_Spec{version = "0.5.9", digit = 'c'})
	w.fake.behaviour[other.tree] = .Good
	w.fake.behaviour[to.tree] = .Crash
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, begin_verified(&w.e, Activation{"op_m", "update_now", "cli", to}) == nil)
	x, err = activate(&w.e)
	testing.expect(t, err == nil && x == .Handover)
	handover(&w)
	x, err = launch(&w) // to, probation
	testing.expect(t, err == nil && x == .Run)
	// The launcher gives up on `to` and starts a `previous` that is not the op's `from`.
	write_pointer(&w.e, POINTER_PREVIOUS, other.tree, "op_m")
	crash(&w)
	w.fallback_flag = true
	x, err = launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, w.launched, other.tree)
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.state, "rolled_back")
	testing.expect(t, strings.contains(l.note, "from_mismatch"), "from_mismatch recorded")
	testing.expect_value(t, lc.read_records(w.root).current, other.tree)
	_ = from
}

// ---- probation: clean vs unclean (J16, J16a) ----

@(private = "file")
to_probation :: proc(w: ^World, to: Ref) {
	x, err := launch(w)
	testing.expect(w.t, err == nil && x == .Run)
	testing.expect(w.t, begin_verified(&w.e, Activation{"op_p", "update_now", "cli", to}) == nil)
	x, err = activate(&w.e)
	testing.expect(w.t, err == nil && x == .Handover)
	handover(w)
	x, err = launch(w)
	testing.expect(w.t, err == nil && x == .Run)
	testing.expect_value(w.t, w.e.phase, Phase.Probation)
}

@(test)
test_three_clean_stops_do_not_roll_back :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-clean")
	defer world_destroy(&w)
	_, to := two_trees(&w)
	to_probation(&w, to)
	for _ in 0 ..< 3 {
		w.fake.clock += 60
		tick(&w.e)
		x, err := stop(&w.e) // §7.5: probation_suspended, attempt unchanged
		testing.expect(t, err == nil && x == .Stop)
		testing.expect_value(t, w.fake.running, "")
		close(&w.e)
		w.open = false
		x, err = launch(&w)
		testing.expect(t, err == nil && x == .Run)
		op, _ := w.e.active.?
		testing.expect_value(t, op.probation_attempt, 1)
	}
	testing.expect(t, tick_until(&w, settled))
	testing.expect_value(t, last_line(&w).state, "committed")
}

@(test)
test_three_unclean_restarts_roll_back :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-unclean")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	to_probation(&w, to)
	w.flavour = .Power_Loss
	for i in 0 ..< 3 {
		w.fake.clock += 60
		tick(&w.e)
		crash(&w) // power loss: no probation_suspended line
		x, err := launch(&w)
		if i < 2 {
			testing.expect(t, err == nil && x == .Run)
		} else {
			// 4th start: 3 unclean attempts used -> rolling_back probation_interrupted, handover.
			testing.expect(t, err == nil && x == .Handover)
			handover(&w)
		}
	}
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.state, "rolled_back")
	testing.expect_value(t, l.error, "probation_interrupted")
	testing.expect_value(t, lc.read_records(w.root).current, from.tree)
}

@(test)
test_known_good_landed_commits_at_start :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-j17")
	defer world_destroy(&w)
	_, to := two_trees(&w)
	to_probation(&w, to)
	write_known_good(&w.e, to.tree, "op_p") // J17: crash after known-good, before the line
	w.flavour = .Power_Loss // (a supervisor crash takes the §7.6 C == K handover path first)
	crash(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, last_line(&w).state, "committed")
	testing.expect_value(t, w.fake.running, to.tree)
}

// ---- J28 rollback_to_previous ----

@(test)
test_rollback_to_previous_pins_after_switch :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-j28")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	out := drive(&w, "op_up", to)
	testing.expect_value(t, out.state, "committed")
	x, err := rollback_to_previous(&w.e, "op_back", "app:usr_1")
	testing.expect(t, err == nil && x == .Handover)
	testing.expect(t, is_pinned(&w.e, to.version, to.sha256), "the newer tree is pinned once current := previous landed")
	handover(&w)
	testing.expect(t, tick_until(&w, settled))
	testing.expect_value(t, last_line(&w).state, "committed")
	testing.expect_value(t, lc.read_known_good(w.root) or_else "", from.tree)
}

@(test)
test_rollback_to_previous_without_previous_fails :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-j28n")
	defer world_destroy(&w)
	two_trees(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	x, err = rollback_to_previous(&w.e, "op_back", "cli")
	testing.expect(t, err == nil && x == .Run)
	l := last_line(&w)
	testing.expect_value(t, l.state, "failed")
	testing.expect_value(t, l.error, "no_previous")
	testing.expect_value(t, len(read_pins(&w.e)), 0)
}

// ---- T9 carry-over (b): repair of the same release failing probation ----

@(test)
test_repair_same_release_rollback_skips_pin :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-repair")
	defer world_destroy(&w)
	from := make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a'})
	// Same bundle re-installed by repair under -r1 (spec §4).
	os.rename(join(w.root, "releases", from.tree), join(w.root, "releases", "tmpmove"))
	from = make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a'})
	os.rename(join(w.root, "releases", "tmpmove"), join(w.root, "releases", strings.concatenate({from.tree, "-r1"}, context.temp_allocator)))
	repair := Ref{from.version, from.sha256, strings.concatenate({from.tree, "-r1"}, context.temp_allocator)}
	w.fake.behaviour[from.tree] = .Good
	w.fake.behaviour[repair.tree] = .Never_Ready
	install(&w, from)
	out := drive(&w, "op_repair", repair)
	testing.expect_value(t, out.state, "rolled_back")
	testing.expect(t, strings.contains(out.note, "pin_skipped same_release"), "pin skip recorded")
	testing.expect_value(t, len(read_pins(&w.e)), 0)
}

// ---- W3 sharing violations on pointer replace ----

@(test)
test_pointer_replace_retries_sharing_violations :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-busy")
	defer world_destroy(&w)
	_, to := two_trees(&w)
	w.inj.busy_count = 5 // a scanner holds the file for a while; within the 60 s budget
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	w.inj.busy_count = 5
	testing.expect(t, begin_verified(&w.e, Activation{"op_b", "update_now", "cli", to}) == nil)
	w.inj.busy_count = 5
	x, err = activate(&w.e)
	testing.expect(t, err == nil && x == .Handover, "busy replace retried and succeeded")
}

@(test)
test_pointer_replace_busy_beyond_budget_fails_before_switch :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-busy2")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, begin_verified(&w.e, Activation{"op_b", "update_now", "cli", to}) == nil)
	w.inj.busy_count = 1_000_000
	x, err = activate(&w.e)
	testing.expect(t, err == nil && x == .Run)
	l := last_line(&w)
	testing.expect_value(t, l.state, "failed")
	testing.expect_value(t, l.error, "pointer_write")
	w.inj.busy_count = 0
	testing.expect_value(t, lc.read_records(w.root).current, from.tree)
	testing.expect_value(t, w.fake.running, from.tree)
}

// ---- §14 hub rule, §11.3 refuse, §8 journal gap, §7.5 stop before switch ----

@(test)
test_hub_rule :: proc(t: ^testing.T) {
	{
		w: World
		world_init(&w, t, "t13-hub1")
		defer world_destroy(&w)
		_, to := two_trees(&w)
		w.fake.hub_recent = true
		w.fake.hub_up = false
		out := drive(&w, "op_h", to)
		testing.expect_value(t, out.state, "rolled_back")
		testing.expect_value(t, out.error, "hub_unreachable")
	}
	{
		w: World
		world_init(&w, t, "t13-hub2")
		defer world_destroy(&w)
		_, to := two_trees(&w)
		w.fake.hub_recent = false
		out := drive(&w, "op_h", to)
		testing.expect_value(t, out.state, "committed")
		testing.expect_value(t, out.note, "probation_offline")
	}
}

@(test)
test_activation_refusals_before_gate :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-refuse")
	defer world_destroy(&w)
	from := make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a', state_schema = 3, state_compat_min = 3})
	older := make_tree(w.root, Tree_Spec{version = "0.5.0", digit = 'b', state_schema = 1, state_compat_min = 1})
	gap := make_tree(w.root, Tree_Spec{version = "0.7.0", digit = 'c', state_schema = 3, state_compat_min = 3, journal_schema = 3})
	w.fake.behaviour[from.tree] = .Good
	install(&w, from)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, begin_verified(&w.e, Activation{"op_r1", "install_version", "cli", older}) == nil)
	activate(&w.e)
	testing.expect_value(t, last_line(&w).error, "state_schema_incompatible")
	testing.expect(t, begin_verified(&w.e, Activation{"op_r2", "update_now", "cli", gap}) == nil)
	activate(&w.e)
	testing.expect_value(t, last_line(&w).error, "journal_schema_gap")
	testing.expect_value(t, lc.read_records(w.root).current, from.tree)
	testing.expect_value(t, w.fake.violations, 0)
}

@(test)
test_service_stop_during_activation_before_switch :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-stopact")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, begin_verified(&w.e, Activation{"op_s", "update_now", "cli", to}) == nil)
	w.fake.stop_flag = true
	x, err = activate(&w.e)
	testing.expect(t, err == nil)
	l := last_line(&w)
	testing.expect_value(t, l.state, "failed")
	testing.expect_value(t, l.error, "service_stopped")
	testing.expect_value(t, lc.read_records(w.root).current, from.tree)
	testing.expect_value(t, len(read_pins(&w.e)), 0)
}

@(test)
test_stop_timeout_restarts_installed_version :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-stopto")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, begin_verified(&w.e, Activation{"op_s", "update_now", "cli", to}) == nil)
	w.fake.stop_ok = false
	w.fake.running = "" // the stop is refused but the fake does not double count
	x, err = activate(&w.e)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, last_line(&w).error, "stop_timeout")
	testing.expect_value(t, w.fake.running, from.tree)
}

// ---- one-way state: rollback restores the snapshot (§11.3, J22) ----

@(test)
test_one_way_migration_restored_on_rollback :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-oneway")
	defer world_destroy(&w)
	from := make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a', state_schema = 1, state_compat_min = 1})
	to := make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b', state_schema = 2, state_compat_min = 2})
	w.fake.behaviour[from.tree] = .Good
	w.fake.behaviour[to.tree] = .Crash
	w.fake.writes_schema[from.tree] = 1
	w.fake.writes_schema[to.tree] = 2
	write_text(join(w.state, "config.toml"), "schema-1")
	install(&w, from)
	out := drive(&w, "op_ow", to)
	testing.expect_value(t, out.state, "rolled_back")
	testing.expect(t, strings.contains(out.note, "state_restored"), "restore recorded")
	testing.expect_value(t, read_text(join(w.state, "config.toml")), "schema-1")
}

when ODIN_OS == .Windows {
	@(test)
	test_windows_pointer_records_seq_increases :: proc(t: ^testing.T) {
		w: World
		world_init(&w, t, "t13-winrec")
		defer world_destroy(&w)
		_, to := two_trees(&w)
		out := drive(&w, "op_w", to)
		testing.expect_value(t, out.state, "committed")
		cur, cok := lc.read_pointer(w.root, POINTER_CURRENT)
		testing.expect(t, cok && cur == to.tree, "current.json decodes with the launcher's reader")
		testing.expect(t, os.exists(join(w.root, "previous.json")))
	}
}

// ---- Error contract: non-crash failures (store.odin append_durable, engine.odin header) ----

@(test)
test_append_failure_cuts_the_journal_back :: proc(t: ^testing.T) {
	dir := make_test_dir(t, "t13-append")
	defer os.remove_all(dir)
	path := join(dir, "ops.jsonl")
	l1 := encode_line(Line{js = 1, seq = 1, ts = 1, op_id = "op_a", action = "update_now", actor = "cli", state = "requested"})
	l2 := encode_line(Line{js = 1, seq = 2, ts = 2, op_id = "op_a", action = "update_now", actor = "cli", state = "verifying"})
	l3 := encode_line(Line{js = 1, seq = 3, ts = 3, op_id = "op_a", action = "update_now", actor = "cli", state = "failed", error = "x"})
	testing.expect(t, append_durable(nil, path, l1) == nil)
	// Short write (half of l2 reaches the file), then the error: the file is cut back.
	inj := Injector{fail_at = 1, fail_kind = .Io}
	err := append_durable(&inj, path, l2)
	testing.expect(t, inj.failed, "failure delivered")
	testing.expect_value(t, error_code(err), "fs_error")
	testing.expect_value(t, read_text(path), l1)
	// The next append is a whole line of its own, and the journal reads clean.
	testing.expect(t, append_durable(nil, path, l3) == nil)
	r := read_journal_file(path, context.temp_allocator)
	testing.expect_value(t, r.status, Journal_Read_Status.Ok)
	testing.expect_value(t, len(r.lines), 2)
}

@(test)
test_commit_write_failure_is_retried_in_place :: proc(t: ^testing.T) {
	for kind in Fail_Kind {
		for offset in 1 ..= 2 { // 1 = known-good.json, 2 = the committed line
			w: World
			world_init(&w, t, "t13-commitretry")
			_, to := two_trees(&w)
			to_probation(&w, to)
			w.inj.fail_at = w.inj.steps + offset
			w.inj.fail_kind = kind
			testing.expect(t, tick_until(&w, settled))
			testing.expectf(t, w.inj.failed, "%v@%d: failure not delivered", kind, offset)
			want := "known-good" if offset == 1 else "ops.jsonl"
			testing.expectf(t, strings.contains(w.inj.failed_what, want), "%v@%d: failed %s, want %s", kind, offset, w.inj.failed_what, want)
			l := last_line(&w)
			testing.expectf(t, l.state == "committed", "%v@%d: %s %s", kind, offset, l.state, l.error)
			testing.expectf(t, w.exits == 0 && w.crashes == 0, "%v@%d: a healthy candidate's supervisor exited (%d exits)", kind, offset, w.exits)
			testing.expect_value(t, lc.read_known_good(w.root) or_else "", to.tree)
			testing.expect_value(t, w.fake.running, to.tree)
			testing.expect_value(t, read_journal_file(join(w.root, "supervisor", "journal", "ops.jsonl"), context.temp_allocator).status, Journal_Read_Status.Ok)
			world_destroy(&w)
		}
	}
}

@(test)
test_fatal_error_poisons_the_engine :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-poison")
	defer world_destroy(&w)
	_, to := two_trees(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect(t, begin_verified(&w.e, Activation{"op_x", "update_now", "cli", to}) == nil)
	w.inj.fail_at = w.inj.steps + 1 // the gate_closed line
	w.inj.fail_kind = .Io
	x, err = activate(&w.e)
	testing.expect_value(t, error_code(err), "fs_error")
	testing.expect(t, fatal(err))
	testing.expect_value(t, EXIT_ENGINE_FAILURE, 1)
	_, again := tick(&w.e)
	testing.expect_value(t, error_code(again), "fs_error")
	_, again = stop(&w.e)
	testing.expect_value(t, error_code(again), "fs_error")
	testing.expect(t, !fatal(fail("busy", "x")) && !fatal(nil), "usage errors are not fatal")
}

@(test)
test_rollback_stop_timeout_exits_and_reaps :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-rbstop")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	w.fake.behaviour[to.tree] = .Never_Ready
	w.fake.stop_fail_once = to.tree // the rollback's stop of the candidate times out once
	out := drive(&w, "op_rs", to)
	testing.expect_value(t, out.state, "rolled_back")
	testing.expect_value(t, w.exits, 1)
	testing.expect_value(t, w.fake.violations, 0)
	testing.expect_value(t, w.fake.running, from.tree)
	stopping, stopped := 0, 0
	for l in journal_lines(&w) {
		if l.state != "rolling_back" do continue
		if l.sub == "stopping" do stopping += 1
		if l.sub == "stopped" do stopped += 1
	}
	testing.expect_value(t, stopping, 2) // first attempt + resume after the restart
	testing.expect_value(t, stopped, 1) // never journaled while the candidate still ran
}

// ---- J25 is sticky across restarts ----

@(test)
test_rollback_failed_survives_restart :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-sticky")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	w.fake.behaviour[to.tree] = .Never_Ready
	x, err := launch(&w)
	handle(&w, x, err)
	w.fake.behaviour[from.tree] = .Never_Ready
	out := drive(&w, "op_bb", to)
	testing.expect_value(t, out.state, "rollback_failed")
	testing.expect_value(t, w.fake.running, "")
	n := len(journal_lines(&w))
	for flavour in Crash_Flavour {
		w.flavour = flavour
		crash(&w)
		x, err = launch(&w)
		testing.expect(t, err == nil && x == .Run)
		testing.expect_value(t, w.e.phase, Phase.Rollback_Failed)
		testing.expect_value(t, w.fake.running, "")
		testing.expect(t, strings.contains(read_text(join(w.state, "supervisor-status.json")), `"phase":"Rollback_Failed"`), "status file says rollback_failed")
		testing.expect_value(t, len(journal_lines(&w)), n) // no new op, nothing journaled
	}
	// A repair-type intent (new op) leaves the terminal state.
	fixed := make_tree(w.root, Tree_Spec{version = "0.6.2", digit = 'c'})
	w.fake.behaviour[fixed.tree] = .Good
	out = drive(&w, "op_fix", fixed)
	testing.expect_value(t, out.state, "committed")
	testing.expect_value(t, w.fake.running, fixed.tree)
}

// J25 stays sticky after lines that change nothing: a side op (check_now, allowed in
// rollback_failed), a single-line J31 rejection (including `rejected rollback_failed`
// itself), a J35 rejected cancel and a busy-cancelled install (T13b safety review).
@(test)
test_rollback_failed_sticky_after_side_and_rejected_lines :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13b-sticky")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	w.fake.behaviour[to.tree] = .Never_Ready
	x, err := launch(&w)
	handle(&w, x, err)
	w.fake.behaviour[from.tree] = .Never_Ready
	out := drive(&w, "op_bb", to)
	testing.expect_value(t, out.state, "rollback_failed")
	lines := []Line {
		{op_id = "op_check", action = "check_now", actor = "cli", state = "requested"},
		{op_id = "op_check", action = "check_now", actor = "cli", state = "noop", note = "up_to_date"},
		{op_id = "op_rej", action = "set_channel", actor = "cli", state = "rejected", error = "rollback_failed"},
		{op_id = "op_cx", action = "cancel", actor = "cli", state = "rejected", error = "nothing_to_cancel"},
		{op_id = "op_busy", action = "install_version", actor = "cli", state = "cancelled", error = "busy"},
	}
	for l in lines do testing.expect(t, journal(&w.e, l) == nil)
	for flavour in Crash_Flavour {
		w.flavour = flavour
		crash(&w)
		x, err = launch(&w)
		testing.expect(t, err == nil && x == .Run)
		testing.expectf(t, w.e.phase == .Rollback_Failed, "phase after restart = %v (want Rollback_Failed)", w.e.phase)
		testing.expectf(t, w.fake.running == "", "runtime started after restart: %q", w.fake.running)
	}
}

// ---- adopt (§6.4: current unproven, no op explains it) ----

@(private = "file")
adopt_world :: proc(w: ^World, with_previous: bool, cand: Behaviour) -> (from, to: Ref) {
	from = make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a'})
	to = make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b'})
	w.fake.behaviour[from.tree] = .Good
	w.fake.behaviour[to.tree] = cand
	e: Engine
	open(&e, world_config(w), fake_host(w.fake))
	if with_previous do write_pointer(&e, POINTER_PREVIOUS, from.tree, "op_lost")
	write_pointer(&e, POINTER_CURRENT, to.tree, "op_lost") // no known-good, no journal
	close(&e)
	return
}

@(test)
test_adopt_success_commits :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-adopt-ok")
	defer world_destroy(&w)
	_, to := adopt_world(&w, false, .Good)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, w.e.phase, Phase.Probation)
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.action, "adopt")
	testing.expect_value(t, l.state, "committed")
	testing.expect_value(t, lc.read_known_good(w.root) or_else "", to.tree)
}

@(test)
test_adopt_failure_rolls_back_to_previous :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-adopt-rb")
	defer world_destroy(&w)
	from, to := adopt_world(&w, true, .Never_Ready)
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.action, "adopt")
	testing.expect_value(t, l.state, "rolled_back")
	rec := lc.read_records(w.root)
	testing.expect_value(t, rec.current, from.tree)
	testing.expect_value(t, rec.known_good, from.tree)
	testing.expect(t, is_pinned(&w.e, to.version, to.sha256), "the failed candidate is pinned")
	testing.expect_value(t, w.fake.running, from.tree)
	testing.expect_value(t, w.fake.violations, 0)
}

@(test)
test_adopt_failure_without_target_keeps_the_only_release :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-adopt-none")
	defer world_destroy(&w)
	_, to := adopt_world(&w, false, .Never_Ready)
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.action, "adopt")
	testing.expect_value(t, l.state, "failed")
	testing.expect_value(t, l.error, "runtime_not_ready")
	testing.expect(t, strings.contains(l.note, "no_rollback_target"), "no_rollback_target recorded")
	testing.expect_value(t, len(read_pins(&w.e)), 0) // the only release is never pinned
	testing.expect_value(t, w.e.phase, Phase.Idle)
	testing.expect_value(t, w.fake.running, to.tree)
	testing.expect_value(t, lc.read_records(w.root).current, to.tree)
	testing.expect_value(t, w.fake.violations, 0)
	// Restarts run it again without a new adopt op (no loop).
	n := len(journal_lines(&w))
	for _ in 0 ..< 2 {
		w.flavour = .Power_Loss
		crash(&w)
		x, err := launch(&w)
		testing.expect(t, err == nil && x == .Run)
		testing.expect_value(t, w.e.phase, Phase.Idle)
		testing.expect_value(t, w.fake.running, to.tree)
	}
	testing.expect_value(t, len(journal_lines(&w)), n)
}

@(test)
test_rollback_without_valid_target_does_not_pin :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t, "t13-notarget")
	defer world_destroy(&w)
	from, to := two_trees(&w)
	w.fake.behaviour[to.tree] = .Never_Ready
	to_probation(&w, to)
	// The rollback target vanished during probation (e.g. a user deleted the directory).
	os.remove(join(w.root, "releases", from.tree, ".complete"))
	testing.expect(t, tick_until(&w, settled))
	l := last_line(&w)
	testing.expect_value(t, l.state, "rollback_failed")
	testing.expect(t, strings.contains(l.note, "no_rollback_target"), "no_rollback_target recorded")
	testing.expect_value(t, len(read_pins(&w.e)), 0) // checked before the pin
	testing.expect_value(t, lc.read_records(w.root).current, to.tree)
	testing.expect_value(t, w.fake.running, "")
	// Sticky: `current` (= to) is named by the rollback_failed op.
	crash(&w)
	x, err := launch(&w)
	testing.expect(t, err == nil && x == .Run)
	testing.expect_value(t, w.e.phase, Phase.Rollback_Failed)
	testing.expect_value(t, w.fake.running, "")
}
