package main

import "core:strings"
import "core:testing"

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

// DELETED (D1, on user instruction): test_bridge_update_command_dispatch_and_execution.
//
// That test drove the PRODUCTION bridge_update apply path end to end with a valid
// SHA-256, which reaches hub_runtime_client.odin:1231-1239 and spawns the REAL detached
// supervisor `scripts/apply-bridge-update.sh`. That script's stop_service() runs
// `pkill -f "ham-bridge"` (scripts/apply-bridge-update.sh:129), which kills EVERY
// ham-bridge process on the host -- including the live dawnstar bridge and the unrelated
// heimdall-bridge-qa service. The `when !ODIN_TEST` guard at :1247 only suppresses the
// test binary's own self-exit; it does NOT stop the supervisor spawn at :1231, so the
// guard sits one step too late to make this test safe.
//
// Do not reinstate a test that calls bridge_hub_handle_command with a bridge_update
// command whose sha256 matches its bundle. Any future coverage of the apply path must
// inject a seam for the supervisor spawn rather than letting the real script run.
