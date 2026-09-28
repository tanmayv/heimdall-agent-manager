package main

// REQ-SHELL-8: rolling retention for bridge-side shell output.
//
// Output capture is unchanged and stays that way: the child's stdout+stderr are
// redirected into a file at spawn (shell_cmd.odin for a direct child, the
// pty-host tee_path for a server) and read back on demand. What this file adds is
// the LIFECYCLE that never existed — before it, every .out file written since the
// feature shipped was still on disk and nothing ever removed one.
//
// Three rules govern the whole mechanism:
//
//   1. RECLAIM IS EVENT-DRIVEN, NOT TIMED. There is no ticker here and there must
//      not be one: the user ruled polling out for status, and aging files out on a
//      timer would smuggle the same thing back in under another name. The sweep
//      runs at moments that already happen — bridge start, a session create, a hub
//      reconnect — and bridge_shell_output_sweep_if_due rate-limits it so a burst
//      of runs does not turn into a burst of directory walks. That rate limit is a
//      debounce on an event, not a schedule: nothing wakes up to check it.
//
//   2. A LIVE SESSION IS NEVER RECLAIMED, AT ANY AGE. A server can legitimately run
//      for weeks while writing nothing, so its mtime is not evidence of anything.
//      Liveness is decided by the session map and the on-disk spec, never by age —
//      see bridge_shell_output_session_is_live for why it takes BOTH.
//
//   3. RECLAIM IS TOMBSTONE-THEN-UNLINK, NEVER TRUNCATE. See
//      bridge_shell_output_reclaim: this is what makes "a reclaim concurrent with an
//      open read" a non-event rather than a race.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// ---- the retention windows ----------------------------------------------
//
// These three constants form ONE ordered chain, and each inequality exists for a
// reason that outlives whoever set the numbers:
//
//     output 5 days  <  rows 7 days  <  tombstones 30 days
//
// Each is documented at its own constant with the inequality it must preserve.
// Changing any one of them in isolation breaks a property, so change them as a
// set. The row window is HUB_SHELL_SESSION_ROW_RETENTION_MS in
// src/hub/service/shell_session/shell_session_retention.odin — it is on the other
// side of the wire but it is the middle link of this same chain.

// BRIDGE_SHELL_OUTPUT_RETENTION is the user's 5-day window: output older than this
// is reclaimed. It is the SHORTEST of the three windows, which is the point — it is
// the only one bounded by output VOLUME, and the reason the other two exist is to
// stay out of its way.
BRIDGE_SHELL_OUTPUT_RETENTION :: 5 * 24 * time.Hour

// BRIDGE_SHELL_TOMBSTONE_RETENTION bounds the residue the reclaim itself leaves.
// It must be GREATER than the hub's row retention (7 days): a tombstone is the only
// thing that can tell a reader "this output was reclaimed" rather than "no such
// session", so it has to outlive every row that could still ask the question. 30
// days is far clear of 7 and costs nothing to hold — a tombstone is a zero-byte
// file, so this residue is bounded by the RUN RATE, not by output volume, which is
// what makes a window this long safe in a task about bounding disk growth.
//
// Past 30 days the tombstone goes too, and a read for that session correctly
// becomes not_found: the row it belonged to was deleted three weeks earlier, so
// there is no longer anyone who can coherently ask.
BRIDGE_SHELL_TOMBSTONE_RETENTION :: 30 * 24 * time.Hour

// BRIDGE_SHELL_OUTPUT_SWEEP_MIN_INTERVAL debounces the event-driven sweep. An agent
// firing a hundred runs in a minute should not walk the session directory a hundred
// times to discover the same nothing. This is NOT a timer: no thread waits on it and
// nothing fires when it elapses — it only makes an already-occurring event cheap.
BRIDGE_SHELL_OUTPUT_SWEEP_MIN_INTERVAL :: time.Hour

// The refusal a reader gets for output that was reclaimed. It is deliberately
// distinct from an empty log and from a bridge-offline failure: the hub maps this
// code to domain .Gone, while offline stays .Bridge_Offline and a genuinely empty
// log is a SUCCESS carrying zero lines. Those three were indistinguishable before
// REQ-SHELL-8 — every reader turned a missing file into empty output.
BRIDGE_SHELL_OUTPUT_RECLAIMED_CODE :: "output_reclaimed"
BRIDGE_SHELL_OUTPUT_RECLAIMED_MESSAGE :: "output no longer available: reclaimed by the 5-day retention window"

// Bridge_Shell_Output_State is the three-way answer every output reader needs, and
// the reason this is an enum rather than a bool: "no bytes" and "no file" are not
// the same fact, and collapsing them is exactly the bug being fixed.
//
//   Available — the .out file exists. It may be ZERO BYTES, and that is a real,
//               successful, empty log: a command that printed nothing. Presence is
//               the key, never size.
//   Reclaimed — the .out is gone and a tombstone proves retention took it.
//   Absent    — neither exists: an id that never ran here, or one whose tombstone
//               has itself aged out. Genuinely not_found, and it must stay that way.
Bridge_Shell_Output_State :: enum {
	Available,
	Reclaimed,
	Absent,
}

@(private = "file")
_bridge_shell_output_sweep_mu: sync.Mutex
@(private = "file")
_bridge_shell_output_last_sweep_ms: i64 // 0 = never swept

// ---- paths ---------------------------------------------------------------

// The tombstone sits beside the output it replaces, suffixed rather than renamed,
// so that: a *.out scan never matches one (".out.reclaimed" does not end in ".out"),
// bridge_shell_session_load_specs never matches one (it filters *.json), and the
// session id is recoverable from either spelling by trimming a known suffix.
BRIDGE_SHELL_OUTPUT_SUFFIX :: ".out"
BRIDGE_SHELL_TOMBSTONE_SUFFIX :: ".out.reclaimed"

bridge_shell_output_tombstone_path :: proc(session_id: string) -> string {
	dir := bridge_shell_output_dir()
	defer delete(dir)
	return strings.concatenate({dir, "/", session_id, BRIDGE_SHELL_TOMBSTONE_SUFFIX})
}

// ---- reading -------------------------------------------------------------

// bridge_shell_output_read is the ONE way to get output off disk. Every reader goes
// through it so the three-state answer is produced in a single place; before this,
// each of the three call sites open-coded `if rerr == nil do output = string(raw)`
// and each independently turned a missing file into an empty string.
//
// When state is .Available the returned content is heap-allocated and owned by the
// caller; for the other two states it is "" and there is nothing to free.
bridge_shell_output_read :: proc(session_id: string) -> (content: string, state: Bridge_Shell_Output_State) {
	path := bridge_shell_output_path(session_id)
	defer delete(path)

	raw, rerr := os.read_entire_file(path, context.allocator)
	if rerr == nil {
		// Includes the zero-byte case, and deliberately so: a run that printed
		// nothing has a real, empty, AVAILABLE log. Only absence means anything else.
		return string(raw), .Available
	}

	tomb := bridge_shell_output_tombstone_path(session_id)
	defer delete(tomb)
	if os.exists(tomb) do return "", .Reclaimed
	return "", .Absent
}

// ---- reclaiming ----------------------------------------------------------

// bridge_shell_output_reclaim frees one session's output. The ORDER of the two
// steps is the whole design, and neither is interchangeable with an alternative:
//
//   1. Write the tombstone FIRST. Doing it after the unlink would leave a window in
//      which neither file exists, and a read landing in that window would answer
//      not_found for output that retention had just taken — the wrong one of the
//      three states.
//
//   2. UNLINK the output; never truncate it, and never reopen it O_TRUNC. On POSIX
//      an unlink cannot shorten a file a reader has already opened: that reader
//      holds the inode and goes on seeing the complete contents until it closes.
//      So a read racing a reclaim resolves to exactly one of "the whole file" or
//      ENOENT->.Reclaimed — never a truncated file presented as a complete one.
//      A truncate would have no such property: it would silently hand back a short
//      log that looks finished, which is the failure AC4 exists to prevent.
//
// Returns whether an output file was actually removed.
bridge_shell_output_reclaim :: proc(session_id: string) -> bool {
	path := bridge_shell_output_path(session_id)
	defer delete(path)
	if !os.exists(path) do return false

	tomb := bridge_shell_output_tombstone_path(session_id)
	defer delete(tomb)
	if !os.exists(tomb) {
		// Zero bytes on purpose: the tombstone's existence IS the whole message, and
		// an empty file makes the 30-day residue bounded by run count alone.
		_ = os.write_entire_file(tomb, []byte{})
	}

	if err := os.remove(path); err != nil {
		// The tombstone now lies: it says reclaimed while the output is still there
		// and readable. Take it back rather than leave the two disagreeing — the
		// reader's precedence checks the .out first, but a later successful reclaim
		// would otherwise skip writing a tombstone it thinks it already wrote.
		_ = os.remove(tomb)
		return false
	}
	return true
}

// ---- liveness ------------------------------------------------------------

// bridge_shell_output_session_is_live answers the one question retention must never
// get wrong (AC2): may this session's output be taken? It takes BOTH available
// signals, because each alone has a hole:
//
//   - The SESSION MAP is authoritative while the bridge has been up long enough to
//     hold the session, but it is EMPTY at process start — and the sweep runs at
//     start. A server that has been up for six days across a bridge restart would
//     be absent from the map at exactly the moment the sweep looked, and losing a
//     live server's log is the single worst outcome available here.
//
//   - The on-disk SPEC covers precisely that hole: specs are written before the
//     process is spawned and deleted only at terminal status, so a spec on disk
//     means "this session was live when the bridge last knew anything about it".
//
// Age is not consulted and must not be: an idle server writes nothing for weeks
// while remaining perfectly alive, so mtime is evidence about OUTPUT, never about
// the process. `spec_ids` is the set of session ids holding a spec, gathered once
// per sweep from the directory listing the sweep is already walking.
bridge_shell_output_session_is_live :: proc(session_id: string, spec_ids: ^map[string]bool) -> bool {
	if spec_ids != nil && spec_ids^[session_id] do return true
	if scalars, ok := bridge_shell_session_scalars(&bridge_shell_session_map, session_id); ok {
		if !bridge_shell_session_status_is_terminal(scalars.status) do return true
	}
	return false
}

// ---- the sweep -----------------------------------------------------------

// bridge_shell_output_sweep reclaims aged output and aged tombstones in ONE walk of
// the session directory, and is the only proc that removes either.
//
// `now_unix_ms` is a parameter rather than a call to the clock so age can be
// INJECTED by a test: reaching a 5-day boundary by sleeping is not a test anyone can
// run. Production callers pass bridge_now_unix_ms().
//
// REQ-SHELL-9 NOTE: this is deliberately one proc over one listing so that reaping
// servers can extend this pass instead of adding a second walk of the same tree.
bridge_shell_output_sweep :: proc(now_unix_ms: i64) -> (outputs_reclaimed: int, tombstones_removed: int) {
	dir := bridge_shell_output_dir()
	defer delete(dir)

	infos, rerr := os.read_directory_by_path(dir, -1, context.allocator)
	if rerr != nil do return 0, 0 // nothing has ever run here
	defer os.file_info_slice_delete(infos, context.allocator)

	// Pass 1: the specs, which are the liveness evidence pass 2 needs. Gathering
	// them from this listing rather than re-reading the directory keeps the sweep to
	// a single walk, and keeps the two passes looking at ONE consistent snapshot.
	spec_ids := make(map[string]bool, 0, context.allocator)
	defer delete(spec_ids)
	for info in infos {
		if !strings.has_suffix(info.name, ".json") do continue
		spec_ids[info.name[:len(info.name) - len(".json")]] = true
	}

	output_cutoff := now_unix_ms - i64(BRIDGE_SHELL_OUTPUT_RETENTION / time.Millisecond)
	tomb_cutoff := now_unix_ms - i64(BRIDGE_SHELL_TOMBSTONE_RETENTION / time.Millisecond)

	for info in infos {
		mtime_ms := time.to_unix_nanoseconds(info.modification_time) / 1_000_000

		if strings.has_suffix(info.name, BRIDGE_SHELL_TOMBSTONE_SUFFIX) {
			if mtime_ms < tomb_cutoff {
				if os.remove(info.fullpath) == nil do tombstones_removed += 1
			}
			continue
		}
		if !strings.has_suffix(info.name, BRIDGE_SHELL_OUTPUT_SUFFIX) do continue

		session_id := info.name[:len(info.name) - len(BRIDGE_SHELL_OUTPUT_SUFFIX)]
		// Liveness is checked BEFORE age, and short-circuits it. Written this way on
		// purpose: it reads as "a live session is never reclaimed, full stop", which
		// is the rule, rather than as "old files are reclaimed, with an exception".
		if bridge_shell_output_session_is_live(session_id, &spec_ids) do continue
		if mtime_ms >= output_cutoff do continue
		if bridge_shell_output_reclaim(session_id) do outputs_reclaimed += 1
	}
	return outputs_reclaimed, tombstones_removed
}

// bridge_shell_output_sweep_if_due is what the event triggers call. It is the
// debounce described at BRIDGE_SHELL_OUTPUT_SWEEP_MIN_INTERVAL plus a single-flight
// guard, so two concurrent triggers (a reconnect landing on top of a session create)
// cannot walk the directory twice or race each other into the same reclaim.
bridge_shell_output_sweep_if_due :: proc() {
	now := bridge_now_unix_ms()

	sync.mutex_lock(&_bridge_shell_output_sweep_mu)
	last := _bridge_shell_output_last_sweep_ms
	due := last == 0 || now - last >= i64(BRIDGE_SHELL_OUTPUT_SWEEP_MIN_INTERVAL / time.Millisecond)
	// Claim the slot before releasing the lock: a second trigger arriving mid-sweep
	// sees the timestamp already moved and returns rather than starting its own.
	if due do _bridge_shell_output_last_sweep_ms = now
	sync.mutex_unlock(&_bridge_shell_output_sweep_mu)
	if !due do return

	outputs, tombs := bridge_shell_output_sweep(now)
	if outputs > 0 || tombs > 0 {
		fmt.println("bridge shell retention: reclaimed", outputs, "output files,", tombs, "tombstones")
	}
}

// bridge_shell_output_sweep_test_reset clears the debounce so a test can run the
// sweep more than once. Tests only — production has no reason to force a sweep.
bridge_shell_output_sweep_test_reset :: proc() {
	sync.mutex_lock(&_bridge_shell_output_sweep_mu)
	_bridge_shell_output_last_sweep_ms = 0
	sync.mutex_unlock(&_bridge_shell_output_sweep_mu)
}
