package http

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import sqlite "odin_test:hub/repository/sqlite"

// H1 (R4 review follow-up): route-level coverage of
// POST /api/v1/owner-local/migrations/abort through the router (with the
// production guard) and real auth resolution. An agent instance token of the
// chain owner's own account is refused with 403 and changes nothing; the
// owner's browser session aborts the migration.
@(test)
owner_migration_abort_route_refuses_instance_token_and_accepts_user_session :: proc(t: ^testing.T) {
	f := wire_setup(t, "abort-route")
	defer wire_teardown(f)
	saved := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = saved
	chain := string(f.chain_id)
	digest := strings.repeat("a", 64, context.temp_allocator)
	testing.expect(t, sqlite.exec(&f.conn, fmt.tprintf(`INSERT INTO owner_legacy_source_generations VALUES('%s','%s',0);
	  INSERT INTO owner_legacy_migrations(migration_id,chain_id,account_id,owner_bridge_id,owner_key_id,selection_digest,state,revision)
	  VALUES('mig_route','%s','%s','%s','bridge_key','%s','draining',1);`, chain, string(f.owner), chain, string(f.owner), f.bridge_pin, digest)))

	h := Bridge_Handlers{auth = &f.auth_svc, taskchains = &f.tc_svc}
	router := new_router()
	defer router_free(&router)
	router.guard = owner_authority_guard
	router.guard_ctx = rawptr(&f.th)
	router_add(&router, "POST", "/api/v1/owner-local/migrations/abort", rawptr(&h), owner_migration_abort_handler)
	body := strings.concatenate({`{"chain_id":"`, chain, `","migration_id":"mig_route"}`}, context.temp_allocator)
	request :: proc(body: string, headers: []contracts.HTTP_Header) -> Request {
		return Request{method = "POST", path = "/api/v1/owner-local/migrations/abort", body = body, request_id = "req_abort_route", remote_addr = "127.0.0.1:4444", headers = headers}
	}
	state :: proc(f: ^wire_fixture) -> string {
		rows, _ := sqlite.legacy_metadata(&f.conn, "SELECT (SELECT count(*) FROM owner_legacy_migrations WHERE migration_id='mig_route'),(SELECT count(*) FROM owner_legacy_aborted_migrations WHERE migration_id='mig_route')", 2)
		return fmt.tprintf("%s/%s", rows[0][0], rows[0][1])
	}

	// The agent's instance token (same account) is refused before any write.
	agent := router_dispatch(&router, request(body, f.agent_headers[:]))
	testing.expectf(t, agent.status == 403, "instance token abort: %d %s", agent.status, agent.body)
	testing.expect(t, strings.contains(agent.body, "agent tokens cannot abort"), agent.body)
	testing.expect_value(t, state(f), "1/0")

	// The owner's browser session aborts it.
	user := router_dispatch(&router, request(body, f.user_headers))
	testing.expectf(t, user.status == 200 && strings.contains(user.body, `"state":"aborted"`), "session abort: %d %s", user.status, user.body)
	testing.expect_value(t, state(f), "0/1")
	// Still refused for the agent after the abort (replay is a human verb too).
	again := router_dispatch(&router, request(body, f.agent_headers[:]))
	testing.expect_value(t, again.status, 403)
}
