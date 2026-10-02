package http

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import user_service "odin_test:hub/service/user"

// REQ-TEL-1: write_bridge_json serializes telemetry_enabled
@(test)
test_write_bridge_json_telemetry_fields :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_telemetry_test",
		label = "Worker Alpha",
		machine_hostname = "worker-01",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = "{}",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "\"telemetry_enabled\":\"inherit\""), "default telemetry_enabled is inherit")

	bridge.telemetry_enabled = "enabled"
	b2 := strings.builder_make()
	defer strings.builder_destroy(&b2)
	write_bridge_json(&b2, bridge, nil)
	out2 := strings.to_string(b2)
	testing.expect(t, strings.contains(out2, "\"telemetry_enabled\":\"enabled\""), "telemetry_enabled is enabled")

	bridge.telemetry_enabled = "disabled"
	b3 := strings.builder_make()
	defer strings.builder_destroy(&b3)
	write_bridge_json(&b3, bridge, nil)
	out3 := strings.to_string(b3)
	testing.expect(t, strings.contains(out3, "\"telemetry_enabled\":\"disabled\""), "telemetry_enabled is disabled")
}

@(private = "file")
telemetry_test_counter: int = 0

@(private = "file")
telemetry_handler_fixture :: struct {
	db_path: string,
	conn: sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	us_repo: iface.User_Repository,
	ag_repo: iface.Agent_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	br_svc: bridge_service.Bridge_Service,
	us_svc: user_service.User_Service,
	ag_svc: agent_service.Agent_Service,
	auth_svc: auth_service.Auth_Service,
	bh: Bridge_Handlers,
	owner_user_id: string,
	bridge_id: string,
}

@(private = "file")
TELEMETRY_TEST_HEADERS := [1]contracts.HTTP_Header{
	{name = "X-authentik-username", value = "tanmay"},
}

@(private = "file")
TELEMETRY_TEST_CIDRS := [1]string{"127.0.0.1/32"}

@(private = "file")
setup_telemetry_test_fixture :: proc(t: ^testing.T, tag: string) -> ^telemetry_handler_fixture {
	f := new(telemetry_handler_fixture)
	seq := sync.atomic_add(&telemetry_test_counter, 1)
	f.db_path = fmt.tprintf("/tmp/test_bridge_telemetry_%s_%d_%d_%d.db", tag, os.get_pid(), time.now()._nsec, seq)
	os.remove(f.db_path)

	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)

	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()

	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)

	f.auth_svc = auth_service.new_auth_service(auth_service.Trusted_Proxy_Config{
		username_header = "X-authentik-username",
		trusted_proxy_cidrs = TELEMETRY_TEST_CIDRS[:],
		auto_provision_users = true,
	}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.bh = Bridge_Handlers{
		auth = &f.auth_svc,
		bridges = &f.br_svc,
		agents = &f.ag_svc,
	}

	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = TELEMETRY_TEST_HEADERS[:],
	})
	testing.expect(t, owner_ok, "trusted proxy owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner_user_id}
	enr, enr_ok, _ := bridge_service.create_enrollment(&f.br_svc, owner_auth, bridge_service.Create_Enrollment_Input{label = "Test Bridge"})
	testing.expect(t, enr_ok, "enrollment ok")
	enrolled, e_ok, _ := bridge_service.enroll_bridge(&f.br_svc, bridge_service.Enroll_Bridge_Input{enrollment_token = enr.token, machine_hostname = "test-box"})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)

	return f
}

@(private = "file")
teardown_telemetry_test_fixture :: proc(f: ^telemetry_handler_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	if len(f.owner_user_id) > 0 do delete(f.owner_user_id)
	if len(f.bridge_id) > 0 do delete(f.bridge_id)
	free(f)
}

// REQ-TEL-1: PATCH /api/v1/bridges/{id} updates telemetry_enabled and persists in repo
@(test)
test_patch_bridge_telemetry :: proc(t: ^testing.T) {
	f := setup_telemetry_test_fixture(t, "patch_tel")
	defer teardown_telemetry_test_fixture(f)

	// Verify initial value from repository is "inherit"
	initial_bridge, get_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, get_ok, "bridge found in repo")
	testing.expect_value(t, initial_bridge.telemetry_enabled, "inherit")

	// 1. PATCH to "enabled"
	req_enabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"enabled"}`,
		request_id = "req_patch_tel_1",
		remote_addr = "127.0.0.1:4444",
		headers = TELEMETRY_TEST_HEADERS[:],
	}
	resp_enabled := rename_bridge_handler(rawptr(&f.bh), req_enabled)
	testing.expect_value(t, resp_enabled.status, 200)
	testing.expect(t, strings.contains(resp_enabled.body, "\"telemetry_enabled\":\"enabled\""), "response has enabled")

	persisted, p_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, p_ok, "persisted bridge retrieved")
	testing.expect_value(t, persisted.telemetry_enabled, "enabled")

	// 2. PATCH to "disabled"
	req_disabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"disabled"}`,
		request_id = "req_patch_tel_2",
		remote_addr = "127.0.0.1:4444",
		headers = TELEMETRY_TEST_HEADERS[:],
	}
	resp_disabled := rename_bridge_handler(rawptr(&f.bh), req_disabled)
	testing.expect_value(t, resp_disabled.status, 200)
	testing.expect(t, strings.contains(resp_disabled.body, "\"telemetry_enabled\":\"disabled\""), "response has disabled")

	persisted2, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect_value(t, persisted2.telemetry_enabled, "disabled")

	// 3. PATCH back to "inherit"
	req_inherit := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"inherit"}`,
		request_id = "req_patch_tel_3",
		remote_addr = "127.0.0.1:4444",
		headers = TELEMETRY_TEST_HEADERS[:],
	}
	resp_inherit := rename_bridge_handler(rawptr(&f.bh), req_inherit)
	testing.expect_value(t, resp_inherit.status, 200)
	testing.expect(t, strings.contains(resp_inherit.body, "\"telemetry_enabled\":\"inherit\""), "response has inherit")

	persisted3, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect_value(t, persisted3.telemetry_enabled, "inherit")

	// 4. Invalid telemetry_enabled value rejected
	req_bad := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"random_value"}`,
		request_id = "req_patch_tel_bad",
		remote_addr = "127.0.0.1:4444",
		headers = TELEMETRY_TEST_HEADERS[:],
	}
	resp_bad := rename_bridge_handler(rawptr(&f.bh), req_bad)
	testing.expect_value(t, resp_bad.status, 400)

	// 5. Empty PATCH body rejected
	req_empty := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{}`,
		request_id = "req_patch_tel_empty",
		remote_addr = "127.0.0.1:4444",
		headers = TELEMETRY_TEST_HEADERS[:],
	}
	resp_empty := rename_bridge_handler(rawptr(&f.bh), req_empty)
	testing.expect_value(t, resp_empty.status, 400)
}
