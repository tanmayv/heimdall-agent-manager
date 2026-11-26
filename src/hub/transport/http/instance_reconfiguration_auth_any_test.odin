package http

import "core:strings"
import "core:testing"
import virtual "core:mem/virtual"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// T3 (ham-ctl parity): GET /agent-instances/{id} and the reconfiguration
// create/list/cancel routes accept bridge-relayed instance tokens
// (require_auth_any) so ham-ctl can reconfigure, while get_instance ->
// require_owner keeps the same-owner boundary.

@(private = "file")
RAA_FOREIGN_INSTANCE :: "inst_raa_foreign"

@(private = "file")
raa_request :: proc(method, path, body: string, headers: []contracts.HTTP_Header) -> Request {
	return Request{method = method, path = path, body = body, request_id = "req_raa", remote_addr = "127.0.0.1:4444", headers = headers}
}

@(private = "file")
raa_scenario :: proc(t: ^testing.T, f: ^wire_fixture) {
	h := Agent_Handlers{auth = &f.auth_svc, agents = &f.ag_svc}

	// A second owner with its own bridge and a running instance on it: its
	// relayed instance token is valid, just not for the fixture owner's instance.
	foreign_token: string
	foreign_bridge := wire_enroll_bridge(t, f, "raa_foreign_owner", "raa-host-foreign", &foreign_token)
	_, saved, save_err := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
		agent_instance_id = RAA_FOREIGN_INSTANCE,
		owner_user_id     = "raa_foreign_owner",
		agent_id          = "agt_raa_foreign",
		bridge_id         = foreign_bridge,
		display_name      = "foreign instance",
		runtime_status    = "running",
		startup_status    = "ready",
		created_at        = "2026-11-26T10:00:00Z",
		updated_at        = "2026-11-26T10:00:00Z",
	})
	if !testing.expectf(t, saved, "foreign instance saved (%s)", save_err.message) do return
	foreign_headers := []contracts.HTTP_Header{
		{name = "Authorization", value = strings.concatenate({"Bearer ", foreign_token})},
		{name = "X-Heimdall-Instance-Token", value = "hit_" + RAA_FOREIGN_INSTANCE},
	}
	own_headers := f.agent_headers[:]

	own_detail := strings.concatenate({"/api/v1/agent-instances/", f.instance_id})
	own_reconfigs := strings.concatenate({own_detail, "/reconfigurations"})
	own_cancel := strings.concatenate({own_reconfigs, "/cancel"})

	// Same-owner instance token: detail and the operation list are readable.
	resp := agent_instance_detail_handler(&h, raa_request("GET", own_detail, "", own_headers))
	testing.expectf(t, resp.status == 200, "own detail: %d %s", resp.status, resp.body)
	testing.expect(t, strings.contains(resp.body, f.instance_id), resp.body)
	resp = list_instance_reconfigurations_handler(&h, raa_request("GET", own_reconfigs, "", own_headers))
	testing.expectf(t, resp.status == 200, "own list: %d %s", resp.status, resp.body)
	testing.expect(t, strings.contains(resp.body, `"operations":[]`), resp.body)
	// An instance token still cannot change the permission mode (users only).
	create_body := strings.concatenate({`{"bridge_id":"`, f.bridge_pin, `","project_id":"","provider":"codex","model":"m","permission_mode":"yolo","expected_revision":0,"idempotency_key":"raa_own"}`})
	resp = create_instance_reconfiguration_handler(&h, raa_request("POST", own_reconfigs, create_body, own_headers))
	testing.expectf(t, resp.status == 403, "own create with permission_mode: %d %s", resp.status, resp.body)

	// The foreign token authenticates (its own instance is readable)...
	resp = agent_instance_detail_handler(&h, raa_request("GET", "/api/v1/agent-instances/" + RAA_FOREIGN_INSTANCE, "", foreign_headers))
	testing.expectf(t, resp.status == 200, "foreign own detail: %d %s", resp.status, resp.body)

	// ...but every switched route refuses the fixture owner's instance.
	resp = agent_instance_detail_handler(&h, raa_request("GET", own_detail, "", foreign_headers))
	testing.expectf(t, resp.status == 404, "foreign detail: %d %s", resp.status, resp.body)
	resp = list_instance_reconfigurations_handler(&h, raa_request("GET", own_reconfigs, "", foreign_headers))
	testing.expectf(t, resp.status == 404, "foreign list: %d %s", resp.status, resp.body)
	foreign_create := strings.concatenate({`{"bridge_id":"`, f.bridge_pin, `","project_id":"","provider":"codex","model":"m","expected_revision":0,"idempotency_key":"raa_foreign"}`})
	resp = create_instance_reconfiguration_handler(&h, raa_request("POST", own_reconfigs, foreign_create, foreign_headers))
	testing.expectf(t, resp.status == 404, "foreign create: %d %s", resp.status, resp.body)
	resp = cancel_instance_reconfiguration_handler(&h, raa_request("POST", own_cancel, `{"idempotency_key":"raa_foreign","expected_operation_revision":1}`, foreign_headers))
	testing.expectf(t, resp.status == 404, "foreign cancel: %d %s", resp.status, resp.body)
	ops, list_err := iface.instance_reconfiguration_list(&f.ag_repo, string(f.owner), f.instance_id, false)
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(ops), 0)

	// A bare bridge token (no instance assertion) is still refused.
	bare := []contracts.HTTP_Header{{name = "Authorization", value = f.agent_auth_value}}
	resp = agent_instance_detail_handler(&h, raa_request("GET", own_detail, "", bare))
	testing.expectf(t, resp.status == 403, "bare bridge token: %d %s", resp.status, resp.body)
}

@(test)
test_instance_routes_accept_same_owner_instance_token_only :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	f := wire_setup(t, "reconfig_auth_any")
	defer wire_teardown(f)
	raa_scenario(t, f)
}
