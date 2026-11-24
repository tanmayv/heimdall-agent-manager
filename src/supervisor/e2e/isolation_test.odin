// T15 (spec §18, report §6.6 REQ-ISO-1): two profiles of one OS user at different versions,
// and two OS users on one hub, with the real launcher and supervisor.
package e2e

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../procs"

// Snapshot of what another instance must keep while its neighbour is changed.
Untouched :: struct {
	current, known_good, pins: string,
	journal:                   int,
	runtime:                   procs.Id,
}

snapshot_of :: proc(i: ^Inst) -> Untouched {
	return {
		current = strings.clone(current(i), context.temp_allocator),
		known_good = strings.clone(known_good(i), context.temp_allocator),
		pins = strings.clone(pins(i), context.temp_allocator),
		journal = journal_len(i),
		runtime = last_runtime(i).id,
	}
}

expect_untouched :: proc(i: ^Inst, u: Untouched, when_: string) -> bool {
	now := snapshot_of(i)
	ok := testing.expectf(i.s.t, now.current == u.current && now.known_good == u.known_good, "%s untouched %s: pointers %s/%s -> %s/%s", i.name, when_, u.current, u.known_good, now.current, now.known_good)
	ok &= testing.expectf(i.s.t, now.pins == u.pins, "%s untouched %s: pins %q -> %q", i.name, when_, u.pins, now.pins)
	ok &= testing.expectf(i.s.t, now.journal == u.journal, "%s untouched %s: journal %d -> %d lines", i.name, when_, u.journal, now.journal)
	ok &= testing.expectf(i.s.t, now.runtime == u.runtime && procs.alive(u.runtime), "%s untouched %s: same runtime alive", i.name, when_)
	return ok
}

// Two profiles of one OS user (same hub URL), A on v0.6.0 and B on v0.6.1, each with its
// own launcher, lock, job / process group and pointers:
//   1. A takes a bad release (rolled back, pinned): B unchanged, same runtime;
//   2. A's supervisor is killed hard (J0 reap of A's runtime): B unchanged;
//   3. both are told to update at the same moment: each commits v0.6.3 on its own.
@(test)
test_two_profiles_at_different_versions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "profiles") do return
	a := new_inst(&s, "a")
	b := new_inst(&s, "b")
	a.first_check_s = NEVER
	b.first_check_s = NEVER
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	t1 := strings.clone(publish(&s, "v0.6.1"))
	defer delete(t1)
	if !install(a, "v0.6.0") do return
	if !install(b, "v0.6.1") do return
	testing.expect(t, current(a) == t0 && current(b) == t1, "different versions")

	// 1.
	ub := snapshot_of(b)
	publish(&s, "v0.6.2", {behaviour = "crash", stable = true})
	send_intent(a, "op_iso_bad", "install_version", `,"version":"v0.6.2"`)
	if !expect_rolled_back(a, "op_iso_bad", t0, "0.6.2") do return
	if !expect_untouched(b, ub, "while A rolled back") do return

	// 2.
	time.sleep(2 * time.Second)
	@(static) old: Runtime
	old = last_runtime(a)
	testing.expectf(t, hard_kill(old.parent), "kill A's supervisor %d", old.parent)
	reaped :: proc(i: ^Inst) -> bool {
		cur := last_runtime(i)
		return !procs.alive(old.id) && cur.id != old.id && live_runtimes(i) == 1
	}
	if !wait_for(a, "A's orphan reaped and a new runtime running", 60 * time.Second, reaped) do return
	if !expect_untouched(b, ub, "while A's supervisor crashed") do return

	// 3. Concurrent updates.
	t3 := strings.clone(publish(&s, "v0.6.3"))
	defer delete(t3)
	send_intent(a, "op_iso_a", "install_version", `,"version":"v0.6.3"`)
	send_intent(b, "op_iso_b", "install_version", `,"version":"v0.6.3"`)
	g_want = t3
	both :: proc(i: ^Inst) -> bool {return known_good(i) == g_want}
	if !wait_for(a, "A on v0.6.3", 150 * time.Second, both) do return
	if !wait_for(b, "B on v0.6.3", 150 * time.Second, both) do return
	for i in ([]^Inst{a, b}) {
		op := "op_iso_a" if i == a else "op_iso_b"
		st, code, _ := op_final(i, op)
		testing.expectf(t, st == "committed", "%s %s %s", op, st, code)
		testing.expectf(t, live_runtimes(i) == 1 && last_runtime(i).tree == t3, "%s runs v0.6.3", i.name)
	}
	testing.expectf(t, !strings.contains(pins(b), "0.6.2"), "A's pin is A's only: B pins %q", pins(b))
	testing.expect_value(t, stop_launcher(a), 0)
	testing.expect_value(t, stop_launcher(b), 0)
	testing.expect_value(t, live_runtimes(a), 0)
	testing.expect_value(t, live_runtimes(b), 0)
}

// Two OS users on one hub (REQ-ISO-1, report §4 R1/R2, Q8 "never manage other OS users'
// bridges"). Needs a second local account prepared by CI (HEIMDALL_E2E_OTHER_USER, see
// .github/workflows/supervisor-e2e.yml); skipped without it.
//
//   1. user B gets its own instance of the SAME hub and profile name (same service name)
//      and runs it under its own account: repair + launcher, committed;
//   2. user A (this test) runs its own instance of the same hub at the same time: committed;
//   3. A's launcher and `ham-supervisor repair` pointed at B's instance root are refused
//      (78, ownership: instance.json names B), although B made the root writable for A,
//      so only the ownership check stands in the way; B's pointers and journal unchanged;
//   4. B's supervisor update fails/rolls back while A keeps running: A unchanged.
@(test)
test_two_os_users_on_one_hub :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	other := os.get_env("HEIMDALL_E2E_OTHER_USER", context.temp_allocator)
	if other == "" {
		log.warn("HEIMDALL_E2E_OTHER_USER not set: two-OS-users test skipped")
		return
	}
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "users") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	publish(&s, "v0.6.1", {behaviour = "crash", stable = true})

	b, ok := other_user_open(&s, other)
	defer other_user_close(&b)
	if !testing.expect(t, ok, "second OS user's instance") do return

	// 1. + 2.
	if !other_user_install(&b, "v0.6.0") do return
	if !install(a, "v0.6.0") do return
	ua := snapshot_of(a)

	// 3. A acting on B's instance: refused, nothing written.
	other_refresh(&b)
	bj := journal_len(b.view)
	// A refusing launcher waits refuse_wait (60 s) before it exits 78 (service restart damping).
	res := run_cmd(&s, {pj(s.bin, exe("ham-launcher")), "--instance-root", b.inst.data, "--state-root", b.inst.state}, 120 * time.Second)
	testing.expectf(t, res.ok && res.code == 78, "A's launcher on B's instance: exit %d (want 78): %s", res.code, res.output)
	res = repair(b.inst, "v0.6.0", "op_users_cross")
	testing.expectf(t, res.ok && res.code == 78, "A's repair on B's instance: exit %d (want 78): %s", res.code, res.output)
	other_refresh(&b)
	testing.expectf(t, journal_len(b.view) == bj && known_good(b.view) == t0, "B unchanged by A's attempts (journal %d -> %d)", bj, journal_len(b.view))

	// 4. B rolls a bad release back; A unchanged.
	other_intent(&b, "op_users_b", "install_version", `,"version":"v0.6.1"`)
	if !other_wait_for(&b, "B's op ends", 240 * time.Second, proc(i: ^Inst) -> bool {return op_done(i, "op_users_b")}) do return
	st, code, _ := op_final(b.view, "op_users_b")
	testing.expectf(t, st == "rolled_back", "B's bad update %s %s", st, code)
	g_want = t0
	if !other_wait_for(&b, "B back on v0.6.0", 60 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want && current(i) == g_want}) do return
	if !expect_untouched(a, ua, "while B rolled back") do return
	testing.expect_value(t, stop_launcher(a), 0)
	testing.expect_value(t, other_user_stop(&b), 0)
	log.infof("two OS users: B=%s", other)
}
