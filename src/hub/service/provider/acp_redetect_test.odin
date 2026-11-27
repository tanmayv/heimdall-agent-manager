package provider

import "core:strings"
import "core:sync"
import "core:thread"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Each test owns its redetector and call log: nothing is process-wide, so
// tests running in parallel never share a dedupe window or a dispatcher.
@(private = "file")
Redetect_Fixture :: struct {
	r: ACP_Redetector,
	calls: [dynamic]string,
}

@(private = "file")
redetect_fake :: proc(ctx: rawptr, bridge_id, provider: string, kind: ACP_Redetect_Kind) {
	f := (^Redetect_Fixture)(ctx)
	append(&f.calls, strings.concatenate({bridge_id, "/", provider, "/", "recheck" if kind == .Recheck else "discover"}))
}

@(private = "file")
redetect_setup :: proc(f: ^Redetect_Fixture) {
	acp_redetector_init(&f.r, redetect_fake, f)
	f.r.inline = true
}

@(private = "file")
redetect_reset :: proc(f: ^Redetect_Fixture) {
	acp_redetector_destroy(&f.r)
	acp_redetector_init(&f.r, redetect_fake, f)
	f.r.inline = true
}

@(private = "file")
redetect_teardown :: proc(f: ^Redetect_Fixture) {
	acp_redetector_destroy(&f.r)
	for call in f.calls do delete(call)
	delete(f.calls)
}

// G5: the launch gate re-detects a non-ready report on an online bridge,
// exactly once per dedupe window, without changing the launch error.
@(test)
test_acp_launch_gate_redetects_non_ready_report_once :: proc(t: ^testing.T) {
	f: Redetect_Fixture; redetect_setup(&f); defer redetect_teardown(&f)
	store := Transport_Test_Store{provider = "copilot", features = `{"features":["acp_runtime_v1"]}`, transports = `["pty","acp"]`, default_transport = "pty",
		recipe = COPILOT_TRANSPORT_TEST_RECIPE, override = "acp",
		adapter = `{"installed":true,"state":"error","version":"1.0.120","checked_at":"2026-11-27T00:00:00Z","error":"ACP initialize probe is required for the selected profile; use Re-check"}`}
	repo := iface.Provider_Repository{ctx = &store, get = transport_test_get, get_provider_transport = transport_test_override, list_status = transport_test_status}
	bridges := iface.Bridge_Repository{ctx = &store, get_bridge = transport_test_bridge}
	svc := Provider_Service{repo = &repo, bridges = &bridges, redetector = &f.r}
	for _ in 0 ..< 3 {
		selected, err := resolve_runtime_transport(&svc, "bridge", "copilot")
		testing.expect(t, err.code == .ACP_Unavailable && selected == "", "the launch still fails with its current error")
		delete(selected)
	}
	testing.expect_value(t, len(f.calls), 1)
	if len(f.calls) == 1 do testing.expect_value(t, f.calls[0], "bridge/copilot/recheck") // System runtime: probe Re-check
	// The settings save starts its own tracked install/Re-check: no extra request.
	redetect_reset(&f)
	entry := domain.Provider_Catalog_Entry{provider = "copilot", acp_recipe_json = COPILOT_TRANSPORT_TEST_RECIPE}
	testing.expect_value(t, require_acp_ready(&svc, "bridge", entry, redetect = false).code, domain.Error_Code.ACP_Unavailable)
	testing.expect_value(t, len(f.calls), 1)
	// A fresh ready report dispatches nothing.
	store.adapter = `{"installed":true,"state":"ready","version":"1.0.120","checked_at":"2026-11-27T00:00:00Z","adapter_package":"@github/copilot","adapter_version":"1.0.114"}`
	selected, err := resolve_runtime_transport(&svc, "bridge", "copilot")
	testing.expect(t, err.code == .None && selected == "acp"); delete(selected)
	testing.expect_value(t, len(f.calls), 1)
	// An adapter runtime (Claude) missing Node.js is re-detected by a discover.
	store = Transport_Test_Store{features = `{"features":["acp_runtime_v1"]}`, transports = `["pty","acp"]`, default_transport = "pty",
		recipe = TRANSPORT_TEST_RECIPE, override = "acp", adapter = `{"installed":false,"state":"missing_node","checked_at":"2026-11-27T00:00:00Z"}`}
	selected, err = resolve_runtime_transport(&svc, "bridge", "claude"); delete(selected)
	testing.expect_value(t, err.code, domain.Error_Code.ACP_Unavailable)
	testing.expect_value(t, len(f.calls), 2)
	if len(f.calls) == 2 do testing.expect_value(t, f.calls[1], "bridge/claude/discover")
	// Installing and unsupported bridges never re-detect.
	redetect_reset(&f)
	store.adapter = `{"installed":false,"state":"installing","checked_at":"2026-11-27T00:00:00Z"}`
	selected, err = resolve_runtime_transport(&svc, "bridge", "claude"); delete(selected)
	store.adapter = `{"installed":false,"state":"missing","checked_at":"2026-11-27T00:00:00Z"}`; store.features = ""
	selected, err = resolve_runtime_transport(&svc, "bridge", "claude"); delete(selected)
	testing.expect_value(t, len(f.calls), 2)
}

@(test)
test_acp_redetect_dedupes_per_bridge_provider_window :: proc(t: ^testing.T) {
	f: Redetect_Fixture; redetect_setup(&f); defer redetect_teardown(&f)
	now := time.now()
	testing.expect(t, acp_request_redetect(&f.r, "b1", "claude", .Discover, now))
	testing.expect(t, !acp_request_redetect(&f.r, "b1", "claude", .Discover, time.time_add(now, 29 * time.Second)))
	testing.expect(t, acp_request_redetect(&f.r, "b2", "claude", .Discover, now), "another bridge is independent")
	testing.expect(t, acp_request_redetect(&f.r, "b1", "kiro", .Recheck, now), "another provider is independent")
	testing.expect(t, acp_request_redetect(&f.r, "b1", "claude", .Discover, time.time_add(now, 31 * time.Second)), "the window expires")
	testing.expect_value(t, len(f.calls), 4)
	testing.expect(t, !acp_request_redetect(nil, "b3", "claude", .Discover, now), "no redetector, no request")
	// Another service's redetector has its own window.
	other: Redetect_Fixture; redetect_setup(&other); defer redetect_teardown(&other)
	testing.expect(t, acp_request_redetect(&other.r, "b1", "claude", .Discover, now))
	testing.expect_value(t, len(f.calls), 4)
}

// A provider-status read re-detects a stale report once; fresh reports, PTY-only
// providers, offline or non-ACP bridges never.
@(test)
test_acp_stale_status_read_redetects_once :: proc(t: ^testing.T) {
	f: Redetect_Fixture; redetect_setup(&f); defer redetect_teardown(&f)
	now, _ := time.rfc3339_to_time_utc("2026-11-27T12:00:00Z")
	bridge := domain.Bridge{bridge_id = "b", capabilities_json = `{"features":["acp_runtime_v1"]}`}
	// The bridge's checked_at is deliberately skewed: only the Hub receipt time counts.
	report := `{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2030-01-01T00:00:00Z","adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}`
	stale := report; stale_at := "2026-11-27T11:00:00Z"
	fresh := report; fresh_at := "2026-11-27T11:55:00Z"
	testing.expect(t, !acp_read_redetect(&f.r, bridge, "claude", `["pty","acp"]`, TRANSPORT_TEST_RECIPE, fresh, fresh_at, now))
	testing.expect(t, !acp_read_redetect(&f.r, bridge, "claude", `["pty","acp"]`, TRANSPORT_TEST_RECIPE, "", "", now), "no report yet: scans create it")
	testing.expect(t, !acp_read_redetect(&f.r, bridge, "claude", `["pty"]`, TRANSPORT_TEST_RECIPE, stale, stale_at, now))
	offline := bridge; offline.status = .Offline
	testing.expect(t, !acp_read_redetect(&f.r, offline, "claude", `["pty","acp"]`, TRANSPORT_TEST_RECIPE, stale, stale_at, now))
	no_acp := bridge; no_acp.capabilities_json = `{"features":[]}`
	testing.expect(t, !acp_read_redetect(&f.r, no_acp, "claude", `["pty","acp"]`, TRANSPORT_TEST_RECIPE, stale, stale_at, now))
	testing.expect_value(t, len(f.calls), 0)
	testing.expect(t, acp_read_redetect(&f.r, bridge, "claude", `["pty","acp"]`, TRANSPORT_TEST_RECIPE, stale, stale_at, now))
	testing.expect(t, !acp_read_redetect(&f.r, bridge, "claude", `["pty","acp"]`, TRANSPORT_TEST_RECIPE, stale, stale_at, time.time_add(now, time.Second)), "deduplicated")
	testing.expect_value(t, len(f.calls), 1)
	if len(f.calls) == 1 do testing.expect_value(t, f.calls[0], "b/claude/discover")
	testing.expect(t, acp_report_stale(report, "", now), "no Hub receipt time: stale once")
	testing.expect(t, acp_report_stale(report, "not a time", now))
	testing.expect(t, !acp_report_stale(report, fresh_at, now))
	testing.expect_value(t, acp_redetect_kind("kiro", `{"state":"outdated"}`), ACP_Redetect_Kind.Recheck)
	testing.expect_value(t, acp_redetect_kind("kiro", stale), ACP_Redetect_Kind.Discover)
	testing.expect_value(t, acp_redetect_kind("claude", `{"state":"missing"}`), ACP_Redetect_Kind.Discover)
}

@(private = "file") slow_done: int

@(private = "file")
redetect_slow :: proc(ctx: rawptr, bridge_id, provider: string, kind: ACP_Redetect_Kind) {
	time.sleep(50 * time.Millisecond)
	sync.atomic_add(&slow_done, 1)
}

// Dispatches run on workers the redetector owns; destroy joins them, so no
// worker outlives the handlers it was given.
@(test)
test_acp_redetector_destroy_joins_workers :: proc(t: ^testing.T) {
	r: ACP_Redetector
	acp_redetector_init(&r, redetect_slow, nil)
	sync.atomic_store(&slow_done, 0)
	started := time.now()
	testing.expect(t, acp_request_redetect(&r, "b", "claude", .Discover, time.now()))
	testing.expect(t, acp_request_redetect(&r, "b", "kiro", .Recheck, time.now()))
	testing.expect(t, time.since(started) < 40 * time.Millisecond, "the caller never waits on the dispatch")
	acp_redetector_destroy(&r)
	testing.expect_value(t, sync.atomic_load(&slow_done), 2)
	testing.expect(t, !acp_request_redetect(&r, "b", "pi", .Discover, time.now()), "a destroyed redetector dispatches nothing")
}

// Item 2: one re-detection in flight per provider, correlated in memory; a
// lost one stops suppressing requests after ACP_REDETECT_INFLIGHT_TTL.
@(test)
test_acp_redetect_in_flight_is_bounded_and_correlated :: proc(t: ^testing.T) {
	f: Redetect_Fixture; redetect_setup(&f); defer redetect_teardown(&f)
	now := time.now()
	acp_redetect_pending_set(&f.r, "b", "claude", "acp_rd_1", .Discover, now)
	later := time.time_add(now, ACP_REDETECT_MIN_INTERVAL + time.Second)
	testing.expect(t, !acp_request_redetect(&f.r, "b", "claude", .Discover, later), "in flight: no second request")
	testing.expect_value(t, acp_redetect_pending_expired(&f.r, "b", "claude", later), "")
	// Only this bridge's own id matches, and only once.
	_, other := acp_redetect_pending_take(&f.r, "b2", "acp_rd_1")
	testing.expect(t, !other)
	_, unknown := acp_redetect_pending_take(&f.r, "b", "acp_rd_2")
	testing.expect(t, !unknown)
	provider, ours := acp_redetect_pending_take(&f.r, "b", "acp_rd_1")
	testing.expect(t, ours && provider == "claude")
	_, again := acp_redetect_pending_take(&f.r, "b", "acp_rd_1")
	testing.expect(t, !again)
	testing.expect(t, acp_request_redetect(&f.r, "b", "claude", .Discover, later), "the result ends the in-flight request")
	// A lost request expires.
	acp_redetect_pending_set(&f.r, "b", "kiro", "cmd_ext_7", .Recheck, now)
	expired := time.time_add(now, ACP_REDETECT_INFLIGHT_TTL + time.Second)
	testing.expect_value(t, acp_redetect_pending_expired(&f.r, "b", "kiro", expired), "cmd_ext_7")
	testing.expect(t, acp_request_redetect(&f.r, "b", "kiro", .Recheck, expired), "a lost request no longer suppresses re-detection")
	_, recheck := acp_redetect_pending_take(&f.r, "b", "cmd_ext_7")
	testing.expect(t, !recheck, "Re-check results arrive as their own tracked command")
	acp_redetect_pending_clear(&f.r, "b", "kiro")
	testing.expect_value(t, acp_redetect_pending_expired(&f.r, "b", "kiro", expired), "")
}

// A worker that cannot be started is uncounted again: shutdown never hangs.
@(test)
test_acp_redetector_failed_worker_start_does_not_block_destroy :: proc(t: ^testing.T) {
	r: ACP_Redetector
	acp_redetector_init(&r, redetect_slow, nil)
	r.start_worker = proc(data: rawptr, fn: proc(data: rawptr)) -> bool { return false }
	testing.expect(t, !acp_request_redetect(&r, "b", "claude", .Discover, time.now()), "nothing was dispatched")
	done: bool
	waiter := thread.create_and_start_with_poly_data2(&r, &done, proc(r: ^ACP_Redetector, done: ^bool) {
		acp_redetector_destroy(r)
		sync.atomic_store(done, true)
	})
	deadline := time.time_add(time.now(), 2 * time.Second)
	for !sync.atomic_load(&done) && time.diff(time.now(), deadline) > 0 do time.sleep(5 * time.Millisecond)
	testing.expect(t, sync.atomic_load(&done), "destroy returned")
	if sync.atomic_load(&done) { thread.join(waiter); thread.destroy(waiter) }
}
