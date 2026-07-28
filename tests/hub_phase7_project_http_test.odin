package hub_phase7_project_http_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

main :: proc() {
	db_path := "/tmp/heimdall-hub-phase7-project-http-test.db"
	default_path := "/tmp/heimdall-hub-phase7-default"
	bridge_path := "/tmp/heimdall-hub-phase7-bridge"
	_ = os.remove(db_path)
	_ = os.remove_all(default_path)
	_ = os.remove_all(bridge_path)
	_ = os.make_directory(default_path)
	_ = os.make_directory(strings.concatenate({default_path, "/.git"}))
	_ = os.make_directory(bridge_path)
	_ = os.make_directory(strings.concatenate({bridge_path, "/.git"}))
	defer { _ = os.remove_all(default_path); _ = os.remove_all(bridge_path) }
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)
	graph.projects.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = nil, validate_project_path = fake_validate_project_path}
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }
	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}
	bridge_id, bridge_token := enroll_bridge_offline(&graph, alice[:], "Alice Bridge")
	connect_bridge(&graph, bridge_token)
	bob_bridge_id, bob_bridge_token := enroll_bridge_offline(&graph, bob[:], "Bob Bridge")
	connect_bridge(&graph, bob_bridge_token)
	offline_bridge_id, _ := enroll_bridge_offline(&graph, alice[:], "Offline Bridge")
	missing_path := request(&graph, "POST", "/api/v1/projects", "{\"name\":\"No Path\"}", alice[:])
	check(missing_path.status == 400, "project default_path is mandatory")
	create_body := strings.concatenate({"{\"name\":\"Heimdall\",\"slug\":\"heimdall\",\"repo_url\":\"https://example/repo\",\"vcs_kind\":\"git\",\"default_path\":\"", default_path, "\",\"owner_user_id\":\"mallory\"}"})
	created := request(&graph, "POST", "/api/v1/projects", create_body, alice[:])
	check(created.status == 201 && strings.contains(created.body, default_path), "create project must return project")
	project_id := extract_json_string(created.body, "project_id")
	list_a := request(&graph, "GET", "/api/v1/projects", "", alice[:])
	check(list_a.status == 200 && strings.contains(list_a.body, project_id), "owner must list own project")
	list_b := request(&graph, "GET", "/api/v1/projects", "", bob[:])
	check(list_b.status == 200 && !strings.contains(list_b.body, project_id), "other user must not list project")
	bob_detail := request(&graph, "GET", project_url(project_id, ""), "", bob[:])
	check(bob_detail.status == 404, "cross-user project detail must be hidden")
	auth_a := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	default_effective, default_ok, default_err := project_service.resolve_effective_path(&graph.projects, auth_a, domain.Project_ID(project_id), bridge_id)
	check(default_ok && default_err.code == .None && default_effective == default_path, "effective path must default to Project.default_path")
	bad_bridge := request(&graph, "PUT", bridge_path_url(project_id, bob_bridge_id, ""), "{\"path\":\"/bob/path\"}", alice[:])
	check(bad_bridge.status == 404, "cannot set path override for another user's bridge")
	offline_validate := request(&graph, "POST", bridge_path_url(project_id, offline_bridge_id, "/validate"), "", alice[:])
	check(offline_validate.status == 503 && strings.contains(offline_validate.body, "bridge_offline"), "validation must fail when selected Bridge is not live")
	set_body := strings.concatenate({"{\"path\":\"", bridge_path, "\"}"})
	set_path := request(&graph, "PUT", bridge_path_url(project_id, bridge_id, ""), set_body, alice[:])
	check(set_path.status == 200 && strings.contains(set_path.body, bridge_path) && strings.contains(set_path.body, "\"is_validated\":false"), "set bridge path override must persist unvalidated path")
	override_effective, override_ok, override_err := project_service.resolve_effective_path(&graph.projects, auth_a, domain.Project_ID(project_id), bridge_id)
	check(override_ok && override_err.code == .None && override_effective == bridge_path, "effective path must prefer bridge override")
	validated := request(&graph, "POST", bridge_path_url(project_id, bridge_id, "/validate"), "", alice[:])
	check(validated.status == 200 && strings.contains(validated.body, "\"is_validated\":true") && strings.contains(validated.body, "validate_project_path") && strings.contains(validated.body, "cmd_"), "validate endpoint must store Bridge command validation result")
	revoked_bridge_id, revoked_bridge_token := enroll_bridge_offline(&graph, alice[:], "Revoked Bridge")
	connect_bridge(&graph, revoked_bridge_token)
	revoke_headers := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	revoke_resp := request(&graph, "POST", bridge_url(revoked_bridge_id, "/revoke"), "", revoke_headers[:])
	check(revoke_resp.status == 200, revoke_resp.body)
	revoked_validate := request(&graph, "POST", bridge_path_url(project_id, revoked_bridge_id, "/validate"), "", alice[:])
	check(revoked_validate.status == 403 && strings.contains(revoked_validate.body, "bridge_revoked"), "validation must fail when selected Bridge is revoked")
	detail_with_paths := request(&graph, "GET", project_url(project_id, ""), "", alice[:])
	check(detail_with_paths.status == 200 && strings.contains(detail_with_paths.body, "bridge_paths") && strings.contains(detail_with_paths.body, bridge_path), "project detail must expose persisted bridge paths")
	bad_delete := request(&graph, "DELETE", bridge_path_url(project_id, bob_bridge_id, ""), "", alice[:])
	check(bad_delete.status == 404, "delete bridge path must reject another user's bridge")
	deleted := request(&graph, "DELETE", bridge_path_url(project_id, bridge_id, ""), "", alice[:])
	check(deleted.status == 200 && strings.contains(deleted.body, "deleted"), "delete bridge path override must work")
	invalid_project := request(&graph, "POST", "/api/v1/projects", "{\"name\":\"Invalid\",\"slug\":\"invalid\",\"vcs_kind\":\"git\",\"default_path\":\"/definitely/not/a/real/path/heimdall-review\"}", alice[:])
	invalid_project_id := extract_json_string(invalid_project.body, "project_id")
	invalid_validate := request(&graph, "POST", bridge_path_url(invalid_project_id, bridge_id, "/validate"), "", alice[:])
	check(invalid_validate.status == 200 && strings.contains(invalid_validate.body, "\"is_validated\":false") && strings.contains(invalid_validate.body, "path_not_found"), "Bridge validation must not mark invalid paths validated")
	fallback_effective, fallback_ok, fallback_err := project_service.resolve_effective_path(&graph.projects, auth_a, domain.Project_ID(project_id), bridge_id)
	check(fallback_ok && fallback_err.code == .None && fallback_effective == default_path, "effective path must fall back after override delete")
	fmt.println("PASS: hub phase7 project http")
}

enroll_bridge_offline :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, label: string) -> (string, string) {
	created := request(graph, "POST", "/api/v1/bridge-enrollments", strings.concatenate({"{\"label\":\"", label, "\"}"}), headers)
	check(created.status == 201, created.body)
	token := extract_json_string(created.body, "enrollment_token")
	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enrolled := request(graph, "POST", "/api/v1/bridges/enroll", "{\"machine\":{\"hostname\":\"host\"},\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\",\"smart\"],\"default_tier\":\"normal\"}]}", enroll_headers[:])
	check(enrolled.status == 201, enrolled.body)
	return extract_json_string(enrolled.body, "bridge_id"), extract_json_string(enrolled.body, "bridge_token")
}

connect_bridge :: proc(graph: ^app.App_Graph, bridge_token: string) {
	bridge_auth, auth_ok, auth_err := bridge_service.verify_bridge_token(&graph.bridges, bridge_token)
	check(auth_ok, auth_err.message)
	bridge, bridge_ok, bridge_err := bridge_service.bridge_runtime_connect(&graph.bridges, bridge_token, "host", "", "", "{\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\"],\"default_tier\":\"normal\"}]}")
	check(bridge_ok && bridge.bridge_id == bridge_auth.bridge_id, bridge_err.message)
}

fake_validate_project_path :: proc(ctx: rawptr, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	_ = ctx
	if strings.contains(command.path, "/definitely/not/a/real/path") do return project_service.Project_Path_Validation_Result{type = "project_path_validation_result", command_id = command.command_id, project_id = command.project_id, path = command.path, ok = false, validation_error = "Path does not exist", details_json = "{\"transport\":\"bridge_ws\",\"command\":\"validate_project_path\",\"error\":{\"code\":\"path_not_found\"}}"}, true, domain.Domain_Error{}
	return project_service.Project_Path_Validation_Result{type = "project_path_validation_result", command_id = command.command_id, project_id = command.project_id, path = command.path, ok = true, details_json = "{\"transport\":\"bridge_ws\",\"command\":\"validate_project_path\",\"command_id\":\"cmd_fake\"}"}, true, domain.Domain_Error{}
}

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response { return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, body = body, request_id = "req_p7", remote_addr = "127.0.0.1", headers = headers}) }
project_url :: proc(project_id, suffix: string) -> string { return strings.concatenate({"/api/v1/projects/", project_id, suffix}) }
bridge_path_url :: proc(project_id, bridge_id, suffix: string) -> string { return strings.concatenate({"/api/v1/projects/", project_id, "/bridge-paths/", bridge_id, suffix}) }
bridge_url :: proc(bridge_id, suffix: string) -> string { return strings.concatenate({"/api/v1/bridges/", bridge_id, suffix}) }

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:]); if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
