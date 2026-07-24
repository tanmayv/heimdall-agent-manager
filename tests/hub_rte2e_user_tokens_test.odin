package hub_rte2e_user_tokens_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import iface "odin_test:hub/repository/iface"
import api_http "odin_test:hub/transport/http"

main :: proc() {
	test_old_user_api_token_table_upgrade()
	db_path := "/tmp/heimdall-hub-rte2e-user-tokens-test.db"
	_ = os.remove(db_path)
	config := app.default_config()
	config.database_path = db_path
	config.migrations_dir = "src/hub/repository/sqlite/migrations"
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config)
	check(ok, message)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}

	// Token issuance no longer auto-creates users: must fail for a nonexistent user.
	nonissue, nonissue_ok, nonissue_err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = domain.User_ID("nobody"), label = "x"})
	check(!nonissue_ok, "token issue must fail when user does not exist (no auto-create)")
	check(nonissue_err.code == .Not_Found, "issue for nonexistent user must return Not_Found")
	_ = nonissue

	// Explicit user creation: name + email mandatory, fresh usr_ id generated.
	_, _, no_name_err := user_service.create_user(&graph.users, user_service.Create_User_Input{email = "noname@example.com"})
	check(no_name_err.code == .Validation_Failed, "create_user must require name")
	_, _, no_email_err := user_service.create_user(&graph.users, user_service.Create_User_Input{name = "NoEmail"})
	check(no_email_err.code == .Validation_Failed, "create_user must require email")
	alice, alice_ok, alice_err := user_service.create_user(&graph.users, user_service.Create_User_Input{name = "Alice", email = "alice@example.com", display_name = "Alice"})
	check(alice_ok, alice_err.message)
	check(alice.email == "alice@example.com" && alice.name == "Alice", "create_user must persist name + email")

	issued, issued_ok, issued_err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = alice.user_id, label = "alice laptop", expires_at = "2099-01-01T00:00:00Z"})
	check(issued_ok, issued_err.message)
	check(strings.has_prefix(issued.plaintext, "hut_"), "plaintext user token must use hut_ prefix")
	check(strings.has_prefix(issued.token.token_id, "utok_"), "token_id must use utok_ prefix")
	check(issued.token.token_hash != issued.plaintext && strings.has_prefix(issued.token.token_hash, "sha1:"), "stored token value must be hashed at rest")

	listed, list_err := auth_service.list_user_api_tokens(&graph.auth, alice.user_id)
	check(list_err.code == .None && len(listed) == 1, "list must return one token metadata row")
	check(listed[0].label == "alice laptop" && listed[0].token_hash != issued.plaintext, "list must expose metadata and never plaintext")

	auth_header := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", issued.plaintext})}}
	me := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_user_token", remote_addr = "10.99.0.5", headers = auth_header[:]})
	check(me.status == 200 && strings.contains(me.body, "alice@example.com"), "valid user bearer token must authenticate from non-proxy clients")
	check(!strings.contains(me.body, issued.plaintext), "responses must not echo plaintext user tokens")

	query_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", query = strings.concatenate({"token=", issued.plaintext}), request_id = "req_query_token", remote_addr = "10.99.0.5", headers = auth_header[:]})
	check(query_token.status == 401, "query token pattern must be rejected even with an Authorization header")
	body_token := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = "/api/v1/chats", body = strings.concatenate({"{\"token\":\"", issued.plaintext, "\"}"}), request_id = "req_body_token", remote_addr = "10.99.0.5", headers = auth_header[:]})
	check(body_token.status == 401, "body token pattern must be rejected even with an Authorization header")

	revoked, revoked_ok, revoked_err := auth_service.revoke_user_api_token(&graph.auth, issued.token.token_id)
	check(revoked_ok && revoked.revoked_at != "", revoked_err.message)
	revoked_me := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_revoked", remote_addr = "10.99.0.5", headers = auth_header[:]})
	check(revoked_me.status == 401, "revoked user token must fail auth")

	// Single active token per user: issuing a second token auto-revokes the first.
	first, first_ok, _ := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = alice.user_id, label = "first"})
	check(first_ok, "first reissue must succeed")
	second, second_ok, second_err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = alice.user_id, label = "second"})
	check(second_ok, second_err.message)
	after_second, after_second_err := auth_service.list_user_api_tokens(&graph.auth, alice.user_id)
	check(after_second_err.code == .None, "list after reissue must not error")
	active_count := 0
	for t in after_second {
		if t.revoked_at == "" do active_count += 1
	}
	check(active_count == 1, "at most one active token must remain after reissue")
	first_record, first_found, _ := iface.user_token_get_by_id(graph.auth.user_tokens, first.token.token_id)
	check(first_found && first_record.revoked_at != "", "the first active token must be auto-revoked when a second is issued")
	// The newest token authenticates.
	second_header := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", second.plaintext})}}
	second_me := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_second", remote_addr = "10.99.0.5", headers = second_header[:]})
	check(second_me.status == 200, "newest active token must authenticate after reissue")

	expired_user, _, _ := user_service.create_user(&graph.users, user_service.Create_User_Input{name = "Expiry", email = "expiry@example.com"})
	expired, expired_ok, expired_err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = expired_user.user_id, label = "expired", expires_at = "2000-01-01T00:00:00Z"})
	check(expired_ok, expired_err.message)
	expired_header := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", expired.plaintext})}}
	expired_me := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_expired", remote_addr = "10.99.0.5", headers = expired_header[:]})
	check(expired_me.status == 401, "expired user token must fail auth")

	bridge_header := [?]contracts.HTTP_Header{{name = "Authorization", value = "Bearer hbr_fake"}}
	bridge_me := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_bridge", remote_addr = "10.99.0.5", headers = bridge_header[:]})
	check(bridge_me.status == 403, "bridge bearer token cannot call user APIs")
	fmt.println("PASS: hub rte2e user tokens")
}

test_old_user_api_token_table_upgrade :: proc() {
	db_path := "/tmp/heimdall-hub-rte2e-old-token-schema-test.db"
	_ = os.remove(db_path)
	conn, conn_ok, conn_err := sqlite.open(db_path)
	check(conn_ok, conn_err.message)
	check(sqlite.exec(&conn, "CREATE TABLE user_api_tokens (token_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, token_hash TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);"), "old user_api_tokens schema setup failed")
	sqlite.close(&conn)

	config := app.default_config()
	config.database_path = db_path
	config.migrations_dir = "src/hub/repository/sqlite/migrations"
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config)
	check(ok, message)
	upgrade_user, _, _ := user_service.create_user(&graph.users, user_service.Create_User_Input{name = "Upgrade", email = "upgrade@example.com"})
	issued, issued_ok, issued_err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = upgrade_user.user_id, label = "after upgrade", expires_at = "2099-01-01T00:00:00Z"})
	check(issued_ok, issued_err.message)
	listed, list_err := auth_service.list_user_api_tokens(&graph.auth, upgrade_user.user_id)
	check(list_err.code == .None && len(listed) == 1 && listed[0].label == "after upgrade", "upgraded old token table must support new token metadata")
	app.shutdown_graph(&graph)
	_ = os.remove(db_path)
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
