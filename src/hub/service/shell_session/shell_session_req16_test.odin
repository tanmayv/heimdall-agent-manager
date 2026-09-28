package shell_session

// REQ-SHELL-16 service-level regression tests. Both defects these cover were
// INVISIBLE rather than incorrect, which is why they survived: the code did the
// right thing to the row and simply failed to record why, so no assertion anywhere
// had reason to look.
//
//   D1b  a bridge refusal arrives carrying the bridge's own reason, instead of
//        being replaced by a constant while `reply` still held it.
//   D2   a start failure is a TERMINAL row and must carry a finish time. One row
//        in production (sh_18d97f993089313f) was terminal with finished_at empty,
//        which silently excluded it from anything reasoning over terminal rows.
//
// The third assertion in each case — that exit_code_set stays false — is not
// incidental. domain/shell_session.odin:356-392 names shell_session_create's
// failure path as a SYNTHESIZED terminal and makes it an invariant that such a
// path never sets exit_code_set, because shell_session_terminal_is_observed uses
// it as the discriminator between a guess and an observation. A future change
// that "helpfully" stamps exit_code 1 here would break bridge supersession with
// no other test failing, so it is pinned here.

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
R16_Repo :: struct {
	last:   domain.Shell_Session,
	writes: int,
}

@(private = "file")
r16_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	f := (^R16_Repo)(ctx)
	f.last = session
	f.writes += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
r16_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r16_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

@(private = "file")
r16_repo :: proc(f: ^R16_Repo) -> iface.Shell_Session_Repository {
	return iface.Shell_Session_Repository{
		ctx               = rawptr(f),
		upsert            = r16_upsert,
		find_live_by_port = r16_find_live_by_port,
		count_live        = r16_count_live,
	}
}

@(private = "file")
R16_NOW :: "2026-09-28T09:00:00Z"

@(private = "file")
r16_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	return R16_NOW
}

// Unlike the create-test sink, this one ANSWERS. The reply it returns is the whole
// point: the D1b defect was that a well-formed `ok:false` reply carrying a reason
// reached the hub and the reason was dropped, so a sink that merely reports
// transport failure cannot reach the code under test at all.
@(private = "file")
R16_Sink :: struct {
	mu:         sync.Mutex,
	reply:      string, // canned bridge reply, returned verbatim
	reply_ok:   bool,   // false = transport/offline branch instead
	sends:      int,
}

@(private = "file")
r16_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	_ = command
	s := (^R16_Sink)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	s.sends += 1
	if !s.reply_ok do return "", false, domain.domain_error(.Bridge_Offline, "test sink offline")
	// create() takes ownership of the reply and deletes it, so hand over a clone.
	return strings.clone(s.reply), true, domain.Domain_Error{}
}

@(private = "file")
R16_Fixture :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	f:    R16_Repo,
	sink: R16_Sink,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
r16_fixture_make :: proc(fx: ^R16_Fixture, reply: string, reply_ok := true) {
	fx.repo         = r16_repo(&fx.f)
	fx.ids          = platform.real_id_generator()
	fx.clk          = platform.Clock{ctx = nil, now = r16_now}
	fx.sink.reply   = reply
	fx.sink.reply_ok = reply_ok
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = r16_send_wait,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
r16_fixture_free :: proc(fx: ^R16_Fixture) {
	shell_session_service_free(&fx.svc)
}

@(private = "file")
r16_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "user_r16"}
}

@(private = "file")
r16_create :: proc(fx: ^R16_Fixture) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return shell_session_create(&fx.svc, r16_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_r16",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})
}

// --- D1b: the bridge's reason survives ---------------------------------------

@(test)
test_req16_start_failure_surfaces_the_bridge_reason :: proc(t: ^testing.T) {
	fx: R16_Fixture
	r16_fixture_make(&fx, `{"type":"shell_start_result","ok":false,"error":"daemon unavailable"}`)
	defer r16_fixture_free(&fx)

	_, ok, err := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")

	// The specific reason is the whole point: "daemon unavailable" is one of the four
	// bridge rejection reasons, and before this it was replaced by a constant that
	// made all four indistinguishable.
	testing.expect(
		t,
		strings.contains(err.message, "daemon unavailable"),
		"the bridge's reason must reach the caller",
	)
	// The generic text is kept as context rather than replaced, so existing callers
	// and logs still match on it.
	testing.expect(
		t,
		strings.contains(err.message, "bridge failed to start shell session"),
		"the generic context must be kept alongside the reason",
	)
}

@(test)
test_req16_start_failure_without_a_reason_falls_back_to_the_constant :: proc(t: ^testing.T) {
	fx: R16_Fixture
	// No `error` field at all. This is also the case that made the unconditional
	// delete in the old set_server_port branch a bad free: _json_str returns a
	// non-allocated "" literal here.
	r16_fixture_make(&fx, `{"type":"shell_start_result","ok":false}`)
	defer r16_fixture_free(&fx)

	_, ok, err := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")
	testing.expect_value(t, err.message, "bridge failed to start shell session")
}

// --- D2: a terminal row carries a finish time --------------------------------

@(test)
test_req16_start_failure_stamps_finished_at :: proc(t: ^testing.T) {
	fx: R16_Fixture
	r16_fixture_make(&fx, `{"type":"shell_start_result","ok":false,"error":"spawn failed"}`)
	defer r16_fixture_free(&fx)

	_, ok, _ := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")

	testing.expect_value(t, fx.f.last.status, domain.Shell_Session_Status_Failed)
	testing.expect_value(t, fx.f.last.finished_at, R16_NOW)

	// The invariant from domain/shell_session.odin:356-392: a synthesized terminal
	// must not claim to have observed an exit.
	testing.expect(t, !fx.f.last.exit_code_set, "a synthesized terminal must not set exit_code_set")
	testing.expect(
		t,
		!domain.shell_session_terminal_is_observed(fx.f.last),
		"a start failure must not be classified as an observed terminal",
	)
}

@(test)
test_req16_offline_bridge_start_failure_also_stamps_finished_at :: proc(t: ^testing.T) {
	fx: R16_Fixture
	// The OTHER failure branch: the bridge never answered at all. It was equally
	// unstamped, and is the branch the production row most likely came through.
	r16_fixture_make(&fx, "", reply_ok = false)
	defer r16_fixture_free(&fx)

	_, ok, _ := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")

	testing.expect_value(t, fx.f.last.status, domain.Shell_Session_Status_Failed)
	testing.expect_value(t, fx.f.last.finished_at, R16_NOW)
	testing.expect(t, !fx.f.last.exit_code_set, "a synthesized terminal must not set exit_code_set")
}
