package http

import "core:encoding/json"
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

// POST /api/v1/agent-instances/{id}/reconfigurations with runtime_transport
// (agent settings panel T1), through the real service and SQLite repositories.

@(private = "file")
RTH_NOW :: "2026-11-26T12:00:00Z"
@(private = "file")
RTH_READY :: `{"installed":true,"state":"ready","version":"0.162.0","runtime_kind":"system","checked_at":"now"}`

@(private = "file")
Rth :: struct {
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
}

@(private = "file")
rth_send :: proc(_: rawptr, _: project_service.Runtime_Command) -> (bool, domain.Domain_Error) { return true, {} }

@(private = "file")
rth_sql :: proc(t: ^testing.T, h: ^Rth, sql: string) { testing.expect(t, sqlite.exec(&h.db, sql), sql) }

@(private = "file")
rth_adapter :: proc(t: ^testing.T, h: ^Rth, adapter_json: string) {
	_, err := iface.bridge_provider_status_upsert(&h.pr, {bridge_id = "brg", provider = "codex", binary_path = "/bin/codex", state = "present", checked_at = RTH_NOW, acp_adapter_json = adapter_json})
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(private = "file")
rth_open :: proc(t: ^testing.T, h: ^Rth) -> bool {
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
	h.service = agent_service.new_agent_service_with_runtime(&h.ar, &h.br, nil, &h.cr, nil, {ctx = h, send_runtime_command = rth_send}, &h.registry, &h.clock, &h.ids)
	h.service.providers = &h.pr
	h.users_repo = iface.User_Repository{get_by_id = proc(_: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
		return {user_id = id, name = string(id), status = .Active}, true, {}
	}}
	h.users = user_service.new_user_service_basic(&h.users_repo, &h.clock, &h.ids)
	h.auth = auth_service.new_auth_service({}, &h.users)
	h.headers = http_test_login(t, &h.auth, "owner")
	h.handlers = Agent_Handlers{auth = &h.auth, agents = &h.service}
	_, ok, err = iface.bridge_save_bridge(&h.br, {bridge_id = "brg", owner_user_id = "owner", status = .Online, capabilities_json = `{"features":["instance_reconfiguration_v1","acp_runtime_v1"]}`, created_at = RTH_NOW, updated_at = RTH_NOW})
	if !testing.expect(t, ok, err.message) do return false
	_, _, live := project_service.bridge_runtime_registry_accept_live(&h.registry, "brg", false, "", "owner")
	if !testing.expect(t, live) do return false
	_, ok, err = iface.agent_save(&h.ar, {agent_id = "agt", owner_user_id = "owner", name = "Worker", slug = "worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = RTH_NOW, updated_at = RTH_NOW})
	if !testing.expect(t, ok, err.message) do return false
	_, perr := iface.bridge_provider_status_upsert(&h.pr, {bridge_id = "brg", provider = "codex", binary_path = "/bin/codex", state = "present", checked_at = RTH_NOW, acp_adapter_json = RTH_READY})
	if !testing.expect_value(t, perr.code, domain.Error_Code.None) do return false
	_, perr = iface.bridge_provider_setting_upsert(&h.pr, {bridge_id = "brg", provider = "codex", enabled = true, updated_at = RTH_NOW})
	if !testing.expect_value(t, perr.code, domain.Error_Code.None) do return false
	_, ok, err = iface.agent_save_instance(&h.ar, {agent_instance_id = "inst", owner_user_id = "owner", agent_id = "agt", bridge_id = "brg", provider = "codex", provider_profile = "codex", model = "gpt-6.1-sol", conversation_id = "chat", runtime_status = "running", startup_status = "ready", activity_status = "idle", runtime_transport = "pty", run_count = 1, created_at = RTH_NOW, updated_at = RTH_NOW})
	return testing.expect(t, ok, err.message)
}

@(private = "file")
rth_close :: proc(h: ^Rth) {
	auth_service.oidc_free(&h.auth)
	project_service.bridge_runtime_registry_destroy(&h.registry)
	sqlite.close(&h.db)
}

@(private = "file")
rth_post :: proc(h: ^Rth, key, extra: string) -> Response {
	body := strings.concatenate({`{"bridge_id":"brg","project_id":"","provider":"codex","provider_profile":"codex","model":"gpt-6.1-sol","expected_revision":0,"idempotency_key":"`, key, `"`, extra, `}`})
	return create_instance_reconfiguration_handler(&h.handlers, {method = "POST", path = "/api/v1/agent-instances/inst/reconfigurations", headers = h.headers, body = body, request_id = "rth"})
}

// Returns data.destination.<field> from a 202 reconfiguration response.
@(private = "file")
rth_destination :: proc(t: ^testing.T, body, field: string) -> string {
	value, err := json.parse_string(body, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil, body) do return "<invalid>"
	data, _ := value.(json.Object)["data"].(json.Object)
	destination, _ := data["destination"].(json.Object)
	text, _ := destination[field].(json.String)
	return string(text)
}

@(private = "file")
rth_run :: proc(t: ^testing.T, scenario: proc(t: ^testing.T, h: ^Rth)) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	h := new(Rth)
	if rth_open(t, h) do scenario(t, h)
	rth_close(h)
}

@(private = "file")
rth_refusals_then_pty :: proc(t: ^testing.T, h: ^Rth) {
	// Unknown keys are still rejected; runtime_transport is the new optional one.
	r := rth_post(h, "bad-key", `,"transport":"acp"`)
	testing.expect_value(t, r.status, 400)
	r = rth_post(h, "bad-value", `,"runtime_transport":"ssh"`)
	testing.expect_value(t, r.status, 422)
	testing.expect(t, strings.contains(r.body, `"code":"invalid_transport"`), r.body)
	// Bridge without acp_runtime_v1: acp_unavailable with details.state.
	rth_sql(t, h, `UPDATE bridges SET capabilities_json='{"features":["instance_reconfiguration_v1"]}';`)
	r = rth_post(h, "no-acp-bridge", `,"runtime_transport":"acp"`)
	testing.expect_value(t, r.status, 409)
	testing.expect(t, strings.contains(r.body, `"code":"acp_unavailable"`), r.body)
	testing.expect(t, strings.contains(r.body, `"state":"unsupported_bridge"`), r.body)
	// Adapter not ready: acp_unavailable with the adapter state.
	rth_sql(t, h, `UPDATE bridges SET capabilities_json='{"features":["instance_reconfiguration_v1","acp_runtime_v1"]}';`)
	rth_adapter(t, h, `{"installed":false,"state":"missing","checked_at":"now"}`)
	r = rth_post(h, "adapter-missing", `,"runtime_transport":"acp"`)
	testing.expect_value(t, r.status, 409)
	testing.expect(t, strings.contains(r.body, `"code":"acp_unavailable"`) && strings.contains(r.body, `"state":"missing"`), r.body)
	rth_adapter(t, h, `{"installed":false,"state":"installing","checked_at":"now"}`)
	r = rth_post(h, "adapter-installing", `,"runtime_transport":"acp"`)
	testing.expect_value(t, r.status, 409)
	testing.expect(t, strings.contains(r.body, `"code":"acp_installing"`), r.body)
	// No refusal persisted an operation.
	for key in ([]string{"bad-key", "bad-value", "no-acp-bridge", "adapter-missing", "adapter-installing"}) {
		_, found, _ := iface.instance_reconfiguration_get(&h.ar, "owner", "inst", key)
		testing.expectf(t, !found, "%s persisted nothing", key)
	}
	// PTY is accepted and frozen in the destination snapshot.
	r = rth_post(h, "pin-pty", `,"runtime_transport":"pty"`)
	if !testing.expect_value(t, r.status, 202) do return
	testing.expect_value(t, rth_destination(t, r.body, "runtime_transport"), "pty")
	testing.expect_value(t, rth_destination(t, r.body, "runtime_transport_override"), "pty")
	// Idempotent replay returns the same operation; another transport conflicts.
	replay := rth_post(h, "pin-pty", `,"runtime_transport":"pty"`)
	testing.expect_value(t, replay.status, 202)
	testing.expect_value(t, rth_destination(t, replay.body, "runtime_transport_override"), "pty")
	conflict := rth_post(h, "pin-pty", `,"runtime_transport":"acp"`)
	testing.expect_value(t, conflict.status, 409)
	testing.expect(t, strings.contains(conflict.body, "idempotency key"), conflict.body)
}

@(private = "file")
rth_acp :: proc(t: ^testing.T, h: ^Rth) {
	r := rth_post(h, "pin-acp", `,"runtime_transport":"acp"`)
	if !testing.expect_value(t, r.status, 202) do return
	testing.expect_value(t, rth_destination(t, r.body, "runtime_transport"), "acp")
	testing.expect_value(t, rth_destination(t, r.body, "runtime_transport_override"), "acp")
}

@(private = "file")
rth_omitted :: proc(t: ^testing.T, h: ^Rth) {
	// Omitted: the bridge-provider setting decides, nothing is pinned.
	rth_sql(t, h, "UPDATE bridge_provider_settings SET transport='acp';")
	r := rth_post(h, "omitted", "")
	if !testing.expect_value(t, r.status, 202) do return
	testing.expect_value(t, rth_destination(t, r.body, "runtime_transport"), "acp")
	testing.expect_value(t, rth_destination(t, r.body, "runtime_transport_override"), "")
}

@(test)
test_reconfiguration_handler_transport_refusals_pty_and_idempotency :: proc(t: ^testing.T) {rth_run(t, rth_refusals_then_pty)}
@(test)
test_reconfiguration_handler_transport_acp :: proc(t: ^testing.T) {rth_run(t, rth_acp)}
@(test)
test_reconfiguration_handler_transport_omitted :: proc(t: ^testing.T) {rth_run(t, rth_omitted)}

@(test)
test_instance_summary_carries_settings_panel_fields :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	inst := domain.Agent_Instance{project_id = "proj", provider = "codex", provider_profile = "", permission_mode = "ask", agent_permission_mode = "yolo", runtime_transport = "acp", runtime_transport_override = "acp"}
	raw := instance_changed_summary_json(inst)
	value, err := json.parse_string(raw)
	if !testing.expect(t, err == nil, raw) do return
	obj := value.(json.Object)
	testing.expect_value(t, string(obj["project_id"].(json.String)), "proj")
	testing.expect_value(t, string(obj["provider_profile"].(json.String)), "codex")
	testing.expect_value(t, string(obj["permission_mode"].(json.String)), "ask")
	testing.expect_value(t, string(obj["effective_permission_mode"].(json.String)), "ask")
	testing.expect_value(t, string(obj["runtime_transport_override"].(json.String)), "acp")
	// Inherited override: effective comes from the agent.
	inst.permission_mode = ""; inst.agent_permission_mode = "ask"; inst.runtime_transport_override = ""
	raw = instance_changed_summary_json(inst)
	value, err = json.parse_string(raw)
	if !testing.expect(t, err == nil, raw) do return
	obj = value.(json.Object)
	testing.expect_value(t, string(obj["permission_mode"].(json.String)), "")
	testing.expect_value(t, string(obj["effective_permission_mode"].(json.String)), "ask")
	testing.expect_value(t, string(obj["runtime_transport_override"].(json.String)), "")
	// A row without the agent's mode omits the effective key rather than guessing.
	inst.agent_permission_mode = ""
	raw = instance_changed_summary_json(inst)
	testing.expect(t, !strings.contains(raw, "effective_permission_mode"), raw)
	// The HTTP instance JSON carries the same choice.
	b := strings.builder_make()
	write_agent_instance_json(&b, {runtime_transport = "acp", runtime_transport_override = "acp"})
	testing.expect(t, strings.contains(strings.to_string(b), `"runtime_transport_override":"acp"`), strings.to_string(b))
}
