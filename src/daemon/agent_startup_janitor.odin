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
		if agents[i].startup_status != "starting" do continue
		if now - agents[i].startup_updated_unix_ms < threshold do continue
		id := agents[i].agent_instance_id
		agents[i].startup_status = "startup_failed"
		agents[i].startup_reason_code = "startup_stale"
		agents[i].startup_safe_diagnostic = "Agent did not report startup status within the configured timeout"
		agents[i].startup_updated_unix_ms = now
		if !agents[i].has_ws do agents[i].connected = false
		agent_lifecycle_emit(id, "startup_failed", "startup_stale")
	}
}
