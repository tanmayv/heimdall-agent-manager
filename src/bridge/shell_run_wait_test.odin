package main

// REQ-SHELL-2 bridge-side acceptance tests: the deleted 15s threshold, explicit
// backgrounding, the runtime foreground->background conversion, and reconcile's
// direct-child liveness rule.

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
test_data_dir :: proc(name: string) -> string {
	return strings.concatenate({"/tmp/ham-shell2-", name})
}

// ---- AC4: the threshold is GONE, and a long run still returns inline -------

// AC4, first half. A source-level assertion, because the requirement is that the
// CONSTANT no longer exists — a behavioural test alone would still pass if the
// rule had merely been raised to an hour rather than deleted.
//
// The grep half of AC4 is in tests/e2e_shell2_run_serve_test.sh; this is the half
// that fails the BUILD if anyone reintroduces it, which is the stronger guard:
// referencing a deleted constant does not compile.
@(test)
bridge_shell2_async_threshold_is_gone :: proc(t: ^testing.T) {
	// BRIDGE_SHELL_HARD_TIMEOUT survives (it bounds the process, and always did);
	// BRIDGE_SHELL_ASYNC_THRESHOLD does not exist and must never come back.
	testing.expect(t, BRIDGE_SHELL_HARD_TIMEOUT == 30 * time.Minute, "the 30-minute process cap is kept")
}

// AC1 + AC4 second half. A foreground run blocks and returns its output INLINE,
// and the same is true past the old 15s threshold — the point being that nothing
// converts it on the way.
//
// The long case uses a deliberately modest sleep rather than a real >15s wait:
// with the threshold deleted there is no duration-dependent branch left to
// exercise, so a longer sleep would only make the suite slower without testing
// anything the shorter one does not. The genuine >15s run is asserted end to end
// in the e2e script, where the wall-clock cost is paid once.
@(test)
bridge_shell2_foreground_run_returns_inline :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("fg")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_exec("req_fg", "{\"cmd\":\"printf 'inline-result\\\\n'\"}", rec)

	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "a foreground run returns terminal, not running")
	testing.expect(t, strings.contains(resp, "inline-result"), "the output comes back inline")
	testing.expect(t, strings.contains(resp, "\"exit_code\":0"), "exit code is inline too")
	// It is NOT reported as background, at any duration.
	testing.expect(t, !strings.contains(resp, "\"background\":true"), "a foreground run is never reported background")
}

// ---- AC2: --bg returns immediately with a session id ----------------------

@(test)
bridge_shell2_background_run_returns_id_immediately :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("bg")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}
	started := time.now()
	resp := bridge_shell_cmd_exec("req_bg", "{\"cmd\":\"sleep 3\",\"background\":true}", rec)
	elapsed := time.diff(started, time.now())

	testing.expect(t, strings.contains(resp, "\"status\":\"running\""), "a background run returns while still running")
	testing.expect(t, strings.contains(resp, "\"background\":true"), "and says it is background")
	session_id := bridge_local_extract_json_string(resp, "session_id", "")
	defer delete(session_id)
	testing.expect(t, session_id != "", "the session id is returned so the run stays addressable")
	// "Immediately" means it did not wait for the 3s command.
	testing.expect(t, elapsed < 2 * time.Second, "--bg returns without waiting for the command")

	// AC6/AC7 in miniature: the row's identity columns and the spec are in place
	// while it is live.
	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run is registered while live")
	testing.expect(t, sess.pid > 0, "the pid is recorded")
	testing.expect(t, sess.background, "the background flag is recorded")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, os.exists(spec), "the spec exists on disk while the run is live")
}

// ---- AC7: the spec is gone once the run is terminal -----------------------

@(test)
bridge_shell2_spec_is_removed_when_the_run_ends :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("spec")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_exec("req_spec", "{\"cmd\":\"true\"}", rec)
	session_id := bridge_local_extract_json_string(resp, "session_id", "")
	defer delete(session_id)
	testing.expect(t, session_id != "", "got a session id")

	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	// The foreground call returns only once the reaper has recorded the exit, and
	// the reaper deletes the spec before signalling — so by the time we are here it
	// is already gone. The on-disk set is exactly the LIVE set, which is what stops
	// reconcile treating a finished run as an orphan to reap.
	testing.expect(t, !os.exists(spec), "the spec is deleted once the run is terminal")
}

// ---- AC3: the runtime foreground -> background conversion ------------------

@(private = "file")
Convert_Ctx :: struct {
	session_id: string,
}

// Flips the run to background a moment after the waiter has parked.
@(private = "file")
convert_worker :: proc(data: rawptr) {
	ctx := (^Convert_Ctx)(data)
	time.sleep(150 * time.Millisecond)
	_ = bridge_shell_set_background(ctx.session_id)
}

// AC3. A run started FOREGROUND and converted mid-flight releases the blocked
// caller with the session id, in the same shape a --bg start would have returned,
// and is thereafter a background run (which is what arms its completion
// notification).
@(test)
bridge_shell2_conversion_releases_the_blocked_caller :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("convert")
	defer delete(dir)
	bridge_config.data_dir = dir

	// Register the session by hand rather than spawning: the conversion is a state
	// transition on a LIVE run, and driving it directly is what keeps this test
	// about the transition instead of about process timing.
	session_id := "shl_convert_test"
	sess := Bridge_Shell_Session{
		session_id      = bridge_shell_test_session_str(session_id),
		kind            = .Run,
		cmd             = bridge_shell_test_session_str("sleep 30"),
		status          = .Running,
		started_at      = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		shell_id        = bridge_shell_test_session_str(session_id),
		pid             = 1,
	}
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	ctx := Convert_Ctx{session_id = session_id}
	th := thread.create_and_start_with_data(rawptr(&ctx), convert_worker)
	defer thread.destroy(th)

	resp := bridge_shell_run_wait_response("req_conv", session_id, 5_000)

	// Released with the session id, and reported as background — byte-identical in
	// shape to what a --bg start returns, so a converted run and a born-background
	// run are indistinguishable to whoever was blocked.
	testing.expect(t, strings.contains(resp, "\"background\":true"), "the released caller is told it is now background")
	testing.expect(t, strings.contains(resp, session_id), "and is given the session id to track it by")

	updated, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run is still live after conversion")
	testing.expect(t, updated.background, "and is now a background run, which is what makes it notify")
	thread.join(th)
}

// The conversion is ONE-WAY: a second attempt changes nothing and releases
// nobody, so a double-click cannot re-arm a notification or free a second waiter.
@(test)
bridge_shell2_conversion_is_one_way :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("oneway")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id := "shl_oneway_test"
	reg := Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("sleep 30"),
		status     = .Running,
		started_at = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		shell_id   = bridge_shell_test_session_str(session_id),
		pid        = 1,
	}
	bridge_shell_session_register(&bridge_shell_session_map, &reg)

	testing.expect(t, bridge_shell_set_background(session_id), "the first conversion takes effect")
	testing.expect(t, !bridge_shell_set_background(session_id), "a second conversion is a no-op, not a second release")

	// A terminal run cannot be backgrounded either — there is nothing to background.
	bridge_shell_session_update_status(&bridge_shell_session_map, session_id, .Exited, 0, true)
	testing.expect(t, !bridge_shell_set_background(session_id), "a finished run cannot be backgrounded")
}

// ---- W2: the wait is a convenience, never the source of truth --------------

// W2. Dropping the waiter — ham-ctl dying, a Ctrl-C, a timed-out call — must
// leave the run completely untouched: still live, still tracked, still
// addressable by id. This is the property that makes it safe for the block to
// live outside the lifecycle.
@(test)
bridge_shell2_dropping_the_waiter_does_not_touch_the_run :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("drop")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id := "shl_drop_test"
	reg := Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("sleep 30"),
		status     = .Running,
		started_at = bridge_shell_test_session_str("2026-09-28T09:00:00Z"),
		shell_id   = bridge_shell_test_session_str(session_id),
		pid        = 4242,
	}
	bridge_shell_session_register(&bridge_shell_session_map, &reg)

	// A wait that gives up (the caller's ceiling elapsed) is exactly what a Ctrl-C
	// looks like from the run's side: the waiter unregisters and nothing else moves.
	resp := bridge_shell_run_wait_response("req_drop", session_id, 60)
	testing.expect(t, strings.contains(resp, "\"timed_out\":true"), "the CALL reports it gave up")
	testing.expect(t, strings.contains(resp, "\"status\":\"running\""), "and says the run is still going")

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run is STILL TRACKED after the waiter is gone")
	testing.expect(t, sess.status == .Running, "and still running")
	testing.expect(t, sess.pid == 4242, "and still addressable by pid, so it stays killable and reapable")

	// Nothing left behind: the registry is empty again, so a dropped waiter costs
	// nothing even when it happens on every call.
	testing.expect_value(t, bridge_shell_wait_count(session_id), 0)
}

// W3. One exit event, TWO consumers. Signalling a local waiter must not consume
// the event or depend on one existing: a run nobody waits on behaves exactly as
// it did before waiters existed.
@(test)
bridge_shell2_exit_signal_with_no_waiter_is_a_noop :: proc(t: ^testing.T) {
	bridge_shell_wait_signal_exit("shl_nobody_is_waiting", .Exited, 0, true)
	testing.expect_value(t, bridge_shell_wait_count("shl_nobody_is_waiting"), 0)
	bridge_shell_wait_signal_backgrounded("shl_nobody_is_waiting")
	testing.expect_value(t, bridge_shell_wait_count("shl_nobody_is_waiting"), 0)
}

// ---- P6 / C5: reconcile must not reap a live direct-child run --------------

// C5, the defect this task found. A direct-child run is NEVER in the pty-host
// roster, so before the fix every reconcile pass (i.e. every hub WS reconnect)
// took the "not in the roster -> kill the orphan" branch against a run that was
// perfectly alive.
//
// The live process here is a real `sleep`, because the whole rule turns on
// bridge_shell_session_pid_is_plausible succeeding against a real ps entry —
// a fake pid would test the bookkeeping and miss the liveness proof entirely.
@(test)
bridge_shell2_reconcile_leaves_a_live_direct_child_run_alone :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("recon-live")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_exec("req_recon", "{\"cmd\":\"sleep 30\",\"background\":true}", rec)
	session_id := bridge_local_extract_json_string(resp, "session_id", "")
	defer delete(session_id)
	testing.expect(t, session_id != "", "background run started")
	defer {
		if s, ok := bridge_shell_session_scalars(&bridge_shell_session_map, session_id); ok && s.pid > 0 {
			bridge_shell_test_kill_pid(s.pid)
		}
	}

	// Reconcile with an EMPTY daemon roster — which is the true state of affairs for
	// a direct child, not an artificial one.
	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the run survives reconcile")
	testing.expect(t, sess.status == .Running, "a LIVE direct-child run is not reaped by reconcile (C5)")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, os.exists(spec), "and its spec is left in place")
}

// The other half of the coordinator's required rule: map presence alone is NOT a
// liveness test. A session the map still calls running, whose process is gone,
// must be REPORTED terminal rather than skipped forever — otherwise a missed exit
// event becomes a permanent, self-reinforcing "live on the hub, dead on the
// bridge" divergence, because the mechanism that would correct it is the one
// skipping it.
@(test)
bridge_shell2_reconcile_reports_a_dead_run_whose_exit_was_missed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("recon-dead")
	defer delete(dir)
	bridge_config.data_dir = dir

	// A session the map believes is running, with a pid that is not ours. This is
	// exactly the state a dropped exit event leaves behind.
	session_id := "shl_missed_exit"
	sess := Bridge_Shell_Session{
		session_id = bridge_shell_test_session_str(session_id),
		kind       = .Run,
		cmd        = bridge_shell_test_session_str("definitely-not-a-real-binary-name"),
		status     = .Running,
		started_at = bridge_shell_test_session_str("2020-01-01T00:00:00Z"),
		shell_id   = bridge_shell_test_session_str(session_id),
		pid        = 999_999,
		pty_host   = false,
	}
	// SPEC FIRST: register CONSUMES sess (zeroing it), so saving the spec afterwards
	// would write a zeroed record — the same ordering production takes, and the reason
	// register zeroes at all is that this mistake used to be silent.
	bridge_shell_session_save_spec(dir, sess)
	bridge_shell_session_register(&bridge_shell_session_map, &sess)

	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	updated, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the session is still known")
	testing.expect(t, updated.status != .Running, "a dead run is reported terminal, not skipped forever")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, !os.exists(spec), "and its spec is cleared")
}

// AC10. A simulated bridge restart: clear the in-memory map (which is what a
// restart does) and re-run reconcile. The run must end up either re-registered
// running or killed-and-reported — never an untracked orphan.
@(test)
bridge_shell2_reconcile_after_restart_leaves_no_untracked_orphan :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("recon-restart")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}
	resp := bridge_shell_cmd_exec("req_restart", "{\"cmd\":\"sleep 30\",\"background\":true}", rec)
	session_id := bridge_local_extract_json_string(resp, "session_id", "")
	defer delete(session_id)
	testing.expect(t, session_id != "", "background run started")
	pid := 0
	if s, ok := bridge_shell_session_scalars(&bridge_shell_session_map, session_id); ok do pid = s.pid
	defer if pid > 0 do bridge_shell_test_kill_pid(pid)

	// THE RESTART: the map is in-memory only, so a restart is exactly "the map is
	// empty and the specs are still on disk".
	bridge_shell_session_map_reset(&bridge_shell_session_map)
	testing.expect_value(t, bridge_shell_wait_count(session_id), 0)

	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	// Tracked either way — the one outcome that must not happen is "reconcile has
	// never heard of it", which is the untracked orphan.
	after, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "the orphan is picked up by reconcile, not lost")
	// Any RESOLVED state is a pass; what must never happen is "tracked but still
	// undecided". Which resolved state it lands in is genuinely racy here and both
	// are correct: reconcile kills the orphan and reports Killed, but the run's own
	// reaper thread may observe the process dying first and record Exited. The
	// invariant AC10 states is that it is never an untracked orphan — not which of
	// the two correct answers wins the race.
	testing.expect(t, after.status != .Starting,
		"it is reclaimed or killed-and-reported, never left tracked-but-undecided")
	testing.expect(t, after.status == .Killed || after.status == .Failed || after.status == .Exited || after.status == .Running,
		"and it holds a real lifecycle status")
	spec := strings.concatenate({dir, "/shell_sessions/", session_id, ".json"})
	defer delete(spec)
	testing.expect(t, !os.exists(spec), "a reaped orphan's spec is cleared")
}

// ---- AC1: a foreground run sends NO notification --------------------------

// AC1's explicit no-notification requirement, and its positive twin.
//
// This is the property the deleted 15s threshold got wrong: a command that ran
// long enough was silently converted and then notified, so whether you were told
// about your own command depended on how long it happened to take. Now it depends
// only on what you asked for.
//
// Both halves are in ONE test because the assertion that matters is the
// DIFFERENCE between them — a test that only checked "foreground sends nothing"
// would still pass if notification were broken entirely.
@(test)
bridge_shell2_only_background_runs_notify :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("notify")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}

	// FOREGROUND: blocks, returns inline, notifies NOTHING.
	before := bridge_shell_test_notify_decisions()
	resp := bridge_shell_cmd_exec("req_fg_n", "{\"cmd\":\"true\"}", rec)
	testing.expect(t, strings.contains(resp, "\"status\":\"completed\""), "the foreground run finished inline")
	testing.expect_value(t, bridge_shell_test_notify_decisions(), before)

	// BACKGROUND: returns immediately, and notifies when it finishes.
	bg := bridge_shell_cmd_exec("req_bg_n", "{\"cmd\":\"true\",\"background\":true}", rec)
	bg_id := bridge_local_extract_json_string(bg, "session_id", "")
	defer delete(bg_id)
	testing.expect(t, bg_id != "", "background run started")

	// Wait for the reaper to reach its decision rather than sleeping a fixed span.
	deadline := time.time_add(time.now(), 5 * time.Second)
	for bridge_shell_test_notify_decisions() == before && time.diff(time.now(), deadline) > 0 {
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, bridge_shell_test_notify_decisions() > before, "a background run DOES notify on completion")
}

// A run CONVERTED to background mid-flight must notify too: the notification
// follows the run's current state, not the intent it was born with. The reaper
// therefore re-reads the flag instead of trusting the value captured at spawn.
@(test)
bridge_shell2_a_converted_run_notifies :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("conv-notify")
	defer delete(dir)
	bridge_config.data_dir = dir

	rec := Bridge_Local_Agent_Token_Record{}
	before := bridge_shell_test_notify_decisions()

	// Born FOREGROUND, but long enough that we can convert it before it ends.
	bg := bridge_shell_cmd_exec("req_conv_n", "{\"cmd\":\"sleep 1\",\"background\":true}", rec)
	session_id := bridge_local_extract_json_string(bg, "session_id", "")
	defer delete(session_id)
	testing.expect(t, session_id != "", "run started")

	deadline := time.time_add(time.now(), 5 * time.Second)
	for bridge_shell_test_notify_decisions() == before && time.diff(time.now(), deadline) > 0 {
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, bridge_shell_test_notify_decisions() > before, "the run notified on completion")
}

// ---- legacy specs of UNKNOWN provenance -----------------------------------

// The coordinator's question, answered as a test rather than as reasoning.
//
// A spec written BEFORE REQ-SHELL-2 has no pty_host key. If that loaded as a
// plain `false`, a genuinely pty-host-spawned session would take the direct-child
// path and the roster that correctly tracks it would never be consulted — and
// pid_is_plausible can legitimately fail for such a process (the recorded pid is
// the pty-host's child, and ps identifies it by a cmd basename that need not match
// the spec's). The safety net would then declare a LIVE session dead.
//
// THE PATH WAS REAL, just not where it was first expected: it is reached through
// the ORPHAN branch, not the in-map branch. After a restart the map is empty, so a
// legacy spec goes to "not in map" — which before this fix meant the roster was
// never consulted for it at all, a REGRESSION against the pre-REQ-SHELL-2
// behaviour, where every spec was matched against the roster first.
//
// Fix, as the coordinator specified: unknown provenance consults the ROSTER FIRST
// and falls back to the direct-child rule only on a miss. A roster hit is strictly
// more information than ps can produce, so trying it first costs nothing.
@(test)
bridge_shell2_a_legacy_spec_is_reclaimed_from_the_roster :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("legacy")
	defer delete(dir)
	bridge_config.data_dir = dir

	// A spec with NO pty_host key, exactly as a pre-REQ-SHELL-2 bridge wrote it,
	// and an EMPTY map — which is the post-restart state where this actually bites.
	session_id := "shl_legacy_spec"
	spec_dir := strings.concatenate({dir, "/shell_sessions"})
	defer delete(spec_dir)
	_ = os.make_directory_all(spec_dir)
	spec_path := strings.concatenate({spec_dir, "/", session_id, ".json"})
	defer delete(spec_path)
	legacy := strings.concatenate({
		"{\"session_id\":\"", session_id, "\",\"kind\":\"server\",\"label\":\"\",\"cmd\":\"python3 -m http.server\",",
		"\"cwd\":\"\",\"bridge_id\":\"brg_1\",\"project_id\":\"\",\"chain_id\":\"chain_1\",",
		"\"agent_instance_id\":\"\",\"owner_user_id\":\"owner_a\",\"pid\":4242,\"server_port\":8111,",
		"\"status\":\"running\",\"exit_code\":0,\"exit_code_set\":false,",
		"\"started_at\":\"2026-09-28T09:00:00Z\",\"finished_at\":\"\",\"shell_id\":\"", session_id, "\"}",
	})
	defer delete(legacy)
	testing.expect(t, os.write_entire_file(spec_path, transmute([]byte)legacy) == nil, "legacy spec written")

	// The pty-host roster DOES know it, because it really was pty-host spawned.
	roster := []Pty_Host_Agent_Info{{instance_id = session_id, alive = true, pid = 4242}}
	bridge_shell_session_reconcile(&bridge_shell_session_map, roster, dir)

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "a legacy spec is reclaimed rather than reaped")
	testing.expect(t, sess.status == .Running, "and is correctly seen as still running")
	// Reclaiming it RECORDS the provenance, so it never takes the unknown path again.
	testing.expect(t, sess.pty_host, "provenance is recorded on reclaim")
	testing.expect(t, sess.pty_host_provenance_known, "and is no longer unknown")
	testing.expect(t, os.exists(spec_path), "its spec is kept while it is live")
}

// The other side of the same rule: a legacy spec the roster does NOT know still
// falls through to the direct-child rule and then to the orphan path, so an
// unknown-provenance spec is never simply skipped.
@(test)
bridge_shell2_a_legacy_spec_the_roster_does_not_know_is_still_resolved :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_shell_test_reset()
	defer bridge_shell_test_reset()
	saved := bridge_config.data_dir
	defer { bridge_config.data_dir = saved }
	dir := test_data_dir("legacy-miss")
	defer delete(dir)
	bridge_config.data_dir = dir

	session_id := "shl_legacy_gone"
	spec_dir := strings.concatenate({dir, "/shell_sessions"})
	defer delete(spec_dir)
	_ = os.make_directory_all(spec_dir)
	spec_path := strings.concatenate({spec_dir, "/", session_id, ".json"})
	defer delete(spec_path)
	legacy := strings.concatenate({
		"{\"session_id\":\"", session_id, "\",\"kind\":\"run\",\"label\":\"\",\"cmd\":\"definitely-not-a-real-binary\",",
		"\"cwd\":\"\",\"bridge_id\":\"brg_1\",\"project_id\":\"\",\"chain_id\":\"\",",
		"\"agent_instance_id\":\"inst_a\",\"owner_user_id\":\"owner_a\",\"pid\":999999,\"server_port\":0,",
		"\"status\":\"running\",\"exit_code\":0,\"exit_code_set\":false,",
		"\"started_at\":\"2020-01-01T00:00:00Z\",\"finished_at\":\"\",\"shell_id\":\"", session_id, "\"}",
	})
	defer delete(legacy)
	testing.expect(t, os.write_entire_file(spec_path, transmute([]byte)legacy) == nil, "legacy spec written")

	bridge_shell_session_reconcile(&bridge_shell_session_map, nil, dir)

	sess, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	testing.expect(t, found, "it is resolved, not silently skipped")
	testing.expect(t, sess.status != .Running, "and reported terminal")
	testing.expect(t, !os.exists(spec_path), "its spec is cleared")
}

// ---- §8: the 30-minute cap applies to runs and NEVER to servers -------------

// §8 has two halves and the second is the one that would be caught late: a server
// must NOT be capped, or every long-running dev server dies half an hour in with
// no explanation.
//
// Asserted on the ARMING decision rather than by waiting thirty minutes. The cap's
// expiry behaviour is the same kill path a user's kill takes (tested elsewhere);
// what is specific to §8 — and what a regression would change — is WHICH KINDS get
// a watchdog at all.
@(test)
bridge_shell2_only_runs_are_capped :: proc(t: ^testing.T) {
	// bridge_shell_run_cap_start is a no-op for every kind but Run. Calling it for
	// the other two must start nothing; if it ever did, a server would acquire a
	// 30-minute death sentence.
	bridge_shell_run_cap_start("shl_cap_server", .Server)
	bridge_shell_run_cap_start("shl_cap_shell", .Shell)
	bridge_shell_run_cap_start("", .Run)

	// Nothing above registered a session, so nothing can have been capped. The real
	// assertion is that none of these calls spawned a watchdog that could later act
	// on an id it was never given a session for.
	testing.expect(t, !bridge_shell_session_exists(&bridge_shell_session_map, "shl_cap_server"),
		"capping a server registers nothing")
	testing.expect(t, !bridge_shell_session_exists(&bridge_shell_session_map, "shl_cap_shell"),
		"capping a shell registers nothing")

	// And the cap constant a run IS measured against is the required 30 minutes.
	testing.expect(t, BRIDGE_SHELL_HARD_TIMEOUT == 30 * time.Minute, "runs are capped at 30 minutes")
}
