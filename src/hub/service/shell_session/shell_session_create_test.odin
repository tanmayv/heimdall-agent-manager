package shell_session

// REQ-SHELL-1 service-level acceptance tests:
//   §8    ONE CLOCK — the hub-assigned started_at is what the row stores AND what
//         the bridge is told to store, so a skewed bridge clock changes nothing.
//   §5    per-kind scope is enforced on create, not silently stored.
//   §1    the retired kind spellings are rejected rather than aliased.

import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- fakes -------------------------------------------------------------------

@(private = "file")
Fake_Repo :: struct {
	last:   domain.Shell_Session,
	writes: int,
	// Canned answers for the two REQ-SHELL-2 create-time checks.
	port_holder:       domain.Shell_Session,
	live_count:        int,
	last_count_kind:   string,
	last_count_column: string,
	last_count_value:  string,
}

@(private = "file")
fake_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	f.last = session
	f.writes += 1
	return true, domain.Domain_Error{}
}

// REQ-SHELL-2 added two repository questions that create now asks before it
// writes anything: "is this port already held on this bridge?" and "is this agent
// or chain already at its live-session cap?". A fake that answers neither makes
// every create fail as misconfigured, so both are wired here.
//
// The defaults are the permissive answers — no holder, nothing live — so these
// tests keep testing what they were written to test. The cap and conflict
// behaviour has its own tests, which set the counters.
@(private = "file")
fake_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	if f.port_holder.session_id != "" && f.port_holder.server_port == server_port {
		return f.port_holder, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
fake_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	f.last_count_kind   = kind
	f.last_count_column = scope_column
	f.last_count_value  = scope_value
	return f.live_count, domain.Domain_Error{}
}

@(private = "file")
fake_repo :: proc(f: ^Fake_Repo) -> iface.Shell_Session_Repository {
	return iface.Shell_Session_Repository{
		ctx               = rawptr(f),
		upsert            = fake_upsert,
		find_live_by_port = fake_find_live_by_port,
		count_live        = fake_count_live,
	}
}

// A clock frozen at a known instant, so the test can assert on the exact value
// rather than on "something timestamp-shaped".
@(private = "file")
FROZEN_NOW :: "2026-09-28T08:00:00Z"

@(private = "file")
frozen_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	return FROZEN_NOW
}

@(private = "file")
Fake_Sink :: struct {
	mu:        sync.Mutex,
	last_body: string,
	sends:     int,
}

// Records the dispatched spec and answers "not ok". create() then marks the row
// failed, which is irrelevant here — the spec has already been built and handed
// to the sink, which is the thing under test.
@(private = "file")
fake_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Fake_Sink)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	delete(s.last_body)
	s.last_body = strings.clone(command.body_json)
	s.sends += 1
	return "", false, domain.domain_error(.Bridge_Offline, "test sink")
}

@(private = "file")
Fixture :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	f:    Fake_Repo,
	sink: Fake_Sink,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
fixture_make :: proc(fx: ^Fixture) {
	fx.repo = fake_repo(&fx.f)
	fx.ids  = platform.real_id_generator()
	fx.clk  = platform.Clock{ctx = nil, now = frozen_now}
	fx.svc  = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = fake_send_wait,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fixture_free :: proc(fx: ^Fixture) {
	shell_session_service_free(&fx.svc)
	delete(fx.sink.last_body)
}

@(private = "file")
test_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "user_clock"}
}

// REQ-SHELL-2 §1 made the STARTER part of create: a `run` is agent-only and a
// `shell` is user-only, decided from the auth KIND (an Instance_Token is an
// agent). Tests that want to reach scope validation for a run must therefore
// present an agent, or they are refused earlier, for a different reason.
@(private = "file")
test_agent_auth :: proc(instance_id := "") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "user_clock", agent_instance_id = instance_id}
}

// --- §8: one clock -----------------------------------------------------------

@(test)
test_shell_session_create_sends_the_hub_started_at_to_the_bridge :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})

	// The row carries the hub clock's value...
	testing.expect_value(t, fx.f.last.started_at, FROZEN_NOW)

	// ...and so does the spec the bridge is asked to spawn from. Two stamps for one
	// fact was the bug: the hub-side 1-day server reap and the bridge-side output
	// retention window read started_at from different clocks, so skew made them
	// disagree about the same session's age. They now read the same string.
	sync.mutex_lock(&fx.sink.mu)
	body := strings.clone(fx.sink.last_body, context.temp_allocator)
	sends := fx.sink.sends
	sync.mutex_unlock(&fx.sink.mu)

	testing.expect_value(t, sends, 1)
	testing.expect(t, strings.contains(body, "\"started_at\":\"" + FROZEN_NOW + "\""), "shell_start spec carries the hub-assigned started_at")
}

// --- §5: scope enforced on create --------------------------------------------

@(test)
test_shell_session_create_rejects_a_kind_missing_its_scope :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	// run is AGENT scoped, so a run with no agent_instance_id has no scope at all.
	//
	// Started BY AN AGENT WITH NO INSTANCE ID ON ITS TOKEN, deliberately: a run from
	// a user is refused by the starter rule before scope is ever reached, and an
	// agent whose token names an instance has that instance filled in for it. This
	// is the one shape that still reaches the scope check, which is what is under
	// test here.
	_, ok, err := shell_session_create(&fx.svc, test_agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Run,
		cmd       = "echo hi",
	})
	testing.expect(t, !ok, "a run without an agent_instance_id is rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)

	// server is CHAIN + BRIDGE scoped.
	_, ok2, err2 := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Server,
		cmd       = "serve",
	})
	testing.expect(t, !ok2, "a server without a chain_id is rejected")
	testing.expect_value(t, err2.code, domain.Error_Code.Validation_Failed)

	// Rejected means NOT STORED and never dispatched — not stored-then-complained-about.
	testing.expect_value(t, fx.f.writes, 0)
	testing.expect_value(t, fx.sink.sends, 0)
}

@(test)
test_shell_session_create_rejects_scope_columns_a_kind_does_not_use :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	// shell is BRIDGE scoped; chain and agent must be left empty rather than
	// filled with noise that later reads would treat as real scope.
	_, ok, err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
		chain_id  = "chain_1",
	})
	testing.expect(t, !ok, "a shell carrying a chain_id is rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)

	_, ok2, _ := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Server,
		cmd               = "serve",
		chain_id          = "chain_1",
		agent_instance_id = "inst_1",
	})
	testing.expect(t, !ok2, "a server carrying an agent_instance_id is rejected")
	testing.expect_value(t, fx.f.writes, 0)
}

@(test)
test_shell_session_create_accepts_each_kind_with_its_own_scope :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	// Each of the three, scoped per the rules. The sink answers not-ok, so create
	// returns false — what is asserted here is that it got PAST validation, which
	// the write count shows.
	// Each kind is presented by a starter allowed to start it (REQ-SHELL-2 §1):
	// run by an agent, shell by a user, server by either.
	_, _, run_err := shell_session_create(&fx.svc, test_agent_auth("inst_1"), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Run,
		cmd = "echo hi", agent_instance_id = "inst_1",
	})
	testing.expect(t, run_err.code != .Validation_Failed, "an agent-scoped run passes validation")
	testing.expect(t, run_err.code != .Forbidden, "an agent may start a run")

	_, _, shell_err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell, cmd = "zsh",
	})
	testing.expect(t, shell_err.code != .Validation_Failed, "a bridge-scoped shell passes validation")

	_, _, server_err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server,
		cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, server_err.code != .Validation_Failed, "a chain+bridge-scoped server passes validation")

	testing.expect_value(t, fx.sink.sends, 3)
}

// --- §1: the retired vocabulary is gone, not aliased -------------------------

@(test)
test_shell_session_create_rejects_retired_kind_spellings :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	for retired in ([]string{"command", "interactive", "agent"}) {
		_, ok, err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
			bridge_id = "brg_1",
			kind      = retired,
			cmd       = "echo hi",
		})
		testing.expect(t, !ok, "a retired kind spelling is rejected")
		testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	}
	testing.expect_value(t, fx.f.writes, 0)
}

// An omitted kind defaults to `shell`, and never to a retired spelling.
//
// CHANGED BY REQ-SHELL-2 (N3). It used to default to `run`, which no user can
// legitimately start: scope validation then refused with "agent_instance_id is
// required for kind run", telling a plain REST caller about an agent field it had
// never mentioned, for a kind it could never have meant. `shell` is the kind a
// person opening a session means, and is what ham-ctl has always defaulted to.
//
// It cannot break a caller that worked before, because every existing caller
// sends an explicit kind — so nothing is silently re-pointed at a different kind
// by this default, it only replaces a guaranteed error with a useful one.
@(test)
test_shell_session_create_defaults_kind_to_shell :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		cmd       = "zsh",
	})
	testing.expect_value(t, fx.f.last.kind, domain.Shell_Session_Kind_Shell)
}

// The other half of N3: an AGENT that omits kind gets a refusal naming the kinds
// it can actually start, rather than the old scope error about a column.
@(test)
test_shell_session_create_agent_omitting_kind_is_told_what_it_may_start :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, ok, err := shell_session_create(&fx.svc, test_agent_auth("inst_1"), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		cmd       = "echo hi",
	})
	testing.expect(t, !ok, "an agent cannot start the defaulted shell kind")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect(t, strings.contains(err.message, "user"), "the refusal names who may start a shell")
	testing.expect_value(t, fx.f.writes, 0)
}

// --- REQ-SHELL-ENC-7: enc_spec forwarding ------------------------------------

@(test)
test_shell_session_create_forwards_enc_spec_to_the_bridge :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	TEST_ENC_SPEC :: "vault:v1:test_armored_ciphertext_spec"
	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
		enc_spec  = TEST_ENC_SPEC,
	})

	sync.mutex_lock(&fx.sink.mu)
	body := strings.clone(fx.sink.last_body, context.temp_allocator)
	sends := fx.sink.sends
	sync.mutex_unlock(&fx.sink.mu)

	testing.expect_value(t, sends, 1)
	testing.expect(t, strings.contains(body, "\"enc_spec\":\"" + TEST_ENC_SPEC + "\""), "shell_start spec carries enc_spec")
}

@(test)
test_shell_session_create_omits_enc_spec_when_empty :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})

	sync.mutex_lock(&fx.sink.mu)
	body := strings.clone(fx.sink.last_body, context.temp_allocator)
	sends := fx.sink.sends
	sync.mutex_unlock(&fx.sink.mu)

	testing.expect_value(t, sends, 1)
	testing.expect(t, !strings.contains(body, "\"enc_spec\":"), "shell_start spec omits enc_spec when empty")
}

