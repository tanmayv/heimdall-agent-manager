package shell_session

// REQ-SHELL-24 service-level acceptance tests: shell_session_restart carries the
// SAME starter/kind authorization as shell_session_start.
//
// A restart spawns a fresh OS process, so it is a start. Before this, restart
// checked ownership and nothing else — and ownership is the one check that can
// never catch this, because a user legitimately owns their own agent's run row.
// The result was a user-authenticated respawn of an agent-only `run`, with the UI
// verb gate (REQ-SHELL-6) as the only thing in the way.
//
// Every test here drives the SERVICE, not the REST handler, for the reason the
// start path's comment gives: the service is the layer every transport goes
// through, so a check asserted at the handler would prove nothing about the next
// caller added.

import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- fixture -----------------------------------------------------------------

@(private = "file")
Repo24 :: struct {
	stored: domain.Shell_Session,
	has:    bool,
	writes: int,
	last:   domain.Shell_Session,
}

@(private = "file")
r24_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo24)(ctx)
	r.stored = session
	r.last = session
	r.has = true
	r.writes += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
r24_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo24)(ctx)
	if r.has && r.stored.session_id == session_id && r.stored.owner_user_id == owner_user_id {
		return r.stored, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
Sink24 :: struct {
	mu:     sync.Mutex,
	bodies: [dynamic]string,
}

// The reply is a SUCCESSFUL respawn, so the permitted cases (AC3, AC4) genuinely
// travel the whole path — bridge send, ok-reply, row update — rather than passing
// for the unrelated reason that the fake bridge refused them.
@(private = "file")
s24_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Sink24)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return strings.clone("{\"ok\":true,\"pid\":4242}"), true, domain.Domain_Error{}
}

@(private = "file")
s24_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink24)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

@(private = "file")
now24 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-29T03:00:00Z" }

@(private = "file")
Fx24 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo24,
	sink: Sink24,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
fx24_make :: proc(fx: ^Fx24) {
	fx.sink.bodies = make([dynamic]string)
	fx.repo = iface.Shell_Session_Repository{
		ctx    = rawptr(&fx.r),
		upsert = r24_upsert,
		get    = r24_get,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now24}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = s24_send_wait,
			send_runtime_command      = s24_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx24_free :: proc(fx: ^Fx24) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
}

// seed installs a LIVE session of `kind` owned by owner_a, as the thing to restart.
// agent_instance_id is set for a run because that is how a real run row looks; the
// gate must not depend on it, which is the point of AC2 — the user owns this row.
@(private = "file")
fx24_seed :: proc(fx: ^Fx24, kind: string) {
	fx.r.stored = domain.Shell_Session{
		session_id        = "sh_1",
		owner_user_id     = "owner_a",
		bridge_id         = "brg_1",
		kind              = kind,
		status            = domain.Shell_Session_Status_Running,
		run_seq           = 0,
		agent_instance_id = "inst_a" if kind == domain.Shell_Session_Kind_Run else "",
	}
	fx.r.has = true
	fx.r.writes = 0
}

@(private = "file")
user24 :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "owner_a"}
}

@(private = "file")
agent24 :: proc(inst := "inst_a") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = inst}
}

// --- AC2: a user may not restart a run, and nothing is spawned ---------------

// THE DEFECT ITSELF. Note what makes it reachable: the row is owned by owner_a and
// the caller IS owner_a, so ownership — the only check restart used to perform —
// passes. The refusal has to come from the starter rule or not at all.
@(test)
test_req24_a_user_cannot_restart_a_run :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Run)

	_, ok, err := shell_session_restart(&fx.svc, user24(), "sh_1")

	testing.expect(t, !ok, "a user may not restart an agent-only run")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)

	// AC2's second half, asserted explicitly: a refusal that still delivered
	// shell_restart to the bridge would be WORSE than the bug being fixed — the
	// process would respawn while the API claimed it had refused.
	testing.expect_value(t, len(fx.sink.bodies), 0)
	// And nothing was persisted, so run_seq did not move either.
	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, fx.r.stored.run_seq, 0)
}

// --- AC3: an agent restarting its OWN run still works -----------------------

// The over-correction guard, and the reason the fix is a STARTER check rather than
// a ban on restarting runs: re-running is the agent's call.
@(test)
test_req24_an_agent_may_restart_its_own_run :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Run)

	session, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")

	testing.expect(t, ok, "an agent may restart its own run")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	// It really respawned: the bridge was asked, and the new run was adopted.
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect(t, strings.contains(fx.sink.bodies[0], "\"type\":\"shell_restart\""), "the bridge was sent shell_restart")
	testing.expect_value(t, session.run_seq, 1)
	testing.expect_value(t, fx.r.stored.run_seq, 1)
	testing.expect_value(t, session.pid, 4242)
}

// --- AC4: user restart of shell and server is UNAFFECTED --------------------

// A `shell` is a user's own interactive terminal. If this fails, the fix narrowed
// something it was told not to touch.
@(test)
test_req24_a_user_may_still_restart_a_shell :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Shell)

	session, ok, err := shell_session_restart(&fx.svc, user24(), "sh_1")

	testing.expect(t, ok, "a user may restart their own shell")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect_value(t, session.run_seq, 1)
}

// A `server` permits BOTH starters, so both must still be able to restart one.
// Covered in both directions because "server is startable by either" is the entry
// in the rules table an over-broad gate would silently take away.
@(test)
test_req24_a_user_may_still_restart_a_server :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Server)

	_, ok, err := shell_session_restart(&fx.svc, user24(), "sh_1")
	testing.expect(t, ok, "a user may restart a server")
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(test)
test_req24_an_agent_may_still_restart_a_server :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Server)

	_, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")
	testing.expect(t, ok, "an agent may restart a server")
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

// --- the mirror, and fail-closed -------------------------------------------

// The other half of the table: an agent may not start a `shell`, so it may not
// restart one either. This is not a case anyone reported — it is here so the gate
// is asserted as the TABLE it reads from rather than as a single run-shaped
// special case, which is how a rules-table change would slip past one-sided tests.
@(test)
test_req24_an_agent_cannot_restart_a_shell :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Shell)

	_, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")
	testing.expect(t, !ok, "an agent may not restart a user's interactive shell")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// A stored kind the hub cannot name FAILS CLOSED. Treating unknown as permitted
// would reintroduce this hole for exactly the rows that are already malformed.
@(test)
test_req24_an_unknown_stored_kind_cannot_be_restarted :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, "command") // a retired REQ-SHELL-1 spelling: parses as nothing

	_, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")
	testing.expect(t, !ok, "an unnameable kind is not restartable by anyone")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}
