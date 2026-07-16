package activity_status_test

import "core:fmt"
import "core:os"
import "core:strings"
import config "odin_test:lib/config"
import wrapper "odin_test:wrapper"

main :: proc() {
	test_activity_config_defaults()
	test_activity_config_override_and_clamp()
	test_peer_config_parse()
	test_capture_classification()
	test_heartbeat_payload_privacy()
	fmt.println("activity_status_test: ok")
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}

test_activity_config_defaults :: proc() {
	cfg := config.default_activity_detection_config()
	check(cfg.enabled, "default activity detection should be enabled")
	check(cfg.sample_line_count == 20, "default sample_line_count should be 20")
	check(cfg.ignore_bottom_lines == 0, "default ignore_bottom_lines should be 0")
	check(cfg.check_interval_seconds == 15, "default check_interval_seconds should be 15")
	check(cfg.min_gap_ms == 100, "default min_gap_ms should be 100")
	check(cfg.max_gap_ms == 500, "default max_gap_ms should be 500")
}

test_activity_config_override_and_clamp :: proc() {
	cfg := config.default_config()
	config.parse_config(`
[wrapper.agent-cmd.pi.activity_detection]
enabled = true
sample_line_count = 33
ignore_bottom_lines = 2
check_interval_seconds = 19
min_gap_ms = 222
max_gap_ms = 444
`, &cfg)
	check(len(cfg.wrapper.agent_commands) > 0, "expected parsed agent command config")
	ad := cfg.wrapper.agent_commands[0].activity_detection
	check(ad.sample_line_count == 33, "sample_line_count override did not parse")
	check(ad.ignore_bottom_lines == 2, "ignore_bottom_lines override did not parse")
	check(ad.check_interval_seconds == 19, "check_interval_seconds override did not parse")
	check(ad.min_gap_ms == 222, "min_gap_ms override did not parse")
	check(ad.max_gap_ms == 444, "max_gap_ms override did not parse")

	effective := wrapper.activity_detection_effective(config.Activity_Detection_Config{
		enabled = true,
		sample_line_count = 2,
		ignore_bottom_lines = 9,
		check_interval_seconds = 0,
		min_gap_ms = 700,
		max_gap_ms = 100,
	})
	check(effective.ignore_bottom_lines == 1, "ignore_bottom_lines should clamp to sample_line_count - 1")
	check(effective.check_interval_seconds == 15, "check_interval_seconds should fall back to 15")
	check(effective.min_gap_ms == 100 && effective.max_gap_ms == 700, "gap range should swap into ascending order")
}

test_peer_config_parse :: proc() {
	cfg := config.default_config()
	config.parse_config(`
[daemon]
federation_advertised_agent_instance_ids = ["reviewer@s-1", "coder@s-2"]

[[peer]]
name = "studio-mini"
endpoint = "http://studio-mini.local:49322/"
token = "peer-secret"
`, &cfg)
	check(len(cfg.daemon.peers) == 1, "expected one parsed peer")
	check(cfg.daemon.peers[0].name == "studio-mini", "peer name did not parse")
	check(cfg.daemon.peers[0].endpoint == "http://studio-mini.local:49322/", "peer endpoint did not parse")
	check(cfg.daemon.peers[0].token == "peer-secret", "peer token did not parse")
	check(len(cfg.daemon.federation_advertised_agent_instance_ids) == 2, "expected advertised agent allowlist to parse")
	check(cfg.daemon.federation_advertised_agent_instance_ids[0] == "reviewer@s-1", "first advertised agent id did not parse")
	check(cfg.daemon.federation_advertised_agent_instance_ids[1] == "coder@s-2", "second advertised agent id did not parse")
}

test_capture_classification :: proc() {
	cfg := wrapper.activity_detection_effective(config.Activity_Detection_Config{
		enabled = true,
		sample_line_count = 3,
		ignore_bottom_lines = 1,
		check_interval_seconds = 15,
		min_gap_ms = 100,
		max_gap_ms = 500,
	})
	idle_caps := []string{
		"top\nbody\nspinner 1\n",
		"top\nbody\nspinner 2\n",
		"top\nbody\nspinner 3\n",
	}
	active_caps := []string{
		"top\nbody\nspinner 1\n",
		"top\nbody changed\nspinner 2\n",
		"top\nbody\nspinner 3\n",
	}
	check(wrapper.classify_activity_captures(idle_caps, cfg) == "idle", "volatile ignored bottom lines should still classify idle")
	check(wrapper.classify_activity_captures(active_caps, cfg) == "active", "difference above ignored bottom lines should classify active")
	check(wrapper.normalize_activity_capture("a\nb\nc\n", 1) == "a\nb", "normalize_activity_capture should drop ignored bottom line")
}

test_heartbeat_payload_privacy :: proc() {
	payload := wrapper.heartbeat_request_json(
		"tester@local",
		"agt_test_token",
		"Tester",
		"pi",
		"normal",
		"default",
		"%1",
		"/tmp/run",
		"running",
		"",
		"ready",
		"",
		"",
		wrapper.Activity_Status_Snapshot{status = "active", checked_unix_ms = 1234, source = wrapper.ACTIVITY_STATUS_SOURCE},
		999,
		555,
	)
	check(strings.contains(payload, `"activity_status":"active"`), "heartbeat payload should include activity_status")
	check(strings.contains(payload, `"activity_checked_unix_ms":1234`), "heartbeat payload should include activity timestamp")
	check(!strings.contains(payload, "spinner 1"), "heartbeat payload must not include raw pane text")
}

