package bridge_bot_delivery_integration_test

// Run from the checkout root after building ham-bridge, ham-ctl, ham-pty-host.
// Run only these tests (imports also contain their own unit suites):
// odin test tests/bridge_bot_delivery_integration_test.odin -file \
//   -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/bot-integration-$$ \
//   -define:ODIN_TEST_NAMES=test_bot_delivery_real_hub_bridge_reply,test_bot_delivery_real_hub_bridge_idle_no_reply
// Put their bin directories on PATH, or set BOT_TEST_BRIDGE, BOT_TEST_CTL,
// BOT_TEST_PTY_HOST. No live hub, bridge or host credentials are used.
import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import bridge "odin_test:bridge"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import bots "odin_test:hub/service/bots"
import bridge_service "odin_test:hub/service/bridge"
import runtime_service "odin_test:hub/service/bridge_runtime"
import channel "odin_test:hub/service/channel"
import provider_service "odin_test:hub/service/provider"
import http "odin_test:hub/transport/http"
import vault "odin_test:lib/vault"

Server :: struct {
	listener:                              net.TCP_Socket,
	port:                                  int,
	graph:                                 ^app.App_Graph,
	upstream:                              int,
	stopping:                              bool,
	worker:                                ^thread.Thread,
	clients:                               [dynamic]net.TCP_Socket,
	threads:                               [dynamic]^thread.Thread,
	mu:                                    sync.Mutex,
	terminal_seq, ack_seq, terminal_count: int,
	terminal_attempt, ack_attempt:         string,
	reads, sends:                          int,
	r2:                                    bool,
}
Pump :: struct {
	server:   ^Server,
	src, dst: net.TCP_Socket,
	to_hub:   bool,
}
listen :: proc() -> (net.TCP_Socket, int, bool) {
	s, e := net.listen_tcp({net.IP4_Loopback, 0})
	if e != nil do return {}, 0, false
	ep, ee := net.bound_endpoint(s)
	return s, ep.port, ee == nil
}
serve_loop :: proc(data: rawptr) {
	s := (^Server)(data)
	for {
		client, peer, err := net.accept_tcp(s.listener)
		if err != nil do break
		if sync.atomic_load(&s.stopping) {net.close(client); break}
		append(&s.clients, client)
		if s.upstream == 0 {
			worker := thread.create_and_start_with_poly_data3(
				client,
				peer,
				s.graph,
				proc(c: net.TCP_Socket, p: net.Endpoint, g: ^app.App_Graph) {
					http.handle_client(c, p, &g.router)
				},
			)
			append(&s.threads, worker)
		} else {
			upstream, e := net.dial_tcp(net.Endpoint{net.IP4_Loopback, s.upstream})
			if e != nil {net.close(client); continue}
			append(&s.clients, upstream)
			for value in ([]Pump{{s, client, upstream, true}, {s, upstream, client, false}}) {
				p := new(Pump); p^ = value
				append(&s.threads, thread.create_and_start_with_data(p, pump))
			}
		}
	}
}
start_server :: proc(s: ^Server) -> bool {
	ok: bool
	s.listener, s.port, ok = listen()
	if !ok do return false
	s.worker = thread.create_and_start_with_data(s, serve_loop)
	return true
}
stop_server :: proc(s: ^Server) {
	if s.worker == nil do return
	sync.atomic_store(&s.stopping, true)
	wake, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, s.port})
	if err == nil do net.close(wake)
	thread.join(s.worker); thread.destroy(s.worker); net.close(s.listener)
	for c in s.clients do _ = net.shutdown(c, .Both)
	for t in s.threads {thread.join(t); thread.destroy(t)}
	if s.upstream != 0 do for c in s.clients do net.close(c)
	delete(
		s.clients,
	); delete(s.threads); delete(s.terminal_attempt, runtime.heap_allocator()); delete(s.ack_attempt, runtime.heap_allocator())
}
// Transparent TCP observer: all bytes reach the production graph unchanged.
// Reassemble frames across TCP segments and unmask bridge frames for assertions.
pump :: proc(data: rawptr) {
	p := (^Pump)(data)
	defer free(p)
	defer free_all(context.temp_allocator)
	defer _ = net.shutdown(p.dst, .Both)
	pending := make([dynamic]byte)
	defer delete(pending)
	headers, websocket := false, false
	buf: [16384]byte
	for {
		n, e := net.recv_tcp(p.src, buf[:])
		if e != nil || n == 0 do return
		sent := 0
		for sent < n {
			written, we := net.send_tcp(p.dst, buf[sent:n])
			if we != nil || written == 0 do return
			sent += written
		}
		if headers && !websocket do continue
		append(&pending, ..buf[:n])
		if !headers {
			end := strings.index(string(pending[:]), "\r\n\r\n")
			if end < 0 do continue
			header := string(pending[:end])
			websocket = strings.contains(header, "websocket") || strings.contains(header, "101 Switching")
			if p.to_hub {
				sync.mutex_lock(&p.server.mu)
				if strings.contains(header, "POST /api/v1/agent-actions/channel/read ") do p.server.reads += 1
				if strings.contains(header, "POST /api/v1/agent-actions/channel/send ") do p.server.sends += 1
				sync.mutex_unlock(&p.server.mu)
			}
			copy(pending[:], pending[end + 4:])
			resize(&pending, len(pending) - end - 4)
			headers = true
		}
		if !websocket do continue
		for len(pending) >= 2 {
			count, offset := int(pending[1] & 127), 2
			if count == 126 {
				if len(pending) < 4 do break
				count = int(pending[2]) * 256 + int(pending[3]); offset = 4
			} else if count == 127 {
				if len(pending) < 10 do break
				count = 0
				for v in pending[2:10] do count = count * 256 + int(v)
				offset = 10
			}
			masked := pending[1] & 128 != 0
			mask_at := offset
			if masked do offset += 4
			if count < 0 || count > 16 * 1024 * 1024 do return
			if len(pending) < offset + count do break
			if pending[0] & 15 == 1 {
				payload := make([]byte, count)
				for i in 0 ..< count {
					payload[i] = pending[offset + i]
					if masked do payload[i] ~= pending[mask_at + i % 4]
				}
				observe_frame(p.server, string(payload))
				delete(payload)
			}
			used := offset + count
			copy(pending[:], pending[used:]); resize(&pending, len(pending) - used)
		}
	}
}
observe_frame :: proc(s: ^Server, raw: string) {
	frame: struct {
		type, attempt_id, state: string,
		seq:                     int,
	}
	if json.unmarshal_string(raw, &frame, allocator = context.temp_allocator) != nil do return
	sync.mutex_lock(&s.mu); defer sync.mutex_unlock(&s.mu)
	if frame.type == "bot_delivery_report" && (frame.state == "acted" || frame.state == "exhausted") {
		s.terminal_seq = frame.seq; s.terminal_count += 1
		if s.terminal_attempt == "" do s.terminal_attempt = strings.clone(frame.attempt_id, runtime.heap_allocator())
	}
	if frame.type == "bot_delivery_report_ack" {
		s.ack_seq = max(s.ack_seq, frame.seq)
		if s.ack_attempt == "" do s.ack_attempt = strings.clone(frame.attempt_id, runtime.heap_allocator())
	}
}
adapter_send :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	if chat != "111" do return "", {kind = .Invalid_Request}
	return strings.clone("test-sent"), {}
}
binary :: proc(key, fallback: string) -> string {
	v := os.get_env(key, context.temp_allocator)
	return v if v != "" else fallback
}
quote :: proc(v: string) -> string {
	escaped, _ := strings.replace_all(v, "'", "'\\''", context.temp_allocator)
	return strings.concatenate({"'", escaped, "'"}, context.temp_allocator)
}
write :: proc(t: ^testing.T, path, body: string, executable := false) -> bool {
	mode := os.Permissions{.Read_User, .Write_User}
	if executable do mode += {.Execute_User}
	return testing.expect(t, os.write_entire_file(path, transmute([]byte)body, mode) == nil, path)
}
scalar :: proc(db: ^sqlite.Conn, query: string) -> string {
	stmt: sqlite.sqlite3_stmt
	if sqlite.sqlite3_prepare_v2(db.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != sqlite.SQLITE_OK do return ""
	defer sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW do return ""
	return strings.clone(string(sqlite.sqlite3_column_text(stmt, 0)), context.temp_allocator)
}
integration_mu: sync.Mutex

integration_case :: proc(t: ^testing.T, mode: string) {
	sync.mutex_lock(&integration_mu)
	defer sync.mutex_unlock(&integration_mu)
	context.allocator = context.temp_allocator
	root := fmt.tprintf("/tmp/heimdall-bot-delivery-%d-%s", os.get_pid(), mode)
	if !testing.expect(t, os.make_directory_all(root) == nil) do return
	defer _ = os.remove_all(root)
	cwd, _ := filepath.abs(".", context.temp_allocator)
	graph := new(app.App_Graph)
	built, message := app.build_graph(
		graph,
		{
			database_path = cat(root, "/hub.db"),
			migrations_dir = "src/hub/repository/sqlite/migrations",
			auto_provision_users = true,
			paddle_environment = "sandbox",
		},
	)
	if !testing.expect(t, built, message) do return
	defer app.shutdown_graph(graph)
	timers := bots.default_bot_timer_config()
	timers.read_ms = 5000; timers.idle_no_reply_ms = 3000
	graph.bots.timers = timers
	adapter := channel.Channel_Adapter {
		provider  = "telegram",
		send_text = adapter_send,
	}
	graph.bots.adapter = &adapter
	hub := Server {
		graph = graph,
	}
	if !testing.expect(t, start_server(&hub)) do return
	defer stop_server(&hub)
	proxy := Server {
		upstream = hub.port,
		graph    = graph,
	}
	if !testing.expect(t, start_server(&proxy)) do return
	defer stop_server(&proxy)
	for &route in graph.router.routes {
		if route.path == "/api/v1/agent-actions/channel/send" {
			route.ctx = &proxy
			route.handler = proc(ctx: rawptr, req: http.Request) -> http.Response {
				s := (^Server)(ctx)
				response := http.bot_agent_channel_send_handler(&s.graph.bot_agent_handlers, req)
				if response.status == 200 {
					state := scalar(&s.graph.db, "SELECT state FROM bot_deliveries LIMIT 1")
					sync.atomic_store(&s.r2, state == "acted")
				}
				return response
			}
		}
	}
	hub_url := fmt.tprintf("http://127.0.0.1:%d", proxy.port)
	graph.ids.generate = proc(ctx: rawptr, prefix: string) -> string {
		p := "brg_test_" if prefix == "brg_" else prefix
		return fmt.tprintf("%s%x", p, time.to_unix_nanoseconds(time.now()))
	}
	enrolled, ok, ee := bridge_service.enroll_bridge_from_device_grant(
		&graph.bridges,
		{owner_user_id = "bot-integration-owner", bridge_public_key = "04aabb"},
	)
	if !testing.expect(t, ok, ee.message) do return
	id := enrolled.bridge.bridge_id
	if !write(t, cat(root, "/bridge-token"), bridge.bridge_credential_file_text(hub_url, id, enrolled.bridge_token)) do return
	scope, scoped := bridge.keystore_scope_name_for_hub(hub_url, id)
	if !testing.expect(t, scoped) do return
	identity_dir := cat(root, "/home/.config/heimdall/bridges/", scope)
	_ = os.make_directory_all(identity_dir)
	_ = os.chmod(identity_dir, {.Read_User, .Write_User, .Execute_User})
	record := make([dynamic]byte, context.temp_allocator)
	append(&record, ..transmute([]byte)string("HBI2"))
	append(&record, u8(len("bot-integration-owner")))
	append(&record, ..transmute([]byte)string("bot-integration-owner"))
	append(&record, u8(len(hub_url)))
	append(&record, ..transmute([]byte)hub_url)
	scalar_key: [32]byte; scalar_key[31] = 1
	append(&record, ..scalar_key[:])
	if !write(t, cat(identity_dir, "/identity_key"), string(record[:])) do return

	// Production explicit startup override; no host keystore is read or written.
	key: [32]byte; key[0] = 42
	vault_id: vault.Vault_Id; vault_id[0] = 1
	kr, kr_ok := vault.keyring_from_single_key("bot-integration-owner", vault_id, 1, key[:])
	if !testing.expect(t, kr_ok) do return
	defer vault.keyring_wipe(&kr)
	kr_bytes, _ := vault.keyring_serialize(&kr, context.temp_allocator)
	keyring, _ := base64.encode(kr_bytes, allocator = context.temp_allocator)
	_ = os.make_directory_all(cat(root, "/data/bridge"))
	_ = os.make_directory_all(cat(root, "/bin"))
	ctl := binary("BOT_TEST_CTL", "ham-ctl")
	// Probes never start the bot or call the CLI. The launched command supplies
	// HAM_CTL and mode inline, after the wrapper's environment sanitization.
	agent_cmd := fmt.tprintf(
		"#!/bin/sh\ncase $1 in --version) echo 'pi 1.0'; exit 0;; esac\nexec env HAM_CTL=%s BOT_AGENT_MODE=%s %s\n",
		quote(ctl),
		quote(mode),
		quote(cat(cwd, "/tools/mock_agent/bot-agent.sh")),
	)
	if !write(t, cat(root, "/bin/pi"), agent_cmd, true) do return
	profile := bridge.Provider_Profile_Store_Wire {
		version  = 2,
		profiles = []bridge.Provider_Profile {
			{
				profile_id = "pi",
				provider = "pi",
				enabled = true,
				config = {binary_path = cat(root, "/bin/pi"), custom_models = []string{"test-model"}},
			},
		},
	}
	profile_json, _ := json.marshal(profile, allocator = context.temp_allocator)
	if !write(t, cat(root, "/data/bridge/provider_profiles.json"), string(profile_json)) do return
	config := fmt.tprintf(
		"[daemon]\ndaemon_id = \"%s\"\ndata_dir = \"%s/data\"\n[wrapper]\nagent_run_dir = \"%s/runs\"\n[bridge]\npty_host_runtime = true\n",
		id,
		root,
		root,
	)
	if !write(t, cat(root, "/config.toml"), config) do return
	bp, bridge_port, _ := listen(); net.close(bp)
	ep, endpoint_port, _ := listen(); net.close(ep)
	log, le := os.open(cat(root, "/bridge.log"), os.O_WRONLY | os.O_CREATE | os.O_TRUNC, {.Read_User, .Write_User})
	if !testing.expect(t, le == nil) do return
	defer os.close(log)
	args := []string {
		"setsid",
		"env",
		"-u",
		"HEIMDALL_AGENT_TOKEN",
		"-u",
		"HEIMDALL_AGENT_INSTANCE_ID",
		"-u",
		"HEIMDALL_BRIDGE_ENDPOINT",
		cat("HOME=", root, "/home"),
		cat("XDG_CONFIG_HOME=", root, "/home/.config"),
		cat("XDG_DATA_HOME=", root, "/home/.local/share"),
		cat("XDG_STATE_HOME=", root, "/home/.local/state"),
		cat("PATH=", root, "/bin:", os.get_env("PATH", context.temp_allocator)),
		cat("HEIMDALL_VAULT_KEYRING=", keyring),
		cat("HEIMDALL_HAM_CTL_BIN=", ctl),
		"HEIMDALL_BRIDGE_PTY_HOST=1",
		cat("HEIMDALL_HAM_PTY_HOST_BIN=", binary("BOT_TEST_PTY_HOST", "ham-pty-host")),
		binary("BOT_TEST_BRIDGE", "ham-bridge"),
		"--config",
		cat(root, "/config.toml"),
		"--hub",
		hub_url,
		"--port",
		fmt.tprintf("%d", bridge_port),
		"--bridge-token-file",
		cat(root, "/bridge-token"),
		"--local-run-dir",
		cat(root, "/endpoint"),
		"--local-endpoint-port",
		fmt.tprintf("%d", endpoint_port),
		"--no-local-proxy",
	}
	child, ce := os.process_start({command = args, stdout = log, stderr = log, working_dir = cwd})
	if !testing.expect(t, ce == nil) do return
	defer {
		cleanup_children(t, child)
		data, _ := os.read_entire_file(cat(root, "/bridge.log"), context.temp_allocator)
		fmt.println("BRIDGE LOG", mode, string(data))
	}
	if !testing.expect(t, bridge.bridge_shell_test_wait_for_own_session(child.pid)) do return
	ready := false
	started := time.tick_now()
	for time.tick_since(started) < 30 * time.Second {
		b, found, _ := iface.bridge_get_bridge(&graph.repos.bridges, id)
		ready = found && b.status == .Online && b.vault_status == "unlocked"
		domain.bridge_destroy(&b)
		if ready do break
		time.sleep(50 * time.Millisecond)
	}
	if !testing.expect(t, ready, "real bridge must hello with unlocked test keyring") do return
	discover_id := "pdr_bot_integration"
	command := http.provider_discover_command_json(discover_id, []string{"pi"})
	reply, discovered, de := runtime_service.send_runtime_command_wait(
		&graph.bridge_runtime_registry,
		{bridge_id = id, command_id = discover_id, body_json = command},
		15000,
	)
	if !testing.expect(t, discovered, cat(de.message, " ", reply)) do return
	report: http.Provider_Discovery_Report_Wire
	if !testing.expect(t, json.unmarshal_string(reply, &report, allocator = context.temp_allocator) == nil, reply) do return
	statuses := make([]domain.Bridge_Provider_Status, len(report.providers), context.temp_allocator)
	for item, i in report.providers {
		statuses[i] = {
			bridge_id            = id,
			provider             = item.provider,
			profile_id           = item.profile_id,
			binary_path          = item.binary_path,
			version_text         = item.version_text,
			state                = item.state,
			checked_at           = item.checked_at,
			extension_state      = item.extension_state,
			extension_version    = item.extension_version,
			extension_checked_at = item.extension_checked_at,
		}
	}
	if !testing.expect_value(t, provider_service.apply_discovery_report(&graph.providers, id, statuses).code, domain.Error_Code.None) do return
	if !testing.expect_value(t, scalar(&graph.db, "SELECT state FROM bridge_provider_status WHERE provider='pi'"), "present") do return
	_, exp_err := iface.experiment_set(
		&graph.experiment_repo,
		{
			owner_user_id = "bot-integration-owner",
			key = "bots",
			enabled = true,
			updated_at = platform.clock_now(&graph.clock),
		},
	)
	if !testing.expect_value(t, exp_err.code, domain.Error_Code.None) do return
	auth := contracts.Auth_Context {
		kind    = .Internal_User,
		user_id = "bot-integration-owner",
	}
	if !testing.expect_value(t, bots.bots_create(&graph.bots, auth).code, domain.Error_Code.None) do return
	bot, be := bots.bots_get(&graph.bots, auth.user_id)
	if !testing.expect_value(t, be.code, domain.Error_Code.None) do return
	defer domain.bot_destroy(&bot)
	now := platform.clock_now(&graph.clock)
	_, placement_err := iface.placement_replace(
		&graph.bot_repo,
		bot.bot_id,
		bot.placement_revision,
		[]domain.Bot_Placement_Candidate {
			{position = 0, bridge_id = id, provider = "pi", model = "*", tier = .Preferred},
		},
		now,
	)
	if !testing.expect_value(t, placement_err.code, domain.Error_Code.None) do return
	if !testing.expect(t, sqlite.exec(&graph.db, fmt.tprintf("INSERT INTO channel_bindings(binding_id,owner_user_id,bot_id,provider,external_chat_id,external_user_id,state,created_at) VALUES('chb_integration','bot-integration-owner','%s','telegram','111','222','active','%s');", bot.bot_id, now))) do return
	// Journal transient states without racing the real bridge.
	if !testing.expect(t, sqlite.exec(&graph.db, "CREATE TABLE test_bot_states (state TEXT); CREATE TRIGGER test_attempt_insert AFTER INSERT ON bot_delivery_attempts BEGIN INSERT INTO test_bot_states VALUES(new.state); END; CREATE TRIGGER test_attempt_update AFTER UPDATE OF state ON bot_delivery_attempts WHEN old.state!=new.state BEGIN INSERT INTO test_bot_states VALUES(new.state); END;")) do return
	if !testing.expect(t, sqlite.exec(&graph.db, fmt.tprintf("INSERT INTO channel_messages(message_id,binding_id,owner_user_id,bot_id,direction,provider_update_key,body,created_at) VALUES('chm_integration','chb_integration','bot-integration-owner','%s','inbound','integration:1','hello','%s');", bot.bot_id, now))) do return
	if !testing.expect_value(t, bots.delivery_on_inbound(&graph.bots, bot.bot_id, bots.bots_stamp_ms(now)).code, domain.Error_Code.None) do return
	finished := false
	started = time.tick_now()
	for time.tick_since(started) < 45 * time.Second {
		bots.bots_supervisor_tick(&graph.bots)
		state := scalar(&graph.db, "SELECT state FROM bot_deliveries LIMIT 1")
		sync.mutex_lock(&proxy.mu)
		acked :=
			proxy.terminal_seq > 0 &&
			proxy.ack_seq >= proxy.terminal_seq &&
			proxy.ack_attempt == proxy.terminal_attempt
		sync.mutex_unlock(&proxy.mu)
		if acked && (state == "acted" || state == "abandoned") {finished = true; break}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, finished, "delivery must terminate and receive matching terminal ack")
	testing.expect_value(
		t,
		scalar(&graph.db, "SELECT group_concat(state,',') FROM test_bot_states WHERE state!='relocating'"),
		cat("sent,accepted,", ("acted" if mode == "reply" else "exhausted")),
	)
	testing.expect(
		t,
		scalar(&graph.db, "SELECT read_at FROM channel_messages WHERE message_id='chm_integration'") != "",
		"agent called real channel read",
	)
	if mode == "reply" {
		testing.expect_value(t, scalar(&graph.db, "SELECT state FROM bot_deliveries LIMIT 1"), "acted")
		testing.expect(t, sync.atomic_load(&proxy.r2), "R2 must commit acted before channel send returns")
		testing.expect_value(
			t,
			scalar(&graph.db, "SELECT body FROM channel_messages WHERE direction='outbound'"),
			"echo: hello",
		)
		testing.expect(
			t,
			scalar(&graph.db, "SELECT replied_at FROM channel_messages WHERE message_id='chm_integration'") != "",
			"R2 marks covered inbound replied",
		)
	} else {
		report := scalar(&graph.db, "SELECT report_json FROM bot_delivery_attempts LIMIT 1")
		testing.expect(t, strings.contains(report, "idle_no_reply"), report)
		testing.expect_value(
			t,
			scalar(&graph.db, "SELECT count(*) FROM channel_messages WHERE direction='outbound'"),
			"0",
		)
		testing.expect_value(
			t,
			scalar(&graph.db, "SELECT replied_at FROM channel_messages WHERE message_id='chm_integration'"),
			"",
		)
	}
	sync.mutex_lock(&proxy.mu)
	testing.expect(t, proxy.reads > 0)
	testing.expect_value(t, proxy.sends, int(1 if mode == "reply" else 0))
	before := proxy.terminal_count
	sync.mutex_unlock(&proxy.mu)
	time.sleep(6 * time.Second) // unacked terminal reports resend at 5 seconds
	sync.mutex_lock(&proxy.mu)
	testing.expect_value(t, proxy.terminal_count, before)
	sync.mutex_unlock(&proxy.mu)
}
@(test)
test_bot_delivery_real_hub_bridge_reply :: proc(t: ^testing.T) {integration_case(t, "reply")}
@(test)
test_bot_delivery_real_hub_bridge_idle_no_reply :: proc(t: ^testing.T) {integration_case(t, "silent")}

cat :: proc(parts: ..string) -> string {return strings.concatenate(parts, context.temp_allocator)}

// pty-hosts/providers create separate sessions. Snapshot the actual descendant
// tree before killing the bridge, then kill every owned child with the safe helper.
cleanup_children :: proc(t: ^testing.T, child: os.Process) {
	output, ok := bridge.process_tree_run_ps(context.temp_allocator)
	testing.expect(t, ok, "must enumerate spawned descendants for cleanup")
	raw := bridge.process_tree_parse_ps_output(output, context.temp_allocator)
	owned := make([dynamic]i32, context.temp_allocator)
	append(&owned, i32(child.pid))
	for i := 0; i < len(owned); i += 1 {
		for p in raw {
			if p.ppid != owned[i] do continue
			exists := false
			for pid in owned do if pid == p.pid do exists = true
			if !exists do append(&owned, p.pid)
		}
	}
	bridge.bridge_shell_test_kill_pid(child.pid)
	for i := len(owned) - 1; i > 0; i -= 1 do bridge.bridge_shell_test_kill_pid(int(owned[i]))
	_, wait_err := os.process_wait(child, 5 * time.Second)
	testing.expect(t, wait_err == nil, "bridge child must be reaped")
}
