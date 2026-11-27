package http

import "base:runtime"
import "core:encoding/json"
import "core:net"
import "core:thread"
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
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

import provider_service "odin_test:hub/service/provider"

@(test)
c2_copilot_native_install_tracks_pinned_identity_and_opt_in :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := extension_test_setup(t, "c2_copilot_install"); defer extension_test_teardown(f)
    path := fmt.tprintf("/api/v1/bridges/%s/providers/copilot/acp-adapter", f.bridge_id)
    response := bridge_provider_acp_adapter_handler(&f.ph, extension_test_request(f,path,`{"action":"install"}`))
    if !testing.expectf(t,response.status==202,"%d %s",response.status,response.body) do return
    id:=json_string(response.body,"command_id");defer delete(id)
    testing.expect_value(t,json_string(f.sink_rec.last_cmd.body_json,"provider",context.temp_allocator),"copilot")
    testing.expect_value(t,json_string(f.sink_rec.last_cmd.body_json,"adapter_version",context.temp_allocator),"1.0.114")
    again:=bridge_provider_acp_adapter_handler(&f.ph,extension_test_request(f,path,`{"action":"install"}`))
    testing.expect(t,again.status==202 && f.sink_rec.count==1)
    extension_test_report(t,f,id,`[{"provider":"copilot","state":"present","acp_adapter":{"installed":true,"state":"ready","version":"1.0.114","provider":"copilot","profile":"copilot","runtime_kind":"native","checked_at":"2026-11-19T00:00:00Z"}}]`)
    result:=strings.concatenate({`{"command_id":"`,id,`","status":"succeeded"}`},context.temp_allocator)
    testing.expect_value(t,bridge_extension_frame(&f.bh,f.bridge_id,"command_result",result).code,domain.Error_Code.None)
    testing.expect_value(t,extension_test_state(t,f,id),"succeeded")
    transport,err:=iface.get_provider_transport(&f.pr_repo,f.bridge_id,"copilot");defer delete(transport)
    testing.expect(t,err.code==.None && transport=="","installation must not select ACP")
}

@(test)
t6_provider_status_exposes_acp_capability_and_latest_install_by_kind :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := extension_test_setup(t, "t6_runtime_status")
    defer extension_test_teardown(f)
    req := extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id))
    req.method = "GET"
    before := bridge_provider_status_handler(&f.ph, req)
    testing.expect_value(t, before.status, 200)
    testing.expect(t, strings.contains(before.body, `"acp_runtime_supported":false`), before.body)
    bridge, found, err := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
    if !testing.expect(t, found && err.code == .None) do return
    defer domain.bridge_destroy(&bridge)
    delete(bridge.capabilities_json)
    bridge.capabilities_json = strings.clone(`{"features":["acp_runtime_v1"]}`)
    saved, saved_ok, save_err := iface.bridge_save_bridge(&f.br_repo, bridge)
    defer if saved_ok do domain.bridge_destroy(&saved)
    testing.expect(t, saved_ok && save_err.code == .None)
    for item in ([]struct{id, kind, state: string}{
        {"t6_acp_old", "install_acp_adapter", "failed"},
        {"t6_extension", "install", "succeeded"},
        {"t6_acp_new", "install_acp_adapter", "dispatched"},
        {"t6_discovery", "discovery", "succeeded"},
    }) {
        created, create_err := iface.provider_extension_command_create(&f.pr_repo, {
            command_id = item.id, bridge_id = f.bridge_id, provider = "claude", profile_id = "claude",
            kind = item.kind, state = item.state,
        })
        testing.expect(t, created && create_err.code == .None)
    }
    after := bridge_provider_status_handler(&f.ph, req)
    testing.expect_value(t, after.status, 200)
    testing.expect(t, strings.contains(after.body, `"acp_runtime_supported":true`), after.body)
    testing.expect(t, strings.contains(after.body, `"command_id":"t6_acp_new"`) && strings.contains(after.body, `"kind":"install_acp_adapter"`), after.body)
    testing.expect(t, strings.contains(after.body, `"command_id":"t6_extension"`), after.body)
    testing.expect(t, !strings.contains(after.body, `t6_acp_old`) && !strings.contains(after.body, `t6_discovery`), after.body)
}

// T2: every providers[] entry carries the Hub-computed ACP verdict, so the UI
// never re-derives capability/adapter rules.
@(test)
t2_provider_status_exposes_acp_availability_per_provider :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := extension_test_setup(t, "t2_acp_availability")
    defer extension_test_teardown(f)
    req := extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id))
    req.method = "GET"
    availability :: proc(t: ^testing.T, body, provider: string) -> string {
        value, err := json.parse_string(body)
        if !testing.expect(t, err == nil, body) do return ""
        data, _ := value.(json.Object)["data"].(json.Object)
        providers, _ := data["providers"].(json.Array)
        for item in providers {
            row := item.(json.Object)
            if name, _ := row["provider"].(json.String); name != provider do continue
            if row["profile_id"].(json.String) != provider do continue
            // Re-emit in wire order; json.Object iteration order is unspecified.
            verdict, _ := row["acp_availability"].(json.Object)
            available, _ := verdict["available"].(json.Boolean)
            reason, _ := verdict["reason"].(json.String)
            fix := "null"
            if value, is_string := verdict["fix"].(json.String); is_string do fix = fmt.tprintf(`"%s"`, value)
            else if _, is_null := verdict["fix"].(json.Null); !is_null do fix = "<missing>"
            return fmt.tprintf(`{{"available":%v,"reason":"%s","fix":%s}}`, bool(available), reason, fix)
        }
        return ""
    }
    before := bridge_provider_status_handler(&f.ph, req)
    testing.expect_value(t, before.status, 200)
    testing.expect_value(t, availability(t, before.body, "claude"), `{"available":false,"reason":"unsupported_bridge","fix":"update_bridge"}`)
    // A catalog provider without an ACP recipe never asks for a bridge update.
    testing.expect_value(t, availability(t, before.body, "antigravity"), `{"available":false,"reason":"no_recipe","fix":null}`)

    bridge, found, err := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
    if !testing.expect(t, found && err.code == .None) do return
    defer domain.bridge_destroy(&bridge)
    delete(bridge.capabilities_json)
    bridge.capabilities_json = strings.clone(`{"features":["acp_runtime_v1"]}`)
    saved, saved_ok, save_err := iface.bridge_save_bridge(&f.br_repo, bridge)
    defer if saved_ok do domain.bridge_destroy(&saved)
    testing.expect(t, saved_ok && save_err.code == .None)
    unchecked := bridge_provider_status_handler(&f.ph, req)
    testing.expect_value(t, availability(t, unchecked.body, "claude"), `{"available":false,"reason":"not_checked","fix":"check_now"}`)

    d, _ := contracts.acp_provider_descriptor("claude")
    for item in ([]struct{adapter, want: string}{
        {`{"installed":false,"state":"missing","checked_at":"2026-11-26T00:00:00Z"}`, `{"available":false,"reason":"adapter_missing","fix":"install_adapter"}`},
        {`{"installed":false,"state":"installing","checked_at":"2026-11-26T00:00:00Z"}`, `{"available":false,"reason":"installing","fix":null}`},
        {fmt.tprintf(`{{"installed":true,"state":"ready","version":"%s","checked_at":"2026-11-26T00:00:00Z","provider":"claude","profile":"claude","runtime_kind":"adapter"}}`, d.pkg.version), `{"available":true,"reason":"ready","fix":null}`},
    }) {
        ok, upsert_err := iface.bridge_provider_status_upsert(&f.pr_repo, {
            bridge_id = f.bridge_id, provider = "claude", profile_id = "claude", state = "present",
            checked_at = "2026-11-26T00:00:00Z", acp_adapter_json = item.adapter,
        })
        testing.expect(t, ok && upsert_err.code == .None)
        response := bridge_provider_status_handler(&f.ph, req)
        testing.expect_value(t, response.status, 200)
        testing.expect_value(t, availability(t, response.body, "claude"), item.want)
    }
}

@(test)
t4_acp_install_endpoint_coalesces_and_tracks_completion :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := extension_test_setup(t, "acp_install")
    defer extension_test_teardown(f)
    path := fmt.tprintf("/api/v1/bridges/%s/providers/claude/acp-adapter", f.bridge_id)
    response := bridge_provider_acp_adapter_handler(rawptr(&f.ph), extension_test_request(f, path, `{"action":"install"}`))
    if !testing.expectf(t, response.status == 202, "%d %s", response.status, response.body) do return
    id := json_string(response.body, "command_id"); defer delete(id)
    testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type", context.temp_allocator), "install_acp_adapter")
    testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "adapter_version", context.temp_allocator), "0.108.0")
    testing.expect(t, strings.has_prefix(json_string(f.sink_rec.last_cmd.body_json, "catalog_etag", context.temp_allocator), "sha256:"))
    second := bridge_provider_acp_adapter_handler(rawptr(&f.ph), extension_test_request(f, path, `{"action":"install"}`))
    testing.expect_value(t, second.status, 202)
    testing.expect_value(t, json_string(second.body, "command_id", context.temp_allocator), id)
    testing.expect_value(t, f.sink_rec.count, 1)
    extension_test_report(t, f, id, `[{"provider":"claude","state":"present","acp_adapter":{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-18T00:00:00Z"}}]`)
    result := strings.concatenate({`{"command_id":"`, id, `","status":"succeeded"}`}, context.temp_allocator)
    testing.expect_value(t, bridge_extension_frame(&f.bh, f.bridge_id, "command_result", result).code, domain.Error_Code.None)
    testing.expect_value(t, extension_test_state(t, f, id), "succeeded")
}

@(test)
t4_acp_settings_starts_shared_install_without_saving_transport :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := extension_test_setup(t, "acp_settings_install"); defer extension_test_teardown(f)
    bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id); defer domain.bridge_destroy(&bridge)
    bridge.capabilities_json = strings.clone(`{"features":["acp_runtime_v1"]}`)
    iface.bridge_save_bridge(&f.br_repo, bridge)
    iface.bridge_provider_status_upsert(&f.pr_repo, {bridge_id = f.bridge_id, provider = "claude", state = "present", acp_adapter_json = `{"state":"missing","installed":false}`})
    path := fmt.tprintf("/api/v1/bridges/%s/providers/claude", f.bridge_id)
    response := bridge_provider_enable_handler(&f.ph, extension_test_request(f, path, `{"transport":"acp"}`))
    testing.expect(t, response.status == 409 && strings.contains(response.body, "acp_installing"), response.body)
    testing.expect_value(t, f.sink_rec.count, 1)
    transport, err := iface.get_provider_transport(&f.pr_repo, f.bridge_id, "claude"); defer delete(transport)
    testing.expect(t, err.code == .None && transport == "")
    install_path := strings.concatenate({path, "/acp-adapter"})
    retry := bridge_provider_acp_adapter_handler(&f.ph, extension_test_request(f, install_path, `{"action":"install"}`))
    testing.expect_value(t, retry.status, 202)
    testing.expect_value(t, f.sink_rec.count, 1)
}

@(test)
t4_acp_install_endpoint_rejects_untrusted_recipe_and_offline :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := extension_test_setup(t, "acp_invalid")
    defer extension_test_teardown(f)
    path := fmt.tprintf("/api/v1/bridges/%s/providers/claude/acp-adapter", f.bridge_id)
    for body in ([]string{`{}`, `{"action":"install","adapter_version":"latest"}`, `{"action":"login"}`, `[]`}) {
        response := bridge_provider_acp_adapter_handler(rawptr(&f.ph), extension_test_request(f, path, body))
        testing.expect_value(t, response.status, 400)
    }
    // pi has no ACP transport (codex gained one in migration 234).
    unsupported := fmt.tprintf("/api/v1/bridges/%s/providers/pi/acp-adapter", f.bridge_id)
    testing.expect_value(t, bridge_provider_acp_adapter_handler(rawptr(&f.ph), extension_test_request(f, unsupported, `{"action":"install"}`)).status, 422)
    req := extension_test_request(f, path, `{"action":"install"}`); req.headers = nil; req.remote_addr = "192.0.2.1:12"
    testing.expect_value(t, bridge_provider_acp_adapter_handler(rawptr(&f.ph), req).status, 401)
    bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
    defer domain.bridge_destroy(&bridge)
    bridge.status = .Offline; iface.bridge_save_bridge(&f.br_repo, bridge)
    testing.expect_value(t, bridge_provider_acp_adapter_handler(rawptr(&f.ph), extension_test_request(f, path, `{"action":"install"}`)).status, 409)
    testing.expect_value(t, f.sink_rec.count, 0)
}
@(private = "file")
Extension_Sink_Recorder :: struct {
	sent:     bool,
	count:    int,
	fail:     bool,
	last_cmd: project_service.Runtime_Command,
}

@(private = "file")
extension_test_sink :: proc(
	ctx: rawptr,
	cmd: project_service.Runtime_Command,
) -> (
	bool,
	domain.Domain_Error,
) {
	rec := (^Extension_Sink_Recorder)(ctx)
	if rec.fail do return false, domain.domain_error(.Bridge_Offline, "test send failed")
	rec.count += 1
	if rec.sent {
		delete(
			rec.last_cmd.bridge_id,
		); delete(rec.last_cmd.command_id); delete(rec.last_cmd.body_json)
	}
	rec.sent = true
	rec.last_cmd = project_service.Runtime_Command {
		bridge_id  = strings.clone(cmd.bridge_id),
		command_id = strings.clone(cmd.command_id),
		body_json  = strings.clone(cmd.body_json),
	}
	return true, domain.Domain_Error{}
}

// Wire fixture for HTTP handler tests
@(private = "file")
extension_handler_fixture :: struct {
	fixed_now:string,
	db_path:       string,
	conn:          sqlite.Conn,
	pr_impl:       sqlite.Provider_Repo_SQLite,
	pr_repo:       iface.Provider_Repository,
	pr_svc:        provider_service.Provider_Service,
	transport_uow_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	transport_uow: iface.Unit_Of_Work_Factory,
	ph:            Provider_Handlers,
	catalog:       bridge_service.Bridge_Update_Catalog,
	br_impl:       sqlite.Bridge_Repo_SQLite,
	us_impl:       sqlite.User_Repo_SQLite,
	ag_impl:       sqlite.Agent_Repo_SQLite,
	br_repo:       iface.Bridge_Repository,
	us_repo:       iface.User_Repository,
	ag_repo:       iface.Agent_Repository,
	clock:         platform.Clock,
	ids:           platform.ID_Generator,
	br_svc:        bridge_service.Bridge_Service,
	us_svc:        user_service.User_Service,
	ag_svc:        agent_service.Agent_Service,
	auth_svc:      auth_service.Auth_Service,
	user_headers: []contracts.HTTP_Header, // session cookie for the fixture owner
	bh:            Bridge_Handlers,
	registry:      project_service.Bridge_Runtime_Registry,
	sink_rec:      Extension_Sink_Recorder,
	owner_user_id: string,
	bridge_id:     string,
}


@(private = "file")
extension_test_setup :: proc(
	t: ^testing.T,
	tag: string,
	database_path: string = ":memory:",
	fixed_now:string = "",
) -> ^extension_handler_fixture {
	f := new(extension_handler_fixture)
	f.db_path = database_path


	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	f.br_repo = sqlite.new_bridge_repository(&f.br_impl, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_impl, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_impl, &f.conn)

	f.clock = platform.real_clock()
	if fixed_now!="" {f.fixed_now=fixed_now;f.clock=platform.Clock{ctx=rawptr(&f.fixed_now),now=profile_test_fixed_now}}
	f.ids = http_test_id_generator()

	f.sink_rec = Extension_Sink_Recorder{}
	sink := project_service.Bridge_Command_Sink {
		ctx                  = rawptr(&f.sink_rec),
		send_runtime_command = extension_test_sink,
	}

	f.br_svc = bridge_service.new_bridge_service_with_runtime(&f.br_repo, sink, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)

	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true},
		&f.us_svc,
	)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc

	f.bh = Bridge_Handlers {
		auth                    = &f.auth_svc,
		bridges                 = &f.br_svc,
		agents                  = &f.ag_svc,
		bridge_runtime_registry = &f.registry,
	}

	f.user_headers = http_test_login(t, &f.auth_svc, "update_test_user")
	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(
		&f.auth_svc,
		auth_service.Auth_Request {
			remote_addr = "127.0.0.1:4444",
			headers = f.user_headers,
		},
	)
	testing.expect(t, owner_ok, "session owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)

	owner_auth := contracts.Auth_Context {
		kind    = .Session,
		user_id = f.owner_user_id,
	}
	// Provisioned through the DEVICE-GRANT path, the only enrollment there is
	// (REQ-ENROLL-9). This replaced a create_enrollment + enroll_bridge pair; the
	// bridge and its credential are what this fixture needs, and how the credential
	// was approved is not what these tests are about.
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(
		&f.br_svc,
		bridge_service.Device_Enroll_Input {
			owner_user_id = f.owner_user_id,
			bridge_public_key = "04aabb",
			bridge_key_fingerprint = "aaaa bbbb cccc dddd",
			machine_hostname = "test-box",
		},
	)
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)


	f.pr_repo = sqlite.new_provider_repository(&f.pr_impl, &f.conn)
	f.pr_svc = provider_service.new_provider_service(&f.pr_repo)
	f.transport_uow=sqlite.new_unit_of_work_factory(&f.transport_uow_impl,&f.conn,nil)
	f.pr_svc.uow_factory=&f.transport_uow
	f.pr_svc.bridges=&f.br_repo
	f.br_svc.provider_repo = &f.pr_repo
	f.bh.providers = &f.pr_svc
	f.ph = {
		auth                    = &f.auth_svc,
		providers               = &f.pr_svc,
		bridges                 = &f.br_svc,
		bridge_runtime_registry = &f.registry,
		clock                   = &f.clock,
		ids                     = &f.ids,
	}
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	bridge.status = .Online
	bridge.version = "0.1.0"
	bridge.commit_sha = "old"
	_, _, _ = iface.bridge_save_bridge(&f.br_repo, bridge)
	_, _, _ = bridge_runtime_service.runtime_accept_hello(
		&f.registry,
		f.bridge_id,
		bridge_runtime_service.PROTOCOL_VERSION,
		"",
	)
	f.catalog = {
		override_version      = "0.2.0",
		override_commit_sha   = "new",
		override_download_url = "https://example.com/heimdall-local-linux-amd64.tar.gz",
		override_sha256       = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	}
	f.br_svc.catalog = &f.catalog
	return f
}

@(private = "file")
extension_test_teardown :: proc(f: ^extension_handler_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)

	delete(f.owner_user_id)
	delete(f.bridge_id)
	if f.sink_rec.sent {
		delete(f.sink_rec.last_cmd.bridge_id)
		delete(f.sink_rec.last_cmd.command_id)
		delete(f.sink_rec.last_cmd.body_json)
	}
	free(f)
}


extension_test_request :: proc(
	f: ^extension_handler_fixture,
	path: string,
	body: string = "{}",
) -> Request {
	return {
		method = "POST",
		path = path,
		body = body,
		request_id = "req_extension",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
}
extension_test_status :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	provider, state, ext_state: string,
	enabled: bool = true,
) {
	_, err := iface.bridge_provider_status_upsert(
		&f.pr_repo,
		{
			bridge_id = f.bridge_id,
			provider = provider,
			binary_path = "/bin/provider",
			state = state,
			extension_state = ext_state,
			extension_version = "0.1.0",
			checked_at = "2026-01-01",
			extension_checked_at = "2026-01-01",
		},
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	_, err = iface.bridge_provider_setting_upsert(
		&f.pr_repo,
		{bridge_id = f.bridge_id, provider = provider, enabled = enabled},
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
extension_test_commands :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
) -> [dynamic]domain.Provider_Extension_Command {
	commands, err := iface.provider_extension_command_list(&f.pr_repo, f.bridge_id)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return commands
}
// The state of one command (temp-allocated; "" when it does not exist).
extension_test_state :: proc(t: ^testing.T, f: ^extension_handler_fixture, command_id: string) -> string {
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	for command in commands {
		if command.command_id == command_id do return strings.clone(command.state, context.temp_allocator)
	}
	return ""
}
extension_test_update :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	body: string,
) -> string {
	response := bridge_update_handler(
		rawptr(&f.bh),
		extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id), body),
	)
	testing.expectf(
		t,
		response.status == 202,
		"expected 202, got %d: %s",
		response.status,
		response.body,
	)
	return json_string(response.body, "command_id")
}
extension_test_restart :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	command_id: string,
	commit: string = "new",
) {
	frame := fmt.tprintf("{{\"command_id\":\"%s\",\"stage\":\"restarting\"}}", command_id)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "bridge_update_progress", frame)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	delete(bridge.version); bridge.version = strings.clone("0.2.0")
	delete(bridge.commit_sha); bridge.commit_sha = strings.clone(commit)
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}
extension_test_report :: proc(
	t: ^testing.T,
	f: ^extension_handler_fixture,
	request_id, providers_json: string,
) {
	frame := fmt.tprintf(
		"{{\"type\":\"provider_discovery_report\",\"request_id\":\"%s\",\"providers\":%s}}",
		request_id,
		providers_json,
	)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "provider_discovery_report", frame)
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(test)
test_extension_install_endpoint_dispatch_tracking_and_verified_completion :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "manual")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	response := bridge_provider_extension_install_handler(
		rawptr(&f.ph),
		extension_test_request(f, path),
	)
	testing.expectf(
		t,
		response.status == 202,
		"expected 202, got %d: %s",
		response.status,
		response.body,
	)
	id := json_string(response.body, "command_id")
	defer delete(id)
	testing.expect(t, strings.has_prefix(id, "cmd_"), id)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "command_id"), id)
	dispatched := f.sink_rec.count
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, len(commands), 1)
	testing.expect_value(t, commands[0].state, "dispatched")
	duplicate := bridge_provider_extension_install_handler(
		rawptr(&f.ph),
		extension_test_request(f, path),
	)
	testing.expect_value(t, duplicate.status, 409)
	testing.expect_value(t, f.sink_rec.count, 1)
	err := bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"accepted\"}}", id),
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	poll := extension_test_request(f, fmt.tprintf("%s/%s", path, id))
	poll.method = "GET"
	tracking := bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect_value(t, tracking.status, 200)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"accepted\""))
	err = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"provider_extension_install_progress",
		fmt.tprintf(
			"{{\"command_id\":\"%s\",\"stage\":\"succeeded\",\"progress_percent\":100}}",
			id,
		),
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(
		t,
		!strings.contains(tracking.body, "\"status\":\"succeeded\""),
		"progress must not masquerade as terminal completion",
	)
	extension_test_report(
		t,
		f,
		id,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.4.31\"}]",
	)
	err = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", id),
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"succeeded\""))
	statuses, _ := iface.bridge_provider_status_list(&f.pr_repo, f.bridge_id)
	defer domain.bridge_provider_statuses_destroy(statuses)
	testing.expect_value(t, statuses[0].extension_version, "0.4.31")
	// Late accepted frames cannot regress completion.
	_ = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"accepted\"}}", id),
	)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"succeeded\""))
}

@(test)
test_extension_install_endpoint_auth_and_eligibility :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "errors")
	defer extension_test_teardown(f)
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	req := extension_test_request(f, path)
	req.headers = nil; req.remote_addr = "192.0.2.1:123"
	response := bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 401)
	req = extension_test_request(f, path)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 409)
	req.path = fmt.tprintf(
		"/api/v1/bridges/%s/providers/no-such-provider/extension-install",
		f.bridge_id,
	)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 404)
	req.path = fmt.tprintf("/api/v1/bridges/%s/providers/pi/extension-install", f.bridge_id)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect_value(t, response.status, 422)
	req.path = path
	extension_test_status(t, f, "codex", "present", "absent")
	f.sink_rec.fail = true
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect(t, response.status >= 400, "send failure must not return Accepted")
	f.sink_rec.fail = false
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	bridge.status = .Offline
	_, _, _ = iface.bridge_save_bridge(&f.br_repo, bridge)
	response = bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect(t, response.status >= 400, "offline bridge rejected")
	testing.expect_value(t, f.sink_rec.count, 0)
}

@(test)
test_extension_update_opt_in_defaults_and_validation :: proc(t: ^testing.T) {
	for body in ([2]string{"{}", "{\"update_extensions\":false}"}) {
		f := extension_test_setup(t, "optout")
		id := extension_test_update(t, f, body)
		extension_test_restart(t, f, id)
		commands := extension_test_commands(t, f)
		testing.expect_value(t, len(commands), 1)
		testing.expect(t, !commands[0].update_extensions)
		testing.expect_value(t, f.sink_rec.count, 1)
		domain.provider_extension_commands_destroy(commands)
		delete(id)
		extension_test_teardown(f)
	}
	f := extension_test_setup(t, "invalid")
	defer extension_test_teardown(f)
	for body in ([3]string {
			"{\"update_extensions\":\"true\"}",
			"{\"update_extensions\":null}",
			"{\"update_extensions\":1}",
		}) {
		response := bridge_update_handler(
			rawptr(&f.bh),
			extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/update", f.bridge_id), body),
		)
		testing.expect_value(t, response.status, 400)
	}
	testing.expect_value(t, f.sink_rec.count, 0)
}

@(test)
test_extension_update_fresh_discovery_restart_recovery_and_dedup :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "automatic")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	extension_test_status(t, f, "claude", "present", "outdated", false)
	extension_test_status(t, f, "antigravity", "present", "outdated")
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	testing.expect_value(t, f.sink_rec.count, 1)
	// Recreate the service projection: opt-in and work survive a Hub restart.
	replacement := provider_service.new_provider_service(&f.pr_repo)
	f.bh.providers = &replacement
	f.ph.providers = &replacement
	extension_test_restart(t, f, id)
	testing.expect_value(t, f.sink_rec.count, 2)
	discovery := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_discover",
	)
	report := "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"},{\"provider\":\"claude\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"},{\"provider\":\"antigravity\",\"state\":\"present\",\"extension_state\":\"absent\",\"extension_version\":\"\"}]"
	extension_test_report(t, f, discovery, report)
	testing.expect_value(t, f.sink_rec.count, 3)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "provider"), "codex")
	install_id := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(install_id)
	extension_test_report(t, f, discovery, report)
	testing.expect_value(t, f.sink_rec.count, 3)
	// Duplicate update success events cannot enqueue a second follow-up.
	_ = bridge_extension_frame(
		&f.bh,
		f.bridge_id,
		"command_result",
		fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", id),
	)
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, len(commands), 3)
	installs := 0
	for command in commands {if command.kind ==
		   "install" {installs += 1; testing.expect_value(t, command.command_id, install_id)}}
	testing.expect_value(t, installs, 1)
}

@(test)
test_extension_update_failure_rollback_and_acceptance_queue_none :: proc(t: ^testing.T) {
	for state in ([3]string{"failed", "cancelled", "accepted"}) {
		f := extension_test_setup(t, "failed")
		id := extension_test_update(t, f, "{\"update_extensions\":true}")
		_ = bridge_extension_frame(
			&f.bh,
			f.bridge_id,
			"command_result",
			fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"%s\"}}", id, state),
		)
		bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
		err := bridge_extension_reconnected(&f.bh, bridge)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		domain.bridge_destroy(&bridge)
		testing.expect_value(t, f.sink_rec.count, 1)
		commands := extension_test_commands(t, f)
		testing.expect_value(t, len(commands), 1)
		domain.provider_extension_commands_destroy(commands)
		delete(id)
		extension_test_teardown(f)
	}
	f := extension_test_setup(t, "rollback")
	defer extension_test_teardown(f)
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	extension_test_restart(t, f, id, "old")
	testing.expect_value(t, f.sink_rec.count, 1)
	commands := extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, commands[0].state, "failed")
}

@(test)
test_extension_update_replays_discovery_but_not_duplicate_followups :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "recovery")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	extension_test_restart(t, f, id)
	discovery := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	err := bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.last_cmd.command_id, discovery)
	extension_test_report(
		t,
		f,
		discovery,
		strings.concatenate({`[{"provider":"codex","state":"present","extension_state":"present","extension_version":"`, contracts.APP_VERSION, `"}]`}, context.temp_allocator),
	)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_discover",
	)
	count := f.sink_rec.count
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, count)
}

@(test)
test_extension_command_owner_scope_and_stale_connection_frames :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "scope")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)
	response := bridge_provider_extension_install_handler(
		rawptr(&f.ph),
		extension_test_request(f, path),
	)
	testing.expect_value(t, response.status, 202)
	id := json_string(response.body, "command_id")
	defer delete(id)
	other_headers := http_test_login(t, &f.auth_svc, "other-extension-owner")
	req := extension_test_request(f, path)
	req.headers = other_headers
	denied := bridge_provider_extension_install_handler(rawptr(&f.ph), req)
	testing.expect(t, denied.status == 403 || denied.status == 404, "other owner cannot install")
	req.path = fmt.tprintf("%s/%s", path, id); req.method = "GET"
	denied = bridge_provider_extension_command_handler(rawptr(&f.ph), req)
	testing.expect(t, denied.status == 403 || denied.status == 404, "other owner cannot poll")
	req = extension_test_request(f, fmt.tprintf("%s/not-this-command", path))
	req.method = "GET"
	missing := bridge_provider_extension_command_handler(rawptr(&f.ph), req)
	testing.expect_value(t, missing.status, 404)
	// The real dispatcher must reject stale generation frames before they mutate state.
	generation := project_service.bridge_runtime_registry_generation(&f.registry, f.bridge_id)
	chunks := [dynamic]Bridge_Chunk_Reassembly{}
	stale := fmt.aprintf(
		"{{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"%s\",\"ok\":true,\"payload\":{{\"status\":\"succeeded\"}}}}",
		id,
	)
	accepted := bridge_ws_process_frame(&f.bh, f.bridge_id, generation + 1, 0, &chunks, stale)
	testing.expect(t, !accepted)
	testing.expect_value(t, extension_test_state(t, f, id), "dispatched")
	// Current generation processes the nested production envelope.
	current := fmt.aprintf(
		"{{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"%s\",\"ok\":true,\"payload\":{{\"status\":\"accepted\"}}}}",
		id,
	)
	accepted = bridge_ws_process_frame(&f.bh, f.bridge_id, generation, 0, &chunks, current)
	testing.expect(t, accepted)
	testing.expect_value(t, extension_test_state(t, f, id), "accepted")
	req = extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id))
	req.method = "GET"
	provider_status := bridge_provider_status_handler(rawptr(&f.ph), req)
	testing.expect_value(t, provider_status.status, 200)
	testing.expect(t, strings.contains(provider_status.body, "\"extension_commands\":[{"))
	testing.expect(
		t,
		strings.contains(provider_status.body, id),
		"provider status exposes resumable command tracking",
	)
}

@(test)
test_extension_update_disk_reopen_retains_consent_and_followup_identity :: proc(t: ^testing.T) {
	database_path := fmt.aprintf(
		"/tmp/heimdall-extension-%d-%d.db",
		os.get_pid(),
		time.now()._nsec,
	)
	defer delete(database_path)
	defer _ = os.remove(database_path)
	f := extension_test_setup(t, "disk-restart", database_path)
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "outdated")
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	frame := fmt.tprintf("{{\"command_id\":\"%s\",\"payload\":{{\"status\":\"succeeded\"}}}}", id)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "command_result", frame)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, 1) // replaced below: completion must still await reconnect
	sqlite.close(&f.conn)
	reopened, ok, open_err := sqlite.open(database_path)
	testing.expect(t, ok)
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = reopened
	// Repositories keep a pointer to f.conn, so this is a real database close/open,
	// with a fresh service projection using the recovered durable journal.
	f.pr_svc = provider_service.new_provider_service(&f.pr_repo)
	f.transport_uow=sqlite.new_unit_of_work_factory(&f.transport_uow_impl,&f.conn,nil)
	f.pr_svc.uow_factory=&f.transport_uow
	f.pr_svc.bridges=&f.br_repo
	f.bh.providers = &f.pr_svc
	commands := extension_test_commands(t, f)
	testing.expect_value(t, len(commands), 1)
	testing.expect(t, commands[0].update_extensions)
	testing.expect_value(t, commands[0].state, "restarting")
	domain.provider_extension_commands_destroy(commands)
	extension_test_restart(t, f, id)
	discovery := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(discovery)
	// A freshly measured version may still have been judged against a cached old
	// catalog. The Hub's current minimum also makes this installed version outdated.
	extension_test_report(
		t,
		f,
		discovery,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"present\",\"extension_version\":\"0.1.0\"}]",
	)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_extension_install",
	)
	install_id := strings.clone(f.sink_rec.last_cmd.command_id)
	defer delete(install_id)
	count := f.sink_rec.count
	extension_test_report(
		t,
		f,
		discovery,
		"[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.1.0\"}]",
	)
	testing.expect_value(t, f.sink_rec.count, count)
	commands = extension_test_commands(t, f)
	defer domain.provider_extension_commands_destroy(commands)
	testing.expect_value(t, len(commands), 3)
	// The DB unique key is authoritative even if a new caller tries another id.
	duplicate := domain.Provider_Extension_Command {
		command_id = "different-id",
		bridge_id  = f.bridge_id,
		kind       = "install",
		provider   = "codex",
		parent_id  = id,
		state      = "queued",
	}
	created, create_err := iface.provider_extension_command_create(&f.pr_repo, duplicate)
	testing.expect_value(t, create_err.code, domain.Error_Code.None)
	testing.expect(t, !created)
}

@(test)
test_extension_auto_install_excludes_disabled_absent_error_and_unmeasured :: proc(t: ^testing.T) {
	for state in ([5]string{"disabled", "absent", "error", "unsupported", ""}) {
		f := extension_test_setup(t, "ineligible")
		extension_test_status(t, f, "codex", "present", "outdated")
		id := extension_test_update(t, f, "{\"update_extensions\":true}")
		extension_test_restart(t, f, id)
		discovery := strings.clone(f.sink_rec.last_cmd.command_id)
		report := fmt.tprintf(
			"[{{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"%s\",\"extension_version\":\"0.1.0\"}}]",
			state,
		)
		extension_test_report(t, f, discovery, report)
		testing.expect_value(
			t,
			json_string(f.sink_rec.last_cmd.body_json, "type"),
			"provider_discover",
		)
		delete(id); delete(discovery)
		extension_test_teardown(f)
	}
}


@(test)
test_extension_update_reconnect_recovers_lost_restart_progress :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "lost-progress")
	defer extension_test_teardown(f)
	id := extension_test_update(t, f, "{\"update_extensions\":true}")
	defer delete(id)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	// An ordinary reconnect with the original build must do nothing.
	err := bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, f.sink_rec.count, 1)
	delete(bridge.version); bridge.version = strings.clone("0.2.0")
	delete(bridge.commit_sha); bridge.commit_sha = strings.clone("new")
	err = bridge_extension_reconnected(&f.bh, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(
		t,
		json_string(f.sink_rec.last_cmd.body_json, "type"),
		"provider_discover",
	)
}

@(test)
test_provider_models_api_filter_empty_and_additive_metadata :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	f := extension_test_setup(t,"model_filter")
	defer extension_test_teardown(f)
	extension_test_status(t,f,"codex","present","present",false)
	extension_test_status(t,f,"claude","absent","absent",true)
	response := bridge_provider_discover_handler(rawptr(&f.ph),extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/providers/discover",f.bridge_id),`{"stage":"models","providers":["codex","claude"],"enabled":true}`))
	testing.expect_value(t,response.status,200)
	testing.expect_value(t,f.sink_rec.count,0)
	saved,err := iface.bridge_provider_models_list(&f.pr_repo,f.bridge_id)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,len(saved),0)
	domain.bridge_provider_models_list_destroy(saved)
	views,_ := provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
	defer provider_service.bridge_provider_views_destroy(views)
	eligible := provider_service.model_discovery_providers(views[:])
	testing.expect_value(t,len(eligible),0)
	for &view in views {
		if view.catalog.provider=="codex" do view.enabled=true
		if view.catalog.provider=="claude" do view.enabled=true // still absent
	}
	eligible=provider_service.model_discovery_providers(views[:])
	testing.expect_value(t,len(eligible),1)
	if len(eligible)==1 do testing.expect_value(t,eligible[0],"codex")
	for view in views do if view.catalog.provider=="codex" {
		b:=strings.builder_make()
		write_bridge_provider_view_json(&b,view,"")
		text:=strings.to_string(b)
		testing.expect(t,strings.contains(text,`"models_source":"static_fallback"`))
		testing.expect(t,strings.contains(text,`"models_state":"not_checked"`))
		testing.expect(t,strings.contains(text,`"models_has_snapshot":false`))
	}
	response=bridge_provider_discover_handler(rawptr(&f.ph),extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/providers/discover",f.bridge_id),`{"stage":"automatic"}`))
	testing.expect_value(t,response.status,400)
}

@(test)
test_provider_models_reply_correlation_presence_and_failure :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	f:=extension_test_setup(t,"model_reply")
	defer extension_test_teardown(f)
	allowed:=[]string{"codex"}
	prefix:=`{"type":"provider_model_discovery_report","request_id":"model-1","command_id":"model-1","providers":[`
	item:=`{"provider":"codex","binary_path":"/bin/codex","version_text":"v1","has_snapshot":true,"models_source":"codex_app_server","models_state":"success","models_checked_at":"2026-10-01T00:00:00Z","models_attempted_at":"2026-10-01T00:00:00Z","models":[{"model_id":"new-model","label":"New"}]}`
	reply:=strings.concatenate({prefix,item,"]}"})
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"wrong-request",allowed,reply,"now").code,domain.Error_Code.Validation_Failed)
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"model-1",allowed,reply,"now").code,domain.Error_Code.None)
	// Extension reconciliation may receive ordinary detection reports. They must
	// preserve the independent model fields without running any model probes.
	command:=domain.Provider_Extension_Command{command_id="ordinary-detection",bridge_id=f.bridge_id,kind="install",state="dispatched"}
	testing.expect_value(t,extension_apply_report(&f.bh,&command,`{"request_id":"ordinary-detection","providers":[{"provider":"codex","state":"present","checked_at":"2026-10-02","extension_state":"error"}]}`).code,domain.Error_Code.None)
	omitted:=strings.concatenate({prefix,`{"provider":"codex","has_snapshot":true,"models_source":"codex_app_server","models_state":"success","models_checked_at":"2026-10-02","models_attempted_at":"2026-10-02"}`,"]}"})
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"model-1",allowed,omitted,"now").code,domain.Error_Code.Validation_Failed)
	failed:=strings.concatenate({`{"type":"command_result","command_id":"model-1","error":`,contracts.wire_error_json(contracts.wire_error(.Validation_Failed,"unknown_command"),context.temp_allocator),"}"})
	testing.expect_value(t,provider_models_apply_reply(&f.pr_svc,f.bridge_id,"model-1",allowed,failed,"2026-10-03T00:00:00Z").code,domain.Error_Code.None)
	views,_:=provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
	defer provider_service.bridge_provider_views_destroy(views)
	for view in views do if view.catalog.provider=="codex" {
		testing.expect_value(t,view.models_state,"unsupported")
		testing.expect_value(t,view.models_checked_at,"2026-10-01T00:00:00Z")
		testing.expect_value(t,len(view.catalog.models),1)
		if len(view.catalog.models)==1 do testing.expect_value(t,view.catalog.models[0].model_id,"new-model")
	}
	testing.expect_value(t,f.sink_rec.count,0)
}

@(private="file")
Model_API_Job :: struct { fixture:^extension_handler_fixture, status:int, body:string }
@(private="file")
model_api_test_worker :: proc(th:^thread.Thread) {
	context.allocator=context.temp_allocator
	job:=(^Model_API_Job)(th.data)
	req:=extension_test_request(job.fixture,fmt.tprintf("/api/v1/bridges/%s/providers/discover",job.fixture.bridge_id),`{"stage":"models","providers":["claude","pi"],"enabled":true}`)
	response:=bridge_provider_discover_handler(rawptr(&job.fixture.ph),req)
	job.status=response.status
	job.body=strings.clone(response.body,runtime.default_allocator())
	free_all(context.temp_allocator)
}
@(test)
test_provider_models_existing_api_runtime_round_trip :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=extension_test_setup(t,"model_api_roundtrip")
	defer extension_test_teardown(f)
	extension_test_status(t,f,"codex","present","present",true)
	extension_test_status(t,f,"claude","present","present",false)
	extension_test_status(t,f,"pi","absent","unsupported",true)
	listener,listen_err:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
	if !testing.expect(t,listen_err==nil) do return
	defer net.close(listener)
	endpoint,_:=net.bound_endpoint(listener)
	client,dial_err:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=endpoint.port})
	if !testing.expect(t,dial_err==nil) do return
	defer net.close(client)
	hub,_,accept_err:=net.accept_tcp(listener)
	if !testing.expect(t,accept_err==nil) do return
	defer net.close(hub)
	generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
	project_service.bridge_runtime_registry_set_command_socket(&f.registry,f.bridge_id,hub,generation)
	defer project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
	job:=Model_API_Job{fixture=f}
	worker:=thread.create(model_api_test_worker)
	worker.data=rawptr(&job)
	thread.start(worker)
	reader:=bridge_ws_reader_make(client)
	frame,received,_:=bridge_ws_read_frame(&reader,5*time.Second)
	bridge_ws_reader_destroy(&reader)
	if testing.expect(t,received,"explicit stage two sends a runtime request") {
		testing.expect_value(t,json_string(frame,"type"),"provider_models_discover")
		names:=json_string_array(frame,"providers")
		testing.expect_value(t,len(names),1)
		if len(names)==1 do testing.expect_value(t,names[0],"codex")
		request_id:=json_string(frame,"request_id")
		reply:=fmt.tprintf(`{{"type":"provider_model_discovery_report","request_id":"%s","command_id":"%s","providers":[{{"provider":"codex","has_snapshot":true,"models_source":"codex_app_server","models_state":"success","models_checked_at":"2026-10-01T00:00:00Z","models_attempted_at":"2026-10-01T00:00:00Z","models":[{{"model_id":"api-new-model","label":"New"}}]}}]}}`,request_id,request_id)
		testing.expect(t,bridge_runtime_service.runtime_command_result_for_connection(&f.registry,f.bridge_id,generation,request_id,reply))
	} else {
		project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
	}
	thread.join(worker);thread.destroy(worker)
	defer delete(job.body,runtime.default_allocator())
	testing.expect_value(t,job.status,200)
	testing.expect(t,strings.contains(job.body,`"model_id":"api-new-model"`),"existing provider response includes discovered models")
	testing.expect(t,strings.contains(job.body,`"models_source":"codex_app_server"`))
	testing.expect_value(t,provider_models_failure_state(.Bridge_Timeout,""),"timeout")
	testing.expect_value(t,provider_models_failure_state(.Validation_Failed,"unknown_command"),"unsupported")
	testing.expect_value(t,provider_models_failure_state(.Validation_Failed,"bridge_busy"),"busy")
}

// Uninstall is the same per-provider action as install: one at a time, the same
// frame with action=uninstall, tracked at .../extension-uninstall/:id.
@(test)
test_extension_uninstall_endpoint_dispatch_and_tracking :: proc(t: ^testing.T) {
	f := extension_test_setup(t, "uninstall")
	defer extension_test_teardown(f)
	extension_test_status(t, f, "codex", "present", "present")
	path := fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-uninstall", f.bridge_id)
	response := bridge_provider_extension_uninstall_handler(rawptr(&f.ph), extension_test_request(f, path))
	testing.expectf(t, response.status == 202, "expected 202, got %d: %s", response.status, response.body)
	id := json_string(response.body, "command_id")
	defer delete(id)
	testing.expect_value(t, json_string(response.body, "kind"), "uninstall")
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type"), "provider_extension_install")
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "action"), "uninstall")
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "provider"), "codex")
	// An install cannot start while the uninstall runs.
	install := bridge_provider_extension_install_handler(rawptr(&f.ph), extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install", f.bridge_id)))
	testing.expect_value(t, install.status, 409)
	testing.expect_value(t, f.sink_rec.count, 1)
	err := bridge_extension_frame(&f.bh, f.bridge_id, "provider_extension_install_progress",
		fmt.tprintf("{{\"command_id\":\"%s\",\"stage\":\"uninstalling\",\"progress_percent\":20}}", id))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	poll := extension_test_request(f, fmt.tprintf("%s/%s", path, id))
	poll.method = "GET"
	tracking := bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect_value(t, tracking.status, 200)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"uninstalling\""), tracking.body)
	// The install path never finds an uninstall command.
	wrong := extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/providers/codex/extension-install/%s", f.bridge_id, id))
	wrong.method = "GET"
	testing.expect_value(t, bridge_provider_extension_command_handler(rawptr(&f.ph), wrong).status, 404)
	extension_test_report(t, f, id, "[{\"provider\":\"codex\",\"state\":\"present\",\"extension_state\":\"absent\"}]")
	err = bridge_extension_frame(&f.bh, f.bridge_id, "command_result", fmt.tprintf("{{\"command_id\":\"%s\",\"status\":\"succeeded\"}}", id))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	tracking = bridge_provider_extension_command_handler(rawptr(&f.ph), poll)
	testing.expect(t, strings.contains(tracking.body, "\"status\":\"succeeded\""), tracking.body)
	statuses, _ := iface.bridge_provider_status_list(&f.pr_repo, f.bridge_id)
	defer domain.bridge_provider_statuses_destroy(statuses)
	for s in statuses do if s.provider == "codex" do testing.expect_value(t, s.extension_state, "absent")
}

// Profile transport tests share the real owner/auth/runtime fixture above.
@(private="file")
Profile_API_Job :: struct { fixture:^extension_handler_fixture, path,method,body:string, status:int, result:string }
@(private="file")
profile_api_test_worker :: proc(th:^thread.Thread) {
 context.allocator=context.temp_allocator
 job:=(^Profile_API_Job)(th.data)
 req:=extension_test_request(job.fixture,job.path,job.body);req.method=job.method
 response:=bridge_provider_profiles_handler(rawptr(&job.fixture.ph),req)
 job.status=response.status
 job.result=strings.clone(response.body,runtime.default_allocator())
 free_all(context.temp_allocator)
}
@(test)
test_profiles_opaque_relay_round_trip_all_operations :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_relay",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 listener,listen_err:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
 if !testing.expect(t,listen_err==nil) do return
 defer net.close(listener)
 endpoint,_:=net.bound_endpoint(listener)
 client,dial_err:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=endpoint.port})
 if !testing.expect(t,dial_err==nil) do return
 defer net.close(client)
 hub,_,accept_err:=net.accept_tcp(listener)
 if !testing.expect(t,accept_err==nil) do return
 defer net.close(hub)
 generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
 project_service.bridge_runtime_registry_set_command_socket(&f.registry,f.bridge_id,hub,generation)
 defer project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
 sealed:="vault:v2:opaque:e7:UNCHANGED+/=ciphertext"
 for route in ([]struct{method,suffix,op:string}{{"PUT","","upsert"},{"DELETE","","remove"},{"POST","/reset","reset"},{"POST","/get","get"}}) {
  job:=Profile_API_Job{fixture=f,path=fmt.tprintf("/api/v1/bridges/%s/provider-profiles/claude_one%s",f.bridge_id,route.suffix),method=route.method,body=fmt.tprintf("{{\"sealed\":\"%s\"}}",sealed)}
  worker:=thread.create(profile_api_test_worker);worker.data=rawptr(&job);thread.start(worker)
  reader:=bridge_ws_reader_make(client)
  frame,received,_:=bridge_ws_read_frame(&reader,5*time.Second);bridge_ws_reader_destroy(&reader)
  if testing.expect(t,received,"relay dispatched opaque operation") {
   testing.expect_value(t,json_string(frame,"type"),"provider_profile_op")
   testing.expect_value(t,json_string(frame,"sealed"),sealed)
   testing.expect_value(t,json_string(frame,"op"),route.op)
   testing.expect_value(t,json_string(frame,"profile_id"),"claude_one")
   id:=json_string(frame,"command_id")
   reply:=fmt.tprintf("{{\"type\":\"provider_profile_op_result\",\"command_id\":\"%s\",\"ok\":true,\"error\":\"\",\"sealed\":\"vault:v2:opaque:e7:redacted-response\"}}",id)
   testing.expect(t,bridge_runtime_service.runtime_command_result_for_connection(&f.registry,f.bridge_id,generation,id,reply))
  } else {project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)}
  thread.join(worker);thread.destroy(worker)
  testing.expect_value(t,job.status,200)
  testing.expect(t,strings.contains(job.result,"vault:v2:opaque:e7:redacted-response"))
  delete(job.result,runtime.default_allocator())
 }
}
@(test)
test_profiles_report_allowlist_authoritative_missing_and_in_use :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_report",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 frame:="{\"type\":\"provider_profiles_report\",\"ok\":true,\"profiles\":[{\"profile_id\":\"claude_one\",\"provider\":\"claude\",\"enabled\":true,\"state\":\"ok\",\"env_count\":1,\"binary_path\":\"NEVER_STORE_PRIVATE_PATH\",\"environment\":[{\"name\":\"NEVER_STORE_ENV_NAME\",\"value\":\"NEVER_STORE_SECRET\"}],\"launch_args\":\"NEVER_STORE_ARGS\"}]}"
 testing.expect_value(t,bridge_provider_profiles_frame(&f.bh,f.bridge_id,frame).code,domain.Error_Code.None)
 req:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/provider-profiles",f.bridge_id));req.method="GET"
 response:=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,response.status,200)
 testing.expect(t,strings.contains(response.body,"claude_one"))
 testing.expect(t,!strings.contains(response.body,"NEVER_STORE"))
 profiles,_:=f.pr_repo.list_profiles(f.pr_repo.ctx,f.bridge_id)
 found:=false
 for p in profiles do if p.profile_id=="claude_one" do found=p.env_count==1
 testing.expect(t,found)
 _,saved,err:=iface.agent_save_instance(&f.ag_repo,domain.Agent_Instance{agent_instance_id="profile-live",owner_user_id=domain.User_ID(f.owner_user_id),agent_id="agent",bridge_id=f.bridge_id,provider="claude",provider_profile="claude_one",model="model",runtime_status="running"})
 testing.expect(t,saved,err.message)
 remove:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/provider-profiles/claude_one",f.bridge_id),"{\"sealed\":\"vault:v2:opaque:e1:test\"}");remove.method="DELETE"
 denied:=bridge_provider_profiles_handler(rawptr(&f.ph),remove)
 testing.expect_value(t,denied.status,409)
 testing.expect(t,strings.contains(denied.body,"profile_in_use") && strings.contains(denied.body,"profile-live"))
 testing.expect_value(t,bridge_provider_profiles_frame(&f.bh,f.bridge_id,"{\"ok\":false,\"profiles\":[]}").code,domain.Error_Code.Validation_Failed)
 profiles,_=f.pr_repo.list_profiles(f.pr_repo.ctx,f.bridge_id)
 for p in profiles do if p.profile_id=="claude_one" do testing.expect_value(t,p.state,"ok")
 testing.expect_value(t,bridge_provider_profiles_frame(&f.bh,f.bridge_id,"{\"ok\":true,\"profiles\":[]}").code,domain.Error_Code.None)
 profiles,_=f.pr_repo.list_profiles(f.pr_repo.ctx,f.bridge_id)
 found=false
 for p in profiles do if p.profile_id=="claude_one" do found=p.state=="missing"
 testing.expect(t,found)
}
@(test)
test_profiles_relay_auth_private_plaintext_and_offline_refused :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_relay_boundary",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 req:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/provider-profiles/claude_one",f.bridge_id),"{\"sealed\":\"vault:v2:opaque:e1:test\",\"environment\":{\"TOKEN\":\"private\"}}");req.method="PUT"
 result:=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,result.status,400)
 req.headers=nil
 result=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,result.status,401)
 req.headers=f.user_headers;req.body="{\"sealed\":\"vault:v2:opaque:e1:test\"}"
 generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
 project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
 result=bridge_provider_profiles_handler(rawptr(&f.ph),req)
 testing.expect_value(t,result.status,409)
}

@(private="file")
profile_test_fixed_now :: proc(ctx:rawptr) -> string {
 return strings.clone((^string)(ctx)^)
}

@(test)
test_profiles_extension_actions_and_update_reports_cannot_cross_accounts :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=extension_test_setup(t,"profiles_extension_scope",fixed_now="2026-10-30T12:00:00Z")
 defer extension_test_teardown(f)
 defer project_service.bridge_runtime_registry_destroy(&f.registry)
 testing.expect_value(t,provider_service.apply_profiles_report(&f.pr_svc,f.bridge_id,[]domain.Bridge_Provider_Profile{{profile_id="claude_one",provider="claude",enabled=true,state="ok"},{profile_id="claude_two",provider="claude",enabled=true,state="ok"}}).code,domain.Error_Code.None)
 for id in ([]string{"claude_one","claude_two"}) {
  testing.expect_value(t,provider_service.apply_discovery_report(&f.pr_svc,f.bridge_id,[]domain.Bridge_Provider_Status{{bridge_id=f.bridge_id,provider="claude",profile_id=id,state="present",extension_state="outdated",extension_version="0.0.0"}}).code,domain.Error_Code.None)
  body:=fmt.tprintf("{{\"profile_id\":\"%s\"}}",id)
  req:=extension_test_request(f,fmt.tprintf("/api/v1/bridges/%s/providers/claude/extension-install",f.bridge_id),body)
  response:=bridge_provider_extension_install_handler(rawptr(&f.ph),req)
  testing.expect_value(t,response.status,202)
  testing.expect_value(t,json_string(f.sink_rec.last_cmd.body_json,"profile_id"),id)
 }
 testing.expect_value(t,f.sink_rec.count,2)
 // A default-account report cannot schedule an install into either custom
 // account, even though both have cached outdated extension observations.
 command:=domain.Provider_Extension_Command{command_id="cmd_ext_profiles_scan",bridge_id=f.bridge_id,kind="discovery",parent_id="profile-update",state="dispatched"}
 report:="{\"request_id\":\"cmd_ext_profiles_scan\",\"providers\":[{\"provider\":\"claude\",\"profile_id\":\"claude\",\"state\":\"present\",\"extension_state\":\"outdated\",\"extension_version\":\"0.0.0\"}]}"
 testing.expect_value(t,extension_apply_report(&f.bh,&command,report).code,domain.Error_Code.None)
 // A present default account is runtime-enabled by default, so it may queue its OWN followup,
 // but never one for a custom account.
 commands,_:=iface.provider_extension_command_list(&f.pr_repo,f.bridge_id)
 for c in commands do testing.expect(t,c.parent_id!="profile-update" || domain.profile_effective_id(c.provider,c.profile_id)=="claude","default report must not queue custom-profile followups")
}

@(private="file")
provider_discover_not_ready_worker :: proc(th:^thread.Thread) {
	context.allocator=context.temp_allocator
	job:=(^Model_API_Job)(th.data)
	req:=extension_test_request(job.fixture,fmt.tprintf("/api/v1/bridges/%s/providers/discover",job.fixture.bridge_id),`{"stage":"providers"}`)
	response:=bridge_provider_discover_handler(rawptr(&job.fixture.ph),req)
	job.status=response.status
	job.body=strings.clone(response.body,runtime.default_allocator())
	free_all(context.temp_allocator)
}

// A bridge that has not received its provider catalog yet refuses discovery with a
// typed retriable failure instead of an empty report. The API must surface it as a
// retriable error the setup wizard retries, and must not record any provider absent.
@(test)
test_provider_discover_catalog_not_ready_is_retriable_and_records_nothing :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=extension_test_setup(t,"discover_not_ready")
	defer extension_test_teardown(f)
	extension_test_status(t,f,"codex","present","present",true)
	listener,listen_err:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
	if !testing.expect(t,listen_err==nil) do return
	defer net.close(listener)
	endpoint,_:=net.bound_endpoint(listener)
	client,dial_err:=net.dial_tcp(net.Endpoint{address=net.IP4_Loopback,port=endpoint.port})
	if !testing.expect(t,dial_err==nil) do return
	defer net.close(client)
	hub,_,accept_err:=net.accept_tcp(listener)
	if !testing.expect(t,accept_err==nil) do return
	defer net.close(hub)
	generation:=project_service.bridge_runtime_registry_generation(&f.registry,f.bridge_id)
	project_service.bridge_runtime_registry_set_command_socket(&f.registry,f.bridge_id,hub,generation)
	defer project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
	job:=Model_API_Job{fixture=f}
	worker:=thread.create(provider_discover_not_ready_worker)
	worker.data=rawptr(&job)
	thread.start(worker)
	reader:=bridge_ws_reader_make(client)
	frame,received,_:=bridge_ws_read_frame(&reader,5*time.Second)
	bridge_ws_reader_destroy(&reader)
	if testing.expect(t,received,"discovery sends a runtime request") {
		testing.expect_value(t,json_string(frame,"type"),"provider_discover")
		request_id:=json_string(frame,"request_id")
		// Exactly what the bridge sends (bridge_provider_discover_not_ready_frames).
		werr:=contracts.wire_error(.Bridge_Busy,"provider_catalog_not_ready","the bridge has not received its provider catalog yet; retry shortly",2000)
		reply:=strings.concatenate({`{"type":"command_result","protocol_version":1,"command_id":"`,request_id,`","ok":false,"error":`,contracts.wire_error_json(werr,context.temp_allocator),`,"payload":{"status":"failed"}}`})
		testing.expect(t,bridge_runtime_service.runtime_command_result_for_connection(&f.registry,f.bridge_id,generation,request_id,reply))
	} else {
		project_service.bridge_runtime_registry_mark_offline(&f.registry,f.bridge_id,generation)
	}
	thread.join(worker);thread.destroy(worker)
	defer delete(job.body,runtime.default_allocator())
	testing.expect_value(t,job.status,503)
	testing.expect(t,strings.contains(job.body,`"code":"bridge_busy"`),job.body)
	testing.expect(t,strings.contains(job.body,`"class":"retriable"`),job.body)
	testing.expect(t,strings.contains(job.body,`"cause":"provider_catalog_not_ready"`),job.body)
	// The refusal applied nothing: the earlier detection is still on record.
	views,_:=provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
	defer provider_service.bridge_provider_views_destroy(views)
	for view in views do if view.catalog.provider=="codex" do testing.expect_value(t,view.detection_state,"present")
}

@(test)
test_provider_transport_http_presence_validation_and_atomic_updates :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 defer free_all(context.temp_allocator)
 f:=extension_test_setup(t,"transport")
 defer extension_test_teardown(f)
 extension_test_status(t,f,"claude","present","present")
 path:=fmt.tprintf("/api/v1/bridges/%s/providers/claude",f.bridge_id)
 // A legacy bridge cannot receive an ACP launch, even if its adapter says ready.
 ready:=`{"installed":true,"state":"ready","version":"0.108.0","node_version":"v22.0.0","error":null,"checked_at":"2026-11-18T00:00:00Z"}`
 _,_ = iface.bridge_provider_status_upsert(&f.pr_repo,{bridge_id=f.bridge_id,provider="claude",state="present",acp_adapter_json=ready})
 request:=extension_test_request(f,path,`{"transport":"acp","enabled":false}`);request.method="PUT"
 response:=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==409,response.body)
 testing.expect(t,strings.contains(response.body,"acp_unavailable"))
 settings,_:=iface.bridge_provider_setting_list(&f.pr_repo,f.bridge_id)
 if len(settings)>0 do testing.expect(t,settings[0].enabled,"rejected combined update must preserve enabled")
 domain.bridge_provider_settings_destroy(settings)
 bridge,_,_:=iface.bridge_get_bridge(&f.br_repo,f.bridge_id)
 bridge.capabilities_json=strings.clone(`{"features":["acp_runtime_v1"]}`)
 _,_,_=iface.bridge_save_bridge(&f.br_repo,bridge)
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 testing.expect(t,strings.contains(response.body,`"transport":"acp"`))
 testing.expect(t,strings.contains(response.body,`"effective_transport":"acp"`))
 // G6: a custom profile has its own selection (here none: the catalog
 // default) and repeats the provider-wide adapter report.
 profile_err:=provider_service.apply_profiles_report(&f.pr_svc,f.bridge_id,[]domain.Bridge_Provider_Profile{{profile_id="work",provider="claude",enabled=true,state="ok"}})
 testing.expect_value(t,profile_err.code,domain.Error_Code.None)
 views,view_err:=provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
 testing.expect_value(t,view_err.code,domain.Error_Code.None)
 custom_found:=false
 for view in views {
  if view.profile_id!="work" do continue
  custom_found=true
  testing.expect_value(t,view.transport,"")
  testing.expect_value(t,view.effective_transport,"pty")
  testing.expect_value(t,view.acp_adapter_json,ready)
 }
 testing.expect(t,custom_found)
 provider_service.bridge_provider_views_destroy(views)
 // Enable-only updates omit transport and retain it.
 request.body=`{"enabled":true}`
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 transport,_:=iface.get_provider_transport(&f.pr_repo,f.bridge_id,"claude")
 testing.expect_value(t,transport,"acp");delete(transport)
 // A settings save per profile: work selects ACP, then PTY, while the default
 // profile keeps ACP; the response is the saved profile's row.
 request.body=`{"profile_id":"work","transport":"acp"}`;response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 testing.expect(t,strings.contains(response.body,`"profile_id":"work"`) && strings.contains(response.body,`"transport":"acp"`) && strings.contains(response.body,`"effective_transport":"acp"`),response.body)
 transport,_=iface.get_provider_transport(&f.pr_repo,f.bridge_id,"claude","work")
 testing.expect_value(t,transport,"acp");delete(transport)
 request.body=`{"profile_id":"work","transport":"pty"}`;response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 testing.expect(t,strings.contains(response.body,`"effective_transport":"pty"`),response.body)
 views,view_err=provider_service.list_bridge_providers(&f.pr_svc,f.bridge_id)
 testing.expect_value(t,view_err.code,domain.Error_Code.None)
 for view in views do if view.catalog.provider=="claude" {
  // Two profiles of one provider on one bridge resolve differently.
  testing.expect_value(t,view.effective_transport,"pty" if view.profile_id=="work" else "acp")
 }
 provider_service.bridge_provider_views_destroy(views)
 // null clears the profile's choice together with an enabled change.
 request.body=`{"profile_id":"work","transport":null,"enabled":false}`;response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 testing.expect(t,strings.contains(response.body,`"transport":null`) && strings.contains(response.body,`"enabled":false`),response.body)
 transport,_=iface.get_provider_transport(&f.pr_repo,f.bridge_id,"claude","work")
 testing.expect_value(t,transport,"");delete(transport)
 // A disabled profile may still store its choice; an unknown profile may not.
 request.body=`{"profile_id":"work","transport":"pty"}`;response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 request.body=`{"profile_id":"nope","transport":"pty"}`;response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status!=200,response.body)
 transport,_=iface.get_provider_transport(&f.pr_repo,f.bridge_id,"claude","nope")
 testing.expect_value(t,transport,"");delete(transport)
 request.body=`{"profile_id":"work","transport":123}`;response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==422,response.body)
 testing.expect(t,strings.contains(response.body,"invalid_transport"),response.body)
 for body in ([]string{`{"transport":1}`,`{"transport":false}`,`{"transport":{}}`,`{"transport":"unknown"}`,`{"transport":""}`}) {
  request.body=body;response=bridge_provider_enable_handler(&f.ph,request)
  testing.expect(t,response.status==422,response.body)
  testing.expect(t,strings.contains(response.body,"invalid_transport"))
 }
 request.body=`{"enabled":null}`
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect_value(t,response.status,400)
 request.body=`{}`
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect_value(t,response.status,400)
 // Clearing and PTY saves work even when readiness/capability disappears.
 bridge.capabilities_json="{}"
 _,_,_=iface.bridge_save_bridge(&f.br_repo,bridge)
 request.body=`{"transport":null}`
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 testing.expect(t,strings.contains(response.body,`"transport":null`))
 testing.expect(t,strings.contains(response.body,`"effective_transport":"pty"`))
 bridge.status=.Offline
 _,_,_=iface.bridge_save_bridge(&f.br_repo,bridge)
 request.body=`{"transport":"acp"}`
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect(t,response.status==200,response.body)
 // Same owned endpoint still hides a foreign bridge.
 testing.expect(t,sqlite.exec(&f.conn,"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('brg_transport_foreign','other','','');"))
 request.path="/api/v1/bridges/brg_transport_foreign/providers/claude"
 response=bridge_provider_enable_handler(&f.ph,request)
 testing.expect_value(t,response.status,404)
}

@(test)
test_provider_transport_http_discovery_accepts_structured_adapter :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 defer free_all(context.temp_allocator)
 raw:=`{"providers":[{"provider":"claude","state":"present","acp_adapter":{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-18T00:00:00Z"}}]}`
 report:Provider_Discovery_Report_Wire
 err:=json.unmarshal_string(raw,&report,json.DEFAULT_SPECIFICATION,context.temp_allocator)
 testing.expect(t,err==nil)
 if len(report.providers)>0 {
  adapter:=provider_acp_adapter_wire_json(report.providers[0].acp_adapter)
  testing.expect(t,strings.contains(adapter,`"state":"ready"`))
 }
 f:=extension_test_setup(t,"transport_report")
 defer extension_test_teardown(f)
 created,create_err:=iface.provider_extension_command_create(&f.pr_repo,{command_id="cmd_ext_transport_report",bridge_id=f.bridge_id,kind="discovery",state="dispatched"})
 if !testing.expect(t,created,create_err.message) do return
 extension_test_report(t,f,"cmd_ext_transport_report",`[{"provider":"claude","state":"present","acp_adapter":{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-18T00:00:00Z"}}]`)
 statuses,status_err:=iface.bridge_provider_status_list(&f.pr_repo,f.bridge_id)
 testing.expect_value(t,status_err.code,domain.Error_Code.None)
 stored:=false
 for status in statuses {
  if status.provider!="claude" do continue
  stored=true
  testing.expect(t,strings.contains(status.acp_adapter_json,`"state":"ready"`))
 }
 testing.expect(t,stored,"tracked discovery also persists the adapter status")
 domain.bridge_provider_statuses_destroy(statuses)
}

@(test)
test_provider_transport_http_busy_is_storage_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// A second connection holds RESERVED: reads and BEGIN DEFERRED succeed,
	// but the actual transport INSERT/UPDATE gets SQLITE_BUSY.
	// Parallel suite processes share HOME. A fixed filename let one process
	// unlink the other's live database while its migrations or busy probe ran.
	path := fmt.aprintf("%s/.cache/heimdall-tests/t8-transport-busy-%d-%d.db", os.get_env("HOME", context.temp_allocator), os.get_pid(), i64(time.tick_now()._nsec))
	fmt.eprintf("PROVIDER_TRANSPORT_BUSY_DB path=%s\n", path)
	// Registered before connection cleanup, so these owned files are removed
	// only after the writer and fixture connections have both closed.
	defer {
		_ = os.remove(path)
		_ = os.remove(strings.concatenate({path, "-wal"}))
		_ = os.remove(strings.concatenate({path, "-shm"}))
		_ = os.remove(strings.concatenate({path, "-journal"}))
	}
	f := extension_test_setup(t, "transport_busy", path)
	if f == nil do return
	defer extension_test_teardown(f)
	writer, opened, open_err := sqlite.open(path)
	if !testing.expect(t, opened, open_err.message) do return
	defer sqlite.close(&writer)
	testing.expect(t, sqlite.exec(&f.conn, "PRAGMA busy_timeout=0;"))
	testing.expect(t, sqlite.exec(&writer, "BEGIN IMMEDIATE;"))
	defer sqlite.exec(&writer, "ROLLBACK;")
	// Exercise the same real repository through both direct and HTTP paths.
	err := iface.set_provider_transport(&f.pr_repo, f.bridge_id, "claude", "pty", "now")
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	route := strings.concatenate({"/api/v1/bridges/", f.bridge_id, "/providers/claude"})
	request := extension_test_request(f, route, `{"transport":"pty"}`)
	request.method = "PUT"
	response := bridge_provider_enable_handler(&f.ph, request)
	testing.expect_value(t, response.status, 500)
	testing.expect(t, strings.contains(response.body, "internal_error"), response.body)
	testing.expect(t, !strings.contains(response.body, "invalid_transport"))
}

// `ham-ctl bridge providers --bridge <id>` relays an instance token to
// provider-status so agents can learn the provider and model ids a launch
// accepts. Ownership still applies, and the mutating provider routes stay
// user-only.
@(test)
provider_status_accepts_relayed_instance_token_read_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "status_instance_token")
	defer extension_test_teardown(f)

	agent_bridge, a_ok, a_err := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id, bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd", machine_hostname = "agent-host",
	})
	if !testing.expectf(t, a_ok, "agent bridge enrolled (%s)", a_err.message) do return
	other_owner, f_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = "someone_else", bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd", machine_hostname = "foreign-host",
	})
	if !testing.expect(t, f_ok, "foreign bridge enrolled") do return
	_, inst_ok, inst_err := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
		agent_instance_id = "inst_status_reader", owner_user_id = domain.User_ID(f.owner_user_id),
		agent_id = "agt_status_reader", bridge_id = agent_bridge.bridge.bridge_id, display_name = "reader",
		runtime_status = "running", startup_status = "ready",
		created_at = "2026-11-21T00:00:00Z", updated_at = "2026-11-21T00:00:00Z",
	})
	if !testing.expectf(t, inst_ok, "instance saved (%s)", inst_err.message) do return
	extension_test_status(t, f, "claude", "present", "current")

	headers := []contracts.HTTP_Header{
		{name = "Authorization", value = strings.concatenate({"Bearer ", agent_bridge.bridge_token})},
		{name = "X-Heimdall-Instance-Token", value = "hit_inst_status_reader"},
	}
	instance_request :: proc(headers: []contracts.HTTP_Header, method, path: string) -> Request {
		return {method = method, path = path, body = "{}", request_id = "req_status_inst", remote_addr = "127.0.0.1:4444", headers = headers}
	}

	ok_resp := bridge_provider_status_handler(&f.ph, instance_request(headers, "GET", fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id)))
	testing.expectf(t, ok_resp.status == 200, "instance token reads an owned bridge's provider-status: %d %s", ok_resp.status, ok_resp.body)
	testing.expect(t, strings.contains(ok_resp.body, `"provider":"claude"`), ok_resp.body)
	testing.expect(t, strings.contains(ok_resp.body, `"models":[`), ok_resp.body)

	foreign_resp := bridge_provider_status_handler(&f.ph, instance_request(headers, "GET", fmt.tprintf("/api/v1/bridges/%s/provider-status", other_owner.bridge.bridge_id)))
	testing.expect_value(t, foreign_resp.status, 404)

	bare := []contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", agent_bridge.bridge_token})}}
	bare_resp := bridge_provider_status_handler(&f.ph, instance_request(bare, "GET", fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id)))
	testing.expect(t, bare_resp.status != 200, "a bare bridge token is still refused")

	put_resp := bridge_provider_enable_handler(&f.ph, instance_request(headers, "PUT", fmt.tprintf("/api/v1/bridges/%s/providers/claude", f.bridge_id)))
	testing.expect(t, put_resp.status == 401 || put_resp.status == 403, fmt.tprintf("mutating provider route stays user-only: %d %s", put_resp.status, put_resp.body))
}

// GET /api/v1/bridges/{id}/providers rows carry descriptor-derived fields the UI
// reads instead of its own provider lists: extension.installable (active row +
// extension JSON + a registry extension) and profile_config_dir.
@(test)
test_bridge_provider_row_descriptor_fields :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	row :: proc(provider, state, extension_json: string) -> string {
		view := provider_service.Bridge_Provider_View{
			catalog = domain.Provider_Catalog_Entry{provider = provider, state = state, extension_json = extension_json},
		}
		b := strings.builder_make()
		write_bridge_provider_view_json(&b, view, "")
		text := strings.to_string(b)
		parsed, err := json.parse_string(text)
		if err != nil do return ""
		_ = parsed
		return text
	}
	EXT :: `{"plugin_id":"heimdall@x","min_version":"1.0.0","install_hint":"h","capabilities":["activity"]}`

	claude := row("claude", "active", EXT)
	testing.expect(t, strings.contains(claude, `"capabilities":["activity"],"installable":true}`), claude)
	testing.expect(t, strings.contains(claude, `"profile_config_dir":{"field":"config_dir","env":"CLAUDE_CONFIG_DIR"}`), claude)

	codex := row("codex", "active", EXT)
	testing.expect(t, strings.contains(codex, `"installable":true`), codex)
	testing.expect(t, strings.contains(codex, `"profile_config_dir":{"field":"home_path","env":"CODEX_HOME"}`), codex)

	agy := row("antigravity", "active", EXT)
	testing.expect(t, strings.contains(agy, `"installable":true`), agy)
	testing.expect(t, strings.contains(agy, `"profile_config_dir":null`), agy)

	// Extension JSON alone is not enough: the registry has no copilot extension.
	copilot := row("copilot", "active", EXT)
	testing.expect(t, strings.contains(copilot, `"installable":false`), copilot)
	testing.expect(t, strings.contains(copilot, `"profile_config_dir":{"field":"config_dir","env":"COPILOT_HOME"}`), copilot)

	kiro := row("kiro", "active", "")
	testing.expect(t, strings.contains(kiro, `"extension":null`), kiro)
	testing.expect(t, strings.contains(kiro, `"profile_config_dir":{"field":"config_dir","env":"KIRO_HOME"}`), kiro)

	retired := row("claude", "retired", EXT)
	testing.expect(t, strings.contains(retired, `"installable":false`), retired)

	unknown := row("custom-cli", "active", EXT)
	testing.expect(t, strings.contains(unknown, `"installable":false`), unknown)
	testing.expect(t, strings.contains(unknown, `"profile_config_dir":null`), unknown)
	for text in ([]string{claude, codex, agy, copilot, kiro, retired, unknown}) do testing.expect(t, text != "", "row is valid JSON")
}

// R2 G5: an inline redetector wired to this fixture's handlers.
@(private = "file")
redetect_test_enable :: proc(t: ^testing.T, f: ^extension_handler_fixture, r: ^provider_service.ACP_Redetector) {
	provider_service.acp_redetector_init(r, provider_acp_redetect_dispatch, &f.ph)
	r.inline = true
	f.pr_svc.redetector = r
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	defer domain.bridge_destroy(&bridge)
	delete(bridge.capabilities_json); bridge.capabilities_json = strings.clone(`{"features":["acp_runtime_v1"]}`)
	_, saved, _ := iface.bridge_save_bridge(&f.br_repo, bridge)
	testing.expect(t, saved)
}

@(private = "file")
redetect_test_adapter :: proc(t: ^testing.T, f: ^extension_handler_fixture, provider: string) -> string {
	statuses, err := iface.bridge_provider_status_list(&f.pr_repo, f.bridge_id)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer domain.bridge_provider_statuses_destroy(statuses)
	for s in statuses do if s.provider == provider && s.profile_id == provider do return strings.clone(s.acp_adapter_json, context.temp_allocator)
	return ""
}

@(private = "file")
redetect_test_read :: proc(t: ^testing.T, f: ^extension_handler_fixture) {
	req := extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id))
	req.method = "GET"
	testing.expect_value(t, bridge_provider_status_handler(&f.ph, req).status, 200)
}

// A stale status read sends one provider-scoped discover; its report is
// applied; nothing is persisted; later triggers (after the window, or after a
// failed send) send again; reports the Hub did not ask for are ignored.
@(test)
r2_stale_status_read_redetects_with_provider_scoped_discover :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "r2_redetect_read"); defer extension_test_teardown(f)
	r: provider_service.ACP_Redetector
	redetect_test_enable(t, f, &r); defer provider_service.acp_redetector_destroy(&r)
	ready := fmt.tprintf(`{{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-26T00:00:00Z","adapter_package":"%s","adapter_version":"0.108.0"}}`, contracts.ACP_CLAUDE_DESCRIPTOR.pkg.name)
	ok, upsert_err := iface.bridge_provider_status_upsert(&f.pr_repo, {bridge_id = f.bridge_id, provider = "claude", profile_id = "claude", state = "present", acp_adapter_json = ready})
	testing.expect(t, ok && upsert_err.code == .None)
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 0) // just received: fresh
	make_stale :: proc(f: ^extension_handler_fixture) { sqlite.exec(&f.conn, "UPDATE bridge_provider_status SET acp_adapter_received_at='2020-01-01T00:00:00Z';") }
	make_stale(f)
	redetect_test_read(t, f)
	if !testing.expect_value(t, f.sink_rec.count, 1) do return
	id := strings.clone(f.sink_rec.last_cmd.command_id, context.temp_allocator)
	testing.expect(t, strings.has_prefix(id, ACP_REDETECT_COMMAND_PREFIX), id)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type", context.temp_allocator), "provider_discover")
	testing.expect(t, strings.contains(f.sink_rec.last_cmd.body_json, `"providers":["claude"]`), f.sink_rec.last_cmd.body_json)
	commands := extension_test_commands(t, f)
	testing.expect_value(t, len(commands), 0) // never persisted
	domain.provider_extension_commands_destroy(commands)
	// In flight: no second request even after the window.
	provider_service.acp_redetector_clear_window(&r)
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 1)
	// A report the Hub did not ask for (another id) changes nothing.
	extension_test_report(t, f, "acp_rd_forged", `[{"provider":"claude","state":"present","acp_adapter":{"installed":false,"state":"missing","checked_at":"2026-11-28T00:00:00Z"}}]`)
	testing.expect(t, strings.contains(redetect_test_adapter(t, f, "claude"), `"state":"ready"`))
	// The matching report is applied and ends the request.
	extension_test_report(t, f, id, `[{"provider":"claude","state":"present","acp_adapter":{"installed":false,"state":"missing_node","checked_at":"2026-11-28T00:00:00Z"}},{"provider":"codex","state":"present","acp_adapter":{"installed":false,"state":"missing","checked_at":"2026-11-28T00:00:00Z"}}]`)
	testing.expect(t, strings.contains(redetect_test_adapter(t, f, "claude"), `"state":"missing_node"`), redetect_test_adapter(t, f, "claude"))
	testing.expect_value(t, redetect_test_adapter(t, f, "codex"), "") // only the provider asked for
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 1) // the applied report is fresh
	// After the window a stale report is re-detected again, with a new id.
	make_stale(f); provider_service.acp_redetector_clear_window(&r)
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 2)
	testing.expect(t, f.sink_rec.last_cmd.command_id != id)
	extension_test_report(t, f, f.sink_rec.last_cmd.command_id, `[{"provider":"claude","state":"present","acp_adapter":{"installed":false,"state":"missing_node","checked_at":"2026-11-28T00:01:00Z"}}]`)
	// A failed send does not block later re-detects.
	make_stale(f); provider_service.acp_redetector_clear_window(&r)
	f.sink_rec.fail = true
	redetect_test_read(t, f)
	f.sink_rec.fail = false
	provider_service.acp_redetector_clear_window(&r)
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 3)
}

// The launch gate re-checks a not-ready System runtime with the tracked
// install_acp_adapter command; a lost one is failed and replaced.
@(test)
r2_launch_gate_rechecks_system_runtime_and_replaces_a_lost_command :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "r2_redetect_gate"); defer extension_test_teardown(f)
	r: provider_service.ACP_Redetector
	redetect_test_enable(t, f, &r); defer provider_service.acp_redetector_destroy(&r)
	ok, upsert_err := iface.bridge_provider_status_upsert(&f.pr_repo, {bridge_id = f.bridge_id, provider = "copilot", profile_id = "copilot", state = "present",
		acp_adapter_json = `{"installed":true,"state":"error","version":"1.0.120","checked_at":"2026-11-27T00:00:00Z","error":"ACP initialize probe is required for the selected profile; use Re-check"}`})
	testing.expect(t, ok && upsert_err.code == .None)
	entry, found, err := iface.provider_catalog_get(&f.pr_repo, "copilot")
	if !testing.expect(t, found && err.code == .None) do return
	defer domain.provider_catalog_entry_destroy(entry)
	testing.expect_value(t, provider_service.require_acp_ready(&f.pr_svc, f.bridge_id, entry, "").code, domain.Error_Code.ACP_Unavailable)
	if !testing.expect_value(t, f.sink_rec.count, 1) do return
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type", context.temp_allocator), "install_acp_adapter")
	first := strings.clone(f.sink_rec.last_cmd.command_id, context.temp_allocator)
	// Gate retries do not pile up commands.
	testing.expect_value(t, provider_service.require_acp_ready(&f.pr_svc, f.bridge_id, entry, "").code, domain.Error_Code.ACP_Unavailable)
	testing.expect_value(t, f.sink_rec.count, 1)
	// No result within the TTL: the command is failed and a new one sent.
	provider_service.acp_redetect_pending_set(&r, f.bridge_id, "copilot", first, .Recheck, time.time_add(time.now(), -(provider_service.ACP_REDETECT_INFLIGHT_TTL + time.Second)))
	provider_service.acp_redetector_clear_window(&r)
	testing.expect_value(t, provider_service.require_acp_ready(&f.pr_svc, f.bridge_id, entry, "").code, domain.Error_Code.ACP_Unavailable)
	testing.expect_value(t, f.sink_rec.count, 2)
	second := strings.clone(f.sink_rec.last_cmd.command_id, context.temp_allocator)
	testing.expect(t, second != first)
	testing.expect_value(t, extension_test_state(t, f, first), "failed")
	// Its terminal result ends the re-detection in flight.
	result := strings.concatenate({`{"command_id":"`, second, `","status":"succeeded"}`}, context.temp_allocator)
	testing.expect_value(t, bridge_extension_frame(&f.bh, f.bridge_id, "command_result", result).code, domain.Error_Code.None)
	testing.expect_value(t, provider_service.acp_redetect_pending_expired(&r, f.bridge_id, "copilot", time.time_add(time.now(), time.Hour)), "")
}

// A "ready" report bound to another catalog recipe is not ready; selecting
// ACP re-checks it (provider_handlers enable path).
@(test)
r2_enable_acp_rechecks_a_ready_report_for_another_recipe :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "r2_enable_mismatch"); defer extension_test_teardown(f)
	bridge, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id); defer domain.bridge_destroy(&bridge)
	bridge.capabilities_json = strings.clone(`{"features":["acp_runtime_v1"]}`)
	iface.bridge_save_bridge(&f.br_repo, bridge)
	iface.bridge_provider_status_upsert(&f.pr_repo, {bridge_id = f.bridge_id, provider = "claude", profile_id = "claude", state = "present",
		acp_adapter_json = fmt.tprintf(`{{"installed":true,"state":"ready","version":"0.0.1","checked_at":"2026-11-27T00:00:00Z","adapter_package":"%s","adapter_version":"0.0.1"}}`, contracts.ACP_CLAUDE_DESCRIPTOR.pkg.name)})
	path := fmt.tprintf("/api/v1/bridges/%s/providers/claude", f.bridge_id)
	response := bridge_provider_enable_handler(&f.ph, extension_test_request(f, path, `{"transport":"acp"}`))
	testing.expect(t, response.status == 409 && strings.contains(response.body, "acp_installing"), response.body)
	testing.expect_value(t, f.sink_rec.count, 1)
	testing.expect_value(t, json_string(f.sink_rec.last_cmd.body_json, "type", context.temp_allocator), "install_acp_adapter")
	transport, err := iface.get_provider_transport(&f.pr_repo, f.bridge_id, "claude"); defer delete(transport)
	testing.expect(t, err.code == .None && transport == "", "the setting is not saved until ready")
}

// G9: the status row carries the ACP runtime kind from the compiled descriptor.
@(test)
r2_provider_status_reports_acp_runtime_kind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "r2_runtime_kind"); defer extension_test_teardown(f)
	req := extension_test_request(f, fmt.tprintf("/api/v1/bridges/%s/provider-status", f.bridge_id))
	req.method = "GET"
	response := bridge_provider_status_handler(&f.ph, req)
	testing.expect_value(t, response.status, 200)
	value, err := json.parse_string(response.body)
	if !testing.expect(t, err == nil) do return
	data, _ := value.(json.Object)["data"].(json.Object)
	providers, _ := data["providers"].(json.Array)
	kinds := map[string]string{}
	for item in providers {
		row := item.(json.Object)
		name, _ := row["provider"].(json.String)
		if kind, is_string := row["acp_runtime_kind"].(json.String); is_string do kinds[string(name)] = string(kind)
		else if _, is_null := row["acp_runtime_kind"].(json.Null); is_null do kinds[string(name)] = "null"
	}
	testing.expect_value(t, kinds["claude"], "adapter")
	testing.expect_value(t, kinds["copilot"], "system")
	testing.expect_value(t, kinds["opencode"], "system")
	testing.expect_value(t, kinds["antigravity"], "null")
}

// A gate Re-check that joins the user's own install never fails it as lost.
@(test)
r2_launch_gate_joins_a_user_install_without_owning_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "r2_redetect_join"); defer extension_test_teardown(f)
	r: provider_service.ACP_Redetector
	redetect_test_enable(t, f, &r); defer provider_service.acp_redetector_destroy(&r)
	iface.bridge_provider_status_upsert(&f.pr_repo, {bridge_id = f.bridge_id, provider = "copilot", profile_id = "copilot", state = "present",
		acp_adapter_json = `{"installed":false,"state":"missing","checked_at":"2026-11-27T00:00:00Z"}`})
	path := fmt.tprintf("/api/v1/bridges/%s/providers/copilot/acp-adapter", f.bridge_id)
	response := bridge_provider_acp_adapter_handler(&f.ph, extension_test_request(f, path, `{"action":"install"}`))
	if !testing.expect_value(t, response.status, 202) do return
	user := json_string(response.body, "command_id", context.temp_allocator)
	entry, _, _ := iface.provider_catalog_get(&f.pr_repo, "copilot"); defer domain.provider_catalog_entry_destroy(entry)
	testing.expect_value(t, provider_service.require_acp_ready(&f.pr_svc, f.bridge_id, entry, "").code, domain.Error_Code.ACP_Unavailable)
	testing.expect_value(t, f.sink_rec.count, 1) // joined, not duplicated
	testing.expect_value(t, provider_service.acp_redetect_pending_expired(&r, f.bridge_id, "copilot", time.time_add(time.now(), time.Hour)), "")
	testing.expect_value(t, extension_test_state(t, f, user), "dispatched")
}

// A failed re-detect discover ends its in-flight state at once.
@(test)
r2_failed_redetect_discover_result_clears_in_flight :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := extension_test_setup(t, "r2_redetect_failed"); defer extension_test_teardown(f)
	r: provider_service.ACP_Redetector
	redetect_test_enable(t, f, &r); defer provider_service.acp_redetector_destroy(&r)
	iface.bridge_provider_status_upsert(&f.pr_repo, {bridge_id = f.bridge_id, provider = "claude", profile_id = "claude", state = "present",
		acp_adapter_json = `{"installed":false,"state":"missing_node","checked_at":"2026-11-27T00:00:00Z"}`})
	sqlite.exec(&f.conn, "UPDATE bridge_provider_status SET acp_adapter_received_at='2020-01-01T00:00:00Z';")
	redetect_test_read(t, f)
	if !testing.expect_value(t, f.sink_rec.count, 1) do return
	id := strings.clone(f.sink_rec.last_cmd.command_id, context.temp_allocator)
	// Another bridge's failure for this id changes nothing.
	failed := fmt.tprintf(`{{"command_id":"%s","status":"failed","error":{{"cause":"provider_catalog_not_ready"}}}}`, id)
	testing.expect_value(t, bridge_extension_frame(&f.bh, "brg_other", "command_result", failed).code, domain.Error_Code.None)
	provider_service.acp_redetector_clear_window(&r)
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 1) // still in flight
	testing.expect_value(t, bridge_extension_frame(&f.bh, f.bridge_id, "command_result", failed).code, domain.Error_Code.None)
	provider_service.acp_redetector_clear_window(&r)
	redetect_test_read(t, f)
	testing.expect_value(t, f.sink_rec.count, 2) // re-detected again
}
