package main

import natstest "odin_test:lib/natstest"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import repo_sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

// POST /api/v1/task-chains with a coordinator (ham-ctl task-chain create
// --coordinator): a coordinator launch that fails validation (missing or
// unknown provider/model, unknown agent or bridge) returns the launch error and
// leaves NO chain row and NO instance (iss_18e9f83723a3d3aa: orphan draft chains
// stayed in the sidebar). Valid creates with and without a coordinator still
// succeed exactly as before.
@(test)
test_task_chain_create_rejected_coordinator_leaves_no_chain :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-chain-orphan-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{nats_url = natstest.testing_url(t), database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", auto_provision_users = true, paddle_environment = "sandbox"})
	if !testing.expect(t, ok, msg) do return
	defer app.shutdown_graph(&graph)
	alice := hub_test_user_headers(&graph, "alice")

	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	if !testing.expect(t, enroll_ok, "device-flow bridge provisioning failed") do return
	if b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id); b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")
	_, _ = iface.bridge_provider_status_upsert(graph.agents.providers, domain.Bridge_Provider_Status{bridge_id = bridge_id, provider = "claude", state = "present", checked_at = "2026-10-01T00:00:00Z"})
	_, _ = iface.bridge_provider_setting_upsert(graph.agents.providers, domain.Bridge_Provider_Setting{bridge_id = bridge_id, provider = "claude", enabled = true, updated_at = "2026-10-01T00:00:00Z"})
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {return true, domain.Domain_Error{}}}

	call :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, body: string) -> api_http.Response {
		return api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/task-chains", body = body, request_id = "req_chain_orphan", remote_addr = "127.0.0.1", headers = headers})
	}
	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/agents", body = `{"name":"Coord","slug":"orphan-coord","default_provider":"claude","default_model":"claude-sonnet-5-5"}`, request_id = "req_agent", remote_addr = "127.0.0.1", headers = alice[:]})
	if !testing.expect_value(t, agent_res.status, 201) do return
	agent_id := orphan_json_field(agent_res.body, "agent_id")

	chain_count :: proc(graph: ^app.App_Graph) -> int {
		chains, _ := iface.taskchain_list_chains_by_owner(&graph.repos.taskchains, "alice")
		return len(chains)
	}
	instance_count :: proc(graph: ^app.App_Graph) -> int {
		instances, _ := iface.agent_list_instances_by_owner(&graph.repos.agents, "alice", 100)
		return len(instances)
	}

	rejected := []struct {
		name, agent, bridge, provider, model: string,
		status:                               int,
		message:                              string,
	}{
		{"missing provider and model", agent_id, bridge_id, "", "", 422, "provider and model are required"},
		{"missing model", agent_id, bridge_id, "claude", "", 422, "provider and model are required"},
		{"unknown model", agent_id, bridge_id, "claude", "no-such-model", 422, "model is unknown or deprecated"},
		{"unknown provider", agent_id, bridge_id, "no-such-provider", "claude-sonnet-5-5", 422, "provider is unknown or deprecated"},
		{"unknown agent", "agt_missing", bridge_id, "claude", "claude-sonnet-5-5", 404, ""},
		{"unknown bridge", agent_id, "brg_missing", "claude", "claude-sonnet-5-5", 404, ""},
		{"missing bridge", agent_id, "", "claude", "claude-sonnet-5-5", 400, "bridge_id is required"},
	}
	for r in rejected {
		before_chains, before_instances := chain_count(&graph), instance_count(&graph)
		res := call(&graph, alice[:], fmt.tprintf(`{{"title":"Rejected","coordinator_agent_id":"%s","bridge_id":"%s","provider":"%s","model":"%s"}}`, r.agent, r.bridge, r.provider, r.model))
		testing.expectf(t, res.status == r.status, "%s: status %d (want %d) body %s", r.name, res.status, r.status, res.body)
		if r.message != "" do testing.expectf(t, strings.contains(res.body, r.message), "%s: error should carry the launch message %q: %s", r.name, r.message, res.body)
		testing.expectf(t, chain_count(&graph) == before_chains, "%s: rejected create left a chain (%d -> %d)", r.name, before_chains, chain_count(&graph))
		testing.expectf(t, instance_count(&graph) == before_instances, "%s: rejected create left an instance (%d -> %d)", r.name, before_instances, instance_count(&graph))
	}
	testing.expect_value(t, chain_count(&graph), 0)
	testing.expect_value(t, instance_count(&graph), 0)

	// A failure late in coordinator preparation, after the chain and instance rows
	// were written, rolls back both: the create is one unit of work.
	testing.expect(t, repo_sqlite.exec(&graph.db, "CREATE TRIGGER orphan_fail_chat BEFORE INSERT ON chat_conversations BEGIN SELECT RAISE(ABORT,'synthetic coordinator chat failure'); END;"))
	late := call(&graph, alice[:], fmt.tprintf(`{{"title":"Late failure","coordinator_agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5"}}`, agent_id, bridge_id))
	testing.expectf(t, late.status >= 400, "late preparation failure must fail the create: %d %s", late.status, late.body)
	testing.expect_value(t, chain_count(&graph), 0)
	testing.expect_value(t, instance_count(&graph), 0)
	testing.expect(t, repo_sqlite.exec(&graph.db, "DROP TRIGGER orphan_fail_chat;"))

	// Valid creates are unchanged: with a coordinator the chain gets that
	// instance; without one only the chain row is written; kind defaults to mixed_work.
	with_coord := call(&graph, alice[:], fmt.tprintf(`{{"title":"With coordinator","coordinator_agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5"}}`, agent_id, bridge_id))
	if !testing.expectf(t, with_coord.status == 201, "valid create with coordinator: %d %s", with_coord.status, with_coord.body) do return
	chain_id := orphan_json_field(with_coord.body, "chain_id")
	chain, found, _ := iface.taskchain_get_chain(&graph.repos.taskchains, domain.Task_Chain_ID(chain_id))
	if !testing.expect(t, found, "created chain should exist") do return
	testing.expect(t, chain.kind == domain.CHAIN_KIND_MIXED_WORK, "default kind is mixed_work")
	inst, inst_found, _ := iface.agent_get_instance(&graph.repos.agents, chain.coordinator_agent_instance_id)
	testing.expect(t, inst_found && inst.agent_id == agent_id && inst.chain_id == chain_id, "coordinator instance is bound to the chain")
	members, _ := iface.taskchain_list_members_by_chain(&graph.repos.taskchains, chain.chain_id, "alice")
	coord_members := 0
	for m in members do if m.role == "coordinator" && m.agent_instance_id == inst.agent_instance_id do coord_members += 1
	testing.expect_value(t, coord_members, 1)
	testing.expect(t, strings.contains(with_coord.body, inst.agent_instance_id), "response carries the coordinator instance")

	plain := call(&graph, alice[:], `{"title":"No coordinator"}`)
	testing.expectf(t, plain.status == 201, "valid create without coordinator: %d %s", plain.status, plain.body)
	testing.expect_value(t, chain_count(&graph), 2)
	testing.expect_value(t, instance_count(&graph), 1)

	// Deprecated kinds are still refused, and refused before any row exists.
	bad_kind := call(&graph, alice[:], `{"title":"Old kind","kind":"team_work"}`)
	testing.expectf(t, bad_kind.status == 400 && strings.contains(bad_kind.body, "mixed_work"), "deprecated kind: %d %s", bad_kind.status, bad_kind.body)
	testing.expect_value(t, chain_count(&graph), 2)
}

@(private = "file")
orphan_json_field :: proc(body, key: string) -> string {
	marker := fmt.tprintf(`"%s":"`, key)
	idx := strings.index(body, marker)
	if idx < 0 do return ""
	rest := body[idx + len(marker):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}
