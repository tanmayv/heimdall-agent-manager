package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import cfg_lib "odin_test:lib/config"
import agent_runtime "odin_test:lib/agent_runtime"
import jsonx "odin_test:lib/jsonx"

Bridge_Provider_Source :: enum {
	Seed,
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
	skill_dir: string,
	bootstrap_file_name: string,
	logo: string,
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
	skill_dir: string,
	skill_dir_set: bool,
	bootstrap_file_name: string,
	bootstrap_file_name_set: bool,
	logo: string,
	logo_set: bool,
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

Bridge_Provider_Models_Wire :: struct {
	flag:   Maybe(string) `json:"flag,omitempty"`,
	cheap:  Maybe(string) `json:"cheap,omitempty"`,
	normal: Maybe(string) `json:"normal,omitempty"`,
	smart:  Maybe(string) `json:"smart,omitempty"`,
}

Bridge_Provider_Startup_Detection_Wire :: struct {
	enabled:                    Maybe(bool)     `json:"enabled,omitempty"`,
	startup_probe_seconds:      Maybe(int)      `json:"startup_probe_seconds,omitempty"`,
	capture_interval_ms:        Maybe(int)      `json:"capture_interval_ms,omitempty"`,
	blocked_patterns:           Maybe([]string) `json:"blocked_patterns,omitempty"`,
	auto_enter_patterns:        Maybe([]string) `json:"auto_enter_patterns,omitempty"`,
	auto_enter_pre_keys:        Maybe([]string) `json:"auto_enter_pre_keys,omitempty"`,
	startup_unknown_is_blocked: Maybe(bool)     `json:"startup_unknown_is_blocked,omitempty"`,
	sanitized_reason_mapping:   Maybe([]string) `json:"sanitized_reason_mapping,omitempty"`,
}

Bridge_Provider_Activity_Detection_Wire :: struct {
	enabled:                Maybe(bool) `json:"enabled,omitempty"`,
	sample_line_count:      Maybe(int)  `json:"sample_line_count,omitempty"`,
	ignore_bottom_lines:    Maybe(int)  `json:"ignore_bottom_lines,omitempty"`,
	check_interval_seconds: Maybe(int)  `json:"check_interval_seconds,omitempty"`,
	min_gap_ms:             Maybe(int)  `json:"min_gap_ms,omitempty"`,
	max_gap_ms:             Maybe(int)  `json:"max_gap_ms,omitempty"`,
}

Bridge_Provider_Override_Wire :: struct {
	name:                 string                                        `json:"name"`,
	enabled:              Maybe(bool)                                   `json:"enabled,omitempty"`,
	command:              Maybe([]string)                               `json:"command,omitempty"`,
	yolo_flags:           Maybe([]string)                               `json:"yolo_flags,omitempty"`,
	prompt_flags:         Maybe([]string)                               `json:"prompt_flags,omitempty"`,
	starter_prompt:       Maybe(string)                                 `json:"starter_prompt,omitempty"`,
	prompt_delivery:      Maybe(string)                                 `json:"prompt_delivery,omitempty"`,
	prompt_tmux_delay_ms: Maybe(int)                                    `json:"prompt_tmux_delay_ms,omitempty"`,
	prompt_tmux_enter:    Maybe(bool)                                   `json:"prompt_tmux_enter,omitempty"`,
	agent_run_dir:        Maybe(string)                                 `json:"agent_run_dir,omitempty"`,
	use_random_dir:       Maybe(bool)                                   `json:"use_random_dir,omitempty"`,
	skill_dir:            Maybe(string)                                 `json:"skill_dir,omitempty"`,
	bootstrap_file_name:  Maybe(string)                                 `json:"bootstrap_file_name,omitempty"`,
	logo:                 Maybe(string)                                 `json:"logo,omitempty"`,
	models:               Maybe(Bridge_Provider_Models_Wire)            `json:"models,omitempty"`,
	startup_detection:    Maybe(Bridge_Provider_Startup_Detection_Wire) `json:"startup_detection,omitempty"`,
	activity_detection:   Maybe(Bridge_Provider_Activity_Detection_Wire)`json:"activity_detection,omitempty"`,
}

Bridge_Provider_Store_Wire :: struct {
	default_provider: string                         `json:"default_provider"`,
	default_tier:     string                         `json:"default_tier"`,
	providers:        []Bridge_Provider_Override_Wire `json:"providers"`,
}

bridge_provider_override_to_wire :: proc(override: Bridge_Provider_Override) -> Bridge_Provider_Override_Wire {
	w: Bridge_Provider_Override_Wire
	w.name = override.name
	if override.enabled_set do w.enabled = override.enabled
	if override.command_set do w.command = override.command
	if override.yolo_flags_set do w.yolo_flags = override.yolo_flags
	if override.prompt_flags_set do w.prompt_flags = override.prompt_flags
	if override.starter_prompt_set do w.starter_prompt = override.starter_prompt
	if override.prompt_delivery_set do w.prompt_delivery = override.prompt_delivery
	if override.prompt_tmux_delay_ms_set do w.prompt_tmux_delay_ms = override.prompt_tmux_delay_ms
	if override.prompt_tmux_enter_set do w.prompt_tmux_enter = override.prompt_tmux_enter
	if override.agent_run_dir_set do w.agent_run_dir = override.agent_run_dir
	if override.use_random_dir_set do w.use_random_dir = override.use_random_dir
	if override.skill_dir_set do w.skill_dir = override.skill_dir
	if override.bootstrap_file_name_set do w.bootstrap_file_name = override.bootstrap_file_name
	if override.logo_set do w.logo = override.logo

	if bridge_provider_override_has_models(override) {
		mw: Bridge_Provider_Models_Wire
		if override.models_flag_set do mw.flag = override.models.flag
		if override.models_cheap_set do mw.cheap = override.models.cheap
		if override.models_normal_set do mw.normal = override.models.normal
		if override.models_smart_set do mw.smart = override.models.smart
		w.models = mw
	}

	if bridge_provider_override_has_startup(override) {
		sw: Bridge_Provider_Startup_Detection_Wire
		if override.startup_enabled_set do sw.enabled = override.startup_detection.enabled
		if override.startup_probe_set do sw.startup_probe_seconds = override.startup_detection.startup_probe_seconds
		if override.startup_capture_set do sw.capture_interval_ms = override.startup_detection.capture_interval_ms
		if override.startup_blocked_patterns_set do sw.blocked_patterns = override.startup_detection.blocked_patterns
		if override.startup_auto_enter_patterns_set do sw.auto_enter_patterns = override.startup_detection.auto_enter_patterns
		if override.startup_auto_enter_pre_keys_set do sw.auto_enter_pre_keys = override.startup_detection.auto_enter_pre_keys
		if override.startup_unknown_blocked_set do sw.startup_unknown_is_blocked = override.startup_detection.startup_unknown_is_blocked
		if override.startup_reason_mapping_set do sw.sanitized_reason_mapping = override.startup_detection.sanitized_reason_mapping
		w.startup_detection = sw
	}

	if bridge_provider_override_has_activity(override) {
		aw: Bridge_Provider_Activity_Detection_Wire
		if override.activity_enabled_set do aw.enabled = override.activity_detection.enabled
		if override.activity_sample_lines_set do aw.sample_line_count = override.activity_detection.sample_line_count
		if override.activity_ignore_bottom_set do aw.ignore_bottom_lines = override.activity_detection.ignore_bottom_lines
		if override.activity_check_interval_set do aw.check_interval_seconds = override.activity_detection.check_interval_seconds
		if override.activity_min_gap_set do aw.min_gap_ms = override.activity_detection.min_gap_ms
		if override.activity_max_gap_set do aw.max_gap_ms = override.activity_detection.max_gap_ms
		w.activity_detection = aw
	}

	return w
}

bridge_provider_override_from_wire :: proc(wire: Bridge_Provider_Override_Wire, fallback_name: string = "", allocator := context.allocator) -> (Bridge_Provider_Override, bool) {
	o: Bridge_Provider_Override
	name := wire.name
	if strings.trim_space(name) == "" {
		name = fallback_name
	}
	if strings.trim_space(name) == "" {
		return o, false
	}
	o.name = strings.clone(name, allocator)

	if v, ok := wire.enabled.?; ok { o.enabled = v; o.enabled_set = true }
	if v, ok := wire.command.?; ok { o.command = bridge_clone_string_slice(v, allocator); o.command_set = true }
	if v, ok := wire.yolo_flags.?; ok { o.yolo_flags = bridge_clone_string_slice(v, allocator); o.yolo_flags_set = true }
	if v, ok := wire.prompt_flags.?; ok { o.prompt_flags = bridge_clone_string_slice(v, allocator); o.prompt_flags_set = true }
	if v, ok := wire.starter_prompt.?; ok { o.starter_prompt = strings.clone(v, allocator); o.starter_prompt_set = true }
	if v, ok := wire.prompt_delivery.?; ok { o.prompt_delivery = strings.clone(v, allocator); o.prompt_delivery_set = true }
	if v, ok := wire.prompt_tmux_delay_ms.?; ok { o.prompt_tmux_delay_ms = v; o.prompt_tmux_delay_ms_set = true }
	if v, ok := wire.prompt_tmux_enter.?; ok { o.prompt_tmux_enter = v; o.prompt_tmux_enter_set = true }
	if v, ok := wire.agent_run_dir.?; ok {
		expanded := bridge_expand_home(v)
		if expanded != v {
			o.agent_run_dir = strings.clone(expanded, allocator)
			delete(expanded)
		} else {
			o.agent_run_dir = strings.clone(v, allocator)
		}
		o.agent_run_dir_set = true
	}
	if v, ok := wire.use_random_dir.?; ok { o.use_random_dir = v; o.use_random_dir_set = true }
	if v, ok := wire.skill_dir.?; ok { o.skill_dir = strings.clone(v, allocator); o.skill_dir_set = true }
	if v, ok := wire.bootstrap_file_name.?; ok {
		trimmed := strings.trim_space(v)
		o.bootstrap_file_name = strings.clone(trimmed, allocator)
		o.bootstrap_file_name_set = true
	}
	if v, ok := wire.logo.?; ok { o.logo = strings.clone(v, allocator); o.logo_set = true }

	if mw, ok := wire.models.?; ok {
		if v, got := mw.flag.?; got { o.models.flag = strings.clone(v, allocator); o.models_flag_set = true }
		if v, got := mw.cheap.?; got { o.models.cheap = strings.clone(v, allocator); o.models_cheap_set = true }
		if v, got := mw.normal.?; got { o.models.normal = strings.clone(v, allocator); o.models_normal_set = true }
		if v, got := mw.smart.?; got { o.models.smart = strings.clone(v, allocator); o.models_smart_set = true }
	}

	if sd, ok := wire.startup_detection.?; ok {
		if v, got := sd.enabled.?; got { o.startup_detection.enabled = v; o.startup_enabled_set = true }
		if v, got := sd.startup_probe_seconds.?; got { o.startup_detection.startup_probe_seconds = v; o.startup_probe_set = true }
		if v, got := sd.capture_interval_ms.?; got { o.startup_detection.capture_interval_ms = v; o.startup_capture_set = true }
		if v, got := sd.blocked_patterns.?; got { o.startup_detection.blocked_patterns = bridge_clone_string_slice(v, allocator); o.startup_blocked_patterns_set = true }
		if v, got := sd.auto_enter_patterns.?; got { o.startup_detection.auto_enter_patterns = bridge_clone_string_slice(v, allocator); o.startup_auto_enter_patterns_set = true }
		if v, got := sd.auto_enter_pre_keys.?; got { o.startup_detection.auto_enter_pre_keys = bridge_clone_string_slice(v, allocator); o.startup_auto_enter_pre_keys_set = true }
		if v, got := sd.startup_unknown_is_blocked.?; got { o.startup_detection.startup_unknown_is_blocked = v; o.startup_unknown_blocked_set = true }
		if v, got := sd.sanitized_reason_mapping.?; got { o.startup_detection.sanitized_reason_mapping = bridge_clone_string_slice(v, allocator); o.startup_reason_mapping_set = true }
	}

	if ad, ok := wire.activity_detection.?; ok {
		if v, got := ad.enabled.?; got { o.activity_detection.enabled = v; o.activity_enabled_set = true }
		if v, got := ad.sample_line_count.?; got { o.activity_detection.sample_line_count = v; o.activity_sample_lines_set = true }
		if v, got := ad.ignore_bottom_lines.?; got { o.activity_detection.ignore_bottom_lines = v; o.activity_ignore_bottom_set = true }
		if v, got := ad.check_interval_seconds.?; got { o.activity_detection.check_interval_seconds = v; o.activity_check_interval_set = true }
		if v, got := ad.min_gap_ms.?; got { o.activity_detection.min_gap_ms = v; o.activity_min_gap_set = true }
		if v, got := ad.max_gap_ms.?; got { o.activity_detection.max_gap_ms = v; o.activity_max_gap_set = true }
	}

	return o, true
}

bridge_provider_mutex: sync.Mutex
bridge_provider_store_loaded: bool
bridge_provider_store_path_value: string
bridge_provider_default_provider_value: string
bridge_provider_default_tier_value: string
bridge_provider_overrides: [dynamic]Bridge_Provider_Override

bridge_provider_store_init :: proc() {
	sync.mutex_lock(&bridge_provider_mutex)
	if bridge_provider_store_loaded {
		sync.mutex_unlock(&bridge_provider_mutex)
		return
	}
	context.allocator = runtime.default_allocator()
	if bridge_provider_overrides == nil {
		bridge_provider_overrides = make([dynamic]Bridge_Provider_Override, runtime.default_allocator())
	} else {
		clear(&bridge_provider_overrides)
	}
	bridge_provider_store_path_value = bridge_provider_store_path()
	bridge_provider_load_unlocked()
	bridge_provider_store_loaded = true
	sync.mutex_unlock(&bridge_provider_mutex)
}

// Reset / clear provider store overrides and loaded state under lock (for tests).
bridge_provider_test_reset :: proc() {
	sync.mutex_lock(&bridge_provider_mutex)
	defer sync.mutex_unlock(&bridge_provider_mutex)
	for &override in bridge_provider_overrides {
		bridge_provider_override_destroy(&override)
	}
	clear(&bridge_provider_overrides)
	if bridge_provider_store_path_value != "" {
		delete(bridge_provider_store_path_value)
		bridge_provider_store_path_value = ""
	}
	if bridge_provider_default_provider_value != "" {
		delete(bridge_provider_default_provider_value)
		bridge_provider_default_provider_value = ""
	}
	if bridge_provider_default_tier_value != "" {
		delete(bridge_provider_default_tier_value)
		bridge_provider_default_tier_value = ""
	}
	bridge_provider_store_loaded = false
}

bridge_provider_store_path :: proc() -> string {
	data_dir := bridge_expand_home(bridge_config.data_dir)
	if strings.trim_space(data_dir) == "" do data_dir = bridge_expand_home("~/.local/share/heimdall")
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/bridge/providers.json"})
}

bridge_expand_home :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") {
		home := os.get_env_alloc("HOME", context.allocator)
		defer delete(home)
		if home != "" do return strings.concatenate({home, path[1:]})
	}
	return path
}

bridge_provider_load_unlocked :: proc() {
	path := bridge_provider_store_path_value
	if strings.trim_space(path) == "" do return
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(raw)
	body := string(raw)

	store_wire: Bridge_Provider_Store_Wire
	if uerr := json.unmarshal_string(body, &store_wire, json.DEFAULT_SPECIFICATION, context.temp_allocator); uerr != nil {
		return
	}

	if bridge_provider_default_provider_value != "" {
		delete(bridge_provider_default_provider_value)
		bridge_provider_default_provider_value = ""
	}
	if bridge_provider_default_tier_value != "" {
		delete(bridge_provider_default_tier_value)
		bridge_provider_default_tier_value = ""
	}
	if len(store_wire.default_provider) > 0 {
		bridge_provider_default_provider_value = strings.clone(store_wire.default_provider)
	}
	if len(store_wire.default_tier) > 0 {
		bridge_provider_default_tier_value = strings.clone(store_wire.default_tier)
	}

	for wire in store_wire.providers {
		override, override_ok := bridge_provider_override_from_wire(wire, "", context.allocator)
		if !override_ok do continue
		bridge_provider_upsert_override_unlocked(override)
	}
}

bridge_provider_upsert_override_unlocked :: proc(override: Bridge_Provider_Override) {
	if strings.trim_space(override.name) == "" do return
	for i in 0..<len(bridge_provider_overrides) {
		if bridge_provider_overrides[i].name == override.name {
			bridge_provider_override_destroy(&bridge_provider_overrides[i])
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

	wire_providers := make([]Bridge_Provider_Override_Wire, len(bridge_provider_overrides), context.temp_allocator)
	for override, i in bridge_provider_overrides {
		wire_providers[i] = bridge_provider_override_to_wire(override)
	}

	store_wire := Bridge_Provider_Store_Wire{
		default_provider = bridge_provider_default_provider_value,
		default_tier     = bridge_provider_default_tier_value,
		providers        = wire_providers,
	}

	opt := json.Marshal_Options{
		pretty           = true,
		use_spaces       = true,
		spaces           = 2,
		sort_maps_by_key = true,
	}
	bytes, merr := json.marshal(store_wire, opt, context.temp_allocator)
	if merr != nil do return false

	payload := strings.concatenate({string(bytes), "\n"}, context.temp_allocator)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)payload) != nil do return false
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
	seeds := bridge_provider_seed_data()
	// Pass 1: seeds (apply store override on top if exists)
	for seed in seeds {
		profile := bridge_provider_profile_from_seed(seed)
		if override, ok := bridge_provider_override_for_name_unlocked(profile.name); ok {
			profile = bridge_provider_apply_override(profile, override)
			profile.source = .Merged
			profile.has_override = true
		}
		append(&profiles, profile)
	}
	// Pass 2: store-only overrides not covered by any seed
	for override in bridge_provider_overrides {
		if strings.trim_space(override.name) == "" do continue
		already := false
		for seed in seeds { if seed.name == override.name { already = true; break } }
		if already do continue
		profile := bridge_provider_profile_from_override(override)
		profile.source = .Store
		profile.has_override = true
		append(&profiles, profile)
	}
	return profiles[:]
}

bridge_provider_override_for_name_unlocked :: proc(name: string) -> (Bridge_Provider_Override, bool) {
	for override in bridge_provider_overrides { if override.name == name do return override, true }
	return {}, false
}

bridge_provider_profile_from_seed :: proc(seed: Bridge_Provider_Seed) -> Bridge_Provider_Profile {
	return Bridge_Provider_Profile{
		name                = seed.name,
		enabled             = true,
		source              = .Seed,
		logo                = seed.logo,
		command             = seed.command,
		prompt_flags        = seed.prompt_flags,
		yolo_flags          = seed.yolo_flags,
		starter_prompt      = seed.starter_prompt,
		prompt_delivery     = seed.prompt_delivery,
		skill_dir           = seed.skill_dir,
		bootstrap_file_name = seed.bootstrap_file_name,
		models              = seed.models,
		startup_detection   = seed.startup_detection,
		activity_detection  = cfg_lib.default_activity_detection_config(),
	}
}

bridge_provider_default_skill_dir :: proc(provider: string) -> string {
	trimmed := strings.trim_space(provider)
	for seed in bridge_provider_seed_data() {
		if strings.equal_fold(seed.name, trimmed) do return seed.skill_dir
	}
	return "skills"
}

bridge_provider_profile_from_override :: proc(override: Bridge_Provider_Override) -> Bridge_Provider_Profile {
	profile := Bridge_Provider_Profile{
		name = override.name,
		enabled = true,
		source = .Store,
		skill_dir = bridge_provider_default_skill_dir(override.name),
		activity_detection = cfg_lib.default_activity_detection_config(),
	}
	return bridge_provider_apply_override(profile, override)
}

bridge_provider_apply_override :: proc(profile: Bridge_Provider_Profile, override: Bridge_Provider_Override) -> Bridge_Provider_Profile {
	result := profile
	if override.enabled_set do result.enabled = override.enabled
	if override.command_set do result.command = override.command
	if override.yolo_flags_set do result.yolo_flags = override.yolo_flags
	if override.prompt_flags_set do result.prompt_flags = override.prompt_flags
	if override.starter_prompt_set do result.starter_prompt = override.starter_prompt
	if override.prompt_delivery_set do result.prompt_delivery = override.prompt_delivery
	if override.prompt_tmux_delay_ms_set do result.prompt_tmux_delay_ms = override.prompt_tmux_delay_ms
	if override.prompt_tmux_enter_set do result.prompt_tmux_enter = override.prompt_tmux_enter
	if override.agent_run_dir_set do result.agent_run_dir = override.agent_run_dir
	if override.use_random_dir_set do result.use_random_dir = override.use_random_dir
	if override.skill_dir_set do result.skill_dir = override.skill_dir
	if override.bootstrap_file_name_set do result.bootstrap_file_name = override.bootstrap_file_name
	if override.logo_set do result.logo = override.logo
	if override.models_flag_set do result.models.flag = override.models.flag
	if override.models_cheap_set do result.models.cheap = override.models.cheap
	if override.models_normal_set do result.models.normal = override.models.normal
	if override.models_smart_set do result.models.smart = override.models.smart
	if override.startup_enabled_set do result.startup_detection.enabled = override.startup_detection.enabled
	if override.startup_probe_set do result.startup_detection.startup_probe_seconds = override.startup_detection.startup_probe_seconds
	if override.startup_capture_set do result.startup_detection.capture_interval_ms = override.startup_detection.capture_interval_ms
	if override.startup_blocked_patterns_set do result.startup_detection.blocked_patterns = override.startup_detection.blocked_patterns
	if override.startup_auto_enter_patterns_set do result.startup_detection.auto_enter_patterns = override.startup_detection.auto_enter_patterns
	if override.startup_auto_enter_pre_keys_set do result.startup_detection.auto_enter_pre_keys = override.startup_detection.auto_enter_pre_keys
	if override.startup_unknown_blocked_set do result.startup_detection.startup_unknown_is_blocked = override.startup_detection.startup_unknown_is_blocked
	if override.startup_reason_mapping_set do result.startup_detection.sanitized_reason_mapping = override.startup_detection.sanitized_reason_mapping
	if override.activity_enabled_set do result.activity_detection.enabled = override.activity_detection.enabled
	if override.activity_sample_lines_set do result.activity_detection.sample_line_count = override.activity_detection.sample_line_count
	if override.activity_ignore_bottom_set do result.activity_detection.ignore_bottom_lines = override.activity_detection.ignore_bottom_lines
	if override.activity_check_interval_set do result.activity_detection.check_interval_seconds = override.activity_detection.check_interval_seconds
	if override.activity_min_gap_set do result.activity_detection.min_gap_ms = override.activity_detection.min_gap_ms
	if override.activity_max_gap_set do result.activity_detection.max_gap_ms = override.activity_detection.max_gap_ms
	return result
}

bridge_default_provider_name :: proc() -> string {
	profile, ok := bridge_default_provider_profile()
	if ok do return profile.name
	return ""
}

bridge_default_provider_profile :: proc() -> (Bridge_Provider_Profile, bool) {
	profiles := bridge_effective_provider_profiles()
	defer delete(profiles)
	if bridge_provider_default_provider_value != "" {
		for profile in profiles {
			if profile.name == bridge_provider_default_provider_value && profile.enabled && bridge_provider_default_tier(profile) != "" do return profile, true
		}
	}
	for profile in profiles {
		if profile.enabled && bridge_provider_default_tier(profile) != "" do return profile, true
	}
	return {}, false
}

bridge_provider_by_name_or_default :: proc(name: string) -> (Bridge_Provider_Profile, bool) {
	profiles := bridge_effective_provider_profiles()
	defer delete(profiles)
	wanted := strings.trim_space(name)
	if wanted != "" {
		for profile in profiles { if profile.name == wanted do return profile, true }
	}
	return bridge_default_provider_profile()
}

bridge_provider_default_tier :: proc(profile: Bridge_Provider_Profile) -> string {
	if bridge_provider_default_tier_value != "" && bridge_provider_model_for_tier(profile, bridge_provider_default_tier_value) != "" do return bridge_provider_default_tier_value
	if strings.trim_space(profile.models.normal) != "" do return "normal"
	if strings.trim_space(profile.models.cheap) != "" do return "cheap"
	if strings.trim_space(profile.models.smart) != "" do return "smart"
	return ""
}

bridge_provider_set_defaults :: proc(provider, tier: string) -> (bool, string) {
	bridge_provider_store_init()
	profiles := bridge_effective_provider_profiles()
	defer delete(profiles)
	found_provider := false
	for profile in profiles {
		if profile.name == provider && profile.enabled && bridge_provider_default_tier(profile) != "" {
			found_provider = true
			if tier != "" && bridge_provider_model_for_tier(profile, tier) == "" do return false, "selected tier is not configured for selected provider"
			break
		}
	}
	if !found_provider do return false, "selected provider is not enabled or has no configured tiers"
	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_default_provider_value = strings.clone(provider)
	bridge_provider_default_tier_value = strings.clone(tier)
	sync.mutex_unlock(&bridge_provider_mutex)
	if !bridge_provider_save_overrides() do return false, "failed to save provider defaults"
	return true, ""
}

bridge_provider_model_for_tier :: proc(profile: Bridge_Provider_Profile, tier: string) -> string {
	return cfg_lib.resolve_model_value(profile.models, tier)
}

bridge_provider_capabilities_json :: proc() -> string {
	profiles := bridge_effective_provider_profiles()
	defer delete(profiles)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	first_profile := true
	default_provider := bridge_default_provider_name()
	for pass in 0..<2 {
		for profile in profiles {
			if pass == 0 && profile.name != default_provider do continue
			if pass == 1 && profile.name == default_provider do continue
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
	defer delete(profiles)
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\"")
	json_write_string(&b, bridge_id)
	strings.write_string(&b, "\",\"default_provider\":\""); json_write_string(&b, bridge_default_provider_name())
	strings.write_string(&b, "\",\"default_tier\":\""); if profile, ok := bridge_default_provider_profile(); ok { json_write_string(&b, bridge_provider_default_tier(profile)) }
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
	strings.write_string(b, ",\"skill_dir\":\""); json_write_string(b, profile.skill_dir); strings.write_byte(b, '"')
	strings.write_string(b, ",\"bootstrap_file_name\":\""); json_write_string(b, profile.bootstrap_file_name); strings.write_byte(b, '"')
	strings.write_string(b, ",\"logo\":\""); json_write_string(b, profile.logo); strings.write_byte(b, '"')
	strings.write_string(b, ",\"startup_detection\":"); bridge_provider_write_startup_json(b, profile.startup_detection)
	strings.write_string(b, ",\"activity_detection\":"); bridge_provider_write_activity_json(b, profile.activity_detection)
	strings.write_string(b, "}")
}

bridge_provider_source_string :: proc(source: Bridge_Provider_Source) -> string {
	switch source {
	case .Seed: return "seed"
	case .Store: return "store"
	case .Merged: return "merged"
	}
	return "seed"
}

bridge_provider_write_override_json :: proc(b: ^strings.Builder, override: Bridge_Provider_Override) {
	wire := bridge_provider_override_to_wire(override)
	opt := json.Marshal_Options{
		sort_maps_by_key = true,
	}
	bytes, merr := json.marshal(wire, opt, context.temp_allocator)
	if merr == nil {
		strings.write_string(b, string(bytes))
	}
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

bridge_provider_override_from_json :: proc(obj: string, allocator := context.allocator) -> (Bridge_Provider_Override, bool) {
	return bridge_provider_override_from_json_with_name(obj, "", allocator)
}

bridge_provider_override_from_json_with_name :: proc(obj, fallback_name: string, allocator := context.allocator) -> (Bridge_Provider_Override, bool) {
	wire: Bridge_Provider_Override_Wire
	if err := json.unmarshal_string(obj, &wire, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return {}, false
	}
	return bridge_provider_override_from_wire(wire, fallback_name, allocator)
}

bridge_provider_upsert_override_json :: proc(name, body: string) -> (Bridge_Provider_Profile, bool, string) {
	bridge_provider_store_init()
	override, ok := bridge_provider_override_from_json_with_name(body, name)
	if !ok do return {}, false, "provider name is required"
	if strings.trim_space(override.name) != strings.trim_space(name) && strings.trim_space(name) != "" do return {}, false, "provider name mismatch"
	if override.command_set && len(override.command) == 0 do return {}, false, "provider command must not be empty"
	candidate, candidate_ok := bridge_provider_candidate_profile(override)
	if !candidate_ok || len(candidate.command) == 0 do return {}, false, "provider command must not be empty"
	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_upsert_override_unlocked(override)
	sync.mutex_unlock(&bridge_provider_mutex)
	if !bridge_provider_save_overrides() do return {}, false, "failed to save provider override"
	profile, profile_ok := bridge_provider_by_name_or_default(override.name)
	if !profile_ok do return {}, false, "provider not found after save"
	return profile, true, ""
}

bridge_provider_candidate_profile :: proc(override: Bridge_Provider_Override) -> (Bridge_Provider_Profile, bool) {
	for seed in bridge_provider_seed_data() {
		if seed.name == override.name do return bridge_provider_apply_override(bridge_provider_profile_from_seed(seed), override), true
	}
	return bridge_provider_profile_from_override(override), true
}

bridge_provider_delete_override :: proc(name: string) -> (bool, string) {
	bridge_provider_store_init()
	trimmed := strings.trim_space(name)
	if trimmed == "" do return false, "provider name is required"
	for seed in bridge_provider_seed_data() {
		if seed.name == trimmed do return false, "deleting seed-backed providers or resetting overrides is deferred in v1"
	}
	deleted := false
	sync.mutex_lock(&bridge_provider_mutex)
	for i in 0..<len(bridge_provider_overrides) {
		if bridge_provider_overrides[i].name == trimmed {
			bridge_provider_override_destroy(&bridge_provider_overrides[i])
			ordered_remove(&bridge_provider_overrides, i)
			deleted = true
			break
		}
	}
	sync.mutex_unlock(&bridge_provider_mutex)
	if !deleted do return false, "store-only provider not found"
	if !bridge_provider_save_overrides() do return false, "failed to save provider overrides"
	return true, ""
}

// Deprecated: Retained for task_scheduler.odin until migrated to typed structs.
bridge_provider_json_extract_string :: proc(json, key, fallback: string) -> string {
	value, ok := bridge_provider_json_extract_string_set(json, key)
	if !ok do return fallback
	return value
}

// Deprecated: Retained for backward compatibility.
bridge_provider_json_extract_string_set :: proc(json, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_string_found(json, key, false, allocator)
}

// Deprecated: Retained for backward compatibility.
bridge_provider_json_extract_bool :: proc(json, key: string) -> (bool, bool) {
	return jsonx.extract_bool_found(json, key)
}

// Deprecated: Retained for backward compatibility.
bridge_provider_json_extract_int :: proc(json, key: string) -> (int, bool) {
	return jsonx.extract_int_found(json, key)
}

// Deprecated: Retained for task_scheduler.odin until migrated to typed structs.
bridge_provider_json_extract_object :: proc(json, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_object(json, key, false, allocator)
}

// Deprecated: Retained for task_scheduler.odin until migrated to typed structs.
bridge_provider_json_extract_array :: proc(json, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_array(json, key, false, allocator)
}

// Deprecated: Retained for backward compatibility.
bridge_provider_json_extract_string_array :: proc(json, key: string, allocator := context.allocator) -> ([]string, bool) {
	if !jsonx.has_key(json, key) do return nil, false
	arr := jsonx.extract_string_array(json, key, false, allocator)
	return arr[:], true
}

// Deprecated: Retained for backward compatibility.
bridge_provider_json_parse_string_array :: proc(array: string, allocator := context.allocator) -> []string {
	arr := jsonx.decode_string_array(array, allocator)
	return arr[:]
}

// Deprecated: Retained for task_scheduler.odin until migrated to typed structs.
bridge_provider_json_top_level_objects :: proc(array: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	parsed, err := json.parse_string(array, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	if err != .None do return out[:]
	arr, is_arr := parsed.(json.Array)
	if !is_arr do return out[:]
	for elem in arr {
		if _, is_obj := elem.(json.Object); is_obj {
			bytes, merr := json.marshal(elem, json.Marshal_Options{}, allocator)
			if merr == nil {
				append(&out, string(bytes))
			}
		}
	}
	return out[:]
}

bridge_clone_string_slice :: proc(values: []string, allocator := context.allocator) -> []string {
	if len(values) == 0 do return nil
	out := make([]string, len(values), allocator)
	for value, i in values do out[i] = strings.clone(value, allocator)
	return out
}

bridge_delete_string_slice :: proc(slice: []string, allocator := context.allocator) {
	if slice == nil do return
	for s in slice {
		delete(s, allocator)
	}
	delete(slice, allocator)
}

bridge_provider_override_destroy :: proc(override: ^Bridge_Provider_Override, allocator := context.allocator) {
	if override == nil do return
	if len(override.name) > 0 do delete(override.name, allocator)
	if override.command_set do bridge_delete_string_slice(override.command, allocator)
	if override.yolo_flags_set do bridge_delete_string_slice(override.yolo_flags, allocator)
	if override.prompt_flags_set do bridge_delete_string_slice(override.prompt_flags, allocator)
	if override.starter_prompt_set && len(override.starter_prompt) > 0 do delete(override.starter_prompt, allocator)
	if override.prompt_delivery_set && len(override.prompt_delivery) > 0 do delete(override.prompt_delivery, allocator)
	if override.agent_run_dir_set && len(override.agent_run_dir) > 0 do delete(override.agent_run_dir, allocator)
	if override.skill_dir_set && len(override.skill_dir) > 0 do delete(override.skill_dir, allocator)
	if override.bootstrap_file_name_set && len(override.bootstrap_file_name) > 0 do delete(override.bootstrap_file_name, allocator)
	if override.logo_set && len(override.logo) > 0 do delete(override.logo, allocator)
	if override.models_flag_set && len(override.models.flag) > 0 do delete(override.models.flag, allocator)
	if override.models_cheap_set && len(override.models.cheap) > 0 do delete(override.models.cheap, allocator)
	if override.models_normal_set && len(override.models.normal) > 0 do delete(override.models.normal, allocator)
	if override.models_smart_set && len(override.models.smart) > 0 do delete(override.models.smart, allocator)
	if override.startup_blocked_patterns_set do bridge_delete_string_slice(override.startup_detection.blocked_patterns, allocator)
	if override.startup_auto_enter_patterns_set do bridge_delete_string_slice(override.startup_detection.auto_enter_patterns, allocator)
	if override.startup_auto_enter_pre_keys_set do bridge_delete_string_slice(override.startup_detection.auto_enter_pre_keys, allocator)
	if override.startup_reason_mapping_set do bridge_delete_string_slice(override.startup_detection.sanitized_reason_mapping, allocator)
	override^ = {}
}

bridge_provider_profile_destroy :: proc(profile: ^Bridge_Provider_Profile, allocator := context.allocator) {
	if profile == nil do return
	profile^ = {}
}

bridge_provider_override_from_seed :: proc(seed: Bridge_Provider_Seed, allocator := context.allocator) -> Bridge_Provider_Override {
	override: Bridge_Provider_Override
	override.name = strings.clone(seed.name, allocator)
	override.enabled = true
	override.enabled_set = true
	override.command = bridge_clone_string_slice(seed.command, allocator)
	override.command_set = true
	if len(seed.yolo_flags) > 0 {
		override.yolo_flags = bridge_clone_string_slice(seed.yolo_flags, allocator)
		override.yolo_flags_set = true
	}
	if len(seed.prompt_flags) > 0 {
		override.prompt_flags = bridge_clone_string_slice(seed.prompt_flags, allocator)
		override.prompt_flags_set = true
	}
	if seed.starter_prompt != "" {
		override.starter_prompt = strings.clone(seed.starter_prompt, allocator)
		override.starter_prompt_set = true
	}
	if seed.prompt_delivery != "" {
		override.prompt_delivery = strings.clone(seed.prompt_delivery, allocator)
		override.prompt_delivery_set = true
	}
	if seed.skill_dir != "" {
		override.skill_dir = strings.clone(seed.skill_dir, allocator)
		override.skill_dir_set = true
	}
	if seed.bootstrap_file_name != "" {
		override.bootstrap_file_name = strings.clone(seed.bootstrap_file_name, allocator)
		override.bootstrap_file_name_set = true
	}
	if seed.logo != "" {
		override.logo = strings.clone(seed.logo, allocator)
		override.logo_set = true
	}
	if seed.models.flag != "" {
		override.models.flag = strings.clone(seed.models.flag, allocator)
		override.models_flag_set = true
	}
	if seed.models.cheap != "" {
		override.models.cheap = strings.clone(seed.models.cheap, allocator)
		override.models_cheap_set = true
	}
	if seed.models.normal != "" {
		override.models.normal = strings.clone(seed.models.normal, allocator)
		override.models_normal_set = true
	}
	if seed.models.smart != "" {
		override.models.smart = strings.clone(seed.models.smart, allocator)
		override.models_smart_set = true
	}
	if seed.startup_detection.enabled {
		override.startup_detection.enabled = true
		override.startup_enabled_set = true
		override.startup_detection.startup_probe_seconds = seed.startup_detection.startup_probe_seconds
		override.startup_probe_set = true
		override.startup_detection.capture_interval_ms = seed.startup_detection.capture_interval_ms
		override.startup_capture_set = true
		if len(seed.startup_detection.blocked_patterns) > 0 {
			override.startup_detection.blocked_patterns = bridge_clone_string_slice(seed.startup_detection.blocked_patterns, allocator)
			override.startup_blocked_patterns_set = true
		}
		if len(seed.startup_detection.auto_enter_patterns) > 0 {
			override.startup_detection.auto_enter_patterns = bridge_clone_string_slice(seed.startup_detection.auto_enter_patterns, allocator)
			override.startup_auto_enter_patterns_set = true
		}
		if len(seed.startup_detection.auto_enter_pre_keys) > 0 {
			override.startup_detection.auto_enter_pre_keys = bridge_clone_string_slice(seed.startup_detection.auto_enter_pre_keys, allocator)
			override.startup_auto_enter_pre_keys_set = true
		}
		override.startup_detection.startup_unknown_is_blocked = seed.startup_detection.startup_unknown_is_blocked
		override.startup_unknown_blocked_set = true
		if len(seed.startup_detection.sanitized_reason_mapping) > 0 {
			override.startup_detection.sanitized_reason_mapping = bridge_clone_string_slice(seed.startup_detection.sanitized_reason_mapping, allocator)
			override.startup_reason_mapping_set = true
		}
	}
	return override
}

bridge_provider_detect_supported_json :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	first := true
	for seed in bridge_provider_seed_data() {
		if !first do strings.write_byte(&b, ',')
		first = false

		bin_name := ""
		if len(seed.command) > 0 {
			bin_name = seed.command[0]
		}
		found_path := bridge_runtime_find_on_path(bin_name)
		defer delete(found_path)
		detected := found_path != ""

		strings.write_string(&b, "{\"name\":\"")
		json_write_string(&b, seed.name)
		strings.write_string(&b, "\",\"detected\":")
		strings.write_string(&b, "true" if detected else "false")
		strings.write_string(&b, ",\"path\":\"")
		if detected {
			json_write_string(&b, found_path)
		}
		strings.write_string(&b, "\"}")
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

bridge_provider_enable_selected_json :: proc(names_json: string) -> (bool, string) {
	bridge_provider_store_init()
	trimmed := strings.trim_space(names_json)
	if trimmed == "" do return false, "missing provider names"

	names: [dynamic]string
	defer delete(names)

	if strings.has_prefix(trimmed, "[") {
		decoded := jsonx.decode_string_array(trimmed, context.temp_allocator)
		for item in decoded {
			append(&names, item)
		}
	} else if strings.has_prefix(trimmed, "{") {
		arr := jsonx.extract_string_array(trimmed, "providers", false, context.temp_allocator)
		if len(arr) > 0 {
			for item in arr do append(&names, item)
		} else {
			arr2 := jsonx.extract_string_array(trimmed, "names", false, context.temp_allocator)
			for item in arr2 do append(&names, item)
		}
	}

	if len(names) == 0 {
		return false, "no valid provider names provided"
	}

	seeds := bridge_provider_seed_data()
	enabled_any := false

	sync.mutex_lock(&bridge_provider_mutex)
	for name in names {
		trimmed_name := strings.trim_space(name)
		if trimmed_name == "" do continue
		for seed in seeds {
			if strings.equal_fold(seed.name, trimmed_name) {
				override := bridge_provider_override_from_seed(seed, context.allocator)
				bridge_provider_upsert_override_unlocked(override)
				if bridge_provider_default_provider_value == "" {
					bridge_provider_default_provider_value = strings.clone(seed.name)
					bridge_provider_default_tier_value = strings.clone("normal")
				}
				enabled_any = true
				break
			}
		}
	}
	sync.mutex_unlock(&bridge_provider_mutex)

	if !enabled_any {
		return false, "none of the specified providers matched supported seeds"
	}

	if !bridge_provider_save_overrides() {
		return false, "failed to save provider overrides"
	}

	return true, ""
}

bridge_agent_runtime_profile :: proc(profile: Bridge_Provider_Profile) -> agent_runtime.Agent_Profile {
	return agent_runtime.Agent_Profile{
		command = profile.command,
		yolo_flags = profile.yolo_flags,
		prompt_flags = profile.prompt_flags,
		starter_prompt = profile.starter_prompt,
		prompt_delivery = profile.prompt_delivery,
		prompt_tmux_delay_ms = profile.prompt_tmux_delay_ms,
		prompt_tmux_enter = profile.prompt_tmux_enter,
		models = profile.models,
		startup_detection = profile.startup_detection,
		activity_detection = profile.activity_detection,
	}
}

bridge_runtime_agent_argv_for_profile :: proc(profile: Bridge_Provider_Profile, tier, agent_token, agent_instance_id: string) -> []string {
	resolved_tier := tier
	if strings.trim_space(resolved_tier) == "" do resolved_tier = bridge_provider_default_tier(profile)
	argv := agent_runtime.build_agent_command(bridge_agent_runtime_profile(profile), resolved_tier, bridge_config.daemon_url, agent_token, agent_instance_id)
	if len(argv) > 0 {
		argv[0] = bridge_runtime_resolve_provider_executable(argv[0])
	}
	return argv
}

bridge_runtime_resolve_provider_executable :: proc(command: string) -> string {
	trimmed := strings.trim_space(command)
	if trimmed == "" do return command
	if strings.contains(trimmed, "/") {
		expanded := bridge_expand_home(trimmed)
		if absolute, err := os.get_absolute_path(expanded, context.allocator); err == nil && strings.trim_space(absolute) != "" do return absolute
		return expanded
	}
	if found := bridge_runtime_find_on_path(trimmed); found != "" do return found
	return command
}

bridge_runtime_shell_command_for_profile :: proc(profile: Bridge_Provider_Profile, tier, agent_token, agent_instance_id: string) -> string {
	argv := bridge_runtime_agent_argv_for_profile(profile, tier, agent_token, agent_instance_id)
	return bridge_shell_join(argv)
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
	out, _ = strings.replace_all(out, "{ctl_bin}", "./.heimdall/bin/ham-ctl")
	out, _ = strings.replace_all(out, strings.concatenate({"./.heimdall/bin/ham-ctl --token ", agent_token, " start-success"}), "./.heimdall/bin/ham-ctl agent start-success")
	out, _ = strings.replace_all(out, "ham-ctl --token ", "./.heimdall/bin/ham-ctl --token ")
	out, _ = strings.replace_all(out, "ham-ctl start-success", "./.heimdall/bin/ham-ctl agent start-success")
	out = strings.concatenate({out, "\n\nHeimdall runtime: use `./.heimdall/bin/ham-ctl` for CLI actions. Your agent token is `", agent_token, "` and your agent instance id is `", agent_instance_id, "`; they are also available in HEIMDALL_AGENT_TOKEN and HEIMDALL_AGENT_INSTANCE_ID."})
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

bridge_provider_startup_log :: proc() {
	profiles := bridge_effective_provider_profiles()
	defer delete(profiles)
	b := strings.builder_make()
	strings.write_string(&b, "bridge providers: ")
	strings.write_string(&b, fmt.tprintf("%d detected [", len(profiles)))
	for profile, i in profiles {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, profile.name)
		strings.write_byte(&b, '(')
		strings.write_string(&b, bridge_provider_source_string(profile.source))
		if profile.has_override do strings.write_string(&b, "/auto")
		strings.write_byte(&b, ')')
	}
	strings.write_byte(&b, ']')
	fmt.println(strings.to_string(b))
}
