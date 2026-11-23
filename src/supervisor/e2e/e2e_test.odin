// Package e2e: the supervisor end to end with real processes (T13b acceptance):
//
//   ham-launcher -> ham-supervisor (test build) -> fakebridge (bin/ham-bridge)
//
// against a fake GitHub on loopback (src/supervisor/testkit) serving releases signed with
// the suite's fixed test key, which only the test build trusts. Needs HEIMDALL_E2E_BIN_DIR
// holding ham-launcher, ham-supervisor (built with -define:HEIMDALL_SUPERVISOR_TEST=true
// -define:HEIMDALL_TEST_PINNED_KEY=<src/supervisor/testdata/e2e-test-key.pub line 2>) and
// fakebridge (src/supervisor/testdata/fakebridge); skipped without it.
//
// One scenario, in order:
//   1. offline `ham-supervisor repair` installs v0.6.0; the launcher starts it; probation
//      commits it (J29 -> J15/J16 -> J17); the first timer check finds nothing newer;
//   2. a live PTY session (fakebridge counts files in <data>/fake-sessions); v0.6.1 is
//      published; after a restart the timer op waits in waiting_for_idle, `current` stays;
//      the session ends; the update activates, hands over (exit 75), and commits;
//   3. v0.6.2 crashes in probation: an update_now intent installs it, the probation fails,
//      it is rolled back (current = v0.6.1) and pinned;
//   4. the launcher is killed hard; a new launcher's supervisor reaps the orphaned runtime
//      (J0) before it starts its own;
//   5. graceful stop (stop-request file): launcher exits 0, no runtime survives.
package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import lc "../../launcher/core"
import "../engine"
import "../procs"
import "../testkit"

ID :: "ins_e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0"

exe :: proc(name: string) -> string {
	return strings.concatenate({name, ".exe"}, context.temp_allocator) when ODIN_OS == .Windows else name
}

pj :: proc(parts: ..string) -> string {
	return engine.join(..parts)
}

Env :: struct {
	t:          ^testing.T,
	bin:        string,
	base:       string,
	data:       string,
	state:      string,
	supervisor: []byte,
	bridge:     []byte,
	key:        testkit.Key,
	gh:         testkit.Fake_GitHub,
	launcher:   os.Process,
	running:    bool,
	log:        ^os.File,
	launches:   int,
}

files_for :: proc(e: ^Env, version, behaviour: string) -> []testkit.Bundle_File {
	f := make([]testkit.Bundle_File, 4, context.temp_allocator)
	f[0] = {path = strings.concatenate({"bin/", exe("ham-supervisor")}, context.temp_allocator), data = e.supervisor, exec = true}
	f[1] = {path = strings.concatenate({"bin/", exe("ham-bridge")}, context.temp_allocator), data = e.bridge, exec = true}
	f[2] = {path = "bin/test-version.txt", data = transmute([]byte)strings.clone(version, context.temp_allocator)}
	f[3] = {path = "bin/behaviour.txt", data = transmute([]byte)strings.clone(behaviour, context.temp_allocator)}
	return f
}

// publish signs and serves a release; returns its tree name (temp).
publish :: proc(e: ^Env, tag, behaviour: string) -> string {
	r := testkit.make_release(&e.key, {tag = tag, files = files_for(e, tag[1:], behaviour)})
	tree := strings.clone(r.tree, context.temp_allocator)
	testkit.github_publish(&e.gh, r)
	return tree
}

start_launcher :: proc(e: ^Env) {
	env, _ := os.environ(context.temp_allocator)
	full := make([dynamic]string, context.temp_allocator)
	for v in env do if !strings.has_prefix(v, "HEIMDALL_SUPERVISOR_TEST_") do append(&full, v)
	append(&full, fmt.tprintf("HEIMDALL_SUPERVISOR_TEST_ORIGIN=%s", testkit.github_origin(&e.gh)))
	append(&full, "HEIMDALL_SUPERVISOR_TEST_PROBATION_S=5")
	append(&full, "HEIMDALL_SUPERVISOR_TEST_FIRST_CHECK_S=3")
	e.launches += 1
	logf, err := os.create(pj(e.base, fmt.tprintf("launcher-%d.log", e.launches)))
	testing.expect(e.t, err == nil)
	e.log = logf
	p, perr := os.process_start({command = {pj(e.bin, exe("ham-launcher")), "--instance-root", e.data, "--state-root", e.state}, env = full[:], stdout = logf, stderr = logf})
	testing.expectf(e.t, perr == nil, "start launcher: %v", perr)
	e.launcher = p
	e.running = true
	time.sleep(1100 * time.Millisecond) // a stop request must be newer than the launcher's start (whole seconds, §7.3)
}

// stop_launcher: graceful stop through the stop-request file (§7.3, every OS).
stop_launcher :: proc(e: ^Env) -> int {
	if !e.running do return -1
	body := fmt.tprintf(`{{"instance_id":"%s","requested_at":%d}}`, ID, time.time_to_unix(time.now()))
	tmp := pj(e.data, "supervisor", "launcher-stop.request.tmp")
	_ = os.write_entire_file(tmp, transmute([]byte)body)
	_ = os.rename(tmp, pj(e.data, "supervisor", "launcher-stop.request"))
	state, err := os.process_wait(e.launcher, 40 * time.Second)
	e.running = false
	os.close(e.log)
	if err != nil || !state.exited {
		_ = os.process_kill(e.launcher)
		_, _ = os.process_wait(e.launcher, 5 * time.Second)
		return -1
	}
	return state.exit_code
}

kill_launcher :: proc(e: ^Env) {
	_ = os.process_kill(e.launcher)
	_, _ = os.process_wait(e.launcher, 10 * time.Second)
	e.running = false
	os.close(e.log)
}

wait_for :: proc(e: ^Env, what: string, timeout: time.Duration, cond: proc(e: ^Env) -> bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		// No free_all here: the scenario keeps temp strings (tree names) across waits.
		if cond(e) do return true
		time.sleep(250 * time.Millisecond)
	}
	testing.expectf(e.t, false, "timed out waiting for %s (logs in %s)", what, e.base)
	dump_journal(e)
	return false
}

journal :: proc(e: ^Env) -> []engine.Line {
	r := engine.read_journal_file(pj(e.data, "supervisor", "journal", "ops.jsonl"), context.temp_allocator)
	return r.lines[:]
}

dump_journal :: proc(e: ^Env) {
	for l in journal(e) do log.infof("journal: %s %s %s/%s err=%s note=%s to=%s", l.op_id, l.actor, l.state, l.sub, l.error, l.note, l.to.tree)
}

known_good :: proc(e: ^Env) -> string {
	t, _ := lc.read_known_good(e.data)
	return t
}

current :: proc(e: ^Env) -> string {
	t, _ := lc.read_pointer(e.data, lc.POINTER_CURRENT)
	return t
}

op_final :: proc(e: ^Env, op_id: string) -> (state, code: string) {
	for l in journal(e) {
		if l.op_id == op_id {
			state = l.state
			code = l.error
		}
	}
	return
}

timer_noops :: proc(e: ^Env) -> int {
	n := 0
	for l in journal(e) do if l.actor == "timer" && l.state == "noop" do n += 1
	return n
}

// runtime_pids: every fakebridge started so far (from <data>/fake-starts.log).
runtime_pids :: proc(e: ^Env) -> []int {
	data, _ := os.read_entire_file(pj(e.data, "fake-starts.log"), context.temp_allocator)
	out := make([dynamic]int, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		if pid, ok := strconv.parse_int(f[0]); ok do append(&out, pid)
	}
	return out[:]
}

live_runtimes :: proc(e: ^Env) -> int {
	n := 0
	for pid in runtime_pids(e) do if _, ok := procs.identify(pid); ok do n += 1
	return n
}

send_intent :: proc(e: ^Env, op_id, action: string) {
	now := time.time_to_unix(time.now())
	body := fmt.tprintf(`{{"is":1,"op_id":"%s","instance_id":"%s","action":"%s","actor":"cli","expires_at":%d,"created_at":%d}}`, op_id, ID, action, now + 3600, now)
	dir := pj(e.data, "supervisor", "intents", "inbox")
	_ = os.make_directory_all(dir)
	tmp := pj(dir, fmt.tprintf("%s.json.tmp", op_id))
	_ = os.write_entire_file(tmp, transmute([]byte)body)
	_ = os.rename(tmp, pj(dir, fmt.tprintf("%s.json", op_id)))
}

@(test)
test_supervisor_end_to_end :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bin := os.get_env("HEIMDALL_E2E_BIN_DIR", context.temp_allocator)
	if bin == "" {
		log.warn("HEIMDALL_E2E_BIN_DIR not set: supervisor e2e skipped")
		return
	}
	e: Env
	e.t = t
	sup, serr := os.read_entire_file(pj(bin, exe("ham-supervisor")), context.allocator)
	br, berr := os.read_entire_file(pj(bin, exe("fakebridge")), context.allocator)
	testing.expect(t, serr == nil && berr == nil, "binaries in HEIMDALL_E2E_BIN_DIR")
	if serr != nil || berr != nil do return
	e.supervisor, e.bridge = sup, br
	defer delete(sup)
	defer delete(br)
	home := os.get_env("HOME" when ODIN_OS != .Windows else "LOCALAPPDATA", context.temp_allocator)
	parent := pj(home, ".cache", "heimdall-tests")
	_ = os.make_directory_all(parent)
	base, derr := os.make_directory_temp(parent, "t13b-e2e-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	// Heap copies: wait_for frees the temp allocator on every poll.
	e.base = strings.clone(base)
	e.data = strings.clone(pj(base, "data"))
	e.state = strings.clone(pj(base, "state"))
	e.bin = strings.clone(bin)
	defer {
		delete(e.base)
		delete(e.data)
		delete(e.state)
		delete(e.bin)
	}
	_ = os.make_directory_all(e.data)
	_ = os.make_directory_all(e.state)
	_ = os.make_directory_all(pj(e.data, "supervisor"))
	testing.expect(t, testkit.write_instance(e.data, e.state, ID), "instance.json")
	e.key = testkit.e2e_key()
	defer testkit.key_destroy(&e.key)
	testing.expect(t, testkit.github_start(&e.gh), "fake GitHub")
	defer testkit.github_stop(&e.gh)
	defer if e.running do kill_launcher(&e)
	log.infof("e2e root %s, fake GitHub %s", e.base, testkit.github_origin(&e.gh))

	// 1. Offline repair installs v0.6.0; the service proves it.
	t0 := publish(&e, "v0.6.0", "good")
	r0 := e.gh.releases[0]
	local := pj(base, "local")
	_ = os.make_directory_all(local)
	_ = os.write_entire_file(pj(local, r0.asset), r0.bundle)
	_ = os.write_entire_file(pj(local, "m.json"), transmute([]byte)r0.manifest)
	_ = os.write_entire_file(pj(local, "m.json.minisig"), transmute([]byte)r0.signature)
	rp, rerr := os.process_start({command = {pj(bin, exe("ham-supervisor")), "repair", "--instance-root", e.data, "--state-root", e.state, "--bundle", pj(local, r0.asset), "--manifest", pj(local, "m.json"), "--signature", pj(local, "m.json.minisig"), "--op-id", "op_e2e_install"}})
	testing.expect(t, rerr == nil)
	rstate, _ := os.process_wait(rp, 60 * time.Second)
	testing.expectf(t, rstate.exited && rstate.exit_code == 0, "repair exit %d", rstate.exit_code)
	testing.expect_value(t, current(&e), t0)

	start_launcher(&e)
	@(static) want: string
	want = t0
	if !wait_for(&e, "v0.6.0 committed", 90 * time.Second, proc(e: ^Env) -> bool {return known_good(e) == want}) do return
	if !wait_for(&e, "first timer check", 60 * time.Second, proc(e: ^Env) -> bool {return timer_noops(e) >= 1}) do return

	// 2. A live session: the timer update waits, then proceeds once the session ends.
	_ = os.make_directory_all(pj(e.data, "fake-sessions"))
	_ = os.write_entire_file(pj(e.data, "fake-sessions", "s1"), transmute([]byte)string("pty"))
	t1 := publish(&e, "v0.6.1", "good")
	testing.expect_value(t, stop_launcher(&e), 0)
	testing.expect_value(t, live_runtimes(&e), 0)
	start_launcher(&e)
	waiting :: proc(e: ^Env) -> bool {
		for l in journal(e) do if l.actor == "timer" && l.state == "waiting_for_idle" do return true
		return false
	}
	if !wait_for(&e, "timer op waiting for idle", 60 * time.Second, waiting) do return
	time.sleep(5 * time.Second)
	testing.expect_value(t, current(&e), t0)
	testing.expect_value(t, known_good(&e), t0)
	_ = os.remove(pj(e.data, "fake-sessions", "s1"))
	want = t1
	if !wait_for(&e, "v0.6.1 committed after the session ended", 120 * time.Second, proc(e: ^Env) -> bool {return known_good(e) == want}) do return
	testing.expect_value(t, current(&e), t1)
	for l in journal(&e) {
		if l.actor == "timer" && l.sub == "gate_closed" do testing.expect(t, !l.forced, "not forced: the session ended")
	}

	// 3. A release that crashes in probation is rolled back and pinned.
	// The v0.6.1 supervisor's first timer check (up_to_date) may land in the same second
	// as the commit; step 1 had exactly one timer noop.
	if !wait_for(&e, "timer check of v0.6.1", 60 * time.Second, proc(e: ^Env) -> bool {return timer_noops(e) >= 2}) do return
	_ = publish(&e, "v0.6.2", "crash")
	send_intent(&e, "op_e2e_bad", "update_now")
	bad_done :: proc(e: ^Env) -> bool {
		st, _ := op_final(e, "op_e2e_bad")
		return engine.is_terminal(st)
	}
	if !wait_for(&e, "bad release rolled back", 180 * time.Second, bad_done) do return
	st, code := op_final(&e, "op_e2e_bad")
	testing.expectf(t, st == "rolled_back", "op_e2e_bad %s %s", st, code)
	want = t1
	if !wait_for(&e, "v0.6.1 running again", 60 * time.Second, proc(e: ^Env) -> bool {return current(e) == want && known_good(e) == want}) do return
	pins, _ := os.read_entire_file(pj(e.data, "supervisor", "pins.json"), context.temp_allocator)
	testing.expectf(t, strings.contains(string(pins), "0.6.2"), "v0.6.2 pinned: %s", string(pins))

	// 4. Hard kill: the next supervisor reaps the orphaned runtime before starting its own.
	time.sleep(3 * time.Second)
	old := runtime_pids(&e)
	last_old := old[len(old) - 1] if len(old) > 0 else 0
	kill_launcher(&e)
	start_launcher(&e)
	@(static) old_pid: int
	old_pid = last_old
	reaped :: proc(e: ^Env) -> bool {
		_, alive := procs.identify(old_pid)
		pids := runtime_pids(e)
		return !alive && len(pids) > 0 && pids[len(pids) - 1] != old_pid && live_runtimes(e) == 1
	}
	if !wait_for(&e, "orphaned runtime gone and a new one running", 60 * time.Second, reaped) do return

	// 5. Graceful stop: exit 0 and nothing of the instance survives.
	testing.expect_value(t, stop_launcher(&e), 0)
	testing.expect_value(t, live_runtimes(&e), 0)
	dump_journal(&e)
	_ = os.remove_all(base)
}
