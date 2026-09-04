package agent_runtime

import "core:fmt"
import "core:strings"
import "core:time"
import cfg_lib "odin_test:lib/config"
import tmux "odin_test:lib/tmux"

Agent_Profile :: struct {
	command: []string,
	yolo_flags: []string,
	prompt_flags: []string,
	starter_prompt: string,
	prompt_delivery: string,
	prompt_tmux_delay_ms: int,
	prompt_tmux_enter: bool,
	models: cfg_lib.Model_Tiers_Config,
	startup_detection: cfg_lib.Startup_Detection_Config,
	activity_detection: cfg_lib.Activity_Detection_Config,
}

Startup_Probe_Result :: struct { status: string, detail: string }
Activity_Sample :: struct { status: string, source: string }

build_agent_command :: proc(profile: Agent_Profile, tier, daemon_url, agent_token, agent_instance_id: string) -> []string {
	argv := make([dynamic]string)
	append(&argv, ..profile.command)
	append(&argv, ..profile.yolo_flags)
	if profile.models.flag != "" {
		model := cfg_lib.resolve_model_value(profile.models, tier)
		if model != "" {
			append(&argv, profile.models.flag)
			append(&argv, model)
		}
	}
	if prompt_delivery(profile) == "flag-injection" {
		prompt := render_starter_prompt_for_agent(profile, daemon_url, agent_token, agent_instance_id)
		if strings.trim_space(prompt) != "" {
			append(&argv, ..profile.prompt_flags)
			append(&argv, prompt)
		}
	}
	return argv[:]
}

prompt_delivery :: proc(profile: Agent_Profile) -> string {
	delivery := profile.prompt_delivery
	if delivery == "tmux" || delivery == "none" || delivery == "flag-injection" do return delivery
	return "flag-injection"
}

render_starter_prompt_for_agent :: proc(profile: Agent_Profile, daemon_url, agent_token, agent_instance_id: string) -> string {
	out := profile.starter_prompt
	if strings.trim_space(out) == "" do return ""
	out, _ = strings.replace_all(out, "{ctl_bin} --token {token} start-success", "{ctl_bin} agent start-success")
	out, _ = strings.replace_all(out, "{ctl_bin} start-success", "{ctl_bin} agent start-success")
	out, _ = strings.replace_all(out, "{token}", agent_token)
	out, _ = strings.replace_all(out, "{agent_token}", agent_token)
	out, _ = strings.replace_all(out, "{instance}", agent_instance_id)
	out, _ = strings.replace_all(out, "{agent_instance_id}", agent_instance_id)
	out, _ = strings.replace_all(out, "{daemon_url}", daemon_url)
	out, _ = strings.replace_all(out, "{ctl_bin}", "./.heimdall/bin/ham-ctl")
	out, _ = strings.replace_all(out, strings.concatenate({"./.heimdall/bin/ham-ctl --token ", agent_token, " start-success"}), "./.heimdall/bin/ham-ctl agent start-success")
	out, _ = strings.replace_all(out, "ham-ctl --token ", "./.heimdall/bin/ham-ctl --token ")
	out, _ = strings.replace_all(out, "ham-ctl start-success", "./.heimdall/bin/ham-ctl agent start-success")
	out = strings.concatenate({out, "\n\nHeimdall runtime: use `./.heimdall/bin/ham-ctl` for CLI actions. Your agent token is `", agent_token, "` and your agent instance id is `", agent_instance_id, "`; they are also available in HEIMDALL_AGENT_TOKEN and HEIMDALL_AGENT_INSTANCE_ID."})
	return out
}

deliver_tmux_starter_prompt :: proc(profile: Agent_Profile, daemon_url, agent_token, agent_instance_id, pane_id: string) -> bool {
	if prompt_delivery(profile) != "tmux" do return false
	prompt := render_starter_prompt_for_agent(profile, daemon_url, agent_token, agent_instance_id)
	if strings.trim_space(prompt) == "" do return false
	delay := profile.prompt_tmux_delay_ms
	if delay <= 0 do delay = 1500
	if delay > 0 do time.sleep(time.Duration(delay) * time.Millisecond)
	return tmux.send_text(pane_id, prompt, profile.prompt_tmux_enter)
}

startup_probe_agent :: proc(cfg: cfg_lib.Startup_Detection_Config, pane_id: string) -> Startup_Probe_Result {
	if !cfg.enabled do return Startup_Probe_Result{status = "ready", detail = "startup detection disabled"}
	probe_seconds := cfg.startup_probe_seconds
	if probe_seconds <= 0 do probe_seconds = 20
	interval_ms := cfg.capture_interval_ms
	if interval_ms <= 0 do interval_ms = 500
	deadline := time.to_unix_nanoseconds(time.now()) + i64(time.Duration(probe_seconds) * time.Second)
	last_auto_enter := i64(0)
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if !tmux.pane_exists(pane_id) do return Startup_Probe_Result{status = "startup_failed", detail = "agent pane exited during startup"}
		pane_text, ok := tmux.capture_pane_text(pane_id, 80)
		if ok {
			if idx := first_pattern(pane_text, cfg.blocked_patterns); idx >= 0 do return Startup_Probe_Result{status = "startup_blocked", detail = startup_reason(cfg, idx, "startup blocked")}
			now := time.to_unix_nanoseconds(time.now())
			if now - last_auto_enter >= i64(2 * time.Second) {
				if idx := first_pattern(pane_text, cfg.auto_enter_patterns); idx >= 0 {
					if idx < len(cfg.auto_enter_pre_keys) && strings.trim_space(cfg.auto_enter_pre_keys[idx]) != "" {
						// pre-keys are tmux NAMED keys (e.g. "Down", "Tab Tab") used to
						// navigate the prompt off its default option BEFORE confirming.
						// They must be sent as key presses, not literal text: send_text
						// would type the word "Down" into the prompt instead of pressing
						// the arrow, leaving the wrong option selected and the launch
						// stuck at the trust/ToS/bypass screen (startup_blocked).
						_ = tmux.send_named_keys(pane_id, cfg.auto_enter_pre_keys[idx], true)
					} else {
						_ = tmux.send_named_keys(pane_id, "Enter", false)
					}
					last_auto_enter = now
					deadline = now + i64(time.Duration(probe_seconds) * time.Second)
				}
			}
		}
		time.sleep(time.Duration(interval_ms) * time.Millisecond)
	}
	if cfg.startup_unknown_is_blocked do return Startup_Probe_Result{status = "startup_blocked", detail = "startup readiness unknown"}
	return Startup_Probe_Result{status = "ready", detail = "startup probe completed"}
}

sample_activity_status :: proc(pane_id: string, cfg: cfg_lib.Activity_Detection_Config) -> Activity_Sample {
	status := "idle"
	source := "pane_alive"
	line_count := cfg.sample_line_count
	if line_count <= 0 do line_count = 20
	if text, ok := tmux.capture_pane_text(pane_id, line_count); ok {
		if strings.trim_space(text) != "" { status = "active"; source = "pane_output" }
	}
	return Activity_Sample{status = status, source = source}
}

first_pattern :: proc(text: string, patterns: []string) -> int {
	lower_text := strings.to_lower(text)
	for pattern, i in patterns {
		p := strings.to_lower(strings.trim_space(pattern))
		if p != "" && strings.contains(lower_text, p) do return i
	}
	return -1
}

startup_reason :: proc(cfg: cfg_lib.Startup_Detection_Config, idx: int, fallback: string) -> string {
	if idx >= 0 && idx < len(cfg.sanitized_reason_mapping) && strings.trim_space(cfg.sanitized_reason_mapping[idx]) != "" do return cfg.sanitized_reason_mapping[idx]
	return fallback
}

log_model_tier_unavailable :: proc(tier, provider: string) {
	if tier != "" do fmt.println("model_tier_unavailable tier", tier, "provider", provider)
}
