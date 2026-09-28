package shell_session

// REQ-SHELL-2 service-level acceptance tests:
//   §1   run is AGENT-ONLY and it is enforced at the API, not only in the UI (AC5).
//   §3   the one-way foreground -> background conversion (AC3's hub half).
//   §10  port conflicts are detected at create and refused (AC13).
//   §11  per-agent run and per-chain server caps (AC14).

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
Repo2 :: struct {
	last:        domain.Shell_Session,
	writes:      int,
	stored:      domain.Shell_Session,
	has_stored:  bool,
	port_holder: domain.Shell_Session,
	live_count:  int,
	count_kind:   string,
	count_column: string,
	count_value:  string,
	listed:      [dynamic]domain.Shell_Session,
}

@(private = "file")
r2_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	r.last = session
	r.stored = session
	r.has_stored = true
	r.writes += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
r2_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	if r.has_stored && r.stored.session_id == session_id && r.stored.owner_user_id == owner_user_id {
		return r.stored, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r2_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	if r.port_holder.session_id != "" && r.port_holder.server_port == server_port {
		return r.port_holder, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r2_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	r.count_kind   = kind
	r.count_column = scope_column
	r.count_value  = scope_value
	return r.live_count, domain.Domain_Error{}
}

@(private = "file")
r2_list_by_owner :: proc(ctx: rawptr, owner_user_id: string, filter: iface.Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for s in r.listed {
		if filter.agent_instance_id != "" && s.agent_instance_id != filter.agent_instance_id do continue
		append(&out, s)
	}
	return out, "", domain.Domain_Error{}
}

@(private = "file")
Fx2 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo2,
	sink: Sink2,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
Sink2 :: struct {
	mu:     sync.Mutex,
	bodies: [dynamic]string,
}

@(private = "file")
s2_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Sink2)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return "", false, domain.domain_error(.Bridge_Offline, "test sink")
}

@(private = "file")
s2_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink2)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

@(private = "file")
now2 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T09:00:00Z" }

@(private = "file")
fx2_make :: proc(fx: ^Fx2) {
	fx.r.listed = make([dynamic]domain.Shell_Session)
	fx.sink.bodies = make([dynamic]string)
	fx.repo = iface.Shell_Session_Repository{
		ctx               = rawptr(&fx.r),
		upsert            = r2_upsert,
		get               = r2_get,
		find_live_by_port = r2_find_live_by_port,
		count_live        = r2_count_live,
		list_by_owner     = r2_list_by_owner,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now2}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = s2_send_wait,
			send_runtime_command      = s2_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx2_free :: proc(fx: ^Fx2) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	delete(fx.r.listed)
}

@(private = "file")
user_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "owner_a"}
}

@(private = "file")
agent_auth :: proc(inst := "inst_a") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = inst}
}

// --- §1 / AC5: run is agent-only, enforced in the service --------------------

// AC5. A USER-authenticated caller attempting to create a kind=run session is
// rejected. Asserted at the SERVICE, deliberately: the requirement is that this
// is enforced at the API rather than only in the UI, and the service is the layer
// every transport goes through — a check that lived only in the REST handler
// would be bypassed by the next caller added.
@(test)
test_req2_a_user_cannot_start_a_run :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "echo hi",
		agent_instance_id = "inst_a",
	})
	testing.expect(t, !ok, "a user may not start a run")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	// Refused means nothing was written and the bridge was never asked to spawn.
	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// The mirror: an agent may not start a `shell`, which is a user's interactive
// terminal. Both directions come from one table, so neither can drift.
@(test)
test_req2_an_agent_cannot_start_a_shell :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, ok, err := shell_session_create(&fx.svc, agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})
	testing.expect(t, !ok, "an agent may not start an interactive shell")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
}

// A server is startable by BOTH, which is the explicit instruction not to build an
// agent-only variant.
@(test)
test_req2_a_server_may_be_started_by_either :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, _, user_err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, user_err.code != .Forbidden, "a user may start a server")

	_, _, agent_err := shell_session_create(&fx.svc, agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, agent_err.code != .Forbidden, "and so may an agent")
}

// An agent's run is attributed from its TOKEN, not from the body, so a run cannot
// be pinned on a different agent instance by asking.
@(test)
test_req2_a_run_is_attributed_from_the_token :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, agent_auth("inst_real"), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "echo hi",
		agent_instance_id = "inst_someone_else",
	})
	testing.expect_value(t, fx.r.last.agent_instance_id, "inst_real")
}

// --- §10 / AC13: port conflicts ---------------------------------------------

// AC13, same-owner branch: the conflict names the session holding the port,
// because the caller can act on that.
@(test)
test_req2_same_owner_port_conflict_names_the_holder :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.port_holder = domain.Shell_Session{
		session_id    = "sh_holder",
		owner_user_id = "owner_a",
		kind          = domain.Shell_Session_Kind_Server,
		server_port   = 8111,
		status        = domain.Shell_Session_Status_Running,
	}

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server,
		cmd = "serve", chain_id = "chain_1", server_port = 8111,
	})
	testing.expect(t, !ok, "the second server on the same port is refused")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "sh_holder"), "a same-owner conflict names the holder")
	testing.expect_value(t, fx.r.writes, 0)
}

// AC13, cross-owner branch. THE ASYMMETRY IS THE POINT and this test exists to
// keep it: the LOOKUP stays owner-unscoped (a port is a host resource, so the
// conflict is real and must be reported), but the ANSWER must not disclose
// another tenant's session id or kind, nor tell the caller to kill something they
// cannot touch.
@(test)
test_req2_cross_owner_port_conflict_discloses_nothing :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.port_holder = domain.Shell_Session{
		session_id    = "sh_other_tenant",
		owner_user_id = "owner_b",
		kind          = domain.Shell_Session_Kind_Server,
		server_port   = 8111,
		status        = domain.Shell_Session_Status_Running,
	}

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server,
		cmd = "serve", chain_id = "chain_1", server_port = 8111,
	})
	testing.expect(t, !ok, "the conflict is still reported across tenants")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	// The negatives are the substance of this test.
	testing.expect(t, !strings.contains(err.message, "sh_other_tenant"), "the other tenant's session id is NOT disclosed")
	testing.expect(t, !strings.contains(err.message, "owner_b"), "nor its owner")
	testing.expect(t, !strings.contains(err.message, "kill"), "and the caller is not told to kill what it cannot touch")
	testing.expect(t, strings.contains(err.message, "in use"), "but it is told the port is unavailable")
}

// A port nobody holds is not a conflict, and a session with no port asks nothing.
@(test)
test_req2_no_port_is_never_a_conflict :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.port_holder = domain.Shell_Session{
		session_id = "sh_holder", owner_user_id = "owner_a", server_port = 8111,
	}

	// AC11's second half: a serve with no --port starts fine.
	_, _, err := shell_session_create(&fx.svc, agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, err.code != .Conflict, "a server with no port exposes nothing and conflicts with nothing")
}

// --- §11 / AC14: caps --------------------------------------------------------

// AC14, runs. The cap is PER AGENT, which is the scope a run already has — the
// scope column the count narrows on is read from the domain rather than named
// here, so the cap cannot drift from the scope rule.
@(test)
test_req2_run_cap_is_per_agent :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = domain.SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT

	_, ok, err := shell_session_create(&fx.svc, agent_auth("inst_busy"), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Run, cmd = "echo hi",
	})
	testing.expect(t, !ok, "an over-cap run is refused")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "agent instance"), "the refusal names the scope the cap applies to")
	testing.expect_value(t, fx.r.writes, 0)

	// It counted LIVE sessions of this kind, narrowed by the agent column.
	testing.expect_value(t, fx.r.count_kind, domain.Shell_Session_Kind_Run)
	testing.expect_value(t, fx.r.count_column, "agent_instance_id")
	testing.expect_value(t, fx.r.count_value, "inst_busy")
}

// AC14, servers. Per CHAIN, again following that kind's own scope.
@(test)
test_req2_server_cap_is_per_chain :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = domain.SHELL_SESSION_MAX_LIVE_SERVERS_PER_CHAIN

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_busy",
	})
	testing.expect(t, !ok, "an over-cap server is refused")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "task chain"), "the refusal names the chain scope")
	testing.expect_value(t, fx.r.count_column, "chain_id")
	testing.expect_value(t, fx.r.count_value, "chain_busy")
}

// One below the cap still passes: the cap is a runaway backstop, not an off-by-one
// trap for a workflow sitting just under it.
@(test)
test_req2_just_under_the_cap_is_allowed :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = domain.SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT - 1

	_, _, err := shell_session_create(&fx.svc, agent_auth("inst_a"), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Run, cmd = "echo hi",
	})
	testing.expect(t, err.code != .Conflict, "the last run under the cap is allowed")
}

// A `shell` has no cap: it is opened by a person, one at a time, and there is no
// runaway shape to bound.
@(test)
test_req2_a_shell_has_no_cap :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = 10_000

	_, _, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell, cmd = "zsh",
	})
	testing.expect(t, err.code != .Conflict, "an interactive shell is not capped")
}

// --- §3 / AC3: the conversion, hub half --------------------------------------

@(private = "file")
seed_live_run :: proc(fx: ^Fx2, session_id := "sh_run_1", agent := "inst_a", background := false) {
	fx.r.stored = domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = "owner_a",
		bridge_id         = "brg_1",
		agent_instance_id = agent,
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "sleep 60",
		status            = domain.Shell_Session_Status_Running,
		background        = background,
	}
	fx.r.has_stored = true
	fx.r.writes = 0
}

// AC3, hub half: the conversion writes the row and asks the bridge to release the
// blocked caller. The bridge half (the caller actually being released with the
// session id) is asserted in the bridge suite.
@(test)
test_req2_background_conversion_persists_then_signals :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx)

	session, ok, err := shell_session_set_background(&fx.svc, user_auth(), "sh_run_1")
	testing.expect(t, ok, "a live foreground run can be backgrounded")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, session.background, "the returned session is background")
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect(t, fx.r.last.background, "and the ROW says so, so it survives a bridge restart")

	// The row is written BEFORE the bridge is told, so a bridge that never gets the
	// command still leaves a run the hub correctly calls background.
	sync.mutex_lock(&fx.sink.mu)
	defer sync.mutex_unlock(&fx.sink.mu)
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect(t, strings.contains(fx.sink.bodies[0], "shell_background"), "the bridge is asked to convert")
	testing.expect(t, strings.contains(fx.sink.bodies[0], "sh_run_1"), "naming the session")
}

// ONE-WAY. A run already background is refused, so a double-click cannot release
// a second waiter or re-arm a notification.
@(test)
test_req2_background_conversion_is_one_way :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, background = true)

	_, ok, err := shell_session_set_background(&fx.svc, user_auth(), "sh_run_1")
	testing.expect(t, !ok, "a run already in the background is not converted again")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect_value(t, fx.r.writes, 0)
}

// Only a RUN has a foreground form, so only a run can be backgrounded.
@(test)
test_req2_only_a_run_can_be_backgrounded :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx)
	fx.r.stored.kind = domain.Shell_Session_Kind_Server

	_, ok, err := shell_session_set_background(&fx.svc, user_auth(), "sh_run_1")
	testing.expect(t, !ok, "a server has no foreground form to convert from")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
}

// --- §9 / AC12: a foreground run whose agent goes unreachable ----------------

// AC12. The run must not stay a live untracked FOREGROUND run. It is CONVERTED,
// not killed — see shell_session_background_runs_for_agent for why: the signals
// that trigger this include a bridge-wide disconnect on which the agent processes
// are usually alive, so killing would destroy in-flight work on a transient blip.
@(test)
test_req2_unreachable_agent_backgrounds_its_foreground_runs :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, "sh_run_1", "inst_gone")
	append(&fx.r.listed, fx.r.stored)

	converted := shell_session_background_runs_for_agent(&fx.svc, "owner_a", "inst_gone")
	testing.expect_value(t, converted, 1)
	testing.expect(t, fx.r.last.background, "the stranded foreground run is now background")
	// Converted, NOT killed: it is still running, so it stays addressable, killable,
	// reapable and capped, and it now notifies on completion.
	testing.expect_value(t, fx.r.last.status, domain.Shell_Session_Status_Running)
}

// A run that is ALREADY background is left alone, so the returned count means
// "runs actually rescued" rather than counting no-ops.
@(test)
test_req2_unreachable_agent_skips_already_background_runs :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, "sh_run_1", "inst_gone", background = true)
	append(&fx.r.listed, fx.r.stored)

	testing.expect_value(t, shell_session_background_runs_for_agent(&fx.svc, "owner_a", "inst_gone"), 0)
	testing.expect_value(t, fx.r.writes, 0)
}

// Another agent's runs are untouched: the hook is scoped to the instance that
// actually went away.
@(test)
test_req2_unreachable_agent_does_not_touch_other_agents_runs :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, "sh_run_1", "inst_healthy")
	append(&fx.r.listed, fx.r.stored)

	testing.expect_value(t, shell_session_background_runs_for_agent(&fx.svc, "owner_a", "inst_gone"), 0)
	testing.expect_value(t, fx.r.writes, 0)
}
