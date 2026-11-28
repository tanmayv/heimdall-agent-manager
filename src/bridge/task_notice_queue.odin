package main

// Task notices wait here, rather than becoming one provider turn per hub frame.
// It is also the PTY runtime's durable inbox (runtime_pty.odin): every queued
// PTY input waits here, FIFO per instance, until the runtime reports a trusted
// idle, and each delivered batch is one turn (CONTRACT-09/18).
// The queue owns heap strings; snapshots and HTTP parsing use the worker's arena.
import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import vm "core:mem/virtual"

BRIDGE_TASK_NOTICE_WINDOW_MS :: i64(2000)
BRIDGE_TASK_NOTICE_MAX :: 512
BRIDGE_TASK_NOTICE_MAX_BYTES :: 1024*1024
BRIDGE_TASK_NOTICE_MAX_AGE_MS :: i64(24*60*60*1000)

Bridge_Task_Notice :: struct {
    instance, task, expected_state, origin, text: string,
    // Admission identity (hub message/command id) and input kind: "" for a
    // notification, BRIDGE_NOTICE_USER_MESSAGE for a user message.
    id, kind: string,
    queued_ms, due_ms: i64,
}
BRIDGE_NOTICE_USER_MESSAGE :: "user_message"
Bridge_Task_Notice_Queue :: struct {
    entries: [dynamic]Bridge_Task_Notice,
}
bridge_task_notices: Bridge_Task_Notice_Queue
bridge_task_notices_mu: sync.Mutex
bridge_task_notices_stop: bool
bridge_task_notice_relay := bridge_local_relay_agent_envelope

bridge_task_notice_same :: proc(a, b: Bridge_Task_Notice) -> bool {
    // A retried admission (same id) is the same input; distinct ids never merge.
    if a.id != "" || b.id != "" do return a.instance == b.instance && a.id == b.id
    return a.instance == b.instance && a.task == b.task && a.expected_state == b.expected_state &&
        a.origin == b.origin && a.text == b.text
}

bridge_task_notice_delete :: proc(n: Bridge_Task_Notice) {
    delete(n.instance); delete(n.task); delete(n.expected_state); delete(n.origin); delete(n.text); delete(n.id); delete(n.kind)
}

bridge_task_notice_clone :: proc(n: Bridge_Task_Notice) -> Bridge_Task_Notice {
    out := n
    out.instance = strings.clone(n.instance); out.task = strings.clone(n.task)
    out.expected_state = strings.clone(n.expected_state); out.origin = strings.clone(n.origin); out.text = strings.clone(n.text)
    out.id = strings.clone(n.id); out.kind = strings.clone(n.kind)
    return out
}

bridge_task_notice_bytes :: proc(n: Bridge_Task_Notice) -> int {
    return len(n.instance)+len(n.task)+len(n.expected_state)+len(n.origin)+len(n.text)+len(n.id)+len(n.kind)
}

// Returns false on pressure: the hub receives accepted, not a false delivery receipt.
// Restores use this same merge, so an entry already queued live is never replayed.
bridge_task_notice_merge :: proc(q: ^Bridge_Task_Notice_Queue, n: Bridge_Task_Notice) -> bool {
    if n.instance == "" || n.text == "" || len(n.text) > 64*1024 ||
        len(n.instance) > 1024 || len(n.task) > 1024 || len(n.origin) > 1024 || len(n.expected_state) > 32 ||
        len(n.id) > 1024 || len(n.kind) > 32 { return false }
    bytes := bridge_task_notice_bytes(n)
    instance_bytes := bytes
    instance_count := 0
    for old in q.entries {
        if bridge_task_notice_same(old, n) do return true
        bytes += bridge_task_notice_bytes(old)
        if old.instance == n.instance { instance_count += 1; instance_bytes += bridge_task_notice_bytes(old) }
    }
    if len(q.entries) >= BRIDGE_TASK_NOTICE_MAX || bytes > BRIDGE_TASK_NOTICE_MAX_BYTES || instance_count >= 128 || instance_bytes > 128*1024 do return false
    append(&q.entries, bridge_task_notice_clone(n))
    return true
}

bridge_task_notice_queue_delete :: proc(q: ^Bridge_Task_Notice_Queue) {
    for n in q.entries do bridge_task_notice_delete(n)
    delete(q.entries); q^ = {}
}

bridge_task_notice_path :: proc() -> string {
    // Use the same per-bridge namespace as local tokens and retry journals.
    tokens := bridge_agent_token_store_path(); defer delete(tokens)
    return strings.concatenate({tokens[:strings.last_index_byte(tokens, '/')], "/task-notices/pending.json"})
}

// Call with the queue mutex held. Atomic owner-only writes match retry journals.
bridge_task_notice_save :: proc() -> bool {
    path := bridge_task_notice_path(); defer delete(path)
    raw, err := json.marshal(bridge_task_notices); defer delete(raw)
    return err == nil && bridge_retry_atomic_write(path, raw)
}

bridge_task_notice_restore :: proc(q: ^Bridge_Task_Notice_Queue, raw: string, now: i64) -> bool {
    if len(raw) > 8*BRIDGE_TASK_NOTICE_MAX_BYTES do return false
    saved: Bridge_Task_Notice_Queue
    defer bridge_task_notice_queue_delete(&saved)
    if json.unmarshal_string(raw, &saved) != nil || len(saved.entries) > BRIDGE_TASK_NOTICE_MAX do return false
    for n in saved.entries {
        if n.queued_ms <= 0 || now-n.queued_ms > BRIDGE_TASK_NOTICE_MAX_AGE_MS do continue
        restored := n
        // A fresh collection window lets restored and reconnect frames merge.
        restored.due_ms = now+BRIDGE_TASK_NOTICE_WINDOW_MS
        if !bridge_task_notice_merge(q, restored) do return false
    }
    return true
}

bridge_task_notice_enqueue :: proc(n: Bridge_Task_Notice) -> bool {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_notices_mu); defer sync.mutex_unlock(&bridge_task_notices_mu)
    if !bridge_task_notice_merge(&bridge_task_notices, n) do return false
    return bridge_task_notice_save()
}

bridge_task_notice_relevant :: proc(n: Bridge_Task_Notice) -> bool {
    if n.task == "" || n.expected_state == "" do return true
    rec, ok := acp_runtime_current_record(n.instance)
    if !ok do return true
    defer { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
    params, _ := json.marshal(struct{task_id: string}{n.task}, allocator = context.temp_allocator)
    reply := bridge_task_notice_relay({"api", "v1", "agent-actions", "tasks", "show"}, "agent.task.show", string(params), rec, 2000)
    defer delete(reply.body)
    // As with N1, failed/unauthorized/unknown reads preserve the notice.
    if !reply.ok || reply.status < 200 || reply.status >= 300 do return true
    obj := acp_event_object(reply.body)
    data, valid := obj["data"].(json.Object)
    if !valid do return true
    state, known := data["state"].(json.String)
    return !known || state == "" || string(state) == n.expected_state
}

bridge_task_notice_text :: proc(batch: []Bridge_Task_Notice) -> string {
    texts := make([dynamic]string, context.temp_allocator)
    for n in batch {
        if !bridge_task_notice_relevant(n) do continue
        append(&texts, n.text)
    }
    return bridge_task_notice_join(texts[:])
}

// One line per batch, FIFO; a repeated line (two message notices from one
// sender) is typed once. Caller owns the result.
bridge_task_notice_join :: proc(texts: []string) -> string {
    b := strings.builder_make()
    for text, i in texts {
        repeated := false
        for prev in texts[:i] do if prev == text do repeated = true
        if repeated do continue
        if strings.builder_len(b) > 0 do strings.write_string(&b, " | ")
        strings.write_string(&b, text)
    }
    return strings.to_string(b)
}

// bridge_task_notice_select returns clones (temp-allocated) of an instance's
// queued user messages whose ids are listed, in queue (FIFO) order.
bridge_task_notice_select :: proc(instance: string, ids: []string) -> []Bridge_Task_Notice {
    out := make([dynamic]Bridge_Task_Notice, context.temp_allocator)
    sync.mutex_lock(&bridge_task_notices_mu); defer sync.mutex_unlock(&bridge_task_notices_mu)
    for n in bridge_task_notices.entries {
        if n.instance != instance || n.kind != BRIDGE_NOTICE_USER_MESSAGE || n.id == "" do continue
        for id in ids do if id == n.id { append(&out, bridge_task_notice_clone_temp(n)); break }
    }
    return out[:]
}

bridge_task_notice_clone_temp :: proc(n: Bridge_Task_Notice) -> Bridge_Task_Notice {
    context.allocator = context.temp_allocator
    return bridge_task_notice_clone(n)
}

// bridge_task_notice_remove_ids drops an instance's queued inputs with these
// ids (delivered by Send now, or already read). Returns how many were removed.
bridge_task_notice_remove_ids :: proc(instance: string, ids: []string) -> int {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_notices_mu); defer sync.mutex_unlock(&bridge_task_notices_mu)
    removed := 0
    for i := 0; i < len(bridge_task_notices.entries); {
        n := bridge_task_notices.entries[i]
        listed := false
        for id in ids do if n.instance == instance && n.id != "" && n.id == id do listed = true
        if listed { bridge_task_notice_delete(n); ordered_remove(&bridge_task_notices.entries, i); removed += 1 } else { i += 1 }
    }
    if removed > 0 do _ = bridge_task_notice_save()
    return removed
}

// All hub relevance reads run on the notice worker, outside ACP ownership and
// dispatcher locks. Busy notices stay in the shared, persisted queue; readiness
// is checked cheaply before the reads and again when starting the prompt.
bridge_task_notice_deliver :: proc(batch: []Bridge_Task_Notice) -> bool {
    if len(batch) == 0 do return true
    instance := batch[0].instance
    // Restore runs before asynchronous runtime reconciliation. An unknown pipe
    // must not be mistaken for a PTY and acknowledged by a one-way socket write.
    snap, present := bridge_runtime_instance_snapshot(instance)
    if !present || !snap.pty_process_alive || snap.stopped_intent_unix_ms != 0 || !snap.start_success_seen do return false
    // Notices never interrupt (CONTRACT-07): the runtime says whether a batch
    // can start a turn now, and a busy agent keeps it queued here.
    rt := bridge_runtime_for(instance)
    if rt == nil || rt.notices_ready == nil || rt.deliver_notices == nil || !rt.notices_ready(instance) do return false
    text := bridge_task_notice_text(batch); defer delete(text)
    if text == "" do return true
    return rt.deliver_notices(instance, text)
}

// A runtime reported a trusted idle (runtime_iface.odin): its queued notices
// are due at the next tick. Leaf lock: the event sink may hold the runtime mutex.
bridge_task_notice_kicks: [dynamic]string
bridge_task_notice_kicks_mu: sync.Mutex

bridge_task_notice_kick :: proc(instance: string) {
    heap := runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_notice_kicks_mu); defer sync.mutex_unlock(&bridge_task_notice_kicks_mu)
    for k in bridge_task_notice_kicks do if k == instance do return
    if len(bridge_task_notice_kicks) >= 1024 do return
    if bridge_task_notice_kicks.allocator.procedure == nil do bridge_task_notice_kicks = make([dynamic]string, heap)
    append(&bridge_task_notice_kicks, strings.clone(instance, heap))
}

// Call with bridge_task_notices_mu held.
bridge_task_notice_apply_kicks_locked :: proc(now: i64) {
    heap := runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_notice_kicks_mu); defer sync.mutex_unlock(&bridge_task_notice_kicks_mu)
    for k in bridge_task_notice_kicks {
        for &n in bridge_task_notices.entries do if n.instance == k && n.due_ms > now do n.due_ms = now
        delete(k, heap)
    }
    clear(&bridge_task_notice_kicks)
}

// One batch per instance; do not hold the producer lock across HTTP or provider I/O.
bridge_task_notice_tick :: proc(now: i64) {
    batch := make([dynamic]Bridge_Task_Notice, allocator = context.temp_allocator)
    sync.mutex_lock(&bridge_task_notices_mu)
    bridge_task_notice_apply_kicks_locked(now)
    i := 0
    expired := false
    for i < len(bridge_task_notices.entries) {
        n := bridge_task_notices.entries[i]
        if now-n.queued_ms > BRIDGE_TASK_NOTICE_MAX_AGE_MS {
            bridge_task_notice_delete(n); ordered_remove(&bridge_task_notices.entries, i)
            expired = true
        } else { i += 1 }
    }
    if expired do _ = bridge_task_notice_save()
    instance := ""
    for n in bridge_task_notices.entries {
        if n.due_ms <= now { instance = n.instance; break }
    }
    for n in bridge_task_notices.entries {
        if n.instance == instance do append(&batch, bridge_task_notice_clone(n))
    }
    sync.mutex_unlock(&bridge_task_notices_mu)
    defer for n in batch do bridge_task_notice_delete(n)
    if len(batch) == 0 do return
    delivered := bridge_task_notice_deliver(batch[:])
    sync.mutex_lock(&bridge_task_notices_mu); defer sync.mutex_unlock(&bridge_task_notices_mu)
    i = 0
    removed := false
    for i < len(bridge_task_notices.entries) {
        n := &bridge_task_notices.entries[i]
        matched := false
        for sent in batch do if bridge_task_notice_same(n^, sent) do matched = true
        if delivered && matched {
            bridge_task_notice_delete(n^); ordered_remove(&bridge_task_notices.entries, i)
            removed = true
        } else {
            if matched do n.due_ms = now+BRIDGE_TASK_NOTICE_WINDOW_MS
            i += 1
        }
    }
    // Retry due times are deliberately reset by restore; do not fsync the
    // entire queue just because a busy/stopped runtime cannot accept a batch.
    if removed do _ = bridge_task_notice_save()
}

bridge_task_notice_worker :: proc() {
    context.allocator = runtime.heap_allocator()
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    for !sync.atomic_load(&bridge_task_notices_stop) {
        bridge_task_notice_tick(bridge_runtime_now_ms())
        free_all(context.temp_allocator)
        time.sleep(100*time.Millisecond)
    }
}

bridge_task_notice_start :: proc() -> ^thread.Thread {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_notices_mu)
    path := bridge_task_notice_path(); defer delete(path)
    info, stat_err := os.stat(path, context.temp_allocator)
    if stat_err == nil && info.type == .Regular && info.size <= 8*BRIDGE_TASK_NOTICE_MAX_BYTES {
        raw, err := os.read_entire_file(path, context.allocator); defer delete(raw)
        if err == nil do _ = bridge_task_notice_restore(&bridge_task_notices, string(raw), bridge_runtime_now_ms())
    }
    sync.mutex_unlock(&bridge_task_notices_mu)
    sync.atomic_store(&bridge_task_notices_stop, false)
    return thread.create_and_start(bridge_task_notice_worker)
}

bridge_task_notice_stop :: proc(worker: ^thread.Thread) {
    if worker == nil do return
    sync.atomic_store(&bridge_task_notices_stop, true)
    thread.join(worker); thread.destroy(worker)
    sync.mutex_lock(&bridge_task_notices_mu); defer sync.mutex_unlock(&bridge_task_notices_mu)
    bridge_task_notice_queue_delete(&bridge_task_notices)
}
