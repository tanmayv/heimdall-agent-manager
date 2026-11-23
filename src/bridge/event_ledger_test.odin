package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

bridge_ledger_test_dir: string
bridge_ledger_test_clock: i64
bridge_ledger_test_path :: proc() -> string { return strings.concatenate({bridge_ledger_test_dir, "/event-ledger-v1.json"}) }
bridge_ledger_test_now :: proc() -> i64 { return bridge_ledger_test_clock }

bridge_ledger_test_run :: proc(t: ^testing.T, scenario: proc(t: ^testing.T)) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    {
        saved_path, saved_now := bridge_event_ledger_path_proc, bridge_event_ledger_now_proc
        bridge_ledger_test_dir = fmt.aprintf("%s/.cache/heimdall-tests/t17-ledger-%d", os.get_env("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
        bridge_event_ledger_path_proc, bridge_event_ledger_now_proc = bridge_ledger_test_path, bridge_ledger_test_now
        bridge_ledger_test_clock = 1_000_000
        bridge_event_ledger_load()
        scenario(t)
        bridge_event_ledger_clear_locked()
        path := bridge_ledger_test_path()
        _ = os.remove(path)
        _ = os.remove(strings.concatenate({path, ".corrupt"}, context.temp_allocator))
        _ = os.remove(bridge_ledger_test_dir)
        delete(path)
        delete(bridge_ledger_test_dir)
        bridge_ledger_test_dir = ""
        bridge_event_ledger_path_proc, bridge_event_ledger_now_proc = saved_path, saved_now
    }
    testing.expect_value(t, len(track.allocation_map), 0)
}
ledger_restart_scenario :: proc(t: ^testing.T) {
    testing.expect(t, bridge_event_ledger_begin("dlv_restart", .Start, bridge_ledger_test_clock, 2_000_000))
    testing.expect(t, bridge_event_ledger_done("dlv_restart", "started", bridge_ledger_test_clock))
    bridge_event_ledger_load()
    e, found := bridge_event_ledger_get("dlv_restart")
    testing.expect(t, found && e.state == .Done && e.outcome == "started" && e.effect == .Start && e.expires_ms == 2_000_000)
}
@(test)
test_ledger_survives_restart :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_restart_scenario) }

ledger_expiry_scenario :: proc(t: ^testing.T) {
    now := bridge_ledger_test_clock
    testing.expect(t, bridge_event_ledger_begin("inside", .Type, now, now - BRIDGE_LEDGER_MARGIN_MS + 1))
    testing.expect(t, bridge_event_ledger_begin("fallback", .Type, now, 0))
    bridge_ledger_test_clock = now + 2
    testing.expect(t, bridge_event_ledger_begin("new", .Type, now + 2, now + 3))
    _, had := bridge_event_ledger_get("inside"); testing.expect(t, !had)
    _, had = bridge_event_ledger_get("fallback"); testing.expect(t, had)
    bridge_ledger_test_clock = now + BRIDGE_LEDGER_FALLBACK_MS + 1
    testing.expect(t, bridge_event_ledger_begin("last", .Type, bridge_ledger_test_clock, 0))
    _, had = bridge_event_ledger_get("fallback"); testing.expect(t, !had)
}
@(test)
test_ledger_evicts_by_expiry_plus_margin :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_expiry_scenario) }

ledger_rate_scenario :: proc(t: ^testing.T) {
    for i in 0..<1000 {
        now := i64(1_000_000) + i64(i) * 36_000
        bridge_ledger_test_clock = now
        testing.expect(t, bridge_event_ledger_begin(fmt.tprintf("dlv_%d", i), .Type, now, now + 3_600_000))
        testing.expect(t, len(bridge_event_ledger) <= 120)
    }
}
@(test)
test_ledger_holds_rate_times_lifetime :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_rate_scenario) }

ledger_corrupt_scenario :: proc(t: ^testing.T) {
    path := bridge_ledger_test_path(); defer delete(path)
    for raw in ([]string{"{broken", "{\"version\":2,\"entries\":[]}"}) {
        testing.expect(t, bridge_retry_atomic_write(path, transmute([]byte)raw))
        bridge_event_ledger_load()
        testing.expect_value(t, len(bridge_event_ledger), 0)
        testing.expect(t, os.exists(path))
        testing.expect(t, bridge_event_ledger_failed)
        testing.expect(t, !bridge_event_ledger_begin("unsafe", .Type, bridge_ledger_test_clock, 0))
    }
    disk := Bridge_Ledger_Disk{version = 1, entries = make([dynamic]Bridge_Ledger_Disk_Entry, context.temp_allocator)}
    for i in 0..<5000 do append(&disk.entries, Bridge_Ledger_Disk_Entry{id = fmt.tprintf("e%d", i), state = 2, effect = 1})
    bytes, _ := json.marshal(disk, allocator = context.temp_allocator)
    testing.expect(t, bridge_retry_atomic_write(path, bytes))
    bridge_event_ledger_load()
    testing.expect_value(t, len(bridge_event_ledger), 0)
}
@(test)
test_ledger_corrupt_file_fails_closed :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_corrupt_scenario) }

ledger_private_scenario :: proc(t: ^testing.T) {
    testing.expect(t, bridge_event_ledger_begin("private", .Type, bridge_ledger_test_clock, 0))
    when ODIN_OS != .Windows {
        path := bridge_ledger_test_path(); defer delete(path)
        f, fe := os.stat(path, context.temp_allocator)
        d, de := os.stat(bridge_ledger_test_dir, context.temp_allocator)
        testing.expect(t, fe == nil && de == nil)
        testing.expect_value(t, f.mode, os.Permissions{.Read_User, .Write_User})
        testing.expect_value(t, d.mode, os.Permissions{.Read_User, .Write_User, .Execute_User})
    }
}
@(test)
test_ledger_file_is_private :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_private_scenario) }


ledger_cost_scenario :: proc(t: ^testing.T) {
    for i in 0..<1000 {
        id := fmt.tprintf("cost_%04d", i)
        before := bridge_event_ledger_written_bytes
        testing.expect(t, bridge_event_ledger_begin(id, .Type, bridge_ledger_test_clock, 0))
        begin_bytes := bridge_event_ledger_written_bytes - before
        before = bridge_event_ledger_written_bytes
        testing.expect(t, bridge_event_ledger_done(id, "notified", bridge_ledger_test_clock))
        done_bytes := bridge_event_ledger_written_bytes - before
        testing.expect(t, begin_bytes < 256 && done_bytes < 256)
        if i == 0 || i == 99 || i == 999 do fmt.printf("ledger entries=%d begin=%d done=%d bytes written\n", i+1, begin_bytes, done_bytes)
    }
    bridge_event_ledger_load()
    testing.expect_value(t, len(bridge_event_ledger), 1000)
}
@(test)
test_ledger_write_cost :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_cost_scenario) }

ledger_test_append :: proc(t: ^testing.T, raw: string) {
    path := bridge_ledger_test_path(); defer delete(path)
    f, err := os.open(path, {.Write, .Append})
    if !testing.expect(t, err == nil) do return
    n, we := os.write(f, transmute([]byte)raw)
    testing.expect(t, we == nil && n == len(raw))
    testing.expect(t, os.sync(f) == nil)
    testing.expect(t, os.close(f) == nil)
}
ledger_torn_tail_scenario :: proc(t: ^testing.T) {
    now := bridge_ledger_test_clock
    testing.expect(t, bridge_event_ledger_begin("snapshot", .Start, now, 0))
    testing.expect(t, bridge_event_ledger_begin("before_effect", .Start, now, now + 1000))
    // Reload before performing the effect: successful begin is already durable.
    bridge_event_ledger_load()
    e, found := bridge_event_ledger_get("before_effect")
    testing.expect(t, found && e.state == .In_Progress && e.effect == .Start)
    // A killed writer can leave an incomplete final append. It must neither
    // discard prior begins nor hide later appends behind that incomplete tail.
    ledger_test_append(t, "{\"entry\":{\"id\":\"torn")
    bridge_event_ledger_load()
    e, found = bridge_event_ledger_get("before_effect")
    testing.expect(t, found && e.state == .In_Progress && !bridge_event_ledger_failed)
    testing.expect(t, !bridge_event_ledger_journal)
    testing.expect(t, bridge_event_ledger_done("before_effect", "started", now))
    bridge_event_ledger_load()
    e, found = bridge_event_ledger_get("before_effect")
    testing.expect(t, found && e.state == .Done && e.outcome == "started")
    testing.expect(t, bridge_event_ledger_begin("forgotten", .Type, now, 0))
    bridge_event_ledger_forget("forgotten")
    bridge_event_ledger_load()
    _, found = bridge_event_ledger_get("forgotten")
    testing.expect(t, !found)
}
@(test)
test_ledger_durable_begin_and_torn_tail :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_torn_tail_scenario) }

ledger_migration_checkpoint_scenario :: proc(t: ^testing.T) {
    now := bridge_ledger_test_clock
    path := bridge_ledger_test_path(); defer delete(path)
    disk := Bridge_Ledger_Disk{version = 1, entries = make([dynamic]Bridge_Ledger_Disk_Entry, context.temp_allocator)}
    append(&disk.entries, Bridge_Ledger_Disk_Entry{"legacy", 2, 1, "notified", now, now + 1000})
    bytes, _ := json.marshal(disk, allocator = context.temp_allocator)
    legacy := strings.concatenate({"\n", string(bytes), "\n"}, context.temp_allocator)
    testing.expect(t, bridge_retry_atomic_write(path, transmute([]byte)legacy))
    bridge_event_ledger_load()
    testing.expect(t, bridge_event_ledger_begin("new", .Start, now, 0))
    testing.expect(t, bridge_event_ledger_journal)
    testing.expect(t, bridge_event_ledger_done("new", "started", now))
    bridge_event_ledger_records = BRIDGE_LEDGER_CHECKPOINT_RECORDS
    testing.expect(t, bridge_event_ledger_begin("checkpointed", .Type, now, 0))
    testing.expect_value(t, bridge_event_ledger_records, 0)
    // Crash before atomic replacement: the partial .tmp is never replayed.
    tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file_from_string(tmp, "{partial checkpoint") == nil)
    bridge_event_ledger_load()
    _ = os.remove(tmp)
    e, found := bridge_event_ledger_get("legacy")
    testing.expect(t, found && e.state == .Done && e.outcome == "notified" && e.expires_ms == now + 1000)
    e, found = bridge_event_ledger_get("new")
    testing.expect(t, found && e.state == .Done && e.effect == .Start)
    _, found = bridge_event_ledger_get("checkpointed")
    testing.expect(t, found)
}
@(test)
test_ledger_migrates_and_checkpoints_without_losing_dedup :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_migration_checkpoint_scenario) }

ledger_failed_append_scenario :: proc(t: ^testing.T) {
    now := bridge_ledger_test_clock
    testing.expect(t, bridge_event_ledger_begin("durable", .Type, now, 0))
    testing.expect(t, bridge_event_ledger_done("durable", "notified", now))
    when ODIN_OS != .Windows {
        path := bridge_ledger_test_path(); defer delete(path)
        testing.expect(t, os.chmod(path, {.Read_User}) == nil)
        testing.expect(t, !bridge_event_ledger_begin("no_effect", .Start, now, 0))
        testing.expect(t, os.chmod(path, {.Read_User, .Write_User}) == nil)
        // Repairing permissions alone cannot clear an ambiguous-write fence.
        testing.expect(t, !bridge_event_ledger_begin("still_fenced", .Start, now, 0))
        bridge_event_ledger_load()
        e, found := bridge_event_ledger_get("durable")
        testing.expect(t, found && e.state == .Done)
        _, found = bridge_event_ledger_get("no_effect")
        testing.expect(t, !found)
        testing.expect(t, bridge_event_ledger_begin("recovered", .Start, now, 0))
    }
    ledger_test_append(t, "{malformed complete record}\n")
    bridge_event_ledger_load()
    testing.expect(t, bridge_event_ledger_failed)
    testing.expect(t, !bridge_event_ledger_begin("unsafe", .Type, now, 0))
}
@(test)
test_ledger_append_failure_and_corruption_fail_closed :: proc(t: ^testing.T) { bridge_ledger_test_run(t, ledger_failed_append_scenario) }
