package config

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

CONFIG_PATH_FLAG :: "--config"

default_config_path :: proc() -> string {
	heimdall_home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if heimdall_home != "" {
		when ODIN_OS == .Windows {
			return strings.concatenate({heimdall_home, "\\config.toml"})
		} else {
			return strings.concatenate({heimdall_home, "/config.toml"})
		}
	}
	when ODIN_OS == .Windows {
		appdata := os.get_env_alloc("APPDATA", context.allocator)
		if appdata != "" do return strings.concatenate({appdata, "\\heimdall\\config.toml"})
		return "heimdall\\config.toml"
	} else when ODIN_OS == .Darwin {
		xdg := os.get_env_alloc("XDG_CONFIG_HOME", context.allocator)
		if xdg != "" do return strings.concatenate({xdg, "/heimdall/config.toml"})
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return strings.concatenate({home, "/.config/heimdall/config.toml"})
		return "config.toml"
	} else {
		xdg := os.get_env_alloc("XDG_CONFIG_HOME", context.allocator)
		if xdg != "" do return strings.concatenate({xdg, "/heimdall/config.toml"})
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return strings.concatenate({home, "/.config/heimdall/config.toml"})
		return "config.toml"
	}
}

Config :: struct {
	daemon: Daemon_Config,
	bridge: Bridge_Config,
	wrapper: Wrapper_Config,
	guide_agent: Guide_Agent_Config,
	ctl: Ctl_Config,
}

Peer_Config :: struct {
	name: string,
	endpoint: string,
	token: string,
}

Bridge_Config :: struct {
	peers: [dynamic]Peer_Config,
}

Role_Default_Agent_Config :: struct {
	use: string,
	agent_id: string,
}

Daemon_Config :: struct {
	bind_host: string,
	advertise_host: string,
	port: u16,
	data_dir: string,
	daemon_id: string,
	user_id: string,
	namespace: string,
	hub_auth_token: string,
	user_token: string,
	hub_enabled: bool,
	nudge_enabled: bool,
	nudge_interval_seconds: int,
	nudge_ready_after_seconds: int,
	nudge_review_after_seconds: int,
	nudge_need_improvements_after_seconds: int,
	nudge_working_stale_after_seconds: int,
	nudge_cooldown_seconds: int,
	nudge_restart_grace_seconds: int,
	nudge_send_escape_prefix: bool,
	startup_stale_after_seconds: int,
	agent_idle_shutdown_seconds: int, // TODO: remove; idle auto-close disabled
	default_agent_provider_profile: string,
	default_agent_model_tier: string,
	default_agent_ids: [dynamic]Role_Default_Agent_Config,
	system_agent_ids: []string,
	wrapper_bin: string,
	artifact_max_bytes: int,
	artifact_blob_dir: string,
	bridge_url: string,
	bridge_token: string,
	federation_poll_interval_seconds: int,
	federation_advertised_agent_instance_ids: []string,
}

Guide_Agent_Config :: struct {
	enabled: bool,
	autostart: bool,
	restart_if_stopped: bool,
	agent_instance_id: string,
	template_id: string,
	provider_profile: string,
	model_tier: string,
}

Wrapper_Config :: struct {
	daemon_url: string,
	credentials_path: string,
	agent_name: string,
	default_agent: string,
	display_name: string,
	requested_access_mode: contracts.Client_Access_Mode,
	command: []string,
	agent_commands: [dynamic]Agent_Command_Config,
	tmux_session: string,
	tmux_window_prefix: string,
	agent_run_dir: string,
	use_random_dir: bool,
	project: string,
	memory_templates: []string,
	stop_message: string,
	ham_ctl_bin: string,
}

Startup_Detection_Config :: struct {
	enabled: bool,
	startup_probe_seconds: int,
	capture_interval_ms: int,
	blocked_patterns: []string,
	auto_enter_patterns: []string,
	// Parallel to auto_enter_patterns. Each entry is a tmux send-keys argument
	// dispatched BEFORE the Enter (e.g. "Down" to move selection off the
	// default option). Empty string or missing index = no pre-key, just Enter.
	auto_enter_pre_keys: []string,
	startup_unknown_is_blocked: bool,
	sanitized_reason_mapping: []string,
}

Activity_Detection_Config :: struct {
	enabled: bool,
	sample_line_count: int,
	ignore_bottom_lines: int,
	check_interval_seconds: int,
	min_gap_ms: int,
	max_gap_ms: int,
}

Model_Tiers_Config :: struct {
	flag:   string,
	cheap:  string,
	normal: string,
	smart:  string,
}

Bootstrap_Feature_Config :: struct {
	name:         string,
	content:      []string,
	relative_dir: string,
	filename:     string,
}

Bootstrap_Config :: struct {
	features: map[string]Bootstrap_Feature_Config,
}

Agent_Command_Config :: struct {
	name: string,
	command: []string,
	yolo_flags: []string,
	prompt_flags: []string,
	starter_prompt: string,
	prompt_delivery: string,
	prompt_tmux_delay_ms: int,
	prompt_tmux_enter: bool,
	prompt_tmux_enter_set: bool,
	agent_run_dir: string,
	use_random_dir: bool,
	use_random_dir_set: bool,
	project: string,
	bootstrap: Bootstrap_Config,
	models: Model_Tiers_Config,
	memory_templates: []string,
	stop_message: string,
	startup_detection: Startup_Detection_Config,
	activity_detection: Activity_Detection_Config,
}

Ctl_Config :: struct {
	daemon_url: string,
}

Load_Result :: struct {
	path: string,
	config: Config,
}

Section :: enum {
	None,
	Daemon,
	Peer,
	Wrapper,
	Wrapper_Agent_Command,
	Wrapper_Agent_Bootstrap,
	Wrapper_Agent_Bootstrap_Feature,
	Wrapper_Agent_Models,
	Wrapper_Agent_Startup_Detection,
	Wrapper_Agent_Activity_Detection,
	Guide_Agent,
	Ctl,
}

config_path_from_args :: proc(args: []string) -> string {
	for i in 0..<len(args) {
		if args[i] == CONFIG_PATH_FLAG && i + 1 < len(args) {
			return args[i + 1]
		}
	}

	return default_config_path()
}

load :: proc(path: string) -> (Load_Result, bool) {
	cfg := default_config()
	expanded_path := expand_home(path)
	data, err := os.read_entire_file(expanded_path, context.allocator)
	if err != nil {
		return Load_Result{}, false
	}

	parse_config(string(data), &cfg)
	return Load_Result {
		path = expanded_path,
		config = cfg,
	}, true
}

expand_home :: proc(path: string) -> string {
	home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if home == "" {
		home = os.get_env_alloc("HOME", context.allocator)
	}
	if path == "~" {
		if home != "" do return home
	}
	if strings.has_prefix(path, "~/") {
		if home != "" do return strings.concatenate({home, "/", path[2:]})
	}
	return path
}

parse_config :: proc(content: string, cfg: ^Config) {
	section := Section.None
	current_agent_command := ""
	current_bootstrap_feature := ""
	current_peer_index := -1
	legacy_warned := make([dynamic]string)
	lines := strings.split(content, "\n")

	for raw_line in lines {
		line := strip_comment(raw_line)
		line = strings.trim_space(line)
		if line == "" do continue

		if line == "[daemon]" {
			section = .Daemon
			continue
		}
		if line == "[wrapper]" {
			section = .Wrapper
			current_agent_command = ""
			continue
		}
		if line == "[[peer]]" {
			section = .Peer
			current_peer_index = ensure_peer(&cfg.bridge)
			continue
		}
		if line == "[guide_agent]" {
			section = .Guide_Agent
			continue
		}
		// Most specific first: [wrapper.agent-cmd.<name>.bootstrap.<FEATURE>]
		// Length guard: prefix(19) + name(≥1) + ".bootstrap."(11) + feature(≥1) + "]"(1) = ≥33
		if strings.has_prefix(line, "[wrapper.agent-cmd.") && strings.has_suffix(line, "]") && len(line) > 33 {
			inner := line[len("[wrapper.agent-cmd."):len(line) - 1]
			if bi := strings.index(inner, ".bootstrap."); bi >= 0 && bi > 0 && bi + len(".bootstrap.") < len(inner) {
				section = .Wrapper_Agent_Bootstrap_Feature
				current_agent_command = inner[:bi]
				current_bootstrap_feature = inner[bi + len(".bootstrap."):]
				ensure_agent_command(&cfg.wrapper, current_agent_command)
				continue
			}
		}
		// [wrapper.agent-cmd.<name>.bootstrap]
		// Length guard: prefix(19) + name(≥1) + ".bootstrap]"(11) = ≥31
		if strings.has_prefix(line, "[wrapper.agent-cmd.") && strings.has_suffix(line, ".bootstrap]") && len(line) > 19 + len(".bootstrap]") {
			section = .Wrapper_Agent_Bootstrap
			current_agent_command = line[len("[wrapper.agent-cmd."):len(line) - len(".bootstrap]")]
			ensure_agent_command(&cfg.wrapper, current_agent_command)
			continue
		}
		// [wrapper.agent-cmd.<name>.models]
		// Length guard: prefix(19) + name(≥1) + ".models]"(8) = ≥28
		if strings.has_prefix(line, "[wrapper.agent-cmd.") && strings.has_suffix(line, ".models]") && len(line) > 19 + len(".models]") {
			section = .Wrapper_Agent_Models
			current_agent_command = line[len("[wrapper.agent-cmd."):len(line) - len(".models]")]
			ensure_agent_command(&cfg.wrapper, current_agent_command)
			continue
		}
		// [wrapper.agent-cmd.<name>.startup_detection]
		// Length guard: prefix(19) + name(≥1) + ".startup_detection]"(19) = ≥39
		if strings.has_prefix(line, "[wrapper.agent-cmd.") && strings.has_suffix(line, ".startup_detection]") && len(line) > 19 + len(".startup_detection]") {
			section = .Wrapper_Agent_Startup_Detection
			current_agent_command = line[len("[wrapper.agent-cmd."):len(line) - len(".startup_detection]")]
			ensure_agent_command(&cfg.wrapper, current_agent_command)
			continue
		}
		// [wrapper.agent-cmd.<name>.activity_detection]
		// Length guard: prefix(19) + name(≥1) + ".activity_detection]"(20) = ≥40
		if strings.has_prefix(line, "[wrapper.agent-cmd.") && strings.has_suffix(line, ".activity_detection]") && len(line) > 19 + len(".activity_detection]") {
			section = .Wrapper_Agent_Activity_Detection
			current_agent_command = line[len("[wrapper.agent-cmd."):len(line) - len(".activity_detection]")]
			ensure_agent_command(&cfg.wrapper, current_agent_command)
			continue
		}
		// [wrapper.agent-cmd.<name>]
		// Length guard: prefix(19) + name(≥1) + "]"(1) = ≥21
		if strings.has_prefix(line, "[wrapper.agent-cmd.") && strings.has_suffix(line, "]") && len(line) > 20 {
			section = .Wrapper_Agent_Command
			current_agent_command = line[len("[wrapper.agent-cmd."):len(line) - 1]
			ensure_agent_command(&cfg.wrapper, current_agent_command)
			continue
		}
		if line == "[ctl]" {
			section = .Ctl
			continue
		}

		eq := strings.index_byte(line, '=')
		if eq < 0 do continue

		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		if legacy_config_key_warned(section, current_agent_command, current_bootstrap_feature, key, &legacy_warned) do continue

		#partial switch section {
		case .Daemon:
			parse_daemon_key(key, value, &cfg.daemon)
		case .Peer:
			parse_peer_key(current_peer_index, key, value, &cfg.bridge)
		case .Wrapper:
			parse_wrapper_key(key, value, &cfg.wrapper)
		case .Wrapper_Agent_Command:
			parse_agent_command_key(current_agent_command, key, value, &cfg.wrapper)
		case .Wrapper_Agent_Bootstrap:
			parse_bootstrap_key(current_agent_command, key, value, &cfg.wrapper)
		case .Wrapper_Agent_Bootstrap_Feature:
			parse_bootstrap_feature_key(current_agent_command, current_bootstrap_feature, key, value, &cfg.wrapper)
		case .Wrapper_Agent_Models:
			parse_models_key(current_agent_command, key, value, &cfg.wrapper)
		case .Wrapper_Agent_Startup_Detection:
			parse_startup_detection_key(current_agent_command, key, value, &cfg.wrapper)
		case .Wrapper_Agent_Activity_Detection:
			parse_activity_detection_key(current_agent_command, key, value, &cfg.wrapper)
		case .Guide_Agent:
			parse_guide_agent_key(key, value, &cfg.guide_agent)
		case .Ctl:
			parse_ctl_key(key, value, &cfg.ctl)
		case:
		}
	}
}

legacy_config_key_warned :: proc(section: Section, agent_name, bootstrap_feature, key: string, warned: ^[dynamic]string) -> bool {
	legacy_key := ""
	#partial switch section {
	case .Wrapper:
		if key == "project" || key == "memory_templates" || key == "default_agent" {
			legacy_key = strings.concatenate({"wrapper.", key})
		}
	case .Wrapper_Agent_Command:
		if key == "project" || key == "memory_templates" {
			legacy_key = strings.concatenate({"wrapper.agent-cmd.", agent_name, ".", key})
		}
	case .Wrapper_Agent_Bootstrap_Feature:
		if key == "content" {
			legacy_key = strings.concatenate({"wrapper.agent-cmd.", agent_name, ".bootstrap.", bootstrap_feature, ".content"})
		}
	case:
	}
	if legacy_key == "" do return false
	for seen in warned^ {
		if seen == legacy_key do return true
	}
	append(warned, strings.clone(legacy_key))
	fmt.fprintf(os.stderr, "WARN deprecated config key ignored: %s\n", legacy_key)
	return true
}

parse_daemon_key :: proc(key, value: string, cfg: ^Daemon_Config) {
	switch key {
	case "bind_host":
		cfg.bind_host = parse_string(value)
	case "advertise_host":
		cfg.advertise_host = parse_string(value)
	case "port":
		if port, ok := strconv.parse_int(value); ok {
			cfg.port = u16(port)
		}
	case "data_dir":
		cfg.data_dir = expand_home(parse_string(value))
	case "daemon_id":
		cfg.daemon_id = parse_string(value)
	case "user_id":
		cfg.user_id = parse_string(value)
	case "namespace":
		cfg.namespace = parse_string(value)
	case "hub_auth_token":
		cfg.hub_auth_token = parse_string(value)
	case "user_token":
		cfg.user_token = parse_string(value)
	case "hub_enabled":
		cfg.hub_enabled = parse_bool(value)
	case "nudge_enabled":
		cfg.nudge_enabled = parse_bool(value)
	case "nudge_interval_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_interval_seconds = int(n)
	case "nudge_ready_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_ready_after_seconds = int(n)
	case "nudge_review_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_review_after_seconds = int(n)
	case "nudge_need_improvements_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_need_improvements_after_seconds = int(n)
	case "nudge_working_stale_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_working_stale_after_seconds = int(n)
	case "nudge_cooldown_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_cooldown_seconds = int(n)
	case "nudge_restart_grace_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_restart_grace_seconds = int(n)
	case "nudge_send_escape_prefix":
		cfg.nudge_send_escape_prefix = parse_bool(value)
	case "startup_stale_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.startup_stale_after_seconds = int(n)
	case "agent_idle_shutdown_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.agent_idle_shutdown_seconds = int(n)
	case "team_idle_shutdown_seconds":
		fmt.println("WARN deprecated config key ignored: daemon.team_idle_shutdown_seconds; use agent_idle_shutdown_seconds")
		if n, ok := strconv.parse_int(value); ok do cfg.agent_idle_shutdown_seconds = int(n)
	case "default_agent_provider_profile":
		cfg.default_agent_provider_profile = parse_string(value)
	case "default_agent_model_tier":
		cfg.default_agent_model_tier = parse_string(value)
	case "system_agent_ids":
		cfg.system_agent_ids = parse_string_array(value)
	case "wrapper_bin":
		cfg.wrapper_bin = parse_string(value)
	case "artifact_max_bytes":
		if n, ok := strconv.parse_int(value); ok do cfg.artifact_max_bytes = int(n)
	case "artifact_blob_dir":
		cfg.artifact_blob_dir = expand_home(parse_string(value))
	case "bridge_url":
		cfg.bridge_url = parse_string(value)
	case "bridge_token":
		cfg.bridge_token = parse_string(value)
	case "federation_poll_interval_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.federation_poll_interval_seconds = int(n)
	case "federation_advertised_agent_instance_ids":
		cfg.federation_advertised_agent_instance_ids = parse_string_array(value)
	case:
		if strings.has_prefix(key, "default_agent_id_") {
			default_use := strings.trim_space(key[len("default_agent_id_"):])
			if default_use != "" do daemon_default_agent_id_set(cfg, default_use, parse_string(value))
		}
	}
}

daemon_default_agent_id_set :: proc(cfg: ^Daemon_Config, default_use, agent_id: string) {
	use_key := strings.to_lower(strings.trim_space(default_use))
	if use_key == "" do return
	for existing, idx in cfg.default_agent_ids {
		if existing.use == use_key {
			cfg.default_agent_ids[idx].agent_id = parse_string(agent_id)
			return
		}
	}
	append(&cfg.default_agent_ids, Role_Default_Agent_Config{use = strings.clone(use_key), agent_id = strings.clone(strings.trim_space(agent_id))})
}

ensure_peer :: proc(cfg: ^Bridge_Config) -> int {
	append(&cfg.peers, Peer_Config{})
	return len(cfg.peers) - 1
}

parse_peer_key :: proc(idx: int, key, value: string, cfg: ^Bridge_Config) {
	if idx < 0 || idx >= len(cfg.peers) do return
	switch key {
	case "name":
		cfg.peers[idx].name = parse_string(value)
	case "endpoint":
		cfg.peers[idx].endpoint = parse_string(value)
	case "token":
		cfg.peers[idx].token = parse_string(value)
	case:
	}
}

parse_guide_agent_key :: proc(key, value: string, cfg: ^Guide_Agent_Config) {
	switch key {
	case "enabled":
		cfg.enabled = parse_bool(value)
	case "autostart":
		cfg.autostart = parse_bool(value)
	case "restart_if_stopped":
		cfg.restart_if_stopped = parse_bool(value)
	case "agent_instance_id":
		cfg.agent_instance_id = parse_string(value)
	case "template_id":
		cfg.template_id = parse_string(value)
	case "provider_profile":
		cfg.provider_profile = parse_string(value)
	case "model_tier":
		cfg.model_tier = parse_string(value)
	case:
	}
}

parse_wrapper_key :: proc(key, value: string, cfg: ^Wrapper_Config) {
	switch key {
	case "daemon_url":
		cfg.daemon_url = parse_string(value)
	case "credentials_path":
		cfg.credentials_path = expand_home(parse_string(value))
	case "agent_name":
		cfg.agent_name = parse_string(value)
	case "display_name":
		cfg.display_name = parse_string(value)
	case "requested_access_mode":
		cfg.requested_access_mode = parse_access_mode(parse_string(value))
	case "command":
		cfg.command = parse_string_array(value)
	case "tmux_session":
		cfg.tmux_session = parse_string(value)
	case "tmux_window_prefix":
		cfg.tmux_window_prefix = parse_string(value)
	case "agent_run_dir":
		cfg.agent_run_dir = expand_home(parse_string(value))
	case "use_random_dir":
		cfg.use_random_dir = parse_bool(value)
	case "stop_message":
		cfg.stop_message = parse_string(value)
	case "ham_ctl_bin":
		cfg.ham_ctl_bin = expand_home(parse_string(value))
	case:
	}
}

parse_ctl_key :: proc(key, value: string, cfg: ^Ctl_Config) {
	switch key {
	case "daemon_url":
		cfg.daemon_url = parse_string(value)
	case:
	}
}

ensure_agent_command :: proc(cfg: ^Wrapper_Config, name: string) -> int {
	for command, i in cfg.agent_commands {
		if command.name == name do return i
	}
	cmd := Agent_Command_Config{name = strings.clone(name)}
	cmd.bootstrap.features = make(map[string]Bootstrap_Feature_Config)
	cmd.activity_detection = default_activity_detection_config()
	append(&cfg.agent_commands, cmd)
	return len(cfg.agent_commands) - 1
}

parse_agent_command_key :: proc(name, key, value: string, cfg: ^Wrapper_Config) {
	idx := ensure_agent_command(cfg, name)
	switch key {
	case "command":
		cfg.agent_commands[idx].command = parse_string_array(value)
	case "yolo_flags":
		cfg.agent_commands[idx].yolo_flags = parse_string_array(value)
	case "prompt_flags":
		cfg.agent_commands[idx].prompt_flags = parse_string_array(value)
	case "starter_prompt":
		cfg.agent_commands[idx].starter_prompt = parse_string(value)
	case "prompt_delivery":
		cfg.agent_commands[idx].prompt_delivery = parse_string(value)
	case "prompt_tmux_delay_ms":
		if n, ok := strconv.parse_int(value); ok do cfg.agent_commands[idx].prompt_tmux_delay_ms = int(n)
	case "prompt_tmux_enter":
		cfg.agent_commands[idx].prompt_tmux_enter = parse_bool(value)
		cfg.agent_commands[idx].prompt_tmux_enter_set = true
	case "agent_run_dir":
		cfg.agent_commands[idx].agent_run_dir = expand_home(parse_string(value))
	case "use_random_dir":
		cfg.agent_commands[idx].use_random_dir = parse_bool(value)
		cfg.agent_commands[idx].use_random_dir_set = true
	case "stop_message":
		cfg.agent_commands[idx].stop_message = parse_string(value)
	case:
	}
}

parse_bootstrap_key :: proc(name, key, value: string, cfg: ^Wrapper_Config) {
	// enabled_features removed — all bootstrap files are always generated.
	_ = name; _ = key; _ = value; _ = cfg
}

parse_bootstrap_feature_key :: proc(name, feature, key, value: string, cfg: ^Wrapper_Config) {
	idx := ensure_agent_command(cfg, name)
	fc := cfg.agent_commands[idx].bootstrap.features[feature]
	switch key {
	case "name":
		fc.name = parse_string(value)
	case "relative_dir":
		fc.relative_dir = parse_string(value)
	case "filename":
		fc.filename = parse_string(value)
	case:
	}
	cfg.agent_commands[idx].bootstrap.features[feature] = fc
}

parse_models_key :: proc(name, key, value: string, cfg: ^Wrapper_Config) {
	idx := ensure_agent_command(cfg, name)
	switch key {
	case "flag":
		cfg.agent_commands[idx].models.flag = parse_string(value)
	case "cheap":
		cfg.agent_commands[idx].models.cheap = parse_string(value)
	case "normal":
		cfg.agent_commands[idx].models.normal = parse_string(value)
	case "smart":
		cfg.agent_commands[idx].models.smart = parse_string(value)
	case:
	}
}

parse_startup_detection_key :: proc(name, key, value: string, cfg: ^Wrapper_Config) {
	idx := ensure_agent_command(cfg, name)
	sd := &cfg.agent_commands[idx].startup_detection
	switch key {
	case "enabled":
		sd.enabled = parse_bool(value)
	case "startup_probe_seconds":
		if n, ok := strconv.parse_int(value); ok do sd.startup_probe_seconds = int(n)
	case "capture_interval_ms":
		if n, ok := strconv.parse_int(value); ok do sd.capture_interval_ms = int(n)
	case "blocked_patterns":
		sd.blocked_patterns = parse_string_array(value)
	case "auto_enter_patterns":
		sd.auto_enter_patterns = parse_string_array(value)
	case "auto_enter_pre_keys":
		sd.auto_enter_pre_keys = parse_string_array(value)
	case "startup_unknown_is_blocked":
		sd.startup_unknown_is_blocked = parse_bool(value)
	case "sanitized_reason_mapping", "reason_mapping":
		sd.sanitized_reason_mapping = parse_string_array(value)
	case:
	}
}

parse_activity_detection_key :: proc(name, key, value: string, cfg: ^Wrapper_Config) {
	idx := ensure_agent_command(cfg, name)
	ad := &cfg.agent_commands[idx].activity_detection
	switch key {
	case "enabled":
		ad.enabled = parse_bool(value)
	case "sample_line_count":
		if n, ok := strconv.parse_int(value); ok do ad.sample_line_count = int(n)
	case "ignore_bottom_lines":
		if n, ok := strconv.parse_int(value); ok do ad.ignore_bottom_lines = int(n)
	case "check_interval_seconds":
		if n, ok := strconv.parse_int(value); ok do ad.check_interval_seconds = int(n)
	case "min_gap_ms":
		if n, ok := strconv.parse_int(value); ok do ad.min_gap_ms = int(n)
	case "max_gap_ms":
		if n, ok := strconv.parse_int(value); ok do ad.max_gap_ms = int(n)
	case:
	}
}

parse_bool :: proc(value: string) -> bool {
	v := strings.trim_space(value)
	return v == "true" || v == "True" || v == "1" || v == "yes"
}

parse_string :: proc(value: string) -> string {
	v := strings.trim_space(value)
	if len(v) >= 2 && v[0] == '"' && v[len(v) - 1] == '"' {
		return v[1:len(v) - 1]
	}
	return v
}

parse_string_array :: proc(value: string) -> []string {
	v := strings.trim_space(value)
	if len(v) < 2 || v[0] != '[' || v[len(v) - 1] != ']' {
		return nil
	}

	inner := strings.trim_space(v[1:len(v) - 1])
	if inner == "" do return nil

	parts := split_top_level_commas(inner)
	items := make([]string, len(parts))
	for part, i in parts {
		items[i] = parse_string(part)
	}
	return items
}

// Split on commas that are NOT inside a "..." or '...' string literal. Handles
// backslash escapes inside double-quoted strings so commas in patterns like
// "Yes, I trust this folder" stay grouped.
split_top_level_commas :: proc(s: string) -> []string {
	out: [dynamic]string
	start := 0
	in_dq := false
	in_sq := false
	i := 0
	for i < len(s) {
		ch := s[i]
		if in_dq {
			if ch == '\\' && i + 1 < len(s) { i += 2; continue }
			if ch == '"' do in_dq = false
		} else if in_sq {
			if ch == '\'' do in_sq = false
		} else {
			switch ch {
			case '"':  in_dq = true
			case '\'': in_sq = true
			case ',':
				append(&out, s[start:i])
				start = i + 1
			}
		}
		i += 1
	}
	append(&out, s[start:])
	return out[:]
}

resolve_model_value :: proc(m: Model_Tiers_Config, tier: string) -> string {
	switch tier {
	case "cheap":  return m.cheap
	case "normal": return m.normal
	case "smart":  return m.smart
	}
	return ""
}

parse_access_mode :: proc(value: string) -> contracts.Client_Access_Mode {
	switch value {
	case "main", "Main":
		return .Main
	case "copy", "Copy":
		return .Copy
	case "read_only", "read-only", "Read_Only":
		return .Read_Only
	case:
		return .Main
	}
}

strip_comment :: proc(line: string) -> string {
	idx := strings.index_byte(line, '#')
	if idx >= 0 {
		return line[:idx]
	}
	return line
}

default_activity_detection_config :: proc() -> Activity_Detection_Config {
	return Activity_Detection_Config{
		enabled = true,
		sample_line_count = 20,
		ignore_bottom_lines = 0,
		check_interval_seconds = 15,
		min_gap_ms = 100,
		max_gap_ms = 500,
	}
}

default_config :: proc() -> Config {
	cfg: Config
	cfg.daemon.bind_host = "127.0.0.1"
	cfg.daemon.advertise_host = ""
	cfg.daemon.port = 49322
	cfg.daemon.data_dir = "~/.local/share/heimdall"
	cfg.daemon.daemon_id = "local-daemon"
	cfg.daemon.user_id = "local-user"
	cfg.daemon.namespace = "default"
	cfg.daemon.hub_auth_token = "local-hub-auth-token"
	cfg.daemon.user_token = "local-user-encryption-token"
	cfg.daemon.hub_enabled = false
	cfg.daemon.nudge_enabled = false
	cfg.daemon.nudge_interval_seconds = 60
	cfg.daemon.nudge_ready_after_seconds = 300
	cfg.daemon.nudge_review_after_seconds = 300
	cfg.daemon.nudge_need_improvements_after_seconds = 300
	cfg.daemon.nudge_working_stale_after_seconds = 900
	cfg.daemon.nudge_cooldown_seconds = 300
	cfg.daemon.nudge_restart_grace_seconds = 60
	cfg.daemon.nudge_send_escape_prefix = false
	cfg.daemon.startup_stale_after_seconds = 120
	cfg.daemon.agent_idle_shutdown_seconds = 1800
	cfg.daemon.default_agent_provider_profile = "pi"
	cfg.daemon.default_agent_model_tier = "normal"
	cfg.daemon.default_agent_ids = make([dynamic]Role_Default_Agent_Config)
	daemon_default_agent_id_set(&cfg.daemon, "conversation", "conversation")
	daemon_default_agent_id_set(&cfg.daemon, "guide", "guide")
	daemon_default_agent_id_set(&cfg.daemon, "coordinator", "coordinator")
	daemon_default_agent_id_set(&cfg.daemon, "worker", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "assignee", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "coder", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "tester", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "researcher", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "specialist", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "reviewer", "reviewer")
	cfg.daemon.system_agent_ids = make([]string, 3)
	cfg.daemon.system_agent_ids[0] = "guide"
	cfg.daemon.system_agent_ids[1] = "memory-auditor"
	cfg.daemon.system_agent_ids[2] = "memory-reviewer"
	cfg.daemon.artifact_max_bytes = 10 * 1024 * 1024
	cfg.daemon.artifact_blob_dir = ""
	cfg.daemon.bridge_url = ""
	cfg.daemon.bridge_token = ""
	cfg.daemon.federation_poll_interval_seconds = 10
	cfg.daemon.federation_advertised_agent_instance_ids = nil
	cfg.bridge.peers = make([dynamic]Peer_Config)

	cfg.guide_agent.enabled = true
	cfg.guide_agent.autostart = true
	cfg.guide_agent.restart_if_stopped = true
	cfg.guide_agent.agent_instance_id = "guide@heimdall"
	cfg.guide_agent.template_id = "guide"
	cfg.guide_agent.provider_profile = "pi"
	cfg.guide_agent.model_tier = "smart"

	cfg.wrapper.daemon_url = "http://127.0.0.1:49322"
	cfg.wrapper.credentials_path = "~/.local/share/heimdall/wrapper-credentials.json"
	cfg.wrapper.agent_name = "pi"
	cfg.wrapper.default_agent = "pi"
	cfg.wrapper.display_name = "{instance}"
	cfg.wrapper.requested_access_mode = .Main
	cfg.wrapper.command = nil
	cfg.wrapper.agent_commands = make([dynamic]Agent_Command_Config)
	cfg.wrapper.tmux_session = "ham-agents"
	cfg.wrapper.tmux_window_prefix = "agent"
	cfg.wrapper.agent_run_dir = ""
	cfg.wrapper.use_random_dir = false
	cfg.wrapper.project = ""
	cfg.wrapper.memory_templates = nil

	cfg.ctl.daemon_url = "http://127.0.0.1:49322"

	return cfg
}
