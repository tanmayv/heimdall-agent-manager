package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

// end-to-end test for REQ-LSP-CFG-1: dir_prefix normalization and "/" rejection.
// Verifies that the create handler:
//   1. Rejects "/" with 400 (Validation_Failed) — would otherwise normalize to ""
//      (the language-default sentinel) and overwrite the user's existing default config.
//   2. Rejects "///" with 400 for the same reason.
//   3. A pre-existing language default (dir_prefix="") survives both rejected POSTs
//      byte-identical: same config_id, same cmd, unchanged.
@(test)
test_lsp_server_config_slash_dir_prefix_rejected :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-lsp-handler-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		username_header      = "X-authentik-username",
		display_name_header  = "X-authentik-name",
		email_header         = "X-authentik-email",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		logout_url           = "/_dev/logout",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}

	// --- Enroll a bridge for alice ---
	enroll_created := api_http.router_dispatch(&graph.router, api_http.Request{
		method     = "POST",
		path       = "/api/v1/bridge-enrollments",
		body       = `{"label":"Alice Bridge"}`,
		request_id = "req_lsph_1",
		remote_addr = "127.0.0.1",
		headers    = alice[:],
	})
	testing.expect(t, enroll_created.status == 201, "bridge enrollment must succeed")

	enrollment_token := ""
	if idx := strings.index(enroll_created.body, "\"enrollment_token\":\""); idx >= 0 {
		rest := enroll_created.body[idx + len("\"enrollment_token\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do enrollment_token = rest[:end]
	}

	enroll_bearer := fmt.tprintf("Bearer %s", enrollment_token)
	enroll_auth := [?]contracts.HTTP_Header{{name = "Authorization", value = enroll_bearer}}
	enrolled := api_http.router_dispatch(&graph.router, api_http.Request{
		method     = "POST",
		path       = "/api/v1/bridges/enroll",
		body       = `{"machine":{"hostname":"lsp-host"},"capabilities":[]}`,
		request_id = "req_lsph_2",
		remote_addr = "127.0.0.1",
		headers    = enroll_auth[:],
	})
	testing.expect(t, enrolled.status == 201, "bridge enroll must succeed")

	bridge_id := ""
	if idx := strings.index(enrolled.body, "\"bridge_id\":\""); idx >= 0 {
		rest := enrolled.body[idx + len("\"bridge_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do bridge_id = rest[:end]
	}
	testing.expect(t, bridge_id != "", "bridge_id must be non-empty after enrollment")

	lsp_path := fmt.tprintf("/api/v1/bridges/%s/lsp-servers", bridge_id)

	// --- Step 1: Create a language default (dir_prefix="") ---
	default_created := api_http.router_dispatch(&graph.router, api_http.Request{
		method     = "POST",
		path       = lsp_path,
		body       = `{"language":"go","cmd":"gopls","dir_prefix":""}`,
		request_id = "req_lsph_3",
		remote_addr = "127.0.0.1",
		headers    = alice[:],
	})
	testing.expect(t, default_created.status == 200, "creating language default must succeed")

	// Capture the config_id of the default row to verify it is unchanged after rejections.
	default_config_id := ""
	if idx := strings.index(default_created.body, "\"config_id\":\""); idx >= 0 {
		rest := default_created.body[idx + len("\"config_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do default_config_id = rest[:end]
	}
	testing.expect(t, default_config_id != "", "default config_id must be non-empty")

	// --- Step 2: POST dir_prefix="/" must be rejected with 400 ---
	slash_rejected := api_http.router_dispatch(&graph.router, api_http.Request{
		method     = "POST",
		path       = lsp_path,
		body       = `{"language":"go","cmd":"gopls-root","dir_prefix":"/"}`,
		request_id = "req_lsph_4",
		remote_addr = "127.0.0.1",
		headers    = alice[:],
	})
	testing.expect(t, slash_rejected.status == 400, `POST dir_prefix="/" must return 400`)

	// --- Step 3: POST dir_prefix="///" must also be rejected with 400 ---
	multi_slash_rejected := api_http.router_dispatch(&graph.router, api_http.Request{
		method     = "POST",
		path       = lsp_path,
		body       = `{"language":"go","cmd":"gopls-root","dir_prefix":"///"}`,
		request_id = "req_lsph_5",
		remote_addr = "127.0.0.1",
		headers    = alice[:],
	})
	testing.expect(t, multi_slash_rejected.status == 400, `POST dir_prefix="///" must return 400`)

	// --- Step 4: The default row must survive both rejections unchanged ---
	list_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method     = "GET",
		path       = lsp_path,
		request_id = "req_lsph_6",
		remote_addr = "127.0.0.1",
		headers    = alice[:],
	})
	testing.expect(t, list_resp.status == 200, "list must succeed")
	testing.expect(t, strings.contains(list_resp.body, default_config_id), "default config_id must be unchanged after rejected POSTs")
	testing.expect(t, strings.contains(list_resp.body, "\"cmd\":\"gopls\""), "default row cmd must be unchanged")
	// Confirm only one config exists (rejections did not create extra rows).
	testing.expect(t, strings.count(list_resp.body, "\"config_id\"") == 1, "exactly one config must exist after rejections")
}
