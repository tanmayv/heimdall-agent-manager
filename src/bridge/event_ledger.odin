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
}
bridge_event_ledger_prune_locked :: proc(now: i64) {
    for id, e in bridge_event_ledger {
        expired := now > e.expires_ms && now - e.expires_ms > BRIDGE_LEDGER_MARGIN_MS
        if e.expires_ms == 0 do expired = now > e.at_ms && now - e.at_ms > BRIDGE_LEDGER_FALLBACK_MS
        if expired {
            delete_key(&bridge_event_ledger, id)
            delete(e.id, runtime.heap_allocator())
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
    if !os.exists(path) do return
    raw, read_err := os.read_entire_file(path, context.temp_allocator)
    disk: Bridge_Ledger_Disk
    bad := read_err != nil
    if !bad do bad = json.unmarshal(raw, &disk, allocator = context.temp_allocator) != nil
    bad = bad || disk.version != 1 || len(disk.entries) > BRIDGE_LEDGER_MAX_ENTRIES
    if !bad {
        for e in disk.entries {
            if e.id == "" || e.state < 1 || e.state > 2 || e.effect < 1 || e.effect > 3 { bad = true; break }
        }
    }
    if bad {
        fmt.eprintln("bridge event ledger corrupt:", path)
        corrupt := strings.concatenate({path, ".corrupt"}, context.temp_allocator)
        _ = os.remove(corrupt)
        _ = os.rename(path, corrupt)
        return
    }
    bridge_event_ledger = make(map[string]Bridge_Ledger_Entry, runtime.heap_allocator())
    for e in disk.entries {
        if e.id in bridge_event_ledger { bridge_event_ledger_clear_locked(); _ = os.rename(path, strings.concatenate({path, ".corrupt"}, context.temp_allocator)); return }
        id := strings.clone(e.id, runtime.heap_allocator())
        bridge_event_ledger[id] = {id, Bridge_Ledger_State(e.state), Bridge_Ledger_Effect(e.effect), strings.clone(e.outcome, runtime.heap_allocator()), e.at_ms, e.expires_ms}
    }
    bridge_event_ledger_prune_locked(bridge_event_ledger_now_proc())
}
// Callers prune before taking entry references, so a save cannot invalidate them.
bridge_event_ledger_save_locked :: proc(now: i64) -> bool {
    disk := Bridge_Ledger_Disk{version = 1, entries = make([dynamic]Bridge_Ledger_Disk_Entry, context.temp_allocator)}
    for _, e in bridge_event_ledger do append(&disk.entries, Bridge_Ledger_Disk_Entry{e.id, int(e.state), int(e.effect), e.outcome, e.at_ms, e.expires_ms})
    bytes, err := json.marshal(disk, allocator = context.temp_allocator)
    if err != nil do return false
    path := bridge_event_ledger_path_proc()
    defer delete(path)
    return bridge_retry_atomic_write(path, bytes)
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
    bridge_event_ledger_prune_locked(now_ms)
    if bridge_event_ledger == nil do bridge_event_ledger = make(map[string]Bridge_Ledger_Entry, runtime.heap_allocator())
    old, had := bridge_event_ledger[id]
    if had && old.state == .Done do return true
    if !had && len(bridge_event_ledger) >= BRIDGE_LEDGER_MAX_ENTRIES do return false
    key := old.id if had else strings.clone(id, runtime.heap_allocator())
    bridge_event_ledger[key] = {key, .In_Progress, effect, "", now_ms, expires_ms}
    if !bridge_event_ledger_save_locked(now_ms) {
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
    bridge_event_ledger_prune_locked(now_ms)
    old, had := bridge_event_ledger[id]
    if !had do return false
    e := old
    e.state, e.outcome, e.at_ms = .Done, strings.clone(outcome, runtime.heap_allocator()), now_ms
    bridge_event_ledger[id] = e
    if !bridge_event_ledger_save_locked(now_ms) {
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
        if !bridge_event_ledger_save_locked(now) {
            bridge_event_ledger[e.id] = e
            return
        }
        delete(e.id, runtime.heap_allocator())
        delete(e.outcome, runtime.heap_allocator())
    }
}
