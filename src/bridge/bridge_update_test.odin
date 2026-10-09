package main

import "core:strings"
import "core:testing"

bridge_update_test_spawn_args: [dynamic]string

bridge_update_test_capture_spawn :: proc(argv: []string) -> bool {
	for arg in argv do append(&bridge_update_test_spawn_args, strings.clone(arg))
	return true
}

bridge_update_test_clear_spawn_args :: proc() {
	for arg in bridge_update_test_spawn_args do delete(arg)
	delete(bridge_update_test_spawn_args)
}

// REQ-BUPD-4: bridge_update_progress_json frame serialization
@(test)
test_bridge_update_progress_json_format :: proc(t: ^testing.T) {
	frame := bridge_update_progress_json("cmd_upd_123", "brg_test", "downloading", 45, "Downloading update package")
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"bridge_update_progress\""), "type is bridge_update_progress")
	testing.expect(t, strings.contains(frame, "\"command_id\":\"cmd_upd_123\""), "command_id is correct")
	testing.expect(t, strings.contains(frame, "\"bridge_id\":\"brg_test\""), "bridge_id is correct")
	testing.expect(t, strings.contains(frame, "\"stage\":\"downloading\""), "stage is downloading")
	testing.expect(t, strings.contains(frame, "\"progress_percent\":45"), "progress_percent is 45")
	testing.expect(t, strings.contains(frame, "\"message\":\"Downloading update package\""), "message matches")
}

// REQ-BUPD-FIX-5: update launch is an injectable argv boundary. This pins the
// exact process identity forwarded to the supervisor without running the script.
@(test)
test_bridge_update_supervisor_launch_uses_structured_argv_and_exact_pid :: proc(t: ^testing.T) {
	bridge_update_test_clear_spawn_args()
	defer bridge_update_test_clear_spawn_args()

	ok := bridge_update_launch_supervisor(
		"/tmp/update scripts/apply-bridge-update.sh",
		"/tmp/data dir",
		"/tmp/stage dir",
		"49323",
		"https://hub.example.test/path?value=one&next=two",
		"424242",
		bridge_update_test_capture_spawn,
	)
	testing.expect(t, ok, "injected supervisor launcher succeeds")
	testing.expect_value(t, len(bridge_update_test_spawn_args), 12)
	if len(bridge_update_test_spawn_args) != 12 do return
	testing.expect_value(t, bridge_update_test_spawn_args[0], "bash")
	testing.expect_value(t, bridge_update_test_spawn_args[1], "/tmp/update scripts/apply-bridge-update.sh")
	testing.expect_value(t, bridge_update_test_spawn_args[3], "/tmp/data dir")
	testing.expect_value(t, bridge_update_test_spawn_args[5], "/tmp/stage dir")
	testing.expect_value(t, bridge_update_test_spawn_args[7], "49323")
	testing.expect_value(t, bridge_update_test_spawn_args[9], "https://hub.example.test/path?value=one&next=two")
	testing.expect_value(t, bridge_update_test_spawn_args[10], "--bridge-pid")
	testing.expect_value(t, bridge_update_test_spawn_args[11], "424242")
}
