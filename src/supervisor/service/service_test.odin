package service

// Service tests (T13b): the supervisor's op driver, inbox and GC against a fake GitHub
// (in memory, releases signed with an ephemeral key by src/supervisor/testkit), a fake
// runtime host and a simulated launcher (exit 75 -> restart the supervisor of `current`).
//
// Bundles contain the fetch preflight helper (src/supervisor/fetch/testdata/fakever) as
// bin/ham-supervisor and bin/ham-bridge; tests that install need HEIMDALL_FETCH_FAKEVER
// (CI builds it, as for the fetch suite) and skip without it.

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import lc "../../launcher/core"
import "../engine"
import "../fetch"
import "../resolver"
import "../testkit"

TEST_ID :: "ins_0123456789abcdef0123456789abcdef"

Behaviour :: enum {
	Good,
	Crash, // exits 20 s after start
	Never_Ready,
}

World :: struct {
	t:         ^testing.T,
	data:      string,
	state:     string,
	key:       testkit.Key,
	published: [dynamic]testkit.Release,
	latest:    int, // index of the stable release; -1 = none
	clock:     i64,
	helper:    []byte,
	// fake host
	running:   string,
	started:   i64,
	behaviour: map[string]Behaviour, // by version
	sessions:  int,
	stop_flag: bool,
	starts:    [dynamic]string,
	ends:      int,
	api_calls: int,
	exited:    bool, // the running runtime has crashed (health Exited until restarted)
	// When set, the bundle download drops this cancel intent into the inbox (it arrives
	// while the download is in progress).
	cancel_on_download: string,
	// supervisor
	s:         Service,
	open:      bool,
	exits:     [dynamic]int,
}

exe :: proc(name: string) -> string {
	return strings.concatenate({name, ".exe"}, context.temp_allocator) when ODIN_OS == .Windows else name
}

helper_bytes :: proc() -> ([]byte, bool) {
	path := os.get_env("HEIMDALL_FETCH_FAKEVER", context.temp_allocator)
	if path == "" do return nil, false
	data, err := os.read_entire_file(path, context.allocator)
	return data, err == nil
}

world_init :: proc(w: ^World, t: ^testing.T) -> bool {
	w.t = t
	helper, ok := helper_bytes()
	if !ok {
		log.warn("HEIMDALL_FETCH_FAKEVER not set: install paths skipped")
		return false
	}
	w.helper = helper
	base, _ := os.temp_directory(context.temp_allocator)
	root, err := os.make_directory_temp(base, "t13b-*", context.allocator)
	testing.expect(t, err == nil)
	w.data = strings.clone(engine.join(root, "data"))
	w.state = strings.clone(engine.join(root, "state"))
	delete(root)
	_ = os.make_directory_all(w.data)
	_ = os.make_directory_all(w.state)
	testing.expect(t, testkit.write_instance(w.data, w.state, TEST_ID), "instance.json")
	w.key = testkit.make_key()
	w.latest = -1
	w.clock = 1_800_000_000
	w.behaviour = make(map[string]Behaviour)
	return true
}

world_destroy :: proc(w: ^World) {
	if w.open do close(&w.s)
	for &r in w.published do testkit.release_destroy(&r)
	delete(w.published)
	delete(w.behaviour)
	for s in w.starts do delete(s)
	delete(w.starts)
	delete(w.exits)
	delete(w.helper)
	delete(w.running)
	testkit.key_destroy(&w.key)
	os.remove_all(engine.join(w.data, ".."))
	delete(w.data)
	delete(w.state)
}

// publish builds and signs a release `tag`; stable = it becomes /releases/latest.
publish :: proc(w: ^World, tag: string, stable := true) -> testkit.Release {
	files := make([]testkit.Bundle_File, 4, context.temp_allocator)
	files[0] = {path = strings.concatenate({"bin/", exe("ham-supervisor")}, context.temp_allocator), data = w.helper, exec = true}
	files[1] = {path = strings.concatenate({"bin/", exe("ham-bridge")}, context.temp_allocator), data = w.helper, exec = true}
	files[2] = {path = "bin/fakever.txt", data = transmute([]byte)strings.clone(tag[1:], context.temp_allocator)}
	files[3] = {path = "share/heimdall/extensions/x.json", data = transmute([]byte)string("{}")}
	r := testkit.make_release(&w.key, {tag = tag, files = files})
	append(&w.published, r)
	if stable do w.latest = len(w.published) - 1
	return r
}

pins :: proc(w: ^World) -> []fetch.Public_Key {
	p := make([]fetch.Public_Key, 1, context.temp_allocator)
	p[0] = w.key.pub
	return p
}

fake_get :: proc(req: resolver.Request, user: rawptr) -> (resp: resolver.Response, ok: bool, detail: string) {
	w := (^World)(user)
	w.api_calls += 1
	switch req.url {
	case resolver.LATEST_URL:
		if w.latest < 0 do return resolver.Response{status = 404, body = `{"message":"Not Found"}`}, true, ""
		return resolver.Response{status = 200, body = testkit.release_api_json(w.published[w.latest])}, true, ""
	case resolver.LIST_URL:
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for r, i in w.published {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, testkit.release_api_json(r, i != w.latest))
		}
		strings.write_byte(&b, ']')
		return resolver.Response{status = 200, body = strings.to_string(b)}, true, ""
	}
	return resolver.Response{status = 404}, true, ""
}

fake_download :: proc(user: rawptr, url: string, sink: fetch.Sink) -> int {
	w := (^World)(user)
	for r in w.published {
		prefix := strings.concatenate({fetch.DOWNLOAD_PREFIX, r.tag, "/"}, context.temp_allocator)
		if !strings.has_prefix(url, prefix) do continue
		name := url[len(prefix):]
		data: []byte
		switch name {
		case r.asset:
			data = r.bundle
			if w.cancel_on_download != "" {
				id := w.cancel_on_download
				w.cancel_on_download = ""
				send_intent(w, id, intent_json(w, id, "cancel"))
			}
		case fetch.MANIFEST_ASSET:
			data = transmute([]byte)r.manifest
		case fetch.SIGNATURE_ASSET:
			data = transmute([]byte)r.signature
		case:
			return 404
		}
		if !sink.write(sink.user, data) do return 0
		return 200
	}
	return 404
}

version_of :: proc(tree: string) -> string {
	i := strings.index_byte(tree, '-')
	return tree[:i] if i > 0 else tree
}

fake_engine_host :: proc(w: ^World) -> engine.Host {
	return engine.Host {
		user = w,
		now = proc(u: rawptr) -> i64 {return (^World)(u).clock},
		reap = proc(u: rawptr) -> bool {return true},
		start_runtime = proc(u: rawptr, tree: string) -> bool {
			w := (^World)(u)
			delete(w.running)
			w.running = strings.clone(tree)
			w.started = w.clock
			w.exited = false
			append(&w.starts, strings.clone(tree))
			return true
		},
		stop_children = proc(u: rawptr, tree: string) -> bool {
			w := (^World)(u)
			delete(w.running)
			w.running = ""
			w.sessions = 0
			return true
		},
		health = proc(u: rawptr) -> engine.Health {
			w := (^World)(u)
			if w.running == "" do return .Down
			if w.exited do return .Exited
			age := w.clock - w.started
			switch w.behaviour[version_of(w.running)] {
			case .Good:
				return .Ready if age >= 2 else .Starting
			case .Crash:
				if age >= 20 do return .Exited
				return .Ready if age >= 2 else .Starting
			case .Never_Ready:
				return .Starting
			}
			return .Starting
		},
		hub_connected = proc(u: rawptr) -> bool {return false},
		hub_recently_connected = proc(u: rawptr) -> bool {return false},
		stop_requested = proc(u: rawptr) -> bool {return (^World)(u).stop_flag},
		gate_count = proc(u: rawptr) -> engine.Busy {
			w := (^World)(u)
			if w.running == "" || w.exited do return {} // not answered: "busy" (fail closed)
			return engine.Busy{counted = true, pty_sessions = w.sessions}
		},
		close_admission = proc(u: rawptr) -> bool {return (^World)(u).running != ""},
		open_admission = proc(u: rawptr) {},
		end_sessions = proc(u: rawptr) {(^World)(u).ends += 1},
	}
}

options :: proc(w: ^World, launched: string, mode := engine.Mode.Normal) -> Options {
	return Options {
		instance_root = w.data,
		state_root = w.state,
		launched = launched,
		mode = mode,
		host = fake_engine_host(w),
		net = Net{get = fake_get, get_user = w, download = fetch.Downloader{get = fake_download, user = w}},
		key_pins = pins(w),
		preflight_timeout_ms = 10_000,
		retry = fetch.Retry_Policy{budget_ms = 200, first_ms = 1, max_ms = 10, sleep = proc(ms: int) {}},
		first_check_s = 1_000_000, // no timer unless a test sets it
	}
}

// launch: the simulated launcher starts the supervisor of `current` (normal mode).
launch :: proc(w: ^World, mode := engine.Mode.Normal, launched := "") -> int {
	if w.open {
		close(&w.s)
		w.open = false
	}
	L := launched
	if L == "" {
		tree, ok := lc.read_pointer(w.data, lc.POINTER_CURRENT)
		testing.expect(w.t, ok, "current pointer")
		L = tree
	}
	code, reason := open(&w.s, options(w, L, mode))
	// Tests run in parallel threads: another test's preflight child may briefly hold an
	// inherited copy of this lock fd between fork and exec. Retry like a launcher would.
	for tries := 0; code >= 0 && reason == "lock_held" && tries < 50; tries += 1 {
		close(&w.s)
		time.sleep(20 * time.Millisecond)
		code, reason = open(&w.s, options(w, L, mode))
	}
	if code >= 0 {
		log.infof("open refused: %s", reason)
		close(&w.s)
		return code
	}
	w.open = true
	x, err := start(&w.s)
	testing.expectf(w.t, !engine.fatal(err), "start: %v", err)
	return exit_of(x, err)
}

// run steps the supervisor (1 s per step) until `done` or `max` steps; a handover restarts
// the supervisor of `current` like the launcher (§7.2).
run :: proc(w: ^World, max := 400, done: proc(w: ^World) -> bool = nil) -> (last_exit: int) {
	for _ in 0 ..< max {
		if done != nil && done(w) do return -1
		w.clock += 1
		x, err := step(&w.s)
		testing.expectf(w.t, !engine.fatal(err), "step: %v", err)
		code := exit_of(x, err)
		if code < 0 do continue
		append(&w.exits, code)
		if code != EXIT_HANDOVER do return code
		if c := launch(w); c >= 0 && c != EXIT_HANDOVER do return c
	}
	return -1
}

op_state :: proc(w: ^World, op_id: string) -> (state, code, note: string) {
	for l in engine.journal_lines(&w.s.eng) {
		if l.op_id == op_id {
			state = l.state
			code = l.error
			note = l.note
		}
	}
	return
}

committed :: proc(w: ^World, op_id: string) -> bool {
	st, _, _ := op_state(w, op_id)
	return engine.is_terminal(st)
}

// install_first: repair-install `tag` on an empty instance, then prove it (adopt / J29).
install_first :: proc(w: ^World, tag: string) -> testkit.Release {
	r := publish(w, tag)
	w.behaviour[r.version] = .Good
	dir := engine.join(w.data, "..", "local")
	_ = os.make_directory_all(dir)
	bundle := engine.join(dir, r.asset)
	_ = os.write_entire_file(bundle, r.bundle)
	mpath := engine.join(dir, fetch.MANIFEST_ASSET)
	_ = os.write_entire_file(mpath, transmute([]byte)r.manifest)
	spath := engine.join(dir, fetch.SIGNATURE_ASSET)
	_ = os.write_entire_file(spath, transmute([]byte)r.signature)
	code := repair({instance_root = w.data, state_root = w.state, bundle = bundle, manifest = mpath, signature = spath, op_id = "op_first", key_pins = pins(w)})
	testing.expect_value(w.t, code, REPAIR_EXIT_OK)
	testing.expect_value(w.t, launch(w), -1)
	run(w, 300, proc(w: ^World) -> bool {return engine.known_good_valid(&w.s.eng) != ""})
	st, _, _ := op_state(w, "op_first")
	testing.expect_value(w.t, st, "committed")
	return r
}

intent_json :: proc(w: ^World, op_id, action: string, extra := "", actor := "app:usr_test") -> string {
	return fmt.tprintf(`{{"is":1,"op_id":"%s","instance_id":"%s","action":"%s","actor":"%s","expires_at":%d,"created_at":%d%s}}`,
		op_id, TEST_ID, action, actor, w.clock + 3600, w.clock, extra)
}

send_intent :: proc(w: ^World, op_id, body: string) {
	dir := engine.join(w.data, "supervisor", "intents", "inbox")
	_ = os.make_directory_all(dir)
	tmp := engine.join(dir, fmt.tprintf("%s.json.tmp", op_id))
	_ = os.write_entire_file(tmp, transmute([]byte)body)
	_ = os.rename(tmp, engine.join(dir, fmt.tprintf("%s.json", op_id)))
}

inbox_empty :: proc(w: ^World) -> bool {
	entries, _ := os.read_directory_by_path(engine.join(w.data, "supervisor", "intents", "inbox"), -1, context.temp_allocator)
	for e in entries do if strings.has_suffix(e.name, ".json") && !strings.has_prefix(e.name, "bad-") do return false
	return true
}

// ---------------------------------------------------------------------------
// Pure tests (no helper needed)

@(test)
test_intent_parse_and_validate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	now: i64 = 1_800_000_000
	good := fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"update_now","actor":"app:u1","expires_at":%d,"created_at":%d,"future":1}}`, TEST_ID, now + 60, now)
	it, st, sok := parse_intent(transmute([]byte)good)
	testing.expect_value(t, st, Parse_Status.Ok)
	testing.expect_value(t, validate_intent(it, sok, TEST_ID, now), "")

	Case :: struct {
		body, want: string,
	}
	cases := []Case {
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"ins_x","action":"update_now","actor":"app:u","expires_at":%d,"created_at":%d}}`, now + 60, now), "wrong_instance"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"explode","actor":"app:u","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now), "unknown_action"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"update_now","actor":"timer","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now), "bad_actor"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"update_now","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now - 1, now - 10), "expired"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"update_now","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 31 * 86400, now), "bad_expiry"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"update_now","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now - 31 * 86400), "stale_intent"},
		{fmt.tprintf(`{{"is":2,"op_id":"op_a","instance_id":"%s","action":"update_now","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now), "schema_error"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"set_channel","channel":"nightly","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now), "bad_channel"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"install_version","version":"latest","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now), "bad_version"},
		{fmt.tprintf(`{{"is":1,"op_id":"op_a","instance_id":"%s","action":"uninstall","actor":"cli","expires_at":%d,"created_at":%d}}`, TEST_ID, now + 60, now), "not_implemented"},
	}
	for c in cases {
		i, s, ok := parse_intent(transmute([]byte)c.body)
		testing.expect_value(t, s, Parse_Status.Ok)
		testing.expectf(t, validate_intent(i, ok, TEST_ID, now) == c.want, "%s: got %q", c.want, validate_intent(i, ok, TEST_ID, now))
	}
	// Unparseable or no usable op_id: never journaled (J31 bad-<ts>.json).
	for bad in ([]string{"", "{", `{"op_id":"x"}`, `{"op_id":"op_../../x"}`, `[1]`}) {
		_, s, _ := parse_intent(transmute([]byte)bad)
		testing.expectf(t, s == .Bad, "%q should be bad", bad)
	}
}

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "t13b-settings-*", context.temp_allocator)
	defer os.remove_all(dir)
	s := read_settings(dir)
	testing.expect_value(t, s.channel, "stable")
	testing.expect(t, s.auto_update, "default auto_update on")
	s.channel = "fast"
	s.auto_update = false
	s.revision = 4
	s.last_op = "op_x"
	s.actor = `app:"q"`
	testing.expect(t, write_settings(dir, s, engine.DEFAULT_RETRY) == nil)
	r := read_settings(dir)
	testing.expect_value(t, r.channel, "fast")
	testing.expect(t, !r.auto_update)
	testing.expect_value(t, r.revision, 4)
	testing.expect_value(t, r.last_op, "op_x")
	testing.expect_value(t, r.actor, `app:"q"`)
}

@(test)
test_procs_file_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "t13b-procs-*", context.temp_allocator)
	defer os.remove_all(dir)
	_ = os.make_directory_all(engine.join(dir, "supervisor"))
	list := []Proc_Record{{id = {pid = 42, start_time = 7}, group = true, role = "runtime", tree = "0.6.0-abc", job = ""}}
	testing.expect(t, write_procs(dir, list) == nil)
	got := read_procs(dir)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0].id.pid, 42)
	testing.expect_value(t, got[0].id.start_time, 7)
	testing.expect_value(t, got[0].role, "runtime")
	testing.expect_value(t, got[0].tree, "0.6.0-abc")
}

// ---------------------------------------------------------------------------
// Install paths (need the fakever helper)

@(test)
test_update_now_installs_and_commits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	a := install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Good

	send_intent(&w, "op_update1", intent_json(&w, "op_update1", "update_now"))
	run(&w, 400, proc(w: ^World) -> bool {return committed(w, "op_update1")})
	st, code, _ := op_state(&w, "op_update1")
	testing.expectf(t, st == "committed", "op_update1 %s %s", st, code)
	cur, _ := lc.read_pointer(w.data, lc.POINTER_CURRENT)
	prev, _ := lc.read_pointer(w.data, lc.POINTER_PREVIOUS)
	testing.expect_value(t, cur, b.tree)
	testing.expect_value(t, prev, a.tree)
	testing.expect_value(t, engine.known_good_valid(&w.s.eng), b.tree)
	testing.expect(t, inbox_empty(&w), "intent consumed")
	// The journal walked the whole diagram (§6.2) for this op.
	want := []string{"requested", "resolving", "downloading", "verifying", "verified", "activating", "probation", "committed"}
	seen := make([dynamic]string, context.temp_allocator)
	for l in engine.journal_lines(&w.s.eng) {
		if l.op_id != "op_update1" do continue
		if len(seen) == 0 || seen[len(seen) - 1] != l.state do append(&seen, l.state)
	}
	testing.expectf(t, len(seen) == len(want), "states %v", seen)
	for s, i in want do if i < len(seen) do testing.expectf(t, seen[i] == s, "state %d: %s != %s", i, seen[i], s)

	// Replaying the same op_id is answered from the op index and never runs again (J1).
	send_intent(&w, "op_update1", intent_json(&w, "op_update1", "update_now"))
	n := len(engine.journal_lines(&w.s.eng))
	run(&w, 5)
	testing.expect(t, inbox_empty(&w), "replay consumed")
	testing.expect_value(t, len(engine.journal_lines(&w.s.eng)), n)

	// Already up to date: noop.
	send_intent(&w, "op_update2", intent_json(&w, "op_update2", "update_now"))
	run(&w, 20, proc(w: ^World) -> bool {return committed(w, "op_update2")})
	st2, _, note2 := op_state(&w, "op_update2")
	testing.expect_value(t, st2, "noop")
	testing.expect_value(t, note2, "up_to_date")
}

@(test)
test_bad_release_rolls_back_and_pins :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	a := install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Crash

	send_intent(&w, "op_bad", intent_json(&w, "op_bad", "update_now"))
	run(&w, 600, proc(w: ^World) -> bool {return committed(w, "op_bad")})
	st, code, _ := op_state(&w, "op_bad")
	testing.expectf(t, st == "rolled_back", "op_bad %s %s", st, code)
	testing.expect_value(t, code, "runtime_exited")
	cur, _ := lc.read_pointer(w.data, lc.POINTER_CURRENT)
	testing.expect_value(t, cur, a.tree)
	testing.expect(t, engine.is_pinned(&w.s.eng, b.version, b.sha256), "candidate pinned")

	// The timer never retries a pinned release (noop pinned); retry_failed clears the pin.
	send_intent(&w, "op_again", intent_json(&w, "op_again", "update_now"))
	run(&w, 30, proc(w: ^World) -> bool {return committed(w, "op_again")})
	st2, _, note2 := op_state(&w, "op_again")
	testing.expect_value(t, st2, "noop")
	testing.expect_value(t, note2, "pinned")
	send_intent(&w, "op_retry", intent_json(&w, "op_retry", "retry_failed", `,"version":"v0.6.1"`))
	run(&w, 10, proc(w: ^World) -> bool {return committed(w, "op_retry")})
	st3, _, _ := op_state(&w, "op_retry")
	testing.expect_value(t, st3, "applied")
	testing.expect(t, !engine.is_pinned(&w.s.eng, b.version, b.sha256), "pin cleared")
}

@(test)
test_timer_waits_for_busy_agents :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	_ = install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Good
	w.sessions = 1 // a live PTY session
	w.s.cache.next_check_at = w.clock + 1 // timer due now

	timer_op :: proc(w: ^World) -> string {
		for l in engine.journal_lines(&w.s.eng) do if l.actor == "timer" do return l.op_id
		return ""
	}
	waiting :: proc(w: ^World) -> bool {
		op, ok := w.s.eng.active.?
		return ok && op.state == "waiting_for_idle"
	}
	run(&w, 60, waiting)
	testing.expect(t, waiting(&w), "timer op waits while a session is live")
	op_id := strings.clone(timer_op(&w), context.temp_allocator)
	cur, _ := lc.read_pointer(w.data, lc.POINTER_CURRENT)
	testing.expect(t, cur != b.tree, "not switched while busy")
	run(&w, 120)
	testing.expect(t, waiting(&w), "still waiting after 2 min")
	// The session ends: the wait ends and the update proceeds.
	w.sessions = 0
	run(&w, 400, proc(w: ^World) -> bool {
		for l in engine.journal_lines(&w.s.eng) do if l.actor == "timer" && l.state == "committed" do return true
		return false
	})
	st, code, _ := op_state(&w, op_id)
	testing.expectf(t, st == "committed", "timer op %s %s", st, code)
	cur2, _ := lc.read_pointer(w.data, lc.POINTER_CURRENT)
	testing.expect_value(t, cur2, b.tree)
}

@(test)
test_update_now_supersedes_wait_and_cancel :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	_ = install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Good
	w.sessions = 2
	waiting :: proc(w: ^World) -> bool {
		op, ok := w.s.eng.active.?
		return ok && op.state == "waiting_for_idle"
	}

	// cancel while waiting (J35): target cancelled, cancel op applied.
	w.s.cache.next_check_at = w.clock + 1
	run(&w, 60, waiting)
	testing.expect(t, waiting(&w))
	target := strings.clone(w.s.eng.active.?.op_id, context.temp_allocator)
	send_intent(&w, "op_mismatch", intent_json(&w, "op_mismatch", "cancel", `,"target_op_id":"op_other"`))
	run(&w, 5, proc(w: ^World) -> bool {return committed(w, "op_mismatch")})
	testing.expect(t, waiting(&w), "a mismatched cancel leaves the wait alone")
	send_intent(&w, "op_cancel", intent_json(&w, "op_cancel", "cancel"))
	run(&w, 10, proc(w: ^World) -> bool {return committed(w, "op_cancel")})
	s1, c1, _ := op_state(&w, "op_mismatch")
	testing.expect_value(t, s1, "rejected")
	testing.expect_value(t, c1, "op_mismatch")
	s2, _, _ := op_state(&w, "op_cancel")
	testing.expect_value(t, s2, "applied")
	s3, _, _ := op_state(&w, target)
	testing.expect_value(t, s3, "cancelled")
	send_intent(&w, "op_cancel2", intent_json(&w, "op_cancel2", "cancel"))
	run(&w, 5, proc(w: ^World) -> bool {return committed(w, "op_cancel2")})
	s4, c4, _ := op_state(&w, "op_cancel2")
	testing.expect_value(t, s4, "rejected")
	testing.expect_value(t, c4, "nothing_to_cancel")

	// A new wait; set_channel and check_now run beside it; install_version is busy;
	// update_now supersedes the wait (J30).
	w.s.cache.next_check_at = w.clock + 1
	run(&w, 60, waiting)
	testing.expect(t, waiting(&w))
	waiting_op := strings.clone(w.s.eng.active.?.op_id, context.temp_allocator)
	send_intent(&w, "op_chan", intent_json(&w, "op_chan", "set_channel", `,"channel":"fast"`))
	send_intent(&w, "op_check", intent_json(&w, "op_check", "check_now"))
	send_intent(&w, "op_iv", intent_json(&w, "op_iv", "install_version", `,"version":"v0.6.1"`))
	run(&w, 5, proc(w: ^World) -> bool {return committed(w, "op_iv") && committed(w, "op_chan") && committed(w, "op_check")})
	sc, _, _ := op_state(&w, "op_chan")
	testing.expect_value(t, sc, "applied")
	testing.expect_value(t, read_settings(w.state).channel, "fast")
	testing.expect_value(t, read_settings(w.state).revision, 1)
	sk, _, nk := op_state(&w, "op_check")
	testing.expect_value(t, sk, "noop")
	testing.expect_value(t, nk, "available")
	si, ci, _ := op_state(&w, "op_iv")
	testing.expect_value(t, si, "cancelled")
	testing.expect_value(t, ci, "busy")
	testing.expect(t, waiting(&w), "side ops left the wait alone")

	send_intent(&w, "op_now", intent_json(&w, "op_now", "update_now"))
	run(&w, 400, proc(w: ^World) -> bool {return committed(w, "op_now")})
	sn, _, nn := op_state(&w, "op_now")
	testing.expect_value(t, sn, "noop")
	testing.expect(t, strings.has_prefix(nn, "superseded_by"), "superseded")
	run(&w, 400, proc(w: ^World) -> bool {
		st, _, _ := op_state(w, "op_now")
		_ = st
		for l in engine.journal_lines(&w.s.eng) do if l.state == "committed" && l.actor == "timer" do return true
		return false
	})
	sw, _, _ := op_state(&w, waiting_op)
	testing.expect_value(t, sw, "committed")
	for l in engine.journal_lines(&w.s.eng) {
		if l.op_id == waiting_op && l.sub == "gate_closed" do testing.expect_value(t, l.interrupted_by, "op_now")
	}
	testing.expect(t, w.ends >= 1, "sessions asked to end before the stop")
}

@(test)
test_invalid_intents_are_rejected_or_moved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	_ = install_first(&w, "v0.6.0")
	send_intent(&w, "op_wrong", strings.concatenate({intent_json(&w, "op_wrong", "update_now")[:0], fmt.tprintf(`{{"is":1,"op_id":"op_wrong","instance_id":"ins_ffffffffffffffffffffffffffffffff","action":"update_now","actor":"cli","expires_at":%d,"created_at":%d}}`, w.clock + 60, w.clock)}, context.temp_allocator))
	send_intent(&w, "garbage", "not json")
	run(&w, 5, proc(w: ^World) -> bool {return committed(w, "op_wrong")})
	st, code, _ := op_state(&w, "op_wrong")
	testing.expect_value(t, st, "rejected")
	testing.expect_value(t, code, "wrong_instance")
	testing.expect(t, inbox_empty(&w), "inbox drained")
	entries, _ := os.read_directory_by_path(engine.join(w.data, "supervisor", "intents", "inbox"), -1, context.temp_allocator)
	bad := 0
	for e in entries do if strings.has_prefix(e.name, "bad-") do bad += 1
	testing.expect_value(t, bad, 1)
}

@(test)
test_gc_keeps_three_trees :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	_ = install_first(&w, "v0.6.0")
	tags := []string{"v0.6.1", "v0.6.2", "v0.6.3"}
	for tag, i in tags {
		r := publish(&w, tag)
		w.behaviour[r.version] = .Good
		id := fmt.tprintf("op_gc%d", i)
		send_intent(&w, id, intent_json(&w, id, "update_now"))
		ctx_id := strings.clone(id, context.temp_allocator)
		_ = ctx_id
		for _ in 0 ..< 400 {
			if committed(&w, id) do break
			run(&w, 1)
		}
		st, code, _ := op_state(&w, id)
		testing.expectf(t, st == "committed", "%s %s %s", id, st, code)
	}
	run(&w, 3)
	entries, _ := os.read_directory_by_path(engine.join(w.data, "releases"), -1, context.temp_allocator)
	trees := 0
	for e in entries do if e.type == .Directory && !strings.has_prefix(e.name, ".") do trees += 1
	testing.expect_value(t, trees, TREES_KEPT)
	testing.expect(t, !os.exists(engine.join(w.data, "releases", w.published[0].tree)), "oldest non-live tree removed")
}

@(test)
test_runtime_crash_while_waiting_is_restarted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	_ = install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Good
	w.sessions = 1
	w.s.cache.next_check_at = w.clock + 1
	waiting :: proc(w: ^World) -> bool {
		op, ok := w.s.eng.active.?
		return ok && op.state == "waiting_for_idle"
	}
	run(&w, 60, waiting)
	testing.expect(t, waiting(&w), "timer op waits")
	starts := len(w.starts)
	w.exited = true // ham-bridge crashes while the op waits for idle agents
	run(&w, 10, proc(w: ^World) -> bool {return !w.exited})
	testing.expect(t, !w.exited, "runtime restarted within the idle backoff")
	testing.expect_value(t, len(w.starts), starts + 1)
	testing.expect(t, waiting(&w), "the op keeps waiting with the restarted runtime")
	// The session ends: the update proceeds as usual.
	w.sessions = 0
	run(&w, 400, proc(w: ^World) -> bool {return engine.known_good_valid(&w.s.eng) != "" && version_of(engine.known_good_valid(&w.s.eng)) == "0.6.1"})
	testing.expect_value(t, version_of(engine.known_good_valid(&w.s.eng)), "0.6.1")
}

@(test)
test_cancel_during_download :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	a := install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Good
	w.cancel_on_download = "op_cancel_dl"
	send_intent(&w, "op_dl", intent_json(&w, "op_dl", "update_now"))
	run(&w, 20, proc(w: ^World) -> bool {return committed(w, "op_dl") && committed(w, "op_cancel_dl")})
	st, _, _ := op_state(&w, "op_dl")
	testing.expect_value(t, st, "cancelled")
	sc, _, _ := op_state(&w, "op_cancel_dl")
	testing.expect_value(t, sc, "applied")
	by := ""
	for l in engine.journal_lines(&w.s.eng) do if l.op_id == "op_dl" && l.state == "cancelled" do by = l.cancelled_by
	testing.expect_value(t, by, "op_cancel_dl")
	cur, _ := lc.read_pointer(w.data, lc.POINTER_CURRENT)
	testing.expect_value(t, cur, a.tree)
	run(&w, 10)
	testing.expect_value(t, len(w.s.eng.open_ops), 0)
	testing.expect_value(t, len(w.s.expires), 0)
}

// J25 through the service: in rollback_failed, a check_now (allowed) and a rejected intent
// (set_channel -> rejected rollback_failed) must not end the sticky state across a restart.
@(test)
test_rollback_failed_stays_sticky_in_service :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: World
	if !world_init(&w, t) do return
	defer world_destroy(&w)
	a := install_first(&w, "v0.6.0")
	b := publish(&w, "v0.6.1")
	w.behaviour[b.version] = .Crash
	send_intent(&w, "op_rf", intent_json(&w, "op_rf", "update_now"))
	// Once the candidate runs, the previous release turns bad too: the rollback fails.
	run(&w, 200, proc(w: ^World) -> bool {return w.s.opts.launched != "" && version_of(w.s.opts.launched) == "0.6.1"})
	w.behaviour[a.version] = .Never_Ready
	run(&w, 600, proc(w: ^World) -> bool {return committed(w, "op_rf")})
	st, _, _ := op_state(&w, "op_rf")
	testing.expect_value(t, st, "rollback_failed")
	testing.expect_value(t, w.s.eng.phase, engine.Phase.Rollback_Failed)

	send_intent(&w, "op_rf_check", intent_json(&w, "op_rf_check", "check_now"))
	send_intent(&w, "op_rf_chan", intent_json(&w, "op_rf_chan", "set_channel", `,"channel":"fast"`))
	run(&w, 10, proc(w: ^World) -> bool {return committed(w, "op_rf_check") && committed(w, "op_rf_chan")})
	sc, cc, _ := op_state(&w, "op_rf_chan")
	testing.expect_value(t, sc, "rejected")
	testing.expect_value(t, cc, "rollback_failed")
	sk, _, _ := op_state(&w, "op_rf_check")
	testing.expect_value(t, sk, "noop")

	starts := len(w.starts)
	testing.expect_value(t, launch(&w), -1) // restart (crash / reboot)
	testing.expectf(t, w.s.eng.phase == .Rollback_Failed, "phase after restart = %v", w.s.eng.phase)
	testing.expect_value(t, len(w.starts), starts) // no runtime started
	run(&w, 30)
	testing.expect_value(t, len(w.starts), starts)
}
