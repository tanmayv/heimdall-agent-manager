package shell_session

// REQ-SHELL-9 service-level tests — servers must not outlive their purpose.
//
// What is asserted HERE, and what is asserted in package app:
//   HERE, THE ROW WORK — given "this chain closed" or "this server is a day old",
//   exactly which rows acquire a durable kill intent, which do not, and what is sent:
//     t9_chain_close_kills_that_chains_servers      the positive
//     t9_chain_close_leaves_other_chains_alone      THE NEGATIVE (AC1 requires both)
//     t9_chain_reap_never_touches_a_run_or_a_shell  AC3, chain half
//     t9_age_reap_kills_old_and_spares_young        AC2, injected timestamps, no sleeping
//     t9_age_reap_never_touches_a_run_or_a_shell    AC3, age half
//     t9_offline_bridge_still_records_the_intent    AC4 — the REQ-SHELL-3 dependency
//     t9_repeated_sweeps_do_not_requeue             AC5
//     t9_age_boundary_and_unparseable_timestamps    the threshold itself, in isolation
//   IN src/hub/app/reaper_req9_test.odin, the SWEEP WIRING — that the reaper carries the
//   age pass and no new timer was introduced (AC6).
//
// A NOTE ON WHAT THE FAKE DELIBERATELY DOES NOT DO. The real list_by_chain narrows on
// chain_id AND on the kinds whose scope key includes .Chain, so the SQL alone makes it
// impossible for a run or a shell to reach the reap. The fake here does NOT apply that
// kind filter: it returns every live row of the chain regardless of kind. That is on
// purpose. If the fake replicated the query's filter, t9_chain_reap_never_touches_a_run
// would be testing the fake rather than the service, and it would keep passing if the
// service's own kind refusal were deleted. Handing the service rows it must refuse is
// the only way to assert that it refuses them.

import "core:strings"
import "core:sync"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"

// --- fake repository ---------------------------------------------------------

@(private = "file")
Repo9 :: struct {
	stored:     map[string]domain.Shell_Session, // session_id -> row
	kill_calls: int,
}

@(private = "file")
r9_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
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

// r9_set_kill_requested mirrors the real op's FIRST-WRITER-WINS rule (REQ-SHELL-3): an
// existing intent is NOT overwritten. The fake must have it, because AC5's "does not
// re-queue" is partly the service skipping and partly this clause holding the original
// timestamp — a fake that clobbered would let a re-queue pass unnoticed.
//
// OWNER-SCOPED, like the real one: a row belonging to another owner is not found. This is
// what makes the chain reap's "a chain can only reap its own servers" claim testable.
@(private = "file")
r9_set_kill_requested :: proc(ctx: rawptr, owner_user_id, session_id, kill_requested_at: string) -> (bool, domain.Domain_Error) {
	r := (^Repo9)(ctx)
	r.kill_calls += 1
	row, had := r.stored[session_id]
	if !had || row.owner_user_id != owner_user_id do return false, domain.Domain_Error{}
	if row.kill_requested_at == "" {
		delete(row.kill_requested_at)
		row.kill_requested_at = strings.clone(kill_requested_at)
		r.stored[session_id] = row
	}
	return true, domain.Domain_Error{}
}

// r9_list_by_chain is owner- and chain-scoped and honours the `live` status group. It
// does NOT apply the real query's kind filter — see the file header for why that
// omission is deliberate rather than an incomplete fake.
@(private = "file")
r9_list_by_chain :: proc(ctx: rawptr, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	r := (^Repo9)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.owner_user_id != owner_user_id do continue
		if s.chain_id != chain_id do continue
		if status_filter == domain.Shell_Session_Status_Group_Live && domain.shell_session_is_terminal(s) do continue
		append(&out, r9_clone(s))
	}
	return out, "", domain.Domain_Error{}
}

// r9_list_live_by_kind is owner-UNscoped, like the real sweep read. The kind filter IS
// applied here because it is the query's entire identity — unlike list_by_chain, where
// the kind narrowing is an implication of the scope descriptor rather than the argument.
// The service's own kind refusal is still exercised, by t9_age_reap_never_touches_a_run
// asking for a kind the reap must not act on.
@(private = "file")
r9_list_live_by_kind :: proc(ctx: rawptr, kind: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo9)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.kind != kind do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, r9_clone(s))
	}
	return out, domain.Domain_Error{}
}

// --- fake bridge sink --------------------------------------------------------

@(private = "file")
Sink9 :: struct {
	mu:      sync.Mutex,
	bodies:  [dynamic]string,
	// offline makes every send fail, which is how a DISCONNECTED bridge is expressed:
	// _shell_session_dispatch_kill classifies any send failure as Queued.
	offline: bool,
}

@(private = "file")
s9_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink9)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.offline do return false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx9 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo9,
	sink: Sink9,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

// NOW9 is when the reap runs. Ages are expressed by seeding started_at in the past
// relative to it — never by sleeping, which is what AC2 requires.
@(private = "file")
NOW9 :: "2026-09-29T12:00:00Z"

// Derived from NOW9 by hand so the arithmetic is visible in the test rather than hidden
// in a helper: one day is 24h, so 25h ago is over the line and 23h ago is under it.
@(private = "file")
STARTED_25H_AGO :: "2026-09-28T11:00:00Z"
@(private = "file")
STARTED_23H_AGO :: "2026-09-28T13:00:00Z"

@(private = "file")
DAY_MS :: i64(24 * 60 * 60 * 1000)

@(private = "file")
now9 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-29T12:00:00Z" }

@(private = "file")
fx9_now_ms :: proc() -> i64 {
	ms, _ := platform.rfc3339_to_unix_ms(NOW9)
	return ms
}

@(private = "file")
fx9_make :: proc(fx: ^Fx9) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.repo = iface.Shell_Session_Repository{
		ctx                = rawptr(&fx.r),
		set_kill_requested = r9_set_kill_requested,
		list_by_chain      = r9_list_by_chain,
		list_live_by_kind  = r9_list_live_by_kind,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now9}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                  = rawptr(&fx.sink),
			send_runtime_command = s9_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx9_free :: proc(fx: ^Fx9) {
	shell_session_service_free(&fx.svc)
	// The KEY is cloned on insert (fx9_seed), so it is freed here alongside the row.
	// Missing this is exactly the leak the tracking allocator reported when this file
	// was first written, and it is worth keeping visible: the sum of the leaked bytes
	// was the sum of the session_id lengths, which is how it was identified as the
	// fixture's rather than the service's.
	for k, s in fx.r.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.r.stored)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
}

@(private = "file")
Seed9 :: struct {
	session_id: string,
	kind:       string,
	chain_id:   string,
	owner:      string,
	status:     string,
	started_at: string,
	kill_at:    string,
}

@(private = "file")
fx9_seed :: proc(fx: ^Fx9, seed: Seed9) {
	row := domain.Shell_Session{
		session_id        = seed.session_id,
		owner_user_id     = seed.owner if seed.owner != "" else "owner_a",
		bridge_id         = "brg_1",
		chain_id          = seed.chain_id,
		kind              = seed.kind if seed.kind != "" else domain.Shell_Session_Kind_Server,
		cmd               = "npm run dev",
		status            = seed.status if seed.status != "" else domain.Shell_Session_Status_Running,
		started_at        = seed.started_at if seed.started_at != "" else STARTED_23H_AGO,
		kill_requested_at = seed.kill_at,
	}
	fx.r.stored[strings.clone(seed.session_id)] = r9_clone(row)
}

@(private = "file")
fx9_intent :: proc(fx: ^Fx9, session_id: string) -> string {
	s, had := fx.r.stored[session_id]
	if !had do return "<missing>"
	return s.kill_requested_at
}

// --- tests: chain-close trigger (A) -------------------------------------------

// AC1, positive half. Closing a chain records a durable kill intent on each of its live
// servers, and actually dispatches — the intent is the durable half, the send the
// best-effort half, and both must happen.
@(test)
t9_chain_close_kills_that_chains_servers :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_1", chain_id = "chain_a"})
	fx9_seed(&fx, {session_id = "srv_2", chain_id = "chain_a"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, reaped, 2)
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
	testing.expect_value(t, fx9_intent(&fx, "srv_2"), NOW9)
	testing.expect_value(t, len(fx.sink.bodies), 2)
}

// AC1, THE NEGATIVE, which the task calls out specifically: another chain's servers keep
// running. A reap that killed everything would pass the positive test above.
@(test)
t9_chain_close_leaves_other_chains_alone :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_mine",  chain_id = "chain_a"})
	fx9_seed(&fx, {session_id = "srv_other", chain_id = "chain_b"})
	// A server of ANOTHER OWNER on the same chain id: scope is owner AND chain, and a
	// chain id is not a capability.
	fx9_seed(&fx, {session_id = "srv_foreign", chain_id = "chain_a", owner = "owner_b"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "srv_mine"), NOW9)
	testing.expect_value(t, fx9_intent(&fx, "srv_other"), "")
	testing.expect_value(t, fx9_intent(&fx, "srv_foreign"), "")
}

// AC3, chain half. The real query cannot even return these rows; the fake hands them over
// anyway so the service's own refusal is what is being asserted. A `run` is bounded by
// its 30-minute cap and a `shell` is a terminal someone is typing into — reaping either
// would be destroying live work on a timer.
@(test)
t9_chain_reap_never_touches_a_run_or_a_shell :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "run_1",   chain_id = "chain_a", kind = domain.Shell_Session_Kind_Run})
	fx9_seed(&fx, {session_id = "shell_1", chain_id = "chain_a", kind = domain.Shell_Session_Kind_Shell})
	fx9_seed(&fx, {session_id = "srv_1",   chain_id = "chain_a"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "run_1"), "")
	testing.expect_value(t, fx9_intent(&fx, "shell_1"), "")
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
	// One dispatch, for the server alone.
	testing.expect_value(t, len(fx.sink.bodies), 1)
}

// --- tests: age trigger (B) ---------------------------------------------------

// AC2. Injected timestamps, not sleeping: the young server is 23 hours old and the old
// one 25, against a one-day window.
@(test)
t9_age_reap_kills_old_and_spares_young :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_old",   started_at = STARTED_25H_AGO})
	fx9_seed(&fx, {session_id = "srv_young", started_at = STARTED_23H_AGO})

	reaped := shell_session_reap_aged_servers(&fx.svc, fx9_now_ms(), DAY_MS)

	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "srv_old"), NOW9)
	testing.expect_value(t, fx9_intent(&fx, "srv_young"), "")
}

// AC3, age half. The age sweep asks the repository for kind=server, so this is the case
// the query would not produce — which is exactly why the service check must exist
// independently rather than being delegated to the query.
@(test)
t9_age_reap_never_touches_a_run_or_a_shell :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	// Both far past the window. A run is deliberately seeded a week old: a run should be
	// bounded by its own 30-minute cap, and if that ever fails this reap must still not
	// be the thing that kills it.
	fx9_seed(&fx, {session_id = "run_old",   kind = domain.Shell_Session_Kind_Run,   started_at = "2026-09-22T12:00:00Z"})
	fx9_seed(&fx, {session_id = "shell_old", kind = domain.Shell_Session_Kind_Shell, started_at = "2026-09-22T12:00:00Z"})

	reaped := shell_session_reap_aged_servers(&fx.svc, fx9_now_ms(), DAY_MS)

	testing.expect_value(t, reaped, 0)
	testing.expect_value(t, fx9_intent(&fx, "run_old"), "")
	testing.expect_value(t, fx9_intent(&fx, "shell_old"), "")
	testing.expect_value(t, len(fx.sink.bodies), 0)

	// And asserted through the service's own gate as well, so a future rewrite of the
	// sweep that stopped passing kind=server would still be caught here.
	run_row, _ := fx.r.stored["run_old"]
	testing.expect(t, !_reap_kill_if_eligible(&fx.svc, run_row), "a run must never be reaped")
}

// --- tests: durability, idempotence, threshold -------------------------------

// AC4 — THE CRITERION THAT PROVES THE REQ-SHELL-3 DEPENDENCY IS REAL. The bridge is
// offline, so the send fails and nothing is delivered. What must survive is the INTENT on
// the row: that is what shell_session_replay_kill_intents redelivers on reconnect, and it
// is the whole reason this reap goes through the durable path instead of firing a command
// and forgetting it.
@(test)
t9_offline_bridge_still_records_the_intent :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx.sink.offline = true
	fx9_seed(&fx, {session_id = "srv_1", chain_id = "chain_a"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	// Reaped, and reported as such: the kill was ACCEPTED even though it was not
	// delivered. Reporting zero here would be the dishonest answer REQ-SHELL-3 removed.
	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
	// Nothing reached the bridge, which is the premise of the test rather than a defect.
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// AC5. Reaping runs repeatedly by construction — three chain close paths call it, and the
// age sweep runs every 20 seconds — so a second pass must be a no-op. Both halves are
// checked: no new kill is recorded, and nothing is re-dispatched.
@(test)
t9_repeated_sweeps_do_not_requeue :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_1",       chain_id = "chain_a"})
	// Already terminal, and already carrying a spent intent: neither may be touched.
	fx9_seed(&fx, {session_id = "srv_done",    chain_id = "chain_a", status = domain.Shell_Session_Status_Exited})
	// Already carrying a PENDING intent from an earlier pass.
	fx9_seed(&fx, {session_id = "srv_pending", chain_id = "chain_a", kill_at = "2026-09-29T11:00:00Z"})

	first := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")
	testing.expect_value(t, first, 1)
	sends_after_first := len(fx.sink.bodies)
	kills_after_first := fx.r.kill_calls

	second := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, second, 0)
	// No second dispatch. This is the point of the reap's skip rule differing from
	// shell_session_kill's: the accept path re-dispatches a pending intent on purpose
	// (a human asking twice means "try again"); a sweep repeating itself means nothing
	// new, and re-dispatching would turn one durable intent into a stream of failed
	// sends against an offline bridge.
	testing.expect_value(t, len(fx.sink.bodies), sends_after_first)
	testing.expect_value(t, fx.r.kill_calls, kills_after_first)
	// First-writer-wins: the original timestamp stands.
	testing.expect_value(t, fx9_intent(&fx, "srv_pending"), "2026-09-29T11:00:00Z")
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
}

// The threshold in isolation, with no repository, no clock and no session — the same
// treatment reaper_bridge_absence_is_terminal gets, and for the same reason: the age rule
// is the part that can be destructively wrong, so it is asserted directly rather than
// only through a sweep.
@(test)
t9_age_boundary_and_unparseable_timestamps :: proc(t: ^testing.T) {
	now := fx9_now_ms()

	testing.expect(t, shell_session_age_exceeds(STARTED_25H_AGO, now, DAY_MS), "25h old must be reapable")
	testing.expect(t, !shell_session_age_exceeds(STARTED_23H_AGO, now, DAY_MS), "23h old must not be")
	// Exactly on the boundary counts as old: the comparison is >=, and a server that has
	// run for precisely the maximum age has reached it.
	testing.expect(t, shell_session_age_exceeds("2026-09-28T12:00:00Z", now, DAY_MS), "exactly one day must be reapable")

	// EMPTY AND MALFORMED ARE "NOT OLD", NEVER "INFINITELY OLD". An empty started_at means
	// the hub has not been told the process began; treating it as ancient would kill the
	// YOUNGEST rows in the table, which is the destructive direction this whole design
	// avoids. Skipping mirrors reap_stale_instances and reaper_bridge_absence_is_terminal.
	testing.expect(t, !shell_session_age_exceeds("", now, DAY_MS), "empty started_at must be skipped")
	testing.expect(t, !shell_session_age_exceeds("not-a-timestamp", now, DAY_MS), "malformed started_at must be skipped")

	// Clock skew between hub and bridge must not manufacture age.
	testing.expect(t, !shell_session_age_exceeds("2026-09-30T12:00:00Z", now, DAY_MS), "a future started_at is not old")
}
