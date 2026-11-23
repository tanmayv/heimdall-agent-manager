package engine

// Failure injection at every durable write of a whole activation (spec §6.3, §18): for each
// scenario, crash at step k = 1, 2, … in each crash mode (step dropped / landed / torn) and
// each flavour (supervisor crash with the launcher alive, or power loss), restart the way
// the launcher would, and assert the instance ends on a working version or in a clearly
// reported terminal state — never on an invalid `current`, never with two runtimes.

import "core:fmt"
import "core:testing"
import lc "../../launcher/core"

Scenario :: enum {
	Good, // candidate healthy
	Bad_Never_Ready, // candidate never reports ready
	Bad_Crash, // candidate crashes in probation
	Both_Bad, // candidate and previous both fail (rollback_failed)
	One_Way_Bad, // one-way state migration; candidate fails -> snapshot restored
	Timer_Forced, // timer op, agents stay busy: waits (agent gate §12), forced, commits
}

@(private = "file")
setup :: proc(w: ^World, s: Scenario) -> (from, to: Ref) {
	from = make_tree(w.root, Tree_Spec{version = "0.6.0", digit = 'a', state_schema = 1, state_compat_min = 1})
	if s == .One_Way_Bad {
		to = make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b', state_schema = 2, state_compat_min = 2})
		w.fake.writes_schema[from.tree] = 1
		w.fake.writes_schema[to.tree] = 2
		write_text(join(w.state, "config.toml"), "schema-1")
	} else {
		to = make_tree(w.root, Tree_Spec{version = "0.6.1", digit = 'b', state_schema = 1, state_compat_min = 1})
	}
	w.fake.behaviour[from.tree] = .Good
	switch s {
	case .Good, .Timer_Forced:
		w.fake.behaviour[to.tree] = .Good
	case .Bad_Never_Ready, .Both_Bad:
		w.fake.behaviour[to.tree] = .Never_Ready
	case .Bad_Crash, .One_Way_Bad:
		w.fake.behaviour[to.tree] = .Crash
	}
	if s == .Timer_Forced {
		w.gate_wait_s = 60
		w.fake.agents = Busy{pty_sessions = 2, helpers = 1}
	}
	install(w, from)
	return
}

@(private = "file")
check_final :: proc(w: ^World, s: Scenario, from, to: Ref, out: Outcome, label: string) {
	defer if w.open {
		// Whatever the history, a supervisor restart now must not resurrect the op or start
		// a second runtime (rollback_failed stays terminal, J25).
		close(&w.e)
		w.open = false
		running_before := w.fake.running
		w.fake.running = "" // the supervisor and its children stopped cleanly
		x, err := launch(w)
		testing.expectf(w.t, err == nil && x == .Run, "%s: restart after the end: %v %v", label, x, err)
		testing.expectf(w.t, w.e.active == nil, "%s: restart re-opened an op", label)
		if out.state == "rollback_failed" {
			testing.expectf(w.t, w.e.phase == .Rollback_Failed && w.fake.running == "", "%s: rollback_failed not sticky across a restart (phase %v, runtime %s)", label, w.e.phase, w.fake.running)
		} else {
			testing.expectf(w.t, w.fake.running == running_before, "%s: restart runs %s, before %s", label, w.fake.running, running_before)
		}
	}
	t := w.t
	rec := lc.read_records(w.root)
	testing.expectf(t, out.state != "", "%s: no terminal state", label)
	testing.expectf(t, w.fake.violations == 0, "%s: two runtimes ran at once (%d)", label, w.fake.violations)
	switch out.state {
	case "committed":
		testing.expectf(t, s == .Good || s == .Timer_Forced, "%s: a bad candidate committed", label)
		testing.expectf(t, rec.current == to.tree && rec.known_good == to.tree, "%s: committed but current=%s known_good=%s", label, rec.current, rec.known_good)
		testing.expectf(t, w.fake.running == to.tree, "%s: committed but runtime is %s", label, w.fake.running)
	case "rolled_back":
		testing.expectf(t, rec.current == from.tree && rec.known_good == from.tree, "%s: rolled_back but current=%s known_good=%s", label, rec.current, rec.known_good)
		testing.expectf(t, w.fake.running == from.tree, "%s: rolled_back but runtime is %s", label, w.fake.running)
		e: Engine
		e.cfg.instance_root = w.root
		testing.expectf(t, is_pinned(&e, to.version, to.sha256), "%s: rolled back without pinning the candidate", label)
		if s == .One_Way_Bad {
			testing.expectf(t, read_text(join(w.state, "config.toml")) == "schema-1", "%s: one-way state not restored: %q", label, read_text(join(w.state, "config.toml")))
		}
	case "failed":
		testing.expectf(t, rec.current == from.tree && rec.known_good == from.tree, "%s: failed but current=%s known_good=%s", label, rec.current, rec.known_good)
		testing.expectf(t, w.fake.running == from.tree, "%s: failed but runtime is %s", label, w.fake.running)
	case "rollback_failed":
		testing.expectf(t, s == .Both_Bad, "%s: rollback_failed although the previous tree is good (error=%s note=%s)", label, out.error, out.note)
		testing.expectf(t, rec.current == from.tree, "%s: rollback_failed must leave current on the previous tree, got %s", label, rec.current)
	case:
		testing.expectf(t, false, "%s: unexpected terminal state %s", label, out.state)
	}
	testing.expectf(t, rec.current != "", "%s: current invalid at the end", label)
}

@(private = "file")
run_scenario :: proc(t: ^testing.T, s: Scenario, flavour: Crash_Flavour, mode: Crash_Mode, crash_at: int) -> (out: Outcome, crashes: int) {
	return run_with(t, s, flavour, Injector{crash_at = crash_at, mode = mode})
}

@(private = "file")
run_with :: proc(t: ^testing.T, s: Scenario, flavour: Crash_Flavour, inj: Injector, delivered: ^bool = nil, what: ^string = nil) -> (out: Outcome, crashes: int) {
	w: World
	world_init(&w, t, "t13-inj")
	defer world_destroy(&w)
	from, to := setup(&w, s)
	w.flavour = flavour
	w.inj = inj
	crash_at := inj.crash_at if inj.fail_at == 0 else inj.fail_at
	mode := inj.mode
	if s == .Both_Bad {
		// The previous tree breaks too once the activation starts (e.g. a shared dependency).
		// It must still start once as installed, so launch on the good tree first.
		x, err := launch(&w)
		handle(&w, x, err)
		w.fake.behaviour[from.tree] = .Never_Ready
	}
	out = drive(&w, "op_01testactivation000000000", to, actor = "timer" if s == .Timer_Forced else "app:usr_test")
	label := fmt.tprintf("%v/%v/%v@%d", s, flavour, mode, crash_at)
	if inj.fail_at != 0 do label = fmt.tprintf("%v/fail-%v@%d (%s)", s, inj.fail_kind, inj.fail_at, w.inj.failed_what)
	if delivered != nil do delivered^ = w.inj.failed
	if what != nil do what^ = w.inj.failed_what
	check_final(&w, s, from, to, out, label)
	return out, w.crashes
}

@(test)
test_baseline_outcomes :: proc(t: ^testing.T) {
	want := [Scenario]string {
		.Good            = "committed",
		.Bad_Never_Ready = "rolled_back",
		.Bad_Crash       = "rolled_back",
		.Both_Bad        = "rollback_failed",
		.One_Way_Bad     = "rolled_back",
		.Timer_Forced    = "committed",
	}
	for s in Scenario {
		out, _ := run_scenario(t, s, .Supervisor, .Drop, 0)
		testing.expectf(t, out.state == want[s], "%v: got %s (%s), want %s", s, out.state, out.error, want[s])
	}
}

// Every durable step x {drop, land, torn} x {supervisor crash, power loss} x scenario.
@(test)
test_crash_at_every_durable_step :: proc(t: ^testing.T) {
	total_runs := 0
	dist := make(map[string]int, context.temp_allocator)
	for s in Scenario {
		for flavour in Crash_Flavour {
			for mode in Crash_Mode {
				for k := 1; k < 400; k += 1 {
					out, crashes := run_scenario(t, s, flavour, mode, k)
					total_runs += 1
					dist[fmt.tprintf("%v %s %s", s, out.state, out.error)] += 1
					if crashes == 0 do break // k is past the last durable step of this scenario
				}
			}
		}
	}
	testing.expectf(t, total_runs > 200, "suspiciously few injection runs: %d", total_runs)
	fmt.printfln("t13 failure injection: %d runs", total_runs)
	for k, v in dist do fmt.printfln("  %4d  %s", v, k)
}

// Every durable step fails once *without* a crash, the way a real disk does: busy beyond the
// W3 budget (fs_busy) or an I/O error (fs_error; a journal append writes half its line
// first). The engine reports it under the Error contract (supervisor exits 1, or retries a
// commit / rolled_back write in place), the launcher restarts it, and the instance must end
// on a working version or in a clearly reported terminal state.
@(test)
test_non_crash_failure_at_every_durable_step :: proc(t: ^testing.T) {
	total_runs := 0
	dist := make(map[string]int, context.temp_allocator)
	for s in Scenario {
		for kind in Fail_Kind {
			for k := 1; k < 400; k += 1 {
				delivered := false
				what := ""
				out, _ := run_with(t, s, .Supervisor, Injector{fail_at = k, fail_kind = kind}, &delivered, &what)
				if !delivered do break // k is past the last durable step of this scenario
				total_runs += 1
				dist[fmt.tprintf("%v %s %s", s, out.state, out.error)] += 1
				if s == .Good || s == .Timer_Forced {
					testing.expectf(t, out.state == "committed" || out.state == "failed" || out.state == "rolled_back", "Good/fail-%v@%d (%s): %s", kind, k, what, out.state)
				}
			}
		}
	}
	testing.expectf(t, total_runs > 100, "suspiciously few failure runs: %d", total_runs)
	fmt.printfln("t13 non-crash failure injection: %d runs", total_runs)
	for k, v in dist do fmt.printfln("  %4d  %s", v, k)
}
