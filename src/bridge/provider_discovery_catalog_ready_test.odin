package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

// A fresh profile has no cached provider catalog until its first sync lands. These
// tests pin the contract that discovery never reports from an empty catalog: it
// waits a bounded time, then refuses with a retriable typed error and re-requests
// the catalog (rate-limited).

catalog_ready_test_snapshot: Bridge_Provider_Catalog_Snapshot

catalog_ready_test_publisher :: proc() {
	time.sleep(100 * time.Millisecond)
	bridge_provider_catalog_publish(&catalog_ready_test_snapshot)
}

@(test)
test_discovery_waits_for_a_catalog_published_during_the_wait :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old, old_loaded := provider_binary_path_with_catalog(nil)
	defer provider_binary_path_restore_catalog(old, old_loaded)
	catalog_ready_test_snapshot = Bridge_Provider_Catalog_Snapshot{providers = []Bridge_Catalog_Provider{{provider = "claude", state = "active", binary = "claude"}}}

	publisher := thread.create_and_start(catalog_ready_test_publisher)
	defer thread.destroy(publisher)
	started := time.tick_now()
	ready := bridge_provider_catalog_wait_ready(time.time_add(time.now(), 2 * time.Second))
	elapsed := time.tick_since(started)
	thread.join(publisher)

	testing.expect(t, ready, "a catalog published during the wait must end it")
	// Woken by the publish broadcast, not by running out the 2s wait.
	testing.expectf(t, elapsed < time.Second, "wait ended after %v", elapsed)
}

@(test)
test_discovery_catalog_wait_is_bounded_without_a_catalog :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old, old_loaded := provider_binary_path_with_catalog(nil)
	defer provider_binary_path_restore_catalog(old, old_loaded)

	started := time.tick_now()
	testing.expect(t, !bridge_provider_catalog_wait_ready(time.time_add(time.now(), 150 * time.Millisecond)))
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed >= 100 * time.Millisecond && elapsed < time.Second, "bounded wait took %v", elapsed)

	// A zero or past deadline only checks.
	started = time.tick_now()
	testing.expect(t, !bridge_provider_catalog_wait_ready({}))
	testing.expect(t, !bridge_provider_catalog_wait_ready(time.time_add(time.now(), -time.Second)))
	testing.expect(t, time.tick_since(started) < 50 * time.Millisecond, "a past deadline must not wait")

	// With a catalog loaded the answer is immediate.
	snap := Bridge_Provider_Catalog_Snapshot{providers = []Bridge_Catalog_Provider{{provider = "codex", state = "active", binary = "codex"}}}
	provider_binary_path_with_catalog(&snap)
	testing.expect(t, bridge_provider_catalog_wait_ready({}))
}

@(test)
test_discovery_deadlines_fit_inside_the_hub_wait :: proc(t: ^testing.T) {
	now := time.now()

	// No Hub deadline (not on a dispatch worker): the plain wait, unbounded probes.
	wait_until, probe_deadline := bridge_provider_discover_deadlines(now, 0)
	testing.expect_value(t, time.diff(now, wait_until), BRIDGE_PROVIDER_CATALOG_READY_WAIT)
	testing.expect(t, probe_deadline == {})

	// The usual 10s Hub wait: full catalog wait, probes stop 500ms before the Hub.
	hub := time.time_add(now, 10 * time.Second)
	wait_until, probe_deadline = bridge_provider_discover_deadlines(now, time.to_unix_nanoseconds(hub))
	testing.expect_value(t, time.diff(now, wait_until), BRIDGE_PROVIDER_CATALOG_READY_WAIT)
	testing.expect_value(t, time.diff(probe_deadline, hub), BRIDGE_PROVIDER_DISCOVERY_REPLY_MARGIN)

	// A short remaining budget shrinks the wait so a second of probing remains.
	hub = time.time_add(now, 2 * time.Second)
	wait_until, probe_deadline = bridge_provider_discover_deadlines(now, time.to_unix_nanoseconds(hub))
	testing.expect_value(t, time.diff(wait_until, probe_deadline), time.Second)
	testing.expect(t, time.diff(wait_until, hub) > 0, "the wait ends before the Hub gives up")

	// An already-expired budget does not wait at all.
	hub = time.time_add(now, -time.Second)
	wait_until, _ = bridge_provider_discover_deadlines(now, time.to_unix_nanoseconds(hub))
	testing.expect(t, time.diff(now, wait_until) < 0)
}

@(test)
test_discovery_not_ready_refusal_is_typed_and_rerequests_the_catalog :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old, old_loaded := provider_binary_path_with_catalog(nil)
	defer provider_binary_path_restore_catalog(old, old_loaded)
	sync.mutex_lock(&bridge_provider_catalog_recovery_mutex)
	old_last := bridge_provider_catalog_recovery_last
	bridge_provider_catalog_recovery_last = {}
	sync.mutex_unlock(&bridge_provider_catalog_recovery_mutex)
	defer {
		sync.mutex_lock(&bridge_provider_catalog_recovery_mutex)
		bridge_provider_catalog_recovery_last = old_last
		sync.mutex_unlock(&bridge_provider_catalog_recovery_mutex)
	}

	now := time.now()
	request, failed := bridge_provider_discover_not_ready_frames("pdr_1", now)
	defer delete(request)
	defer delete(failed)
	testing.expect(t, strings.contains(request, `"type":"provider_catalog_request"`), request)

	// A failed command_result carrying the shared wire error: the Hub turns it into
	// 503 bridge_busy / retriable / provider_catalog_not_ready, never an empty report.
	testing.expect(t, strings.contains(failed, `"type":"command_result"`), failed)
	testing.expect(t, strings.contains(failed, `"command_id":"pdr_1"`), failed)
	testing.expect(t, !strings.contains(failed, "provider_discovery_report"), failed)
	werr, found := contracts.wire_error_parse(failed, context.temp_allocator)
	if testing.expect(t, found, failed) {
		testing.expect_value(t, werr.code, contracts.Error_Code.Bridge_Busy)
		testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.retriable)
		testing.expect_value(t, werr.cause, BRIDGE_PROVIDER_CATALOG_NOT_READY_CAUSE)
		testing.expect_value(t, werr.retry_after_ms, i64(BRIDGE_PROVIDER_CATALOG_RETRY_AFTER_MS))
	}

	// Retries inside the recovery interval refuse without re-requesting the catalog.
	again, failed_again := bridge_provider_discover_not_ready_frames("pdr_2", time.time_add(now, time.Second))
	defer delete(failed_again)
	testing.expect_value(t, again, "")
	testing.expect(t, strings.contains(failed_again, `"command_id":"pdr_2"`), failed_again)

	// Once the interval passes, a still-missing catalog is requested again.
	later, failed_later := bridge_provider_discover_not_ready_frames("pdr_3", time.time_add(now, BRIDGE_PROVIDER_CATALOG_RECOVERY_INTERVAL + time.Second))
	defer delete(later)
	defer delete(failed_later)
	testing.expect(t, later != "", "the catalog must be re-requested after the interval")
}

@(test)
test_catalog_applies_in_memory_when_the_restart_cache_cannot_be_written :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old, old_loaded := provider_binary_path_with_catalog(nil)
	defer provider_binary_path_restore_catalog(old, old_loaded)
	saved_hook := bridge_provider_reprobe_hook
	defer bridge_provider_reprobe_hook = saved_hook
	bridge_provider_reprobe_hook = proc() {}

	// <data_dir>/bridge is a regular file, so the cache directory cannot be created.
	dir := fmt.aprintf("%s/.cache/heimdall-tests/catalog-unwritable-%d", os.get_env("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	defer delete(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer _ = os.remove_all(dir)
	blocker := strings.concatenate({dir, "/bridge"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(blocker, "not a directory") == nil)
	old_dir := bridge_config.data_dir
	bridge_config.data_dir = dir
	defer bridge_config.data_dir = old_dir

	catalog_json := `{"providers":[{"provider":"claude","display_name":"Claude Code","binary":"claude","state":"active","models":[{"model_id":"m1","label":"M1","state":"active"}]}]}`
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, catalog_json, digest[:])
	hex_digest := hex.encode(digest[:])
	defer delete(hex_digest)
	etag := strings.concatenate({"sha256:", string(hex_digest)}, context.temp_allocator)

	// Discovery must not stay refused until a restart because a cache write failed.
	testing.expect(t, bridge_provider_catalog_apply(etag, catalog_json), "a valid catalog applies even when the cache write fails")
	testing.expect(t, bridge_provider_catalog_wait_ready({}), "discovery sees the applied catalog")
}
