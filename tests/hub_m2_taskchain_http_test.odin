package hub_m2_taskchain_http_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

main :: proc() {
	db_path := "/tmp/heimdall-hub-m2-taskchain-http-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
	})
	check(ok, message)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}
	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}
	chain := request(&graph, "POST", "/api/v1/task-chains", "{\"title\":\"M2 Chain\",\"owner_user_id\":\"mallory\"}", alice[:])
	check(chain.status == 201 && strings.contains(chain.body, "\"publish_state\":\"draft\""), "create chain must create draft owned by auth context")
	chain_id := extract_json_string(chain.body, "chain_id")
	list_a := request(&graph, "GET", "/api/v1/task-chains", "", alice[:])
	check(list_a.status == 200 && strings.contains(list_a.body, chain_id), "owner must list own task chain")
	list_b := request(&graph, "GET", "/api/v1/task-chains", "", bob[:])
	check(list_b.status == 200 && !strings.contains(list_b.body, chain_id), "other user must not list task chain")
	detail_b := request(&graph, "GET", chain_url(chain_id, ""), "", bob[:])
	check(detail_b.status == 404, "cross-user task chain detail must be hidden")
	task_draft := request(&graph, "POST", chain_url(chain_id, "/tasks"), "{\"title\":\"M2 Task\"}", alice[:])
	check(task_draft.status == 201 && strings.contains(task_draft.body, "\"publish_state\":\"draft\""), "create task must create draft task")
	task_id := extract_json_string(task_draft.body, "task_id")
	draft_nudge := request(&graph, "POST", task_url(chain_id, task_id, "/nudge"), "{\"message\":\"wake\"}", alice[:])
	check(draft_nudge.status == 409, "draft task must not be nudged")
	draft_status := request(&graph, "POST", task_url(chain_id, task_id, "/status"), "{\"status\":\"in_progress\"}", alice[:])
	check(draft_status.status == 409, "draft task must reject execution status changes")
	publish_task_before_chain := request(&graph, "POST", task_url(chain_id, task_id, "/publish"), "", alice[:])
	check(publish_task_before_chain.status == 409, "task cannot publish before chain")
	other_chain := request(&graph, "POST", "/api/v1/task-chains", "{\"title\":\"Other Chain\"}", alice[:])
	other_chain_id := extract_json_string(other_chain.body, "chain_id")
	publish_chain := request(&graph, "POST", chain_url(chain_id, "/publish"), "", alice[:])
	check(publish_chain.status == 200 && strings.contains(publish_chain.body, "\"publish_state\":\"published\"") && strings.contains(publish_chain.body, "\"status\":\"active\""), "publish chain must set published/active")
	wrong_parent_publish := request(&graph, "POST", task_url(other_chain_id, task_id, "/publish"), "", alice[:])
	check(wrong_parent_publish.status == 404, "task publish must reject wrong parent chain path")
	// publish_chain cascade-publishes all draft tasks, so the task is already
	// published/assigned; a redundant publish_task must report 409 already-published.
	published_task_list := request(&graph, "GET", chain_url(chain_id, "/tasks"), "", alice[:])
	check(published_task_list.status == 200 && strings.contains(published_task_list.body, "\"publish_state\":\"published\"") && strings.contains(published_task_list.body, "\"status\":\"assigned\""), "chain publish must cascade task to published/assigned")
	publish_task := request(&graph, "POST", task_url(chain_id, task_id, "/publish"), "", alice[:])
	check(publish_task.status == 409, "re-publishing an already-published task must return 409")
	wrong_parent_status := request(&graph, "POST", task_url(other_chain_id, task_id, "/status"), "{\"status\":\"in_progress\"}", alice[:])
	check(wrong_parent_status.status == 404, "task status must reject wrong parent chain path")
	wrong_parent_nudge := request(&graph, "POST", task_url(other_chain_id, task_id, "/nudge"), "{\"message\":\"wrong\"}", alice[:])
	check(wrong_parent_nudge.status == 404, "task nudge must reject wrong parent chain path")
	valid_transitions := [?]string{"in_progress", "in_validation", "validated_not_good", "in_progress", "in_validation", "validated_good", "completed"}
	for status in valid_transitions {
		resp := request(&graph, "POST", task_url(chain_id, task_id, "/status"), strings.concatenate({"{\"status\":\"", status, "\"}"}), alice[:])
		check(resp.status == 200 && strings.contains(resp.body, strings.concatenate({"\"status\":\"", status, "\""})), strings.concatenate({"valid task transition failed: ", status}))
	}
	terminal := request(&graph, "POST", task_url(chain_id, task_id, "/status"), "{\"status\":\"in_progress\"}", alice[:])
	check(terminal.status == 409, "terminal task must reject further transition")
	check(strings.contains(request(&graph, "GET", chain_url(chain_id, "/tasks"), "", alice[:]).body, "\"unblocks_dependents\":true"), "completed task must report unblock=true")
	paused_task := request(&graph, "POST", chain_url(chain_id, "/tasks"), "{\"title\":\"Paused Task\"}", alice[:])
	paused_id := extract_json_string(paused_task.body, "task_id")
	_ = request(&graph, "POST", task_url(chain_id, paused_id, "/publish"), "", alice[:])
	paused := request(&graph, "POST", task_url(chain_id, paused_id, "/status"), "{\"status\":\"paused\"}", alice[:])
	check(paused.status == 200 && strings.contains(paused.body, "\"unblocks_dependents\":false"), "paused task must not unblock dependents")
	third := request(&graph, "POST", chain_url(chain_id, "/tasks"), "{\"title\":\"Nudged Task\"}", alice[:])
	third_id := extract_json_string(third.body, "task_id")
	_ = request(&graph, "POST", task_url(chain_id, third_id, "/publish"), "", alice[:])
	nudge := request(&graph, "POST", task_url(chain_id, third_id, "/nudge"), "{\"message\":\"ping\"}", alice[:])
	check(nudge.status == 200 && strings.contains(nudge.body, "\"target_role\":\"assignee\"") && strings.contains(nudge.body, "\"nudge_id\":"), "manual nudge endpoint must notify without status mutation")
	after_nudge := request(&graph, "GET", chain_url(chain_id, "/tasks"), "", alice[:])
	check(strings.contains(after_nudge.body, third_id) && strings.contains(after_nudge.body, "\"status\":\"assigned\""), "nudge must not mutate task status")
	complete_chain := request(&graph, "POST", chain_url(chain_id, "/complete"), "{}", alice[:])
	check(complete_chain.status == 200 && strings.contains(complete_chain.body, "\"status\":\"completed\""), "complete chain endpoint must work after publish")
	fmt.println("PASS: hub M2 taskchain http")
}

Response :: api_http.Response

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, body = body, request_id = "req_m2", remote_addr = "127.0.0.1", headers = headers})
}

chain_url :: proc(chain_id, suffix: string) -> string {
	return strings.concatenate({"/api/v1/task-chains/", chain_id, suffix})
}

task_url :: proc(chain_id, task_id, suffix: string) -> string {
	return strings.concatenate({"/api/v1/task-chains/", chain_id, "/tasks/", task_id, suffix})
}

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:]); if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
