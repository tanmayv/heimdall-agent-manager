package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import virtual "core:mem/virtual"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

// T4: reconfigure apply now|after_turn and POST .../reconfigurations/cancel,
// through the real service and SQLite repositories.

@(private = "file")
RDH_NOW :: "2026-11-26T12:00:00Z"

@(private = "file")
Rdh :: struct {
	db: sqlite.Conn,
	ai: sqlite.Agent_Repo_SQLite, bi: sqlite.Bridge_Repo_SQLite,
	pi: sqlite.Provider_Repo_SQLite, ci: sqlite.Content_Repo_SQLite,
	ar: iface.Agent_Repository, br: iface.Bridge_Repository,
	pr: iface.Provider_Repository, cr: iface.Content_Repository,
	registry: project_service.Bridge_Runtime_Registry,
	clock: platform.Clock, ids: platform.ID_Generator,
	users_repo: iface.User_Repository,
	users: user_service.User_Service,
	auth: auth_service.Auth_Service,
	service: agent_service.Agent_Service,
	handlers: Agent_Handlers,
	headers: []contracts.HTTP_Header,
	sent: int,
}

@(private = "file")
rdh_send :: proc(ctx: rawptr, _: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	(^Rdh)(ctx).sent += 1
	return true, {}
}

@(private = "file")
rdh_open :: proc(t: ^testing.T, h: ^Rdh) -> bool {
	db, ok, err := sqlite.open(":memory:")
	if !testing.expect(t, ok, err.message) do return false
	h.db = db
	migrated, merr := sqlite.run_migrations(&h.db)
	if !testing.expect(t, migrated, merr.message) do return false
	h.ar = sqlite.new_agent_repository(&h.ai, &h.db)
	h.br = sqlite.new_bridge_repository(&h.bi, &h.db)
	h.pr = sqlite.new_provider_repository(&h.pi, &h.db)
	h.cr = sqlite.new_content_repository(&h.ci, &h.db)
	h.clock = platform.real_clock()
	h.ids = http_test_id_generator()
	h.service = agent_service.new_agent_service_with_runtime(&h.ar, &h.br, nil, &h.cr, nil, {ctx = h, send_runtime_command = rdh_send}, &h.registry, &h.clock, &h.ids)
	h.service.providers = &h.pr
	h.users_repo = iface.User_Repository{get_by_id = proc(_: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
		return {user_id = id, name = string(id), status = .Active}, true, {}
	}}
	h.users = user_service.new_user_service_basic(&h.users_repo, &h.clock, &h.ids)
	h.auth = auth_service.new_auth_service({}, &h.users)
	h.headers = http_test_login(t, &h.auth, "owner")
	h.handlers = Agent_Handlers{auth = &h.auth, agents = &h.service}
	_, ok, err = iface.bridge_save_bridge(&h.br, {bridge_id = "brg", owner_user_id = "owner", status = .Online, capabilities_json = `{"features":["instance_reconfiguration_v1"]}`, created_at = RDH_NOW, updated_at = RDH_NOW})
	if !testing.expect(t, ok, err.message) do return false
	_, _, live := project_service.bridge_runtime_registry_accept_live(&h.registry, "brg", false, "", "owner")
	if !testing.expect(t, live) do return false
	_, ok, err = iface.agent_save(&h.ar, {agent_id = "agt", owner_user_id = "owner", name = "Worker", slug = "worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = RDH_NOW, updated_at = RDH_NOW})
	if !testing.expect(t, ok, err.message) do return false
	_, perr := iface.bridge_provider_status_upsert(&h.pr, {bridge_id = "brg", provider = "codex", binary_path = "/bin/codex", state = "present", checked_at = RDH_NOW})
	if !testing.expect_value(t, perr.code, domain.Error_Code.None) do return false
	_, perr = iface.bridge_provider_setting_upsert(&h.pr, {bridge_id = "brg", provider = "codex", enabled = true, updated_at = RDH_NOW})
	if !testing.expect_value(t, perr.code, domain.Error_Code.None) do return false
	_, ok, err = iface.agent_save_instance(&h.ar, {agent_instance_id = "inst", owner_user_id = "owner", agent_id = "agt", bridge_id = "brg", provider = "codex", provider_profile = "codex", model = "gpt-6.1-sol", conversation_id = "chat", runtime_status = "running", startup_status = "ready", activity_status = "busy", runtime_transport = "pty", launch_epoch = "launch_1", run_count = 1, created_at = RDH_NOW, updated_at = RDH_NOW})
	return testing.expect(t, ok, err.message)
}

@(private = "file")
rdh_close :: proc(h: ^Rdh) {
	auth_service.oidc_free(&h.auth)
	project_service.bridge_runtime_registry_destroy(&h.registry)
	sqlite.close(&h.db)
}

@(private = "file")
rdh_post :: proc(h: ^Rdh, key, extra: string) -> Response {
	body := strings.concatenate({`{"bridge_id":"brg","project_id":"","provider":"codex","provider_profile":"codex","model":"gpt-6.1-sol","permission_mode":"ask","expected_revision":0,"idempotency_key":"`, key, `"`, extra, `}`})
	return create_instance_reconfiguration_handler(&h.handlers, {method = "POST", path = "/api/v1/agent-instances/inst/reconfigurations", headers = h.headers, body = body, request_id = "rdh"})
}

@(private = "file")
rdh_cancel :: proc(h: ^Rdh, key: string, revision: int) -> Response {
	body := fmt.tprintf(`{{"idempotency_key":"%s","expected_operation_revision":%d}}`, key, revision)
	return cancel_instance_reconfiguration_handler(&h.handlers, {method = "POST", path = "/api/v1/agent-instances/inst/reconfigurations/cancel", headers = h.headers, body = body, request_id = "rdh"})
}

// Returns data.<field> of a success envelope as text (numbers formatted).
@(private = "file")
rdh_field :: proc(t: ^testing.T, body, field: string) -> string {
	value, err := json.parse_string(body, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil, body) do return "<invalid>"
	data, _ := value.(json.Object)["data"].(json.Object)
	#partial switch v in data[field] {
	case json.String: return string(v)
	case json.Integer: return fmt.tprintf("%d", v)
	case json.Float: return fmt.tprintf("%d", int(v))
	}
	return "<missing>"
}

@(private = "file")
rdh_run :: proc(t: ^testing.T, scenario: proc(t: ^testing.T, h: ^Rdh)) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	h := new(Rdh)
	if rdh_open(t, h) do scenario(t, h)
	rdh_close(h)
}

@(private = "file")
rdh_after_turn_cancel_and_restart_now :: proc(t: ^testing.T, h: ^Rdh) {
	r := rdh_post(h, "bad-apply", `,"apply":"later"`)
	testing.expect_value(t, r.status, 400)
	testing.expect(t, strings.contains(r.body, "apply must be"), r.body)
	// Busy instance: queued, nothing sent, waiting_since exposed.
	r = rdh_post(h, "queued", `,"apply":"after_turn"`)
	if !testing.expect_value(t, r.status, 202) do return
	testing.expect_value(t, rdh_field(t, r.body, "phase"), fmt.tprintf("%d", int(domain.Instance_Reconfiguration_Phase.Waiting_For_Idle)))
	testing.expect_value(t, rdh_field(t, r.body, "apply"), "after_turn")
	testing.expect(t, rdh_field(t, r.body, "waiting_since") != "", r.body)
	testing.expect_value(t, h.sent, 0)
	// The WS summary names the phase and carries waiting_since.
	op, _, _ := iface.instance_reconfiguration_get(&h.ar, "owner", "inst", "queued")
	summary := reconfiguration_summary_json(op)
	testing.expect(t, strings.contains(summary, `"phase":"waiting_for_idle"`) && strings.contains(summary, `"apply":"after_turn"`) && strings.contains(summary, fmt.tprintf(`"waiting_since":"%s"`, op.waiting_since)), summary)
	// Cancel: stale revision and other keys conflict; the matching one cancels.
	c := rdh_cancel(h, "queued", op.revision + 1)
	testing.expect_value(t, c.status, 409)
	c = rdh_cancel(h, "missing", 1)
	testing.expect_value(t, c.status, 404)
	c = rdh_cancel(h, "queued", op.revision)
	if !testing.expect_value(t, c.status, 200) do return
	testing.expect_value(t, rdh_field(t, c.body, "failure_code"), "cancelled")
	c = rdh_cancel(h, "queued", op.revision + 1)
	testing.expect_value(t, c.status, 409)
	// Restart now supersedes a queued operation; an omitted apply does not.
	r = rdh_post(h, "queued-2", `,"apply":"after_turn"`)
	testing.expect_value(t, r.status, 202)
	r = rdh_post(h, "implicit", "")
	testing.expect_value(t, r.status, 409)
	r = rdh_post(h, "restart-now", `,"apply":"now"`)
	if !testing.expect_value(t, r.status, 202) do return
	testing.expect_value(t, rdh_field(t, r.body, "phase"), fmt.tprintf("%d", int(domain.Instance_Reconfiguration_Phase.Stopping)))
	testing.expect_value(t, h.sent, 1)
	old, _, _ := iface.instance_reconfiguration_get(&h.ar, "owner", "inst", "queued-2")
	testing.expect_value(t, old.failure_code, "superseded")
	// Cancel is refused outside waiting_for_idle.
	now_op, _, _ := iface.instance_reconfiguration_get(&h.ar, "owner", "inst", "restart-now")
	c = rdh_cancel(h, "restart-now", now_op.revision)
	testing.expect_value(t, c.status, 409)
}

@(test)
test_reconfiguration_after_turn_cancel_and_restart_now_http :: proc(t: ^testing.T) {
	rdh_run(t, rdh_after_turn_cancel_and_restart_now)
}
