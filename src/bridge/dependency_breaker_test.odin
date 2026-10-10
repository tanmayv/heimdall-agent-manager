package main

import "core:testing"
import "core:strings"
import "core:time"

@(test)
bridge_dependency_breaker_opens_half_opens_and_recovers :: proc(t: ^testing.T) {
	key := "test-dependency-breaker-opens"
	now := i64(1_000_000)
	for _ in 0..<BRIDGE_DEPENDENCY_BREAKER_FAILURE_THRESHOLD do bridge_dependency_breaker_record_at(key, false, now)
	testing.expect(t, !bridge_dependency_breaker_allow_at(key, now + 1), "open breaker rejects immediately")
	probe_at := now + i64(BRIDGE_DEPENDENCY_BREAKER_COOLDOWN) + 1
	testing.expect(t, bridge_dependency_breaker_allow_at(key, probe_at), "one half-open recovery probe is admitted")
	testing.expect(t, !bridge_dependency_breaker_allow_at(key, probe_at), "parallel half-open probes are rejected")
	bridge_dependency_breaker_record_at(key, true, probe_at)
	testing.expect(t, bridge_dependency_breaker_allow_at(key, probe_at + 1), "successful probe closes the breaker")
	snapshot, ok := bridge_dependency_breaker_snapshot(key)
	defer delete(snapshot.key)
	testing.expect(t, ok)
	testing.expect_value(t, snapshot.consecutive_failures, 0)
	testing.expect_value(t, snapshot.open_until_ns, i64(0))
}

@(test)
bridge_dependency_breaker_failed_half_open_probe_reopens :: proc(t: ^testing.T) {
	key := "test-dependency-breaker-reopens"
	now := i64(2_000_000)
	for _ in 0..<BRIDGE_DEPENDENCY_BREAKER_FAILURE_THRESHOLD do bridge_dependency_breaker_record_at(key, false, now)
	probe_at := now + i64(BRIDGE_DEPENDENCY_BREAKER_COOLDOWN) + 1
	testing.expect(t, bridge_dependency_breaker_allow_at(key, probe_at))
	bridge_dependency_breaker_record_at(key, false, probe_at)
	testing.expect(t, !bridge_dependency_breaker_allow_at(key, probe_at + 1), "failed half-open probe restarts cooldown")
}

@(test)
bridge_dependency_breaker_metrics_do_not_expose_keys :: proc(t: ^testing.T) {
	json := bridge_dependency_breaker_metrics_json()
	defer delete(json)
	testing.expect(t, strings.contains(json, `"tracked":`))
	testing.expect(t, strings.contains(json, `"rejected":`))
	testing.expect(t, !strings.contains(json, "test-dependency-breaker"), "breaker metrics expose counts, not dependency names")
}
