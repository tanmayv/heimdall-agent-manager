package bridge_runtime

import "core:fmt"
import "core:testing"
import project_service "odin_test:hub/service/project"

// Guards the ring-buffer eviction fix: the command-result cache must keep caching
// past its capacity. The old fixed array stopped storing after 256 entries, so
// send_runtime_command_wait never saw the reply and every bridge relay 409-timed
// out hub-wide until a restart.
@(test)
runtime_command_cache_evicts_and_keeps_caching :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer free(registry)
	cap := len(registry.command_ids)
	total := cap + 44 // overflow the ring so the oldest entries are evicted

	ids: [dynamic]string
	results: [dynamic]string
	defer { for s in ids do delete(s); for s in results do delete(s); delete(ids); delete(results) }
	for i in 0 ..< total {
		id := fmt.aprintf("cmd_%d", i)
		res := fmt.aprintf("{\"command_id\":\"cmd_%d\"}", i)
		append(&ids, id); append(&results, res)
		_, _ = runtime_command_result_idempotent(registry, "brg_x", id, res)
	}

	// The cache never stops: count keeps advancing past the capacity.
	testing.expect_value(t, registry.command_count, total)

	// The most recent `cap` results are still retrievable (this is what a relay
	// waiting on a fresh command needs).
	newest, ok := runtime_command_cached(registry, ids[total - 1])
	testing.expect(t, ok, "the newest command result must still be cached")
	testing.expect_value(t, newest, results[total - 1])
	mid, ok_mid := runtime_command_cached(registry, ids[total - cap]) // oldest still-live
	testing.expect(t, ok_mid, "the oldest still-live result must be cached")
	_ = mid

	// The overflowed-out oldest entries are evicted (bounded memory), not corrupt.
	_, ok_evicted := runtime_command_cached(registry, ids[0])
	testing.expect(t, !ok_evicted, "the oldest overflowed id must be evicted")

	// Idempotent: the first result for an id still wins over a later frame.
	first := "{\"first\":true}"
	second := "{\"second\":true}"
	got1, _ := runtime_command_result_idempotent(registry, "brg_x", "dup_id", first)
	testing.expect_value(t, got1, first)
	got2, existed := runtime_command_result_idempotent(registry, "brg_x", "dup_id", second)
	testing.expect(t, existed, "second frame for a cached id must report a hit")
	testing.expect_value(t, got2, first)
}
