package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import http "odin_test:lib/http_client"

Bridge_Config :: struct {
	bind_host: string,
	port: u16,
	daemon_url: string,
	daemon_id: string,
	bridge_token: string,
	data_dir: string,
	peers: [dynamic]cfg_lib.Peer_Config,
	peer_auth_token: string,
	chunk_bytes: int,
	bootstrap_cache_max_bytes: int,
	local_endpoint_port: u16,
	local_endpoint_run_dir: string,
	agent_command: string,
	agent_commands: [dynamic]cfg_lib.Agent_Command_Config,
	nudge_enabled: bool,
	nudge_interval_seconds: int,
	nudge_ready_after_seconds: int,
	nudge_review_after_seconds: int,
	nudge_working_stale_after_seconds: int,
	nudge_cooldown_seconds: int,
	nudge_restart_grace_seconds: int,
	fs_root: string,
	fs_read_page_bytes: i64,
	// BR-2: when true the bridge drives agents through ham-pty-host instead of
	// tmux. Default false (tmux path) until DEL-1 flips it. Also overridable at
	// runtime via HEIMDALL_BRIDGE_PTY_HOST for A/B testing.
	pty_host_runtime: bool,
	// CT-4: Code-level audit mode. Rejects agent launches and PTY allocation.
	audit_mode: bool,
}

Bridge_Peer_Link_State :: struct {
	name: string,
	daemon_id: contracts.Daemon_ID,
	endpoint: string,
	status: contracts.Bridge_Reachability_Status,
	active_sessions: int,
	has_socket: bool,
	ws_socket: net.TCP_Socket,
	last_seen_unix_ms: i64,
	last_error: string,
}

bridge_config: Bridge_Config
bridge_peer_states: [dynamic]Bridge_Peer_Link_State
bridge_state_mutex: sync.Mutex
bridge_sequence: i64

main :: proc() {
	when ODIN_OS != .Windows {
		_ = posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
		_ = posix.signal(.SIGINT, auto_cast bridge_signal_handler)
		_ = posix.signal(.SIGTERM, auto_cast bridge_signal_handler)
	}
	if has_flag(os.args, "--version") {
		fmt.println("ham-bridge", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION, "bridge", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION, "ws", contracts.BRIDGE_WS_FRAME_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	if len(os.args) > 1 && os.args[1] == "enroll" {
		if !bridge_enroll_command(os.args) do os.exit(1)
		return
	}
	if has_flag(os.args, "--bridge-wrapper-supervisor") || (len(os.args) > 1 && os.args[1] == "wrapper-supervisor") {
		fmt.eprintln("ham-bridge wrapper-supervisor is removed; use ham-wrapper bridge-runtime")
		os.exit(1)
	}

	bridge_config = bridge_config_from_args(os.args)
	bridge_fs_init(bridge_config.fs_root, bridge_config.fs_read_page_bytes)
	bridge_provider_store_init()
	bootstrap_cache_init(&bootstrap_global_cache, bridge_config.data_dir, bridge_config.bootstrap_cache_max_bytes)
	if has_flag(os.args, "--bootstrap-fetch") {
		instance_id := option_value(os.args, "--instance-id", "")
		run_dir := option_value(os.args, "--run-dir", "")
		bridge_endpoint := option_value(os.args, "--bridge-endpoint", os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator))
		agent_token := option_value(os.args, "--agent-token", os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator))
		provider := option_value(os.args, "--provider", "")
		if !bridge_bootstrap_fetch_manifest_and_materialize(bridge_config.daemon_url, bridge_config.bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider, &bootstrap_global_cache) {
			if !bridge_bootstrap_fetch_and_materialize(bridge_config.daemon_url, bridge_config.bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider) {
				fmt.eprintln("bootstrap fetch/materialization failed")
				os.exit(1)
			}
		}
		fmt.println("bootstrap materialized", run_dir)
		return
	}
	bridge_runtime_init()
	bridge_agent_token_store_init()
	// Start the local endpoint at bridge boot, not lazily on launch. Wrappers may
	// outlive and reconnect after a bridge restart, so recovery requires the local
	// JSONL socket before any new launch command arrives.
	if endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint(); endpoint_ok {
		local_config := bridge_local_endpoint_config_default(bridge_config.local_endpoint_run_dir, bridge_config.local_endpoint_port)
		fmt.println("bridge local endpoint", endpoint, "fallback", bridge_local_endpoint_env_value(local_config, false), "socket_mode", "0600")
	}
	bridge_hub_runtime_start()
	bridge_task_scheduler_configure()
	bridge_task_scheduler_start()
	bridge_action_scheduler_start()
	// CT-5: Monitor 20-hour Cloudtop LOAS/gcert credentials and re-arm on renewal
	bridge_gcert_monitor_start()
	if bridge_config.chunk_bytes <= 0 do bridge_config.chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES
	bridge_peer_state_init(bridge_config.peers[:])
	_ = run_bridge_server(bridge_config)
}

when ODIN_OS != .Windows {
	bridge_signal_handler :: proc "c" (sig: posix.Signal) {
		// Clean up processes on SIGTERM/SIGINT before cgroup reaping
		os.exit(0)
	}
}

print_usage :: proc() {
	fmt.println("ham-bridge", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-bridge [--config <path>] [--bind-host 127.0.0.1] [--port 49323] [--daemon-url URL|--hub URL] [--daemon-id ID] [--bridge-token TOKEN|--bridge-token-file PATH] [--local-endpoint-port PORT] [--local-run-dir DIR] [--agent-command CMD]")
	fmt.println("bridge runtime: ham-wrapper bridge-runtime --bridge-endpoint unix:/run/heimdall/bridge.sock --agent-token hlat_... --agent-instance-id inst_... --provider pi --tier normal --run-dir <dir> -- <agent-command>")
	fmt.println("enroll: ham-bridge enroll [--hub http://127.0.0.1:49322] [--enrollment-token TOKEN] [--bridge-token-file PATH]")
	fmt.println("TLS: https:// Hub URLs use HTTPS and wss:// with certificate/hostname validation; http:// tunnel URLs use ws://.")
	fmt.println("bootstrap fetch: ham-bridge --bootstrap-fetch --daemon-url URL --bridge-token TOKEN|--bridge-token-file PATH --instance-id INST --run-dir DIR")
	fmt.println("bridge runtime: ham-wrapper bridge-runtime --bridge-endpoint unix:/run/bridge.sock --agent-token hlat_... --agent-instance-id INST --run-dir DIR -- <agent-command>")
	fmt.println("loopback routes:", contracts.ROUTE_BRIDGE_HEALTH, contracts.ROUTE_BRIDGE_SEND, contracts.ROUTE_BRIDGE_REQUEST, contracts.ROUTE_BRIDGE_VALIDATE_PROJECT_PATH, contracts.ROUTE_BRIDGE_REACHABLE)
}

bridge_is_loopback_url :: proc(url_str: string) -> bool {
	trimmed := strings.trim_space(url_str)
	return strings.contains(trimmed, "127.0.0.1") || strings.contains(trimmed, "localhost") || strings.contains(trimmed, "[::1]")
}

bridge_auto_pair_loopback :: proc(args: []string, hub_url: string) -> bool {
	endpoint := strings.trim_right(strings.trim_space(hub_url), "/")
	hostname := option_value(args, "--name", option_value(args, "--hostname", os.get_env("HOSTNAME", context.allocator)))
	if hostname == "" do hostname = "cloudtop"
	fmt.printfln("bridge enroll: attempting local loopback auto-pairing with hub at %s (hostname=%s)", endpoint, hostname)
	body := fmt.tprintf("{\"hostname\":\"%s\",\"label\":\"%s\"}", hostname, hostname)
	resp, ok := http.request_with_headers_timeout("POST", endpoint, "/api/v1/bridges/auto-pair", body, nil, http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 {
		fmt.eprintfln("bridge enroll: local loopback auto-pair failed (HTTP %d); fall back to --enrollment-token", resp.status if ok else 0)
		return false
	}
	bridge_token := extract_json_string(resp.body, "bridge_token", "")
	bridge_id := extract_json_string(resp.body, "bridge_id", "brg_local")
	persisted_hub_url := extract_json_string(resp.body, "hub_url", endpoint)

	token_file := option_value(args, "--bridge-token-file", os.get_env("HAM_BRIDGE_TOKEN_FILE", context.allocator))
	if strings.trim_space(token_file) == "" {
		token_file = cfg_lib.expand_home("~/.local/share/heimdall/bridge_token")
	}
	if bridge_token == "" {
		if tok, ok := bridge_read_token_file(token_file); ok {
			bridge_token = tok
		} else {
			fmt.eprintln("bridge enroll: auto-pair response did not contain a bridge token and local token file is empty")
			return false
		}
	}
	config_path := cfg_lib.config_path_from_args(args)
	if strings.trim_space(token_file) != "" {
		if !bridge_write_token_file(token_file, bridge_token) do return false
		if !bridge_write_enrolled_config(config_path, persisted_hub_url, "", bridge_id) {
			fmt.eprintln("warning: bridge token was saved, but config.toml could not be updated; pass --hub/--bridge-token-file when starting ham-bridge")
		}
		fmt.println("bridge_token_file", token_file)
	} else {
		if !bridge_write_enrolled_config(config_path, persisted_hub_url, bridge_token, bridge_id) do return false
	}
	fmt.printfln("bridge enroll SUCCESS: loopback auto-paired as bridge_id=%s hub_url=%s", bridge_id, persisted_hub_url)
	fmt.println("  next: start the bridge (ham-bridge --hub <url> ...); it will open the runtime WS and should log 'bridge hub runtime ready'.")
	return true
}

bridge_enroll_command :: proc(args: []string) -> bool {
	hub_url := option_value(args, "--hub", option_value(args, "--daemon-url", "http://127.0.0.1:49322"))
	token := option_value(args, "--enrollment-token", os.get_env("HAM_BRIDGE_ENROLLMENT_TOKEN", context.allocator))

	// CT-2: Auto-pairing on loopback if enrollment token is omitted.
	if strings.trim_space(token) == "" {
		if bridge_is_loopback_url(hub_url) {
			return bridge_auto_pair_loopback(args, hub_url)
		}
		fmt.eprintln("ham-bridge enroll requires --hub and --enrollment-token (or HAM_BRIDGE_ENROLLMENT_TOKEN) for non-loopback Hubs")
		return false
	}
	if !bridge_hub_url_supported(hub_url) {
		fmt.eprintln("ham-bridge enroll --hub must be an http:// or https:// base URL")
		return false
	}
	hostname := option_value(args, "--name", option_value(args, "--hostname", os.get_env("HOSTNAME", context.allocator)))
	if hostname == "" do hostname = "ham-bridge"
	body_b := strings.builder_make()
	strings.write_string(&body_b, "{\"hub_url\":\""); json_write_string(&body_b, hub_url)
	strings.write_string(&body_b, "\",\"hostname\":\""); json_write_string(&body_b, hostname)
	strings.write_string(&body_b, "\",\"label\":\""); json_write_string(&body_b, hostname)
	strings.write_string(&body_b, "\",\"machine\":{\"hostname\":\""); json_write_string(&body_b, hostname); strings.write_string(&body_b, "\"}}")
	body := strings.to_string(body_b)
	// Log a token PREVIEW only (never the full secret) so we can tell it was passed.
	token_preview := token[:min(8, len(token))]
	fmt.printfln("bridge enroll: POST %s/api/v1/bridges/enroll (enrollment_token=%s..., len=%d)", hub_url, token_preview, len(token))
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	resp, ok := http.request_with_headers_timeout("POST", hub_url, "/api/v1/bridges/enroll", body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok {
		// Transport failure: could not reach the hub at all (proxy/tunnel down,
		// DNS, connection refused, TLS handshake failed, timeout).
		fmt.eprintfln("bridge enroll FAILED: could not reach the hub at %s — check the proxy/tunnel is up and --hub is correct (transport error, no HTTP response)", hub_url)
		return false
	}
	if resp.status != 201 {
		// The hub answered but rejected enrollment (bad/expired token, wrong Host
		// via a misconfigured proxy, etc.). resp.body carries the hub's reason.
		fmt.eprintfln("bridge enroll FAILED: hub returned HTTP %d — %s", resp.status, resp.body)
		if resp.status == 401 || resp.status == 403 do fmt.eprintln("  hint: the enrollment token is invalid, already used, or expired — create a fresh one in the UI (Settings -> Bridges -> Add bridge).")
		if resp.status == 404 do fmt.eprintln("  hint: the enrollment token was not found (invalid/expired — create a fresh one), OR the proxy isn't rewriting Host to the hub / --hub points at the wrong base URL.")
		return false
	}
	fmt.printfln("bridge enroll: hub accepted (HTTP 201)")
	bridge_token := extract_json_string(resp.body, "bridge_token", "")
	bridge_id := extract_json_string(resp.body, "bridge_id", "")
	persisted_hub_url := extract_json_string(resp.body, "hub_url", hub_url)
	token_file := option_value(args, "--bridge-token-file", os.get_env("HAM_BRIDGE_TOKEN_FILE", context.allocator))
	config_path := cfg_lib.config_path_from_args(args)
	if strings.trim_space(token_file) != "" {
		if !bridge_write_token_file(token_file, bridge_token) do return false
		if !bridge_write_enrolled_config(config_path, persisted_hub_url, "", bridge_id) {
			fmt.eprintln("warning: bridge token was saved, but config.toml could not be updated; pass --hub/--bridge-token-file when starting ham-bridge")
		}
		fmt.println("bridge_token_file", token_file)
	} else {
		if !bridge_write_enrolled_config(config_path, persisted_hub_url, bridge_token, bridge_id) do return false
	}
	fmt.printfln("bridge enroll SUCCESS: enrolled as bridge_id=%s hub_url=%s", bridge_id, persisted_hub_url)
	fmt.println("  next: start the bridge (ham-bridge --hub <url> --bridge-token-file <path> ...); it will open the runtime WS and should log 'bridge hub runtime ready'.")
	return true
}

bridge_hub_url_supported :: proc(hub_url: string) -> bool {
	trimmed := strings.trim_right(strings.trim_space(hub_url), "/")
	authority := ""
	if strings.has_prefix(trimmed, "http://") {
		authority = trimmed[len("http://"):]
	} else if strings.has_prefix(trimmed, "https://") {
		authority = trimmed[len("https://"):]
	} else {
		return false
	}
	if strings.trim_space(authority) == "" do return false
	if strings.contains(authority, "/") || strings.contains(authority, "?") || strings.contains(authority, "#") do return false
	return true
}

bridge_write_enrolled_config :: proc(path, hub_url, bridge_token, bridge_id: string) -> bool {
	if strings.trim_space(path) == "" || strings.trim_space(hub_url) == "" do return false
	if slash := strings.last_index_byte(path, '/'); slash > 0 { _ = os.make_directory_all(path[:slash]) }
	b := strings.builder_make()
	strings.write_string(&b, "[wrapper]\ndaemon_url = \""); json_write_string(&b, hub_url)
	strings.write_string(&b, "\"\n\n[daemon]\n")
	if strings.trim_space(bridge_token) != "" {
		strings.write_string(&b, "bridge_token = \""); json_write_string(&b, bridge_token)
		strings.write_string(&b, "\"\n")
	}
	strings.write_string(&b, "daemon_id = \""); json_write_string(&b, bridge_id)
	strings.write_string(&b, "\"\n")
	return os.write_entire_file(path, strings.to_string(b)) == nil
}

bridge_write_token_file :: proc(path, token: string) -> bool {
	if strings.trim_space(path) == "" || strings.trim_space(token) == "" do return false
	if slash := strings.last_index_byte(path, '/'); slash > 0 { _ = os.make_directory_all(path[:slash]) }
	content := strings.concatenate({strings.trim_space(token), "\n"})
	defer delete(content)
	err := os.write_entire_file(path, content, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		fmt.eprintln("failed to write bridge token file", path)
		return false
	}
	_ = os.chmod(path, os.Permissions{.Read_User, .Write_User})
	return true
}

bridge_read_token_file :: proc(path: string) -> (string, bool) {
	trimmed_path := strings.trim_space(path)
	if trimmed_path == "" do return "", false
	data, err := os.read_entire_file(trimmed_path, context.allocator)
	if err != nil {
		fmt.eprintln("failed to read bridge token file", trimmed_path)
		return "", false
	}
	text := strings.trim_space(string(data))
	if text == "" do return "", false
	return strings.clone(text), true
}

bridge_config_from_args :: proc(args: []string) -> Bridge_Config {
	cfg := Bridge_Config{
		bind_host = "127.0.0.1",
		port = 49323,
		fs_read_page_bytes = BRIDGE_FS_READ_PAGE_BYTES,
		daemon_url = "http://127.0.0.1:49322",
		daemon_id = "brg_local",
		bridge_token = "",
		data_dir = "~/.local/share/heimdall",
		peers = make([dynamic]cfg_lib.Peer_Config),
		peer_auth_token = "",
		chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES,
		bootstrap_cache_max_bytes = 256 * 1024 * 1024,
		local_endpoint_port = 0,
		local_endpoint_run_dir = "/tmp/heimdall-bridge-local",
		agent_command = "sleep 3600",
		agent_commands = make([dynamic]cfg_lib.Agent_Command_Config),
	}

	config_path := cfg_lib.config_path_from_args(args)
	if loaded, ok := cfg_lib.load(config_path); ok {
		cfg.daemon_url = loaded.config.wrapper.daemon_url
		cfg.daemon_id = loaded.config.daemon.daemon_id
		cfg.bridge_token = loaded.config.daemon.bridge_token
		cfg.data_dir = loaded.config.daemon.data_dir
		// Nudge/scheduler knobs are bridge-owned: prefer the [bridge] section.
		// Fall back to the legacy [daemon].nudge_* keys (from the ham-daemon era)
		// with a deprecation warning so existing configs keep working.
		if loaded.config.bridge.nudge_configured {
			cfg.nudge_enabled = loaded.config.bridge.nudge_enabled
			cfg.nudge_interval_seconds = loaded.config.bridge.nudge_interval_seconds
			cfg.nudge_ready_after_seconds = loaded.config.bridge.nudge_ready_after_seconds
			cfg.nudge_review_after_seconds = loaded.config.bridge.nudge_review_after_seconds
			cfg.nudge_working_stale_after_seconds = loaded.config.bridge.nudge_working_stale_after_seconds
			cfg.nudge_cooldown_seconds = loaded.config.bridge.nudge_cooldown_seconds
			cfg.nudge_restart_grace_seconds = loaded.config.bridge.nudge_restart_grace_seconds
		} else {
			if loaded.config.daemon.nudge_enabled || loaded.config.daemon.nudge_interval_seconds != 0 {
				fmt.println("WARN deprecated config: [daemon].nudge_* is bridge-owned; move these keys to a [bridge] section")
			}
			cfg.nudge_enabled = loaded.config.daemon.nudge_enabled
			cfg.nudge_interval_seconds = loaded.config.daemon.nudge_interval_seconds
			cfg.nudge_ready_after_seconds = loaded.config.daemon.nudge_ready_after_seconds
			cfg.nudge_review_after_seconds = loaded.config.daemon.nudge_review_after_seconds
			cfg.nudge_working_stale_after_seconds = loaded.config.daemon.nudge_working_stale_after_seconds
			cfg.nudge_cooldown_seconds = loaded.config.daemon.nudge_cooldown_seconds
			cfg.nudge_restart_grace_seconds = loaded.config.daemon.nudge_restart_grace_seconds
		}
		cfg.fs_root = loaded.config.bridge.fs_root
		if loaded.config.bridge.fs_read_page_bytes > 0 {
			cfg.fs_read_page_bytes = i64(loaded.config.bridge.fs_read_page_bytes)
		}
		cfg.pty_host_runtime = loaded.config.bridge.pty_host_runtime
		if len(loaded.config.wrapper.command) > 0 do cfg.agent_command = strings.join(loaded.config.wrapper.command, " ")
		for agent_cmd in loaded.config.wrapper.agent_commands do append(&cfg.agent_commands, agent_cmd)
		for peer in loaded.config.bridge.peers {
			if strings.trim_space(peer.name) == "" || strings.trim_space(peer.endpoint) == "" || strings.trim_space(peer.token) == "" do continue
			append(&cfg.peers, cfg_lib.Peer_Config{name = strings.clone(peer.name), endpoint = strings.clone(peer.endpoint), token = strings.clone(peer.token)})
		}
	}

	cfg.bind_host = option_value(args, "--bind-host", cfg.bind_host)
	cfg.daemon_url = option_value(args, "--daemon-url", cfg.daemon_url)
	cfg.daemon_url = option_value(args, "--hub", cfg.daemon_url)
	cfg.daemon_id = option_value(args, "--daemon-id", cfg.daemon_id)
	bridge_token_file := option_value(args, "--bridge-token-file", os.get_env("HAM_BRIDGE_TOKEN_FILE", context.allocator))
	if token_from_file, token_file_ok := bridge_read_token_file(bridge_token_file); token_file_ok do cfg.bridge_token = token_from_file
	cfg.bridge_token = option_value(args, "--bridge-token", cfg.bridge_token)
	cfg.peer_auth_token = option_value(args, "--peer-auth-token", cfg.peer_auth_token)
	if port_s := option_value(args, "--port", ""); port_s != "" {
		if port_i, ok := strconv.parse_int(port_s); ok do cfg.port = u16(port_i)
	}
	if chunk_s := option_value(args, "--chunk-bytes", ""); chunk_s != "" {
		if chunk_i, ok := strconv.parse_int(chunk_s); ok do cfg.chunk_bytes = int(chunk_i)
	}
	if fs_page_s := option_value(args, "--fs-read-page-bytes", ""); fs_page_s != "" {
		if fs_page_i, ok := strconv.parse_int(fs_page_s); ok && fs_page_i > 0 do cfg.fs_read_page_bytes = i64(fs_page_i)
	}
	if cache_bytes_s := option_value(args, "--bootstrap-cache-max-bytes", ""); cache_bytes_s != "" {
		if cache_bytes_i, ok := strconv.parse_int(cache_bytes_s); ok do cfg.bootstrap_cache_max_bytes = int(cache_bytes_i)
	}
	if local_port_s := option_value(args, "--local-endpoint-port", ""); local_port_s != "" {
		if local_port_i, ok := strconv.parse_int(local_port_s); ok do cfg.local_endpoint_port = u16(local_port_i)
	}
	cfg.local_endpoint_run_dir = option_value(args, "--local-run-dir", cfg.local_endpoint_run_dir)
	cfg.agent_command = option_value(args, "--agent-command", cfg.agent_command)
	for i in 0..<len(args) {
		if args[i] == "--peer-ws" && i + 1 < len(args) {
			append(&cfg.peers, cfg_lib.Peer_Config{name = fmt.tprintf("cli-peer-%d", len(cfg.peers) + 1), endpoint = strings.clone(args[i + 1]), token = strings.clone(cfg.peer_auth_token)})
		}
	}
	cfg.data_dir = option_value(args, "--data-dir", cfg.data_dir)
	// Expand a leading ~ in data_dir. The default (and typical config value) is
	// "~/.local/share/heimdall", but nothing expanded it before, so a bridge whose
	// cwd is not $HOME (e.g. launchd starts it with cwd=/) resolved the bootstrap
	// blob cache to a LITERAL "~/.local/share/heimdall" directory. That made every
	// cache lookup miss and every cache_put fail its file write, so bootstrap blob
	// resolution failed with "blob hash verify/cache failed" and NO agent could
	// launch. Expand here so the cache always lands under the real home dir
	// regardless of the process working directory.
	cfg.data_dir = cfg_lib.expand_home(cfg.data_dir)

	// CT-2: Loopback auto-pairing default: load runtime token from token file.
	if strings.trim_space(cfg.bridge_token) == "" && bridge_is_loopback_url(cfg.daemon_url) {
		token_file := option_value(args, "--bridge-token-file", os.get_env("HAM_BRIDGE_TOKEN_FILE", context.allocator))
		if strings.trim_space(token_file) == "" {
			token_file = cfg_lib.expand_home("~/.local/share/heimdall/bridge_token")
		}
		if token_from_file, ok := bridge_read_token_file(token_file); ok {
			cfg.bridge_token = token_from_file
			cfg.daemon_id = "brg_local"
		}
	}

	// CT-4: Code-level audit mode flag / env check
	if has_flag(args, "--audit-mode") || os.get_env("HEIMDALL_AUDIT_MODE", context.allocator) == "1" || os.get_env("HEIMDALL_AUDIT_MODE", context.allocator) == "true" {
		cfg.audit_mode = true
	}

	return cfg
}

bridge_runtime_init :: proc() {
	bridge_state_mutex = sync.Mutex{}
	bridge_sequence = 0
}

bridge_next_id :: proc(prefix: string) -> string {
	bridge_sequence += 1
	return fmt.tprintf("%s_%d_%d", prefix, bridge_now_unix_ms(), bridge_sequence)
}

bridge_peer_state_init :: proc(peers: []cfg_lib.Peer_Config) {
	bridge_peer_states = make([dynamic]Bridge_Peer_Link_State)
	for peer in peers {
		name := strings.trim_space(peer.name)
		if name == "" do name = fmt.tprintf("peer-%d", len(bridge_peer_states) + 1)
		append(&bridge_peer_states, Bridge_Peer_Link_State{
			name = strings.clone(name),
			daemon_id = contracts.Daemon_ID(strings.clone(name)),
			endpoint = strings.clone(peer.endpoint),
			status = .Unreachable,
			last_seen_unix_ms = 0,
			last_error = "",
		})
	}
}

bridge_peer_state_set :: proc(name: string, status: contracts.Bridge_Reachability_Status, err: string) {
	for i in 0..<len(bridge_peer_states) {
		if bridge_peer_states[i].name != name do continue
		bridge_peer_states[i].status = status
		if status == .Linked do bridge_peer_states[i].last_seen_unix_ms = bridge_now_unix_ms()
		bridge_peer_states[i].last_error = strings.clone(err)
		return
	}
}

bridge_should_dial_peer :: proc(peer_name: string) -> bool {
	self_daemon_id := strings.trim_space(bridge_config.daemon_id)
	peer_daemon_id := strings.trim_space(peer_name)
	if self_daemon_id == "" || peer_daemon_id == "" do return false
	if self_daemon_id == peer_daemon_id do return false
	if strings.has_prefix(peer_daemon_id, "cli-peer-") do return true
	return strings.compare(self_daemon_id, peer_daemon_id) < 0
}

run_bridge_server :: proc(cfg: Bridge_Config) -> bool {
	address := net.IP4_Loopback
	if cfg.bind_host != "127.0.0.1" {
		if parsed, ok := net.parse_ip4_address(cfg.bind_host); ok do address = parsed
	}
	listener, err := net.listen_tcp({address, int(cfg.port)})
	if err != nil {
		fmt.println("failed to listen", cfg.bind_host, cfg.port, "error:", err)
		return false
	}
	defer net.close(listener)
	fmt.println("ham-bridge listening", cfg.bind_host, cfg.port, "daemon_url", cfg.daemon_url)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		thread.run_with_poly_data(client, handle_bridge_client)
	}
}

handle_bridge_client :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	request, ok := read_http_request(client)
	if !ok do return
	method, route := request_method_route(request)
	if method == "OPTIONS" {
		write_response(client, 200, "OK", `{}`)
		return
	}
	if !contracts.bridge_route_supported(.Bridge, method, route) {
		write_response(client, 404, "Not Found", bridge_unsupported_route_json(method, route))
		return
	}
	if !bridge_loopback_authorized(request) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"bridge loopback unauthorized"}`)
		return
	}
	switch route {
	case contracts.ROUTE_BRIDGE_HEALTH:
		write_response(client, 200, "OK", bridge_health_json())
	case contracts.ROUTE_BRIDGE_SEND:
		bridge_handle_send(client, request_body(request))
	case contracts.ROUTE_BRIDGE_REQUEST:
		bridge_handle_request(client, request_body(request))
	case contracts.ROUTE_BRIDGE_VALIDATE_PROJECT_PATH:
		bridge_handle_validate_project_path(client, request_body(request))
	case contracts.ROUTE_BRIDGE_REACHABLE:
		write_response(client, 200, "OK", bridge_reachable_json())
	case:
		write_response(client, 404, "Not Found", bridge_unsupported_route_json(method, route))
	}
}

bridge_loopback_authorized :: proc(request: string) -> bool {
	if strings.trim_space(bridge_config.bridge_token) == "" do return true
	auth := extract_header(request, contracts.BRIDGE_LOOPBACK_AUTH_HEADER)
	return auth == strings.concatenate({contracts.BRIDGE_AUTH_BEARER_PREFIX, bridge_config.bridge_token})
}



bridge_health_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"ws_frame_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"self_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","bridge_id":"ham-bridge","chunk_bytes":`)
	strings.write_string(&b, fmt.tprintf("%d", bridge_config.chunk_bytes))
	strings.write_string(&b, `,"large_payload_target_bytes":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_LARGE_PAYLOAD_TARGET_BYTES))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_send_stub_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Rejected))
	strings.write_string(&b, `","error_code":"`); json_write_string(&b, contracts.BRIDGE_ERROR_NOT_IMPLEMENTED)
	strings.write_string(&b, `","message":"bridge send transport scaffold only; async transit queue arrives in a later task"}`)
	return strings.to_string(b)
}

bridge_request_stub_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"result_kind":"`); json_write_string(&b, contracts.BRIDGE_RESULT_UNSUPPORTED_SCAFFOLD)
	strings.write_string(&b, `","status_code":501,"status_text":"Not Implemented","error_code":"`); json_write_string(&b, contracts.BRIDGE_ERROR_NOT_IMPLEMENTED)
	strings.write_string(&b, `","message":"bridge request transport scaffold only"}`)
	return strings.to_string(b)
}

bridge_peer_name_for_daemon :: proc(dest_daemon_id: string) -> string {
	trimmed := strings.trim_space(dest_daemon_id)
	for state in bridge_peer_states {
		if string(state.daemon_id) == trimmed || state.name == trimmed do return state.name
	}
	return trimmed
}

bridge_send_accepted_json :: proc(idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Accepted_Queued))
	strings.write_string(&b, `","bridge_message_id":"`); json_write_string(&b, bridge_next_id("bridge_msg"))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","message":"accepted by bridge transport"}`)
	return strings.to_string(b)
}

bridge_send_backpressure_json :: proc(idempotency_key, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Backpressure))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","error_code":"backpressure","message":"`); json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_send_unreachable_json :: proc(idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Destination_Unreachable))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","error_code":"unreachable","message":"peer websocket unavailable"}`)
	return strings.to_string(b)
}

bridge_request_transport_error_json :: proc(status_code: int, status_text, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"result_kind":"`); json_write_string(&b, contracts.BRIDGE_RESULT_TRANSPORT_ERROR)
	strings.write_string(&b, `","status_code":`); strings.write_string(&b, fmt.tprintf("%d", status_code))
	strings.write_string(&b, `,"status_text":"`); json_write_string(&b, status_text)
	strings.write_string(&b, `","error_code":"transport_error","message":"`); json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_request_response_json :: proc(status_code: int, status_text, body: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"result_kind":"`); json_write_string(&b, contracts.BRIDGE_RESULT_DESTINATION_DAEMON_HTTP_RESPONSE)
	strings.write_string(&b, `","status_code":`); strings.write_string(&b, fmt.tprintf("%d", status_code))
	strings.write_string(&b, `,"status_text":"`); json_write_string(&b, status_text)
	strings.write_string(&b, `","body":"`); json_write_string(&b, body)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_handle_send :: proc(client: net.TCP_Socket, body: string) {
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	write_response(client, 503, "Service Unavailable", bridge_send_unreachable_json(idempotency_key))
}

bridge_validate_project_path_ws_result_json :: proc(body: string) -> string {
	return bridge_project_path_validation_result_json(body)
}

bridge_handle_validate_project_path :: proc(client: net.TCP_Socket, body: string) {
	write_response(client, 200, "OK", bridge_project_path_validation_result_json(body))
}

bridge_project_path_validation_result_json :: proc(body: string) -> string {
	command_id := extract_json_string(body, "command_id", "")
	if cached, cached_ok := bridge_validation_command_cached(command_id); cached_ok do return cached
	project_id := extract_json_string(body, "project_id", "")
	path := extract_json_string(body, "path", "")
	vcs_kind := extract_json_string(body, "vcs_kind", "")
	repo_url := extract_json_string(body, "repo_url", "")
	result := bridge_validate_project_path_local(path, vcs_kind, repo_url)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"project_path_validation_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"project_id\":\""); json_write_string(&b, project_id)
	strings.write_string(&b, "\",\"path\":\""); json_write_string(&b, path)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if result.ok else "false")
	strings.write_string(&b, ",\"validation_error\":\""); json_write_string(&b, result.message)
	strings.write_string(&b, "\",\"error\":{\"code\":\""); json_write_string(&b, result.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, result.message)
	strings.write_string(&b, "\"}}")
	result_json := strings.to_string(b)
	bridge_validation_command_store(command_id, result_json)
	return result_json
}

bridge_handle_request :: proc(client: net.TCP_Socket, body: string) {
	write_response(client, 503, "Service Unavailable", bridge_request_transport_error_json(503, "Service Unavailable", "peer websocket unavailable"))
}

bridge_reachable_json :: proc() -> string {
	return bridge_reachable_json_with_change(false)
}

bridge_reachability_update_json :: proc() -> string {
	return bridge_reachable_json_with_change(true)
}

bridge_peer_state_refresh_last_seen_for_linked_locked :: proc() {
	now := bridge_now_unix_ms()
	for i in 0..<len(bridge_peer_states) {
		if bridge_peer_states[i].status != .Linked do continue
		if bridge_peer_states[i].last_seen_unix_ms >= now do now = bridge_peer_states[i].last_seen_unix_ms + 1
		bridge_peer_states[i].last_seen_unix_ms = now
	}
}

bridge_reachable_json_with_change :: proc(include_changed: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"self_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","reachable":[`)
	sync.mutex_lock(&bridge_state_mutex)
	bridge_peer_state_refresh_last_seen_for_linked_locked()
	for i in 0..<len(bridge_peer_states) {
		state := bridge_peer_states[i]
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"daemon_id":"`); json_write_string(&b, string(state.daemon_id))
		strings.write_string(&b, `","reach":"direct","next_hop_daemon_id":"`); json_write_string(&b, string(state.daemon_id))
		strings.write_string(&b, `","hops":1,"status":"`); json_write_string(&b, bridge_reachability_status_wire(state.status))
		strings.write_string(&b, `","via":[],"last_seen_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", state.last_seen_unix_ms))
		strings.write_string(&b, `}`)
	}
	sync.mutex_unlock(&bridge_state_mutex)
	strings.write_string(&b, `]`)
	if include_changed {
		strings.write_string(&b, `,"changed_unix_ms":`)
		strings.write_string(&b, fmt.tprintf("%d", bridge_now_unix_ms()))
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_reachability_push_to_daemon :: proc() {
	if strings.trim_space(bridge_config.daemon_url) == "" do return
	headers := [?]http.Header{{name = "X-Heimdall-Daemon-ID", value = bridge_config.daemon_id}}
	_, _ = http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_POST, bridge_config.daemon_url, contracts.ROUTE_FEDERATION_REACHABILITY, bridge_reachability_update_json(), headers[:], contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS)
}

bridge_reachability_status_wire :: proc(status: contracts.Bridge_Reachability_Status) -> string {
	switch status {
	case .Linked:
		return contracts.BRIDGE_REACHABILITY_STATUS_LINKED
	case .Unreachable:
		return contracts.BRIDGE_REACHABILITY_STATUS_UNREACHABLE
	}
	return contracts.BRIDGE_REACHABILITY_STATUS_UNREACHABLE
}

bridge_unsupported_route_json :: proc(method, route: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"error_code":"`)
	json_write_string(&b, contracts.BRIDGE_ERROR_UNSUPPORTED_ROUTE)
	strings.write_string(&b, `","message":"unsupported bridge route","method":"`)
	json_write_string(&b, method)
	strings.write_string(&b, `","route":"`)
	json_write_string(&b, route)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [4096]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return "", false
	request := strings.clone(string(buf[:n]))
	for !http_request_complete(request) {
		m, err := net.recv_tcp(client, buf[:])
		if err != nil || m <= 0 do break
		request = strings.concatenate({request, string(buf[:m])})
	}
	return request, true
}

http_request_complete :: proc(request: string) -> bool {
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return false
	content_length := request_content_length(request)
	if content_length <= 0 do return true
	body_len := len(request) - (head_end + 4)
	return body_len >= content_length
}

request_body :: proc(request: string) -> string {
	if idx := strings.index(request, "\r\n\r\n"); idx >= 0 do return request[idx + 4:]
	return ""
}

request_content_length :: proc(request: string) -> int {
	value := extract_header(request, "Content-Length")
	if value == "" do value = extract_header(request, "content-length")
	if value == "" do return 0
	if parsed, ok := strconv.parse_int(value); ok do return int(parsed)
	return 0
}

extract_header :: proc(request, name: string) -> string {
	pattern := fmt.tprintf("%s:", name)
	idx := strings.index(request, pattern)
	if idx < 0 do return ""
	start := idx + len(pattern)
	end := strings.index(request[start:], "\r\n")
	if end < 0 do return ""
	return strings.trim_space(request[start:start + end])
}

bridge_tcp_send_all :: proc(client: net.TCP_Socket, data: []byte) -> bool {
	sent_total := 0
	for sent_total < len(data) {
		sent, err := net.send_tcp(client, data[sent_total:])
		if err != nil || sent <= 0 do return false
		sent_total += sent
	}
	return true
}

write_response :: proc(client: net.TCP_Socket, status: int, status_text, body: string) {
	builder := strings.builder_make()
	strings.write_string(&builder, fmt.tprintf("HTTP/1.1 %d %s\r\n", status, status_text))
	strings.write_string(&builder, "Content-Type: application/json\r\n")
	strings.write_string(&builder, fmt.tprintf("Content-Length: %d\r\n", len(body)))
	strings.write_string(&builder, "Access-Control-Allow-Origin: *\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Headers: Content-Type, Authorization\r\n")
	strings.write_string(&builder, "Connection: close\r\n\r\n")
	header_bytes := transmute([]byte)strings.to_string(builder)
	if !bridge_tcp_send_all(client, header_bytes) do return
	if len(body) > 0 do _ = bridge_tcp_send_all(client, transmute([]byte)body)
}




json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	escaped := false
	for end < len(body) {
		ch := body[end]
		if escaped {
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return json_unescape(body[start:end])
		}
		end += 1
	}
	return fallback
}

json_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	i := 0
	for i < len(value) {
		ch := value[i]
		if ch == '\\' {
			if i + 1 < len(value) {
				next_ch := value[i + 1]
				switch next_ch {
				case 'n': strings.write_byte(&builder, '\n')
				case 'r': strings.write_byte(&builder, '\r')
				case 't': strings.write_byte(&builder, '\t')
				case '"': strings.write_byte(&builder, '"')
				case '\\': strings.write_byte(&builder, '\\')
				case 'u':
					if i + 5 < len(value) {
						hex_str := value[i + 2 : i + 6]
						val, ok := strconv.parse_int(hex_str, 16)
						if ok {
							strings.write_rune(&builder, rune(val))
							i += 6
							continue
						}
					}
					strings.write_byte(&builder, 'u')
				case:
					strings.write_byte(&builder, next_ch)
				}
				i += 2
			} else {
				strings.write_byte(&builder, '\\')
				i += 1
			}
		} else {
			strings.write_byte(&builder, ch)
			i += 1
		}
	}
	return strings.to_string(builder)
}

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	for start < len(body) && (body[start] == ' ' || body[start] == '\n' || body[start] == '\r' || body[start] == '\t') do start += 1
	end := start
	for end < len(body) && ((body[end] >= '0' && body[end] <= '9') || body[end] == '-') do end += 1
	if end <= start do return fallback
	if parsed, ok := strconv.parse_int(body[start:end]); ok do return int(parsed)
	return fallback
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i in 0..<len(args) {
		if args[i] == name && i + 1 < len(args) do return args[i + 1]
	}
	return fallback
}

request_method_route :: proc(request: string) -> (method: string, route: string) {
	first_space := strings.index_byte(request, ' ')
	if first_space < 0 do return "", ""
	method = request[:first_space]
	path_start := first_space + 1
	path_end_rel := strings.index_byte(request[path_start:], ' ')
	if path_end_rel < 0 do return method, ""
	path := request[path_start:path_start + path_end_rel]
	if q := strings.index_byte(path, '?'); q >= 0 do path = path[:q]
	return method, path
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

bridge_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
