package main

// REQ-SHELL-8 bridge-side tests — the 5-day rolling window for shell output.
//
// AGE IS INJECTED, NEVER SLEPT. bridge_shell_output_sweep takes `now_unix_ms` as a
// parameter precisely so a 5-day boundary can be crossed in a unit test: each test
// below writes a file at the real now and then sweeps with a clock placed days
// ahead. The same file is asserted SURVIVING one sweep and RECLAIMED by a later one,
// which pins the boundary from both sides rather than only proving deletion happens
// eventually.
//
// The tests map onto the acceptance criteria as:
//   AC1  old reclaimed / young kept          -> boundary_reclaims_only_past_the_window
//   AC2  a live session is NEVER reclaimed   -> live_session_output_survives_any_age
//                                               (both liveness signals, separately)
//   AC3  reclaimed / empty / absent distinct -> three_states_are_distinguishable,
//                                               empty_output_is_not_reclaimed
//   AC4  reclaim concurrent with a read      -> open_reader_sees_whole_file
//   AC6  the window is a named constant      -> windows_are_ordered
//   plus the tombstone lifecycle             -> tombstones_age_out_after_rows

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// ---- helpers -------------------------------------------------------------

DAY_MS :: i64(24 * 60 * 60 * 1000)

// _retention_dir points the bridge at a private data dir and returns the session
// directory both specs and output live in. Each test uses its own dir so the
// package's tests stay independent of each other's leftovers.
@(private = "file")
_retention_dir :: proc(name: string) -> string {
	bridge_config.data_dir = name
	dir := bridge_shell_output_dir()
	_ = os.make_directory_all(dir)
	return dir
}

// _clean_dir empties the session directory without removing it. Tests assert on
// RECLAIM COUNTS, so a stray file left by an earlier run of the suite would change
// the answer — the cleanup is part of the assertion, not housekeeping.
@(private = "file")
_clean_dir :: proc(dir: string) {
	infos, rerr := os.read_directory_by_path(dir, -1, context.allocator)
	if rerr != nil do return
	defer os.file_info_slice_delete(infos, context.allocator)
	for info in infos do _ = os.remove(info.fullpath)
}

@(private = "file")
_write_output :: proc(session_id, content: string) -> string {
	path := bridge_shell_output_path(session_id)
	_ = os.write_entire_file(path, transmute([]byte)content)
	return path
}

@(private = "file")
_write_spec_file :: proc(dir, session_id: string) {
	path := strings.concatenate({dir, "/", session_id, ".json"})
	defer delete(path)
	_ = os.write_entire_file(path, transmute([]byte)string("{\"session_id\":\"x\"}"))
}

@(private = "file")
_register_live :: proc(session_id: string, status: Bridge_Shell_Session_Status) {
	a := bridge_shell_session_map_allocator(&bridge_shell_session_map)
	sess := Bridge_Shell_Session{
		session_id = strings.clone(session_id, a),
		kind       = .Server,
		cmd        = strings.clone("sleep 999999", a),
		cwd        = strings.clone("/tmp", a),
		bridge_id  = strings.clone("brg_ret", a),
		label      = strings.clone("retention", a),
		status     = status,
		pid        = 4242,
		shell_id   = strings.clone(session_id, a),
		started_at = strings.clone("2026-09-01T00:00:00Z", a),
	}
	bridge_shell_session_register(&bridge_shell_session_map, &sess)
}

// ---- AC6 + the window ordering ------------------------------------------

// The three windows are ONE chain, and this test is what makes an edit to any single
// one of them fail loudly instead of silently breaking a property that lives in a
// comment. It is the cheapest test in the file and the one most likely to earn its
// keep: the inequalities are invisible at every individual call site.
@(test)
bridge_shell8_windows_are_ordered :: proc(t: ^testing.T) {
	testing.expect(t, BRIDGE_SHELL_OUTPUT_RETENTION == 5 * 24 * time.Hour,
		"the user's requirement is FIVE days of output retention")
	// Rows (7d, hub side) must outlive output, and tombstones must outlive rows, so a
	// user can never see a row whose output is gone without being told why.
	testing.expect(t, BRIDGE_SHELL_TOMBSTONE_RETENTION > 7 * 24 * time.Hour,
		"a tombstone must outlive the hub row that could still ask about it (7 days)")
	testing.expect(t, BRIDGE_SHELL_TOMBSTONE_RETENTION > BRIDGE_SHELL_OUTPUT_RETENTION,
		"a tombstone must outlive the output it replaces")
}

// ---- AC1: the boundary ---------------------------------------------------

@(test)
bridge_shell8_boundary_reclaims_only_past_the_window :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-boundary")
	defer delete(dir)
	_clean_dir(dir)

	path := _write_output("shl_aged", "line one\nline two\n")
	defer delete(path)
	now := bridge_now_unix_ms()

	// Four days old: INSIDE the window. Nothing may be touched.
	reclaimed, _ := bridge_shell_output_sweep(now + 4 * DAY_MS)
	testing.expect(t, reclaimed == 0, "output inside the 5-day window is not reclaimed")
	testing.expect(t, os.exists(path), "the file itself is still there")

	// Six days old: PAST the window. Same file, same sweep, opposite outcome — which
	// is what makes this a boundary test rather than a deletion test.
	reclaimed2, _ := bridge_shell_output_sweep(now + 6 * DAY_MS)
	testing.expect(t, reclaimed2 == 1, "output past the 5-day window is reclaimed")
	testing.expect(t, !os.exists(path), "the output file is gone")

	tomb := bridge_shell_output_tombstone_path("shl_aged")
	defer delete(tomb)
	testing.expect(t, os.exists(tomb), "a tombstone records that retention took it")
}

// ---- AC2: a live session is never reclaimed -----------------------------

// THE CRITERION MOST LIKELY TO BE GOT WRONG, per the task, so both liveness signals
// are asserted SEPARATELY. Either one alone leaves a hole: the map is empty at
// bridge start (when the sweep runs), and a spec is all that survives a restart.
//
// The ages here are absurd on purpose — 90 days against a 5-day window — because the
// rule is "never, at any age", not "not for a while".
@(test)
bridge_shell8_live_session_output_survives_any_age :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-live")
	defer delete(dir)
	_clean_dir(dir)

	// (a) live because the session map says so — a server running right now.
	in_map := _write_output("shl_in_map", "server still logging\n")
	defer delete(in_map)
	_register_live("shl_in_map", .Running)

	// (b) live because a SPEC is on disk — the same server after a bridge restart,
	// before anything has reloaded it into the map. This is the case that made the
	// map-only check unsafe at startup.
	by_spec := _write_output("shl_by_spec", "server logged before the restart\n")
	defer delete(by_spec)
	_write_spec_file(dir, "shl_by_spec")

	// (c) the control: identical file, no map entry and no spec. If this one is NOT
	// reclaimed the test proves nothing, because the sweep might simply be inert.
	dead := _write_output("shl_dead", "this run ended long ago\n")
	defer delete(dead)

	now := bridge_now_unix_ms()
	reclaimed, _ := bridge_shell_output_sweep(now + 90 * DAY_MS)

	testing.expect(t, os.exists(in_map), "a session live in the map is never reclaimed, at any age")
	testing.expect(t, os.exists(by_spec), "a session live by its on-disk spec is never reclaimed, at any age")
	testing.expect(t, !os.exists(dead), "control: an equally old session that is NOT live IS reclaimed")
	testing.expect(t, reclaimed == 1, "exactly one of the three was eligible")
}

// A session in the map with a TERMINAL status is not live. Without this the map
// check would protect every session the bridge had ever seen for as long as the
// process stayed up, and a long-lived bridge would retain output forever — the
// original defect, reintroduced by an over-broad guard.
@(test)
bridge_shell8_terminal_map_entry_does_not_protect_output :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-terminal")
	defer delete(dir)
	_clean_dir(dir)

	path := _write_output("shl_done", "finished days ago\n")
	defer delete(path)
	_register_live("shl_done", .Exited)

	reclaimed, _ := bridge_shell_output_sweep(bridge_now_unix_ms() + 6 * DAY_MS)
	testing.expect(t, reclaimed == 1, "a terminal session in the map is not live and is reclaimed")
	testing.expect(t, !os.exists(path), "its output is gone")
}

// ---- AC3: three distinct states -----------------------------------------

@(test)
bridge_shell8_three_states_are_distinguishable :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-states")
	defer delete(dir)
	_clean_dir(dir)

	have := _write_output("shl_have", "real output\n")
	defer delete(have)

	content, state := bridge_shell_output_read("shl_have")
	defer if state == .Available do delete(content)
	testing.expect(t, state == .Available, "a present file reads as available")
	testing.expect(t, strings.contains(content, "real output"), "and yields its content")

	// Reclaim it, then ask again: the SAME id must now answer differently.
	_ = bridge_shell_output_reclaim("shl_have")
	_, state2 := bridge_shell_output_read("shl_have")
	testing.expect(t, state2 == .Reclaimed, "after reclaim the same id reports reclaimed, not absent")

	// An id that never existed is NOT reclaimed. This branch matters as much as the
	// other two: letting the fallback answer "reclaimed" for every unknown id would
	// be the same class of wrong answer as the silent-empty bug being removed.
	_, state3 := bridge_shell_output_read("shl_never_existed")
	testing.expect(t, state3 == .Absent, "an id that never ran here is absent, never reclaimed")
}

// The zero-byte case, deliberately its own test rather than a variant of the one
// above: a command that printed nothing must report an honest EMPTY log, not a
// reclaimed one. PRESENCE is the key, never size — overshooting here would replace
// one wrong answer with another.
@(test)
bridge_shell8_empty_output_is_not_reclaimed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-empty")
	defer delete(dir)
	_clean_dir(dir)

	path := _write_output("shl_silent", "")
	defer delete(path)
	testing.expect(t, os.exists(path), "a run that printed nothing still has an output file")

	content, state := bridge_shell_output_read("shl_silent")
	defer if state == .Available do delete(content)
	testing.expect(t, state == .Available, "zero bytes is an available, empty log — not a reclaimed one")
	testing.expect(t, len(content) == 0, "and it is genuinely empty")
}

// ---- AC4: a reclaim concurrent with an open read ------------------------

// The guarantee is structural, not probabilistic, so the test makes it structural
// too: open the file, reclaim it WHILE the handle is open, then read through that
// handle. On POSIX an unlink cannot shorten a file an existing reader already
// opened, so the reader must still see every byte.
//
// This is exactly why reclaim unlinks rather than truncating. A truncate would let
// this read return a SHORT log indistinguishable from a complete one — silent data
// corruption, and the failure AC4 exists to rule out.
@(test)
bridge_shell8_open_reader_sees_whole_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-concurrent")
	defer delete(dir)
	_clean_dir(dir)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 500 do strings.write_string(&b, "a line of output that must survive the reclaim\n")
	expected := strings.to_string(b)

	path := _write_output("shl_racing", expected)
	defer delete(path)

	handle, oerr := os.open(path, os.O_RDONLY)
	testing.expect(t, oerr == nil, "reader opened the output file")
	defer os.close(handle)

	// The reclaim lands between the reader's open and its read — the exact window
	// that would corrupt the result if reclaim truncated instead of unlinking.
	removed := bridge_shell_output_reclaim("shl_racing")
	testing.expect(t, removed, "the reclaim did happen while the reader held the file open")
	testing.expect(t, !os.exists(path), "the path is gone for anyone who opens it AFTER the reclaim")

	size, serr := os.file_size(handle)
	testing.expect(t, serr == nil, "the open handle still stats")
	testing.expectf(t, int(size) == len(expected),
		"the open reader still sees the COMPLETE file: got %d bytes, want %d", int(size), len(expected))

	buf := make([]byte, int(size))
	defer delete(buf)
	n, rerr := os.read(handle, buf)
	testing.expect(t, rerr == nil, "and can still read through the handle")
	testing.expectf(t, n == len(expected), "reading it back yields every byte: got %d, want %d", n, len(expected))

	// A reader arriving after the reclaim gets the explicit answer, never a short read.
	_, state := bridge_shell_output_read("shl_racing")
	testing.expect(t, state == .Reclaimed, "a reader arriving after the reclaim is told so explicitly")
}

// ---- the tombstone lifecycle --------------------------------------------

// Tombstones are bounded too — a retention feature that swapped unbounded large
// files for unbounded small ones would only move the leak. They outlive the hub's
// 7-day row window and then go, at which point the id is correctly absent again:
// the row that could have asked about it was deleted three weeks earlier.
@(test)
bridge_shell8_tombstones_age_out_after_rows :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-tombstones")
	defer delete(dir)
	_clean_dir(dir)

	path := _write_output("shl_old", "output\n")
	defer delete(path)
	now := bridge_now_unix_ms()

	_, _ = bridge_shell_output_sweep(now + 6 * DAY_MS)
	tomb := bridge_shell_output_tombstone_path("shl_old")
	defer delete(tomb)
	testing.expect(t, os.exists(tomb), "reclaim leaves a tombstone")

	// Still well inside the tombstone window, and past the row window: the reader
	// must still be able to say "reclaimed" rather than "never existed".
	_, tombs_removed := bridge_shell_output_sweep(now + 20 * DAY_MS)
	testing.expect(t, tombs_removed == 0, "a tombstone outlives the 7-day row window")
	_, state := bridge_shell_output_read("shl_old")
	testing.expect(t, state == .Reclaimed, "and still reports reclaimed while a row could exist")

	_, tombs_removed2 := bridge_shell_output_sweep(now + 40 * DAY_MS)
	testing.expect(t, tombs_removed2 == 1, "past 30 days the tombstone itself is reclaimed")
	_, state2 := bridge_shell_output_read("shl_old")
	testing.expect(t, state2 == .Absent, "and the id is absent again, which is now the honest answer")
}

// The debounce is not a timer, and this pins the property that matters: a second
// trigger arriving immediately does no work. If this ever starts sweeping on every
// call, a busy bridge walks its session directory once per run.
@(test)
bridge_shell8_sweep_is_debounced_not_timed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := _retention_dir("/tmp/ham-shell8-debounce")
	defer delete(dir)
	_clean_dir(dir)

	bridge_shell_output_sweep_test_reset()
	defer bridge_shell_output_sweep_test_reset()

	// First call claims the slot; the second is inside the interval and returns
	// without touching the filesystem. Both are just calls — nothing scheduled them,
	// which is the whole point: no ticker exists to be found by AC5's grep.
	bridge_shell_output_sweep_if_due()
	path := _write_output("shl_after", "written between the two triggers\n")
	defer delete(path)
	bridge_shell_output_sweep_if_due()
	testing.expect(t, os.exists(path), "the debounced second trigger did not run a sweep")
}
