package main

import cfg_lib "odin_test:lib/config"

Bridge_Provider_Seed :: struct {
	name:                string,
	logo:                string,
	command:             []string,
	prompt_flags:        []string,
	yolo_flags:          []string,
	starter_prompt:      string,
	prompt_delivery:     string,
	skill_dir:           string,
	bootstrap_file_name: string,
	models:              cfg_lib.Model_Tiers_Config,
	startup_detection:   cfg_lib.Startup_Detection_Config,
}

BRIDGE_PROVIDER_SEEDS := [?]Bridge_Provider_Seed{
	{
		name = "claude",
		logo = "claude",
		command = {"claude"},
		yolo_flags = {"--dangerously-skip-permissions"},
		starter_prompt = "First, run: {ctl_bin} agent start-success. Then read your bootstrap file (CLAUDE.md) for context, identity, and what you can do.",
		skill_dir = ".claude/skills",
		bootstrap_file_name = "CLAUDE.md",
		models = cfg_lib.Model_Tiers_Config{
			flag   = "--model",
			cheap  = "claude-sonnet-4-8",
			normal = "claude-opus-5",
			smart  = "claude-fable-5",
		},
		startup_detection = cfg_lib.Startup_Detection_Config{
			enabled = true,
			startup_probe_seconds = 20,
			capture_interval_ms = 500,
			auto_enter_patterns = {"Yes, I trust this folder"},
			auto_enter_pre_keys = {"Down"},
			startup_unknown_is_blocked = false,
			sanitized_reason_mapping = {"trust=Claude Code directory trust prompt"},
		},
	},
	{
		name = "codex",
		logo = "codex",
		command = {"codex"},
		yolo_flags = {"--approval-policy=never"},
		starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.",
		skill_dir = ".codex/skills",
		bootstrap_file_name = "AGENTS.md",
		models = cfg_lib.Model_Tiers_Config{
			flag   = "-m",
			cheap  = "gpt-4o-mini",
			normal = "gpt-4o",
			smart  = "gpt-5-pro",
		},
		startup_detection = cfg_lib.Startup_Detection_Config{
			enabled = true,
			startup_probe_seconds = 20,
			capture_interval_ms = 500,
			auto_enter_patterns = {"Allow for this session"},
			startup_unknown_is_blocked = false,
		},
	},
	{
		name = "copilot",
		logo = "copilot",
		command = {"copilot"},
		starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.",
		skill_dir = ".copilot/skills",
		bootstrap_file_name = "AGENTS.md",
		models = cfg_lib.Model_Tiers_Config{
			flag   = "--model",
			cheap  = "claude-sonnet-4.6",
			normal = "claude-sonnet-4.6",
			smart  = "claude-opus-4.6",
		},
		startup_detection = cfg_lib.Startup_Detection_Config{
			enabled = true,
			startup_probe_seconds = 15,
			capture_interval_ms = 500,
			startup_unknown_is_blocked = false,
		},
	},
	{
		name = "antigravity",
		logo = "antigravity",
		command = {"agy"},
		starter_prompt = "First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.",
		skill_dir = ".agents/skills",
		bootstrap_file_name = "AGENTS.md",
		models = cfg_lib.Model_Tiers_Config{
			flag   = "--model",
			cheap  = "Gemini 3.5 Flash (Medium)",
			normal = "Gemini 3.5 Flash (Medium)",
			smart  = "Gemini 3.1 Pro (High)",
		},
		startup_detection = cfg_lib.Startup_Detection_Config{
			enabled = true,
			startup_probe_seconds = 20,
			capture_interval_ms = 500,
			startup_unknown_is_blocked = false,
		},
	},
}

bridge_provider_seed_data :: proc() -> []Bridge_Provider_Seed {
	return BRIDGE_PROVIDER_SEEDS[:]
}
