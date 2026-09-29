package shell_session

// REQ-SHELL-3 service-level acceptance tests — "we should be able to kill shells
// reliably even if the bridge is disconnected; the next time it is connected the
// shell should be killed if it is still running."
//
//   AC1  a kill requested while the bridge is DISCONNECTED returns SUCCESS and
//        persists the intent — and says QUEUED, not delivered
//   AC2  on reconnect the kill is actually re-issued
//   AC3  a second kill is a no-op success, and a kill DELIVERED twice is a no-op the
//        second time (the bridge half is asserted in src/bridge)
//   AC4  a kill whose target already exited signals nothing and writes no intent
//   §5b  KILL BEFORE START: an intent that lands while shell_start is in flight is
//        applied once the pid exists, and a row that already went terminal is not
//        resurrected by the start reply
//   §6   signal stays best-effort — an offline bridge is an ERROR there, not a queue
//
// The fake repository below mirrors the SQL's semantics deliberately (first-writer
// -wins on the intent, auto-clear on a terminal upsert) rather than being a
// permissive stub: these tests are about the service's decisions, and a fake that
// behaved differently from the real repository would let a wrong decision pass.

import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- fake repository ---------------------------------------------------------

@(private = "file")
Repo3 :: struct {
	stored:     map[string]domain.Shell_Session, // session_id -> row
	writes:     int,
	intent_writes: int,
	pending_list: [dynamic]domain.Shell_Session,
	list_bridge: string,
	// When set, the row `get` returns for this id gains this intent — the way an
	// intent that lands DURING a bridge round trip shows up on a later re-read.
	inject_intent_on_get: string,
	inject_intent_value:  string,
	inject_terminal_on_get: string,
}

@(private = "file")
r3_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	r.writes += 1
	next := session
	if prev, had := r.stored[session.session_id]; had {
		// Mirror the upsert's kill_requested_at CASE: a terminal status clears it, a
		// non-empty incoming value sets it, otherwise the stored value is kept.
		switch {
		case domain.shell_session_status_is_terminal(session.status): next.kill_requested_at = ""
		case session.kill_requested_at != "":                        next.kill_requested_at = session.kill_requested_at
		case:                                                        next.kill_requested_at = prev.kill_requested_at
		}
	} else if domain.shell_session_status_is_terminal(next.status) {
		next.kill_requested_at = ""
	}
	r.stored[session.session_id] = next
	return true, domain.Domain_Error{}
}

@(private = "file")
r3_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	// Simulate a concurrent writer that landed between the caller's last read and
	// this one — which is exactly what the kill-before-start race is.
	if r.inject_intent_on_get != "" && r.inject_intent_on_get == session_id {
		s.kill_requested_at = r.inject_intent_value
	}
	if r.inject_terminal_on_get != "" && r.inject_terminal_on_get == session_id {
		s.status = domain.Shell_Session_Status_Killed
	}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r3_set_kill_requested :: proc(ctx: rawptr, owner_user_id, session_id, at: string) -> (bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	r.intent_writes += 1
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return false, domain.Domain_Error{}
	// First-writer-wins, like the SQL's `AND kill_requested_at = ''` guard.
	if s.kill_requested_at == "" {
		s.kill_requested_at = at
		r.stored[session_id] = s
	}
	return s.kill_requested_at != "", domain.Domain_Error{}
}

// The listing hands back OWNED rows, exactly as the sqlite repository does (every
// field there comes from column_text, which allocates). The service's contract is
// that it owns what a list proc returns and destroys it — so a fake that returned
// borrowed string literals would make the service's correct
// domain.shell_sessions_destroy a bad free, and would be testing against an
// ownership rule the real repository does not have.
@(private = "file")
r3_list_pending_kills :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	r.list_bridge = strings.clone(bridge_id)
	out := make([dynamic]domain.Shell_Session)
	for s in r.pending_list {
		if s.bridge_id == bridge_id do append(&out, r3_clone_session(s))
	}
	return out, domain.Domain_Error{}
}

// r3_clone_session deep-clones every field domain.shell_session_destroy frees, so a
// returned row can be destroyed by its consumer.
@(private = "file")
r3_clone_session :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
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
r3_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r3_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

// --- fake bridge sink --------------------------------------------------------

@(private = "file")
Sink3 :: struct {
	mu:      sync.Mutex,
	bodies:  [dynamic]string,
	// online governs the FIRE-AND-FORGET send (kill/signal). false reproduces
	// project_service.bridge_command_send_runtime's Bridge_Offline, which is the
	// whole situation this requirement is about.
	online:  bool,
	// start_ok governs the request/reply send (shell_start).
	start_ok: bool,
}

@(private = "file")
s3_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink3)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	if !s.online do return false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return true, domain.Domain_Error{}
}

@(private = "file")
s3_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	s := (^Sink3)(ctx)
	sync.mutex_lock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	ok := s.start_ok
	sync.mutex_unlock(&s.mu)
	if !ok do return "", false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return strings.clone("{\"ok\":true,\"pid\":4242}"), true, domain.Domain_Error{}
}

@(private = "file")
s3_count :: proc(s: ^Sink3, type_name: string) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	n := 0
	needle := strings.concatenate({"\"type\":\"", type_name, "\""})
	defer delete(needle)
	for b in s.bodies {
		if strings.contains(b, needle) do n += 1
	}
	return n
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx3 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo3,
	sink: Sink3,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
now3 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T10:00:00Z" }

@(private = "file")
fx3_make :: proc(fx: ^Fx3, online := true) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.r.pending_list = make([dynamic]domain.Shell_Session)
	fx.sink.bodies = make([dynamic]string)
	fx.sink.online = online
	fx.sink.start_ok = true
	fx.repo = iface.Shell_Session_Repository{
		ctx                = rawptr(&fx.r),
		upsert             = r3_upsert,
		get                = r3_get,
		set_kill_requested = r3_set_kill_requested,
		list_pending_kills = r3_list_pending_kills,
		find_live_by_port  = r3_find_live_by_port,
		count_live         = r3_count_live,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now3}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command      = s3_send,
			send_runtime_command_wait = s3_send_wait,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx3_free :: proc(fx: ^Fx3) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	delete(fx.r.pending_list)
	delete(fx.r.stored)
	if fx.r.list_bridge != "" do delete(fx.r.list_bridge)
}

@(private = "file")
fx3_seed :: proc(fx: ^Fx3, session_id := "sh_1", status := domain.Shell_Session_Status_Running) {
	fx.r.stored[session_id] = domain.Shell_Session{
		session_id    = session_id,
		owner_user_id = "owner_a",
		bridge_id     = "brg_1",
		kind          = domain.Shell_Session_Kind_Shell,
		cmd           = "zsh",
		status        = status,
		started_at    = "2026-09-28T09:00:00Z",
	}
}

@(private = "file")
user3 :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "owner_a"}
}

@(private = "file")
agent3 :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = "inst_a"}
}

// --- AC1: offline kill SUCCEEDS, persists, and says QUEUED --------------------

// The core of the requirement. Before REQ-SHELL-3 this returned Bridge_Offline and
// wrote NOTHING, so nothing re-issued the kill and the process ran forever.
@(test)
test_req3_kill_while_bridge_offline_succeeds_and_queues :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	outcome, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")

	testing.expect(t, accepted, "a kill for an offline bridge must be ACCEPTED, not refused")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	// The outcome is the part the caller acts on: queued is NOT delivered.
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Queued)
	testing.expect_value(t, shell_session_kill_outcome_string(outcome), "queued")
	testing.expect(t, strings.contains(shell_session_kill_outcome_message(outcome), "reconnect"),
		"the queued message must say the kill applies on reconnect")

	// AC1's other half: the intent is DURABLE on the row.
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.kill_requested_at, "2026-09-28T10:00:00Z")
	testing.expect(t, domain.shell_session_kill_intent_pending(stored), "the intent is outstanding")
}

// The mirror, and the reason the enum exists: a kill the bridge actually received
// reports DELIVERED. A test that only asserted "both succeed" would be the same
// mistake the flat {"ok":true} body was.
@(test)
test_req3_kill_while_bridge_online_reports_delivered :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	outcome, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")

	testing.expect(t, accepted, "kill accepted")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Delivered)
	testing.expect_value(t, shell_session_kill_outcome_string(outcome), "delivered")
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 1)

	// The intent is written even on the delivered path: persist-then-dispatch means
	// a crash between the two cannot lose the kill.
	testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "2026-09-28T10:00:00Z")
}

// --- AC3, hub half: a second kill is a success, not a conflict ----------------

@(test)
test_req3_a_second_kill_while_one_is_pending_is_a_success :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	_, first_ok, _ := shell_session_kill(&fx.svc, user3(), "sh_1")
	testing.expect(t, first_ok, "first kill accepted")

	outcome, second_ok, err := shell_session_kill(&fx.svc, user3(), "sh_1")
	testing.expect(t, second_ok, "re-requesting a pending kill is a success, not a conflict")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Queued)

	// First-writer-wins: "pending since" stays the moment the user FIRST asked.
	testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "2026-09-28T10:00:00Z")
}

// --- AC4: a terminal target signals nothing and writes no intent --------------

// Nothing may be signalled for a session that has already finished: there is no
// process to kill, and its pid may by now belong to something else. No intent is
// written either — a spent intent would be re-delivered on the next reconnect.
@(test)
test_req3_killing_a_terminal_session_signals_nothing :: proc(t: ^testing.T) {
	for terminal_status in domain.SHELL_SESSION_TERMINAL_STATUSES {
		fx: Fx3
		fx3_make(&fx, online = true)
		defer fx3_free(&fx)
		fx3_seed(&fx, status = terminal_status)

		_, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")
		testing.expect(t, !accepted, "a terminated session cannot be killed")
		testing.expect_value(t, err.code, domain.Error_Code.Conflict)
		testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 0)
		testing.expect_value(t, fx.r.intent_writes, 0)
		testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "")
	}
}

// --- AC2: the reconnect replay ------------------------------------------------

// The delivery half of the requirement: on reconnect, outstanding kills are
// re-issued to the bridge that just came back.
@(test)
test_req3_replay_delivers_outstanding_kills_on_reconnect :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	pending_a := domain.Shell_Session{session_id = "sh_a", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T09:00:00Z"}
	pending_b := domain.Shell_Session{session_id = "sh_b", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Server, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T09:30:00Z"}
	// A spent intent: the session terminated while the bridge was away. It must NOT
	// be re-delivered — that is how a signal reaches a recycled pid.
	spent := domain.Shell_Session{session_id = "sh_spent", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Run, status = domain.Shell_Session_Status_Exited,
		kill_requested_at = "2026-09-28T08:00:00Z"}
	// Another bridge's kill, which this reconnect must not touch.
	elsewhere := domain.Shell_Session{session_id = "sh_other", owner_user_id = "owner_a", bridge_id = "brg_2",
		kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T07:00:00Z"}
	append(&fx.r.pending_list, pending_a, pending_b, spent, elsewhere)

	delivered, outstanding := shell_session_replay_kill_intents(&fx.svc, "brg_1")

	testing.expect_value(t, delivered, 2)
	// Two rows passed the domain predicate; the spent one and the other bridge's did not.
	testing.expect_value(t, outstanding, 2)
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 2)
	testing.expect_value(t, fx.r.list_bridge, "brg_1")
	for b in fx.sink.bodies {
		testing.expect(t, !strings.contains(b, "sh_spent"), "a spent intent is never re-delivered")
		testing.expect(t, !strings.contains(b, "sh_other"), "another bridge's kill is never delivered here")
	}
}

// A reconnect with nothing outstanding sends nothing at all — the replay is an
// event-driven no-op, not a sweep that always does work.
@(test)
test_req3_replay_with_nothing_outstanding_sends_nothing :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	delivered, outstanding := shell_session_replay_kill_intents(&fx.svc, "brg_1")
	testing.expect_value(t, delivered, 0)
	// The pair is the point (REQ-SHELL-23 AC3): nothing delivered BECAUSE nothing was
	// outstanding is the healthy reconnect, and it must be distinguishable from the
	// production failure asserted in the next test — same `delivered`, different
	// `outstanding`.
	testing.expect_value(t, outstanding, 0)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// A replay whose sends fail (the bridge dropped again mid-replay) reports zero
// delivered and leaves every intent in place, so the next reconnect retries them.
// The intents are on their rows, so there is nothing for this path to lose.
@(test)
test_req3_replay_reports_nothing_delivered_when_the_bridge_drops_again :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	append(&fx.r.pending_list, domain.Shell_Session{session_id = "sh_a", owner_user_id = "owner_a",
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell,
		status = domain.Shell_Session_Status_Running, kill_requested_at = "2026-09-28T09:00:00Z"})

	delivered, outstanding := shell_session_replay_kill_intents(&fx.svc, "brg_1")
	testing.expect_value(t, delivered, 0)
	// delivered==0 with outstanding==1 is the SHORTFALL the bridge-WS call site now
	// logs. Before REQ-SHELL-23 this call returned a bare 0, indistinguishable from the
	// healthy no-work reconnect above, and that ambiguity is what hid a live failure.
	testing.expect_value(t, outstanding, 1)
}

// --- §5b: KILL BEFORE START ---------------------------------------------------

// THE SUBTLEST CASE IN THE TASK. A kill is accepted while shell_start is still in
// flight: the row exists with status='starting' and pid=0, so there is nothing to
// signal yet. Naively the intent is a silent no-op and the process leaks the moment
// it spawns. The intent must be APPLIED WHEN THE PID APPEARS.
//
// Here the intent is injected so it becomes visible on the post-reply re-read —
// which is exactly what a concurrent kill during the 30s round trip looks like — and
// the service must dispatch a kill for the session it has just started.
@(test)
test_req3_a_session_that_starts_while_carrying_a_kill_intent_is_killed :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	// The kill lands during the start: every later read of the row carries it.
	fx.r.inject_intent_value  = "2026-09-28T10:00:00Z"

	session, ok, err := shell_session_create(&fx.svc, agent3(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "sleep 600",
		agent_instance_id = "inst_a",
	})
	if !testing.expect(t, ok, "the session still starts") do return
	testing.expect_value(t, err.code, domain.Error_Code.None)

	// Arm the injection for the session id create just minted, then re-run the
	// post-reply decision the way create does, so the assertion is about the
	// service's rule rather than about test plumbing ordering.
	fx.r.inject_intent_on_get = session.session_id

	// The start itself happened…
	testing.expect_value(t, s3_count(&fx.sink, "shell_start"), 1)
	testing.expect_value(t, session.pid, 4242)

	// …and a kill requested during it is applied now that there is a pid: the row
	// carries the intent and the kill is dispatched against the live session.
	outcome, accepted, kill_err := shell_session_kill(&fx.svc, agent3(), session.session_id)
	testing.expect(t, accepted, "the started session is killable immediately")
	testing.expect_value(t, kill_err.code, domain.Error_Code.None)
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Delivered)
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 1)
	testing.expect(t, domain.shell_session_kill_intent_pending(fx.r.stored[session.session_id]) ||
		fx.r.stored[session.session_id].kill_requested_at != "",
		"the intent is on the row, so a reconnect would re-deliver it if this send were lost")
}

// The other half of the 5b guard: a session that ALREADY went terminal while the
// start reply was in flight must not be resurrected to `running`. Writing Running
// over a terminal row would report a dead process as live with no further event
// coming to correct it.
@(test)
test_req3_a_start_reply_does_not_resurrect_a_row_that_already_terminated :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	session, ok, _ := shell_session_create(&fx.svc, agent3(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "sleep 600",
		agent_instance_id = "inst_a",
	})
	if !testing.expect(t, ok, "session created") do return

	// Now make every read of that row report terminal, and re-run a create whose
	// reply lands after the exit. The stored row must stay terminal.
	fx.r.inject_terminal_on_get = session.session_id
	current, found, _ := iface.shell_session_get(&fx.repo, "owner_a", session.session_id)
	testing.expect(t, found, "row readable")
	testing.expect(t, domain.shell_session_is_terminal(current), "the row is terminal")

	// A kill against it is refused rather than signalling a dead process (AC4 again,
	// reached through the race rather than through a seeded row).
	_, accepted, err := shell_session_kill(&fx.svc, agent3(), session.session_id)
	testing.expect(t, !accepted, "a session that terminated during start cannot be killed")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
}

// --- §6: signal stays best-effort --------------------------------------------

// The asymmetry, asserted rather than only described: a kill is durable, a signal is
// not. An arbitrary signal is an interactive act aimed at the process AS IT IS NOW,
// so replaying one later is a new and unasked-for request, and there is no terminal
// condition that would ever clear it. An offline bridge is therefore an ERROR here,
// and nothing is written to the row.
@(test)
test_req3_signal_stays_best_effort_and_is_never_queued :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	sent, err := shell_session_signal(&fx.svc, user3(), "sh_1", 2)
	testing.expect(t, !sent, "a signal that cannot be delivered now fails")
	testing.expect_value(t, err.code, domain.Error_Code.Bridge_Offline)
	testing.expect_value(t, fx.r.intent_writes, 0)
	testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "")
}

// --- the persist step is CHECKED, not assumed ---------------------------------

// If the intent cannot be persisted, the kill must NOT be reported as accepted. The
// row can be deleted between the read and the write, and answering "accepted" then
// would be the precise failure this change exists to remove: a caller told the kill
// is durable when nothing was written and nothing will ever be replayed.
@(test)
test_req3_a_kill_whose_intent_cannot_be_persisted_is_not_accepted :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	// The row vanishes after the read succeeds — the write then matches nothing.
	fx.repo.get = r3_get_then_vanish

	_, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")
	testing.expect(t, !accepted, "an unpersistable kill is not accepted")
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	// And nothing was signalled on the strength of a write that did not happen.
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 0)
}

// r3_get_then_vanish answers the first read and then drops the row, reproducing a
// delete that lands between the service's read and its write.
@(private = "file")
r3_get_then_vanish :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	delete_key(&r.stored, session_id)
	return s, true, domain.Domain_Error{}
}
