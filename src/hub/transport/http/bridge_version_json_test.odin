package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// REQ-BUPD-1: write_bridge_json serializes bridge version, commit, build timestamp, and update status.
@(test)
test_write_bridge_json_version_fields :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_version_test",
		label = "Worker Alpha",
		machine_hostname = "worker-01",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = "{}",
		version = "0.2.0",
		commit_sha = "796bfb57",
		build_timestamp = "2026-10-01T12:00:00Z",
		update_status = "idle",
		update_message = "",
		update_progress = 0,
		update_error = "",
		last_seen_at = "2026-10-01T12:01:00Z",
		updated_at = "2026-10-01T12:01:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"bridge_id\":\"brg_version_test\""), "bridge_id serialized")
	testing.expect(t, strings.contains(out, "\"version\":\"0.2.0\""), "version serialized")
	testing.expect(t, strings.contains(out, "\"commit_sha\":\"796bfb57\""), "commit_sha serialized")
	testing.expect(t, strings.contains(out, "\"build_timestamp\":\"2026-10-01T12:00:00Z\""), "build_timestamp serialized")
	testing.expect(t, strings.contains(out, "\"update_status\":\"idle\""), "update_status serialized")
	testing.expect(t, strings.contains(out, "\"update_progress\":0"), "update_progress serialized")
	testing.expect(t, strings.contains(out, "\"update_error\":\"\""), "update_error serialized")
	testing.expect(t, strings.contains(out, "\"target\":\"linux-amd64\""), "target serialized")
	testing.expect(t, strings.contains(out, "\"update_available\":"), "update_available serialized")
	testing.expect(t, strings.contains(out, "\"latest_version\":"), "latest_version serialized")

	// Test with active update error
	bridge.update_status = "failed"
	bridge.update_error = "verification failed: binary crashed"
	b2 := strings.builder_make()
	defer strings.builder_destroy(&b2)

	write_bridge_json(&b2, bridge, nil)
	out2 := strings.to_string(b2)
	testing.expect(t, strings.contains(out2, "\"update_status\":\"failed\""), "update_status failed serialized")
	testing.expect(t, strings.contains(out2, "\"update_error\":\"verification failed: binary crashed\""), "update_error text serialized")
}
