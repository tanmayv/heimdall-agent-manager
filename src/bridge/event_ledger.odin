package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

Bridge_Ledger_State :: enum { In_Progress = 1, Done = 2 }
Bridge_Ledger_Effect :: enum { Type = 1, Start = 2, Flow = 3 }
Bridge_Ledger_Entry :: struct {
    id: string,
    state: Bridge_Ledger_State,
    effect: Bridge_Ledger_Effect,
    outcome: string,
    at_ms, expires_ms: i64,
}
BRIDGE_LEDGER_MAX_ENTRIES :: 4096
BRIDGE_LEDGER_MARGIN_MS :: i64(10 * 60 * 1000)
BRIDGE_LEDGER_FALLBACK_MS :: i64(48 * 60 * 60 * 1000)
Bridge_Ledger_Disk_Entry :: struct {
    id: string,
    state, effect: int,
    outcome: string,
    at_ms, expires_ms: i64,
}
Bridge_Ledger_Disk :: struct { version: int, entries: [dynamic]Bridge_Ledger_Disk_Entry }
// One fsynced record per transition; a single-file atomic checkpoint every
// 8192 records bounds replay/disk growth and amortizes the full-map rewrite.
BRIDGE_LEDGER_CHECKPOINT_RECORDS :: 2 * BRIDGE_LEDGER_MAX_ENTRIES
Bridge_Ledger_Record :: struct { entry: Bridge_Ledger_Disk_Entry, forget: bool, pruned: []string }
bridge_event_ledger_records: int
bridge_event_ledger_journal: bool
bridge_event_ledger_failed: bool // unknown load state; requires operator repair/reload
bridge_event_ledger_io_failed: bool // known memory state; next mutation checkpoints
bridge_event_ledger_pruned: [dynamic]string
bridge_event_ledger_written_bytes: i64 // durability-path measurement, under mutex
bridge_event_ledger_mutex: sync.Mutex
bridge_event_ledger: map[string]Bridge_Ledger_Entry
bridge_event_ledger_path_proc: proc() -> string = bridge_event_ledger_path
bridge_event_ledger_now_proc: proc() -> i64 = bridge_runtime_now_ms

bridge_event_ledger_path :: proc() -> string {
    tokens := bridge_agent_token_store_path()
    defer delete(tokens)
    slash := strings.last_index_any(tokens, "/\\")
    return strings.concatenate({tokens[:slash], "/event-ledger-v1.json"})
}
bridge_event_ledger_clear_locked :: proc() {
    for _, e in bridge_event_ledger {
        delete(e.id, runtime.heap_allocator())
        delete(e.outcome, runtime.heap_allocator())
    }
    delete(bridge_event_ledger)
    bridge_event_ledger = nil
    bridge_event_ledger_records = 0
    bridge_event_ledger_journal = false
    bridge_event_ledger_failed = false
    bridge_event_ledger_io_failed = false
    bridge_event_ledger_clear_pruned_locked()
}
bridge_event_ledger_clear_pruned_locked :: proc() {
    for id in bridge_event_ledger_pruned do delete(id, runtime.heap_allocator())
    delete(bridge_event_ledger_pruned)
    bridge_event_ledger_pruned = nil
}
bridge_event_ledger_prune_locked :: proc(now: i64) {
    for id, e in bridge_event_ledger {
        expired := now > e.expires_ms && now - e.expires_ms > BRIDGE_LEDGER_MARGIN_MS
        if e.expires_ms == 0 do expired = now > e.at_ms && now - e.at_ms > BRIDGE_LEDGER_FALLBACK_MS
        if expired {
            delete_key(&bridge_event_ledger, id)
            if bridge_event_ledger_pruned == nil do bridge_event_ledger_pruned = make([dynamic]string, runtime.heap_allocator())
            append(&bridge_event_ledger_pruned, e.id)
            delete(e.outcome, runtime.heap_allocator())
        }
    }
}
bridge_event_ledger_load :: proc() {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    bridge_event_ledger_clear_locked()
    path := bridge_event_ledger_path_proc()
    defer delete(path)
    _, stat_err := os.stat(path, context.temp_allocator)
    if stat_err == .Not_Exist do return
    if stat_err != nil { bridge_event_ledger_failed = true; return }
    raw, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil { bridge_event_ledger_failed = true; return }
    disk: Bridge_Ledger_Disk
    first := strings.index_byte(string(raw), 10)
    // Legacy snapshots may contain formatting or a trailing newline. Decode
    // the complete v1 document before interpreting v2 newline framing.
    whole_err := json.unmarshal(raw, &disk, allocator = context.temp_allocator)
    legacy := whole_err == nil && disk.version == 1
    bad := false
    if !legacy {
        disk = {}
        snapshot := raw[:first] if first >= 0 else raw
        bad = json.unmarshal(snapshot, &disk, allocator = context.temp_allocator) != nil
    }
    bad = bad || (disk.version != 1 && disk.version != 2)
    if !bad {
        for e in disk.entries {
            if !bridge_event_ledger_valid(e) { bad = true; break }
        }
    }
    if bad {
        fmt.eprintln("bridge event ledger corrupt:", path)
        // Do not quarantine and start empty: that would erase the dedup
        // horizon. Retain the file for repair and deny new effects on reload.
        bridge_event_ledger_failed = true
        return
    }
    bridge_event_ledger = make(map[string]Bridge_Ledger_Entry, runtime.heap_allocator())
    for e in disk.entries {
        if e.id in bridge_event_ledger { bridge_event_ledger_failed = true; return }
        bridge_event_ledger_apply_locked(e, false)
    }
    if disk.version == 2 {
        if first < 0 { bridge_event_ledger_failed = true; return }
        rest := string(raw[first+1:])
        for len(rest) > 0 {
            end := strings.index_byte(rest, 10)
            // A crash can leave only the last append incomplete. Retain every
            // complete record and force an atomic checkpoint before next use.
            if end < 0 { break }
            record: Bridge_Ledger_Record
            if json.unmarshal(transmute([]byte)rest[:end], &record, allocator = context.temp_allocator) != nil ||
               (!record.forget && !bridge_event_ledger_valid(record.entry)) || record.entry.id == "" {
                bridge_event_ledger_failed = true
                return
            }
            for id in record.pruned {
                if id == "" { bridge_event_ledger_failed = true; return }
                bridge_event_ledger_apply_locked(Bridge_Ledger_Disk_Entry{id = id}, true)
            }
            bridge_event_ledger_apply_locked(record.entry, record.forget)
            bridge_event_ledger_records += 1
            rest = rest[end+1:]
        }
        bridge_event_ledger_journal = len(rest) == 0
    }
    bridge_event_ledger_prune_locked(bridge_event_ledger_now_proc())
    // An old journal plus a clock rollback can recover more than the admission
    // cap. Preserve those dedup entries; begin refuses new IDs until they expire.
}
bridge_event_ledger_valid :: proc(e: Bridge_Ledger_Disk_Entry) -> bool {
    return e.id != "" && e.state >= 1 && e.state <= 2 && e.effect >= 1 && e.effect <= 3
}
bridge_event_ledger_apply_locked :: proc(e: Bridge_Ledger_Disk_Entry, forget: bool) {
    old, had := bridge_event_ledger[e.id]
    if had {
        delete_key(&bridge_event_ledger, e.id)
        delete(old.id, runtime.heap_allocator())
        delete(old.outcome, runtime.heap_allocator())
    }
    if forget do return
    id := strings.clone(e.id, runtime.heap_allocator())
    bridge_event_ledger[id] = {id, Bridge_Ledger_State(e.state), Bridge_Ledger_Effect(e.effect), strings.clone(e.outcome, runtime.heap_allocator()), e.at_ms, e.expires_ms}
}
bridge_event_ledger_disk_entry :: proc(e: Bridge_Ledger_Entry) -> Bridge_Ledger_Disk_Entry {
    return {e.id, int(e.state), int(e.effect), e.outcome, e.at_ms, e.expires_ms}
}
// The caller has staged the new map state. No effect may run before this
// succeeds. Any ambiguous write failure fences later writes until reload.
bridge_event_ledger_save_locked :: proc(id: string, forget := false) -> bool {
    if bridge_event_ledger_failed do return false
    path := bridge_event_ledger_path_proc()
    defer delete(path)
    bytes: []byte
    checkpoint := !bridge_event_ledger_journal || bridge_event_ledger_records >= BRIDGE_LEDGER_CHECKPOINT_RECORDS
    if checkpoint {
        disk := Bridge_Ledger_Disk{version = 2, entries = make([dynamic]Bridge_Ledger_Disk_Entry, context.temp_allocator)}
        for _, e in bridge_event_ledger do append(&disk.entries, bridge_event_ledger_disk_entry(e))
        encoded, err := json.marshal(disk, allocator = context.temp_allocator)
        if err != nil do return false
        bytes = transmute([]byte)strings.concatenate({string(encoded), "\n"}, context.temp_allocator)
        if !bridge_retry_atomic_write(path, bytes) { bridge_event_ledger_journal = false; bridge_event_ledger_io_failed = true; return false }
        bridge_event_ledger_journal = true
        bridge_event_ledger_records = 0
    } else {
        e := Bridge_Ledger_Disk_Entry{id = id} if forget else bridge_event_ledger_disk_entry(bridge_event_ledger[id])
        encoded, err := json.marshal(Bridge_Ledger_Record{e, forget, bridge_event_ledger_pruned[:]}, allocator = context.temp_allocator)
        if err != nil do return false
        bytes = transmute([]byte)strings.concatenate({string(encoded), "\n"}, context.temp_allocator)
        f, open_err := os.open(path, {.Write, .Append}, {.Read_User, .Write_User})
        if open_err != nil { bridge_event_ledger_journal = false; bridge_event_ledger_io_failed = true; return false }
        n, write_err := os.write(f, bytes)
        sync_err := os.sync(f)
        close_err := os.close(f)
        if write_err != nil || n != len(bytes) || sync_err != nil || close_err != nil {
            bridge_event_ledger_journal = false
            bridge_event_ledger_io_failed = true
            return false
        }
        bridge_event_ledger_records += 1
    }
    bridge_event_ledger_io_failed = false
    bridge_event_ledger_clear_pruned_locked()
    bridge_event_ledger_written_bytes += i64(len(bytes))
    return true
}
bridge_event_ledger_get :: proc(id: string) -> (Bridge_Ledger_Entry, bool) {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    e, found := bridge_event_ledger[id]
    if !found do return {}, false
    e.id = strings.clone(e.id, context.temp_allocator)
    e.outcome = strings.clone(e.outcome, context.temp_allocator)
    return e, true
}
bridge_event_ledger_begin :: proc(id: string, effect: Bridge_Ledger_Effect, now_ms, expires_ms: i64) -> bool {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    if bridge_event_ledger_failed do return false
    bridge_event_ledger_prune_locked(now_ms)
    if bridge_event_ledger == nil do bridge_event_ledger = make(map[string]Bridge_Ledger_Entry, runtime.heap_allocator())
    old, had := bridge_event_ledger[id]
    if had && old.state == .Done do return true
    if !had && len(bridge_event_ledger) >= BRIDGE_LEDGER_MAX_ENTRIES do return false
    key := old.id if had else strings.clone(id, runtime.heap_allocator())
    bridge_event_ledger[key] = {key, .In_Progress, effect, "", now_ms, expires_ms}
    if !bridge_event_ledger_save_locked(id) {
        if had { bridge_event_ledger[key] = old }
        else { delete_key(&bridge_event_ledger, key); delete(key, runtime.heap_allocator()) }
        return false
    }
    if had do delete(old.outcome, runtime.heap_allocator())
    return true
}
bridge_event_ledger_done :: proc(id, outcome: string, now_ms: i64) -> bool {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    if bridge_event_ledger_failed do return false
    bridge_event_ledger_prune_locked(now_ms)
    old, had := bridge_event_ledger[id]
    if !had do return false
    e := old
    e.state, e.outcome, e.at_ms = .Done, strings.clone(outcome, runtime.heap_allocator()), now_ms
    bridge_event_ledger[id] = e
    if !bridge_event_ledger_save_locked(id) {
        bridge_event_ledger[id] = old
        delete(e.outcome, runtime.heap_allocator())
        return false
    }
    delete(old.outcome, runtime.heap_allocator())
    return true
}
bridge_event_ledger_forget :: proc(id: string) {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    now := bridge_event_ledger_now_proc()
    bridge_event_ledger_prune_locked(now)
    e, had := bridge_event_ledger[id]
    if had && e.state == .In_Progress {
        delete_key(&bridge_event_ledger, id)
        if !bridge_event_ledger_save_locked(id, true) {
            bridge_event_ledger[e.id] = e
            return
        }
        delete(e.id, runtime.heap_allocator())
        delete(e.outcome, runtime.heap_allocator())
    }
}

// A corrupt/unreadable load has unknown durable state and stays unavailable.
// Transient write failures preserve known memory state and retry a checkpoint.
bridge_event_ledger_failure_reason :: proc() -> string {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    if bridge_event_ledger_failed || bridge_event_ledger_io_failed do return "ledger_unavailable"
    return "ledger_full"
}
bridge_event_ledger_health_json :: proc() -> string {
    sync.mutex_lock(&bridge_event_ledger_mutex)
    defer sync.mutex_unlock(&bridge_event_ledger_mutex)
    status := "ready"
    if bridge_event_ledger_failed {status = "unavailable"}
    else if bridge_event_ledger_io_failed {status = "checkpoint_pending"}
    else if len(bridge_event_ledger) >= BRIDGE_LEDGER_MAX_ENTRIES {status = "full"}
    bytes, err := json.marshal(struct {status: string, entries, capacity: int}{status, len(bridge_event_ledger), BRIDGE_LEDGER_MAX_ENTRIES})
    if err != nil do return ""
    return string(bytes)
}
