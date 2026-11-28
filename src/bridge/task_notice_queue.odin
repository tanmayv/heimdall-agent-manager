package main

// Notice policy and the inbox worker, on top of the one bridge inbox
// (bridge_inbox.odin). Nothing here queues input of its own:
//   - task and lease notices are admitted to the instance's inbox (through
//     its runtime when one is up, else straight into the shared store);
//   - relevance: a task notice is delivered only while its hub task is still
//     in the expected state. The worker reads task states over HTTP, outside
//     every runtime lock, into a small cache that each drain consults;
//   - the worker drains the shared inboxes of runtimes that have a delivery
//     target (PTY): at a trusted idle, one turn per FIFO batch, never an
//     interrupt (CONTRACT-07/09/18). An ACP runtime drains its own claimed
//     inbox on its dispatcher (acp_inbox.odin);
//   - the restart replay: at start the worker loads every saved inbox, and
//     upgrades the notice queue file older bridges kept (pending.json).
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import vm "core:mem/virtual"

BRIDGE_TASK_NOTICE_WINDOW_MS :: i64(BRIDGE_INBOX_DEBOUNCE_MS)
BRIDGE_TASK_NOTICE_MAX_AGE_MS :: i64(24*60*60*1000)
// A cached task state is fresh enough to decide a delivery for this long; a
// requested read that has not happened by the deadline fails open.
BRIDGE_TASK_STATE_FRESH_MS :: i64(3000)
BRIDGE_TASK_STATE_DEADLINE_MS :: i64(5000)
BRIDGE_NOTICE_USER_MESSAGE :: "user_message"

bridge_task_notices_stop: bool
bridge_task_notice_relay := bridge_local_relay_agent_envelope

// ---- admission ----------------------------------------------------------------

// bridge_task_notice_enqueue admits a task or lease notice: to the instance's
// runtime when one owns it, else to its inbox file, which the runtime drains
// once it is up. False: not durably admitted (the hub keeps it pending).
bridge_task_notice_enqueue :: proc(instance: string, input: Runtime_Input) -> bool {
    if rt := bridge_runtime_owner(instance); rt != nil && bridge_runtime_submit_to(rt, instance, input, .Queue) do return true
    return bridge_inbox_admit_shared(instance, input)
}

bridge_inbox_input_from :: proc(input: Runtime_Input, now: i64) -> Bridge_Inbox_Input {
    context.allocator = runtime.heap_allocator()
    user := input.kind == .User_Message
    id := input.id
    if id == "" do id = fmt.tprintf("%s_%d", "input" if user else "notice", time.tick_now()._nsec)
    // Shared-store notifications always get a turn: the PTY runtime has no
    // context-only lane, and a wake must never wait for an unrelated turn.
    return {id = strings.clone(id), text = strings.clone(input.text), lane = .Steer if user else .Wake,
        key = strings.clone(input.key if input.key != "" else input.task), kind = strings.clone(BRIDGE_NOTICE_USER_MESSAGE if user else input.origin),
        task = strings.clone(input.task), expected_state = strings.clone(input.expected_state), queued_ms = now}
}

// bridge_inbox_admit_shared admits to an unclaimed inbox and commits it
// before returning true; a full, unreadable or claimed inbox refuses.
bridge_inbox_admit_shared :: proc(instance: string, input: Runtime_Input, coalesce_steer := false) -> bool {
    if input.text == "" do return false
    now := bridge_runtime_now_ms()
    entry := bridge_inbox_input_from(input, now)
    if !bridge_inbox_input_valid(entry) { bridge_inbox_input_delete(entry); return false }
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    slot := bridge_inbox_slot_locked(instance)
    if slot == nil { bridge_inbox_input_delete(entry); return false }
    id := strings.clone(entry.id, context.temp_allocator)
    switch bridge_inbox_admit(&slot.inbox, entry, now, coalesce_steer) {
    case .Duplicate: return true
    case .Full: return false
    case .Added:
    }
    if !bridge_inbox_save(&slot.inbox) {
        bridge_inbox_remove(&slot.inbox, id, remember = false)
        return false
    }
    return true
}

// ---- relevance ------------------------------------------------------------------

Bridge_Inbox_Relevance :: enum u8 { Deliver, Wait, Drop }

Bridge_Task_State :: struct {
    instance, task, state: string,
    fetched_ms, requested_ms: i64,
}
bridge_task_states: [dynamic]Bridge_Task_State
bridge_task_states_mu: sync.Mutex

// bridge_inbox_relevance decides whether a queued input may be delivered
// now. Leaf lock only: it runs on runtime dispatchers. A state the hub could
// not report keeps the notice deliverable, as a failed read always did.
bridge_inbox_relevance :: proc(instance: string, input: Bridge_Inbox_Input, _now: i64 = 0) -> Bridge_Inbox_Relevance {
    if input.task == "" || input.expected_state == "" do return .Deliver
    heap := runtime.heap_allocator()
    now := bridge_runtime_now_ms()
    sync.mutex_lock(&bridge_task_states_mu); defer sync.mutex_unlock(&bridge_task_states_mu)
    if bridge_task_states.allocator.procedure == nil do bridge_task_states = make([dynamic]Bridge_Task_State, heap)
    for &s in bridge_task_states {
        if s.instance != instance || s.task != input.task do continue
        if s.fetched_ms != 0 && now-s.fetched_ms <= BRIDGE_TASK_STATE_FRESH_MS && s.fetched_ms >= s.requested_ms {
            return .Drop if s.state != "" && s.state != input.expected_state else .Deliver
        }
        if s.requested_ms <= s.fetched_ms { s.requested_ms = now; return .Wait }
        return .Deliver if now-s.requested_ms > BRIDGE_TASK_STATE_DEADLINE_MS else .Wait
    }
    if len(bridge_task_states) >= 1024 do return .Deliver
    append(&bridge_task_states, Bridge_Task_State{instance = strings.clone(instance, heap), task = strings.clone(input.task, heap), requested_ms = now})
    return .Wait
}

// bridge_task_state_fetch reads a task's state as the instance's agent
// (temp-allocated; "" when the hub cannot say).
bridge_task_state_fetch :: proc(instance, task: string) -> string {
    rec, ok := acp_runtime_current_record(instance)
    if !ok do return ""
    defer { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
    params, _ := json.marshal(struct{task_id: string}{task}, allocator = context.temp_allocator)
    reply := bridge_task_notice_relay({"api", "v1", "agent-actions", "tasks", "show"}, "agent.task.show", string(params), rec, 2000)
    defer delete(reply.body)
    if !reply.ok || reply.status < 200 || reply.status >= 300 do return ""
    obj := acp_event_object(reply.body)
    data, valid := obj["data"].(json.Object)
    if !valid do return ""
    state, known := data["state"].(json.String)
    return strings.clone(string(state), context.temp_allocator) if known else ""
}

// bridge_task_notice_relevant: the task is still in expected_state, or the
// hub could not say (failed, unauthorized and unknown reads keep the notice).
bridge_task_notice_relevant :: proc(instance, task, expected_state: string) -> bool {
    if task == "" || expected_state == "" do return true
    state := bridge_task_state_fetch(instance, task)
    return state == "" || state == expected_state
}

// Worker: performs the requested reads without holding any lock across HTTP.
bridge_task_state_refresh :: proc() {
    heap := runtime.heap_allocator()
    Want :: struct { instance, task: string }
    wants := make([dynamic]Want, context.temp_allocator)
    now := bridge_runtime_now_ms()
    sync.mutex_lock(&bridge_task_states_mu)
    for i := 0; i < len(bridge_task_states); {
        s := bridge_task_states[i]
        if now-max(s.requested_ms, s.fetched_ms) > 10*60*1000 {
            delete(s.instance, heap); delete(s.task, heap); delete(s.state, heap)
            unordered_remove(&bridge_task_states, i); continue
        }
        if s.requested_ms > s.fetched_ms do append(&wants, Want{strings.clone(s.instance, context.temp_allocator), strings.clone(s.task, context.temp_allocator)})
        i += 1
    }
    sync.mutex_unlock(&bridge_task_states_mu)
    for w in wants {
        state := bridge_task_state_fetch(w.instance, w.task)
        fetched := bridge_runtime_now_ms()
        sync.mutex_lock(&bridge_task_states_mu)
        for &s in bridge_task_states do if s.instance == w.instance && s.task == w.task {
            delete(s.state, heap); s.state = strings.clone(state, heap); s.fetched_ms = max(fetched, s.requested_ms)
        }
        sync.mutex_unlock(&bridge_task_states_mu)
    }
}

bridge_task_states_reset :: proc() {
    heap := runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_states_mu); defer sync.mutex_unlock(&bridge_task_states_mu)
    for s in bridge_task_states { delete(s.instance, heap); delete(s.task, heap); delete(s.state, heap) }
    clear(&bridge_task_states)
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

// ---- drain ----------------------------------------------------------------------

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

// Call with bridge_inbox_mu held.
bridge_task_notice_apply_kicks_locked :: proc() {
    heap := runtime.heap_allocator()
    sync.mutex_lock(&bridge_task_notice_kicks_mu); defer sync.mutex_unlock(&bridge_task_notice_kicks_mu)
    for k in bridge_task_notice_kicks {
        if slot := bridge_inbox_slots[k]; slot != nil && !slot.claimed { slot.kicked = true; slot.retry_ms = 0 }
        delete(k, heap)
    }
    clear(&bridge_task_notice_kicks)
}

// The worker drives a runtime through its transport's delivery target: ready
// says whether a batch can start a turn now, deliver hands it over as one
// text and returns once the turn is submitted.
Bridge_Inbox_Target :: struct {
    transport: string,
    ready:     proc(instance: string) -> bool,
    deliver:   proc(instance, text: string) -> bool,
}

// bridge_inbox_target selects the delivery target by the instance's recorded
// transport; nil (an unknown instance, or a runtime that drains its own
// inbox) keeps the batch queued.
bridge_inbox_target :: proc(instance: string) -> ^Bridge_Inbox_Target {
    rt := bridge_runtime_owner(instance)
    if rt == nil do return nil
    targets := [?]^Bridge_Inbox_Target{&pty_inbox_target}
    for target in targets do if target.transport == rt.transport do return target
    return nil
}

// Call with bridge_inbox_mu held. Drops notifications older than the age
// limit (shared store only; their hub state is long gone).
bridge_inbox_expire_locked :: proc(slot: ^Bridge_Inbox_Slot, now: i64) {
    expired := false
    for i := 0; i < len(slot.inbox.queue); {
        input := slot.inbox.queue[i]
        if input.lane != .Steer && input.queued_ms > 0 && now-input.queued_ms > BRIDGE_TASK_NOTICE_MAX_AGE_MS {
            bridge_inbox_remove(&slot.inbox, input.id); expired = true; continue
        }
        i += 1
    }
    if expired do _ = bridge_inbox_save(&slot.inbox)
}

// Call with bridge_inbox_mu held: a user input is due at once, notifications
// when their collection window closes or a trusted idle was reported.
bridge_inbox_due_locked :: proc(slot: ^Bridge_Inbox_Slot, now: i64) -> bool {
    if slot.claimed || slot.busy || len(slot.inbox.queue) == 0 || now < slot.retry_ms do return false
    for input in slot.inbox.queue do if input.lane == .Steer do return true
    return slot.kicked || bridge_inbox_window_closed(&slot.inbox, now)
}

bridge_task_notice_tick :: proc(now: i64) {
    due := make([dynamic]string, context.temp_allocator)
    sync.mutex_lock(&bridge_inbox_mu)
    bridge_task_notice_apply_kicks_locked()
    for instance, slot in bridge_inbox_slots {
        if slot.claimed do continue
        bridge_inbox_expire_locked(slot, now)
        if !bridge_inbox_due_locked(slot, now) do continue
        append(&due, strings.clone(instance, context.temp_allocator))
        // Ask for the task states this batch needs before reading them.
        for input in slot.inbox.queue do _ = bridge_inbox_relevance(instance, input)
    }
    sync.mutex_unlock(&bridge_inbox_mu)
    // Dispatcher-drained (ACP) inboxes ask for theirs from their drain.
    bridge_task_state_refresh()
    for instance in due do bridge_inbox_drain_shared(instance, now)
}

// bridge_inbox_drain_shared delivers one FIFO batch of an instance's shared
// inbox as one turn. The batch leaves the inbox only after the target
// reports the turn submitted (for PTY: pasted and submitted), so a failure
// keeps it queued. Remaining double-delivery window: a bridge crash after
// the submit keys and before the inbox file is rewritten (one atomic write)
// replays the batch after restart.
bridge_inbox_drain_shared :: proc(instance: string, now: i64) {
    target := bridge_inbox_target(instance)
    // Restore runs before asynchronous runtime reconciliation. An unknown pipe
    // must not be mistaken for a PTY and acknowledged by a one-way socket write.
    snap, present := bridge_runtime_instance_snapshot(instance)
    usable := target != nil && present && snap.pty_process_alive && snap.stopped_intent_unix_ms == 0 && snap.start_success_seen
    // Notices never interrupt (CONTRACT-07): the runtime says whether a batch
    // can start a turn now, and a busy agent keeps it queued.
    ready := usable && target.ready(instance)
    batch := make([dynamic]string, context.temp_allocator)    // ids typed now
    dropped := make([dynamic]string, context.temp_allocator)  // stale task notices
    texts := make([dynamic]string, context.temp_allocator)
    sync.mutex_lock(&bridge_inbox_mu)
    slot := bridge_inbox_slots[instance]
    if slot == nil || !bridge_inbox_due_locked(slot, now) { sync.mutex_unlock(&bridge_inbox_mu); return }
    if !ready {
        slot.retry_ms = now+BRIDGE_TASK_NOTICE_WINDOW_MS
        sync.mutex_unlock(&bridge_inbox_mu); return
    }
    for input in slot.inbox.queue {
        switch bridge_inbox_relevance(instance, input, now) {
        case .Drop: append(&dropped, strings.clone(input.id, context.temp_allocator))
        case .Wait:
            // The batch goes as one turn once every decision is known.
            sync.mutex_unlock(&bridge_inbox_mu); return
        case .Deliver:
            append(&batch, strings.clone(input.id, context.temp_allocator))
            append(&texts, strings.clone(input.text, context.temp_allocator))
        }
    }
    if len(batch) > 0 do slot.busy = true
    sync.mutex_unlock(&bridge_inbox_mu)
    delivered := false
    if len(batch) > 0 {
        text := bridge_task_notice_join(texts[:]); defer delete(text)
        delivered = target.deliver(instance, text)
    }
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    slot = bridge_inbox_slots[instance]
    if slot == nil do return
    slot.busy = false
    for id in dropped do bridge_inbox_remove(&slot.inbox, id)
    if delivered {
        for id in batch do bridge_inbox_remove(&slot.inbox, id)
        bridge_inbox_window_reset(&slot.inbox)
        slot.kicked = false
    } else if len(batch) > 0 {
        slot.retry_ms = now+BRIDGE_TASK_NOTICE_WINDOW_MS
    }
    if (delivered || len(dropped) > 0) && !bridge_inbox_save(&slot.inbox) {
        fmt.eprintfln("bridge inbox: could not commit delivery for instance=%q; a restart may deliver it again", instance)
    }
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

// ---- restart and upgrade ------------------------------------------------------

// The notice queue file of bridges before the one inbox: every instance's
// pending task notices and PTY inputs in one list.
Bridge_Legacy_Task_Notice :: struct {
    instance, task, expected_state, origin, text: string,
    id, kind: string,
    queued_ms, due_ms: i64,
}
Bridge_Legacy_Task_Notices :: struct { entries: []Bridge_Legacy_Task_Notice }

bridge_task_notice_legacy_path :: proc() -> string {
    tokens := bridge_agent_token_store_path(); defer delete(tokens)
    return strings.concatenate({tokens[:strings.last_index_byte(tokens, '/')], "/task-notices/pending.json"})
}

// bridge_task_notice_upgrade moves a legacy notice file's entries into the
// instances' inboxes. Entries without an identity get one derived from their
// content, so repeating an interrupted upgrade never duplicates an input.
// Returns false when an inbox could not be committed (the file is kept).
bridge_task_notice_upgrade :: proc(raw: string, now: i64) -> bool {
    context.allocator = runtime.heap_allocator()
    if len(raw) > 8*1024*1024 do return false
    saved: Bridge_Legacy_Task_Notices
    if json.unmarshal_string(raw, &saved, allocator = context.temp_allocator) != nil do return false
    touched := make([dynamic]^Bridge_Inbox_Slot, context.temp_allocator)
    ok := true
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    for n in saved.entries {
        if n.instance == "" || n.text == "" || n.queued_ms <= 0 || now-n.queued_ms > BRIDGE_TASK_NOTICE_MAX_AGE_MS do continue
        slot := bridge_inbox_slot_locked(n.instance)
        if slot == nil { ok = false; continue }
        id := n.id
        if id == "" {
            h := hash.fnv64a(transmute([]byte)strings.join({n.instance, n.task, n.expected_state, n.origin, n.text}, "\x00", context.temp_allocator))
            id = fmt.tprintf("notice_legacy_%x", h)
        }
        user := n.kind == BRIDGE_NOTICE_USER_MESSAGE
        entry := bridge_inbox_input_from({kind = .User_Message if user else .Notification, id = id, text = n.text, key = n.task,
            origin = n.origin, task = n.task, expected_state = n.expected_state}, n.queued_ms)
        if bridge_inbox_admit(&slot.inbox, entry, now) == .Full do ok = false
        found := false
        for s in touched do if s == slot do found = true
        if !found do append(&touched, slot)
    }
    for slot in touched do if !bridge_inbox_save(&slot.inbox) do ok = false
    return ok
}

// Loads every saved inbox (restart replay) after upgrading a legacy notice
// file. Runtimes that drain their own inbox claim theirs from the registry.
bridge_inbox_restore_all :: proc() {
    context.allocator = runtime.heap_allocator()
    legacy := bridge_task_notice_legacy_path(); defer delete(legacy)
    if raw, err := os.read_entire_file(legacy, context.allocator); err == nil {
        defer delete(raw)
        if bridge_task_notice_upgrade(string(raw), bridge_runtime_now_ms()) {
            _ = os.remove(legacy)
        } else {
            fmt.eprintfln("bridge inbox: could not upgrade %s; it is kept for the next start", legacy)
        }
    }
    dir := bridge_inbox_dir(); defer delete(dir)
    entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil do return
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    for e in entries {
        if e.type != .Regular || filepath.ext(e.name) != ".json" do continue
        _ = bridge_inbox_slot_locked(strings.trim_suffix(e.name, ".json"))
    }
}

bridge_task_notice_start :: proc() -> ^thread.Thread {
    bridge_inbox_restore_all()
    sync.atomic_store(&bridge_task_notices_stop, false)
    return thread.create_and_start(bridge_task_notice_worker)
}

bridge_task_notice_stop :: proc(worker: ^thread.Thread) {
    if worker == nil do return
    sync.atomic_store(&bridge_task_notices_stop, true)
    thread.join(worker); thread.destroy(worker)
    bridge_inbox_forget_all()
    bridge_task_states_reset()
}
