package main

// The one durable bridge inbox (G7, REQ R5): every input an agent has not yet
// received waits here, per instance, whatever its transport. The store owns
// admission (identity dedupe, completed ids, key coalescing, lanes, bounds),
// Send now batch membership, the notice collection window and its own
// persistence. It never talks to an agent: a runtime adapter drains it
// (acp_inbox.odin on the ACP dispatcher, the inbox worker in
// task_notice_queue.odin for PTY) and decides when a delivery is committed.
//
// File: <per-bridge dir>/inbox/<instance>.json, written atomically (0600,
// fsync, rename). It is the Bridge_Inbox struct as JSON (version 1); when the
// instance's conversation is sealed, the file is the same JSON sealed with the
// vault keyring ({"schema_version":2,"instance":...,"sealed_state":...}), like
// the ACP journal it used to live in.
//
// Ownership: an inbox is either in the shared registry (guarded by
// bridge_inbox_mu; the PTY runtime and the worker use it) or claimed by one
// ACP runtime, whose dispatcher is then its only user. A claimed instance
// keeps a registry tombstone so a shared admission cannot fork its state.
import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import vault "odin_test:lib/vault"

BRIDGE_INBOX_VERSION :: 1
BRIDGE_INBOX_DEBOUNCE_MS :: 2000
BRIDGE_INBOX_CAP_MS :: 10000
// Preserve the pre-inbox journal's 128 x 256 KiB restore contract. Limit each
// prompt's context separately, and reserve admission slots for real input.
BRIDGE_INBOX_MAX_BYTES :: 128*256*1024
BRIDGE_INBOX_DIGEST_BYTES :: 512*1024
BRIDGE_INBOX_SLOTS :: 128
BRIDGE_INBOX_NOTICE_SLOTS :: 112
BRIDGE_INBOX_COMPLETED_MAX :: 256
BRIDGE_INBOX_TEXT_MAX :: 256*1024
// An explicit Send now batch is one input standing for its frozen members
// (ACP only; a PTY Send now has no members).
BRIDGE_INBOX_SEND_NOW_KIND :: "send_now"
BRIDGE_INBOX_SEND_NOW_ID_MAX :: 128

// Steer: a user input; it waits for idle and starts (or is steered into) a
// turn. Batch: a notification that starts a turn after the collection window,
// subject to the notice rate limit. Digest: context only, it joins the next
// turn. Wake: a notification that starts a turn after the collection window
// and is never rate limited (task and lease wakes); it never steers.
// The JSON encoding is the enum's integer: append new lanes only.
Bridge_Inbox_Lane :: enum { Steer, Batch, Digest, Wake }

Bridge_Inbox_Input :: struct {
    id, text: string,
    lane: Bridge_Inbox_Lane,
    key, kind: string,
    // Relevance: deliver only while the hub task is still in expected_state
    // (task_notice_queue.odin). Empty: always relevant.
    task, expected_state: string,
    // Admission time in the shared store (bridge clock); 0 when not tracked.
    queued_ms: i64,
}

// Durable batch selection. members is FIFO and frozen at the first merge;
// later arrivals never join (except a rejected steer that predates it).
// state: waiting | steering | cancelling | delivered | failed | empty.
Bridge_Inbox_Send_Now :: struct {
    batch_id, state: string,
    attempt: i64,
    members: [dynamic]string,
}

Bridge_Inbox :: struct {
    version: int,
    queue: [dynamic]Bridge_Inbox_Input,
    // Identities already delivered (or superseded): a retried admission of
    // one is acknowledged, never delivered again. Bounded, oldest first.
    completed_inputs: [dynamic]string,
    send_now: Bridge_Inbox_Send_Now,
    // The last memberless Send now request applied (PTY): a repeat of it is a
    // no-op, also after a restart.
    send_now_applied: string,
    // Collection window of the Batch/Wake lanes and the notice rate limit.
    batch_first_ms, batch_last_ms, last_notice_turn_ms: i64,
    instance: string `json:"-"`,
    sealed: bool `json:"-"`,
    saved: string `json:"-"`, // bytes last written; an unchanged save is skipped
}

bridge_inbox_input_delete :: proc(input: Bridge_Inbox_Input) {
    context.allocator = runtime.heap_allocator()
    delete(input.id); delete(input.text); delete(input.key); delete(input.kind); delete(input.task); delete(input.expected_state)
}

bridge_inbox_input_clone :: proc(input: Bridge_Inbox_Input, allocator := context.allocator) -> Bridge_Inbox_Input {
    context.allocator = allocator
    return {id = strings.clone(input.id), text = strings.clone(input.text), lane = input.lane, key = strings.clone(input.key),
        kind = strings.clone(input.kind), task = strings.clone(input.task), expected_state = strings.clone(input.expected_state), queued_ms = input.queued_ms}
}

bridge_inbox_send_now_delete :: proc(s: ^Bridge_Inbox_Send_Now) {
    context.allocator = runtime.heap_allocator()
    delete(s.batch_id); delete(s.state)
    for id in s.members do delete(id)
    delete(s.members)
    s^ = {}
}

bridge_inbox_delete :: proc(inbox: ^Bridge_Inbox) {
    context.allocator = runtime.heap_allocator()
    for input in inbox.queue do bridge_inbox_input_delete(input)
    delete(inbox.queue)
    for id in inbox.completed_inputs do delete(id)
    delete(inbox.completed_inputs)
    bridge_inbox_send_now_delete(&inbox.send_now)
    delete(inbox.send_now_applied)
    delete(inbox.instance); delete(inbox.saved)
    inbox^ = {}
}

bridge_inbox_input_valid :: proc(input: Bridge_Inbox_Input) -> bool {
    return input.id != "" && len(input.id) <= 1024 && len(input.text) <= BRIDGE_INBOX_TEXT_MAX && len(input.key) <= 1024 && len(input.kind) <= 256 &&
        len(input.task) <= 1024 && len(input.expected_state) <= 64 && input.lane >= .Steer && input.lane <= .Wake
}

bridge_inbox_send_now_valid :: proc(s: ^Bridge_Inbox_Send_Now, max_members: int) -> bool {
    if len(s.batch_id) > BRIDGE_INBOX_SEND_NOW_ID_MAX || s.attempt < 0 || len(s.members) > max_members do return false
    switch s.state { case "", "waiting", "steering", "cancelling", "delivered", "failed", "empty": case: return false }
    for id in s.members do if id == "" || len(id) > 1024 do return false
    return true
}

// Bounds every restored inbox must satisfy (in-flight work is the adapter's).
bridge_inbox_valid :: proc(inbox: ^Bridge_Inbox, max_members: int) -> bool {
    if inbox.version > BRIDGE_INBOX_VERSION || len(inbox.queue) > BRIDGE_INBOX_SLOTS || len(inbox.completed_inputs) > BRIDGE_INBOX_COMPLETED_MAX do return false
    bytes := 0
    for input in inbox.queue {
        if !bridge_inbox_input_valid(input) do return false
        bytes += len(input.text)
    }
    if bytes > BRIDGE_INBOX_MAX_BYTES do return false
    if inbox.batch_first_ms < 0 || inbox.batch_last_ms < inbox.batch_first_ms || inbox.last_notice_turn_ms < 0 do return false
    for id in inbox.completed_inputs do if id == "" || len(id) > 1024 do return false
    if len(inbox.send_now_applied) > BRIDGE_INBOX_SEND_NOW_ID_MAX do return false
    return bridge_inbox_send_now_valid(&inbox.send_now, max_members)
}

bridge_inbox_completed :: proc(inbox: ^Bridge_Inbox, id: string) -> bool {
    for saved in inbox.completed_inputs do if saved == id do return true
    return false
}

bridge_inbox_remember :: proc(inbox: ^Bridge_Inbox, id: string) {
    if id == "" || bridge_inbox_completed(inbox, id) do return
    heap := runtime.heap_allocator()
    if inbox.completed_inputs.allocator.procedure == nil do inbox.completed_inputs = make([dynamic]string, heap)
    append(&inbox.completed_inputs, strings.clone(id, heap))
    if len(inbox.completed_inputs) > BRIDGE_INBOX_COMPLETED_MAX { delete(inbox.completed_inputs[0], heap); ordered_remove(&inbox.completed_inputs, 0) }
}

bridge_inbox_index :: proc(inbox: ^Bridge_Inbox, id: string) -> int {
    for input, i in inbox.queue do if input.id == id do return i
    return -1
}

bridge_inbox_send_now_member :: proc(inbox: ^Bridge_Inbox, id: string) -> bool {
    for m in inbox.send_now.members do if m == id do return true
    return false
}

// Already queued, delivered or inside a Send now batch: a retried admission
// of this identity must be acknowledged, never queued again.
bridge_inbox_known :: proc(inbox: ^Bridge_Inbox, id: string) -> bool {
    return bridge_inbox_completed(inbox, id) || bridge_inbox_index(inbox, id) >= 0 || bridge_inbox_send_now_member(inbox, id)
}

Bridge_Inbox_Admit :: enum u8 { Added, Duplicate, Full }

// bridge_inbox_admit takes ownership of input (heap strings). A notification
// with the same key and kind as a queued one replaces it in place (the older
// identity becomes completed); a Steer input coalesces only when
// coalesce_steer. reserved_* account for input the adapter holds in flight.
bridge_inbox_admit :: proc(inbox: ^Bridge_Inbox, input: Bridge_Inbox_Input, now: i64, coalesce_steer := false, reserved_slots := 0, reserved_bytes := 0) -> Bridge_Inbox_Admit {
    context.allocator = runtime.heap_allocator()
    if bridge_inbox_known(inbox, input.id) { bridge_inbox_input_delete(input); return .Duplicate }
    replace := -1
    bytes := len(input.text) + reserved_bytes
    for entry, i in inbox.queue {
        if (coalesce_steer || (input.lane != .Steer && entry.lane != .Steer)) &&
           input.key != "" && entry.key == input.key && entry.kind == input.kind { replace = i }
        bytes += len(entry.text)
    }
    if replace >= 0 do bytes -= len(inbox.queue[replace].text)
    slots := BRIDGE_INBOX_SLOTS if input.lane == .Steer else BRIDGE_INBOX_NOTICE_SLOTS
    if (replace < 0 && len(inbox.queue) + reserved_slots >= slots) || bytes > BRIDGE_INBOX_MAX_BYTES { bridge_inbox_input_delete(input); return .Full }
    if replace >= 0 {
        bridge_inbox_remember(inbox, inbox.queue[replace].id)
        bridge_inbox_input_delete(inbox.queue[replace]); inbox.queue[replace] = input
    } else {
        if inbox.queue.allocator.procedure == nil do inbox.queue = make([dynamic]Bridge_Inbox_Input)
        append(&inbox.queue, input)
    }
    if input.lane == .Batch || input.lane == .Wake {
        if inbox.batch_first_ms == 0 do inbox.batch_first_ms = now
        inbox.batch_last_ms = now
    }
    return .Added
}

// bridge_inbox_remove drops a queued input; with remember its identity is
// recorded as completed. Returns whether it was queued.
bridge_inbox_remove :: proc(inbox: ^Bridge_Inbox, id: string, remember := true) -> bool {
    i := bridge_inbox_index(inbox, id)
    if i < 0 do return false
    // id may be the entry's own string: record it before freeing the entry.
    if remember do bridge_inbox_remember(inbox, id)
    bridge_inbox_input_delete(inbox.queue[i]); ordered_remove(&inbox.queue, i)
    return true
}

// The collection window has closed: no Batch/Wake arrival for the debounce
// interval, or the cap since the first one.
bridge_inbox_window_closed :: proc(inbox: ^Bridge_Inbox, now: i64) -> bool {
    return now-inbox.batch_last_ms >= BRIDGE_INBOX_DEBOUNCE_MS || now-inbox.batch_first_ms >= BRIDGE_INBOX_CAP_MS
}

bridge_inbox_window_reset :: proc(inbox: ^Bridge_Inbox) {
    inbox.batch_first_ms = 0; inbox.batch_last_ms = 0
}

// bridge_inbox_send_now_freeze selects the batch: the listed user inputs
// still queued, in queue (FIFO) order, move to the queue front as members of the
// batch (kind send_now). Bot and notification entries never join. Returns
// how many were selected; the caller sets the batch state.
bridge_inbox_send_now_freeze :: proc(inbox: ^Bridge_Inbox, ids: []string, skip_kind := "") -> int {
    context.allocator = runtime.heap_allocator()
    s := &inbox.send_now
    for id in s.members do delete(id)
    clear(&s.members)
    selected := make([dynamic]Bridge_Inbox_Input, context.temp_allocator)
    for i := 0; i < len(inbox.queue); {
        input := inbox.queue[i]
        listed := false
        for id in ids do if id == input.id do listed = true
        if !listed || input.lane != .Steer || (skip_kind != "" && input.kind == skip_kind) { i += 1; continue }
        append(&selected, input); ordered_remove(&inbox.queue, i)
    }
    if s.members.allocator.procedure == nil do s.members = make([dynamic]string)
    for &input in selected {
        delete(input.kind); input.kind = strings.clone(BRIDGE_INBOX_SEND_NOW_KIND)
        append(&s.members, strings.clone(input.id))
    }
    if len(selected) > 0 do inject_at_elems(&inbox.queue, 0, ..selected[:])
    return len(selected)
}

// bridge_inbox_send_now_begin records a new batch identity (any previous,
// undispatched selection returns to ordinary queued inputs first).
bridge_inbox_send_now_begin :: proc(inbox: ^Bridge_Inbox, batch_id: string, attempt: i64) {
    context.allocator = runtime.heap_allocator()
    for &input in inbox.queue do if input.kind == BRIDGE_INBOX_SEND_NOW_KIND { delete(input.kind); input.kind = "" }
    bridge_inbox_send_now_delete(&inbox.send_now)
    inbox.send_now.batch_id = strings.clone(batch_id); inbox.send_now.attempt = attempt
}

bridge_inbox_note_send_now_applied :: proc(inbox: ^Bridge_Inbox, id: string) {
    context.allocator = runtime.heap_allocator()
    if inbox.send_now_applied == id do return
    delete(inbox.send_now_applied); inbox.send_now_applied = strings.clone(id)
}

bridge_inbox_send_now_set_state :: proc(inbox: ^Bridge_Inbox, state: string) {
    context.allocator = runtime.heap_allocator()
    if inbox.send_now.state == state do return
    delete(inbox.send_now.state); inbox.send_now.state = strings.clone(state)
}

// bridge_inbox_merge moves every input of src that dst does not know into
// dst's queue (FIFO after dst's own), unions completed identities and adopts
// src's batch when dst has none. Used to upgrade older stores; repeating it
// never duplicates an input. src is left empty.
bridge_inbox_merge :: proc(dst, src: ^Bridge_Inbox) {
    context.allocator = runtime.heap_allocator()
    for id in src.completed_inputs do bridge_inbox_remember(dst, id)
    for input in src.queue {
        if bridge_inbox_known(dst, input.id) || len(dst.queue) >= BRIDGE_INBOX_SLOTS { bridge_inbox_input_delete(input); continue }
        if dst.queue.allocator.procedure == nil do dst.queue = make([dynamic]Bridge_Inbox_Input)
        append(&dst.queue, input)
    }
    clear(&src.queue)
    if dst.send_now.batch_id == "" && src.send_now.batch_id != "" {
        dst.send_now = src.send_now; src.send_now = {}
    }
    if dst.send_now_applied == "" && src.send_now_applied != "" {
        dst.send_now_applied = src.send_now_applied; src.send_now_applied = ""
    }
    if dst.batch_first_ms == 0 do dst.batch_first_ms = src.batch_first_ms
    dst.batch_last_ms = max(dst.batch_last_ms, src.batch_last_ms, dst.batch_first_ms)
    dst.last_notice_turn_ms = max(dst.last_notice_turn_ms, src.last_notice_turn_ms)
}

// ---- persistence ------------------------------------------------------------

// The per-bridge namespace shared with local tokens and retry journals.
bridge_inbox_dir :: proc() -> string {
    tokens := bridge_agent_token_store_path(); defer delete(tokens)
    return strings.concatenate({tokens[:strings.last_index_byte(tokens, '/')], "/inbox"})
}

bridge_inbox_path :: proc(instance: string) -> (string, bool) {
    if !acp_state_component_ok(instance) do return "", false
    dir := bridge_inbox_dir(); defer delete(dir)
    return strings.concatenate({dir, "/", instance, ".json"}), true
}

Bridge_Inbox_Sealed :: struct { schema_version: int, instance, sealed_state: string }

bridge_inbox_encode :: proc(inbox: ^Bridge_Inbox) -> (string, bool) {
    inbox.version = BRIDGE_INBOX_VERSION
    raw, err := json.marshal(inbox^, allocator = context.temp_allocator)
    if err != nil do return "", false
    if !inbox.sealed do return string(raw), true
    defer crypto.zero_explicit(raw_data(raw), len(raw))
    kr, unlocked := acp_chat_keyring(); defer vault.keyring_wipe(&kr)
    if !unlocked do return "", false
    sealed, ok := bridge_encrypt_vault_text(string(raw), &kr, context.temp_allocator)
    if !ok do return "", false
    header, herr := json.marshal(Bridge_Inbox_Sealed{2, inbox.instance, sealed}, allocator = context.temp_allocator)
    return string(header), herr == nil
}

// bridge_inbox_save commits the inbox to its file; an inbox without a valid
// instance id is memory only. Unchanged contents are not rewritten.
bridge_inbox_save :: proc(inbox: ^Bridge_Inbox) -> bool {
    path, ok := bridge_inbox_path(inbox.instance)
    if !ok do return true
    defer delete(path)
    raw, encoded := bridge_inbox_encode(inbox)
    if !encoded do return false
    if raw == inbox.saved do return true
    dir := bridge_inbox_dir(); defer delete(dir)
    if bridge_make_directory_all(dir) != nil && !os.is_dir(dir) do return false
    if !bridge_retry_atomic_write(path, transmute([]byte)raw) do return false
    heap := runtime.heap_allocator()
    delete(inbox.saved, heap); inbox.saved = strings.clone(raw, heap)
    return true
}

// bridge_inbox_decode reads either file form into an empty inbox.
bridge_inbox_decode :: proc(raw: string, inbox: ^Bridge_Inbox) -> bool {
    header: Bridge_Inbox_Sealed
    if json.unmarshal_string(raw, &header, allocator = context.temp_allocator) == nil && header.schema_version == 2 && header.sealed_state != "" {
        kr, unlocked := acp_chat_keyring(); defer vault.keyring_wipe(&kr)
        if !unlocked do return false
        plain, opened := bridge_decrypt_vault_token(header.sealed_state, &kr)
        if !opened do return false
        defer { crypto.zero_explicit(raw_data(plain), len(plain)); delete(plain) }
        inbox.sealed = true
        return json.unmarshal_string(plain, inbox, allocator = runtime.heap_allocator()) == nil
    }
    return json.unmarshal_string(raw, inbox, allocator = runtime.heap_allocator()) == nil
}

// bridge_inbox_load reads an instance's inbox. A missing file is an empty
// inbox; an unreadable one (a sealed file while the vault is locked, a
// corrupt file) is not ok and must never be overwritten.
bridge_inbox_load :: proc(instance: string) -> (inbox: Bridge_Inbox, ok: bool) {
    heap := runtime.heap_allocator()
    path, valid := bridge_inbox_path(instance)
    if !valid do return {instance = strings.clone(instance, heap)}, true
    defer delete(path)
    if !os.exists(path) do return {instance = strings.clone(instance, heap)}, true
    raw, err := os.read_entire_file(path, heap)
    if err != nil do return {}, false
    defer delete(raw, heap)
    if len(raw) > 2*BRIDGE_INBOX_MAX_BYTES+65536 || !bridge_inbox_decode(string(raw), &inbox) || !bridge_inbox_valid(&inbox, BRIDGE_INBOX_SLOTS) {
        fmt.eprintfln("bridge inbox: %s is unreadable; keeping it and refusing new input for instance=%q", path, instance)
        bridge_inbox_delete(&inbox)
        return {}, false
    }
    inbox.instance = strings.clone(instance, heap)
    inbox.saved = strings.clone(string(raw), heap)
    return inbox, true
}

// ---- registry ---------------------------------------------------------------

Bridge_Inbox_Slot :: struct {
    inbox: Bridge_Inbox,
    claimed: bool, // an ACP runtime owns this instance's inbox (tombstone)
    kicked: bool,  // a trusted idle: the collection window ends now
    busy: bool,    // a delivery of this inbox is being typed
    retry_ms: i64, // a failed or not-ready delivery waits until then
}

bridge_inbox_mu: sync.Mutex
bridge_inbox_slots: map[string]^Bridge_Inbox_Slot

// Call with bridge_inbox_mu held. Loads the instance's file on first use; nil
// when the file is unreadable or the inbox is claimed.
bridge_inbox_slot_locked :: proc(instance: string) -> ^Bridge_Inbox_Slot {
    context.allocator = runtime.heap_allocator()
    if bridge_inbox_slots == nil do bridge_inbox_slots = make(map[string]^Bridge_Inbox_Slot)
    if slot := bridge_inbox_slots[instance]; slot != nil do return nil if slot.claimed else slot
    if instance == "" || len(bridge_inbox_slots) >= 4096 do return nil
    inbox, ok := bridge_inbox_load(instance)
    if !ok do return nil
    slot := new(Bridge_Inbox_Slot)
    slot.inbox = inbox
    bridge_inbox_slots[strings.clone(instance)] = slot
    return slot
}

// bridge_inbox_lock returns an instance's shared inbox with bridge_inbox_mu
// held (nil, unlocked, when unavailable). Pair with bridge_inbox_unlock.
bridge_inbox_lock :: proc(instance: string) -> ^Bridge_Inbox {
    sync.mutex_lock(&bridge_inbox_mu)
    slot := bridge_inbox_slot_locked(instance)
    if slot == nil { sync.mutex_unlock(&bridge_inbox_mu); return nil }
    return &slot.inbox
}

bridge_inbox_unlock :: proc() { sync.mutex_unlock(&bridge_inbox_mu) }

// bridge_inbox_claim hands an instance's inbox to one owner (an ACP runtime);
// nil when it cannot be read. The registry keeps a tombstone until release.
bridge_inbox_claim :: proc(instance: string) -> ^Bridge_Inbox {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    if bridge_inbox_slots == nil do bridge_inbox_slots = make(map[string]^Bridge_Inbox_Slot)
    inbox := new(Bridge_Inbox)
    slot := bridge_inbox_slots[instance]
    if slot != nil && !slot.claimed {
        inbox^ = slot.inbox; slot.inbox = {}
    } else {
        loaded, ok := bridge_inbox_load(instance)
        if !ok { free(inbox); return nil }
        inbox^ = loaded
    }
    if slot == nil && acp_state_component_ok(instance) {
        slot = new(Bridge_Inbox_Slot)
        bridge_inbox_slots[strings.clone(instance)] = slot
    }
    if slot != nil do slot.claimed = true
    return inbox
}

// bridge_inbox_release ends a claim. The file is the inbox's truth: the next
// user reloads it.
bridge_inbox_release :: proc(inbox: ^Bridge_Inbox) {
    if inbox == nil do return
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_inbox_mu)
    if slot := bridge_inbox_slots[inbox.instance]; slot != nil && slot.claimed {
        key, _ := delete_key(&bridge_inbox_slots, inbox.instance)
        delete(key); free(slot)
    }
    sync.mutex_unlock(&bridge_inbox_mu)
    bridge_inbox_delete(inbox)
    free(inbox)
}

// bridge_inbox_forget_all drops every unclaimed shared inbox from memory
// (shutdown, tests); the files stay.
bridge_inbox_forget_all :: proc() {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
    keys := make([dynamic]string, context.temp_allocator)
    for key, slot in bridge_inbox_slots do if !slot.claimed do append(&keys, key)
    for key in keys {
        stored, slot := delete_key(&bridge_inbox_slots, key)
        bridge_inbox_delete(&slot.inbox); free(slot); delete(stored)
    }
}
