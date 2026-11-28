package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"

// PTY implementation of the turn-based runtime interface (runtime_iface.odin).
//
// The provider CLI runs in a terminal under ham-pty-host, so inputs are typed.
// PTY is made to behave like ACP behind the interface (G8):
//   - every input is admitted to the one durable bridge inbox first
//     (bridge_inbox.odin) and survives bridge and agent restarts; the inbox
//     worker (task_notice_queue.odin) drains it through pty_inbox_target;
//   - queue (the default) types only at a trusted idle (extension hooks first,
//     pane-diff activity as the fallback), one turn per FIFO batch, and never
//     presses an interrupt key (CONTRACT-05/18);
//   - a PTY agent is never typed message bodies: a user message is a notice
//     that points at chat read, and the agent's own chat read returns every
//     unread message (and is the read evidence). So the inbox keeps ONE
//     coalesced unread-messages notice per agent, however many arrive;
//   - steer and send now are explicit user modes driven by the key data in
//     contracts.Pty_Delivery (provider descriptor, then profile; CONTRACT-17).
//     Send now needs no member batch: it presses the interrupt keys, types the
//     notice and submits, consuming the pending notice; it is idempotent per
//     hub request through one remembered id in the inbox;
//   - notifications always queue (the shared policy in runtime_iface.odin).

// The inbox worker's delivery target for this transport (task_notice_queue.odin).
pty_inbox_target := Bridge_Inbox_Target{transport = "pty", ready = pty_agent_notices_ready, deliver = pty_agent_deliver_notices}

pty_agent_runtime := Agent_Runtime{
	transport       = "pty",
	submit          = pty_agent_submit,
	send_now        = pty_agent_send_now,
	inputs_read     = pty_agent_inputs_read,
	interrupt       = pty_agent_interrupt,
	can_steer       = pty_agent_can_steer,
	usage           = bridge_ext_usage_snapshot,
}

// Seams: tests capture frames and skip real delays.
pty_runtime_daemon: proc() -> (string, bool) = bridge_pty_host_ensure_daemon
pty_runtime_send: proc(socket: string, frame: []byte) -> bool = bridge_pty_host_send_oneway
pty_runtime_sleep: proc(ms: int) = pty_runtime_sleep_default
pty_runtime_now: proc() -> i64 = bridge_runtime_now_ms

pty_runtime_sleep_default :: proc(ms: int) {
	if ms > 0 do time.sleep(time.Duration(ms) * time.Millisecond)
}

// After typing, the next batch waits until the activity detector has seen the
// turn (an activity update after the typing) or this long has passed, so two
// batches are never typed into one turn.
PTY_RUNTIME_TYPED_GRACE_MS :: i64(10_000)

// ---- key data ---------------------------------------------------------------

// pty_runtime_delivery resolves an instance's delivery key data: defaults, then
// the provider descriptor, then the profile it was spawned with. Read at every
// delivery, so a profile edit applies without a restart (G5). Key lists are
// temp-allocated or static.
pty_runtime_delivery :: proc(instance: string) -> contracts.Pty_Delivery {
	provider, profile := bridge_pty_host_instance_profile(instance)
	descriptor := contracts.provider_descriptor_or_generic(provider)
	profile_spec: contracts.Pty_Delivery_Spec
	if provider != "" && profile != "" {
		if pp, err := profile_lookup(provider, profile); err == .None do profile_spec = pp.config.pty_delivery
	}
	return contracts.pty_delivery_resolve(descriptor.pty_delivery, profile_spec)
}

pty_runtime_key :: proc(name: string) -> (Pty_Host_Key, bool) {
	switch name {
	case "esc": return .Esc, true
	case "enter": return .Enter, true
	case "ctrl_c": return .Ctrl_C, true
	case "tab": return .Tab, true
	case "ctrl_d": return .Ctrl_D, true
	}
	return .Enter, false
}

// Interrupt_If_Busy presses the interrupt keys only while the agent is not at
// a trusted idle.
Pty_Delivery_Step :: enum u8 { Interrupt, Interrupt_If_Busy, Type, Submit }

// Queue types at a trusted idle (the worker gates it) and never interrupts.
// Steer stops a running turn and has the agent read the current message (no
// interrupt when idle). Send now always interrupts first.
@(private = "file") pty_plan_queue := [?]Pty_Delivery_Step{.Type, .Submit}
@(private = "file") pty_plan_send_now := [?]Pty_Delivery_Step{.Interrupt, .Type, .Submit}
@(private = "file") pty_plan_steer := [?]Pty_Delivery_Step{.Interrupt_If_Busy, .Type, .Submit}

// pty_runtime_plan is the fixed step list of a delivery mode (CONTRACT-17).
pty_runtime_plan :: proc(mode: Runtime_Mode) -> []Pty_Delivery_Step {
	switch mode {
	case .Queue: return pty_plan_queue[:]
	case .Send_Now: return pty_plan_send_now[:]
	case .Steer: return pty_plan_steer[:]
	}
	return nil
}

// pty_runtime_body renders the typed body: vault tokens decrypted, then
// sanitized (no ESC, CR/LF folded to spaces) and/or wrapped as a bracketed
// paste. Caller owns the result.
pty_runtime_body :: proc(text: string, d: contracts.Pty_Delivery) -> string {
	plain := bridge_decrypt_embedded_vault_tokens(text)
	if d.paste_mode == .Bracketed {
		defer delete(plain)
		return bridge_pty_host_paste_wrap(plain)
	}
	if !d.sanitize do return plain
	defer delete(plain)
	b := strings.builder_make()
	for i in 0..<len(plain) {
		c := plain[i]
		switch c {
		case '\x1b':
		case '\r', '\n':
			if i > 0 && plain[i-1] == '\r' && c == '\n' do continue
			strings.write_byte(&b, ' ')
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

pty_runtime_keys :: proc(socket, instance: string, names: []string, delay_ms: int) -> bool {
	for name, i in names {
		key, ok := pty_runtime_key(name)
		if !ok do return false
		if i > 0 do pty_runtime_sleep(delay_ms)
		frame := pty_host_encode_key(instance, key)
		defer delete(frame)
		if !pty_runtime_send(socket, frame) do return false
	}
	return true
}

// pty_runtime_execute runs one delivery mode's steps with the given key data.
// It does not gate on idle itself: the queue path asks notices_ready first.
pty_runtime_execute :: proc(socket, instance, text: string, mode: Runtime_Mode, d: contracts.Pty_Delivery) -> bool {
	for step in pty_runtime_plan(mode) {
		switch step {
		case .Interrupt, .Interrupt_If_Busy:
			if step == .Interrupt_If_Busy && pty_runtime_idle(instance, after_typing = false) do continue
			if !pty_runtime_keys(socket, instance, d.interrupt_keys, d.key_delay_ms) do return false
			pty_runtime_sleep(d.interrupt_settle_ms)
		case .Type:
			body := pty_runtime_body(text, d)
			defer delete(body)
			frame := pty_host_encode_input(instance, transmute([]byte)body)
			defer delete(frame)
			if !pty_runtime_send(socket, frame) do return false
		case .Submit:
			// Let the TUI's input box register the paste before submitting.
			pty_runtime_sleep(d.submit_delay_ms)
			if !pty_runtime_keys(socket, instance, d.submit_keys, d.key_delay_ms) do return false
			if d.second_submit {
				pty_runtime_sleep(d.second_submit_delay_ms)
				if !pty_runtime_keys(socket, instance, d.submit_keys, d.key_delay_ms) do return false
			}
		}
	}
	return true
}

// ---- trusted idle -----------------------------------------------------------

pty_runtime_typed: map[string]i64
pty_runtime_typed_mu: sync.Mutex

pty_runtime_note_typed :: proc(instance: string) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&pty_runtime_typed_mu); defer sync.mutex_unlock(&pty_runtime_typed_mu)
	if pty_runtime_typed == nil do pty_runtime_typed = make(map[string]i64, allocator = heap)
	if _, exists := pty_runtime_typed[instance]; exists {
		pty_runtime_typed[instance] = pty_runtime_now()
		return
	}
	if len(pty_runtime_typed) >= 4096 do return
	pty_runtime_typed[strings.clone(instance, heap)] = pty_runtime_now()
}

pty_runtime_last_typed :: proc(instance: string) -> i64 {
	sync.mutex_lock(&pty_runtime_typed_mu); defer sync.mutex_unlock(&pty_runtime_typed_mu)
	return pty_runtime_typed[instance] if pty_runtime_typed != nil else 0
}

// ---- deliverable now ----------------------------------------------------------

// Whether anything may be typed into an instance's terminal now. The one check
// of every PTY delivery: the worker's queue drain (through notices_ready),
// Send now and the explicit modes (CONTRACT-10).
//   Not_Running: no snapshot, the child is not alive, a stop is in flight, or
//                the agent has not reported start success.
Pty_Deliverable :: enum u8 { Ready, Not_Running }

pty_runtime_deliverable_snapshot :: proc(snap: Bridge_Runtime_Instance, ok: bool) -> Pty_Deliverable {
	if !ok || !snap.pty_process_alive || snap.stopped_intent_unix_ms != 0 || !snap.start_success_seen do return .Not_Running
	return .Ready
}

pty_runtime_deliverable :: proc(instance: string) -> Pty_Deliverable {
	snap, ok := bridge_runtime_instance_snapshot(instance)
	return pty_runtime_deliverable_snapshot(snap, ok)
}

// The Send now outcome of a check that did not pass (the input stays queued).
pty_runtime_withheld_outcome :: proc(d: Pty_Deliverable) -> contracts.Runtime_Send_Now_Outcome {
	switch d {
	case .Ready: return .Delivered
	case .Not_Running: return .Not_Running
	}
	return .Failed
}

// pty_runtime_idle reports a trusted idle of a deliverable agent. With
// after_typing, it also requires that the turn we last typed has been seen.
pty_runtime_idle :: proc(instance: string, after_typing := true) -> bool {
	snap, ok := bridge_runtime_instance_snapshot(instance)
	if pty_runtime_deliverable_snapshot(snap, ok) != .Ready do return false
	if snap.activity_status != "idle" || !bridge_activity_source_trusted_idle(snap.activity_source_kind) do return false
	if !after_typing do return true
	last := pty_runtime_last_typed(instance)
	return last == 0 || snap.activity_updated_unix_ms > last || pty_runtime_now() - last >= PTY_RUNTIME_TYPED_GRACE_MS
}

// ---- interface methods --------------------------------------------------------

pty_runtime_known :: proc(instance: string) -> bool {
	_, ok := bridge_runtime_instance_snapshot(instance)
	return ok
}

pty_runtime_type_now :: proc(instance, text: string, mode: Runtime_Mode) -> bool {
	socket, ok := pty_runtime_daemon()
	if !ok do return false
	if !pty_runtime_execute(socket, instance, text, mode, pty_runtime_delivery(instance)) do return false
	pty_runtime_note_typed(instance)
	return true
}

// The coalescing key of the one pending unread-messages notice.
PTY_UNREAD_NOTICE_KEY :: "unread_messages"

// pty_runtime_unread reports whether a queued input is an unread-messages
// notice (every user input admitted to a PTY inbox points at chat read).
pty_runtime_unread :: proc(input: Bridge_Inbox_Input) -> bool {
	return input.lane == .Steer && input.kind == BRIDGE_NOTICE_USER_MESSAGE
}

// Admission to the durable inbox (bridge_inbox.odin). User messages are due
// at once (still gated on idle); notifications join the collection window.
// A hub message notice coalesces into the one pending unread notice: a second
// arrival replaces it in place with the sender-neutral text.
pty_runtime_enqueue :: proc(instance: string, input: Runtime_Input) -> bool {
	if input.kind != .User_Message || !input.hub_message do return bridge_inbox_admit_shared(instance, input)
	notice := input
	notice.key = PTY_UNREAD_NOTICE_KEY
	if inbox := bridge_inbox_lock(instance); inbox != nil {
		for queued in inbox.queue do if queued.key == PTY_UNREAD_NOTICE_KEY && pty_runtime_unread(queued) && queued.id != input.id do notice.text = bridge_pty_host_unread_notice()
		bridge_inbox_unlock()
	}
	return bridge_inbox_admit_shared(instance, notice, coalesce_steer = true)
}

pty_agent_submit :: proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool {
	if !pty_runtime_known(instance) do return false
	if mode == .Queue do return pty_runtime_enqueue(instance, input)
	// Explicit steer / send now types right away through the same section as
	// Send now; otherwise the input waits in the inbox. A hub message notice
	// points at chat read, so it also stands for every pending unread notice.
	outcome := pty_runtime_deliver_now(instance, input.text, mode, input_id = input.id, consume_unread = input.hub_message)
	if outcome == .Delivered do return true
	queued := pty_runtime_enqueue(instance, input)
	// A stopped agent was not reached: say so, the input still waits.
	return queued && outcome != .Not_Running
}

// pty_runtime_deliver_now is the one consume-and-busy section of explicit
// deliveries (Send now, explicit steer / send now). It types only into a
// deliverable agent (pty_runtime_deliverable), claims the inbox's busy flag so
// the worker never types into the same moment, types text with the mode's
// plan, and only then commits: the pending unread notices it stands for
// (consume_unread) leave the inbox, input_id becomes a completed identity and
// request_id the last applied Send now. A request id already applied is a
// no-op, also after a restart. Any outcome but Delivered leaves the inbox as
// it was.
pty_runtime_deliver_now :: proc(instance, text: string, mode: Runtime_Mode, request_id := "", input_id := "", consume_unread := false) -> contracts.Runtime_Send_Now_Outcome {
	consumed := make([dynamic]string, context.temp_allocator)
	if request_id != "" && pty_runtime_send_now_applied(instance, request_id) do return .Delivered
	// Read outside the inbox lock: the runtime registry is never taken under it.
	if d := pty_runtime_deliverable(instance); d != .Ready do return pty_runtime_withheld_outcome(d)
	{
		sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
		slot := bridge_inbox_slot_locked(instance)
		if slot == nil || slot.busy do return .Failed
		if request_id != "" && slot.inbox.send_now_applied == request_id do return .Delivered
		if consume_unread do for input in slot.inbox.queue do if pty_runtime_unread(input) do append(&consumed, strings.clone(input.id, context.temp_allocator))
		slot.busy = true
	}
	typed := pty_runtime_type_now(instance, text, mode)
	sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
	slot := bridge_inbox_slot_locked(instance)
	if slot == nil do return .Failed
	slot.busy = false
	if !typed do return .Failed
	for id in consumed do bridge_inbox_remove(&slot.inbox, id)
	if input_id != "" do bridge_inbox_remember(&slot.inbox, input_id)
	if request_id != "" do bridge_inbox_note_send_now_applied(&slot.inbox, request_id)
	if !bridge_inbox_save(&slot.inbox) do fmt.eprintfln("bridge inbox: could not commit an explicit delivery for instance=%q; a restart may deliver it again", instance)
	return .Delivered
}

pty_runtime_send_now_applied :: proc(instance, request_id: string) -> bool {
	sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
	slot := bridge_inbox_slot_locked(instance)
	return slot != nil && slot.inbox.send_now_applied == request_id
}

// pty_agent_send_now types the unread notice right away: interrupt keys, the
// notice, submit (CONTRACT-06). The agent's chat read then returns every
// unread message, so there are no members: req.message_ids is not used. The
// pending unread notices are consumed so nothing is typed twice.
pty_agent_send_now :: proc(instance: string, req: Runtime_Send_Now) -> contracts.Runtime_Send_Now_Outcome {
	if !pty_runtime_known(instance) || req.batch_id == "" || len(req.batch_id) > BRIDGE_INBOX_SEND_NOW_ID_MAX do return .Failed
	return pty_runtime_deliver_now(instance, bridge_pty_host_unread_notice(), .Send_Now, request_id = req.batch_id, consume_unread = true)
}

// Inputs the agent already read (chat read) no longer need a notice.
pty_agent_inputs_read :: proc(instance: string, ids: []string) -> bool {
	sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
	slot := bridge_inbox_slot_locked(instance)
	if slot == nil do return false
	removed := false
	for id in ids do if bridge_inbox_remove(&slot.inbox, id) do removed = true
	return !removed || bridge_inbox_save(&slot.inbox)
}

pty_agent_interrupt :: proc(instance: string) -> bool {
	socket, ok := pty_runtime_daemon()
	if !ok do return false
	d := pty_runtime_delivery(instance)
	return pty_runtime_keys(socket, instance, d.interrupt_keys, d.key_delay_ms)
}

pty_agent_can_steer :: proc(instance: string) -> bool {
	return pty_runtime_delivery(instance).can_steer
}

pty_agent_notices_ready :: proc(instance: string) -> bool {
	return pty_runtime_idle(instance)
}

pty_agent_deliver_notices :: proc(instance, text: string) -> bool {
	return pty_runtime_type_now(instance, text, .Queue)
}
