package bridge_runtime_launch_test

import "core:fmt"
import "core:os"
import "core:strings"
import bridge "odin_test:bridge"

main :: proc() {
	bridge.bridge_hub_runtime_init()
	bridge.bridge_runtime_set_status("inst_launch", "starting", "active")
	first, ok := bridge.bridge_runtime_instance_snapshot("inst_launch")
	check(ok && first.state_seq == 1 && first.runtime_status == "starting", "initial status must set seq=1")
	bridge.bridge_runtime_set_status("inst_launch", "starting", "active")
	same, _ := bridge.bridge_runtime_instance_snapshot("inst_launch")
	check(same.state_seq == 1, "same status must not increment state_seq")
	bridge.bridge_runtime_set_status("inst_launch", "running", "idle")
	changed, _ := bridge.bridge_runtime_instance_snapshot("inst_launch")
	check(changed.state_seq == 2 && changed.runtime_status == "running", "changed status must increment state_seq")
	heartbeat := bridge.bridge_hub_heartbeat_json()
	check(strings.contains(heartbeat, "bridge_heartbeat") && strings.contains(heartbeat, "inst_launch") && strings.contains(heartbeat, "state_seq"), "heartbeat digest must include instance state_seq")

	argv := bridge.bridge_runtime_wrapper_supervisor_argv("tcp:127.0.0.1:49324", "hlat_wrapper", "hlat_agent", "inst_launch", "/tmp/run", "sleep 3600")
	joined := strings.join(argv, " ")
	check(strings.contains(joined, "wrapper-supervisor") && strings.contains(joined, "--agent-token hlat_wrapper") && strings.contains(joined, "--child-agent-token hlat_agent"), "launch argv must invoke wrapper supervisor with separate wrapper/agent local tokens")

	// §12.0.2 endpoint selection: Unix primary, loopback fallback, none if neither started.
	local_config := bridge.bridge_local_endpoint_config_default("/tmp/heimdall-bridge-launch-test", 49424)
	bridge.bridge_runtime_local_endpoint_unix_started = true
	bridge.bridge_runtime_local_endpoint_loopback_started = false
	unix_only := bridge.bridge_runtime_select_endpoint(local_config)
	check(strings.has_prefix(unix_only, "unix:"), "endpoint selection must prefer Unix when Unix started")
	bridge.bridge_runtime_local_endpoint_unix_started = false
	bridge.bridge_runtime_local_endpoint_loopback_started = true
	loopback_only := bridge.bridge_runtime_select_endpoint(local_config)
	check(strings.has_prefix(loopback_only, "tcp:"), "endpoint selection must fall back to loopback when Unix unavailable")
	bridge.bridge_runtime_local_endpoint_unix_started = false
	bridge.bridge_runtime_local_endpoint_loopback_started = false
	none := bridge.bridge_runtime_select_endpoint(local_config)
	check(none == "", "endpoint selection must return empty when neither transport started")

	result1 := bridge.bridge_command_result_json("cmd_launch", "accepted", "")
	result2 := bridge.bridge_command_result_json("cmd_launch", "succeeded", "starting")
	bridge.bridge_runtime_cache_command("cmd_launch", result1)
	bridge.bridge_runtime_cache_command("cmd_launch", result2)
	cached, cached_ok := bridge.bridge_runtime_cached_command("cmd_launch")
	check(cached_ok && strings.contains(cached, "succeeded") && strings.contains(cached, "starting"), "command cache must retain final result after accepted")

	fmt.println("PASS: bridge runtime launch helpers")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
