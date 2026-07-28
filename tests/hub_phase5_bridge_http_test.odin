package hub_phase5_bridge_http_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

main :: proc() {
	db_path := "/tmp/heimdall-hub-phase5-http-test.db"
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
	alice := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "alice"},
		{name = "X-authentik-name", value = "Alice"},
	}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	create := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridge-enrollments", body = "{\"label\":\"Alice Mac\",\"expires_in_seconds\":900}", request_id = "req_create", remote_addr = "127.0.0.1", headers = alice[:]})
	check(create.status == 201, "create enrollment endpoint must return 201")
	created_expires_at := extract_json_string(create.body, "expires_at")
	check(created_expires_at != "" && created_expires_at != "9999-12-31T23:59:59Z", "create enrollment must compute expires_at from expires_in_seconds")
	unlabeled := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridge-enrollments", body = "{\"expires_in_seconds\":900}", request_id = "req_unlabeled", remote_addr = "127.0.0.1", headers = alice[:]})
	check(unlabeled.status == 201, "unlabeled enrollment must return 201")
	unlabeled_token := extract_json_string(unlabeled.body, "enrollment_token")
	expires_at_bypass := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridge-enrollments", body = "{\"expires_at\":\"9999-12-31T23:59:59Z\"}", request_id = "req_exp_bypass", remote_addr = "127.0.0.1", headers = alice[:]})
	check(expires_at_bypass.status == 400, "public create enrollment must reject expires_at bypass")
	token := extract_json_string(create.body, "enrollment_token")
	check(strings.has_prefix(token, "hbe_"), "create enrollment must return one-time hbe token")
	list_enrollments := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridge-enrollments", request_id = "req_list_enr", remote_addr = "127.0.0.1", headers = alice[:]})
	check(list_enrollments.status == 200 && strings.contains(list_enrollments.body, "Alice Mac"), "list enrollment endpoint must show own enrollment")
	check(!strings.contains(list_enrollments.body, "enrollment_token") && !strings.contains(list_enrollments.body, token) && !strings.contains(list_enrollments.body, unlabeled_token), "list enrollment endpoint must not leak raw token")
	revocable := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridge-enrollments", body = "{\"label\":\"Revocable\"}", request_id = "req_revocable", remote_addr = "127.0.0.1", headers = alice[:]})
	revocable_id := extract_json_string(revocable.body, "enrollment_id")
	revoke_enrollment := api_http.router_dispatch(&graph.router, api_http.Request{method = "DELETE", path = enrollment_url(revocable_id), request_id = "req_revoke_enrollment", remote_addr = "127.0.0.1", headers = alice[:]})
	check(revoke_enrollment.status == 200 && strings.contains(revoke_enrollment.body, "revoked"), "revoke enrollment endpoint must revoke pending enrollment")

	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enroll := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridges/enroll", body = "{\"machine\":{\"hostname\":\"alice-host\",\"os\":\"macos\",\"arch\":\"arm64\"}}", request_id = "req_enroll", remote_addr = "203.0.113.10", headers = enroll_headers[:]})
	check(enroll.status == 201, "bridge enroll endpoint must accept Authorization: Bearer enrollment token")
	bridge_id := extract_json_string(enroll.body, "bridge_id")
	bridge_token := extract_json_string(enroll.body, "bridge_token")
	check(strings.has_prefix(bridge_id, "brg_") && strings.has_prefix(bridge_token, "hbr_"), "enroll endpoint must return bridge id and hbr token")
	unlabeled_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", unlabeled_token})}}
	unlabeled_enroll := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridges/enroll", body = "{\"machine\":{\"hostname\":\"default-host\",\"os\":\"linux\",\"arch\":\"amd64\"}}", request_id = "req_unlabeled_enroll", remote_addr = "203.0.113.11", headers = unlabeled_headers[:]})
	check(unlabeled_enroll.status == 201, "unlabeled enrollment must enroll successfully")
	default_bridge_id := extract_json_string(unlabeled_enroll.body, "bridge_id")
	default_detail := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(default_bridge_id, ""), request_id = "req_default_detail", remote_addr = "127.0.0.1", headers = alice[:]})
	check(default_detail.status == 200 && strings.contains(default_detail.body, "\"label\":\"default-host\"") && strings.contains(default_detail.body, "\"label_is_user_customized\":false"), "default label must derive from hostname when enrollment label omitted")
	reuse := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridges/enroll", body = "{\"machine\":{\"hostname\":\"other\"}}", request_id = "req_reuse", headers = enroll_headers[:]})
	check(reuse.status == 409, "enrollment token must be one-time at API boundary")
	query_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridges/enroll", query = strings.concatenate({"token=", token}), body = "{\"machine\":{\"hostname\":\"bad\"}}", request_id = "req_query_token"})
	check(query_token.status == 401, "enroll endpoint must reject tokens in query/body")
	body_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/bridges/enroll", body = strings.concatenate({"{\"token\":\"", token, "\",\"machine\":{\"hostname\":\"bad-body\"}}"}), request_id = "req_body_token"})
	check(body_token.status == 401, "enroll endpoint must reject tokens in request body")

	list_bridges := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges", request_id = "req_list_bridge", remote_addr = "127.0.0.1", headers = alice[:]})
	check(list_bridges.status == 200 && strings.contains(list_bridges.body, bridge_id) && strings.contains(list_bridges.body, "Alice Mac"), "owner must list own bridge")
	bob_list := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges", request_id = "req_bob", remote_addr = "127.0.0.1", headers = bob[:]})
	check(bob_list.status == 200 && !strings.contains(bob_list.body, bridge_id), "other user must not list bridge")
	bob_detail := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), request_id = "req_bob_detail", remote_addr = "127.0.0.1", headers = bob[:]})
	check(bob_detail.status == 404, "cross-user bridge detail must be hidden")
	rename := api_http.router_dispatch(&graph.router, api_http.Request{method = "PATCH", path = bridge_url(bridge_id, ""), body = "{\"label\":\"Work Mac\"}", request_id = "req_rename", remote_addr = "127.0.0.1", headers = alice[:]})
	check(rename.status == 200 && strings.contains(rename.body, "Work Mac") && strings.contains(rename.body, "\"label_is_user_customized\":true"), "rename endpoint must customize label")
	bridge_auth := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	bridge_detail_with_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), request_id = "req_bridge_token_detail", headers = bridge_auth[:]})
	check(bridge_detail_with_token.status == 200 && strings.contains(bridge_detail_with_token.body, bridge_id), "bridge token must resolve owner/bridge through Authorization: Bearer")
	wrong_bridge_with_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url("brg_other", ""), request_id = "req_bridge_token_wrong", headers = bridge_auth[:]})
	check(wrong_bridge_with_token.status == 404, "bridge token must be scoped to its own bridge")
	bridge_query_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), query = strings.concatenate({"token=", bridge_token}), request_id = "req_bridge_query", headers = bridge_auth[:]})
	check(bridge_query_token.status == 401, "bridge token endpoint must reject query/body tokens")
	bridge_list_with_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges", request_id = "req_bridge_list_token", headers = bridge_auth[:]})
	check(bridge_list_with_token.status == 403, "bridge token must not call user bridge-management list API")
	me_with_bridge := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_bridge_me", headers = bridge_auth[:]})
	check(me_with_bridge.status == 403, "bridge token must not call user APIs")
	body_bridge_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = bridge_url(bridge_id, "/revoke"), body = strings.concatenate({"{\"token\":\"", bridge_token, "\"}"}), request_id = "req_bridge_body_token"})
	check(body_bridge_token.status == 401, "bridge token must be rejected when supplied in request body")
	revoke := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = bridge_url(bridge_id, "/revoke"), request_id = "req_revoke", remote_addr = "127.0.0.1", headers = alice[:]})
	check(revoke.status == 200 && strings.contains(revoke.body, "revoked"), "revoke endpoint must revoke bridge")
	revoked_bridge_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = bridge_url(bridge_id, ""), request_id = "req_revoked_bridge_token", headers = bridge_auth[:]})
	check(revoked_bridge_token.status == 403, "revoked bridge token must be rejected at API boundary")

	fmt.println("PASS: hub phase5 bridge http")
}

bridge_url :: proc(bridge_id, suffix: string) -> string {
	return strings.concatenate({"/api/v1/bridges/", bridge_id, suffix})
}

enrollment_url :: proc(enrollment_id: string) -> string {
	return strings.concatenate({"/api/v1/bridge-enrollments/", enrollment_id})
}

extract_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
