package shell_session

// REQ-SHELL-10 service-level acceptance tests — the convergence protocol's hub half.
//
// The requirement's acceptance criteria, and where each is asserted:
//   AC1  all three diff branches converge to bridge truth
//        -> t10_absent_row_goes_terminal / t10_untracked_session_is_adopted /
//           t10_bridge_wins_on_status_disagreement
//   AC2  a kill requested while the bridge was disconnected is delivered on reconnect
//        -> t10_kill_intent_replayed_for_revived_session
//   AC4  an inventory from bridge A naming bridge B's session changes nothing on B
//        -> t10_inventory_cannot_touch_another_bridge
//   AC5  applying the same inventory twice is a no-op the second time
//        -> t10_same_inventory_twice_is_a_noop
//   plus the direction REQ-SHELL-14 depends on — "hub says terminal, bridge says
//   running" — in its three distinguishable cases
//        -> t10_unobserved_terminal_is_revived /
//           t10_observed_terminal_is_not_revived /
//           t10_observed_terminal_loses_to_a_newer_run
//
// AC3 (bridge-offline presentation) and AC6 (the connection-generation guard) are not
// here because this task's design puts neither in this layer: the bridge-offline state
// is DERIVED at serialization time from the live registry rather than stored, so it is
// asserted in the transport package where it is computed, and it needs no generation
// guard precisely because it writes nothing on disconnect. See
// shell_session_status_unknown in src/hub/transport/http/shell_session_rest_handlers.odin.
//
// The fake repository below deliberately mirrors the SQL's OWNERSHIP semantics, not
// just its logic: upsert stores a deep clone and frees what it superseded, exactly as
// sqlite copies a bound row into the database. A fake that stored the caller's
// pointers would make this service's correct domain.shell_session_destroy look like a
// use-after-free, and would be testing an ownership rule the real repository does not
// have.

import "core:strings"
import "core:sync"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"

// --- fake repository ---------------------------------------------------------

// KEYED BY (bridge_id, session_id), exactly as migration 048 rekeyed the real table
// for REQ-SHELL-1 §7 — not by session_id alone. The difference is load-bearing for
// AC4: under the composite key an adopt of the same session_id on another bridge
// creates a SEPARATE row, while a session_id-keyed fake would silently let it
// overwrite the other bridge's row and would report a cross-bridge write this code
// cannot actually perform.
@(private = "file")
Repo10 :: struct {
	stored: map[string]domain.Shell_Session, // "<bridge_id>\x00<session_id>" -> row
	writes: int,
}

@(private = "file")
r10_key :: proc(bridge_id, session_id: string) -> string {
	// context.temp_allocator: keys are compared and cloned by the map on insert, so a
	// per-call scratch string is enough and nothing here has to be freed by hand.
	return strings.concatenate({bridge_id, "\x00", session_id}, context.temp_allocator)
}

@(private = "file")
r10_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
	out := s
	out.session_id        = strings.clone(s.session_id)
	out.owner_user_id     = strings.clone(s.owner_user_id)
	out.bridge_id         = strings.clone(s.bridge_id)
	out.project_id        = strings.clone(s.project_id)
	out.chain_id          = strings.clone(s.chain_id)
	out.agent_instance_id = strings.clone(s.agent_instance_id)
	out.kind              = strings.clone(s.kind)
	out.conversation_id   = strings.clone(s.conversation_id)
	out.label             = strings.clone(s.label)
	out.cmd               = strings.clone(s.cmd)
	out.cwd               = strings.clone(s.cwd)
	out.status            = strings.clone(s.status)
	out.kill_requested_at = strings.clone(s.kill_requested_at)
	out.started_at        = strings.clone(s.started_at)
	out.finished_at       = strings.clone(s.finished_at)
	out.created_at        = strings.clone(s.created_at)
	out.last_activity_at  = strings.clone(s.last_activity_at)
	return out
}

@(private = "file")
r10_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	r.writes += 1
	key := r10_key(session.bridge_id, session.session_id)
	next := r10_clone(session)
	if prev, had := r.stored[key]; had {
		// Mirror the real upsert's kill_requested_at CASE: a terminal status clears the
		// intent structurally (REQ-SHELL-3), a non-empty incoming value sets it,
		// otherwise the stored value survives. This diff writes no intent of its own and
		// relies on exactly that auto-clear, so a fake without it would let the test pass
		// while the real thing left a spent intent behind.
		switch {
		case domain.shell_session_status_is_terminal(session.status): next.kill_requested_at = _r10_replace(next.kill_requested_at, "")
		case session.kill_requested_at != "":                          // keep incoming
		case:                                                          next.kill_requested_at = _r10_replace(next.kill_requested_at, prev.kill_requested_at)
		}
		domain.shell_session_destroy(prev)
	} else if domain.shell_session_status_is_terminal(next.status) {
		next.kill_requested_at = _r10_replace(next.kill_requested_at, "")
	}
	// Clone the key only when INSERTING: assigning to an existing entry keeps the map's
	// original key, so cloning unconditionally would leak one key string per update.
	if _, present := r.stored[key]; present {
		r.stored[key] = next
	} else {
		r.stored[strings.clone(key)] = next
	}
	return true, domain.Domain_Error{}
}

// _r10_replace frees a clone's field and returns a fresh clone of `with`, so the
// stored row stays wholly repo-owned whichever branch above ran.
@(private = "file")
_r10_replace :: proc(current, with: string) -> string {
	delete(current)
	return strings.clone(with)
}

@(private = "file")
r10_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	// Owner-scoped and bridge-agnostic, like the real owner-scoped get.
	for _, s in r.stored {
		if s.session_id == session_id && s.owner_user_id == owner_user_id do return r10_clone(s), true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

// Bridge-scoped and owner-unscoped, like the real get_by_id. The bridge check is the
// fake's whole point for AC4: a session belonging to another bridge must not resolve.
@(private = "file")
r10_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	s, had := r.stored[r10_key(bridge_id, session_id)]
	if !had do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return r10_clone(s), true, domain.Domain_Error{}
}

@(private = "file")
r10_list_live_by_bridge :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, r10_clone(s))
	}
	return out, domain.Domain_Error{}
}

@(private = "file")
r10_list_pending_kills :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if !domain.shell_session_kill_intent_pending(s) do continue
		append(&out, r10_clone(s))
	}
	return out, domain.Domain_Error{}
}

// --- fake bridge sink --------------------------------------------------------

@(private = "file")
Sink10 :: struct {
	mu:     sync.Mutex,
	bodies: [dynamic]string,
}

@(private = "file")
s10_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink10)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

@(private = "file")
s10_count :: proc(s: ^Sink10, type_name: string) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	needle := strings.concatenate({"\"type\":\"", type_name, "\""})
	defer delete(needle)
	n := 0
	for b in s.bodies {
		if strings.contains(b, needle) do n += 1
	}
	return n
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx10 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo10,
	sink: Sink10,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
NOW10 :: "2026-09-28T12:00:00Z"

@(private = "file")
now10 :: proc(ctx: rawptr) -> string { _ = ctx; return strings.clone(NOW10) }

@(private = "file")
fx10_make :: proc(fx: ^Fx10) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.sink.bodies = make([dynamic]string)
	fx.repo = iface.Shell_Session_Repository{
		ctx                 = rawptr(&fx.r),
		upsert              = r10_upsert,
		get                 = r10_get,
		get_by_id           = r10_get_by_id,
		list_live_by_bridge = r10_list_live_by_bridge,
		list_pending_kills  = r10_list_pending_kills,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now10}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                  = rawptr(&fx.sink),
			send_runtime_command = s10_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx10_free :: proc(fx: ^Fx10) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	for k, s in fx.r.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.r.stored)
}

@(private = "file")
Seed10 :: struct {
	session_id:    string,
	bridge_id:     string,
	status:        string,
	exit_code_set: bool,
	run_seq:       int,
	kill_at:       string,
}

@(private = "file")
fx10_seed :: proc(fx: ^Fx10, seed: Seed10) {
	row := domain.Shell_Session{
		session_id        = seed.session_id,
		owner_user_id     = "owner_a",
		bridge_id         = seed.bridge_id,
		kind              = domain.Shell_Session_Kind_Shell,
		cmd               = "zsh",
		status            = seed.status,
		exit_code_set     = seed.exit_code_set,
		run_seq           = seed.run_seq,
		kill_requested_at = seed.kill_at,
		started_at        = "2026-09-28T09:00:00Z",
	}
	fx.r.stored[strings.clone(r10_key(seed.bridge_id, seed.session_id))] = r10_clone(row)
}

@(private = "file")
fx10_row :: proc(fx: ^Fx10, session_id: string, bridge_id := "brg_1") -> (domain.Shell_Session, bool) {
	s, had := fx.r.stored[r10_key(bridge_id, session_id)]
	return s, had
}

// inv10 builds an inventory frame the way the bridge does, so these tests exercise
// the real parser rather than a convenient shape it never sees.
@(private = "file")
inv10 :: proc(entries: []string, truncated := false) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_inventory\",\"sessions\":[")
	for e, i in entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, e)
	}
	strings.write_string(&b, "],\"truncated\":")
	strings.write_string(&b, truncated ? "true" : "false")
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
Entry10 :: struct {
	session_id: string,
	status:     string,
	kind:       string,
	owner:      string,
	pid:        int,
	run_seq:    int,
}

@(private = "file")
entry10 :: proc(e: Entry10) -> string {
	kind := e.kind if e.kind != "" else domain.Shell_Session_Kind_Shell
	owner := e.owner if e.owner != "" else "owner_a"
	status := e.status if e.status != "" else domain.Shell_Session_Status_Running
	b := strings.builder_make()
	strings.write_string(&b, "{\"session_id\":\"")
	strings.write_string(&b, e.session_id)
	strings.write_string(&b, "\",\"kind\":\"")
	strings.write_string(&b, kind)
	strings.write_string(&b, "\",\"status\":\"")
	strings.write_string(&b, status)
	strings.write_string(&b, "\",\"shell_id\":\"\",\"started_at\":\"2026-09-28T09:00:00Z\",\"label\":\"\",\"cmd\":\"zsh\",\"cwd\":\"/tmp\",\"owner_user_id\":\"")
	strings.write_string(&b, owner)
	strings.write_string(&b, "\",\"project_id\":\"\",\"chain_id\":\"\",\"agent_instance_id\":\"\",\"background\":false,\"pid\":")
	strings.write_int(&b, e.pid)
	strings.write_string(&b, ",\"server_port\":0,\"run_seq\":")
	strings.write_int(&b, e.run_seq)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// --- AC1: the three diff branches --------------------------------------------

// BRANCH (a): the hub believes a session is live; the bridge's complete inventory
// does not name it. It died while we were away — invariant (b), for the reconnect
// case. The status must be TERMINAL but NOT OBSERVED: fabricating an exit code here
// would make this guess outrank a real exit that may still arrive from the bridge's
// durable outbox (see domain.shell_session_terminal_is_observed).
@(test)
t10_absent_row_goes_terminal :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_gone", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	frame := inv10({}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.terminated, 1)
	row, had := fx10_row(&fx, "sh_gone")
	testing.expect(t, had, "the row must still exist — converging is not deleting")
	testing.expect_value(t, row.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
	testing.expect_value(t, row.finished_at, NOW10)
	testing.expect(t, !domain.shell_session_terminal_is_observed(row),
		"a status the hub SYNTHESIZED must not claim to be an observed exit, or a late real exit can never correct it")
}

// BRANCH (b): the bridge is running a session the hub has no row for — invariant (a),
// "running on a bridge but untracked by the hub". Adopting it is what makes it
// listable and killable instead of an invisible process.
@(test)
t10_untracked_session_is_adopted :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)

	e := entry10(Entry10{session_id = "sh_new", pid = 4242, run_seq = 3}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.adopted, 1)
	row, had := fx10_row(&fx, "sh_new")
	testing.expect(t, had, "an untracked live session must become a row")
	testing.expect_value(t, row.bridge_id, "brg_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.pid, 4242)
	// The bridge's echo is the only record of which run this is; taking it is what
	// stops a later exit for run 3 being discarded as stale against a row that had
	// defaulted to 0.
	testing.expect_value(t, row.run_seq, 3)
}

// BRANCH (c): both sides know the session and disagree about its status. The bridge
// owns the processes and has just observed this one, so the bridge wins.
@(test)
t10_bridge_wins_on_status_disagreement :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_1", bridge_id = "brg_1", status = domain.Shell_Session_Status_Starting})

	e := entry10(Entry10{session_id = "sh_1", status = domain.Shell_Session_Status_Running, pid = 99}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.corrected, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.pid, 99)
}

// --- "hub says terminal, bridge says running" — REQ-SHELL-14's dependency -----

// The case REQ-SHELL-14 exists to create: it writes off the sessions of a bridge it
// judges gone, necessarily WITHOUT observing anything. If that bridge returns with the
// process alive, this diff is the only thing that can undo the guess — so the guess
// must lose to the bridge's observation.
@(test)
t10_unobserved_terminal_is_revived :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Failed, exit_code_set = false, // synthesized
	})

	e := entry10(Entry10{session_id = "sh_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.finished_at, "")
}

// The exception, and the reason reviving is conditional rather than unconditional: a
// terminal the hub OBSERVED for THIS run is not a guess, it is a report from a bridge
// that watched the process end. Resurrecting a row on the strength of a claim that
// contradicts something we watched happen would be adopting the WORSE evidence.
@(test)
t10_observed_terminal_is_not_revived :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Exited, exit_code_set = true, run_seq = 2, // observed
	})

	e := entry10(Entry10{session_id = "sh_1", run_seq = 2}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 0)
	testing.expect_value(t, res.conflicted, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Exited)
}

// …but a NEWER run is not that conflict at all: the bridge restarted the session, so
// it is describing a different run from the one the hub watched end, and it wins as
// usual. Without this, a restart whose hub-side write was lost would leave the session
// permanently terminal with a live process behind it.
@(test)
t10_observed_terminal_loses_to_a_newer_run :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Exited, exit_code_set = true, run_seq = 2,
	})

	e := entry10(Entry10{session_id = "sh_1", run_seq = 3}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
}

// --- AC4: a bridge may only ever touch its own sessions ----------------------

// The check that matters most in this file. One inventory mutates MANY rows, so a
// missing scope check here is not one leaked session but a whole bridge's worth —
// and, in practice, another user's.
@(test)
t10_inventory_cannot_touch_another_bridge :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_b", bridge_id = "brg_2", status = domain.Shell_Session_Status_Running})

	// Bridge A names bridge B's session, both as a live entry and by omitting it.
	e := entry10(Entry10{session_id = "sh_b"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	// B's row is untouched: not corrected, not revived, and — crucially — not
	// TERMINATED, even though bridge A's inventory is complete and A's live-row query
	// is what drives the "absent means dead" branch.
	b_row, b_had := fx10_row(&fx, "sh_b", "brg_2")
	testing.expect(t, b_had, "bridge B's row must still exist")
	testing.expect_value(t, b_row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, b_row.bridge_id, "brg_2")
	testing.expect_value(t, res.corrected, 0)
	testing.expect_value(t, res.terminated, 0)
	testing.expect_value(t, res.revived, 0)
	// A's entry resolved to nothing on A (the lookup is bridge-scoped), so it took the
	// adopt path — and adoption stamps the REPORTING bridge's id. Whatever that created
	// is A's own row under the composite key (bridge_id, session_id), never B's.
	if res.adopted == 1 {
		a_row, a_had := fx10_row(&fx, "sh_b", "brg_1")
		testing.expect(t, a_had, "the adopted row belongs to the reporting bridge")
		testing.expect_value(t, a_row.bridge_id, "brg_1")
	}
}

// --- AC5: idempotence --------------------------------------------------------

// Reconnect flapping delivers the same inventory repeatedly. The second application
// must write nothing and publish nothing, or a bridge that reconnects five times in a
// minute produces five rounds of events for one convergence.
@(test)
t10_same_inventory_twice_is_a_noop :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_1", bridge_id = "brg_1", status = domain.Shell_Session_Status_Starting})
	fx10_seed(&fx, Seed10{session_id = "sh_gone", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	e := entry10(Entry10{session_id = "sh_1", status = domain.Shell_Session_Status_Running}); defer delete(e)
	e2 := entry10(Entry10{session_id = "sh_new"}); defer delete(e2)
	frame := inv10({e, e2}); defer delete(frame)

	first := shell_session_apply_inventory(&fx.svc, "brg_1", frame)
	testing.expect(t, shell_session_inventory_changed(first), "the first apply must converge something")
	writes_after_first := fx.r.writes

	second := shell_session_apply_inventory(&fx.svc, "brg_1", frame)
	testing.expect(t, !shell_session_inventory_changed(second), "the second apply must change nothing")
	testing.expect_value(t, second.adopted, 0)
	testing.expect_value(t, second.corrected, 0)
	testing.expect_value(t, second.terminated, 0)
	testing.expect_value(t, second.revived, 0)
	testing.expect_value(t, fx.r.writes, writes_after_first)
}

// --- truncation: a bound must not become a death sentence --------------------

// The "it died while we were away" branch reasons from ABSENCE, and a truncated
// inventory cannot establish absence — only that the bridge ran out of room. Reading a
// full buffer as a death report would kill off rows whose processes are alive, which
// is strictly worse than the stale row it set out to fix.
@(test)
t10_truncated_inventory_does_not_terminate :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_unlisted", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	e := entry10(Entry10{session_id = "sh_new"}); defer delete(e)
	frame := inv10({e}, truncated = true); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.terminated, 0)
	row, _ := fx10_row(&fx, "sh_unlisted")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	// Presence-based branches are unaffected by truncation, so adoption still happens.
	testing.expect_value(t, res.adopted, 1)
}

// --- AC2 / invariant (c): the kill lands on reconnect ------------------------

// The window this closes: shell_session_replay_kill_intents runs on the bridge-WS
// ACCEPT path, strictly before this frame can arrive. A session revived (or adopted)
// by the diff was therefore not in the set that replay read, and its durable kill
// would wait for a further reconnect that may never come.
@(test)
t10_kill_intent_replayed_for_revived_session :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Failed, // a REQ-SHELL-14-style guess
		kill_at = "2026-09-28T11:00:00Z",
	})

	e := entry10(Entry10{session_id = "sh_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 1)
	testing.expect_value(t, res.kills_replayed, 1)
}

// A diff that changed nothing must not re-issue kills either — the replay is
// conditioned on convergence so a no-op inventory stays a no-op end to end.
@(test)
t10_noop_inventory_replays_no_kills :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Running,
		kill_at = "2026-09-28T11:00:00Z",
	})

	e := entry10(Entry10{session_id = "sh_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect(t, !shell_session_inventory_changed(res), "nothing diverged, so nothing should be written")
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 0)
}

// --- refusals ----------------------------------------------------------------

// Adoption is the one branch that CREATES a row, so it is the one an entry could use
// to manufacture junk. A row with no owner is invisible to every owner-scoped read and
// unkillable through the API — worse than the untracked process it meant to fix — and
// one that violates its kind's scope rule would be returned by the wrong listings for
// the rest of its life (REQ-SHELL-1 §5).
@(test)
t10_unadoptable_entries_are_refused :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)

	no_owner := entry10(Entry10{session_id = "sh_no_owner", owner = " "}); defer delete(no_owner)
	// kind=shell is BRIDGE scoped and forbids chain_id, so this entry contradicts its
	// own kind's scope rule.
	bad_scope_src := entry10(Entry10{session_id = "sh_bad_scope"}); defer delete(bad_scope_src)
	bad_scope, _ := strings.replace(bad_scope_src, "\"chain_id\":\"\"", "\"chain_id\":\"chain_x\"", 1)
	defer delete(bad_scope)
	unknown_kind := entry10(Entry10{session_id = "sh_bad_kind", kind = "agent"}); defer delete(unknown_kind)
	// A terminal status in an inventory is refused: ending a session belongs to the
	// exit path, which carries the exit code this frame does not.
	terminal := entry10(Entry10{session_id = "sh_terminal", status = domain.Shell_Session_Status_Exited}); defer delete(terminal)

	frame := inv10({no_owner, bad_scope, unknown_kind, terminal}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.adopted, 0)
	testing.expect_value(t, res.ignored, 4)
	for id in ([]string{"sh_no_owner", "sh_bad_scope", "sh_bad_kind", "sh_terminal"}) {
		_, had := fx10_row(&fx, id)
		testing.expectf(t, !had, "%s must not have been stored", id)
	}
}

// --- the parser --------------------------------------------------------------

// A shell session's cmd is arbitrary user text. A brace counter alone would end the
// object early on `echo "}"`, truncating every field after it — silently, since the
// result is a well-formed entry with missing values. The key scan has the same hazard
// in reverse: a cmd containing `"pid":` must not be read as the field.
@(test)
t10_parse_survives_json_lookalikes_in_cmd :: proc(t: ^testing.T) {
	frame := strings.concatenate({
		"{\"type\":\"shell_inventory\",\"sessions\":[",
		"{\"session_id\":\"sh_1\",\"kind\":\"shell\",\"status\":\"running\",",
		"\"cmd\":\"echo '}' && echo \\\"pid\\\": 7 && echo [sessions]\",",
		"\"owner_user_id\":\"owner_a\",\"pid\":31337,\"run_seq\":0},",
		"{\"session_id\":\"sh_2\",\"kind\":\"shell\",\"status\":\"running\",\"cmd\":\"zsh\",\"owner_user_id\":\"owner_a\",\"pid\":2,\"run_seq\":0}",
		"],\"truncated\":false}",
	})
	defer delete(frame)

	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].session_id, "sh_1")
	testing.expect_value(t, entries[0].pid, 31337)
	testing.expect_value(t, entries[1].session_id, "sh_2")
	testing.expect_value(t, entries[1].pid, 2)
}

// The coordinator asked for the replay window to be pinned on the ADOPTED path as
// well as the revived one. It cannot be: a kill intent lives ON A ROW
// (kill_requested_at), and adoption is by definition the branch where NO ROW EXISTS —
// so an adopted session cannot carry a pre-existing intent, and there is no state to
// construct the test from. Reported rather than faked with a hand-placed intent no
// real code path could have written.
//
// The CORRECTED path can carry one, and it exercises the same window for the same
// reason, so it is pinned here instead: the accept-path replay saw this row before the
// inventory arrived, and whether the kill goes out in THIS reconnect or waits for a
// further one that may never come is decided by the re-run after the diff.
@(test)
t10_kill_intent_replayed_for_corrected_session :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status  = domain.Shell_Session_Status_Starting,
		kill_at = "2026-09-28T11:00:00Z", // accepted while the bridge was offline
	})

	e := entry10(Entry10{session_id = "sh_1", status = domain.Shell_Session_Status_Running}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.corrected, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 1)
	testing.expect_value(t, res.kills_replayed, 1)
	// The intent is still OUTSTANDING, not cleared by delivery: it retires when a
	// terminal status lands, which is REQ-SHELL-3's structural auto-clear and not this
	// path's business. Clearing it here would strand the session if the kill were lost.
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect(t, domain.shell_session_kill_intent_pending(row),
		"an intent is spent by a terminal status landing, not by being dispatched")
}
