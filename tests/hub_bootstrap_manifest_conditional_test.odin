// HUB-1..HUB-3 acceptance test: the conditional, agent-keyed bootstrap manifest.
//
//  1. Cold GET  -> 200 + ETag + version + assembly hashes.
//  2. Warm GET with matching If-None-Match -> 304, no re-render (render counter
//     unchanged) and no memories scan.
//  3. GET a fragment hash from /bridge/blobs/{hash} -> 200 with the body.
//  4. Add a memory -> the content epoch bumps, next GET is a 200 with a NEW
//     version/ETag (memories fragment appears), and the stale If-None-Match no
//     longer yields a 304.
package hub_bootstrap_manifest_conditional_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import agent_service "odin_test:hub/service/agent"
import api_http "odin_test:hub/transport/http"

main :: proc() {
	db_path := "/tmp/heimdall-hub-bootstrap-manifest-conditional-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}

	// Enroll a bridge so we have a bridge bearer token for the /bridge/* routes.
	bridge_token := enroll_bridge(&graph, alice[:])
	bearer := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}

	// Create an agent with instructions so the identity fragment is non-empty.
	agent := request(&graph, "POST", "/api/v1/agents", "{\"name\":\"Backend Agent\",\"slug\":\"backend\",\"default_provider\":\"claude\",\"default_tier\":\"normal\",\"instructions\":\"You are a backend specialist.\"}", alice[:])
	check(agent.status == 201, "create agent must return 201")
	agent_id := extract_json_string(agent.body, "agent_id")
	check(agent_id != "", "agent_id must be present")

	manifest_url := strings.concatenate({"/api/v1/bridge/agents/", agent_id, "/bootstrap-manifest?role=worker&provider=claude"})

	// (1) COLD: 200 + ETag + version.
	renders_before := agent_service.bootstrap_manifest_render_count()
	cold := request(&graph, "GET", manifest_url, "", bearer[:])
	check(cold.status == 200, "cold manifest GET must be 200")
	etag := response_header(cold, "ETag")
	check(etag != "", "cold manifest must set an ETag header")
	check(strings.contains(cold.body, "\"version\":\""), "manifest must carry a version")
	check(strings.contains(cold.body, "agent_identity"), "manifest assembly must include the identity fragment")
	check(strings.contains(cold.body, "\"protocol\":2"), "manifest must be protocol 2")
	renders_after_cold := agent_service.bootstrap_manifest_render_count()
	check(renders_after_cold == renders_before + 1, "cold GET must render exactly once")

	// Pull one fragment hash out of the manifest for the blob GET below.
	frag_hash := extract_json_string(cold.body, "hash")
	check(strings.has_prefix(frag_hash, "sha256:"), "manifest must expose a sha256 fragment hash")

	// (2) WARM: matching If-None-Match -> 304, and NO additional render.
	// Do intervening heap churn between the cold insert and the warm lookup, then
	// repeat the warm GET, to surface any read-after-free on the map key (a
	// transient key freed after insert would leave the stored key's bytes dangling;
	// churn reallocates that buffer with different content and the lookup MISSes ->
	// spurious re-render). A correct clone-on-insert survives this.
	churn := make([dynamic]string)
	for i := 0; i < 256; i += 1 {
		append(&churn, strings.concatenate({"heap-churn-filler-", itoa(i), "-padding-padding-padding"}))
	}
	inm := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}, {name = "If-None-Match", value = etag}}
	warm := request(&graph, "GET", manifest_url, "", inm[:])
	check(warm.status == 304, "warm GET with matching ETag must be 304")
	check(warm.body == "", "304 response must have an empty body")
	// Second warm GET after even more churn: still a HIT, still no re-render.
	for i := 0; i < 256; i += 1 {
		append(&churn, strings.concatenate({"more-heap-churn-", itoa(i), "-xxxxxxxxxxxxxxxxxxxxxxxx"}))
	}
	warm2 := request(&graph, "GET", manifest_url, "", inm[:])
	check(warm2.status == 304, "repeat warm GET after heap churn must still be 304 (no dangling map key)")
	renders_after_warm := agent_service.bootstrap_manifest_render_count()
	check(renders_after_warm == renders_after_cold, "warm 304s must NOT re-render (no memories scan) even after intervening allocations")
	_ = churn

	// (3) Per-hash immutable blob GET.
	blob_url := strings.concatenate({"/api/v1/bridge/blobs/", url_encode_hash(frag_hash)})
	blob := request(&graph, "GET", blob_url, "", bearer[:])
	check(blob.status == 200, "blob GET must be 200")
	check(strings.contains(blob.body, "backend specialist"), "blob body must contain the fragment content")
	cache_control := response_header(blob, "Cache-Control")
	check(strings.contains(cache_control, "immutable"), "blob response must be marked immutable")

	// (4) Add a memory -> epoch bump -> next GET is a fresh 200 with a NEW ETag,
	//     and the old If-None-Match no longer matches.
	mem := request(&graph, "POST", "/api/v1/memories", strings.concatenate({"{\"type\":\"fact\",\"title\":\"House Style\",\"body\":\"Prefer explicit error handling.\",\"agent_id\":\"", agent_id, "\",\"status\":\"active\"}"}), alice[:])
	check(mem.status == 201 || mem.status == 200, "create memory must succeed")

	after_mem := request(&graph, "GET", manifest_url, "", inm[:])
	check(after_mem.status == 200, "after a memory change the stale ETag must NOT yield 304")
	new_etag := response_header(after_mem, "ETag")
	check(new_etag != "" && new_etag != etag, "memory change must produce a new ETag/version")
	check(strings.contains(after_mem.body, "memories"), "manifest must now include a memories fragment")

	fmt.println("PASS: hub bootstrap manifest conditional")
}

url_encode_hash :: proc(hash: string) -> string {
	// Only the ':' needs encoding for our router/path handling.
	replaced, _ := strings.replace_all(hash, ":", "%3A")
	return replaced
}

response_header :: proc(resp: api_http.Response, name: string) -> string {
	for h in resp.headers {
		if strings.equal_fold(h.name, name) do return h.value
	}
	return ""
}

enroll_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> string {
	created := request(graph, "POST", "/api/v1/bridge-enrollments", "{\"label\":\"Alice Bridge\"}", headers)
	check(created.status == 201, "bridge enrollment create failed")
	token := extract_json_string(created.body, "enrollment_token")
	enroll_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	enrolled := request(graph, "POST", "/api/v1/bridges/enroll", "{\"machine\":{\"hostname\":\"host\"},\"capabilities\":[{\"provider\":\"claude\",\"tiers\":[\"normal\",\"smart\"],\"default_tier\":\"normal\"}]}", enroll_headers[:])
	check(enrolled.status == 201, enrolled.body)
	return extract_json_string(enrolled.body, "bridge_token")
}

request :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	// Mirror the real server's split_target_query: the router matches on a bare
	// path, and handlers read the query string separately.
	bare := path
	query := ""
	if q := strings.index_byte(path, '?'); q >= 0 {
		bare = path[:q]
		query = path[q + 1:]
	}
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = bare, query = query, body = body, request_id = "req_bmc", remote_addr = "127.0.0.1", headers = headers})
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

itoa :: proc(n: int) -> string {
	return fmt.aprintf("%d", n)
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
