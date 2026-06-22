package main

import "core:fmt"
import "core:net"
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
				id := agents[i].agent_instance_id
				agents[i].startup_status = "startup_failed"
				agents[i].startup_reason_code = "startup_stale"
				agents[i].startup_safe_diagnostic = "Agent did not report startup status within the configured timeout"
				agents[i].startup_updated_unix_ms = now
				if !agents[i].has_ws do agents[i].connected = false
				agent_lifecycle_emit(id, "startup_failed", "startup_stale")
			}
			continue
		}

		// 2. Sweep connected agents whose heartbeats have stopped (Liveness Check)
		if agents[i].connected {
			hb_timeout := i64(30 * 1000) // 30 seconds of silence = offline
			if now - agents[i].last_seen_unix_ms >= hb_timeout {
				id := agents[i].agent_instance_id
				fmt.println("LIVENESS TIMEOUT: Agent", id, "has not sent heartbeats for 30s. Marking offline.")
				
				if agents[i].has_ws {
					net.close(agents[i].ws_socket)
					agents[i].has_ws = false
				}
				agents[i].connected = false
				agents[i].exec_state = "offline"
				
				agent_lifecycle_emit(id, "disconnected", "heartbeat_timeout")
			}
		}
	}
	test_run_janitor_tick()
}
