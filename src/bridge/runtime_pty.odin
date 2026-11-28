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
//   - steer and send now are explicit user modes driven by the key data in
//     contracts.Pty_Delivery (provider descriptor, then profile; CONTRACT-17);
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
PTY_RUNTIME_IDLE_POLL_MS :: 100

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

Pty_Delivery_Step :: enum u8 { Interrupt, Wait_Idle, Type, Submit }

@(private = "file") pty_plan_queue := [?]Pty_Delivery_Step{.Type, .Submit}
@(private = "file") pty_plan_send_now := [?]Pty_Delivery_Step{.Interrupt, .Wait_Idle, .Type, .Submit}
@(private = "file") pty_plan_steer := [?]Pty_Delivery_Step{.Interrupt, .Type, .Submit}

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
		case .Interrupt:
			if !pty_runtime_keys(socket, instance, d.interrupt_keys, d.key_delay_ms) do return false
			pty_runtime_sleep(d.interrupt_settle_ms)
		case .Wait_Idle:
			pty_runtime_wait_idle(instance, d.idle_wait_ms)
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

// pty_runtime_idle reports a trusted idle for a live, started agent. With
// after_typing, it also requires that the turn we last typed has been seen.
pty_runtime_idle :: proc(instance: string, after_typing := true) -> bool {
	snap, ok := bridge_runtime_instance_snapshot(instance)
	if !ok || !snap.pty_process_alive || snap.stopped_intent_unix_ms != 0 || !snap.start_success_seen do return false
	if snap.activity_status != "idle" || !bridge_activity_source_trusted_idle(snap.activity_source_kind) do return false
	if !after_typing do return true
	last := pty_runtime_last_typed(instance)
	return last == 0 || snap.activity_updated_unix_ms > last || pty_runtime_now() - last >= PTY_RUNTIME_TYPED_GRACE_MS
}

// Send now's bounded wait after the interrupt keys. It proceeds after limit_ms
// even without an idle: the user asked for the input to go now.
pty_runtime_wait_idle :: proc(instance: string, limit_ms: int) {
	waited := 0
	for waited < limit_ms && !pty_runtime_idle(instance, after_typing = false) {
		pty_runtime_sleep(PTY_RUNTIME_IDLE_POLL_MS)
		waited += PTY_RUNTIME_IDLE_POLL_MS
	}
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

// Admission to the durable inbox (bridge_inbox.odin). User messages are due
// at once (still gated on idle); notifications join the collection window.
pty_runtime_enqueue :: proc(instance: string, input: Runtime_Input) -> bool {
	return bridge_inbox_admit_shared(instance, input)
}

pty_agent_submit :: proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool {
	if !pty_runtime_known(instance) do return false
	if mode == .Queue do return pty_runtime_enqueue(instance, input)
	// Explicit steer / send now types right away; if the terminal is not
	// reachable the input still waits in the inbox.
	if pty_runtime_type_now(instance, input.text, mode) do return true
	return pty_runtime_enqueue(instance, input)
}

// pty_agent_send_now delivers the frozen FIFO batch of the listed inputs still
// queued: it steers when the CLI can steer, else interrupts once, waits for
// idle and types the batch as one turn (CONTRACT-06). An empty batch is a
// no-op. The selection is inbox state (bridge_inbox.odin): it is frozen and
// committed before typing, so a retry or a restart types the same members,
// and a repeated batch id is idempotent once delivered.
pty_agent_send_now :: proc(instance: string, req: Runtime_Send_Now) -> bool {
	if !pty_runtime_known(instance) || req.batch_id == "" || len(req.batch_id) > 128 do return false
	texts := make([dynamic]string, context.temp_allocator)
	members := make([dynamic]string, context.temp_allocator)
	{
		sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
		slot := bridge_inbox_slot_locked(instance)
		if slot == nil || slot.busy do return false
		inbox := &slot.inbox
		s := &inbox.send_now
		if s.batch_id == req.batch_id && (s.state == "delivered" || s.state == "empty") do return true
		if s.batch_id != req.batch_id {
			bridge_inbox_send_now_begin(inbox, req.batch_id, req.attempt)
			if bridge_inbox_send_now_freeze(inbox, req.message_ids) == 0 {
				bridge_inbox_send_now_set_state(inbox, "empty")
				return bridge_inbox_save(inbox)
			}
		}
		s.attempt = max(s.attempt, req.attempt)
		bridge_inbox_send_now_set_state(inbox, "waiting")
		if !bridge_inbox_save(inbox) do return false
		for input in inbox.queue do if input.kind == BRIDGE_INBOX_SEND_NOW_KIND {
			append(&texts, strings.clone(input.text, context.temp_allocator))
			append(&members, strings.clone(input.id, context.temp_allocator))
		}
		if len(members) == 0 {
			bridge_inbox_send_now_set_state(inbox, "empty")
			return bridge_inbox_save(inbox)
		}
		slot.busy = true
	}
	text := bridge_task_notice_join(texts[:])
	defer delete(text)
	mode := Runtime_Mode.Steer if pty_agent_can_steer(instance) else .Send_Now
	typed := pty_runtime_type_now(instance, text, mode)
	sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
	slot := bridge_inbox_slot_locked(instance)
	if slot == nil do return false
	slot.busy = false
	if !typed do return false
	for id in members do bridge_inbox_remove(&slot.inbox, id)
	bridge_inbox_send_now_set_state(&slot.inbox, "delivered")
	if !bridge_inbox_save(&slot.inbox) do fmt.eprintfln("bridge inbox: could not commit Send now for instance=%q; a restart may deliver it again", instance)
	return true
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
