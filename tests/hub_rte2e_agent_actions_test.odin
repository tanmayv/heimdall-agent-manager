package hub_rte2e_agent_actions_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import bridge "odin_test:bridge"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"
import api_http "odin_test:hub/transport/http"

PORT :: 49673

main :: proc() {
	db_path := "/tmp/heimdall-hub-rte2e-agent-actions-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", bind_host = "127.0.0.1", port = PORT, username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)

	owner := domain.User_ID("alice")
	now := "2026-07-23T00:00:00Z"
	agent_id := "agent_relay"
	instance_id := "inst_relay"
	_, agent_saved, agent_err := iface.agent_save(&graph.repos.agents, domain.Agent{agent_id = agent_id, owner_user_id = owner, name = "Relay Agent", slug = "relay", default_provider = "claude", default_tier = "normal", state = .Active, created_at = now, updated_at = now})
	check(agent_saved, agent_err.message)
	_, inst_saved, inst_err := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{agent_instance_id = instance_id, owner_user_id = owner, agent_id = agent_id, bridge_id = "bridge_relay", provider = "claude", tier = "normal", chain_id = "chain_relay", runtime_status = "starting", startup_status = "starting", activity_status = "unknown", created_at = now, updated_at = now, started_at = now, last_seen_at = now})
	check(inst_saved, inst_err.message)
	auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = string(owner), name = string(owner)}
	conv, conv_saved, conv_err := content_service.create_conversation(&graph.content, auth, content_service.Chat_Input{agent_id = agent_id, agent_instance_id = instance_id, title = "Relay Chat"})
	check(conv_saved && conv.agent_instance_id == instance_id, conv_err.message)
	chain_id := domain.Task_Chain_ID("chain_relay")
	task_id := domain.Task_ID("task_relay")
	_, chain_saved, chain_err := iface.taskchain_save_chain(&graph.repos.taskchains, domain.Task_Chain{chain_id = chain_id, owner_user_id = owner, title = "Relay Chain", publish_state = .Published, status = .Active, kind = "team_work", created_at = now, updated_at = now, published_at = now})
	check(chain_saved, chain_err.message)
	_, task_saved, task_err := iface.taskchain_save_task(&graph.repos.taskchains, domain.Task{task_id = task_id, chain_id = chain_id, owner_user_id = owner, title = "Relay Task", publish_state = .Published, status = .In_Progress, assignee_ref_json = strings.concatenate({"{\"type\":\"agent_instance\",\"agent_instance_id\":\"", instance_id, "\"}"}), reviewer_refs_json = "[]", created_at = now, updated_at = now, published_at = now, started_at = now})
	check(task_saved, task_err.message)

	thread.run_with_poly_data(&graph.router, serve_hub)
	bridge.bridge_agent_token_store_init()
	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", PORT)
	issued := bridge.bridge_agent_token_issue(instance_id, strings.concatenate({"hit_", instance_id}), .Agent)

	response := ""
	for attempt in 0..<25 {
		_ = attempt
		response = bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{ \"v\" : 1, \"id\" : \"relay\", \"token\" : \"", issued.plaintext_token, "\", \"method\" : \"agent.chat.send_to_user\", \"params\" : { \"body\" : \"hello from local bridge\" } }"}))
		if strings.contains(response, "\"ok\":true") do break
	}
	check(strings.contains(response, "\"ok\":true") && strings.contains(response, "agent_to_user") && strings.contains(response, "hello from local bridge"), response)

	comment_resp := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"comment\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.tasks.comment\",\"params\":{\"task_id\":\"", string(task_id), "\",\"body\":\"real task comment from local bridge\"}}"}))
	check(strings.contains(comment_resp, "\"ok\":true") && strings.contains(comment_resp, "real task comment from local bridge") && strings.contains(comment_resp, instance_id), comment_resp)
	comments, comments_err := iface.taskchain_list_comments_by_task(&graph.repos.taskchains, task_id, owner)
	check(comments_err.code == .None && len(comments) == 1 && comments[0].body == "real task comment from local bridge" && comments[0].author_agent_instance_id == instance_id, "local agent task comment must persist with Bridge-resolved instance identity")

	spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"spoof\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.chat.send_to_user\",\"params\":{\"body\":\"bad\",\"agent_instance_id\":\"other\"}}"}))
	check(strings.contains(spoof, "\"ok\":false") && strings.contains(spoof, "forbidden"), "local spoofed identity must remain rejected")

	fmt.println("PASS: hub RTE2E agent action relay")
	app.shutdown_graph(&graph)
	_ = os.remove(db_path)
	os.exit(0)
}

serve_hub :: proc(router: ^api_http.Router) {
	_ = api_http.serve(router, api_http.Server_Config{bind_host = "127.0.0.1", port = PORT})
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
