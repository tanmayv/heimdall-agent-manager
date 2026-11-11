package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

// POST /chats create_owner_chain, success path through the real Hub graph:
// the Bridge prepares the Hub-chosen chain (stand-in that registers its
// route), the instance launches into it, the reply is 201 and names the chain
// (NewConversationPage and CreateChainModal open chain:<id> from it), one
// conversation is saved and nothing is discarded.
Owner_Create_Chat_Probe :: struct { prepares, discards: int, chain, agent, title, title_source: string }
@(private = "file") owner_create_chat_probe: Owner_Create_Chat_Probe

@(test)
test_create_chat_owner_chain_success_replies_with_the_chain :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-owner-create-chat-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", auto_provision_users = true, paddle_environment = "sandbox"})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)
	alice := hub_test_user_headers(&graph, "alice")

	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	if b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id); b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")
	_, _ = iface.bridge_provider_status_upsert(graph.agents.providers, domain.Bridge_Provider_Status{bridge_id = bridge_id, provider = "claude", state = "present", checked_at = "2026-10-01T00:00:00Z"})
	_, _ = iface.bridge_provider_setting_upsert(graph.agents.providers, domain.Bridge_Provider_Setting{bridge_id = bridge_id, provider = "claude", enabled = true, updated_at = "2026-10-01T00:00:00Z"})
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) { return true, {} }}

	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/agents", body = `{"name":"Planner","slug":"one-step-planner","default_provider":"claude","default_model":"claude-sonnet-5-5"}`, request_id = "req_occ_1", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, agent_res.status, 201)
	agent_id := occ_field(agent_res.body, "agent_id")
	api_http.router_dispatch(&graph.router, api_http.Request{method = "PATCH", path = strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id}, context.temp_allocator), body = `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`, request_id = "req_occ_2", remote_addr = "127.0.0.1", headers = alice[:]})

	// The Bridge stand-in: accepts the Hub-chosen id; the registry then routes it.
	owner_create_chat_probe = {}
	graph.content_handlers.prepare_owner_chain = proc(ctx: rawptr, bridge_id, agent_id, chain_id, title, description, title_source: string) -> (string, domain.Domain_Error) {
		p := &owner_create_chat_probe
		sync.atomic_add(&p.prepares, 1)
		p.chain, p.agent, p.title, p.title_source = strings.clone(chain_id), strings.clone(agent_id), strings.clone(title), strings.clone(title_source)
		return chain_id, {}
	}
	graph.content_handlers.discard_owner_chain = proc(ctx: rawptr, bridge_id, chain_id: string) -> bool {
		sync.atomic_add(&owner_create_chat_probe.discards, 1)
		return true
	}
	graph.agents.taskchains.owner_registry_routes = proc(ctx: rawptr, account, chain: string) -> ([]domain.Owner_Registry_Record, domain.Domain_Error) {
		if chain == "" || chain != owner_create_chat_probe.chain do return nil, {}
		out := make([]domain.Owner_Registry_Record, 1, context.temp_allocator)
		out[0] = domain.Owner_Registry_Record{account_id = account, chain_id = chain}
		return out, {}
	}
	before := occ_chat_count(&graph, alice[:])

	body := strings.concatenate({`{"agent_id":"`, agent_id, `","bridge_id":"`, bridge_id, `","provider":"claude","model":"claude-sonnet-5-5","create_owner_chain":true,"initial_message":{"body":"Plan the release\nwith tickets"}}`}, context.temp_allocator)
	res := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/chats", body = body, request_id = "req_occ_3", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, res.status, 201)
	testing.expect_value(t, owner_create_chat_probe.prepares, 1)
	testing.expect_value(t, owner_create_chat_probe.discards, 0)
	testing.expect(t, strings.has_prefix(owner_create_chat_probe.chain, "chain_") && len(owner_create_chat_probe.chain) == len("chain_") + 32, "the Hub chooses a chain_<32 hex> id")
	testing.expect_value(t, owner_create_chat_probe.agent, agent_id)
	// The run's default '<agent-name> #<n>' title, never the first message,
	// marked default so the owner Bridge nudges the coordinator for a title.
	testing.expect_value(t, owner_create_chat_probe.title, "Planner #1")
	testing.expect_value(t, owner_create_chat_probe.title_source, "default")
	testing.expect_value(t, occ_field(res.body, "chain_id"), owner_create_chat_probe.chain)
	testing.expect(t, occ_field(res.body, "agent_instance_id") != "", "the reply names the launched instance")
	testing.expect_value(t, occ_chat_count(&graph, alice[:]), before + 1)
	delete(owner_create_chat_probe.chain); delete(owner_create_chat_probe.agent); delete(owner_create_chat_probe.title)
}

@(private = "file")
occ_field :: proc(body, key: string) -> string {
	needle := strings.concatenate({`"`, key, `":"`}, context.temp_allocator)
	i := strings.index(body, needle)
	if i < 0 do return ""
	rest := body[i + len(needle):]
	end := strings.index_byte(rest, '"')
	return rest[:end] if end >= 0 else ""
}

@(private = "file")
occ_chat_count :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> int {
	res := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/chats", request_id = "req_occ_list", remote_addr = "127.0.0.1", headers = headers})
	return strings.count(res.body, `"conversation_id"`)
}
