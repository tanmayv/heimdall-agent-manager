package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import cfg_lib "odin_test:lib/config"

Bridge_Provider_Source :: enum {
	Config,
	Store,
	Merged,
}

Bridge_Provider_Profile :: struct {
	name: string,
	enabled: bool,
	source: Bridge_Provider_Source,
	has_override: bool,
	command: []string,
	yolo_flags: []string,
	prompt_flags: []string,
	starter_prompt: string,
	prompt_delivery: string,
	prompt_tmux_delay_ms: int,
	prompt_tmux_enter: bool,
	agent_run_dir: string,
	use_random_dir: bool,
	models: cfg_lib.Model_Tiers_Config,
	startup_detection: cfg_lib.Startup_Detection_Config,
	activity_detection: cfg_lib.Activity_Detection_Config,
}

Bridge_Provider_Override :: struct {
	name: string,
	enabled: bool,
	enabled_set: bool,
	command: []string,
	command_set: bool,
	yolo_flags: []string,
	yolo_flags_set: bool,
	prompt_flags: []string,
	prompt_flags_set: bool,
	starter_prompt: string,
	starter_prompt_set: bool,
	prompt_delivery: string,
	prompt_delivery_set: bool,
	prompt_tmux_delay_ms: int,
	prompt_tmux_delay_ms_set: bool,
	prompt_tmux_enter: bool,
	prompt_tmux_enter_set: bool,
	agent_run_dir: string,
	agent_run_dir_set: bool,
	use_random_dir: bool,
	use_random_dir_set: bool,
	models: cfg_lib.Model_Tiers_Config,
	models_flag_set: bool,
	models_cheap_set: bool,
	models_normal_set: bool,
	models_smart_set: bool,
	startup_detection: cfg_lib.Startup_Detection_Config,
	startup_enabled_set: bool,
	startup_probe_set: bool,
	startup_capture_set: bool,
	startup_blocked_patterns_set: bool,
	startup_auto_enter_patterns_set: bool,
	startup_auto_enter_pre_keys_set: bool,
	startup_unknown_blocked_set: bool,
	startup_reason_mapping_set: bool,
	activity_detection: cfg_lib.Activity_Detection_Config,
	activity_enabled_set: bool,
	activity_sample_lines_set: bool,
	activity_ignore_bottom_set: bool,
	activity_check_interval_set: bool,
	activity_min_gap_set: bool,
	activity_max_gap_set: bool,
}

bridge_provider_mutex: sync.Mutex
bridge_provider_store_loaded: bool
bridge_provider_store_path_value: string
bridge_provider_overrides: [dynamic]Bridge_Provider_Override

bridge_provider_store_init :: proc() {
	sync.mutex_lock(&bridge_provider_mutex)
	defer sync.mutex_unlock(&bridge_provider_mutex)
	if bridge_provider_store_loaded do return
	bridge_provider_overrides = make([dynamic]Bridge_Provider_Override)
	bridge_provider_store_path_value = bridge_provider_store_path()
	bridge_provider_load_unlocked()
	bridge_provider_store_loaded = true
}

bridge_provider_store_path :: proc() -> string {
	data_dir := bridge_expand_home(bridge_config.data_dir)
	if strings.trim_space(data_dir) == "" do data_dir = bridge_expand_home("~/.local/share/heimdall")
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/bridge/providers.json"})
}

bridge_expand_home :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") {
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return strings.concatenate({home, path[1:]})
	}
	return path
}

bridge_provider_load_unlocked :: proc() {
	path := bridge_provider_store_path_value
	if strings.trim_space(path) == "" do return
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	providers_array, ok := bridge_provider_json_extract_array(string(raw), "providers")
	if !ok do return
	objects := bridge_provider_json_top_level_objects(providers_array)
	for obj in objects {
		override, override_ok := bridge_provider_override_from_json(obj)
		if !override_ok do continue
		bridge_provider_upsert_override_unlocked(override)
	}
}

bridge_provider_upsert_override_unlocked :: proc(override: Bridge_Provider_Override) {
	if strings.trim_space(override.name) == "" do return
	for i in 0..<len(bridge_provider_overrides) {
		if bridge_provider_overrides[i].name == override.name {
			bridge_provider_overrides[i] = override
			return
		}
	}
	append(&bridge_provider_overrides, override)
}

bridge_provider_save_overrides :: proc() -> bool {
	bridge_provider_store_init()
	sync.mutex_lock(&bridge_provider_mutex)
	defer sync.mutex_unlock(&bridge_provider_mutex)
	path := bridge_provider_store_path_value
	if strings.trim_space(path) == "" do return false
	if slash := strings.last_index_byte(path, '/'); slash > 0 { _ = os.make_directory_all(path[:slash]) }
	b := strings.builder_make()
	strings.write_string(&b, "{\n  \"providers\": [")
	for override, i in bridge_provider_overrides {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, "\n    ")
		bridge_provider_write_override_json(&b, override)
	}
	strings.write_string(&b, "\n  ]\n}\n")
	content := strings.to_string(b)
	tmp := strings.concatenate({path, ".tmp"})
	if os.write_entire_file(tmp, content) != nil do return false
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

bridge_effective_provider_profiles :: proc() -> []Bridge_Provider_Profile {
	bridge_provider_store_init()
	sync.mutex_lock(&bridge_provider_mutex)
	defer sync.mutex_unlock(&bridge_provider_mutex)
	profiles := make([dynamic]Bridge_Provider_Profile)
	for cmd in bridge_config.agent_commands {
		profile := bridge_provider_profile_from_config(cmd)
		if override, ok := bridge_provider_override_for_name_unlocked(profile.name); ok {
			profile = bridge_provider_apply_override(profile, override)
			profile.source = .Merged
			profile.has_override = true
		}
		append(&profiles, profile)
	}
	for override in bridge_provider_overrides {
		if bridge_config_agent_command_exists(override.name) do continue
		profile := bridge_provider_profile_from_override(override)
		profile.source = .Store
		profile.has_override = true
		append(&profiles, profile)
	}
	return profiles[:]
}

bridge_config_agent_command_exists :: proc(name: string) -> bool {
	for cmd in bridge_config.agent_commands { if cmd.name == name do return true }
	return false
}

bridge_provider_override_for_name_unlocked :: proc(name: string) -> (Bridge_Provider_Override, bool) {
	for override in bridge_provider_overrides { if override.name == name do return override, true }
	return {}, false
}

bridge_provider_profile_from_config :: proc(cmd: cfg_lib.Agent_Command_Config) -> Bridge_Provider_Profile {
	return Bridge_Provider_Profile{
		name = strings.clone(cmd.name),
		enabled = true,
		source = .Config,
		command = bridge_clone_string_slice(cmd.command),
		yolo_flags = bridge_clone_string_slice(cmd.yolo_flags),
		prompt_flags = bridge_clone_string_slice(cmd.prompt_flags),
		starter_prompt = strings.clone(cmd.starter_prompt),
		prompt_delivery = strings.clone(cmd.prompt_delivery),
		prompt_tmux_delay_ms = cmd.prompt_tmux_delay_ms,
		prompt_tmux_enter = cmd.prompt_tmux_enter,
		agent_run_dir = strings.clone(cmd.agent_run_dir),
		use_random_dir = cmd.use_random_dir,
		models = cmd.models,
		startup_detection = cmd.startup_detection,
		activity_detection = cmd.activity_detection,
	}
}

bridge_provider_profile_from_override :: proc(override: Bridge_Provider_Override) -> Bridge_Provider_Profile {
	profile := Bridge_Provider_Profile{
		name = strings.clone(override.name),
		enabled = true,
		source = .Store,
		activity_detection = cfg_lib.default_activity_detection_config(),
	}
	return bridge_provider_apply_override(profile, override)
}

bridge_provider_apply_override :: proc(profile: Bridge_Provider_Profile, override: Bridge_Provider_Override) -> Bridge_Provider_Profile {
	result := profile
	if override.enabled_set do result.enabled = override.enabled
	if override.command_set do result.command = bridge_clone_string_slice(override.command)
	if override.yolo_flags_set do result.yolo_flags = bridge_clone_string_slice(override.yolo_flags)
	if override.prompt_flags_set do result.prompt_flags = bridge_clone_string_slice(override.prompt_flags)
	if override.starter_prompt_set do result.starter_prompt = strings.clone(override.starter_prompt)
	if override.prompt_delivery_set do result.prompt_delivery = strings.clone(override.prompt_delivery)
	if override.prompt_tmux_delay_ms_set do result.prompt_tmux_delay_ms = override.prompt_tmux_delay_ms
	if override.prompt_tmux_enter_set do result.prompt_tmux_enter = override.prompt_tmux_enter
	if override.agent_run_dir_set do result.agent_run_dir = strings.clone(override.agent_run_dir)
	if override.use_random_dir_set do result.use_random_dir = override.use_random_dir
	if override.models_flag_set do result.models.flag = strings.clone(override.models.flag)
	if override.models_cheap_set do result.models.cheap = strings.clone(override.models.cheap)
	if override.models_normal_set do result.models.normal = strings.clone(override.models.normal)
	if override.models_smart_set do result.models.smart = strings.clone(override.models.smart)
	if override.startup_enabled_set do result.startup_detection.enabled = override.startup_detection.enabled
	if override.startup_probe_set do result.startup_detection.startup_probe_seconds = override.startup_detection.startup_probe_seconds
	if override.startup_capture_set do result.startup_detection.capture_interval_ms = override.startup_detection.capture_interval_ms
	if override.startup_blocked_patterns_set do result.startup_detection.blocked_patterns = bridge_clone_string_slice(override.startup_detection.blocked_patterns)
	if override.startup_auto_enter_patterns_set do result.startup_detection.auto_enter_patterns = bridge_clone_string_slice(override.startup_detection.auto_enter_patterns)
	if override.startup_auto_enter_pre_keys_set do result.startup_detection.auto_enter_pre_keys = bridge_clone_string_slice(override.startup_detection.auto_enter_pre_keys)
	if override.startup_unknown_blocked_set do result.startup_detection.startup_unknown_is_blocked = override.startup_detection.startup_unknown_is_blocked
	if override.startup_reason_mapping_set do result.startup_detection.sanitized_reason_mapping = bridge_clone_string_slice(override.startup_detection.sanitized_reason_mapping)
	if override.activity_enabled_set do result.activity_detection.enabled = override.activity_detection.enabled
	if override.activity_sample_lines_set do result.activity_detection.sample_line_count = override.activity_detection.sample_line_count
	if override.activity_ignore_bottom_set do result.activity_detection.ignore_bottom_lines = override.activity_detection.ignore_bottom_lines
	if override.activity_check_interval_set do result.activity_detection.check_interval_seconds = override.activity_detection.check_interval_seconds
	if override.activity_min_gap_set do result.activity_detection.min_gap_ms = override.activity_detection.min_gap_ms
	if override.activity_max_gap_set do result.activity_detection.max_gap_ms = override.activity_detection.max_gap_ms
	return result
}

bridge_default_provider_name :: proc() -> string {
	profiles := bridge_effective_provider_profiles()
	for profile in profiles {
		if profile.enabled && bridge_provider_default_tier(profile) != "" do return profile.name
	}
	return ""
}

bridge_provider_by_name_or_default :: proc(name: string) -> (Bridge_Provider_Profile, bool) {
	profiles := bridge_effective_provider_profiles()
	wanted := strings.trim_space(name)
	if wanted != "" {
		for profile in profiles { if profile.name == wanted do return profile, true }
	}
	for profile in profiles {
		if profile.enabled && bridge_provider_default_tier(profile) != "" do return profile, true
	}
	return {}, false
}

bridge_provider_default_tier :: proc(profile: Bridge_Provider_Profile) -> string {
	if strings.trim_space(profile.models.normal) != "" do return "normal"
	if strings.trim_space(profile.models.cheap) != "" do return "cheap"
	if strings.trim_space(profile.models.smart) != "" do return "smart"
	return ""
}

bridge_provider_model_for_tier :: proc(profile: Bridge_Provider_Profile, tier: string) -> string {
	return cfg_lib.resolve_model_value(profile.models, tier)
}

bridge_provider_capabilities_json :: proc() -> string {
	profiles := bridge_effective_provider_profiles()
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	first_profile := true
	for profile in profiles {
		if !profile.enabled do continue
		default_tier := bridge_provider_default_tier(profile)
		if default_tier == "" do continue
		if !first_profile do strings.write_byte(&b, ',')
		first_profile = false
		strings.write_string(&b, "{\"provider\":\"")
		json_write_string(&b, profile.name)
		strings.write_string(&b, "\",\"tiers\":[")
		first_tier := true
		bridge_provider_write_capability_tier(&b, &first_tier, "cheap", profile.models.cheap)
		bridge_provider_write_capability_tier(&b, &first_tier, "normal", profile.models.normal)
		bridge_provider_write_capability_tier(&b, &first_tier, "smart", profile.models.smart)
		strings.write_string(&b, "],\"default_tier\":\"")
		json_write_string(&b, default_tier)
		strings.write_string(&b, "\"}")
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

bridge_provider_write_capability_tier :: proc(b: ^strings.Builder, first_tier: ^bool, tier, model: string) {
	if strings.trim_space(model) == "" do return
	if !first_tier^ do strings.write_byte(b, ',')
	first_tier^ = false
	strings.write_byte(b, '"')
	json_write_string(b, tier)
	strings.write_byte(b, '"')
}

bridge_provider_profiles_report_json :: proc(bridge_id: string) -> string {
	profiles := bridge_effective_provider_profiles()
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\"")
	json_write_string(&b, bridge_id)
	strings.write_string(&b, "\",\"providers\":[")
	for profile, i in profiles {
		if i > 0 do strings.write_byte(&b, ',')
		bridge_provider_write_profile_json(&b, profile)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_provider_write_profile_json :: proc(b: ^strings.Builder, profile: Bridge_Provider_Profile) {
	strings.write_string(b, "{\"name\":\""); json_write_string(b, profile.name)
	strings.write_string(b, "\",\"enabled\":"); strings.write_string(b, "true" if profile.enabled else "false")
	strings.write_string(b, ",\"source\":\""); json_write_string(b, bridge_provider_source_string(profile.source))
	strings.write_string(b, "\",\"has_override\":"); strings.write_string(b, "true" if profile.has_override else "false")
	strings.write_string(b, ",\"command\":"); bridge_provider_write_string_array_json(b, profile.command)
	strings.write_string(b, ",\"models\":"); bridge_provider_write_models_json(b, profile.models)
	strings.write_string(b, ",\"prompt_flags\":"); bridge_provider_write_string_array_json(b, profile.prompt_flags)
	strings.write_string(b, ",\"yolo_flags\":"); bridge_provider_write_string_array_json(b, profile.yolo_flags)
	strings.write_string(b, ",\"starter_prompt\":\""); json_write_string(b, profile.starter_prompt)
	strings.write_string(b, "\",\"prompt_delivery\":\""); json_write_string(b, profile.prompt_delivery)
	strings.write_string(b, "\",\"prompt_tmux_delay_ms\":"); strings.write_string(b, fmt.tprintf("%d", profile.prompt_tmux_delay_ms))
	strings.write_string(b, ",\"prompt_tmux_enter\":"); strings.write_string(b, "true" if profile.prompt_tmux_enter else "false")
	strings.write_string(b, ",\"agent_run_dir\":\""); json_write_string(b, profile.agent_run_dir)
	strings.write_string(b, "\",\"use_random_dir\":"); strings.write_string(b, "true" if profile.use_random_dir else "false")
	strings.write_string(b, ",\"startup_detection\":"); bridge_provider_write_startup_json(b, profile.startup_detection)
	strings.write_string(b, ",\"activity_detection\":"); bridge_provider_write_activity_json(b, profile.activity_detection)
	strings.write_string(b, "}")
}

bridge_provider_source_string :: proc(source: Bridge_Provider_Source) -> string {
	switch source {
	case .Config: return "config"
	case .Store: return "store"
	case .Merged: return "merged"
	}
	return "config"
}

bridge_provider_write_override_json :: proc(b: ^strings.Builder, override: Bridge_Provider_Override) {
	strings.write_byte(b, '{')
	first := true
	bridge_provider_write_json_field_prefix(b, &first, "name")
	strings.write_byte(b, '"'); json_write_string(b, override.name); strings.write_byte(b, '"')
	if override.enabled_set { bridge_provider_write_json_field_prefix(b, &first, "enabled"); strings.write_string(b, "true" if override.enabled else "false") }
	if override.command_set { bridge_provider_write_json_field_prefix(b, &first, "command"); bridge_provider_write_string_array_json(b, override.command) }
	if override.prompt_flags_set { bridge_provider_write_json_field_prefix(b, &first, "prompt_flags"); bridge_provider_write_string_array_json(b, override.prompt_flags) }
	if override.yolo_flags_set { bridge_provider_write_json_field_prefix(b, &first, "yolo_flags"); bridge_provider_write_string_array_json(b, override.yolo_flags) }
	if override.starter_prompt_set { bridge_provider_write_json_field_prefix(b, &first, "starter_prompt"); strings.write_byte(b, '"'); json_write_string(b, override.starter_prompt); strings.write_byte(b, '"') }
	if override.prompt_delivery_set { bridge_provider_write_json_field_prefix(b, &first, "prompt_delivery"); strings.write_byte(b, '"'); json_write_string(b, override.prompt_delivery); strings.write_byte(b, '"') }
	if override.prompt_tmux_delay_ms_set { bridge_provider_write_json_field_prefix(b, &first, "prompt_tmux_delay_ms"); strings.write_string(b, fmt.tprintf("%d", override.prompt_tmux_delay_ms)) }
	if override.prompt_tmux_enter_set { bridge_provider_write_json_field_prefix(b, &first, "prompt_tmux_enter"); strings.write_string(b, "true" if override.prompt_tmux_enter else "false") }
	if override.agent_run_dir_set { bridge_provider_write_json_field_prefix(b, &first, "agent_run_dir"); strings.write_byte(b, '"'); json_write_string(b, override.agent_run_dir); strings.write_byte(b, '"') }
	if override.use_random_dir_set { bridge_provider_write_json_field_prefix(b, &first, "use_random_dir"); strings.write_string(b, "true" if override.use_random_dir else "false") }
	if bridge_provider_override_has_models(override) {
		bridge_provider_write_json_field_prefix(b, &first, "models")
		bridge_provider_write_override_models_json(b, override)
	}
	if bridge_provider_override_has_startup(override) {
		bridge_provider_write_json_field_prefix(b, &first, "startup_detection")
		bridge_provider_write_override_startup_json(b, override)
	}
	if bridge_provider_override_has_activity(override) {
		bridge_provider_write_json_field_prefix(b, &first, "activity_detection")
		bridge_provider_write_override_activity_json(b, override)
	}
	strings.write_byte(b, '}')
}

bridge_provider_write_json_field_prefix :: proc(b: ^strings.Builder, first: ^bool, key: string) {
	if !first^ do strings.write_byte(b, ',')
	first^ = false
	strings.write_byte(b, '"')
	json_write_string(b, key)
	strings.write_string(b, "\":")
}

bridge_provider_override_has_models :: proc(override: Bridge_Provider_Override) -> bool {
	return override.models_flag_set || override.models_cheap_set || override.models_normal_set || override.models_smart_set
}

bridge_provider_override_has_startup :: proc(override: Bridge_Provider_Override) -> bool {
	return override.startup_enabled_set || override.startup_probe_set || override.startup_capture_set || override.startup_blocked_patterns_set || override.startup_auto_enter_patterns_set || override.startup_auto_enter_pre_keys_set || override.startup_unknown_blocked_set || override.startup_reason_mapping_set
}

bridge_provider_override_has_activity :: proc(override: Bridge_Provider_Override) -> bool {
	return override.activity_enabled_set || override.activity_sample_lines_set || override.activity_ignore_bottom_set || override.activity_check_interval_set || override.activity_min_gap_set || override.activity_max_gap_set
}

bridge_provider_write_override_models_json :: proc(b: ^strings.Builder, override: Bridge_Provider_Override) {
	strings.write_byte(b, '{')
	first := true
	if override.models_flag_set { bridge_provider_write_json_field_prefix(b, &first, "flag"); strings.write_byte(b, '"'); json_write_string(b, override.models.flag); strings.write_byte(b, '"') }
	if override.models_cheap_set { bridge_provider_write_json_field_prefix(b, &first, "cheap"); strings.write_byte(b, '"'); json_write_string(b, override.models.cheap); strings.write_byte(b, '"') }
	if override.models_normal_set { bridge_provider_write_json_field_prefix(b, &first, "normal"); strings.write_byte(b, '"'); json_write_string(b, override.models.normal); strings.write_byte(b, '"') }
	if override.models_smart_set { bridge_provider_write_json_field_prefix(b, &first, "smart"); strings.write_byte(b, '"'); json_write_string(b, override.models.smart); strings.write_byte(b, '"') }
	strings.write_byte(b, '}')
}

bridge_provider_write_override_startup_json :: proc(b: ^strings.Builder, override: Bridge_Provider_Override) {
	strings.write_byte(b, '{')
	first := true
	if override.startup_enabled_set { bridge_provider_write_json_field_prefix(b, &first, "enabled"); strings.write_string(b, "true" if override.startup_detection.enabled else "false") }
	if override.startup_probe_set { bridge_provider_write_json_field_prefix(b, &first, "startup_probe_seconds"); strings.write_string(b, fmt.tprintf("%d", override.startup_detection.startup_probe_seconds)) }
	if override.startup_capture_set { bridge_provider_write_json_field_prefix(b, &first, "capture_interval_ms"); strings.write_string(b, fmt.tprintf("%d", override.startup_detection.capture_interval_ms)) }
	if override.startup_blocked_patterns_set { bridge_provider_write_json_field_prefix(b, &first, "blocked_patterns"); bridge_provider_write_string_array_json(b, override.startup_detection.blocked_patterns) }
	if override.startup_auto_enter_patterns_set { bridge_provider_write_json_field_prefix(b, &first, "auto_enter_patterns"); bridge_provider_write_string_array_json(b, override.startup_detection.auto_enter_patterns) }
	if override.startup_auto_enter_pre_keys_set { bridge_provider_write_json_field_prefix(b, &first, "auto_enter_pre_keys"); bridge_provider_write_string_array_json(b, override.startup_detection.auto_enter_pre_keys) }
	if override.startup_unknown_blocked_set { bridge_provider_write_json_field_prefix(b, &first, "startup_unknown_is_blocked"); strings.write_string(b, "true" if override.startup_detection.startup_unknown_is_blocked else "false") }
	if override.startup_reason_mapping_set { bridge_provider_write_json_field_prefix(b, &first, "sanitized_reason_mapping"); bridge_provider_write_string_array_json(b, override.startup_detection.sanitized_reason_mapping) }
	strings.write_byte(b, '}')
}

bridge_provider_write_override_activity_json :: proc(b: ^strings.Builder, override: Bridge_Provider_Override) {
	strings.write_byte(b, '{')
	first := true
	if override.activity_enabled_set { bridge_provider_write_json_field_prefix(b, &first, "enabled"); strings.write_string(b, "true" if override.activity_detection.enabled else "false") }
	if override.activity_sample_lines_set { bridge_provider_write_json_field_prefix(b, &first, "sample_line_count"); strings.write_string(b, fmt.tprintf("%d", override.activity_detection.sample_line_count)) }
	if override.activity_ignore_bottom_set { bridge_provider_write_json_field_prefix(b, &first, "ignore_bottom_lines"); strings.write_string(b, fmt.tprintf("%d", override.activity_detection.ignore_bottom_lines)) }
	if override.activity_check_interval_set { bridge_provider_write_json_field_prefix(b, &first, "check_interval_seconds"); strings.write_string(b, fmt.tprintf("%d", override.activity_detection.check_interval_seconds)) }
	if override.activity_min_gap_set { bridge_provider_write_json_field_prefix(b, &first, "min_gap_ms"); strings.write_string(b, fmt.tprintf("%d", override.activity_detection.min_gap_ms)) }
	if override.activity_max_gap_set { bridge_provider_write_json_field_prefix(b, &first, "max_gap_ms"); strings.write_string(b, fmt.tprintf("%d", override.activity_detection.max_gap_ms)) }
	strings.write_byte(b, '}')
}

bridge_provider_write_models_json :: proc(b: ^strings.Builder, models: cfg_lib.Model_Tiers_Config) {
	strings.write_string(b, "{\"flag\":\""); json_write_string(b, models.flag)
	strings.write_string(b, "\",\"cheap\":\""); json_write_string(b, models.cheap)
	strings.write_string(b, "\",\"normal\":\""); json_write_string(b, models.normal)
	strings.write_string(b, "\",\"smart\":\""); json_write_string(b, models.smart)
	strings.write_string(b, "\"}")
}

bridge_provider_write_startup_json :: proc(b: ^strings.Builder, sd: cfg_lib.Startup_Detection_Config) {
	strings.write_string(b, "{\"enabled\":"); strings.write_string(b, "true" if sd.enabled else "false")
	strings.write_string(b, ",\"startup_probe_seconds\":"); strings.write_string(b, fmt.tprintf("%d", sd.startup_probe_seconds))
	strings.write_string(b, ",\"capture_interval_ms\":"); strings.write_string(b, fmt.tprintf("%d", sd.capture_interval_ms))
	strings.write_string(b, ",\"blocked_patterns\":"); bridge_provider_write_string_array_json(b, sd.blocked_patterns)
	strings.write_string(b, ",\"auto_enter_patterns\":"); bridge_provider_write_string_array_json(b, sd.auto_enter_patterns)
	strings.write_string(b, ",\"auto_enter_pre_keys\":"); bridge_provider_write_string_array_json(b, sd.auto_enter_pre_keys)
	strings.write_string(b, ",\"startup_unknown_is_blocked\":"); strings.write_string(b, "true" if sd.startup_unknown_is_blocked else "false")
	strings.write_string(b, ",\"sanitized_reason_mapping\":"); bridge_provider_write_string_array_json(b, sd.sanitized_reason_mapping)
	strings.write_string(b, "}")
}

bridge_provider_write_activity_json :: proc(b: ^strings.Builder, ad: cfg_lib.Activity_Detection_Config) {
	strings.write_string(b, "{\"enabled\":"); strings.write_string(b, "true" if ad.enabled else "false")
	strings.write_string(b, ",\"sample_line_count\":"); strings.write_string(b, fmt.tprintf("%d", ad.sample_line_count))
	strings.write_string(b, ",\"ignore_bottom_lines\":"); strings.write_string(b, fmt.tprintf("%d", ad.ignore_bottom_lines))
	strings.write_string(b, ",\"check_interval_seconds\":"); strings.write_string(b, fmt.tprintf("%d", ad.check_interval_seconds))
	strings.write_string(b, ",\"min_gap_ms\":"); strings.write_string(b, fmt.tprintf("%d", ad.min_gap_ms))
	strings.write_string(b, ",\"max_gap_ms\":"); strings.write_string(b, fmt.tprintf("%d", ad.max_gap_ms))
	strings.write_string(b, "}")
}

bridge_provider_write_string_array_json :: proc(b: ^strings.Builder, values: []string) {
	strings.write_byte(b, '[')
	for value, i in values {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		json_write_string(b, value)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}

bridge_provider_override_from_json :: proc(obj: string) -> (Bridge_Provider_Override, bool) {
	o: Bridge_Provider_Override
	o.name = bridge_provider_json_extract_string(obj, "name", "")
	if strings.trim_space(o.name) == "" do return o, false
	if v, ok := bridge_provider_json_extract_bool(obj, "enabled"); ok { o.enabled = v; o.enabled_set = true }
	if v, ok := bridge_provider_json_extract_string_array(obj, "command"); ok { o.command = v; o.command_set = true }
	if v, ok := bridge_provider_json_extract_string_array(obj, "yolo_flags"); ok { o.yolo_flags = v; o.yolo_flags_set = true }
	if v, ok := bridge_provider_json_extract_string_array(obj, "prompt_flags"); ok { o.prompt_flags = v; o.prompt_flags_set = true }
	if v, ok := bridge_provider_json_extract_string_set(obj, "starter_prompt"); ok { o.starter_prompt = v; o.starter_prompt_set = true }
	if v, ok := bridge_provider_json_extract_string_set(obj, "prompt_delivery"); ok { o.prompt_delivery = v; o.prompt_delivery_set = true }
	if v, ok := bridge_provider_json_extract_int(obj, "prompt_tmux_delay_ms"); ok { o.prompt_tmux_delay_ms = v; o.prompt_tmux_delay_ms_set = true }
	if v, ok := bridge_provider_json_extract_bool(obj, "prompt_tmux_enter"); ok { o.prompt_tmux_enter = v; o.prompt_tmux_enter_set = true }
	if v, ok := bridge_provider_json_extract_string_set(obj, "agent_run_dir"); ok { o.agent_run_dir = bridge_expand_home(v); o.agent_run_dir_set = true }
	if v, ok := bridge_provider_json_extract_bool(obj, "use_random_dir"); ok { o.use_random_dir = v; o.use_random_dir_set = true }
	if models_obj, ok := bridge_provider_json_extract_object(obj, "models"); ok {
		if v, got := bridge_provider_json_extract_string_set(models_obj, "flag"); got { o.models.flag = v; o.models_flag_set = true }
		if v, got := bridge_provider_json_extract_string_set(models_obj, "cheap"); got { o.models.cheap = v; o.models_cheap_set = true }
		if v, got := bridge_provider_json_extract_string_set(models_obj, "normal"); got { o.models.normal = v; o.models_normal_set = true }
		if v, got := bridge_provider_json_extract_string_set(models_obj, "smart"); got { o.models.smart = v; o.models_smart_set = true }
	}
	if sd_obj, ok := bridge_provider_json_extract_object(obj, "startup_detection"); ok {
		if v, got := bridge_provider_json_extract_bool(sd_obj, "enabled"); got { o.startup_detection.enabled = v; o.startup_enabled_set = true }
		if v, got := bridge_provider_json_extract_int(sd_obj, "startup_probe_seconds"); got { o.startup_detection.startup_probe_seconds = v; o.startup_probe_set = true }
		if v, got := bridge_provider_json_extract_int(sd_obj, "capture_interval_ms"); got { o.startup_detection.capture_interval_ms = v; o.startup_capture_set = true }
		if v, got := bridge_provider_json_extract_string_array(sd_obj, "blocked_patterns"); got { o.startup_detection.blocked_patterns = v; o.startup_blocked_patterns_set = true }
		if v, got := bridge_provider_json_extract_string_array(sd_obj, "auto_enter_patterns"); got { o.startup_detection.auto_enter_patterns = v; o.startup_auto_enter_patterns_set = true }
		if v, got := bridge_provider_json_extract_string_array(sd_obj, "auto_enter_pre_keys"); got { o.startup_detection.auto_enter_pre_keys = v; o.startup_auto_enter_pre_keys_set = true }
		if v, got := bridge_provider_json_extract_bool(sd_obj, "startup_unknown_is_blocked"); got { o.startup_detection.startup_unknown_is_blocked = v; o.startup_unknown_blocked_set = true }
		if v, got := bridge_provider_json_extract_string_array(sd_obj, "sanitized_reason_mapping"); got { o.startup_detection.sanitized_reason_mapping = v; o.startup_reason_mapping_set = true }
	}
	if ad_obj, ok := bridge_provider_json_extract_object(obj, "activity_detection"); ok {
		if v, got := bridge_provider_json_extract_bool(ad_obj, "enabled"); got { o.activity_detection.enabled = v; o.activity_enabled_set = true }
		if v, got := bridge_provider_json_extract_int(ad_obj, "sample_line_count"); got { o.activity_detection.sample_line_count = v; o.activity_sample_lines_set = true }
		if v, got := bridge_provider_json_extract_int(ad_obj, "ignore_bottom_lines"); got { o.activity_detection.ignore_bottom_lines = v; o.activity_ignore_bottom_set = true }
		if v, got := bridge_provider_json_extract_int(ad_obj, "check_interval_seconds"); got { o.activity_detection.check_interval_seconds = v; o.activity_check_interval_set = true }
		if v, got := bridge_provider_json_extract_int(ad_obj, "min_gap_ms"); got { o.activity_detection.min_gap_ms = v; o.activity_min_gap_set = true }
		if v, got := bridge_provider_json_extract_int(ad_obj, "max_gap_ms"); got { o.activity_detection.max_gap_ms = v; o.activity_max_gap_set = true }
	}
	return o, true
}

bridge_provider_json_extract_string :: proc(json, key, fallback: string) -> string {
	value, ok := bridge_provider_json_extract_string_set(json, key)
	if !ok do return fallback
	return value
}

bridge_provider_json_extract_string_set :: proc(json, key: string) -> (string, bool) {
	start := bridge_provider_json_member_value_start(json, key)
	if start < 0 do return "", false
	rest := strings.trim_space(json[start:])
	if len(rest) == 0 || rest[0] != '"' do return "", false
	end := 1
	escaped := false
	for end < len(rest) {
		ch := rest[end]
		if escaped { escaped = false } else if ch == '\\' { escaped = true } else if ch == '"' { return json_unescape(rest[1:end]), true }
		end += 1
	}
	return "", false
}

bridge_provider_json_extract_bool :: proc(json, key: string) -> (bool, bool) {
	start := bridge_provider_json_member_value_start(json, key)
	if start < 0 do return false, false
	rest := strings.trim_space(json[start:])
	if strings.has_prefix(rest, "true") do return true, true
	if strings.has_prefix(rest, "false") do return false, true
	return false, false
}

bridge_provider_json_extract_int :: proc(json, key: string) -> (int, bool) {
	start := bridge_provider_json_member_value_start(json, key)
	if start < 0 do return 0, false
	rest := strings.trim_space(json[start:])
	end := 0
	if end < len(rest) && rest[end] == '-' do end += 1
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
	if end == 0 || (end == 1 && rest[0] == '-') do return 0, false
	if parsed, ok := strconv_parse_int_bridge_provider(rest[:end]); ok do return int(parsed), true
	return 0, false
}

bridge_provider_json_extract_object :: proc(json, key: string) -> (string, bool) {
	start := bridge_provider_json_member_value_start(json, key)
	if start < 0 do return "", false
	rest := strings.trim_space(json[start:])
	if len(rest) == 0 || rest[0] != '{' do return "", false
	if value, ok := bridge_provider_json_balanced(rest, '{', '}'); ok do return value, true
	return "", false
}

bridge_provider_json_extract_array :: proc(json, key: string) -> (string, bool) {
	start := bridge_provider_json_member_value_start(json, key)
	if start < 0 do return "", false
	rest := strings.trim_space(json[start:])
	if len(rest) == 0 || rest[0] != '[' do return "", false
	if value, ok := bridge_provider_json_balanced(rest, '[', ']'); ok do return value, true
	return "", false
}

bridge_provider_json_extract_string_array :: proc(json, key: string) -> ([]string, bool) {
	array, ok := bridge_provider_json_extract_array(json, key)
	if !ok do return nil, false
	return bridge_provider_json_parse_string_array(array), true
}

bridge_provider_json_parse_string_array :: proc(array: string) -> []string {
	out := make([dynamic]string)
	i := 0
	for i < len(array) {
		if array[i] != '"' { i += 1; continue }
		start := i + 1
		j := start
		escaped := false
		for j < len(array) {
			ch := array[j]
			if escaped { escaped = false } else if ch == '\\' { escaped = true } else if ch == '"' { append(&out, json_unescape(array[start:j])); i = j + 1; break }
			j += 1
		}
		if j >= len(array) do break
	}
	return out[:]
}

bridge_provider_json_top_level_objects :: proc(array: string) -> []string {
	out := make([dynamic]string)
	in_string := false
	escaped := false
	depth := 0
	start := -1
	for i in 0..<len(array) {
		ch := array[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == '{' {
			if depth == 0 do start = i
			depth += 1
			continue
		}
		if ch == '}' {
			depth -= 1
			if depth == 0 && start >= 0 {
				append(&out, strings.clone(array[start:i + 1]))
				start = -1
			}
		}
	}
	return out[:]
}

bridge_provider_json_balanced :: proc(rest: string, open, close: byte) -> (string, bool) {
	depth := 0
	in_string := false
	escaped := false
	for i in 0..<len(rest) {
		ch := rest[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == open do depth += 1
		if ch == close {
			depth -= 1
			if depth == 0 do return rest[:i + 1], true
		}
	}
	return "", false
}

bridge_provider_json_member_value_start :: proc(json, key: string) -> int {
	i := 0
	for i < len(json) {
		if json[i] != '"' { i += 1; continue }
		start := i + 1
		j := start
		escaped := false
		for j < len(json) {
			ch := json[j]
			if escaped { escaped = false; j += 1; continue }
			if ch == '\\' { escaped = true; j += 1; continue }
			if ch == '"' do break
			j += 1
		}
		if j >= len(json) do return -1
		k := j + 1
		for k < len(json) && bridge_provider_json_is_ws(json[k]) do k += 1
		if json[start:j] == key && k < len(json) && json[k] == ':' do return k + 1
		i = j + 1
	}
	return -1
}

bridge_provider_json_is_ws :: proc(ch: byte) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

strconv_parse_int_bridge_provider :: proc(value: string) -> (int, bool) {
	if value == "" do return 0, false
	neg := false
	idx := 0
	if value[0] == '-' { neg = true; idx = 1 }
	if idx >= len(value) do return 0, false
	result := 0
	for idx < len(value) {
		ch := value[idx]
		if ch < '0' || ch > '9' do return 0, false
		result = result * 10 + int(ch - '0')
		idx += 1
	}
	if neg do result = -result
	return result, true
}

bridge_clone_string_slice :: proc(values: []string) -> []string {
	if len(values) == 0 do return nil
	out := make([]string, len(values))
	for value, i in values do out[i] = strings.clone(value)
	return out
}

bridge_runtime_shell_command_for_profile :: proc(profile: Bridge_Provider_Profile, tier, agent_token, agent_instance_id: string) -> string {
	argv := make([dynamic]string)
	append(&argv, ..profile.command)
	append(&argv, ..profile.yolo_flags)
	resolved_tier := tier
	if strings.trim_space(resolved_tier) == "" do resolved_tier = bridge_provider_default_tier(profile)
	if profile.models.flag != "" {
		model := bridge_provider_model_for_tier(profile, resolved_tier)
		if model != "" {
			append(&argv, profile.models.flag)
			append(&argv, model)
		}
	}
	starter_prompt := bridge_provider_render_starter_prompt(profile.starter_prompt, agent_token, agent_instance_id)
	if starter_prompt != "" {
		append(&argv, ..profile.prompt_flags)
		append(&argv, starter_prompt)
	}
	return bridge_shell_join(argv[:])
}

bridge_provider_render_starter_prompt :: proc(prompt, agent_token, agent_instance_id: string) -> string {
	out := prompt
	// Agents launched by the Bridge have only the Bridge local endpoint + local
	// agent token in their environment. Normalize legacy bootstrap text so
	// start-success routes through `ham-ctl agent ...` instead of the old Hub
	// `/agent-rpc` path (onboarding audit B3).
	out, _ = strings.replace_all(out, "{ctl_bin} --token {token} start-success", "{ctl_bin} agent start-success")
	out, _ = strings.replace_all(out, "{ctl_bin} start-success", "{ctl_bin} agent start-success")
	out, _ = strings.replace_all(out, "{token}", agent_token)
	out, _ = strings.replace_all(out, "{agent_token}", agent_token)
	out, _ = strings.replace_all(out, "{instance}", agent_instance_id)
	out, _ = strings.replace_all(out, "{agent_instance_id}", agent_instance_id)
	out, _ = strings.replace_all(out, "{daemon_url}", bridge_config.daemon_url)
	out, _ = strings.replace_all(out, "{ctl_bin}", "ham-ctl")
	out, _ = strings.replace_all(out, strings.concatenate({"ham-ctl --token ", agent_token, " start-success"}), "ham-ctl agent start-success")
	out, _ = strings.replace_all(out, "ham-ctl start-success", "ham-ctl agent start-success")
	return out
}

bridge_shell_join :: proc(argv: []string) -> string {
	b := strings.builder_make()
	for arg, i in argv {
		if i > 0 do strings.write_byte(&b, ' ')
		bridge_shell_write_quoted(&b, arg)
	}
	return strings.to_string(b)
}

bridge_shell_write_quoted :: proc(b: ^strings.Builder, arg: string) {
	strings.write_byte(b, '\'')
	for ch in arg {
		if ch == '\'' {
			strings.write_string(b, "'\\''")
		} else {
			strings.write_rune(b, ch)
		}
	}
	strings.write_byte(b, '\'')
}
