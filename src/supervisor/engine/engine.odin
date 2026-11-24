// Package engine is the supervisor's activation engine (T13): the operation journal, the
// pointer switch, health probation, automatic rollback, the rollback_failed terminal state,
// the failed-candidate pin and the per-instance lock
// (docs/specs/bridge-supervisor-engine.md §4, §6, §7.5, §7.6, §9, §11, §14).
//
// Phase 1 is dormant (§1): the engine runs only against test roots. It never touches a real
// instance's bin/, service definition, .install.lock or ~/.heimdall-auto-update.lock.
//
// Processes (runtime + PTY host, agents) are behind `Host`, so the same engine code runs in
// the real supervisor and under the fake host of the failure-injection tests. The engine is
// single-threaded and tick-driven: the supervisor's main loop calls `tick` (every ~1 s) and
// `stop` on a service stop; `activate` runs one activation synchronously.
//
// Lifecycle of one supervisor process:
//
//   e, exit := open(cfg, host)              lock, J0 (reap via host, rotation, index, tmp leftovers)
//   exit = start(&e, launched_tree, mode)   §7.6 decision + journal recovery; READY after this
//   loop { exit = tick(&e) }                probation / rollback probation; exit 75 = handover
//   activate(&e, …)                         verified op -> … -> exit 75 (handover)
//   stop(&e)                                §7.5, exit 0
//   close(&e)
//
// Error contract. `start`, `tick`, `activate`, `rollback_to_previous`, `stop`,
// `begin_verified` and `mark_verified` return (Exit, Error). When `fatal(err)` is true the
// supervisor must exit with EXIT_ENGINE_FAILURE (1) at once, never 0, 75 or 78, and must not
// call the engine again: the engine is poisoned and every later call returns the same error.
// A non-fatal error (`busy`, `no_op`, `bad_state`, `not_verified`) is a refused request that
// wrote nothing; the engine keeps running. Exit 1 is how a durable step that failed without
// a crash (fs_busy after the W3 budget, fs_error, journal_torn, stop_timeout) is recovered:
// the journal line of every sub-step is written before its effect and every sub-step is
// idempotent, so the next supervisor start (J0 reap, then §6.3/§7.6) resumes the op exactly
// as after a crash — the launcher restarts on exit 1 and applies the §7.2 fallback rule
// while `current` != `known-good`. Two writes are retried in place instead, because the
// runtime is healthy and an exit would cost a good candidate its probation: the
// `known-good` record and terminal line of `committed` / `rolled_back` (retried on the next
// tick while probation holds; the launcher's T_commit deadline bounds it).
package engine

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "../fetch"

ENGINE_VERSION :: 1

Health :: enum {
	Down, // not started
	Starting, // started, not yet ready
	Ready, // runtime local health = ready (config loaded, PTY host handshake ok)
	Exited, // runtime or PTY host exited / restarted
}

// Host: everything the engine does not do itself.
Host :: struct {
	user:                   rawptr,
	// Wall clock, unix seconds.
	now:                    proc(user: rawptr) -> i64,
	// J0 layer 3: terminate every live procs.json entry; false = a survivor after 20 s.
	reap:                   proc(user: rawptr) -> bool,
	// Start runtime + PTY host from `tree` (always this supervisor's own tree, §2).
	start_runtime:          proc(user: rawptr, tree: string) -> bool,
	// Close admission, stop agents, PTY host and runtime started from `tree`, and wait until
	// every recorded (pid, start_time) has exited (§12 stopping, W7). false = stop_timeout.
	stop_children:          proc(user: rawptr, tree: string) -> bool,
	health:                 proc(user: rawptr) -> Health,
	hub_connected:          proc(user: rawptr) -> bool,
	// Did the running runtime report `connected` within 5 min (§14 hub rule)?
	hub_recently_connected: proc(user: rawptr) -> bool,
	// A service stop arrived while an activation runs (checked between pre-switch steps).
	stop_requested:         proc(user: rawptr) -> bool,
	// User pointer passed to the gate hooks below (gate_count, close/open_admission,
	// end_sessions) so they can come from src/supervisor/runtimectl while the other hooks
	// are the supervisor's own. nil = `user`.
	gate_user:              rawptr,
	// Agent gate (§12, T14), answered by the runtime over the supervisor<->runtime channel
	// (src/supervisor/runtimectl: the runtime's local endpoint, spec §12.2).
	// Fails closed: a nil gate_count is "not counted", which a timer op treats as busy
	// (it waits, then is forced at force_at); user-started ops interrupt regardless.
	// gate_count: live PTY sessions, in-flight launches and helper processes of this
	// instance; `counted` = false when the runtime did not answer (treated as busy).
	gate_count:             proc(user: rawptr) -> Busy,
	// Close / reopen launch admission in the running runtime (in memory; a restarted
	// runtime starts open). false = the runtime did not confirm.
	close_admission:        proc(user: rawptr) -> bool,
	open_admission:         proc(user: rawptr),
	// §12 stopping: ask the runtime to end its sessions (agents and shell sessions get a
	// soft stop and the hub sees them exit) before stop_children's grace and hard stop.
	// Called after `stopping` is journaled, for the activation and the rollback stop.
	// Optional: nil = stop_children alone. Best effort; the result is not checked, because
	// stop_children waits for every recorded process either way.
	end_sessions:           proc(user: rawptr),
}

Mode :: enum {
	Normal,
	Fallback,
}

// Exit tells the supervisor's main loop what to do next.
Exit :: enum {
	Run, // keep running (READY / keep ticking)
	Stop, // exit 0
	Handover, // exit 75
	Refuse, // exit 78
}

// EXIT_ENGINE_FAILURE: the supervisor's exit code for a fatal engine error (see the Error
// contract above). The launcher treats it as a crash (§7.2).
EXIT_ENGINE_FAILURE :: 1

// USAGE_ERRORS: refusals that wrote nothing and leave the engine usable.
USAGE_ERRORS :: []string{"busy", "no_op", "bad_state", "not_verified", "nothing_to_cancel", "op_mismatch", "past_point_of_no_return"}

// fatal: a non-nil error the supervisor must exit 1 on (Error contract).
fatal :: proc(err: Error) -> bool {
	f, ok := err.?
	if !ok do return false
	for c in USAGE_ERRORS do if f.code == c do return false
	return true
}

// retryable_write: a write that failed without a crash and left nothing half done.
@(private)
retryable_write :: proc(err: Error) -> bool {
	c := error_code(err)
	return c == "fs_error" || c == "fs_busy"
}

// poison records a fatal error; every later engine call returns it (Error contract).
@(private)
poison :: proc(e: ^Engine, err: Error) {
	if e.failed != nil || !fatal(err) do return
	f := err.?
	e.failed = Failure{strings.clone(f.code, e.alloc), strings.clone(f.detail, e.alloc)}
	e.phase = .Offline
}

exit_code :: proc(x: Exit) -> int {
	switch x {
	case .Run:
		return -1
	case .Stop:
		return 0
	case .Handover:
		return 75
	case .Refuse:
		return 78
	}
	return -1
}

Phase :: enum {
	Idle, // runtime running from the launched tree, no probation
	Probation, // probation of the active op's `to`
	Rollback_Probation, // probation of `from` after a rollback
	Rollback_Failed, // terminal; runtime restarts stopped, only repair-type intents accepted
	Offline, // runtime not started (refused, handed over, stopped)
}

Config :: struct {
	instance_root:        string, // <data>
	state_root:           string, // <state>
	retry:                Retry_Policy,
	ready_timeout_s:      i64, // runtime ready after start (60)
	probation_s:          i64, // healthy after ready (120)
	max_unclean_attempts: int, // 3
	state_stores:         []State_Store,
	gate_wait_s:          i64, // agent gate: longest wait of a timer op for idle agents (7200, §12)
}

default_config :: proc(instance_root, state_root: string) -> Config {
	return Config {
		instance_root = instance_root,
		state_root = state_root,
		retry = DEFAULT_RETRY,
		ready_timeout_s = 60,
		probation_s = 120,
		max_unclean_attempts = 3,
		state_stores = DEFAULT_STATE_STORES,
		gate_wait_s = GATE_WAIT_S,
	}
}

Engine :: struct {
	cfg:            Config,
	host:           Host,
	inj:            ^Injector,
	arena:          virtual.Arena,
	alloc:          mem.Allocator,
	lock:           Lock,
	launched:       string,
	mode:           Mode,
	last_seq:       i64,
	active:         Maybe(Line), // last line of the active op
	phase:          Phase,
	// Probation bookkeeping (in memory; a restart restarts the window, J16).
	runtime_tree:   string,
	started_at:     i64,
	ready_at:       i64,
	hub_seen:       bool,
	refuse_reason:  string,
	// Last terminal line in the journal (sticky rollback_failed, adopt without a target).
	last_terminal:  Maybe(Line), // for the J30 carry (gate.odin interrupt_pending)
	// Last line that settled what the instance runs (committed, rolled_back,
	// rollback_failed, failed adopt): the only line J25 stickiness and the adopt rule read.
	last_settled:   Maybe(Line),
	// committed / rolled_back failed with a retryable write; retried on the next tick.
	finish_pending: bool,
	// First fatal error (Error contract); non-nil = poisoned.
	failed:         Error,
	// Agent gate: latest count while an op waits for idle (status only, not journaled).
	gate_busy:      Busy,
	// Agent gate: what the waiting status file last showed (write throttle, gate.odin).
	gate_shown:     Gate_Shown,
	// Last line of every op whose last line is not terminal (normally 0-2), kept in memory
	// so the running supervisor never re-parses the journal per tick (T13b review). Built
	// at load, updated by `journal`; entries (heap clones in `heap`) are removed when the
	// op's terminal line is written.
	open_ops:       map[string]Line,
	heap:           mem.Allocator,
}

now :: proc(e: ^Engine) -> i64 {
	return e.host.now(e.host.user)
}

@(private)
sup_dir :: proc(e: ^Engine, parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, e.cfg.instance_root, "supervisor")
	append(&all, ..parts)
	return join(..all[:])
}

@(private)
journal_path :: proc(e: ^Engine) -> string {
	return sup_dir(e, JOURNAL_DIR, JOURNAL_FILE)
}

@(private)
clone_line :: proc(e: ^Engine, l: Line) -> Line {
	c := l
	c.op_id = strings.clone(l.op_id, e.alloc)
	c.action = strings.clone(l.action, e.alloc)
	c.actor = strings.clone(l.actor, e.alloc)
	c.state = strings.clone(l.state, e.alloc)
	c.sub = strings.clone(l.sub, e.alloc)
	c.error = strings.clone(l.error, e.alloc)
	c.note = strings.clone(l.note, e.alloc)
	c.interrupted_by = strings.clone(l.interrupted_by, e.alloc)
	c.cancelled_by = strings.clone(l.cancelled_by, e.alloc)
	c.from = Ref{strings.clone(l.from.version, e.alloc), strings.clone(l.from.sha256, e.alloc), strings.clone(l.from.tree, e.alloc)}
	c.to = Ref{strings.clone(l.to.version, e.alloc), strings.clone(l.to.sha256, e.alloc), strings.clone(l.to.tree, e.alloc)}
	return c
}

// journal: append one line (write-ahead), then for a terminal line update the op index.
journal :: proc(e: ^Engine, l: Line) -> Error {
	line := l
	line.js = JOURNAL_SCHEMA
	line.seq = e.last_seq + 1
	line.ts = now(e)
	if err := append_durable(e.inj, journal_path(e), encode_line(line)); err != nil do return err
	e.last_seq = line.seq
	if is_terminal(line.state) {
		// A terminal line of another op (J30 `noop superseded_by`) leaves the active op alone.
		if a, has := e.active.?; !has || a.op_id == line.op_id do e.active = nil
		if decides_state(line) do e.last_terminal = clone_line(e, line)
		if settles(line) do e.last_settled = clone_line(e, line)
		// The index is reconciled from the journal at every start (§6.1), so only a crash
		// stops here; a failed index write (e.g. fs_busy) does not undo a durable result.
		if err := index_add(e, line.op_id, line.state, line.ts); err != nil && is_crash(err) do return err
	} else if a, has := e.active.?; !has || a.op_id == line.op_id {
		e.active = clone_line(e, line)
	}
	open_ops_note(e, line)
	// A non-terminal line of another op (a short side op of §10 coalescing, e.g. check_now or
	// set_channel while an update waits for idle agents) leaves the active op alone too; the
	// caller restores the view with `reload_active` once the side op is terminal.
	write_status(e, line)
	return nil
}

// reload_active sets the active op from the open ops (§6.1: the last op whose last line is
// not terminal; see pick_active). The service calls it after a side op (§10 coalescing) ends.
reload_active :: proc(e: ^Engine) {
	e.active = nil
	if op, ok := pick_active(non_terminal_ops(e)); ok do e.active = clone_line(e, op)
}

// decides_state: may this terminal line be `last_terminal`, the line start() reads to keep
// J25 rollback_failed sticky (and an adopt without a target settled) and gate.odin reads for
// the J30 carry? Only an installing op that did something: side ops (check_now, set_channel,
// cancel, …) and lines of ops that changed nothing — `rejected` (J31, including the
// `rejected rollback_failed` answer itself), `noop` (J30 superseded, up to date, pinned),
// `expired`, `cancelled` (J35, `busy`) — never end or replace that state (T13b safety review).
decides_state :: proc(l: Line) -> bool {
	if is_side_action(l.action) do return false
	switch l.state {
	case "rejected", "noop", "expired", "cancelled":
		return false
	}
	return true
}

// settles: a terminal line that decided what the instance runs. Only these keep or end J25
// rollback_failed and the adopt-without-target rule. An op that ended before the switch —
// `failed` (download_failed, interrupted_before_switch, stop_timeout, …), `noop`,
// `cancelled`, `expired`, `rejected` — and every side op changed nothing, so a repair or
// install_version that fails while in rollback_failed leaves the instance in it (T13b
// safety review round 3).
settles :: proc(l: Line) -> bool {
	if is_side_action(l.action) do return false
	switch l.state {
	case "committed", "rolled_back", "rollback_failed":
		return true
	case "failed":
		return l.action == "adopt" // a failed adopt probation settled on running `to`
	}
	return false
}

// sticky_failed: J25 — the last settled line is rollback_failed naming the launched tree.
// While it holds, no runtime is started (run_idle and the pre-switch failure paths return
// to Rollback_Failed instead).
sticky_failed :: proc(e: ^Engine) -> bool {
	lt, ok := e.last_settled.?
	return ok && lt.state == "rollback_failed" && e.launched != "" && (lt.from.tree == e.launched || lt.to.tree == e.launched)
}

// SIDE_ACTIONS: ops that never install and may run beside an active op (§10 coalescing).
SIDE_ACTIONS :: []string{"check_now", "set_channel", "set_auto_update", "retry_failed", "cancel"}

is_side_action :: proc(action: string) -> bool {
	for a in SIDE_ACTIONS do if a == action do return true
	return false
}

// pick_active: among the last lines of non-terminal ops, the latest one — except that a side
// op left non-terminal by a crash never shadows an installing op beside it (the service
// finishes the side op separately, see service.drive).
@(private)
pick_active :: proc(open: []Line) -> (op: Line, ok: bool) {
	best_main, best_side: Maybe(Line)
	for l in open {
		if is_side_action(l.action) {
			if b, has := best_side.?; !has || l.seq > b.seq do best_side = l
		} else if b, has := best_main.?; !has || l.seq > b.seq {
			best_main = l
		}
	}
	if b, has := best_main.?; has do return b, true
	if b, has := best_side.?; has do return b, true
	return
}

// open_lines: the last line of every op whose last line is not terminal, oldest first; one
// pass with a map from op_id to its last line index (O(n)).
@(private)
open_lines :: proc(lines: []Line, allocator := context.temp_allocator) -> []Line {
	last := make(map[string]int, 16, context.temp_allocator)
	for l, i in lines do last[l.op_id] = i
	out := make([dynamic]Line, allocator)
	for l, i in lines {
		if last[l.op_id] == i && !is_terminal(l.state) do append(&out, l)
	}
	return out[:]
}

// non_terminal_ops: the open ops from memory (no file read), oldest first (by seq).
non_terminal_ops :: proc(e: ^Engine, allocator := context.temp_allocator) -> []Line {
	out := make([dynamic]Line, 0, len(e.open_ops), allocator)
	for _, l in e.open_ops do append(&out, l)
	slice.sort_by(out[:], proc(a, b: Line) -> bool {return a.seq < b.seq})
	return out[:]
}

// is_open: the op has a line and is not terminal.
is_open :: proc(e: ^Engine, op_id: string) -> bool {
	return op_id in e.open_ops
}

// journal_lines: every valid line of ops.jsonl (temp-allocated). Reads the file: only for
// rare replay checks (J35 `cancelled_by` after a crash), never per tick.
journal_lines :: proc(e: ^Engine) -> []Line {
	r := read_journal_file(journal_path(e), context.temp_allocator)
	return r.lines[:]
}

// open_ops_note keeps `open_ops` current after `l` was journaled.
@(private)
open_ops_note :: proc(e: ^Engine, l: Line) {
	if old, ok := e.open_ops[l.op_id]; ok {
		delete_key(&e.open_ops, l.op_id)
		free_heap_line(e, old)
	}
	if is_terminal(l.state) do return
	c := clone_heap_line(e, l)
	e.open_ops[c.op_id] = c
}

@(private)
open_ops_reset :: proc(e: ^Engine) {
	for _, l in e.open_ops do free_heap_line(e, l)
	clear(&e.open_ops)
}

@(private)
clone_heap_line :: proc(e: ^Engine, l: Line) -> Line {
	a := e.heap
	c := l
	c.op_id = strings.clone(l.op_id, a)
	c.action = strings.clone(l.action, a)
	c.actor = strings.clone(l.actor, a)
	c.state = strings.clone(l.state, a)
	c.sub = strings.clone(l.sub, a)
	c.error = strings.clone(l.error, a)
	c.note = strings.clone(l.note, a)
	c.interrupted_by = strings.clone(l.interrupted_by, a)
	c.cancelled_by = strings.clone(l.cancelled_by, a)
	c.from = Ref{strings.clone(l.from.version, a), strings.clone(l.from.sha256, a), strings.clone(l.from.tree, a)}
	c.to = Ref{strings.clone(l.to.version, a), strings.clone(l.to.sha256, a), strings.clone(l.to.tree, a)}
	return c
}

@(private)
free_heap_line :: proc(e: ^Engine, l: Line) {
	a := e.heap
	for s in ([]string{l.op_id, l.action, l.actor, l.state, l.sub, l.error, l.note, l.interrupted_by, l.cancelled_by, l.from.version, l.from.sha256, l.from.tree, l.to.version, l.to.sha256, l.to.tree}) {
		delete(s, a)
	}
}

@(private)
index_add :: proc(e: ^Engine, op_id, state: string, at: i64) -> Error {
	path := sup_dir(e, JOURNAL_DIR, OP_INDEX_FILE)
	idx, _ := read_op_index(path, context.temp_allocator)
	if cur, ok := idx[op_id]; ok && cur.state == state do return nil
	idx[op_id] = Index_Entry{state, at}
	prune_index(&idx, now(e))
	data := encode_op_index(idx)
	return replace_durable(e.inj, e.cfg.retry, path, transmute([]byte)data, op_id, PRIVATE_FILE_PERMS)
}

@(private)
prune_index :: proc(idx: ^map[string]Index_Entry, now_s: i64) {
	old := make([dynamic]string, context.temp_allocator)
	for k, v in idx do if now_s - v.at > INDEX_HORIZON_S do append(&old, k)
	for k in old do delete_key(idx, k)
}

// write_status: <state>/supervisor-status.json (diagnostics, §3). Best effort, not a
// durable step: the journal is the authority.
@(private)
write_status :: proc(e: ^Engine, l: Line) {
	if crashed(e.inj) || e.cfg.state_root == "" || !os.is_directory(e.cfg.state_root) do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"engine":%d,"phase":"%v","tree":`, ENGINE_VERSION, e.phase)
	write_json_string(&b, e.launched)
	strings.write_string(&b, `,"op_id":`)
	write_json_string(&b, l.op_id)
	strings.write_string(&b, `,"state":`)
	write_json_string(&b, l.state)
	strings.write_string(&b, `,"sub":`)
	write_opt_string(&b, l.sub)
	strings.write_string(&b, `,"error":`)
	write_opt_string(&b, l.error)
	write_gate_status(e, &b, l)
	fmt.sbprintf(&b, `,"at":%d}}`, l.ts)
	strings.write_byte(&b, '\n')
	path := join(e.cfg.state_root, "supervisor-status.json")
	tmp := fmt.tprintf("%s.tmp", path)
	if write_new_synced(tmp, transmute([]byte)strings.to_string(b), PRIVATE_FILE_PERMS) == nil {
		platform_replace(tmp, path)
	}
}

// ---------------------------------------------------------------------------------------
// open: lock + J0
// ---------------------------------------------------------------------------------------

// open takes the instance lock and runs J0 (§6.3): orphan reap through the host, finish an
// interrupted rotation (J33), torn-tail truncation / corrupt journal (§16), op index
// reconcile, *.tmp-* leftovers. Returns .Refuse (78) when the lock is held or an orphan
// survives; `e.refuse_reason` says which.
open :: proc(e: ^Engine, cfg: Config, host: Host, inj: ^Injector = nil) -> Exit {
	e^ = {}
	e.cfg = cfg
	if e.cfg.retry.budget_ms == 0 && e.cfg.retry.first_ms == 0 do e.cfg.retry = DEFAULT_RETRY
	if e.cfg.ready_timeout_s == 0 do e.cfg.ready_timeout_s = 60
	if e.cfg.probation_s == 0 do e.cfg.probation_s = 120
	if e.cfg.max_unclean_attempts == 0 do e.cfg.max_unclean_attempts = 3
	if e.cfg.gate_wait_s == 0 do e.cfg.gate_wait_s = GATE_WAIT_S
	e.host = host
	e.inj = inj
	e.heap = context.allocator // open_ops allocates on first insert (nothing to free on refusal before it)
	_ = virtual.arena_init_growing(&e.arena)
	e.alloc = virtual.arena_allocator(&e.arena)
	e.cfg.instance_root = strings.clone(cfg.instance_root, e.alloc)
	e.cfg.state_root = strings.clone(cfg.state_root, e.alloc)
	e.phase = .Offline

	for d in ([]string{sup_dir(e), sup_dir(e, JOURNAL_DIR)}) {
		if !os.is_directory(d) {
			if err := make_dir_durable(e.inj, d); err != nil {
				e.refuse_reason = strings.clone(error_code(err), e.alloc)
				return .Refuse
			}
		}
	}
	l, lerr := lock_acquire(sup_dir(e, "engine.lock"))
	if lerr != nil {
		e.refuse_reason = "lock_held"
		return .Refuse
	}
	e.lock = l
	if e.host.reap != nil && !e.host.reap(e.host.user) {
		e.refuse_reason = "orphan_unkillable"
		return .Refuse
	}
	if err := recover_rotation(e); err != nil {
		e.refuse_reason = strings.clone(error_code(err), e.alloc)
		return .Refuse
	}
	if err := load_journal(e); err != nil {
		e.refuse_reason = strings.clone(error_code(err), e.alloc)
		return .Refuse
	}
	if err := remove_tmp_leftovers(e); err != nil {
		e.refuse_reason = strings.clone(error_code(err), e.alloc)
		return .Refuse
	}
	return .Run
}

close :: proc(e: ^Engine) {
	open_ops_reset(e)
	delete(e.open_ops)
	lock_release(&e.lock)
	virtual.arena_destroy(&e.arena)
}

// J33: ops.jsonl missing and .new present -> finish step 3; both present -> delete .new.
@(private)
recover_rotation :: proc(e: ^Engine) -> Error {
	cur := journal_path(e)
	nw := sup_dir(e, JOURNAL_DIR, JOURNAL_NEW)
	if !os.exists(nw) do return nil
	if !os.exists(cur) do return rename_durable(e.inj, e.cfg.retry, nw, cur)
	return remove_durable(e.inj, nw)
}

@(private)
load_journal :: proc(e: ^Engine) -> Error {
	path := journal_path(e)
	r := read_journal_file(path, context.temp_allocator)
	switch r.status {
	case .Missing, .Ok:
	case .Torn_Tail:
		if err := truncate_durable(e.inj, path, r.valid_bytes); err != nil do return err
	case .Corrupt:
		// §16: keep the evidence, start a new journal with a failed journal_corrupt line.
		ts := now(e)
		if err := rename_durable(e.inj, e.cfg.retry, path, sup_dir(e, JOURNAL_DIR, fmt.tprintf("ops.corrupt-%d.jsonl", ts))); err != nil do return err
		for l in r.lines do e.last_seq = max(e.last_seq, l.seq)
		clear(&r.lines)
		if err := journal(e, Line{op_id = fmt.tprintf("op_journal_corrupt_%d", ts), action = "journal", actor = "supervisor", state = "failed", error = "journal_corrupt"}); err != nil do return err
	}
	for l in r.lines do e.last_seq = max(e.last_seq, l.seq)
	open_ops_reset(e)
	for l in open_lines(r.lines[:]) do open_ops_note(e, l)
	if op, ok := pick_active(non_terminal_ops(e)); ok do e.active = clone_line(e, op)
	last_t, last_s: i64 = -1, -1
	for l in r.lines {
		if is_terminal(l.state) && decides_state(l) && l.seq > last_t {
			last_t = l.seq
			e.last_terminal = clone_line(e, l)
		}
		if is_terminal(l.state) && settles(l) && l.seq > last_s {
			last_s = l.seq
			e.last_settled = clone_line(e, l)
		}
	}
	if err := reconcile_index(e, r.lines[:]); err != nil do return err
	return maybe_rotate(e, r.lines[:], r.valid_bytes)
}

// reconcile_index: every terminal line within 31 days is in op-index.json (§6.1).
@(private)
reconcile_index :: proc(e: ^Engine, lines: []Line) -> Error {
	path := sup_dir(e, JOURNAL_DIR, OP_INDEX_FILE)
	idx, _ := read_op_index(path, context.temp_allocator)
	changed := false
	rotated := read_journal_file(sup_dir(e, JOURNAL_DIR, JOURNAL_ROTATED), context.temp_allocator)
	t := now(e)
	for set in ([][]Line{rotated.lines[:], lines}) {
		for l in set {
			if !is_terminal(l.state) || t - l.ts > INDEX_HORIZON_S do continue
			if cur, ok := idx[l.op_id]; ok && cur.state == l.state do continue
			idx[l.op_id] = Index_Entry{l.state, l.ts}
			changed = true
		}
	}
	before := len(idx)
	prune_index(&idx, t)
	if len(idx) != before do changed = true
	if !changed do return nil
	data := encode_op_index(idx)
	return replace_durable(e.inj, e.cfg.retry, path, transmute([]byte)data, "reconcile", PRIVATE_FILE_PERMS)
}

// maybe_rotate: §6.1 rotation when ops.jsonl > 1 MiB and no op is active.
@(private)
maybe_rotate :: proc(e: ^Engine, lines: []Line, size: i64) -> Error {
	if size <= ROTATE_BYTES || e.active != nil do return nil
	t := now(e)
	// Final line of every op terminal within 31 days, at least the last 50 ops.
	finals := make([dynamic]Line, context.temp_allocator)
	for l, i in lines {
		if !is_terminal(l.state) do continue
		last := true
		for j := i + 1; j < len(lines); j += 1 do if lines[j].op_id == l.op_id {last = false; break}
		if last do append(&finals, l)
	}
	keep_from := len(finals)
	for i := len(finals) - 1; i >= 0; i -= 1 {
		if t - finals[i].ts <= INDEX_HORIZON_S || len(finals) - i <= ROTATE_KEEP_MIN do keep_from = i
	}
	b := strings.builder_make(context.temp_allocator)
	for l in finals[keep_from:] do strings.write_string(&b, encode_line(l))
	nw := sup_dir(e, JOURNAL_DIR, JOURNAL_NEW)
	if err := write_file_durable(e.inj, nw, transmute([]byte)strings.to_string(b)); err != nil do return err
	if err := rename_durable(e.inj, e.cfg.retry, journal_path(e), sup_dir(e, JOURNAL_DIR, JOURNAL_ROTATED)); err != nil do return err
	return rename_durable(e.inj, e.cfg.retry, nw, journal_path(e))
}

// J0: delete *.tmp-* leftovers of interrupted pointer / record writes.
@(private)
remove_tmp_leftovers :: proc(e: ^Engine) -> Error {
	for dir in ([]string{e.cfg.instance_root, sup_dir(e), sup_dir(e, JOURNAL_DIR)}) {
		entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil do continue
		for ent in entries {
			if strings.contains(ent.name, ".tmp-") {
				if rerr := remove_durable(e.inj, join(dir, ent.name)); rerr != nil do return rerr
			}
		}
	}
	// Interrupted snapshot restores (J22) under <state>; only our own temp names.
	if e.cfg.state_root != "" {
		entries, err := os.read_directory_by_path(e.cfg.state_root, -1, context.temp_allocator)
		if err == nil {
			for ent in entries {
				if strings.contains(ent.name, ".tmp-restore-") {
					if rerr := remove_durable(e.inj, join(e.cfg.state_root, ent.name)); rerr != nil do return rerr
				}
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------------------
// start: §7.6 decision + recovery (J10–J25, J32)
// ---------------------------------------------------------------------------------------

POST_SWITCH_SUBS :: []string{"pointers_done", "handover"}

// start decides, after J0 and the journal read and before READY, what this supervisor
// launch does (§7.6), resolves the active op (§6.3) and starts the runtime where the
// result is to run. Returns .Run (send READY, then tick), .Handover (exit 75 without
// READY) or .Refuse.
start :: proc(e: ^Engine, launched: string, mode: Mode) -> (x: Exit, err: Error) {
	if e.failed != nil do return .Run, e.failed
	defer poison(e, err)
	e.launched = strings.clone(launched, e.alloc)
	e.mode = mode
	L := launched
	C := current_valid(e)
	K := known_good_valid(e)

	if !tree_is_valid(e, L) {
		e.refuse_reason = "launched_tree_invalid"
		return .Refuse, nil
	}

	// Torn / invalid `current` (J14): the launcher started `previous` (fallback) or `K`.
	if C == "" {
		if op, ok := e.active.?; ok && (op.state == "activating" || op.state == "probation" || op.state == "rolling_back") && op.from.tree == L {
			if op.state == "activating" {
				// The switch never produced a valid `current`: not past the point of no return.
				if err = write_pointer(e, POINTER_CURRENT, L, op.op_id); err != nil do return
				if err = journal(e, terminal_of(op, "failed", "pointer_write")); err != nil do return
				return run_idle(e)
			}
			return run_rollback(e, op, op.error if op.state == "rolling_back" else "current_invalid", Ref{})
		}
		// No operation explains it: point `current` back at the tree we were started on.
		if mode == .Fallback || L == K || K == "" {
			if err = write_pointer(e, POINTER_CURRENT, L, "op_recover_current"); err != nil do return
			C = L
		} else {
			return .Handover, nil
		}
	}

	if mode == .Fallback && C != L {
		if C == K do return .Handover, nil // committed before the launcher gave up (J17)
		if op, ok := e.active.?; ok && op.to.tree == C && op_past_switch(op) {
			from := op.from
			note := ""
			if from.tree != L {
				note = "from_mismatch"
				from, _ = ref_of_tree(e, L)
			}
			reason := op.error if op.state == "rolling_back" && op.error != "" else "launcher_fallback"
			return run_rollback(e, op, reason, from, note)
		}
		// No active op naming C (journal lost, fresh install): synthetic rollback (§7.6).
		if op, ok := e.active.?; ok {
			if err = journal(e, terminal_of(op, "failed", "interrupted_before_switch")); err != nil do return
		}
		to_ref, _ := ref_of_tree(e, C)
		from_ref, _ := ref_of_tree(e, L)
		syn := Line {
			op_id  = fmt.tprintf("op_fallback_%d_%d", now(e), e.last_seq + 1),
			action = "rollback_to_previous",
			actor  = "supervisor",
			state  = "rolling_back",
			sub    = "stopping",
			from   = from_ref,
			to     = to_ref,
			error  = "launcher_fallback",
		}
		return run_rollback(e, syn, "launcher_fallback", from_ref, "", true)
	}

	if mode == .Normal && L != C do return .Handover, nil

	// From here L == C.
	op, has_op := e.active.?
	// A side op (check_now, set_channel, …) left by a crash decides nothing here; the
	// service finishes it after READY.
	if has_op && is_side_action(op.action) {
		has_op = false
		e.active = nil
	}
	if !has_op {
		lt, has_lt := e.last_settled.?
		if has_lt && lt.state == "rollback_failed" && (lt.from.tree == C || lt.to.tree == C) {
			// J25 is sticky: the last op that names `current` ended rollback_failed and no op
			// came after it, so runtime restarts stay stopped across supervisor restarts and
			// reboots until a repair-type intent starts a new op.
			e.phase = .Rollback_Failed
			write_status(e, lt)
			return .Run, nil
		}
		if K != C {
			if has_lt && lt.action == "adopt" && lt.state == "failed" && lt.to.tree == C && strings.contains(lt.note, "no_rollback_target") {
				// This tree already failed an adopt probation with nothing to roll back to:
				// run it (it is the only installed release) without probing it again.
				return run_idle(e)
			}
			// No journal entry explains an unproven `current` (journal lost, or a fresh
			// install that wrote no op): prove it like a candidate; rollback target is
			// `previous` (or K). With no valid target other than C the probation only decides
			// whether C becomes known-good; a failure never stops or pins it (run_rollback).
			from_tree := K if K != "" else previous_valid(e)
			if from_tree == C do from_tree = ""
			from_ref, _ := ref_of_tree(e, from_tree)
			to_ref, _ := ref_of_tree(e, C)
			adopt := Line {
				op_id             = fmt.tprintf("op_adopt_%d_%d", now(e), e.last_seq + 1),
				action            = "adopt",
				actor             = "supervisor",
				state             = "probation",
				sub               = "probation",
				from              = from_ref,
				to                = to_ref,
				probation_attempt = 1,
			}
			if err = journal(e, adopt); err != nil do return
			return run_probation(e)
		}
		return run_idle(e)
	}

	switch op.state {
	case "activating":
		if C == op.to.tree {
			// J14/J15/J15a: the switch landed; this is the candidate's first start.
			if op.action == "rollback_to_previous" {
				if err = pin_user_rollback(e, op); err != nil do return
			}
			if K == op.to.tree {
				return commit(e, op)
			}
			next := op
			next.state = "probation"
			next.sub = "probation"
			next.probation_attempt = 1
			next.error = ""
			if err = journal(e, next); err != nil do return
			return run_probation(e)
		}
		// J10–J13: not past the point of no return.
		if err = drop_incomplete_snapshot(e, op.op_id); err != nil do return
		if err = journal(e, terminal_of(op, "failed", "interrupted_before_switch")); err != nil do return
		return run_idle(e)
	case "probation":
		if K == op.to.tree do return commit(e, op) // J17: known-good landed, line missing
		if C != op.to.tree {
			return run_rollback(e, op, "current_reverted", Ref{})
		}
		attempt := op.probation_attempt
		if op.sub != "probation_suspended" do attempt += 1 // J16 vs J16a
		if attempt > e.cfg.max_unclean_attempts {
			return run_rollback(e, op, "probation_interrupted", Ref{})
		}
		next := op
		next.sub = "probation"
		next.probation_attempt = attempt
		if err = journal(e, next); err != nil do return
		return run_probation(e)
	case "rolling_back":
		return run_rollback(e, op, op.error, Ref{})
	}
	// Pre-activation states (requested … waiting_for_idle): nothing to undo (J3–J9). The
	// caller resumes or re-drives the op; the installed version runs meanwhile.
	return run_idle(e)
}

@(private)
op_past_switch :: proc(op: Line) -> bool {
	switch op.state {
	case "probation", "rolling_back":
		return true
	case "activating":
		return op.sub == "pointers_begin" || op.sub == "pointers_done" || op.sub == "handover"
	}
	return false
}

current_valid :: proc(e: ^Engine) -> string {
	t := read_pointer_raw(e, POINTER_CURRENT)
	return t if tree_is_valid(e, t) else ""
}

previous_valid :: proc(e: ^Engine) -> string {
	t := read_pointer_raw(e, POINTER_PREVIOUS)
	return t if tree_is_valid(e, t) else ""
}

known_good_valid :: proc(e: ^Engine) -> string {
	t := read_known_good_raw(e)
	return t if tree_is_valid(e, t) else ""
}

@(private)
terminal_of :: proc(op: Line, state, err: string, note := "") -> Line {
	t := op
	t.state = state
	t.sub = ""
	t.error = err
	t.note = note
	return t
}

@(private)
drop_incomplete_snapshot :: proc(e: ^Engine, op_id: string) -> Error {
	dir := snapshot_dir(e, op_id)
	if os.exists(dir) && !os.exists(join(dir, SNAPSHOT_JSON)) do return remove_durable(e.inj, dir)
	return nil
}

@(private)
start_runtime :: proc(e: ^Engine, tree: string) -> bool {
	if crashed(e.inj) do return false
	e.runtime_tree = strings.clone(tree, e.alloc)
	e.started_at = now(e)
	e.ready_at = 0
	e.hub_seen = false
	return e.host.start_runtime(e.host.user, tree)
}

@(private)
run_idle :: proc(e: ^Engine) -> (Exit, Error) {
	if sticky_failed(e) {
		// J25: an op that ended before the switch (or a start that resumed one) never
		// starts the tree whose rollback failed.
		e.phase = .Rollback_Failed
		if lt, ok := e.last_settled.?; ok do write_status(e, lt)
		return .Run, nil
	}
	e.phase = .Idle
	start_runtime(e, e.launched)
	return .Run, nil
}

@(private)
run_probation :: proc(e: ^Engine) -> (Exit, Error) {
	op, _ := e.active.?
	e.phase = .Probation if op.state == "probation" else .Rollback_Probation
	start_runtime(e, e.launched)
	return .Run, nil
}

// ---------------------------------------------------------------------------------------
// activation (verified -> activating -> handover), §4.3, §6.2, J10–J15, J28
// ---------------------------------------------------------------------------------------

Activation :: struct {
	op_id:  string,
	action: string, // update_now, install_version, repair, rollback_to_previous, timer op …
	actor:  string,
	to:     Ref, // verified tree (fetch.prepare_release result, or `previous` for J28)
}

// begin_verified journals `requested` and `verified` for an op whose tree is already
// prepared (the resolve/download/verify part of the diagram is T11/T12's code, driven by
// the caller). Used by tests and by rollback_to_previous.
begin_verified :: proc(e: ^Engine, a: Activation) -> (err: Error) {
	if e.failed != nil do return e.failed
	defer poison(e, err)
	if _, busy := e.active.?; busy do return fail("busy", "an operation is active")
	base := Line{op_id = a.op_id, action = a.action, actor = a.actor}
	l := base
	l.state = "requested"
	if err = journal(e, l); err != nil do return
	l.state = "verified"
	l.to = a.to
	return journal(e, l)
}

// mark_verified journals `verified` for the active op once its tree is prepared (the
// orchestrator resumes an op left in requested … verifying after a restart this way).
mark_verified :: proc(e: ^Engine, to: Ref) -> (err: Error) {
	if e.failed != nil do return e.failed
	defer poison(e, err)
	op, ok := e.active.?
	if !ok do return fail("no_op", "no active operation")
	if is_terminal(op.state) || op.state == "activating" || op.state == "probation" || op.state == "rolling_back" {
		return fail("bad_state", "operation is %s", op.state)
	}
	l := op
	l.state = "verified"
	l.sub = ""
	l.to = to
	return journal(e, l)
}

// rollback_to_previous (J28): requested -> verifying -> verified (read-only local check of
// `previous`), then the normal activation with to = previous.
rollback_to_previous :: proc(e: ^Engine, op_id, actor: string) -> (x: Exit, err: Error) {
	if e.failed != nil do return .Run, e.failed
	defer poison(e, err)
	if _, busy := e.active.?; busy do return .Run, fail("busy", "an operation is active")
	base := Line{op_id = op_id, action = "rollback_to_previous", actor = actor}
	l := base
	l.state = "requested"
	if err = journal(e, l); err != nil do return
	l.state = "verifying"
	if err = journal(e, l); err != nil do return
	P := previous_valid(e)
	C := current_valid(e)
	if P == "" || P == C {
		err = journal(e, terminal_of(l, "failed", "no_previous"))
		return .Run, err
	}
	if !tree_sizes_match(e, P) {
		err = journal(e, terminal_of(l, "failed", "tree_damaged"))
		return .Run, err
	}
	to, _ := ref_of_tree(e, P)
	l.state = "verified"
	l.to = to
	if err = journal(e, l); err != nil do return
	return activate(e)
}

// activate runs the active `verified` (or `waiting_for_idle`) op through the agent gate
// (§12, gate.odin) and `activating` up to the handover (exit 75). A timer op whose agents
// are busy is journaled `waiting_for_idle` and returns .Run; `tick` re-evaluates it. Errors
// before the `current` switch end the op `failed <code>` with the installed version
// running; an error after it starts the rollback.
activate :: proc(e: ^Engine) -> (x: Exit, err: Error) {
	if e.failed != nil do return .Run, e.failed
	defer poison(e, err)
	op, ok := e.active.?
	if !ok || (op.state != "verified" && op.state != "waiting_for_idle") {
		return .Run, fail("not_verified", "no verified operation to activate")
	}
	cur, rule, done, px, perr := precheck(e, op)
	if done do return px, perr
	return gate(e, cur, rule)
}

// precheck: the refusals that end an op before the gate (§11.3 "before the gate"). Re-run
// at every gate evaluation, so a wait never outlives a changed `current`. `done` = the op
// ended (terminal line written) or failed to.
@(private)
precheck :: proc(e: ^Engine, op: Line) -> (cur: Line, rule: Schema_Rule, done: bool, x: Exit, err: Error) {
	F := e.launched
	done = true
	if current_valid(e) != F {
		err = journal(e, terminal_of(op, "failed", "current_changed"))
		return
	}
	if op.to.tree == F {
		err = journal(e, terminal_of(op, "noop", ""))
		return
	}
	if !tree_is_valid(e, op.to.tree) {
		err = journal(e, terminal_of(op, "failed", "tree_invalid"))
		return
	}
	from, _ := ref_of_tree(e, F)
	fs := tree_schemas(e, F)
	ts := tree_schemas(e, op.to.tree)
	rule = schema_rule(fs, ts)
	if rule == .Refuse {
		err = journal(e, terminal_of(op, "failed", "state_schema_incompatible"))
		return
	}
	if abs(ts.journal_schema - fs.journal_schema) > 1 {
		err = journal(e, terminal_of(op, "failed", "journal_schema_gap"))
		return
	}
	cur = op
	cur.from = from
	cur.error = ""
	return cur, rule, false, .Run, nil
}

// activate_steps: `activating` from `gate_closed` (journaled here, with the gate's fields
// in `cur`) to the handover. Admission is already closed (gate.odin).
@(private)
activate_steps :: proc(e: ^Engine, op: Line, rule: Schema_Rule, superseded: Line = {}) -> (x: Exit, err: Error) {
	F := e.launched
	cur := op
	cur.state = "activating"
	cur.hub = e.host.hub_recently_connected != nil && e.host.hub_recently_connected(e.host.user)

	step :: proc(e: ^Engine, cur: ^Line, sub: string) -> Error {
		cur.sub = sub
		return journal(e, cur^)
	}
	before_switch_fail :: proc(e: ^Engine, cur: Line, code: string, children_stopped: bool) -> (Exit, Error) {
		if err := journal(e, terminal_of(cur, "failed", code)); err != nil do return .Run, err
		if crashed(e.inj) do return .Run, crash_error("after failed")
		if sticky_failed(e) {
			// J25: in rollback_failed nothing ran before this attempt; nothing runs after it.
			e.phase = .Rollback_Failed
			return .Run, nil
		}
		if !children_stopped {
			// The runtime still runs (nothing was stopped): reopen its launch admission
			// instead of starting a second runtime next to it.
			gate_open_admission(e)
			e.phase = .Idle
			return .Run, nil
		}
		// The installed version is restarted as normal (W7 stopped it).
		return run_idle(e)
	}

	if err = step(e, &cur, "gate_closed"); err != nil do return
	if superseded.op_id != "" {
		// J30: the update_now that ended the wait is answered by this op.
		if err = journal(e, superseded); err != nil do return
	}
	if stop_req(e) do return before_switch_fail(e, cur, "service_stopped", false)
	if err = step(e, &cur, "stopping"); err != nil do return
	if crashed(e.inj) do return .Run, crash_error("stopping")
	e.phase = .Offline
	host_end_sessions(e)
	if !e.host.stop_children(e.host.user, F) do return before_switch_fail(e, cur, "stop_timeout", true)
	if err = step(e, &cur, "stopped"); err != nil do return
	if stop_req(e) do return before_switch_fail(e, cur, "service_stopped", true)
	if err = step(e, &cur, "snapshot"); err != nil do return
	if serr := take_snapshot(e, cur.op_id, F, rule == .One_Way); serr != nil {
		if is_crash(serr) do return .Run, serr
		if rule == .One_Way do return before_switch_fail(e, cur, "snapshot_failed", true)
		// Insurance snapshot only: carry on without it (§11.3 rollback-safe row).
		cur.note = "snapshot_skipped"
	}
	if stop_req(e) do return before_switch_fail(e, cur, "service_stopped", true)
	if err = step(e, &cur, "pointers_begin"); err != nil do return
	if perr := write_pointer(e, POINTER_PREVIOUS, F, cur.op_id); perr != nil {
		if is_crash(perr) do return .Run, perr
		return before_switch_fail(e, cur, "pointer_write", true)
	}
	if perr := write_pointer(e, POINTER_CURRENT, cur.to.tree, cur.op_id); perr != nil {
		if is_crash(perr) do return .Run, perr
		if read_pointer_raw(e, POINTER_CURRENT) == F {
			return before_switch_fail(e, cur, "pointer_write", true)
		}
		// `current` is no longer F: past the point of no return.
		return run_rollback(e, cur, "pointer_write", Ref{})
	}
	// Point of no return passed (J14). J28: pin the tree we leave, then pointers_done.
	if cur.action == "rollback_to_previous" {
		if err = pin_user_rollback(e, cur); err != nil do return
	}
	if err = step(e, &cur, "pointers_done"); err != nil do return
	if err = step(e, &cur, "handover"); err != nil do return
	e.phase = .Offline
	return .Handover, nil
}

@(private)
stop_req :: proc(e: ^Engine) -> bool {
	return e.host.stop_requested != nil && e.host.stop_requested(e.host.user)
}

// J28: the newer tree `from` is pinned (user_rollback) only once `current := to` landed.
@(private)
pin_user_rollback :: proc(e: ^Engine, op: Line) -> Error {
	if op.from.version == "" do return nil
	return add_pin(e, op.from.version, op.from.sha256, op.op_id, "user_rollback")
}

@(private)
tree_sizes_match :: proc(e: ^Engine, tree: string) -> bool {
	return fetch.tree_check_sizes(join(e.cfg.instance_root, "releases", tree)) == nil
}

// ---------------------------------------------------------------------------------------
// probation (§14), commit (J17)
// ---------------------------------------------------------------------------------------

// tick advances probation and an op waiting for idle agents (§12). Call about once a
// second while running.
tick :: proc(e: ^Engine) -> (x: Exit, err: Error) {
	if e.failed != nil do return .Run, e.failed
	defer poison(e, err)
	if op, waiting := e.active.?; waiting && op.state == "waiting_for_idle" && e.phase == .Idle {
		// Agent gate (§12): re-count, activate when idle or at force_at.
		return activate(e)
	}
	if e.phase != .Probation && e.phase != .Rollback_Probation do return .Run, nil
	op, ok := e.active.?
	if !ok do return .Run, nil
	if e.finish_pending {
		// The previous tick decided the result but a write failed: `known-good` may already
		// name the new tree, so finish that decision before judging health again (J17).
		target := op.to.tree if e.phase == .Probation else op.from.tree
		if known_good_valid(e) == target {
			if e.phase == .Probation do return commit(e, op)
			return rolled_back(e, op)
		}
	}
	h := e.host.health(e.host.user)
	t := now(e)
	reason := ""
	switch {
	case h == .Exited:
		reason = "runtime_exited"
	case e.ready_at == 0 && h == .Ready:
		e.ready_at = t
	case e.ready_at == 0 && t - e.started_at >= e.cfg.ready_timeout_s:
		reason = "runtime_not_ready"
	case e.ready_at != 0 && h != .Ready:
		reason = "runtime_unhealthy"
	}
	// The hub rule (§14) applies to the candidate only: a rollback must never depend on the
	// hub (report §8.3), so the rollback probation ignores it.
	hub_required := op.hub && e.phase == .Probation
	if reason == "" && hub_required && e.host.hub_connected != nil && e.host.hub_connected(e.host.user) do e.hub_seen = true
	if reason == "" && e.ready_at != 0 && t - e.ready_at >= e.cfg.probation_s {
		if hub_required && !e.hub_seen do reason = "hub_unreachable"
		else if e.phase == .Probation do return commit(e, op)
		else do return rolled_back(e, op)
	}
	if reason == "" do return .Run, nil
	if e.phase == .Probation do return run_rollback(e, op, reason, Ref{})
	return rollback_failed(e, op, reason)
}

// finish_failed: committed / rolled_back could not be written. During probation a
// retryable write failure is retried on the next tick (Error contract); anything else is
// fatal.
@(private)
finish_failed :: proc(e: ^Engine, err: Error) -> (Exit, Error) {
	if (e.phase == .Probation || e.phase == .Rollback_Probation) && retryable_write(err) {
		e.finish_pending = true
		return .Run, nil
	}
	return .Run, err
}

@(private)
commit :: proc(e: ^Engine, op: Line) -> (Exit, Error) {
	if err := write_known_good(e, op.to.tree, op.op_id); err != nil do return finish_failed(e, err)
	note := "" if op.hub else "probation_offline"
	if err := journal(e, terminal_of(op, "committed", "", note)); err != nil do return finish_failed(e, err)
	e.finish_pending = false
	if e.phase != .Probation {
		// Committed at start (J17 replay): the runtime of `to` still has to run.
		return run_idle(e)
	}
	e.phase = .Idle
	return .Run, nil
}

@(private)
rolled_back :: proc(e: ^Engine, op: Line) -> (Exit, Error) {
	if err := write_known_good(e, op.from.tree, op.op_id); err != nil do return finish_failed(e, err)
	if err := journal(e, terminal_of(op, "rolled_back", op.error, op.note)); err != nil do return finish_failed(e, err)
	e.finish_pending = false
	e.phase = .Idle
	return .Run, nil
}

@(private)
rollback_failed :: proc(e: ^Engine, op: Line, why: string) -> (Exit, Error) {
	if !crashed(e.inj) {
		// Stop before the terminal line: a runtime that outlives rollback_failed would run
		// unmonitored. On stop_timeout the op stays rolling_back and the next start reaps.
		if !e.host.stop_children(e.host.user, e.launched) {
			return .Run, fail("stop_timeout", "children of %s did not stop before rollback_failed", e.launched)
		}
		e.runtime_tree = ""
	}
	note := why
	if op.note != "" do note = fmt.tprintf("%s; %s", op.note, why)
	if err := journal(e, terminal_of(op, "rollback_failed", op.error, note)); err != nil do return .Run, err
	e.phase = .Rollback_Failed
	return .Run, nil
}

// ---------------------------------------------------------------------------------------
// rollback (J18–J25)
// ---------------------------------------------------------------------------------------

ROLLBACK_SUBS :: []string{"stopping", "stopped", "pin", "pointers", "restore", "handover", "probation", "probation_suspended"}

// rollback_target_ok: `from` names a valid tree other than `to`.
@(private)
rollback_target_ok :: proc(e: ^Engine, op: Line) -> bool {
	return op.from.tree != "" && op.from.tree != op.to.tree && tree_is_valid(e, op.from.tree)
}

@(private)
sub_index :: proc(sub: string) -> int {
	for s, i in ROLLBACK_SUBS do if s == sub do return i
	return 0
}

// run_rollback starts or resumes the rollback of `op` (to -> from). Every sub-step is
// idempotent and is re-run from the last journaled one (its line is written before its
// effect). The executor is this supervisor: if it runs from `to`, it hands over (exit 75)
// once `current := from`; if it runs from `from` (launcher fallback), it goes straight to
// the rollback probation.
@(private)
run_rollback :: proc(e: ^Engine, op_in: Line, reason: string, from_override: Ref, note := "", synthetic := false) -> (x: Exit, err: Error) {
	op := op_in
	if !ref_empty(from_override) do op.from = from_override
	if note != "" do op.note = note
	op.error = reason if reason != "" else op.error
	if op.error == "" do op.error = "rollback"
	if op.action == "adopt" && op_in.state != "rolling_back" && !rollback_target_ok(e, op) {
		// Adopt with nothing to roll back to (fresh install / lost journal and no other valid
		// tree): stopping or pinning the only release would leave the instance offline for
		// good. The op ends failed, the tree keeps running, and later starts do not re-probe
		// it (start). A repair intent replaces it.
		if !crashed(e.inj) && e.runtime_tree != "" {
			if !e.host.stop_children(e.host.user, e.runtime_tree) {
				return .Run, fail("stop_timeout", "children of %s did not stop", e.runtime_tree)
			}
			e.runtime_tree = ""
		}
		e.phase = .Offline
		if err = journal(e, terminal_of(op, "failed", op.error, "no_rollback_target")); err != nil do return
		return run_idle(e)
	}
	resume := 0
	if op_in.state == "rolling_back" && !synthetic do resume = sub_index(op_in.sub)
	op.state = "rolling_back"
	op.probation_attempt = op_in.probation_attempt if op_in.state == "rolling_back" else 0

	if resume <= sub_index("stopping") {
		op.sub = "stopping"
		if err = journal(e, op); err != nil do return
		e.phase = .Offline
		// `stopped` is journaled only once every child has exited. On stop_timeout the op
		// stays at `stopping` and the error is fatal: the next start reaps the survivors (J0)
		// before `current := from` can take effect, so two runtimes never run.
		stop_tree := ""
		if e.runtime_tree != "" do stop_tree = e.runtime_tree
		else if op.to.tree != "" && e.launched == op.to.tree do stop_tree = op.to.tree
		if !crashed(e.inj) && stop_tree != "" {
			host_end_sessions(e)
			if !e.host.stop_children(e.host.user, stop_tree) {
				return .Run, fail("stop_timeout", "children of %s did not stop", stop_tree)
			}
			e.runtime_tree = ""
		}
		op.sub = "stopped"
		if err = journal(e, op); err != nil do return
	}
	if resume <= sub_index("pin") {
		op.sub = "pin"
		if err = journal(e, op); err != nil do return
		// The target is checked before the pin: with nothing to roll back to, pinning `to`
		// would only block the release that is still installed (and maybe the only one).
		if !rollback_target_ok(e, op) do return rollback_failed(e, op, "no_rollback_target")
		if op.to.sha256 != "" && op.to.sha256 == op.from.sha256 {
			// T9 carry-over (b): a repair (same release, new -r<n> dir) that fails probation
			// would pin the running release; skip it explicitly.
			op.note = "pin_skipped same_release" if op.note == "" else fmt.tprintf("%s; pin_skipped same_release", op.note)
		} else if op.to.version != "" {
			if err = add_pin(e, op.to.version, op.to.sha256, op.op_id, op.error); err != nil do return
		}
	}
	if resume <= sub_index("pointers") {
		op.sub = "pointers"
		if err = journal(e, op); err != nil do return
		if op.from.tree == "" || !tree_is_valid(e, op.from.tree) {
			return rollback_failed(e, op, "no_rollback_target")
		}
		if read_pointer_raw(e, POINTER_CURRENT) != op.from.tree {
			if err = write_pointer(e, POINTER_CURRENT, op.from.tree, op.op_id); err != nil do return
		}
	}
	if resume <= sub_index("restore") {
		op.sub = "restore"
		if err = journal(e, op); err != nil do return
		if snapshot_required(e, op.op_id) {
			if rerr := restore_snapshot(e, op.op_id); rerr != nil {
				// A damaged or missing snapshot is terminal; a write that failed (fs_busy,
				// fs_error) is fatal and the restore is redone from `restore` at the next start.
				if error_code(rerr) != "restore_failed" do return .Run, rerr
				return rollback_failed(e, op, error_code(rerr))
			}
			op.note = "state_restored" if op.note == "" else fmt.tprintf("%s; state_restored", op.note)
		}
	}
	if e.launched != op.from.tree {
		// J23: the `to` supervisor hands over; the launcher starts `from` (= current = K).
		if resume <= sub_index("handover") {
			op.sub = "handover"
			if err = journal(e, op); err != nil do return
		}
		e.phase = .Offline
		return .Handover, nil
	}
	// We are `from`: rollback probation (J24), unclean restarts count (max 3, J16 rule).
	attempt := op.probation_attempt
	if op_in.state == "rolling_back" && op_in.sub == "probation_suspended" {
		// clean stop: same attempt
	} else {
		attempt += 1
	}
	if attempt < 1 do attempt = 1
	if attempt > e.cfg.max_unclean_attempts {
		return rollback_failed(e, op, "probation_interrupted")
	}
	op.sub = "probation"
	op.probation_attempt = attempt
	if err = journal(e, op); err != nil do return
	return run_probation(e)
}

// ---------------------------------------------------------------------------------------
// service stop (§7.5)
// ---------------------------------------------------------------------------------------

// stop handles a service stop between ticks: probation (either kind) is suspended with the
// attempt unchanged (J16a); children are stopped; exit 0.
stop :: proc(e: ^Engine) -> (x: Exit, err: Error) {
	if e.failed != nil do return .Stop, e.failed
	defer poison(e, err)
	if op, ok := e.active.?; ok && (e.phase == .Probation || e.phase == .Rollback_Probation) {
		s := op
		s.sub = "probation_suspended"
		if err = journal(e, s); err != nil do return
	}
	if e.runtime_tree != "" && !crashed(e.inj) {
		if !e.host.stop_children(e.host.user, e.runtime_tree) {
			// Exit 1, not 0: the next start reaps the survivors (J0).
			return .Stop, fail("stop_timeout", "children of %s did not stop", e.runtime_tree)
		}
		e.runtime_tree = ""
	}
	e.phase = .Offline
	return .Stop, nil
}

