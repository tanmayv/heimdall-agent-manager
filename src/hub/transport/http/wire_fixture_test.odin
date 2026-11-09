package http

// Shared real-stack fixture for handler tests: a session-cookie owner, enrolled
// bridges and an instance assertion for agent-action requests, over sqlite.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import user_service "odin_test:hub/service/user"

wire_fixture :: struct {
	db_path:  string,
	conn:     sqlite.Conn,
	tc_impl:  sqlite.Taskchain_Repo_SQLite,
	ag_impl:  sqlite.Agent_Repo_SQLite,
	br_impl:  sqlite.Bridge_Repo_SQLite,
	us_impl:  sqlite.User_Repo_SQLite,
	tc_repo:  iface.Taskchain_Repository,
	ag_repo:  iface.Agent_Repository,
	br_repo:  iface.Bridge_Repository,
	us_repo:  iface.User_Repository,
	clock:    platform.Clock,
	ids:      platform.ID_Generator,
	ag_svc:   agent_service.Agent_Service,
	br_svc:   bridge_service.Bridge_Service,
	us_svc:   user_service.User_Service,
	auth_svc: auth_service.Auth_Service,
	user_headers: []contracts.HTTP_Header, // session cookie for the fixture owner
	ah:       Agent_Action_Handlers,
	bh:       Bridge_Handlers,

	owner:          domain.User_ID,
	chain_id:       domain.Task_Chain_ID,
	bridge_pin:     string, // owner bridge used as the pin / clear / reject baseline
	bridge_alt:     string, // second owner bridge used as the repin target
	bridge_foreign: string,
	bridge_token:   string, // plaintext token of bridge_pin (agent-action auth)
	instance_id:    string,
	// The agent-action headers live in the (heap) fixture so their backing array
	// outlives the request frame, and the two dynamic values are fixture-owned
	// clones of setup scratch strings.
	agent_headers:     [2]contracts.HTTP_Header,
	agent_auth_value:  string,
	agent_relay_value: string,
}

// File-scope so the backing arrays outlive the frames that build requests and
// store the cidrs: a compound literal allocated inside wire_setup dangles once
// setup returns (auth.remote_addr_trusted reads it on every later request).

wire_cookie_request :: proc(f: ^wire_fixture, method, path, body: string) -> Request {
	return Request{
		method      = method,
		path        = path,
		body        = body,
		request_id  = "req_wire",
		remote_addr = "127.0.0.1:4444",
		headers     = f.user_headers,
	}
}

wire_agent_request :: proc(f: ^wire_fixture, action, body: string) -> Request {
	return Request{
		method      = "POST",
		path        = fmt.tprintf("/api/v1/agent-actions/tasks/%s", action),
		body        = body,
		request_id  = "req_wire_agent",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
}

// wire_body builds a request body on the heap. It must NOT be fmt.tprintf: Odin's
// formatter treats `{`/`}` as directives, so a tprintf'd JSON literal comes back as
// `%!(MISSING CLOSE BRACE)title":...` — a body with NO fields, which the service
// then rejects ("task title is required"). The caller owns the result.
wire_body :: proc(parts: []string) -> string {
	return strings.concatenate(parts)
}

// wire_enroll_bridge provisions a bridge for an owner through the DEVICE-GRANT path,
// the only enrollment there is (REQ-ENROLL-9).
//
// It takes the owner as a plain user id rather than an Auth_Context: the deleted
// create_enrollment derived the owner from an Auth_Context, while
// enroll_bridge_from_device_grant takes the approving user directly — the browser
// approval is what establishes ownership, so there is no request context to read.
// The `wire-host-foreign` case still works, which is what matters here: it is how
// this file builds a bridge owned by SOMEONE ELSE to test cross-owner task scoping.
wire_enroll_bridge :: proc(t: ^testing.T, f: ^wire_fixture, owner_user_id: string, hostname: string, token_out: ^string) -> string {
	enrolled, e_ok, e_err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = hostname,
	})
	testing.expectf(t, e_ok, "bridge %s enrolled (%s)", hostname, e_err.message)
	if token_out != nil do token_out^ = enrolled.bridge_token
	return enrolled.bridge.bridge_id
}

wire_setup :: proc(t: ^testing.T, tag: string) -> ^wire_fixture {
	f := new(wire_fixture)
	f.db_path = ":memory:"
	

	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.tc_repo = sqlite.new_taskchain_repository(&f.tc_impl, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_impl, &f.conn)
	f.br_repo = sqlite.new_bridge_repository(&f.br_impl, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_impl, &f.conn)

	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()

	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)

	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.ah = Agent_Action_Handlers{auth = &f.auth_svc, agents = &f.ag_svc, bridges = &f.br_svc}
	f.bh = Bridge_Handlers{auth = &f.auth_svc, agents = &f.ag_svc, bridges = &f.br_svc, chains = &f.tc_repo}

	// Resolve the owner through the SAME session-cookie path the cookie handlers use
	// (auto-provisioned), so the fixture owner id is exactly what auth will produce.
	f.user_headers = http_test_login(t, &f.auth_svc, "wire_owner")
	owner_ctx, owner_ok, owner_err := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers     = f.user_headers,
	})
	testing.expectf(t, owner_ok, "session owner resolves (%s)", owner_err.message)
	f.owner = domain.User_ID(owner_ctx.user_id)

	f.chain_id = domain.Task_Chain_ID("chain_wire_tb2")
	// The fixture chain is a Bridge-owned chain: its owner-registry route.
	route_ok := sqlite.exec(&f.conn, fmt.tprintf("INSERT INTO owner_local_chains VALUES('%s','%s','brg_wire_owner','key_wire','dev_wire','%s','{}')", f.chain_id, f.owner, strings.repeat("0", 64, context.temp_allocator)))
	testing.expect(t, route_ok, "owner route fixture saved")
	owner_auth := contracts.Auth_Context{kind = .Session, user_id = string(f.owner)}
	f.bridge_pin = wire_enroll_bridge(t, f, owner_auth.user_id, "wire-host-pin", &f.bridge_token)
	f.bridge_alt = wire_enroll_bridge(t, f, owner_auth.user_id, "wire-host-alt", nil)
	f.bridge_foreign = wire_enroll_bridge(t, f, "wire_foreign_owner", "wire-host-foreign", nil)
	// Enrollment mints its ids/token on the temp allocator; the fixture must own
	// stable copies since they feed later comparisons and request bodies.
	f.bridge_token = strings.clone(f.bridge_token)
	f.bridge_pin = strings.clone(f.bridge_pin)
	f.bridge_alt = strings.clone(f.bridge_alt)
	f.bridge_foreign = strings.clone(f.bridge_foreign)

	f.instance_id = "inst_wire_tb2"
	_, inst_ok, inst_err := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
		agent_instance_id = f.instance_id,
		owner_user_id     = f.owner,
		agent_id          = "agt_wire_tb2",
		bridge_id         = f.bridge_pin,
		display_name      = "wire instance",
		chain_id          = string(f.chain_id),
		runtime_status    = "running",
		startup_status    = "ready",
		created_at        = "2026-09-25T10:00:00Z",
		updated_at        = "2026-09-25T10:00:00Z",
	})
	testing.expectf(t, inst_ok, "instance fixture saved (%s)", inst_err.message)

	f.agent_auth_value = strings.concatenate({"Bearer ", f.bridge_token})
	f.agent_relay_value = strings.concatenate({"hit_", f.instance_id})
	f.agent_headers[0] = contracts.HTTP_Header{name = "Authorization", value = f.agent_auth_value}
	f.agent_headers[1] = contracts.HTTP_Header{name = "X-Heimdall-Instance-Token", value = f.agent_relay_value}
	return f
}

wire_teardown :: proc(f: ^wire_fixture) {
	sqlite.close(&f.conn)
	
	delete(f.bridge_token)
	delete(f.bridge_pin)
	delete(f.bridge_alt)
	delete(f.bridge_foreign)
	delete(f.agent_auth_value)
	delete(f.agent_relay_value)
	free(f)
}


// wire_seed_legacy_chain seeds a legacy (pre-removal) Hub chain row owned by
// the fixture owner: a read-only record the one-shot importer can export.
wire_seed_legacy_chain :: proc(t: ^testing.T, f: ^wire_fixture, chain_id: string) {
	_, ok, err := iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id      = domain.Task_Chain_ID(chain_id),
		owner_user_id = f.owner,
		title         = "Legacy Chain",
		publish_state = .Published,
		status        = .Active,
		kind          = domain.CHAIN_KIND_MIXED_WORK,
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	})
	testing.expectf(t, ok, "legacy chain fixture saved (%s)", err.message)
}
