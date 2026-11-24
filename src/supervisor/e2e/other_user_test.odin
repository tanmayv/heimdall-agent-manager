// A second local OS user for test_two_os_users_on_one_hub. CI prepares the account and
// exports (see .github/workflows/supervisor-e2e.yml):
//
//   HEIMDALL_E2E_OTHER_USER        account name
//   HEIMDALL_E2E_SHARED_DIR        a directory both users can traverse and write
//   HEIMDALL_E2E_OTHER_PASSWORD    Windows only (CreateProcessWithLogonW)
//   HEIMDALL_E2E_OTHER_SID         Windows only (instance.json owner)
//
// POSIX runs B's commands through `sudo -n -u <user>` (the runner has passwordless sudo)
// and reads B's private files through a root copy (B's journal and records are 0600);
// Windows starts them with CreateProcessWithLogonW and reads them directly (the runner is
// an administrator and the shared directory grants everyone access by inheritance).
package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

Other :: struct {
	s:        ^Suite,
	user:     string,
	root:     string, // <shared>/<unique>
	bin:      string, // B's copies of ham-launcher / ham-supervisor
	inst:     ^Inst, // B's instance (paths under root); reads go through other_view
	view:     ^Inst, // A-readable copy of B's data (POSIX) or inst itself (Windows)
	launcher: Other_Proc,
	running:  bool,
	launches: int,
}

other_user_open :: proc(s: ^Suite, user: string) -> (b: Other, ok: bool) {
	b.s = s
	b.user = strings.clone(user)
	shared := os.get_env("HEIMDALL_E2E_SHARED_DIR", context.temp_allocator)
	if !testing.expect(s.t, shared != "", "HEIMDALL_E2E_SHARED_DIR set") do return
	root, err := os.make_directory_temp(shared, "t15-users-*", context.temp_allocator)
	if !testing.expectf(s.t, err == nil, "shared root: %v", err) do return
	b.root = strings.clone(root)
	b.bin = strings.clone(pj(root, "bin"))
	_ = os.make_directory_all(b.bin)
	for name in ([]string{"ham-launcher", "ham-supervisor"}) {
		data, rerr := os.read_entire_file(pj(s.bin, exe(name)), context.temp_allocator)
		if !testing.expect(s.t, rerr == nil, "read binary") do return
		if !testing.expect(s.t, os.write_entire_file(pj(b.bin, exe(name)), data) == nil, "copy binary") do return
	}
	if !other_prepare(&b) do return

	i := new(Inst)
	i.s = s
	i.name = strings.clone("b")
	i.id = fmt.aprintf("ins_%032x", 0xb0b0_0000 + 1)
	i.data = strings.clone(pj(root, "b", "data"))
	i.state = strings.clone(pj(root, "b", "state"))
	i.first_check_s = NEVER
	append(&s.insts, i) // suite_close frees it (its launcher is ours to stop, not s's)
	b.inst = i
	body := fmt.tprintf(`{{"schema":1,"instance_id":"%s","service_name":"heimdall-bridge-test","hub_url":"http://127.0.0.1:9","profile":"test","owner":%s,"data_root":"%s","state_root":"%s","layout":1,"created_at":1795400000}}`,
		i.id, other_owner_json(&b), json_path(i.data), json_path(i.state))
	if !other_make_instance(&b, body) do return
	b.view = other_view_inst(&b)
	log.infof("second OS user %s: instance root %s", user, i.data)
	return b, true
}

json_path :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, `\`, `\\`, context.temp_allocator)
	return s
}

other_user_close :: proc(b: ^Other) {
	if b.running do other_kill(&b.launcher)
	other_cleanup(b)
	delete(b.user)
	delete(b.root)
	delete(b.bin)
}

other_env :: proc(b: ^Other) -> []string {
	env := make([dynamic]string, context.temp_allocator)
	append(&env, fmt.tprintf("HEIMDALL_SUPERVISOR_TEST_ORIGIN=%s", testkit_origin(b.s)))
	append(&env, "HEIMDALL_SUPERVISOR_TEST_PROBATION_S=5")
	append(&env, "HEIMDALL_SUPERVISOR_TEST_READY_S=10")
	append(&env, fmt.tprintf("HEIMDALL_SUPERVISOR_TEST_FIRST_CHECK_S=%d", NEVER))
	return env[:]
}

// other_run runs a short command as B and waits for it.
other_run :: proc(b: ^Other, command: []string, timeout := 90 * time.Second) -> Run_Result {
	out := pj(b.s.base, fmt.tprintf("other-%d.log", time.tick_now()._nsec))
	p, ok := other_spawn(b, command, other_env(b), out)
	if !ok do return {}
	exited, code := other_wait(&p, timeout)
	if !exited do other_kill(&p)
	data, _ := os.read_entire_file(out, context.temp_allocator)
	return {ok = exited, code = code, output = string(data)}
}

other_user_install :: proc(b: ^Other, tag: string) -> bool {
	s := b.s
	r := release_of(s, tag)
	local := pj(b.root, "local")
	_ = os.make_directory_all(local)
	_ = os.write_entire_file(pj(local, r.asset), r.bundle)
	_ = os.write_entire_file(pj(local, "m.json"), transmute([]byte)r.manifest)
	_ = os.write_entire_file(pj(local, "m.json.minisig"), transmute([]byte)r.signature)
	res := other_run(b, {pj(b.bin, exe("ham-supervisor")), "repair", "--instance-root", b.inst.data, "--state-root", b.inst.state, "--bundle", pj(local, r.asset), "--manifest", pj(local, "m.json"), "--signature", pj(local, "m.json.minisig"), "--op-id", "op_install_b"})
	log.infof("B: repair %s -> exit %d: %s", tag, res.code, strings.trim_space(res.output))
	if !testing.expectf(s.t, res.ok && res.code == 0, "B's repair exit %d", res.code) do return false
	b.launches += 1
	p, ok := other_spawn(b, {pj(b.bin, exe("ham-launcher")), "--instance-root", b.inst.data, "--state-root", b.inst.state}, other_env(b), pj(s.base, fmt.tprintf("other-launcher-%d.log", b.launches)))
	if !testing.expect(s.t, ok, "B's launcher started") do return false
	b.launcher = p
	b.running = true
	time.sleep(1100 * time.Millisecond)
	g_want = r.tree
	return other_wait_for(b, "B committed", 120 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want})
}

// other_wait_for polls `cond` on a fresh view of B's state.
other_wait_for :: proc(b: ^Other, what: string, timeout: time.Duration, cond: proc(i: ^Inst) -> bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		other_refresh(b)
		if cond(b.view) do return true
		time.sleep(time.Second)
	}
	other_refresh(b)
	testing.expectf(b.s.t, false, "B: timed out waiting for %s (root %s)", what, b.root)
	dump_journal(b.view)
	return false
}

// other_intent drops an intent into B's inbox as B would.
other_intent :: proc(b: ^Other, op_id, action, extra: string) {
	now := time.time_to_unix(time.now())
	body := fmt.tprintf(`{{"is":1,"op_id":"%s","instance_id":"%s","action":"%s","actor":"cli","expires_at":%d,"created_at":%d%s}}`, op_id, b.inst.id, action, now + 3600, now, extra)
	other_write(b, pj(b.inst.data, "supervisor", "intents", "inbox"), fmt.tprintf("%s.json", op_id), body)
}

other_user_stop :: proc(b: ^Other) -> int {
	if !b.running do return -1
	body := fmt.tprintf(`{{"instance_id":"%s","requested_at":%d}}`, b.inst.id, time.time_to_unix(time.now()))
	other_write(b, pj(b.inst.data, "supervisor"), "launcher-stop.request", body)
	exited, code := other_wait(&b.launcher, 40 * time.Second)
	b.running = false
	if !exited {
		other_kill(&b.launcher)
		return -1
	}
	return code
}

testkit_origin :: proc(s: ^Suite) -> string {
	return fmt.tprintf("http://127.0.0.1:%d", s.gh.port)
}
