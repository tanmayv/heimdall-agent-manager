package main

import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"

agent_startup_janitor_cfg: cfg_lib.Daemon_Config
agent_startup_janitor_started: bool

agent_startup_janitor_start :: proc(cfg: cfg_lib.Daemon_Config) {
	agent_startup_janitor_cfg = cfg
	if agent_startup_janitor_started do return
	agent_startup_janitor_started = true
	thread.run(agent_startup_janitor_worker)
}

agent_startup_janitor_worker :: proc() {
	for {
		time.sleep(30 * time.Second)
		agent_startup_janitor_tick()
	}
}

agent_startup_janitor_tick :: proc() {
	timeout := agent_startup_janitor_cfg.startup_stale_after_seconds
	if timeout <= 0 do timeout = 120
	now := now_unix_ms()
	threshold := i64(timeout) * 1000
	for i in 0..<agent_count {
		if is_test_token(agents[i].agent_token) do continue

		// 1. Sweep starting agents (exited or stale startup)
		if agents[i].startup_status == "starting" {
			if now - agents[i].startup_updated_unix_ms >= threshold {
				agent_runtime_tracker_apply_startup_timeout(agents[i].agent_instance_id, now)
			}
			continue
		}

		// 2. Sweep connected agents whose heartbeats have stopped (Liveness Check)
		if agents[i].connected {
			hb_timeout := i64(30 * 1000) // 30 seconds of silence = offline
			if now - agents[i].last_seen_unix_ms >= hb_timeout {
				agent_runtime_tracker_apply_heartbeat_timeout(agents[i].agent_instance_id)
			}
		}
	}
	audit_janitor_tick()
	test_run_janitor_tick()
}
