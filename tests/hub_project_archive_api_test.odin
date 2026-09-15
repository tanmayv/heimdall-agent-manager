package hub_project_archive_api_test

// HTTP-level coverage for REQ-PROJ-ARCHIVE-1 (project soft-archive), independent of
// any bridge setup so it exercises the archive route + ownership + list parity in
// isolation. Mirrors how durable agents are archived.

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

req :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, body = body, request_id = "req_pa", remote_addr = "127.0.0.1", headers = headers})
}

json_str :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	tail := body[idx + len(needle):]
	end := strings.index(tail, "\""); if end < 0 do return ""
	return tail[:end]
}

main :: proc() {
	db_path := "/tmp/project_archive_api_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	// Create -> defaults to state active.
	created := req(&graph, "POST", "/api/v1/projects", "{\"name\":\"Archive Me\",\"slug\":\"archive-me\",\"default_path\":\"/tmp/archive-me\"}", alice[:])
	check(created.status == 201, fmt.tprintf("create project: %d %s", created.status, created.body))
	check(strings.contains(created.body, "\"state\":\"active\""), "new project must default to state active")
	pid := json_str(created.body, "project_id")
	check(pid != "", "project_id must be present")
	archive_path := strings.concatenate({"/api/v1/projects/", pid, "/archive"})

	// Ownership enforced: another user cannot archive it (hidden -> 404).
	bob_arch := req(&graph, "POST", archive_path, "", bob[:])
	check(bob_arch.status == 404, fmt.tprintf("cross-owner archive must be 404, got %d", bob_arch.status))

	// Owner archives -> 200 and state flips to archived.
	arch := req(&graph, "POST", archive_path, "", alice[:])
	check(arch.status == 200 && strings.contains(arch.body, "\"state\":\"archived\""), fmt.tprintf("owner archive must set state archived: %d %s", arch.status, arch.body))

	// Soft-only: still readable with archived state (row not removed).
	detail := req(&graph, "GET", strings.concatenate({"/api/v1/projects/", pid}), "", alice[:])
	check(detail.status == 200 && strings.contains(detail.body, "\"state\":\"archived\""), "archived project must still be readable with archived state")

	// List parity with agents: archived project still appears in the owner's list.
	list := req(&graph, "GET", "/api/v1/projects", "", alice[:])
	check(list.status == 200 && strings.contains(list.body, pid), "archived project must still be listed (parity with agents)")

	// Re-archiving is idempotent (still archived, still 200).
	arch2 := req(&graph, "POST", archive_path, "", alice[:])
	check(arch2.status == 200 && strings.contains(arch2.body, "\"state\":\"archived\""), "re-archiving must remain archived")

	// Archiving a non-existent project -> 404.
	missing := req(&graph, "POST", "/api/v1/projects/proj_does_not_exist/archive", "", alice[:])
	check(missing.status == 404, fmt.tprintf("archiving a missing project must 404, got %d", missing.status))

	fmt.println("PASS: hub project archive api test")
}
