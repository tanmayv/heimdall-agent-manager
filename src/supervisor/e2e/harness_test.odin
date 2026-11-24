// Shared harness of the supervisor e2e suite (T13b, extended into the T15 cross-OS
// failure-injection suite): a Suite owns the fake GitHub, the signing key and the binaries;
// an Inst is one bridge instance (own data/state roots, own launcher process).
//
//   ham-launcher -> ham-supervisor (test build) -> fakebridge (bin/ham-bridge)
//
// Needs HEIMDALL_E2E_BIN_DIR holding ham-launcher, ham-supervisor (built with
// -define:HEIMDALL_SUPERVISOR_TEST=true -define:HEIMDALL_TEST_PINNED_KEY=<key line>) and
// fakebridge; every test is skipped without it. Tests run one at a time
// (-define:ODIN_TEST_THREADS=1): wait_for conditions use @(static) captures.
package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import lc "../../launcher/core"
import "../engine"
import "../procs"
import "../testkit"

exe :: proc(name: string) -> string {
	return strings.concatenate({name, ".exe"}, context.temp_allocator) when ODIN_OS == .Windows else name
}

pj :: proc(parts: ..string) -> string {
	return engine.join(..parts)
}

Suite :: struct {
	t:          ^testing.T,
	bin:        string,
	base:       string,
	supervisor: []byte,
	bridge:     []byte,
	key:        testkit.Key,
	gh:         testkit.Fake_GitHub,
	insts:      [dynamic]^Inst,
	ok:         bool,
}

Inst :: struct {
	s:             ^Suite,
	name:          string,
	id:            string,
	data:          string,
	state:         string,
	launcher:      os.Process,
	running:       bool,
	log:           ^os.File,
	launches:      int,
	first_check_s: int, // timer's first check after start (0 = 3 s; large = never)
	probation_s:   int, // 0 = 5 s
}

// suite_open: false = skipped (no binaries) or setup failed (already reported).
suite_open :: proc(s: ^Suite, t: ^testing.T, name: string) -> bool {
	s.t = t
	bin := os.get_env("HEIMDALL_E2E_BIN_DIR", context.temp_allocator)
	if bin == "" {
		log.warnf("HEIMDALL_E2E_BIN_DIR not set: %s skipped", name)
		return false
	}
	sup, serr := os.read_entire_file(pj(bin, exe("ham-supervisor")), context.allocator)
	br, berr := os.read_entire_file(pj(bin, exe("fakebridge")), context.allocator)
	testing.expect(t, serr == nil && berr == nil, "binaries in HEIMDALL_E2E_BIN_DIR")
	if serr != nil || berr != nil {
		delete(sup)
		delete(br)
		return false
	}
	s.supervisor, s.bridge = sup, br
	parent := pj(test_home(), ".cache", "heimdall-tests")
	_ = os.make_directory_all(parent)
	base, derr := os.make_directory_temp(parent, fmt.tprintf("t15-%s-*", name), context.temp_allocator)
	testing.expect(t, derr == nil, "temp dir")
	s.base = strings.clone(base)
	s.bin = strings.clone(bin)
	s.key = testkit.e2e_key()
	s.insts = make([dynamic]^Inst)
	if !testing.expect(t, testkit.github_start(&s.gh), "fake GitHub") do return false
	log.infof("%s: root %s, fake GitHub %s", name, s.base, testkit.github_origin(&s.gh))
	s.ok = true
	return true
}

// suite_close stops every launcher, the fake GitHub, and removes the root when the test
// passed (kept for the logs otherwise).
suite_close :: proc(s: ^Suite) {
	for i in s.insts {
		if i.running do kill_launcher(i)
		delete(i.name)
		delete(i.id)
		delete(i.data)
		delete(i.state)
		free(i)
	}
	delete(s.insts)
	if s.ok {
		testkit.github_stop(&s.gh)
		testkit.key_destroy(&s.key)
	}
	if !testing.failed(s.t) && s.base != "" do _ = os.remove_all(s.base)
	delete(s.base)
	delete(s.bin)
	delete(s.supervisor)
	delete(s.bridge)
}

test_home :: proc() -> string {
	return os.get_env("HOME" when ODIN_OS != .Windows else "LOCALAPPDATA", context.temp_allocator)
}

NEVER :: 1_000_000 // first_check_s: no timer check during the test

// new_inst creates an instance root (instance.json owned by the current user).
new_inst :: proc(s: ^Suite, name: string) -> ^Inst {
	i := new(Inst)
	i.s = s
	i.name = strings.clone(name)
	i.id = fmt.aprintf("ins_%032x", 0xe2e0_0000 + len(s.insts) + 1)
	i.data = strings.clone(pj(s.base, name, "data"))
	i.state = strings.clone(pj(s.base, name, "state"))
	_ = os.make_directory_all(pj(i.data, "supervisor"))
	_ = os.make_directory_all(i.state)
	testing.expect(s.t, testkit.write_instance(i.data, i.state, i.id), "instance.json")
	append(&s.insts, i)
	return i
}

// Release_Opts: what a published test release does when it runs.
Release_Opts :: struct {
	behaviour:     string, // fakebridge: good | crash | noready | unhealthy
	sup_behaviour: string, // supervisor (test hook): "" | noready | exit78
	stable:        bool, // becomes /releases/latest (else a prerelease)
	pad_bytes:     int, // extra file in the bundle (slower extraction)
}

files_for :: proc(s: ^Suite, version: string, o: Release_Opts) -> []testkit.Bundle_File {
	f := make([dynamic]testkit.Bundle_File, context.temp_allocator)
	append(&f, testkit.Bundle_File{path = strings.concatenate({"bin/", exe("ham-supervisor")}, context.temp_allocator), data = s.supervisor, exec = true})
	append(&f, testkit.Bundle_File{path = strings.concatenate({"bin/", exe("ham-bridge")}, context.temp_allocator), data = s.bridge, exec = true})
	append(&f, testkit.Bundle_File{path = "bin/test-version.txt", data = transmute([]byte)strings.clone(version, context.temp_allocator)})
	behaviour := o.behaviour if o.behaviour != "" else "good"
	append(&f, testkit.Bundle_File{path = "bin/behaviour.txt", data = transmute([]byte)strings.clone(behaviour, context.temp_allocator)})
	if o.sup_behaviour != "" {
		append(&f, testkit.Bundle_File{path = "bin/supervisor-behaviour.txt", data = transmute([]byte)strings.clone(o.sup_behaviour, context.temp_allocator)})
	}
	if o.pad_bytes > 0 {
		pad := make([]byte, o.pad_bytes, context.temp_allocator)
		for k in 0 ..< len(pad) do pad[k] = byte(k * 7919 >> 3)
		append(&f, testkit.Bundle_File{path = "share/heimdall/pad.bin", data = pad})
	}
	return f[:]
}

build_release :: proc(s: ^Suite, tag: string, o: Release_Opts) -> testkit.Release {
	return testkit.make_release(&s.key, {tag = tag, files = files_for(s, tag[1:], o)})
}

// publish signs and serves a release; returns its tree name (temp).
publish :: proc(s: ^Suite, tag: string, o := Release_Opts{stable = true}) -> string {
	r := build_release(s, tag, o)
	tree := strings.clone(r.tree, context.temp_allocator)
	testkit.github_publish(&s.gh, r, o.stable)
	return tree
}

release_of :: proc(s: ^Suite, tag: string) -> ^testkit.Release {
	for &r in s.gh.releases do if r.tag == tag do return &r
	return nil
}

// Run_Result: exit code and combined output of a short command.
Run_Result :: struct {
	ok:     bool,
	code:   int,
	output: string, // temp
}

run_cmd :: proc(s: ^Suite, command: []string, timeout := 90 * time.Second, env: []string = nil) -> Run_Result {
	// A pipe and a reader thread: on Windows a file passed as stdout came out empty.
	r, w, perr := os.pipe()
	if perr != nil do return {}
	p, serr := os.process_start({command = command, stdout = w, stderr = w, env = env})
	os.close(w)
	if serr != nil {
		os.close(r)
		log.errorf("start %v: %v", command, serr)
		return {}
	}
	Reader :: struct {
		f:   ^os.File,
		out: [dynamic]byte,
	}
	rd := Reader{f = r, out = make([dynamic]byte)}
	th := thread.create_and_start_with_data(&rd, proc(data: rawptr) {
		rd := (^Reader)(data)
		buf: [4096]byte
		for {
			n, err := os.read(rd.f, buf[:])
			if n > 0 do append(&rd.out, ..buf[:n])
			if err != nil || n <= 0 do break
		}
	})
	st, werr := os.process_wait(p, timeout)
	if werr != nil || !st.exited {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p, 5 * time.Second)
	}
	thread.join(th)
	thread.destroy(th)
	os.close(r)
	output := strings.clone(string(rd.out[:]), context.temp_allocator)
	delete(rd.out)
	return {ok = werr == nil && st.exited, code = st.exit_code, output = output}
}

// repair runs `ham-supervisor repair` with local copies of a published release.
repair :: proc(i: ^Inst, tag: string, op_id: string) -> Run_Result {
	s := i.s
	r := release_of(s, tag)
	if r == nil do return {}
	local := pj(s.base, "local", tag)
	_ = os.make_directory_all(local)
	_ = os.write_entire_file(pj(local, r.asset), r.bundle)
	_ = os.write_entire_file(pj(local, "m.json"), transmute([]byte)r.manifest)
	_ = os.write_entire_file(pj(local, "m.json.minisig"), transmute([]byte)r.signature)
	res := run_cmd(s, {pj(s.bin, exe("ham-supervisor")), "repair", "--instance-root", i.data, "--state-root", i.state, "--bundle", pj(local, r.asset), "--manifest", pj(local, "m.json"), "--signature", pj(local, "m.json.minisig"), "--op-id", op_id})
	log.infof("%s: repair %s -> exit %d: %s", i.name, tag, res.code, strings.trim_space(res.output))
	return res
}

launcher_env :: proc(i: ^Inst) -> []string {
	env, _ := os.environ(context.temp_allocator)
	full := make([dynamic]string, context.temp_allocator)
	for v in env do if !strings.has_prefix(v, "HEIMDALL_SUPERVISOR_TEST_") do append(&full, v)
	append(&full, fmt.tprintf("HEIMDALL_SUPERVISOR_TEST_ORIGIN=%s", testkit.github_origin(&i.s.gh)))
	append(&full, fmt.tprintf("HEIMDALL_SUPERVISOR_TEST_PROBATION_S=%d", i.probation_s if i.probation_s > 0 else 5))
	append(&full, "HEIMDALL_SUPERVISOR_TEST_READY_S=10")
	append(&full, fmt.tprintf("HEIMDALL_SUPERVISOR_TEST_FIRST_CHECK_S=%d", i.first_check_s if i.first_check_s > 0 else 3))
	return full[:]
}

start_launcher :: proc(i: ^Inst) {
	i.launches += 1
	logf, err := os.create(pj(i.s.base, i.name, fmt.tprintf("launcher-%d.log", i.launches)))
	testing.expect(i.s.t, err == nil)
	i.log = logf
	p, perr := os.process_start({command = {pj(i.s.bin, exe("ham-launcher")), "--instance-root", i.data, "--state-root", i.state}, env = launcher_env(i), stdout = logf, stderr = logf})
	testing.expectf(i.s.t, perr == nil, "start launcher: %v", perr)
	i.launcher = p
	i.running = true
	time.sleep(1100 * time.Millisecond) // a stop request must be newer than the launcher's start (whole seconds, §7.3)
}

// stop_launcher: graceful stop through the stop-request file (§7.3, every OS).
stop_launcher :: proc(i: ^Inst) -> int {
	if !i.running do return -1
	body := fmt.tprintf(`{{"instance_id":"%s","requested_at":%d}}`, i.id, time.time_to_unix(time.now()))
	tmp := pj(i.data, "supervisor", "launcher-stop.request.tmp")
	_ = os.write_entire_file(tmp, transmute([]byte)body)
	_ = os.rename(tmp, pj(i.data, "supervisor", "launcher-stop.request"))
	state, err := os.process_wait(i.launcher, 40 * time.Second)
	i.running = false
	os.close(i.log)
	if err != nil || !state.exited {
		_ = os.process_kill(i.launcher)
		_, _ = os.process_wait(i.launcher, 5 * time.Second)
		return -1
	}
	return state.exit_code
}

kill_launcher :: proc(i: ^Inst) {
	_ = os.process_kill(i.launcher)
	_, _ = os.process_wait(i.launcher, 10 * time.Second)
	i.running = false
	os.close(i.log)
}

wait_for :: proc(i: ^Inst, what: string, timeout: time.Duration, cond: proc(i: ^Inst) -> bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if cond(i) do return true
		time.sleep(250 * time.Millisecond)
	}
	testing.expectf(i.s.t, false, "%s: timed out waiting for %s (logs in %s)", i.name, what, i.s.base)
	dump(i)
	return false
}

journal :: proc(i: ^Inst) -> []engine.Line {
	r := engine.read_journal_file(pj(i.data, "supervisor", "journal", "ops.jsonl"), context.temp_allocator)
	return r.lines[:]
}

journal_len :: proc(i: ^Inst) -> int {
	return len(journal(i))
}

dump_journal :: proc(i: ^Inst) {
	for l in journal(i) do log.infof("%s journal: %s %s %s %s/%s err=%s note=%s to=%s", i.name, l.op_id, l.action, l.actor, l.state, l.sub, l.error, l.note, l.to.tree)
}

dump :: proc(i: ^Inst) {
	dump_journal(i)
	for n in 1 ..= i.launches {
		data, err := os.read_entire_file(pj(i.s.base, i.name, fmt.tprintf("launcher-%d.log", n)), context.temp_allocator)
		if err == nil do log.infof("%s launcher-%d.log:\n%s", i.name, n, string(data))
	}
	data, _ := os.read_entire_file(pj(i.data, "fake-starts.log"), context.temp_allocator)
	log.infof("%s fake-starts.log:\n%s", i.name, string(data))
}

known_good :: proc(i: ^Inst) -> string {
	t, _ := lc.read_known_good(i.data)
	return t
}

current :: proc(i: ^Inst) -> string {
	t, _ := lc.read_pointer(i.data, lc.POINTER_CURRENT)
	return t
}

previous :: proc(i: ^Inst) -> string {
	t, _ := lc.read_pointer(i.data, lc.POINTER_PREVIOUS)
	return t
}

pins :: proc(i: ^Inst) -> string {
	data, _ := os.read_entire_file(pj(i.data, "supervisor", "pins.json"), context.temp_allocator)
	return string(data)
}

// op_final: the last state and error of op `op_id`.
op_final :: proc(i: ^Inst, op_id: string) -> (state, code, note: string) {
	for l in journal(i) {
		if l.op_id == op_id {
			state = l.state
			code = l.error
			note = l.note
		}
	}
	return
}

op_done :: proc(i: ^Inst, op_id: string) -> bool {
	st, _, _ := op_final(i, op_id)
	return engine.is_terminal(st)
}

// count_lines: journal lines of `actor` in `state`.
count_lines :: proc(i: ^Inst, actor, state: string) -> int {
	n := 0
	for l in journal(i) do if l.actor == actor && l.state == state do n += 1
	return n
}

timer_noops :: proc(i: ^Inst) -> int {
	return count_lines(i, "timer", "noop")
}

// Runtime: one fakebridge start, with its identity (from <data>/fake-starts.log:
// "<pid> <tree> <behaviour> <parent pid> <start_time>"). Liveness is checked by identity:
// Windows reuses pids quickly.
Runtime :: struct {
	id:     procs.Id,
	parent: int,
	tree:   string,
}

runtimes :: proc(i: ^Inst) -> []Runtime {
	data, _ := os.read_entire_file(pj(i.data, "fake-starts.log"), context.temp_allocator)
	out := make([dynamic]Runtime, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 5 do continue
		r: Runtime
		r.id.pid, _ = strconv.parse_int(f[0])
		r.tree = f[1]
		r.parent, _ = strconv.parse_int(f[3])
		st, _ := strconv.parse_u64(f[4])
		r.id.start_time = st
		append(&out, r)
	}
	return out[:]
}

last_runtime :: proc(i: ^Inst) -> Runtime {
	rs := runtimes(i)
	return rs[len(rs) - 1] if len(rs) > 0 else {}
}

live_runtimes :: proc(i: ^Inst) -> int {
	n := 0
	for r in runtimes(i) do if procs.alive(r.id) do n += 1
	return n
}

send_intent :: proc(i: ^Inst, op_id, action: string, extra := "") {
	now := time.time_to_unix(time.now())
	body := fmt.tprintf(`{{"is":1,"op_id":"%s","instance_id":"%s","action":"%s","actor":"cli","expires_at":%d,"created_at":%d%s}}`, op_id, i.id, action, now + 3600, now, extra)
	dir := pj(i.data, "supervisor", "intents", "inbox")
	_ = os.make_directory_all(dir)
	tmp := pj(dir, fmt.tprintf("%s.json.tmp", op_id))
	_ = os.write_entire_file(tmp, transmute([]byte)body)
	_ = os.rename(tmp, pj(dir, fmt.tprintf("%s.json", op_id)))
}

// set_channel writes <state>/update.json directly (before the first start).
set_channel :: proc(i: ^Inst, channel: string) {
	body := fmt.tprintf(`{{"channel":"%s","auto_update":true,"revision":1,"actor":"cli","updated_at":%d,"last_op":"op_t15_channel"}}`, channel, time.time_to_unix(time.now()))
	_ = os.write_entire_file(pj(i.state, "update.json"), transmute([]byte)body)
}

// set_behaviour makes an installed tree's runtime behave differently from its next start on.
set_behaviour :: proc(i: ^Inst, tree, behaviour: string) {
	_ = os.make_directory_all(pj(i.data, "fake-behaviour"))
	_ = os.write_entire_file(pj(i.data, "fake-behaviour", tree), transmute([]byte)behaviour)
}

set_hub :: proc(i: ^Inst, up: bool) {
	if up do _ = os.write_entire_file(pj(i.data, "fake-hub-up"), transmute([]byte)string("up"))
	else do _ = os.remove(pj(i.data, "fake-hub-up"))
}

// install: offline repair of `tag`, then the launcher proves it (committed).
g_want: string
install :: proc(i: ^Inst, tag: string) -> bool {
	r := release_of(i.s, tag)
	op, _ := strings.replace_all(tag, ".", "_", context.temp_allocator)
	op = fmt.tprintf("op_install_%s", op)
	res := repair(i, tag, op)
	if !testing.expectf(i.s.t, res.ok && res.code == 0, "%s: repair %s exit %d", i.name, tag, res.code) do return false
	start_launcher(i)
	g_want = r.tree
	// known-good lands one step before the `committed` line (J17): wait for both, so a
	// caller's snapshot of the journal is not taken in between.
	return wait_committed(i, op, r.tree, fmt.tprintf("%s committed", tag), 90 * time.Second)
}

g_op: string

// wait_committed: op `op` committed (journal line written) with `tree` as known-good.
wait_committed :: proc(i: ^Inst, op, tree, what: string, timeout: time.Duration) -> bool {
	g_want = tree
	g_op = op
	return wait_for(i, what, timeout, proc(i: ^Inst) -> bool {return known_good(i) == g_want && op_done(i, g_op)})
}
