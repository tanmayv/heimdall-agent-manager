// Package e2e: the supervisor end to end with real processes (T13b acceptance, and the
// T15 cross-OS failure-injection suite; harness in harness_test.odin, coverage map in
// docs/specs/bridge-supervisor-t15-suite.md), against a fake GitHub on loopback
// (src/supervisor/testkit) serving releases signed with the suite's fixed test key, which
// only the test build trusts.
//
// test_supervisor_end_to_end, in order:
//   1. offline `ham-supervisor repair` installs v0.6.0; the launcher starts it; probation
//      commits it (J29 -> J15/J16 -> J17); the first timer check finds nothing newer;
//   2. a live PTY session (fakebridge counts files in <data>/fake-sessions); v0.6.1 is
//      published; after a restart the timer op waits in waiting_for_idle, `current` stays;
//      the session ends; the update activates, hands over (exit 75), and commits;
//   3. v0.6.2 crashes in probation: an update_now intent installs it, the probation fails,
//      it is rolled back (current = v0.6.1) and pinned;
//   4. the supervisor is killed hard; the launcher restarts it and it reaps the orphaned
//      runtime (J0) before it starts its own;
//   5. graceful stop (stop-request file): launcher exits 0, no runtime survives.
package e2e

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../procs"

@(test)
test_supervisor_end_to_end :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "main") do return
	e := new_inst(&s, "a")

	// 1. Offline repair installs v0.6.0; the service proves it.
	t0 := publish(&s, "v0.6.0")
	if !install(e, "v0.6.0") do return
	testing.expect_value(t, current(e), t0)
	@(static) want: string
	if !wait_for(e, "first timer check", 60 * time.Second, proc(e: ^Inst) -> bool {return timer_noops(e) >= 1}) do return

	// 2. A live session: the timer update waits, then proceeds once the session ends.
	_ = os.make_directory_all(pj(e.data, "fake-sessions"))
	_ = os.write_entire_file(pj(e.data, "fake-sessions", "s1"), transmute([]byte)string("pty"))
	t1 := publish(&s, "v0.6.1")
	testing.expect_value(t, stop_launcher(e), 0)
	testing.expect_value(t, live_runtimes(e), 0)
	start_launcher(e)
	waiting :: proc(e: ^Inst) -> bool {
		for l in journal(e) do if l.actor == "timer" && l.state == "waiting_for_idle" do return true
		return false
	}
	if !wait_for(e, "timer op waiting for idle", 60 * time.Second, waiting) do return
	time.sleep(5 * time.Second)
	testing.expect_value(t, current(e), t0)
	testing.expect_value(t, known_good(e), t0)
	_ = os.remove(pj(e.data, "fake-sessions", "s1"))
	want = t1
	if !wait_for(e, "v0.6.1 committed after the session ended", 120 * time.Second, proc(e: ^Inst) -> bool {return known_good(e) == want}) do return
	testing.expect_value(t, current(e), t1)
	for l in journal(e) {
		if l.actor == "timer" && l.sub == "gate_closed" do testing.expect(t, !l.forced, "not forced: the session ended")
	}

	// 3. A release that crashes in probation is rolled back and pinned.
	// The v0.6.1 supervisor's first timer check (up_to_date) may land in the same second
	// as the commit; step 1 had exactly one timer noop.
	if !wait_for(e, "timer check of v0.6.1", 60 * time.Second, proc(e: ^Inst) -> bool {return timer_noops(e) >= 2}) do return
	_ = publish(&s, "v0.6.2", {behaviour = "crash", stable = true})
	send_intent(e, "op_e2e_bad", "update_now")
	bad_done :: proc(e: ^Inst) -> bool {
		return op_done(e, "op_e2e_bad")
	}
	if !wait_for(e, "bad release rolled back", 180 * time.Second, bad_done) do return
	st, code, _ := op_final(e, "op_e2e_bad")
	testing.expectf(t, st == "rolled_back", "op_e2e_bad %s %s", st, code)
	want = t1
	if !wait_for(e, "v0.6.1 running again", 60 * time.Second, proc(e: ^Inst) -> bool {return current(e) == want && known_good(e) == want}) do return
	testing.expectf(t, strings.contains(pins(e), "0.6.2"), "v0.6.2 pinned: %s", pins(e))

	// 4. Supervisor crash (§2.1): kill the supervisor hard; the launcher restarts it and its
	//    J0 reap clears the runtime the dead supervisor left (Linux: parent-death signal
	//    first; Windows: the job died with it; macOS: only the reap), before it starts its own.
	time.sleep(3 * time.Second)
	@(static) old: Runtime
	old = last_runtime(e)
	testing.expect(t, old.id.pid > 0 && old.parent > 0, "runtime and supervisor pids")
	testing.expectf(t, hard_kill(old.parent), "kill supervisor %d", old.parent)
	reaped :: proc(e: ^Inst) -> bool {
		cur := last_runtime(e)
		return !procs.alive(old.id) && cur.id != old.id && live_runtimes(e) == 1
	}
	if !wait_for(e, "orphaned runtime gone and a new one running", 60 * time.Second, reaped) do return
	testing.expect_value(t, current(e), t1)

	// 5. Graceful stop: exit 0 and nothing of the instance survives.
	testing.expect_value(t, stop_launcher(e), 0)
	testing.expect_value(t, live_runtimes(e), 0)
	dump_journal(e)
}
