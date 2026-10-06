package main

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import cfg_lib "odin_test:lib/config"

@(private = "file")
provider_test_dir :: proc(name: string) -> string {
	return strings.concatenate({"/tmp/ham-provider-test-", name})
}

@(private = "file")
provider_test_cleanup :: proc(data_dir: string) {
	file_path := strings.concatenate({data_dir, "/bridge/providers.json"})
	tmp_path := strings.concatenate({file_path, ".tmp"})
	defer delete(file_path)
	defer delete(tmp_path)
	_ = os.remove(tmp_path)
	_ = os.remove(file_path)
	bdir := strings.concatenate({data_dir, "/bridge"})
	defer delete(bdir)
	_ = os.remove(bdir)
	_ = os.remove(data_dir)
}

// REQ-P2-PROVIDER: Round-trip serialization for all override fields.
@(test)
test_provider_store_roundtrip_all_fields :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	dir := provider_test_dir("roundtrip-all")
	defer delete(dir)
	defer provider_test_cleanup(dir)

	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	store_path := strings.concatenate({dir, "/bridge/providers.json"})
	defer delete(store_path)

	orig := Bridge_Provider_Override{
		name                    = strings.clone("custom-provider"),
		enabled                 = true,
		enabled_set             = true,
		command                 = bridge_clone_string_slice([]string{"custom-bin", "--verbose"}),
		command_set             = true,
		yolo_flags              = bridge_clone_string_slice([]string{"--danger", "--auto"}),
		yolo_flags_set          = true,
		prompt_flags            = bridge_clone_string_slice([]string{"--prompt", "-p"}),
		prompt_flags_set        = true,
		starter_prompt          = strings.clone("hello provider"),
		starter_prompt_set      = true,
		prompt_delivery         = strings.clone("tmux"),
		prompt_delivery_set     = true,
		prompt_tmux_delay_ms    = 250,
		prompt_tmux_delay_ms_set= true,
		prompt_tmux_enter       = true,
		prompt_tmux_enter_set   = true,
		agent_run_dir           = strings.clone("/tmp/custom_run"),
		agent_run_dir_set       = true,
		use_random_dir          = true,
		use_random_dir_set      = true,
		skill_dir               = strings.clone("skills_v2"),
		skill_dir_set           = true,
		bootstrap_file_name     = strings.clone("AGENT_CUSTOM.md"),
		bootstrap_file_name_set = true,
		logo                    = strings.clone("custom_logo.png"),
		logo_set                = true,
		models                  = cfg_lib.Model_Tiers_Config{
			flag   = strings.clone("--model"),
			cheap  = strings.clone("model-cheap"),
			normal = strings.clone("model-normal"),
			smart  = strings.clone("model-smart"),
		},
		models_flag_set         = true,
		models_cheap_set        = true,
		models_normal_set       = true,
		models_smart_set        = true,
		startup_detection       = cfg_lib.Startup_Detection_Config{
			enabled                    = true,
			startup_probe_seconds      = 12,
			capture_interval_ms        = 350,
			blocked_patterns           = bridge_clone_string_slice([]string{"[Blocked]", "Access denied"}),
			auto_enter_patterns        = bridge_clone_string_slice([]string{"Press Enter", "Select [Y/n]"}),
			auto_enter_pre_keys        = bridge_clone_string_slice([]string{"Down", ""}),
			startup_unknown_is_blocked = true,
			sanitized_reason_mapping   = bridge_clone_string_slice([]string{"auth_failure", "eacces"}),
		},
		startup_enabled_set             = true,
		startup_probe_set               = true,
		startup_capture_set             = true,
		startup_blocked_patterns_set    = true,
		startup_auto_enter_patterns_set = true,
		startup_auto_enter_pre_keys_set = true,
		startup_unknown_blocked_set     = true,
		startup_reason_mapping_set      = true,
		activity_detection              = cfg_lib.Activity_Detection_Config{
			enabled                = true,
			sample_line_count      = 15,
			ignore_bottom_lines    = 3,
			check_interval_seconds = 4,
			min_gap_ms             = 120,
			max_gap_ms             = 2500,
		},
		activity_enabled_set        = true,
		activity_sample_lines_set   = true,
		activity_ignore_bottom_set  = true,
		activity_check_interval_set = true,
		activity_min_gap_set        = true,
		activity_max_gap_set        = true,
	}

	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_store_path_value = strings.clone(store_path)
	bridge_provider_default_provider_value = strings.clone("custom-provider")
	bridge_provider_default_tier_value = strings.clone("smart")
	bridge_provider_store_loaded = true
	bridge_provider_upsert_override_unlocked(orig)
	sync.mutex_unlock(&bridge_provider_mutex)

	saved := bridge_provider_save_overrides()
	testing.expect(t, saved, "save_overrides should succeed")

	// Verify file was written and can be read
	raw, rerr := os.read_entire_file(store_path, context.allocator)
	testing.expect(t, rerr == nil, "file should exist on disk")
	defer delete(raw)

	// Reset in-memory state and reload from disk
	bridge_provider_test_reset()

	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_store_path_value = strings.clone(store_path)
	bridge_provider_store_loaded = true
	bridge_provider_load_unlocked()
	sync.mutex_unlock(&bridge_provider_mutex)

	testing.expect_value(t, bridge_provider_default_provider_value, "custom-provider")
	testing.expect_value(t, bridge_provider_default_tier_value, "smart")
	testing.expect_value(t, len(bridge_provider_overrides), 1)

	if len(bridge_provider_overrides) != 1 do return
	loaded := bridge_provider_overrides[0]

	// Verify all basic string and bool fields
	testing.expect_value(t, loaded.name, "custom-provider")
	testing.expect_value(t, loaded.enabled, true)
	testing.expect_value(t, loaded.enabled_set, true)
	testing.expect_value(t, loaded.command_set, true)
	testing.expect_value(t, len(loaded.command), 2)
	testing.expect_value(t, loaded.command[0], "custom-bin")
	testing.expect_value(t, loaded.command[1], "--verbose")
	testing.expect_value(t, loaded.yolo_flags_set, true)
	testing.expect_value(t, len(loaded.yolo_flags), 2)
	testing.expect_value(t, loaded.prompt_flags_set, true)
	testing.expect_value(t, len(loaded.prompt_flags), 2)
	testing.expect_value(t, loaded.starter_prompt, "hello provider")
	testing.expect_value(t, loaded.starter_prompt_set, true)
	testing.expect_value(t, loaded.prompt_delivery, "tmux")
	testing.expect_value(t, loaded.prompt_delivery_set, true)
	testing.expect_value(t, loaded.prompt_tmux_delay_ms, 250)
	testing.expect_value(t, loaded.prompt_tmux_delay_ms_set, true)
	testing.expect_value(t, loaded.prompt_tmux_enter, true)
	testing.expect_value(t, loaded.prompt_tmux_enter_set, true)
	testing.expect_value(t, loaded.agent_run_dir, "/tmp/custom_run")
	testing.expect_value(t, loaded.agent_run_dir_set, true)
	testing.expect_value(t, loaded.use_random_dir, true)
	testing.expect_value(t, loaded.use_random_dir_set, true)
	testing.expect_value(t, loaded.skill_dir, "skills_v2")
	testing.expect_value(t, loaded.skill_dir_set, true)
	testing.expect_value(t, loaded.bootstrap_file_name, "AGENT_CUSTOM.md")
	testing.expect_value(t, loaded.bootstrap_file_name_set, true)
	testing.expect_value(t, loaded.logo, "custom_logo.png")
	testing.expect_value(t, loaded.logo_set, true)

	// Verify model tiers
	testing.expect_value(t, loaded.models_flag_set, true)
	testing.expect_value(t, loaded.models.flag, "--model")
	testing.expect_value(t, loaded.models_cheap_set, true)
	testing.expect_value(t, loaded.models.cheap, "model-cheap")
	testing.expect_value(t, loaded.models_normal_set, true)
	testing.expect_value(t, loaded.models.normal, "model-normal")
	testing.expect_value(t, loaded.models_smart_set, true)
	testing.expect_value(t, loaded.models.smart, "model-smart")

	// Verify startup detection
	testing.expect_value(t, loaded.startup_enabled_set, true)
	testing.expect_value(t, loaded.startup_detection.enabled, true)
	testing.expect_value(t, loaded.startup_probe_set, true)
	testing.expect_value(t, loaded.startup_detection.startup_probe_seconds, 12)
	testing.expect_value(t, loaded.startup_capture_set, true)
	testing.expect_value(t, loaded.startup_detection.capture_interval_ms, 350)
	testing.expect_value(t, loaded.startup_blocked_patterns_set, true)
	testing.expect_value(t, len(loaded.startup_detection.blocked_patterns), 2)
	testing.expect_value(t, loaded.startup_detection.blocked_patterns[0], "[Blocked]")
	testing.expect_value(t, loaded.startup_auto_enter_patterns_set, true)
	testing.expect_value(t, len(loaded.startup_detection.auto_enter_patterns), 2)
	testing.expect_value(t, loaded.startup_auto_enter_pre_keys_set, true)
	testing.expect_value(t, len(loaded.startup_detection.auto_enter_pre_keys), 2)
	testing.expect_value(t, loaded.startup_detection.auto_enter_pre_keys[0], "Down")
	testing.expect_value(t, loaded.startup_unknown_blocked_set, true)
	testing.expect_value(t, loaded.startup_detection.startup_unknown_is_blocked, true)
	testing.expect_value(t, loaded.startup_reason_mapping_set, true)
	testing.expect_value(t, len(loaded.startup_detection.sanitized_reason_mapping), 2)

	// Verify activity detection
	testing.expect_value(t, loaded.activity_enabled_set, true)
	testing.expect_value(t, loaded.activity_detection.enabled, true)
	testing.expect_value(t, loaded.activity_sample_lines_set, true)
	testing.expect_value(t, loaded.activity_detection.sample_line_count, 15)
	testing.expect_value(t, loaded.activity_ignore_bottom_set, true)
	testing.expect_value(t, loaded.activity_detection.ignore_bottom_lines, 3)
	testing.expect_value(t, loaded.activity_check_interval_set, true)
	testing.expect_value(t, loaded.activity_detection.check_interval_seconds, 4)
	testing.expect_value(t, loaded.activity_min_gap_set, true)
	testing.expect_value(t, loaded.activity_detection.min_gap_ms, 120)
	testing.expect_value(t, loaded.activity_max_gap_set, true)
	testing.expect_value(t, loaded.activity_detection.max_gap_ms, 2500)
}

// REQ-P2-PROVIDER: Partial override preservation and omitempty behavior.
@(test)
test_provider_store_partial_override_preservation :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	dir := provider_test_dir("partial-override")
	defer delete(dir)
	defer provider_test_cleanup(dir)

	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	store_path := strings.concatenate({dir, "/bridge/providers.json"})
	defer delete(store_path)

	orig := Bridge_Provider_Override{
		name        = strings.clone("partial-provider"),
		enabled     = false,
		enabled_set = true,
	}

	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_store_path_value = strings.clone(store_path)
	bridge_provider_store_loaded = true
	bridge_provider_upsert_override_unlocked(orig)
	sync.mutex_unlock(&bridge_provider_mutex)

	saved := bridge_provider_save_overrides()
	testing.expect(t, saved, "save_overrides should succeed")

	// Read serialized content directly to verify omitted fields are NOT written
	raw, rerr := os.read_entire_file(store_path, context.allocator)
	testing.expect(t, rerr == nil, "file should exist")
	defer delete(raw)
	body := string(raw)

	// "enabled": false should be present
	testing.expect(t, strings.contains(body, "\"enabled\": false") || strings.contains(body, "\"enabled\":false"), "enabled: false must be serialized")
	// Unset fields must NOT be in JSON
	testing.expect(t, !strings.contains(body, "\"command\""), "unset command must not be serialized")
	testing.expect(t, !strings.contains(body, "\"models\""), "unset models must not be serialized")
	testing.expect(t, !strings.contains(body, "\"startup_detection\""), "unset startup_detection must not be serialized")
	testing.expect(t, !strings.contains(body, "\"activity_detection\""), "unset activity_detection must not be serialized")

	// Reload and verify partial flags
	bridge_provider_test_reset()

	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_store_path_value = strings.clone(store_path)
	bridge_provider_store_loaded = true
	bridge_provider_load_unlocked()
	sync.mutex_unlock(&bridge_provider_mutex)

	testing.expect_value(t, len(bridge_provider_overrides), 1)
	if len(bridge_provider_overrides) != 1 do return
	loaded := bridge_provider_overrides[0]

	testing.expect_value(t, loaded.name, "partial-provider")
	testing.expect_value(t, loaded.enabled, false)
	testing.expect_value(t, loaded.enabled_set, true)
	testing.expect_value(t, loaded.command_set, false)
	testing.expect_value(t, loaded.models_smart_set, false)
	testing.expect_value(t, loaded.startup_enabled_set, false)
	testing.expect_value(t, loaded.activity_enabled_set, false)
}

// REQ-P2-PROVIDER: Model tiers partial override and resolution.
@(test)
test_provider_store_model_tiers_and_resolution :: proc(t: ^testing.T) {
	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	json_payload := `{"name": "tier-test", "models": {"smart": "claude-3-5-sonnet", "cheap": "claude-3-haiku"}}`
	override, ok := bridge_provider_override_from_json_with_name(json_payload, "tier-test")
	testing.expect(t, ok, "override from json should succeed")
	defer bridge_provider_override_destroy(&override)

	testing.expect_value(t, override.name, "tier-test")
	testing.expect_value(t, override.models_smart_set, true)
	testing.expect_value(t, override.models.smart, "claude-3-5-sonnet")
	testing.expect_value(t, override.models_cheap_set, true)
	testing.expect_value(t, override.models.cheap, "claude-3-haiku")
	testing.expect_value(t, override.models_normal_set, false)
	testing.expect_value(t, override.models_flag_set, false)

	// Apply on top of a seed profile
	base_profile := Bridge_Provider_Profile{
		name   = "tier-test",
		models = cfg_lib.Model_Tiers_Config{
			flag   = "--model",
			normal = "seed-normal",
			cheap  = "seed-cheap",
		},
	}
	merged := bridge_provider_apply_override(base_profile, override)

	testing.expect_value(t, merged.models.flag, "--model")
	testing.expect_value(t, merged.models.normal, "seed-normal") // Preserved from seed
	testing.expect_value(t, merged.models.cheap, "claude-3-haiku") // Overridden
	testing.expect_value(t, merged.models.smart, "claude-3-5-sonnet") // Added by override
}

// REQ-P2-PROVIDER: Pattern arrays and auto-enter pre-keys in startup detection.
@(test)
test_provider_store_pattern_arrays_and_keys :: proc(t: ^testing.T) {
	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	json_payload := `
	{
		"name": "pattern-agent",
		"startup_detection": {
			"enabled": true,
			"blocked_patterns": ["Pattern 1", "Pattern 2: [A-Z]+"],
			"auto_enter_patterns": ["Continue? (Y/n)", "Confirm:"],
			"auto_enter_pre_keys": ["Down", "Tab"]
		}
	}
	`
	override, ok := bridge_provider_override_from_json(json_payload)
	testing.expect(t, ok, "should unmarshal successfully")
	defer bridge_provider_override_destroy(&override)

	testing.expect_value(t, override.name, "pattern-agent")
	testing.expect_value(t, override.startup_enabled_set, true)
	testing.expect_value(t, override.startup_detection.enabled, true)
	testing.expect_value(t, override.startup_blocked_patterns_set, true)
	testing.expect_value(t, len(override.startup_detection.blocked_patterns), 2)
	testing.expect_value(t, override.startup_detection.blocked_patterns[1], "Pattern 2: [A-Z]+")
	testing.expect_value(t, override.startup_auto_enter_patterns_set, true)
	testing.expect_value(t, len(override.startup_detection.auto_enter_patterns), 2)
	testing.expect_value(t, override.startup_auto_enter_pre_keys_set, true)
	testing.expect_value(t, len(override.startup_detection.auto_enter_pre_keys), 2)
	testing.expect_value(t, override.startup_detection.auto_enter_pre_keys[0], "Down")
	testing.expect_value(t, override.startup_detection.auto_enter_pre_keys[1], "Tab")
}

// REQ-P2-PROVIDER: Backward compatibility with legacy providers.json disk format.
@(test)
test_provider_store_backward_compatibility :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	dir := provider_test_dir("legacy-compat")
	defer delete(dir)
	defer provider_test_cleanup(dir)

	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	store_path := strings.concatenate({dir, "/bridge/providers.json"})
	defer delete(store_path)

	bdir := strings.concatenate({dir, "/bridge"})
	defer delete(bdir)
	_ = os.make_directory_all(bdir)

	legacy_json := `
	{
		"default_provider": "legacy-cli",
		"default_tier": "normal",
		"providers": [
			{
				"name": "legacy-cli",
				"enabled": true,
				"command": ["legacy-agent", "--worker"],
				"prompt_flags": ["--task"],
				"models": {
					"normal": "legacy-gpt-4o"
				}
			}
		]
	}
	`
	werr := os.write_entire_file(store_path, transmute([]byte)legacy_json)
	testing.expect(t, werr == nil, "write legacy fixture")

	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_store_path_value = strings.clone(store_path)
	bridge_provider_store_loaded = true
	bridge_provider_load_unlocked()
	sync.mutex_unlock(&bridge_provider_mutex)

	testing.expect_value(t, bridge_provider_default_provider_value, "legacy-cli")
	testing.expect_value(t, bridge_provider_default_tier_value, "normal")
	testing.expect_value(t, len(bridge_provider_overrides), 1)

	if len(bridge_provider_overrides) != 1 do return
	p := bridge_provider_overrides[0]
	testing.expect_value(t, p.name, "legacy-cli")
	testing.expect_value(t, p.enabled, true)
	testing.expect_value(t, p.command_set, true)
	testing.expect_value(t, len(p.command), 2)
	testing.expect_value(t, p.command[0], "legacy-agent")
	testing.expect_value(t, p.models_normal_set, true)
	testing.expect_value(t, p.models.normal, "legacy-gpt-4o")
}

// REQ-P2-PROVIDER: JSON parsing edge cases (fallback name, invalid syntax, empty command).
@(test)
test_provider_override_edge_cases :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	// Fallback name when name not in JSON
	payload := `{"enabled": true, "starter_prompt": "test"}`
	override, ok := bridge_provider_override_from_json_with_name(payload, "fallback-agent")
	testing.expect(t, ok, "fallback name should be accepted")
	testing.expect_value(t, override.name, "fallback-agent")
	testing.expect_value(t, override.starter_prompt, "test")
	bridge_provider_override_destroy(&override)

	// Missing name with empty fallback -> fail
	_, nok := bridge_provider_override_from_json_with_name(payload, "")
	testing.expect(t, !nok, "missing name must return false")

	// Invalid JSON -> fail cleanly
	_, bad_ok := bridge_provider_override_from_json_with_name("{invalid json: not closed", "any")
	testing.expect(t, !bad_ok, "invalid JSON must return false")

	// Upsert validation: empty provider name rejected
	_, name_ok, _ := bridge_provider_upsert_override_json("", `{"command": ["x"]}`)
	testing.expect(t, !name_ok, "empty provider name should be rejected")

	// Upsert validation: name mismatch rejected
	_, mismatch_ok, _ := bridge_provider_upsert_override_json("agent-a", `{"name": "agent-b", "command": ["x"]}`)
	testing.expect(t, !mismatch_ok, "name mismatch should be rejected")

	// Upsert validation: empty command slice rejected
	_, empty_cmd_ok, _ := bridge_provider_upsert_override_json("agent-c", `{"name": "agent-c", "command": []}`)
	testing.expect(t, !empty_cmd_ok, "empty command should be rejected")
}

// REQ-P2-PROVIDER: Zero tracking allocator leaks during unmarshal and lifecycle.
@(test)
test_provider_store_zero_tracking_allocator_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m_allocator := mem.tracking_allocator(&track)

	json_payload := `
	{
		"name": "leak-free-agent",
		"enabled": true,
		"command": ["bin1", "bin2"],
		"yolo_flags": ["--yolo"],
		"prompt_flags": ["--prompt"],
		"starter_prompt": "hello world",
		"prompt_delivery": "tmux",
		"agent_run_dir": "/tmp/custom_dir",
		"skill_dir": "custom_skills",
		"bootstrap_file_name": "BOOTSTRAP.md",
		"logo": "logo.svg",
		"models": {
			"flag": "--model",
			"cheap": "m-cheap",
			"normal": "m-normal",
			"smart": "m-smart"
		},
		"startup_detection": {
			"enabled": true,
			"blocked_patterns": ["err1", "err2"],
			"auto_enter_patterns": ["enter1"],
			"auto_enter_pre_keys": ["pre1"],
			"sanitized_reason_mapping": ["reason1"]
		},
		"activity_detection": {
			"enabled": true,
			"sample_line_count": 10
		}
	}
	`

	override, ok := bridge_provider_override_from_json_with_name(json_payload, "leak-free-agent", m_allocator)
	testing.expect(t, ok, "unmarshal should succeed")

	// Verify fields allocated properly
	testing.expect_value(t, override.name, "leak-free-agent")
	testing.expect_value(t, len(override.command), 2)
	testing.expect_value(t, override.models.smart, "m-smart")

	// Destroy override against the same tracking allocator
	bridge_provider_override_destroy(&override, m_allocator)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// REQ-PROVIDER-ADDITIVE-1: Verify seed.models are copied to profiles and capabilities produces non-empty tiers.
@(test)
test_provider_seeds_models_and_capabilities :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	profiles := bridge_effective_provider_profiles()
	defer delete(profiles)

	testing.expect(t, len(profiles) >= 4, "expected at least 4 default seed profiles")

	found_claude := false
	found_codex := false
	found_antigravity := false
	found_copilot := false

	for &profile in profiles {
		switch profile.name {
		case "claude":
			found_claude = true
			testing.expect_value(t, profile.models.flag, "--model")
			testing.expect_value(t, profile.models.cheap, "claude-3-5-haiku-latest")
			testing.expect_value(t, profile.models.normal, "claude-3-5-sonnet-latest")
			testing.expect_value(t, profile.models.smart, "claude-3-7-sonnet-latest")
		case "codex":
			found_codex = true
			testing.expect_value(t, profile.models.flag, "-m")
			testing.expect_value(t, profile.models.cheap, "gpt-4o-mini")
			testing.expect_value(t, profile.models.normal, "gpt-4o")
			testing.expect_value(t, profile.models.smart, "gpt-5-pro")
		case "antigravity":
			found_antigravity = true
			testing.expect_value(t, profile.models.flag, "--model")
			testing.expect_value(t, profile.models.cheap, "Gemini 3.5 Flash (Medium)")
			testing.expect_value(t, profile.models.normal, "Gemini 3.5 Flash (Medium)")
			testing.expect_value(t, profile.models.smart, "Gemini 3.1 Pro (High)")
		case "copilot":
			found_copilot = true
			testing.expect_value(t, profile.models.flag, "--model")
			testing.expect_value(t, profile.models.cheap, "claude-sonnet-4.6")
			testing.expect_value(t, profile.models.normal, "claude-sonnet-4.6")
			testing.expect_value(t, profile.models.smart, "claude-opus-4.6")
		}
	}

	testing.expect(t, found_claude, "claude profile must be present")
	testing.expect(t, found_codex, "codex profile must be present")
	testing.expect(t, found_antigravity, "antigravity profile must be present")
	testing.expect(t, found_copilot, "copilot profile must be present")

	// Test profile destroy helper
	profile_copy := profiles[0]
	bridge_provider_profile_destroy(&profile_copy)

	// Capabilities must be non-empty and report all tiers
	caps_json := bridge_provider_capabilities_json()
	defer delete(caps_json)
	testing.expect(t, caps_json != "[]", "capabilities should not be empty")
	testing.expect(t, strings.contains(caps_json, "claude"), "capabilities must include claude")
	testing.expect(t, strings.contains(caps_json, "cheap"), "capabilities must include cheap tier")
	testing.expect(t, strings.contains(caps_json, "normal"), "capabilities must include normal tier")
	testing.expect(t, strings.contains(caps_json, "smart"), "capabilities must include smart tier")
}

// REQ-PROVIDER-ADDITIVE-1: Test detect_supported_providers
@(test)
test_provider_detect_supported_json :: proc(t: ^testing.T) {
	detected_json := bridge_provider_detect_supported_json()
	defer delete(detected_json)

	testing.expect(t, strings.has_prefix(detected_json, "["), "detected_json must be an array")
	testing.expect(t, strings.has_suffix(detected_json, "]"), "detected_json must be an array")
	testing.expect(t, strings.contains(detected_json, "\"name\":\"claude\""), "must contain claude")
	testing.expect(t, strings.contains(detected_json, "\"name\":\"codex\""), "must contain codex")
	testing.expect(t, strings.contains(detected_json, "\"name\":\"antigravity\""), "must contain antigravity")
	testing.expect(t, strings.contains(detected_json, "\"name\":\"copilot\""), "must contain copilot")
	testing.expect(t, strings.contains(detected_json, "\"detected\":"), "must contain detected field")
	testing.expect(t, strings.contains(detected_json, "\"path\":"), "must contain path field")

	parsed, err := json.parse_string(detected_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect(t, err == .None, "detected_json must be valid JSON")
	arr, is_arr := parsed.(json.Array)
	testing.expect(t, is_arr, "parsed value must be array")
	testing.expect_value(t, len(arr), 4)
}

// REQ-PROVIDER-ADDITIVE-1: Test enable_providers
@(test)
test_provider_enable_selected_json :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	dir := provider_test_dir("enable-selected")
	defer delete(dir)
	defer provider_test_cleanup(dir)

	bridge_provider_test_reset()
	defer bridge_provider_test_reset()

	store_path := strings.concatenate({dir, "/bridge/providers.json"})
	defer delete(store_path)

	sync.mutex_lock(&bridge_provider_mutex)
	bridge_provider_store_path_value = strings.clone(store_path)
	bridge_provider_store_loaded = true
	sync.mutex_unlock(&bridge_provider_mutex)

	// Test array form: ["claude", "antigravity"]
	ok, msg := bridge_provider_enable_selected_json(`["claude", "antigravity"]`)
	testing.expect(t, ok, msg)

	// Verify overrides were added and saved
	sync.mutex_lock(&bridge_provider_mutex)
	claude_override, claude_ok := bridge_provider_override_for_name_unlocked("claude")
	agy_override, agy_ok := bridge_provider_override_for_name_unlocked("antigravity")
	sync.mutex_unlock(&bridge_provider_mutex)

	testing.expect(t, claude_ok, "claude override must exist")
	testing.expect_value(t, claude_override.enabled, true)
	testing.expect_value(t, claude_override.models.normal, "claude-3-5-sonnet-latest")

	testing.expect(t, agy_ok, "antigravity override must exist")
	testing.expect_value(t, agy_override.enabled, true)
	testing.expect_value(t, agy_override.models.cheap, "Gemini 3.5 Flash (Medium)")

	// Test object form: {"providers": ["codex"]}
	ok_obj, msg_obj := bridge_provider_enable_selected_json(`{"providers": ["codex"]}`)
	testing.expect(t, ok_obj, msg_obj)

	sync.mutex_lock(&bridge_provider_mutex)
	codex_override, codex_ok := bridge_provider_override_for_name_unlocked("codex")
	sync.mutex_unlock(&bridge_provider_mutex)

	testing.expect(t, codex_ok, "codex override must exist")
	testing.expect_value(t, codex_override.enabled, true)
	testing.expect_value(t, codex_override.models.flag, "-m")
	testing.expect_value(t, codex_override.models.smart, "gpt-5-pro")

	// Invalid input handling
	bad_ok, _ := bridge_provider_enable_selected_json(`["nonexistent_tool_xyz"]`)
	testing.expect(t, !bad_ok, "unknown provider should fail")
}

// REQ-PROVIDER-ADDITIVE-1: Target for verification command:
// odin test src/bridge -define:ODIN_TEST_NAMES=main.test_provider
@(test)
test_provider :: proc(t: ^testing.T) {
	test_provider_seeds_models_and_capabilities(t)
	test_provider_detect_supported_json(t)
	test_provider_enable_selected_json(t)
}
