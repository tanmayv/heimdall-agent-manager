package engine

// Test harness: a temp instance root with release trees, a fake host (runtime processes,
// clock, hub), and a simulated launcher that applies the §7.2 rule between supervisor
// processes, so a whole activation can be driven through crashes, handovers and fallbacks.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import lc "../../launcher/core"

make_test_dir :: proc(t: ^testing.T, prefix: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, fmt.tprintf("%s-*", prefix), context.temp_allocator)
	testing.expect(t, err == nil, "make_directory_temp")
	return dir
}

write_text :: proc(path, text: string) -> bool {
	dir, _ := os.split_path(path)
	os.make_directory_all(dir)
	return os.write_entire_file(path, transmute([]byte)text) == nil
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return string(data)
}

Tree_Spec :: struct {
	version:          string,
	digit:            byte, // fills the 64-hex digest
	state_schema:     int,
	state_compat_min: int,
	journal_schema:   int,
}

// make_tree creates a valid release tree (spec §3/§4) and returns its name and Ref.
make_tree :: proc(root: string, s: Tree_Spec) -> Ref {
	sha := strings.repeat(fmt.tprintf("%c", s.digit), 64, context.temp_allocator)
	name := fmt.tprintf("%s-%s", s.version, sha[:12])
	dir := join(root, "releases", name)
	os.make_directory_all(join(dir, "bin"))
	bin := "fake supervisor binary\n"
	write_text(join(dir, "bin", "ham-supervisor"), bin)
	release := fmt.tprintf(
		`{{"version":"%s","targets":{{"%s":{{"sha256":"%s"}}}},"min_engine":1,"journal_schema":%d,"state_schema":%d,"state_compat_min":%d,"min_launcher_abi":1}}`,
		s.version,
		lc.TARGET,
		sha,
		max(s.journal_schema, 1),
		max(s.state_schema, 1),
		max(s.state_compat_min, 1),
	)
	write_text(join(dir, "release.json"), release)
	write_text(
		join(dir, "tree.json"),
		fmt.tprintf(`{{"files":[{{"path":"bin/ham-supervisor","size":%d,"sha256":"%s"}}]}}`, len(bin), strings.repeat("0", 64, context.temp_allocator)),
	)
	write_text(join(dir, ".complete"), "")
	return Ref{strings.clone(s.version, context.temp_allocator), strings.clone(sha, context.temp_allocator), strings.clone(name, context.temp_allocator)}
}

// ---- fake host ----

Behaviour :: enum {
	Good, // ready 5 s after start, stays ready
	Never_Ready, // never reports ready
	Crash, // ready, then exits 20 s after start
}

Fake :: struct {
	clock:          i64,
	running:        string,
	started_at:     i64,
	behaviour:      map[string]Behaviour,
	starts:         [dynamic]string,
	violations:     int, // a runtime started while another one runs (two runtimes, F5)
	stop_ok:        bool,
	reap_ok:        bool,
	hub_recent:     bool,
	hub_up:         bool,
	stop_flag:      bool,
	// stop_children of this tree fails once (stop_timeout) and leaves the runtime running.
	stop_fail_once: string,
	state_root:     string,
	// One-way state: a tree listed here writes "schema-<n>" into config.toml at start; a tree
	// whose schema is lower crashes when it finds a newer one (it cannot read it).
	writes_schema:  map[string]int,
	// Agent gate (§12). `agents` is what the running runtime reports; with no runtime the
	// count is unavailable (counted = false). `silent` = the runtime never answers.
	agents:         Busy,
	silent:         bool,
	admission_open: bool,
	closes:         int, // close_admission calls
	opens:          int, // open_admission calls
	// A launch races the close: the count taken right after the next close is one higher.
	race_on_close:  bool,
	stops:          [dynamic]string, // stop_children calls (tree)
	// end_sessions calls: len(stops) at the time of each call (0 = before the first stop).
	ends:           [dynamic]int,
}

fake_new :: proc() -> ^Fake {
	f := new(Fake)
	f.clock = 1_800_000_000
	f.stop_ok = true
	f.reap_ok = true
	f.behaviour = make(map[string]Behaviour)
	f.writes_schema = make(map[string]int)
	f.starts = make([dynamic]string)
	f.stops = make([dynamic]string)
	f.ends = make([dynamic]int)
	return f
}

fake_free :: proc(f: ^Fake) {
	delete(f.behaviour)
	delete(f.writes_schema)
	delete(f.starts)
	delete(f.stops)
	delete(f.ends)
	free(f)
}

fake_host :: proc(f: ^Fake) -> Host {
	return Host {
		user = f,
		now = proc(u: rawptr) -> i64 {return (^Fake)(u).clock},
		reap = proc(u: rawptr) -> bool {
			// J0 layer 3: survivors of an earlier supervisor (e.g. after exit 1 on a
			// stop_timeout) are terminated here.
			f := (^Fake)(u)
			if f.reap_ok do f.running = ""
			return f.reap_ok
		},
		start_runtime = proc(u: rawptr, tree: string) -> bool {
			f := (^Fake)(u)
			if f.running != "" do f.violations += 1
			f.running = strings.clone(tree, context.temp_allocator)
			f.started_at = f.clock
			f.admission_open = true // a fresh runtime starts with admission open
			append(&f.starts, strings.clone(tree, context.temp_allocator))
			if n, ok := f.writes_schema[tree]; ok && f.state_root != "" {
				write_text(join(f.state_root, "config.toml"), fmt.tprintf("schema-%d", n))
			}
			return true
		},
		stop_children = proc(u: rawptr, tree: string) -> bool {
			f := (^Fake)(u)
			append(&f.stops, strings.clone(tree, context.temp_allocator))
			if !f.stop_ok do return false
			if f.stop_fail_once != "" && f.stop_fail_once == tree {
				f.stop_fail_once = ""
				return false
			}
			f.running = ""
			return true
		},
		health = proc(u: rawptr) -> Health {
			f := (^Fake)(u)
			if f.running == "" do return .Down
			// A tree that cannot read the state on disk crashes (one-way migration test).
			if mine, ok := f.writes_schema[f.running]; ok && f.state_root != "" {
				text := read_text(join(f.state_root, "config.toml"))
				if strings.has_prefix(text, "schema-") {
					n := int(text[7] - '0')
					if n > mine do return .Exited
				}
			}
			age := f.clock - f.started_at
			switch f.behaviour[f.running] {
			case .Good:
				return .Ready if age >= 5 else .Starting
			case .Never_Ready:
				return .Starting
			case .Crash:
				if age >= 20 do return .Exited
				return .Ready if age >= 5 else .Starting
			}
			return .Starting
		},
		hub_connected = proc(u: rawptr) -> bool {return (^Fake)(u).hub_up},
		hub_recently_connected = proc(u: rawptr) -> bool {return (^Fake)(u).hub_recent},
		stop_requested = proc(u: rawptr) -> bool {return (^Fake)(u).stop_flag},
		gate_count = proc(u: rawptr) -> Busy {
			f := (^Fake)(u)
			if f.running == "" || f.silent do return Busy{}
			b := f.agents
			b.counted = true
			return b
		},
		close_admission = proc(u: rawptr) -> bool {
			f := (^Fake)(u)
			f.closes += 1
			if f.running == "" || f.silent do return false
			if f.race_on_close {
				f.race_on_close = false
				f.agents.launches += 1
			}
			f.admission_open = false
			return true
		},
		open_admission = proc(u: rawptr) {
			f := (^Fake)(u)
			f.opens += 1
			if f.running != "" do f.admission_open = true
		},
		end_sessions = proc(u: rawptr) {
			f := (^Fake)(u)
			append(&f.ends, len(f.stops))
		},
	}
}

// ---- world: instance root + simulated launcher ----

Crash_Flavour :: enum {
	Supervisor, // the supervisor dies, the launcher lives (§7.2 fallback may apply)
	Power_Loss, // machine restarts: launcher restarts too, torn writes possible
}

World :: struct {
	t:             ^testing.T,
	root:          string,
	state:         string,
	fake:          ^Fake,
	inj:           Injector,
	flavour:       Crash_Flavour,
	e:             Engine,
	open:          bool,
	launched:      string,
	mode:          Mode,
	unproven:      bool, // launched C while C != K
	fallback_flag: bool,
	crashes:       int,
	exits:         int, // supervisor exit 1 after a fatal engine error (Error contract)
	handovers:     int,
	refusals:      int,
	gate_wait_s:   i64, // 0 = default (2 h)
}

world_init :: proc(w: ^World, t: ^testing.T, prefix: string) {
	w.t = t
	w.root = make_test_dir(t, prefix)
	w.state = join(w.root, "state")
	os.make_directory_all(w.state)
	w.fake = fake_new()
	w.fake.state_root = strings.clone(w.state, context.temp_allocator)
}

world_destroy :: proc(w: ^World) {
	if w.open do close(&w.e)
	w.open = false
	os.remove_all(w.root)
	fake_free(w.fake)
}

TEST_STORES := []State_Store{{.State, "config.toml", 1 << 20}}

world_config :: proc(w: ^World) -> Config {
	cfg := default_config(w.root, w.state)
	cfg.retry.sleep = proc(ms: int) {}
	cfg.state_stores = TEST_STORES
	if w.gate_wait_s != 0 do cfg.gate_wait_s = w.gate_wait_s
	return cfg
}

// install: the initial state of an installed instance: current = known-good = tree.
install :: proc(w: ^World, tree: Ref) {
	e: Engine
	if open(&e, world_config(w), fake_host(w.fake)) != .Run {
		testing.fail_now(w.t, "install: open")
	}
	defer close(&e)
	testing.expect(w.t, write_pointer(&e, POINTER_CURRENT, tree.tree, "op_install") == nil)
	testing.expect(w.t, write_known_good(&e, tree.tree, "op_install") == nil)
}

// launch: §7.2 with re-read of all three records, then supervisor open + start.
launch :: proc(w: ^World) -> (x: Exit, err: Error) {
	rec := lc.read_records(w.root)
	C, P, K := rec.current, rec.previous, rec.known_good
	switch {
	case w.fallback_flag:
		w.launched, w.mode = P, .Fallback
	case C == "":
		if P != "" do w.launched, w.mode = P, .Fallback
		else if K != "" do w.launched, w.mode = K, .Normal
		else do testing.fail_now(w.t, "launcher: no tree to start")
	case:
		w.launched, w.mode = C, .Normal
	}
	w.unproven = !w.fallback_flag && C != "" && C != K
	w.launched = strings.clone(w.launched, context.temp_allocator)
	ox := open(&w.e, world_config(w), fake_host(w.fake), &w.inj)
	w.open = true
	if ox == .Refuse {
		if crashed(&w.inj) do return .Run, crash_error("open")
		w.refusals += 1
		return .Refuse, nil
	}
	return start(&w.e, w.launched, w.mode)
}

// crash: the supervisor process is gone. Children die with it (§2.1).
crash :: proc(w: ^World) {
	w.crashes += 1
	if w.open do close(&w.e)
	w.open = false
	w.fake.running = ""
	switch w.flavour {
	case .Supervisor:
		P := lc.read_records(w.root).previous
		if w.unproven && P != "" && P != w.launched do w.fallback_flag = true
	case .Power_Loss:
		w.fallback_flag = false
	}
	// After the single injected crash nothing else fails.
	w.inj.crash_at = 0
	w.inj.crashed = false
}

// exit_failure: the supervisor exits 1 on a fatal engine error (Error contract). Unlike a
// crash its children are not assumed dead: the next start's J0 reap must deal with them.
// The launcher treats exit 1 like a crash (§7.2).
exit_failure :: proc(w: ^World) {
	w.exits += 1
	if w.open do close(&w.e)
	w.open = false
	P := lc.read_records(w.root).previous
	w.fallback_flag = w.unproven && P != "" && P != w.launched
}

handover :: proc(w: ^World) {
	w.handovers += 1
	testing.expectf(w.t, w.fake.running == "", "handover with a runtime still running from %s", w.fake.running)
	if w.open do close(&w.e)
	w.open = false
	w.fake.running = ""
	w.fallback_flag = false
}

// handle routes one engine result; returns false when the step crashed or exited.
handle :: proc(w: ^World, x: Exit, err: Error) -> bool {
	if err != nil {
		if is_crash(err) {
			crash(w)
			return false
		}
		if fatal(err) {
			// The poisoned engine refuses further calls (Error contract).
			if w.open {
				_, again := tick(&w.e)
				testing.expectf(w.t, error_code(again) == error_code(err), "poisoned engine answered %v after %v", again, err)
			}
			exit_failure(w)
			return false
		}
		testing.expectf(w.t, false, "engine usage error %v", err)
		exit_failure(w)
		return false
	}
	#partial switch x {
	case .Handover:
		handover(w)
		return false
	case .Refuse:
		if w.open do close(&w.e)
		w.open = false
		return false
	}
	return true
}

Outcome :: struct {
	state:  string,
	error:  string,
	note:   string,
	op_id:  string,
	steps:  int, // durable steps counted by the injector during the run
	crashed: bool,
}

// drive: from an installed instance, run one activation of `to` through the engine,
// restarting supervisors exactly like the launcher would, until the op is terminal and
// the instance is idle (or rollback_failed). Returns the op's terminal line.
drive :: proc(w: ^World, op_id: string, to: Ref, max_iters := 400, actor := "app:usr_test") -> (out: Outcome) {
	begun := false
	for iter := 0; iter < max_iters; iter += 1 {
		if !w.open {
			x, err := launch(w)
			if !handle(w, x, err) do continue
		}
		e := &w.e
		op, has := e.active.?
		switch {
		case !begun && !has:
			begun = true
			err := begin_verified(e, Activation{op_id = op_id, action = "update_now", actor = actor, to = to})
			if !handle(w, .Run, err) do continue
			x, aerr := activate(e)
			handle(w, x, aerr)
		case has && (op.state == "requested" || op.state == "verifying"):
			err := mark_verified(e, to)
			if !handle(w, .Run, err) do continue
			x, aerr := activate(e)
			handle(w, x, aerr)
		case has && op.state == "verified":
			x, aerr := activate(e)
			handle(w, x, aerr)
		case !has && begun && (e.phase == .Idle || e.phase == .Rollback_Failed):
			out = final_outcome(w, op_id)
			if out.state == "" {
				begun = false // the crash came before the op's first line landed
				continue
			}
			out.steps = w.inj.steps
			return
		case:
			w.fake.clock += 5
			x, err := tick(e)
			handle(w, x, err)
		}
	}
	testing.expectf(w.t, false, "drive did not settle (op %s)", op_id)
	return
}

// final_outcome reads the journal: the last terminal line of op_id (or of a synthetic op
// that replaced it).
final_outcome :: proc(w: ^World, op_id: string) -> (out: Outcome) {
	r := read_journal_file(join(w.root, "supervisor", "journal", "ops.jsonl"), context.temp_allocator)
	for l in r.lines {
		if is_terminal(l.state) && (l.op_id == op_id || strings.has_prefix(l.op_id, "op_fallback_") || strings.has_prefix(l.op_id, "op_adopt_")) {
			out.state = l.state
			out.error = l.error
			out.note = l.note
			out.op_id = l.op_id
		}
	}
	return
}
