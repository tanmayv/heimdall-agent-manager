// Package service is the running ham-supervisor (T13b): it wires the T13 engine, the T11
// resolver, the T12 fetch pipeline and the T14 agent gate into one tick-driven process
// (docs/specs/bridge-supervisor-engine.md §2, §6, §7.3, §10, §13.3, §14, §15, §16).
//
//   s: Service
//   if code := open(&s, opts); code >= 0 do exit(code)    ownership (§3), lock + J0 (§6.3)
//   x, err := start(&s)                                    §7.6 decision, recovery
//   .Run -> write READY, then loop { x, err = step(&s) }   tick, inbox, timer, op driver
//   stop -> shutdown(&s)                                   §7.5, exit 0
//
// Everything happens on the main thread. An operation runs synchronously inside `step`
// from `requested` to `verified` (resolve, download, verify, unpack) and on through the
// agent gate; a timer op whose agents are busy waits in `waiting_for_idle` and `step`
// re-evaluates it every second (engine.tick). Exit codes follow the engine's contract:
// 0 stop, 75 handover, 78 refuse, 1 fatal engine error.
package service

import "core:fmt"
import "core:os"
import "core:strings"
import lc "../../launcher/core"
import "../engine"
import "../fetch"
import "../resolver"

EXIT_STOP :: 0
EXIT_FATAL :: engine.EXIT_ENGINE_FAILURE
EXIT_HANDOVER :: 75
EXIT_REFUSE :: 78

INBOX_INTERVAL_S :: 2
BAD_INTENT_TTL_S :: 7 * 24 * 3600
TREES_KEPT :: 3

// Net: the network the supervisor uses, injected so tests can serve a fake GitHub.
Net :: struct {
	get:      resolver.Get, // GitHub API (resolution, §13.1)
	get_user: rawptr,
	download: fetch.Downloader, // release asset downloads (§14 steps 1, 6)
}

Options :: struct {
	instance_root:        string, // <data>
	state_root:           string, // <state>
	launched:             string, // --launched-tree
	mode:                 engine.Mode, // --launch-mode
	target:               string, // "" = this build's target
	host:                 engine.Host,
	net:                  Net,
	engine_cfg:           engine.Config, // zero = engine.default_config
	key_pins:             []fetch.Public_Key, // nil = the embedded pinned keys
	os_policy:            fetch.Os_Signature_Policy,
	preflight_timeout_ms: int,
	retry:                fetch.Retry_Policy, // zero = fetch.DEFAULT_RETRY (tests shorten it)
	// Random source in [0, 1) for the cadence jitter; nil = 0.5.
	rand:                 proc() -> f64,
	// First timer check this many seconds after start; < 0 = the spec's 10–30 min (§13.3).
	first_check_s:        i64,
	// Called once a runtime that was running in the idle phase exits: restart it.
	// (The engine restarts nothing outside probation; the service does, with backoff.)
	log:                  proc(msg: string),
}

Service :: struct {
	opts:           Options,
	eng:            engine.Engine,
	instance:       lc.Instance_Record,
	cache:          resolver.Cache,
	last_scan:      i64,
	// expires_at of user-started ops accepted by this process (J2/J26). An op resumed after
	// a restart has no in-memory expiry: it was accepted, so it runs.
	expires:        map[string]i64,
	opened:         bool,
	gc_due:         bool,
	idle_restarts:  int,
	scan_now:       bool, // the driver stepped back for a queued cancel: scan at once
	idle_retry_at:  i64,
}

logf :: proc(s: ^Service, format: string, args: ..any) {
	msg := fmt.tprintf(format, ..args)
	if s.opts.log != nil do s.opts.log(msg)
}

now :: proc(s: ^Service) -> i64 {
	return s.opts.host.now(s.opts.host.user)
}

target :: proc(s: ^Service) -> string {
	return s.opts.target if s.opts.target != "" else lc.TARGET
}

sup_path :: proc(s: ^Service, parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, s.opts.instance_root, "supervisor")
	append(&all, ..parts)
	return engine.join(..all[:])
}

// open: ownership check (§3 [T0 Q8]) and engine.open (lock, J0). Returns -1 to continue or
// the exit code (78 on refusal). `reason` says why it refused.
open :: proc(s: ^Service, opts: Options) -> (code: int, reason: string) {
	s^ = {}
	s.opts = opts
	s.expires = make(map[string]i64)
	rec, rreason := lc.read_instance_record(opts.instance_root)
	s.instance = rec // owned by s (freed by close), also on refusal
	if rreason != "" do return EXIT_REFUSE, rreason
	if creason := lc.check_instance_record(rec, opts.instance_root, opts.state_root); creason != "" {
		return EXIT_REFUSE, creason
	}
	cfg := opts.engine_cfg
	if cfg.instance_root == "" {
		base := engine.default_config(opts.instance_root, opts.state_root)
		if cfg.probation_s > 0 do base.probation_s = cfg.probation_s
		if cfg.ready_timeout_s > 0 do base.ready_timeout_s = cfg.ready_timeout_s
		if cfg.gate_wait_s > 0 do base.gate_wait_s = cfg.gate_wait_s
		if cfg.retry.budget_ms > 0 do base.retry = cfg.retry
		cfg = base
	}
	if engine.open(&s.eng, cfg, opts.host) != .Run {
		return EXIT_REFUSE, s.eng.refuse_reason
	}
	s.opened = true
	load_cache(s)
	return -1, ""
}

close :: proc(s: ^Service) {
	if s.opened do engine.close(&s.eng)
	resolver.cache_destroy(&s.cache)
	for k in s.expires do delete(k)
	delete(s.expires)
	delete(s.instance.instance_id)
	delete(s.instance.owner.sid)
	delete(s.instance.data_root)
	delete(s.instance.state_root)
	s.opened = false
}

// exit_of maps an engine result to the process exit code; -1 = keep running.
exit_of :: proc(x: engine.Exit, err: engine.Error) -> int {
	if engine.fatal(err) do return EXIT_FATAL
	return engine.exit_code(x)
}

// start: §7.6 decision and journal recovery (engine.start). .Run = write READY, then step.
start :: proc(s: ^Service) -> (x: engine.Exit, err: engine.Error) {
	x, err = engine.start(&s.eng, s.opts.launched, s.opts.mode)
	if x != .Run || err != nil do return
	first := s.opts.first_check_s
	t := now(s)
	if first >= 0 {
		s.cache.next_check_at = max(t + first, s.cache.rate_limit_reset_at)
	} else {
		resolver.schedule_start(&s.cache, t, rand01(s))
	}
	s.gc_due = true
	return
}

rand01 :: proc(s: ^Service) -> f64 {
	return s.opts.rand() if s.opts.rand != nil else 0.5
}

stop_requested :: proc(s: ^Service) -> bool {
	h := s.opts.host
	return h.stop_requested != nil && h.stop_requested(h.user)
}

// step: one main-loop iteration (call about once a second).
step :: proc(s: ^Service) -> (x: engine.Exit, err: engine.Error) {
	x, err = engine.tick(&s.eng)
	if x != .Run || err != nil do return
	if stop_requested(s) do return
	// The inbox goes first, so a cancel that made the driver step back (cancel_pending)
	// reaches the op before the driver resumes it.
	t := now(s)
	if t - s.last_scan >= INBOX_INTERVAL_S || s.last_scan == 0 || s.scan_now {
		s.last_scan = t
		s.scan_now = false
		x, err = scan_inbox(s)
		if x != .Run || err != nil do return
	}
	x, err = drive(s)
	if x != .Run || err != nil do return
	prune_expiries(s)
	if s.gc_due {
		s.gc_due = false
		gc(s)
	}
	x, err = timer(s)
	if x != .Run || err != nil do return
	err = watch_idle_runtime(s)
	return
}

// shutdown: §7.5 service stop.
shutdown :: proc(s: ^Service) -> (x: engine.Exit, err: engine.Error) {
	return engine.stop(&s.eng)
}

// watch_idle_runtime: the engine judges the runtime only during probation. While idle, a
// runtime that exited is restarted from the launched tree with backoff (1 s doubling to
// 60 s); the hub reconnect and agent reconcile are the runtime's own.
@(private)
watch_idle_runtime :: proc(s: ^Service) -> engine.Error {
	h := s.opts.host
	if s.eng.phase != .Idle || h.health == nil do return nil
	// An op that has not reached `activating` (requested … waiting_for_idle) leaves the
	// runtime to us: without a restart a crashed runtime would stay down for the whole gate
	// wait (an unanswered count is "busy", so a timer op would wait 2 h, T13b review).
	if op, active := s.eng.active.?; active && !pre_activation(op.state) do return nil
	hl := h.health(h.user)
	t := now(s)
	if hl == .Ready {
		s.idle_restarts = 0
		return nil
	}
	if hl != .Exited do return nil
	if t < s.idle_retry_at do return nil
	logf(s, "runtime exited while idle; restarting from %s (attempt %d)", s.opts.launched, s.idle_restarts + 1)
	if !h.stop_children(h.user, s.opts.launched) {
		// A survivor must never run beside a new runtime: exit 1, the launcher restarts us
		// and J0 reaps it (or refuses with 78 if it cannot), T13b safety review.
		return engine.fail("stop_timeout", "a recorded process of %s survived its stop", s.opts.launched)
	}
	_ = h.start_runtime(h.user, s.opts.launched)
	s.idle_restarts += 1
	s.idle_retry_at = t + min(i64(1) << uint(min(s.idle_restarts, 6)), 60)
	return nil
}

// pre_activation: states before `activating` (nothing of the runtime is being stopped).
pre_activation :: proc(state: string) -> bool {
	switch state {
	case "requested", "resolving", "downloading", "verifying", "verified", "waiting_for_idle":
		return true
	}
	return false
}

// ---------------------------------------------------------------------------------------
// Journal helpers
// ---------------------------------------------------------------------------------------

// put journals one line; a terminal line schedules GC (§15 "after every terminal op").
put :: proc(s: ^Service, l: engine.Line) -> engine.Error {
	if err := engine.journal(&s.eng, l); err != nil do return err
	if engine.is_terminal(l.state) {
		s.gc_due = true
		forget_expiry(s, l.op_id)
	}
	return nil
}

// prune_expiries drops the expiry of every op that is no longer open: terminal lines are
// also written by the engine itself (cancel_active, interrupt, commit, rollback). An entry is
// added only right before its op's `requested` line, so an entry without an open op is done.
prune_expiries :: proc(s: ^Service) {
	if len(s.expires) == 0 do return
	done := make([dynamic]string, context.temp_allocator)
	for k in s.expires do if !engine.is_open(&s.eng, k) do append(&done, k)
	for k in done do forget_expiry(s, k)
}

// forget_expiry drops an op's in-memory expires_at once it is terminal (the map would
// otherwise grow by one entry per accepted intent for the life of the process).
forget_expiry :: proc(s: ^Service, op_id: string) {
	if op_id not_in s.expires do return
	key, _ := delete_key(&s.expires, op_id)
	delete(key)
}

terminal :: proc(op: engine.Line, state: string, code := "", note := "") -> engine.Line {
	t := op
	t.state = state
	t.sub = ""
	t.error = code
	t.note = note
	return t
}

next_state :: proc(op: engine.Line, state: string) -> engine.Line {
	t := op
	t.state = state
	t.sub = ""
	t.error = ""
	return t
}

// in_index: the op already reached a terminal state (§6.1 op index).
in_index :: proc(s: ^Service, op_id: string) -> bool {
	idx, ok := engine.read_op_index(sup_path(s, "journal", "op-index.json"), context.temp_allocator)
	if !ok do return false
	_, found := idx[op_id]
	return found
}

// in_journal: any line of the op exists. Open ops answer from memory; otherwise the file
// is read (once per arriving intent, never per tick), which also covers a terminal op whose
// op-index write failed without a crash (the index is reconciled only at start).
in_journal :: proc(s: ^Service, op_id: string) -> bool {
	if engine.is_open(&s.eng, op_id) do return true
	for l in engine.journal_lines(&s.eng) do if l.op_id == op_id do return true
	return false
}

// ---------------------------------------------------------------------------------------
// resolver.json (ETag cache, cadence)
// ---------------------------------------------------------------------------------------

@(private)
load_cache :: proc(s: ^Service) {
	data, err := os.read_entire_file(sup_path(s, "resolver.json"), context.temp_allocator)
	if err == nil {
		if c, ok := resolver.cache_unmarshal(data); ok && c.target == target(s) {
			s.cache = c
			return
		}
	}
	s.cache = resolver.cache_make()
	s.cache.target = strings.clone(target(s), s.cache.allocator)
}

@(private)
save_cache :: proc(s: ^Service) {
	data, ok := resolver.cache_marshal(s.cache, context.temp_allocator)
	if !ok do return
	// Best effort: a lost cache only costs a non-conditional request.
	_ = engine.replace_durable(nil, s.eng.cfg.retry, sup_path(s, "resolver.json"), data, "resolver", engine.PRIVATE_FILE_PERMS)
}

// ---------------------------------------------------------------------------------------
// Live trees (W1)
// ---------------------------------------------------------------------------------------

live_trees :: proc(s: ^Service) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, t: string) {
		if t == "" do return
		for x in out do if x == t do return
		append(out, t)
	}
	add(&out, engine.read_pointer_raw(&s.eng, lc.POINTER_CURRENT))
	add(&out, engine.read_pointer_raw(&s.eng, lc.POINTER_PREVIOUS))
	add(&out, engine.read_known_good_raw(&s.eng))
	add(&out, s.opts.launched)
	for l in engine.non_terminal_ops(&s.eng) {
		add(&out, l.to.tree)
		add(&out, l.from.tree)
	}
	for t in procs_trees(s.opts.instance_root) do add(&out, t)
	return out[:]
}
