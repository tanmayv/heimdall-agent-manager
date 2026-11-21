package main

import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"

// Scripted daemon for the probe seam: each probe consumes one step.
ACP_Probe_Test_Step :: enum {
	Daemon_Down,      // ensure_daemon fails
	Silent,           // daemon up, Capabilities gets no reply
	Old_Daemon_Error, // daemon up, replies Error (predates the tag)
	Wrong_Reply,      // daemon up, replies Pong
	No_Pipes,         // Capabilities{piped_spawn_v1:false}
	Pipes,            // Capabilities{piped_spawn_v1:true}
}

acp_probe_test_steps: []ACP_Probe_Test_Step
acp_probe_test_next: int
acp_probe_test_requests: int

acp_probe_test_step :: proc() -> ACP_Probe_Test_Step {
	return acp_probe_test_steps[min(acp_probe_test_next, len(acp_probe_test_steps) - 1)]
}

acp_probe_test_ensure :: proc() -> (string, bool) {
	step := acp_probe_test_step()
	if step == .Daemon_Down {
		acp_probe_test_next += 1
		return "", false
	}
	return "/tmp/acp-probe-test.sock", true
}

acp_probe_test_request :: proc(socket: string, frame: []byte, timeout_ms: int) -> (Pty_Host_Reply, bool) {
	acp_probe_test_requests += 1
	step := acp_probe_test_step()
	acp_probe_test_next += 1
	#partial switch step {
	case .Silent:           return {}, false
	case .Old_Daemon_Error: return {kind = .Error}, true
	case .Wrong_Reply:      return {kind = .Pong}, true
	case .No_Pipes:         return {kind = .Capabilities, piped_spawn_v1 = false}, true
	case .Pipes:            return {kind = .Capabilities, piped_spawn_v1 = true}, true
	}
	return {}, false
}

// acp_probe_test_begin installs the scripted daemon under the config lock (the
// latch and negotiation flags are process globals other tests read).
acp_probe_test_begin :: proc(steps: []ACP_Probe_Test_Step) -> ACP_Probe_IO {
	sync.mutex_lock(&bridge_test_config_mutex)
	saved := acp_probe_io
	acp_probe_io = ACP_Probe_IO{ensure_daemon = acp_probe_test_ensure, request = acp_probe_test_request}
	acp_probe_test_steps = steps
	acp_probe_test_next = 0
	acp_probe_test_requests = 0
	acp_probe_reset()
	return saved
}

acp_probe_test_end :: proc(saved: ACP_Probe_IO) {
	acp_probe_io = saved
	acp_probe_reset()
	bridge_hub_reset_heartbeat_negotiation()
	sync.mutex_unlock(&bridge_test_config_mutex)
}

acp_features_advertised :: proc() -> bool {
	return slice.contains(bridge_runtime_features(), contracts.BRIDGE_FEATURE_ACP_RUNTIME)
}

// REQ-ACP-3: the hub-connect probe fails (daemon still cold), a later probe on the
// same connection succeeds, and acp_runtime_v1 appears in the advertised features
// with the change marked for re-advertising.
@(test)
test_acp_probe_failed_then_successful_flips_acp_runtime_v1 :: proc(t: ^testing.T) {
	saved := acp_probe_test_begin([]ACP_Probe_Test_Step{.Silent, .Pipes})
	defer acp_probe_test_end(saved)

	bridge_acp_runtime_probe_on_connect()
	testing.expect(t, !acp_features_advertised(), "a silent daemon at connect leaves ACP unadvertised")
	testing.expect(t, !sync.atomic_load(&bridge_acp_features_dirty), "the hello carries the connect result: nothing to re-advertise")
	testing.expect(t, sync.atomic_load(&acp_probe_next_retry_ns) != 0, "a failed probe schedules a retry")

	outcome, changed := bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Supported)
	testing.expect(t, changed, "the latch flipped")
	testing.expect(t, acp_features_advertised(), "acp_runtime_v1 is advertised after the successful re-probe")
	testing.expect(t, sync.atomic_load(&bridge_acp_features_dirty), "the flip is queued for re-advertising on the live connection")
	testing.expect_value(t, sync.atomic_load(&acp_probe_next_retry_ns), i64(0))
	testing.expect(t, strings.contains(bridge_features_update_json(), `"acp_runtime_v1"`), "the update frame carries the new list")
	testing.expect(t, strings.contains(bridge_features_update_json(), `"type":"bridge_features_update"`), "frame type")

	// A second successful probe changes nothing.
	sync.atomic_store(&bridge_acp_features_dirty, false)
	_, changed = bridge_acp_runtime_probe(.Provider_Scan)
	testing.expect(t, !changed, "an unchanged result is not re-advertised")
	testing.expect(t, !sync.atomic_load(&bridge_acp_features_dirty), "still clean")
}

// REQ-ACP-2: each failure is classified; an unavailable daemon keeps the last known
// value while a live daemon's answer is authoritative.
@(test)
test_acp_probe_classifies_outcomes :: proc(t: ^testing.T) {
	saved := acp_probe_test_begin([]ACP_Probe_Test_Step{.Pipes, .Daemon_Down, .Old_Daemon_Error, .Wrong_Reply, .No_Pipes, .Silent})
	defer acp_probe_test_end(saved)

	outcome, _ := bridge_acp_runtime_probe(.Hub_Connect)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Supported)
	outcome, _ = bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Daemon_Unavailable)
	testing.expect(t, acp_features_advertised(), "a daemon that is down right now does not withdraw the feature")
	testing.expect_value(t, acp_probe_test_requests, 1)

	changed: bool
	outcome, changed = bridge_acp_runtime_probe(.Daemon_Restart)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Lacks_Piped_Spawn)
	testing.expect(t, changed && !acp_features_advertised(), "an adopted older daemon (Error reply) withdraws the feature")
	outcome, _ = bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Bad_Reply)
	outcome, _ = bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.Lacks_Piped_Spawn)
	outcome, _ = bridge_acp_runtime_probe(.Retry)
	testing.expect_value(t, outcome, ACP_Probe_Outcome.No_Reply)
	testing.expect(t, !acp_features_advertised(), "still unsupported")
}

// REQ-ACP-1: the loop tick re-probes when the daemon was (re)started or adopted, and
// when a scheduled retry is due — not otherwise.
@(test)
test_acp_probe_due_on_daemon_epoch_and_retry :: proc(t: ^testing.T) {
	saved := acp_probe_test_begin([]ACP_Probe_Test_Step{.Pipes})
	defer acp_probe_test_end(saved)

	now := time.to_unix_nanoseconds(time.now())
	_, due := bridge_acp_runtime_probe_due(now)
	testing.expect(t, !due, "nothing due after reset")

	sync.atomic_add(&pty_host_daemon_epoch, 1)
	trigger: ACP_Probe_Trigger
	trigger, due = bridge_acp_runtime_probe_due(now)
	testing.expect(t, due && trigger == .Daemon_Restart, "a started/adopted daemon is re-probed")
	_, _ = bridge_acp_runtime_probe(trigger)
	_, due = bridge_acp_runtime_probe_due(now)
	testing.expect(t, !due, "the probe records the epoch it saw")

	sync.atomic_store(&acp_probe_next_retry_ns, now + i64(time.Second))
	_, due = bridge_acp_runtime_probe_due(now)
	testing.expect(t, !due, "a retry is not due early")
	trigger, due = bridge_acp_runtime_probe_due(now + i64(time.Second))
	testing.expect(t, due && trigger == .Retry, "a due retry re-probes")

	sync.atomic_store(&acp_probe_running, true)
	_, due = bridge_acp_runtime_probe_due(now + i64(time.Second))
	testing.expect(t, !due, "single flight: no second probe while one runs")
}

@(test)
test_acp_probe_retry_backoff_is_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, acp_probe_retry_delay(1), ACP_PROBE_RETRY_MIN)
	testing.expect_value(t, acp_probe_retry_delay(2), 2 * ACP_PROBE_RETRY_MIN)
	testing.expect_value(t, acp_probe_retry_delay(3), 4 * ACP_PROBE_RETRY_MIN)
	testing.expect_value(t, acp_probe_retry_delay(50), ACP_PROBE_RETRY_MAX)
}

// REQ-ACP-1: the re-advertising route per hub generation.
@(test)
test_acp_advertise_route :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_acp_advertise_route(false, true, true, true), ACP_Advertise_Route.None)
	testing.expect_value(t, bridge_acp_advertise_route(true, true, true, true), ACP_Advertise_Route.Features_Update)
	testing.expect_value(t, bridge_acp_advertise_route(true, true, true, false), ACP_Advertise_Route.Features_Update)
	// Legacy connection: the beat's features replace the stored list.
	testing.expect_value(t, bridge_acp_advertise_route(true, false, false, true), ACP_Advertise_Route.Heartbeat)
	// Omission negotiated with an older hub: only the hello can carry it.
	testing.expect_value(t, bridge_acp_advertise_route(true, false, true, true), ACP_Advertise_Route.Reconnect)
	testing.expect_value(t, bridge_acp_advertise_route(true, false, true, false), ACP_Advertise_Route.None)
}

// The classified probe keeps pty_host_supports_pipes' contract for its callers.
@(test)
test_pty_host_probe_pipes_classification :: proc(t: ^testing.T) {
	saved := acp_probe_test_begin([]ACP_Probe_Test_Step{.Pipes, .No_Pipes, .Old_Daemon_Error, .Wrong_Reply, .Silent})
	defer acp_probe_test_end(saved)
	testing.expect_value(t, pty_host_probe_pipes("/tmp/x.sock", acp_probe_test_request), Pty_Host_Pipe_Probe.Supported)
	testing.expect_value(t, pty_host_probe_pipes("/tmp/x.sock", acp_probe_test_request), Pty_Host_Pipe_Probe.Lacks_Piped_Spawn)
	testing.expect_value(t, pty_host_probe_pipes("/tmp/x.sock", acp_probe_test_request), Pty_Host_Pipe_Probe.Lacks_Piped_Spawn)
	testing.expect_value(t, pty_host_probe_pipes("/tmp/x.sock", acp_probe_test_request), Pty_Host_Pipe_Probe.Bad_Reply)
	testing.expect_value(t, pty_host_probe_pipes("/tmp/x.sock", acp_probe_test_request), Pty_Host_Pipe_Probe.No_Reply)
}
