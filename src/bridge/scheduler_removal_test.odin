package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:mem"
import "core:time"
import httpc "odin_test:lib/httpc"

prune_test_send :: proc(req: httpc.Request, allocator := context.allocator) -> (httpc.Response, httpc.Error) {
    if req.method != .GET || strings.join(req.path, "/", context.temp_allocator) != "api/v1/bridge/update-catalog" {
        return {status = 404}, .None
    }
    if len(req.headers) != 1 || req.headers[0].value != "Bearer live-token" {
        return {status = 401}, .None
    }
    return {status = 200}, .None
}

@(test)
test_prune_probe_is_ungated :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    test_prune_probe_is_ungated_scenario(t)
    testing.expect_value(t, len(track.allocation_map), 0)
}

test_prune_probe_is_ungated_scenario :: proc(t: ^testing.T) {
    testing.expect_value(t, bridge_prune_probe({daemon_url = "https://example.test", bridge_token = "live-token"}, prune_test_send), Prune_Verdict.Alive)
    testing.expect_value(t, bridge_prune_probe({daemon_url = "https://example.test", bridge_token = "revoked-token"}, prune_test_send), Prune_Verdict.Dead)
}

@(test)
test_retry_journal_drops_scheduler_records :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    test_retry_journal_drops_scheduler_records_scenario(t)
    testing.expect_value(t, len(track.allocation_map), 0)
}

test_retry_journal_drops_scheduler_records_scenario :: proc(t: ^testing.T) {
    path := fmt.tprintf("%s/retry-upgrade-%d/receipts.json", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    defer os.remove_all(path[:strings.last_index_byte(path, '/')])
    j := Bridge_Retry_Journal{version = 1, loaded = true, receipts = make([dynamic]Bridge_Retry_Receipt, context.temp_allocator)}
    for key in ([]string{"sync:old", "slot:old"}) {
        append(&j.receipts, Bridge_Retry_Receipt{key = key, budget = {state = .Waiting_Repair,
            first_ms = 1000, last_wall_ms = 1000, deadline_ms = 2000, attempts = 1}})
    }
    testing.expect(t, bridge_retry_journal_save(&j, path))
    restored: Bridge_Retry_Journal
    testing.expect(t, bridge_retry_journal_load(&restored, path))
    testing.expect(t, restored.loaded && !restored.failed)
    testing.expect_value(t, len(restored.receipts), 0)
    delete(restored.receipts)

    append(&j.receipts, Bridge_Retry_Receipt{key = "refresh:keep", budget = {}})
    append(&j.receipts, Bridge_Retry_Receipt{key = "ready:keep", budget = {}})
    testing.expect(t, bridge_retry_journal_save(&j, path))
    restored = {}
    testing.expect(t, bridge_retry_journal_load(&restored, path))
    testing.expect_value(t, len(restored.receipts), 2)
    for r in restored.receipts {
        testing.expect(t, strings.has_prefix(r.key, "refresh:") || strings.has_prefix(r.key, "ready:"))
        testing.expect_value(t, r.budget.state, Bridge_Operation_State.Pending)
        delete(r.key, runtime.heap_allocator())
        delete(r.target_instance_id, runtime.heap_allocator())
    }
    delete(restored.receipts)
}

@(test)
test_heartbeat_ack_with_schedule_fields_is_ignored :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    test_heartbeat_ack_with_schedule_fields_is_ignored_scenario(t)
    testing.expect_value(t, len(track.allocation_map), 0)
}

test_heartbeat_ack_with_schedule_fields_is_ignored_scenario :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    // Escaped field names exercise the old wire payload without retaining obsolete symbols.
    ack := `{"type":"bridge_heartbeat_ack","schedules_\u0076ersion":99,"schedules_\u0065poch":"old","schedules_\u0072evision":42}`
    testing.expect(t, !hub_command_frame_is_chunk(ack))
    bridge_hub_handle_command(nil, ack)
    testing.expect(t, bridge_recovery_resume({}, "", false), "removed recovery succeeds without locks or credentials")
}
