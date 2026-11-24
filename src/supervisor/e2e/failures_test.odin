// T15 (spec §18, report §7 Phase 1): failing candidates, failing rollback and repair, and
// clean vs unclean stops during probation, with the real launcher and supervisor.
package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// expect_rolled_back waits for op `op_id`, then checks it was rolled back to `good`
// (current = known-good = good, one runtime alive) and that `version` is pinned.
expect_rolled_back :: proc(i: ^Inst, op_id, good, version: string, timeout := 240 * time.Second) -> bool {
	@(static) want_op: string
	want_op = op_id
	if !wait_for(i, fmt.tprintf("%s ends", op_id), timeout, proc(i: ^Inst) -> bool {return op_done(i, want_op)}) do return false
	st, code, note := op_final(i, op_id)
	ok := testing.expectf(i.s.t, st == "rolled_back", "%s: %s ended %s %s (%s), want rolled_back", i.name, op_id, st, code, note)
	log.infof("%s: %s -> %s %s (%s)", i.name, op_id, st, code, note)
	g_want = good
	running_again :: proc(i: ^Inst) -> bool {
		return current(i) == g_want && known_good(i) == g_want && live_runtimes(i) == 1 && last_runtime(i).tree == g_want
	}
	if !wait_for(i, fmt.tprintf("%s running again after %s", good, op_id), 60 * time.Second, running_again) do return false
	ok &= testing.expectf(i.s.t, strings.contains(pins(i), version), "%s: %s pinned: %s", i.name, version, pins(i))
	return ok
}

// Failing candidate in every way the spec names: runtime never ready, runtime unhealthy
// after ready, supervisor never READY (launcher T_ready fallback), supervisor exits 78 in
// probation (launcher fallback). Each one is rolled back to v0.6.0 and pinned; v0.6.0's
// runtime is the only one left. (Crash in probation: test_supervisor_end_to_end step 3.)
@(test)
test_failing_candidates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "candidates") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	if !install(a, "v0.6.0") do return

	Case :: struct {
		tag:  string,
		opts: Release_Opts,
		code: string, // expected journal error ("" = any)
	}
	cases := []Case {
		{"v0.6.1", {behaviour = "noready"}, "runtime_not_ready"},
		{"v0.6.2", {behaviour = "unhealthy"}, "runtime_unhealthy"},
		{"v0.6.3", {sup_behaviour = "noready"}, ""},
		{"v0.6.4", {sup_behaviour = "exit78"}, ""},
	}
	for c, n in cases {
		publish(&s, c.tag, c.opts)
		op := fmt.tprintf("op_cand_%d", n + 1)
		send_intent(a, op, "install_version", fmt.tprintf(`,"version":"%s"`, c.tag))
		if !expect_rolled_back(a, op, t0, c.tag[1:]) do return
		if c.code != "" {
			_, code, _ := op_final(a, op)
			testing.expectf(t, code == c.code, "%s: error %s, want %s", c.tag, code, c.code)
		}
	}
	testing.expect_value(t, stop_launcher(a), 0)
	testing.expect_value(t, live_runtimes(a), 0)
}

// Failing rollback (J25 rollback_failed) and the repair paths out of it:
//   1. v0.6.1 crashes in probation; its rollback target v0.6.0 now crashes too ->
//      rollback_failed, no runtime; sticky across a launcher restart;
//   2. `ham-supervisor repair` with v0.6.0's bundle while its tree is intact -> exit 0
//      `noop up_to_date` that says the instance is STILL in rollback_failed; a restart
//      still starts no runtime (T13b review note);
//   3. the v0.6.0 tree is damaged; repair with its bundle installs a `-r<n>` tree, the
//      launcher proves it, rollback_failed is over.
@(test)
test_failing_rollback_and_repair :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "rollback") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	if !install(a, "v0.6.0") do return

	// 1.
	publish(&s, "v0.6.1", {behaviour = "crash", stable = true})
	set_behaviour(a, t0, "crash") // the rollback target's next start fails as well
	send_intent(a, "op_rb_bad", "install_version", `,"version":"v0.6.1"`)
	if !wait_for(a, "op_rb_bad ends", 240 * time.Second, proc(i: ^Inst) -> bool {return op_done(i, "op_rb_bad")}) do return
	st, code, note := op_final(a, "op_rb_bad")
	testing.expectf(t, st == "rollback_failed", "op_rb_bad ended %s %s (%s), want rollback_failed", st, code, note)
	if !wait_for(a, "no runtime in rollback_failed", 30 * time.Second, proc(i: ^Inst) -> bool {return live_runtimes(i) == 0}) do return
	testing.expect_value(t, current(a), t0)
	testing.expectf(t, strings.contains(pins(a), "0.6.1"), "v0.6.1 pinned: %s", pins(a))
	starts := len(runtimes(a))
	testing.expect_value(t, stop_launcher(a), 0)
	start_launcher(a)
	time.sleep(10 * time.Second)
	testing.expectf(t, len(runtimes(a)) == starts, "rollback_failed is sticky: no runtime start after a restart (%d -> %d)", starts, len(runtimes(a)))
	testing.expect_value(t, live_runtimes(a), 0)
	testing.expect_value(t, stop_launcher(a), 0)

	// 2. Intact tree: noop, and it says so.
	set_behaviour(a, t0, "good")
	res := repair(a, "v0.6.0", "op_rb_repair_noop")
	testing.expectf(t, res.ok && res.code == 0, "repair of the intact tree: exit %d", res.code)
	testing.expectf(t, strings.contains(res.output, "noop up_to_date") && strings.contains(res.output, "STILL in rollback_failed"), "repair output names rollback_failed: %q", res.output)
	st, _, note = op_final(a, "op_rb_repair_noop")
	testing.expectf(t, st == "noop" && note == "up_to_date", "repair op %s %s", st, note)
	start_launcher(a)
	time.sleep(10 * time.Second)
	testing.expectf(t, len(runtimes(a)) == starts, "still rollback_failed after the noop repair (%d -> %d)", starts, len(runtimes(a)))
	testing.expect_value(t, stop_launcher(a), 0)

	// 3. Damaged tree: repair installs a -r<n> tree and the service proves it.
	damaged := pj(a.data, "releases", t0, "bin", "test-version.txt")
	testing.expect(t, os.write_entire_file(damaged, transmute([]byte)string("damaged")) == nil, "damage the tree")
	res = repair(a, "v0.6.0", "op_rb_repair")
	testing.expectf(t, res.ok && res.code == 0, "repair of the damaged tree: exit %d", res.code)
	@(static) rtree: string
	rtree = strings.clone(current(a))
	defer delete(rtree)
	testing.expectf(t, rtree != t0 && strings.has_prefix(rtree, t0) && strings.contains(rtree, "-r"), "repair tree %s (damaged %s)", rtree, t0)
	start_launcher(a)
	repaired :: proc(i: ^Inst) -> bool {
		return known_good(i) == rtree && live_runtimes(i) == 1 && last_runtime(i).tree == rtree
	}
	if !wait_for(a, "repaired tree committed", 90 * time.Second, repaired) do return
	st, _, _ = op_final(a, "op_rb_repair")
	testing.expectf(t, st == "committed", "op_rb_repair %s", st)
	testing.expect_value(t, stop_launcher(a), 0)
	testing.expect_value(t, live_runtimes(a), 0)
}

// Service stops during probation (spec §7.5, §18; T9 carry-over (c)):
//   - three CLEAN stops (stop-request file: the graceful path on every OS, and on Windows
//     the one an SSH/headless caller can use) do not count -> the candidate still commits;
//   - three UNCLEAN stops (the launcher killed hard: SIGKILL / TerminateProcess, which is
//     what `schtasks /End` and a logoff do to the launcher's job on Windows) count -> the
//     candidate is rolled back (probation_interrupted) and pinned.
@(test)
test_stops_during_probation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "stops") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	a.probation_s = 40
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	if !install(a, "v0.6.0") do return

	// probation_starts: probation lines of `op` (one per supervisor start that runs it).
	probation_starts :: proc(i: ^Inst, op: string) -> int {
		n := 0
		for l in journal(i) do if l.op_id == op && l.state == "probation" && l.sub != "probation_suspended" do n += 1
		return n
	}
	@(static) want_starts: int

	// Clean stops.
	t1 := strings.clone(publish(&s, "v0.6.1"))
	defer delete(t1)
	send_intent(a, "op_clean", "install_version", `,"version":"v0.6.1"`)
	for n in 0 ..< 3 {
		want_starts = n + 1
		if !wait_for(a, fmt.tprintf("op_clean in probation (%d)", n), 120 * time.Second, proc(i: ^Inst) -> bool {return probation_starts(i, "op_clean") >= want_starts}) do return
		time.sleep(2 * time.Second)
		testing.expect_value(t, stop_launcher(a), 0)
		testing.expect_value(t, live_runtimes(a), 0)
		start_launcher(a)
	}
	g_want = t1
	if !wait_for(a, "op_clean committed after 3 clean stops", 180 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	st, code, _ := op_final(a, "op_clean")
	testing.expectf(t, st == "committed", "op_clean %s %s", st, code)

	// Unclean stops: kill the launcher (and, where the OS does not do it for us, the
	// supervisor) hard while the candidate is in probation.
	publish(&s, "v0.6.2")
	send_intent(a, "op_unclean", "install_version", `,"version":"v0.6.2"`)
	for n in 0 ..< 3 {
		want_starts = n + 1
		if !wait_for(a, fmt.tprintf("op_unclean in probation (%d)", n), 120 * time.Second, proc(i: ^Inst) -> bool {return probation_starts(i, "op_unclean") >= want_starts}) do return
		time.sleep(2 * time.Second)
		sup := last_runtime(a).parent
		kill_launcher(a)
		// Windows: the launcher's job takes the supervisor and runtime with it. POSIX: kill
		// the supervisor too (a crash of the whole service); the next supervisor's J0 reap
		// clears a surviving runtime (macOS has no parent-death signal).
		if sup > 0 && ODIN_OS != .Windows do _ = hard_kill(sup)
		start_launcher(a)
	}
	if !expect_rolled_back(a, "op_unclean", t1, "0.6.2") do return
	_, code, _ = op_final(a, "op_unclean")
	testing.expectf(t, code == "probation_interrupted", "op_unclean error %s, want probation_interrupted", code)
	testing.expect_value(t, stop_launcher(a), 0)
	testing.expect_value(t, live_runtimes(a), 0)
}
