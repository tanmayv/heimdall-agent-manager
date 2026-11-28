package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// ---- frame capture ------------------------------------------------------------

// One captured PTY write: typed text, or a key.
Pty_Test_Op :: struct { input: string, key: Pty_Host_Key, is_key: bool }

pty_test_ops: [dynamic]Pty_Test_Op
pty_test_send_fail: bool

// Tests run in parallel and the seams are global: frames for instances other
// than the capture tests' own go to the real socket.
pty_test_captured :: proc(frame: []byte) -> (data: []byte, ok: bool) {
	if len(frame) < 9 do return nil, false
	n := int(frame[5])<<24 | int(frame[6])<<16 | int(frame[7])<<8 | int(frame[8])
	if len(frame) < 9+n do return nil, false
	instance := string(frame[9:9+n])
	if !strings.has_prefix(instance, "inst_pty_") && !strings.has_prefix(instance, "inst_notice_") do return nil, false
	return frame[9+n:], true
}

pty_test_send :: proc(socket: string, frame: []byte) -> bool {
	data, captured := pty_test_captured(frame)
	if !captured do return bridge_pty_host_send_oneway(socket, frame)
	if pty_test_send_fail do return false
	heap := runtime.heap_allocator()
	if pty_test_ops.allocator.procedure == nil do pty_test_ops = make([dynamic]Pty_Test_Op, heap)
	switch frame[4] {
	case PTY_HOST_T_INPUT: append(&pty_test_ops, Pty_Test_Op{input = strings.clone(string(data), heap)})
	case PTY_HOST_T_KEY: append(&pty_test_ops, Pty_Test_Op{key = Pty_Host_Key(data[0]), is_key = true})
	}
	return true
}
pty_test_daemon :: proc() -> (string, bool) { return "pty-test-socket", true }
pty_test_sleep :: proc(ms: int) {}

// Typed inputs so far and the last one typed.
pty_test_inputs :: proc() -> (count: int, last: string) {
	for op in pty_test_ops do if !op.is_key { count += 1; last = op.input }
	return
}

pty_test_reset :: proc() {
	for op in pty_test_ops do delete(op.input, runtime.heap_allocator())
	clear(&pty_test_ops)
}

// Text renders the ops compactly: typed text in quotes, keys by name.
pty_test_trace :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for op, i in pty_test_ops {
		if i > 0 do strings.write_string(&b, " ")
		if op.is_key { fmt.sbprintf(&b, "%v", op.key) } else { fmt.sbprintf(&b, "%q", op.input) }
	}
	return strings.to_string(b)
}

Pty_Test_Env :: struct {
	daemon:  proc() -> (string, bool),
	send:    proc(socket: string, frame: []byte) -> bool,
	sleep:   proc(ms: int),
	queue:   Bridge_Task_Notice_Queue,
	data:    string,
	dir:     string,
}

// pty_test_begin installs the capture seams, an empty notice queue and a
// private data dir. Hold bridge_test_config_mutex around begin/end.
pty_test_begin :: proc(name: string) -> Pty_Test_Env {
	env := Pty_Test_Env{daemon = pty_runtime_daemon, send = pty_runtime_send, sleep = pty_runtime_sleep, queue = bridge_task_notices, data = bridge_config.data_dir}
	pty_runtime_daemon = pty_test_daemon; pty_runtime_send = pty_test_send; pty_runtime_sleep = pty_test_sleep
	bridge_task_notices = {}
	env.dir = fmt.aprintf("%s/.cache/heimdall-tests/%s-%d", os.get_env("HOME", context.temp_allocator), name, sync.current_thread_id(), allocator = runtime.heap_allocator())
	bridge_config.data_dir = env.dir
	pty_test_reset(); pty_test_send_fail = false
	return env
}

pty_test_end :: proc(env: ^Pty_Test_Env) {
	pty_runtime_daemon = env.daemon; pty_runtime_send = env.send; pty_runtime_sleep = env.sleep
	bridge_task_notice_queue_delete(&bridge_task_notices); bridge_task_notices = env.queue
	bridge_config.data_dir = env.data
	os.remove_all(env.dir); delete(env.dir, runtime.heap_allocator())
	pty_test_reset(); pty_test_send_fail = false
}

// pty_test_activity sets an instance live and started with the given activity
// as if reported by source (pane_diff / claude_extension / bridge).
pty_test_activity :: proc(id, activity, source: string, updated_ms: i64 = 0) {
	bridge_runtime_set_status(id, "running", activity)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == id {
		inst.activity_status = activity
		inst.activity_source = source
		inst.activity_updated_unix_ms = updated_ms if updated_ms != 0 else bridge_runtime_now_ms()
		inst.pty_process_alive = true
		inst.start_success_seen = true
	}
}

pty_test_forget_typed :: proc(id: string) {
	sync.mutex_lock(&pty_runtime_typed_mu); defer sync.mutex_unlock(&pty_runtime_typed_mu)
	if pty_runtime_typed == nil do return
	for k in pty_runtime_typed do if k == id { delete_key(&pty_runtime_typed, k); delete(k, runtime.heap_allocator()); break }
}

// ---- key data -------------------------------------------------------------------

@(test)
pty_delivery_modes_are_fixed_step_lists :: proc(t: ^testing.T) {
	testing.expect_value(t, len(pty_runtime_plan(.Queue)), 2)
	testing.expect(t, pty_runtime_plan(.Queue)[0] == .Type && pty_runtime_plan(.Queue)[1] == .Submit, "queue = type, submit")
	sn := pty_runtime_plan(.Send_Now)
	testing.expect(t, len(sn) == 4 && sn[0] == .Interrupt && sn[1] == .Wait_Idle && sn[2] == .Type && sn[3] == .Submit, "send_now = interrupt, wait idle, type, submit")
	st := pty_runtime_plan(.Steer)
	testing.expect(t, len(st) == 3 && st[0] == .Interrupt && st[1] == .Type && st[2] == .Submit, "steer = interrupt, type, submit")
}

@(test)
pty_delivery_key_data_defaults_descriptor_then_profile :: proc(t: ^testing.T) {
	d := contracts.pty_delivery_resolve()
	testing.expect(t, len(d.interrupt_keys) == 1 && d.interrupt_keys[0] == "esc", "interrupt defaults to Esc")
	testing.expect(t, len(d.submit_keys) == 1 && d.submit_keys[0] == "enter" && d.second_submit, "submit defaults to Enter twice")
	testing.expect(t, d.paste_mode == .Raw && d.sanitize && !d.can_steer)
	codex, _ := contracts.provider_descriptor("codex")
	testing.expect(t, contracts.pty_delivery_resolve(codex.pty_delivery).paste_mode == .Bracketed, "codex pastes bracketed (descriptor data)")
	profile := contracts.Pty_Delivery_Spec{interrupt_keys = {"ctrl_c"}, second_submit = "off", can_steer = "on", paste_mode = "raw", submit_delay_ms = -1}
	r := contracts.pty_delivery_resolve(codex.pty_delivery, profile)
	testing.expect(t, r.interrupt_keys[0] == "ctrl_c" && !r.second_submit && r.can_steer && r.paste_mode == .Raw && r.submit_delay_ms == 0, "profile overrides the descriptor")
	testing.expect_value(t, r.submit_keys[0], "enter")
	bad := contracts.Pty_Delivery_Spec{interrupt_keys = {"rm -rf"}, can_steer = "on"}
	testing.expect(t, !contracts.pty_delivery_spec_valid(bad))
	testing.expect(t, !contracts.pty_delivery_resolve(bad).can_steer, "an invalid layer is skipped whole")
	for p in contracts.provider_descriptors() do testing.expect(t, contracts.pty_delivery_spec_valid(p.pty_delivery), p.provider)
}

@(test)
pty_delivery_profile_override_reaches_instance_and_is_validated :: proc(t: ^testing.T) {
	pp := Provider_Profile{provider = "claude"}
	pp.config.pty_delivery = {submit_keys = {"bogus"}}
	testing.expect(t, profile_validate(&pp) == .Config_Invalid, "unknown key names are rejected at save")
	pp.config.pty_delivery = {submit_keys = {"tab", "enter"}}
	testing.expect(t, profile_validate(&pp) != .Config_Invalid)
	// An untracked instance resolves the defaults; a tracked provider its descriptor.
	testing.expect(t, pty_runtime_delivery("inst_pty_untracked").paste_mode == .Raw)
	bridge_pty_host_track_instance_provider("inst_pty_codex_track", "codex", "")
	defer bridge_pty_host_untrack_instance_provider("inst_pty_codex_track")
	testing.expect(t, pty_runtime_delivery("inst_pty_codex_track").paste_mode == .Bracketed)
	provider, profile := bridge_pty_host_instance_profile("inst_pty_codex_track")
	testing.expect(t, provider == "codex" && profile == "")
}

@(test)
pty_body_is_pasted_without_esc :: proc(t: ^testing.T) {
	raw := pty_runtime_body("stop\x1b now\r\nplease\n", contracts.pty_delivery_resolve())
	defer delete(raw)
	testing.expect_value(t, raw, "stop now please ")
	bracketed := pty_runtime_body("a\x1bb", contracts.pty_delivery_resolve({paste_mode = "bracketed"}))
	defer delete(bracketed)
	testing.expect_value(t, bracketed, "\x1b[200~ab\x1b[201~")
}

// ---- delivery modes -------------------------------------------------------------

@(test)
pty_queue_waits_for_trusted_idle_and_never_presses_esc :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-queue"); defer pty_test_end(&env)
	id := "inst_pty_queue"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_forget_typed(id)
	pty_test_activity(id, "active", "pane_diff")
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_q1", text = "New message from User", hub_message = true}))
	bridge_task_notice_tick(bridge_runtime_now_ms() + 1)
	testing.expect_value(t, len(pty_test_ops), 0) // busy: nothing typed
	testing.expect_value(t, len(bridge_task_notices.entries), 1) // admitted durably
	// A launch default "idle" is not a trusted idle.
	pty_test_activity(id, "idle", "bridge")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 5000)
	testing.expect_value(t, len(pty_test_ops), 0)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 10_000)
	testing.expect_value(t, pty_test_trace(), `"New message from User" Enter Enter`)
	testing.expect_value(t, len(bridge_task_notices.entries), 0)
	// The next input waits until the typed turn has been seen.
	pty_test_reset()
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_q2", text = "second"}))
	bridge_task_notice_tick(bridge_runtime_now_ms() + 20_000)
	testing.expect_value(t, len(pty_test_ops), 0)
	pty_test_activity(id, "idle", "claude_extension", bridge_runtime_now_ms() + 1)
	bridge_task_notice_tick(bridge_runtime_now_ms() + 30_000)
	testing.expect_value(t, pty_test_trace(), `"second" Enter Enter`)
}

@(test)
pty_notifications_never_interrupt :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-notify"); defer pty_test_end(&env)
	id := "inst_pty_notify"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_forget_typed(id)
	pty_test_activity(id, "active", "pane_diff")
	// Even an explicit steer / send now request for a notification only queues.
	for mode in ([]Runtime_Mode{.Queue, .Steer, .Send_Now}) {
		testing.expect(t, bridge_runtime_submit(id, {kind = .Notification, id = fmt.tprintf("cmd_%v", mode), text = "Shell run sh_1 exited.", origin = "shell_run"}, mode))
	}
	testing.expect_value(t, len(pty_test_ops), 0)
	testing.expect_value(t, len(bridge_task_notices.entries), 3)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1)
	// One turn for the batch; the repeated line is typed once; no Esc anywhere.
	testing.expect_value(t, pty_test_trace(), `"Shell run sh_1 exited." Enter Enter`)
	testing.expect(t, bridge_runtime_effective_mode(&pty_agent_runtime, id, .Notification, .Send_Now) == .Queue)
}

@(test)
pty_steer_and_send_now_follow_key_data :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-modes"); defer pty_test_end(&env)
	id := "inst_pty_modes"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	// Default key data cannot steer: steer becomes send now (CONTRACT-06/15).
	testing.expect(t, !bridge_runtime_can_steer(id))
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, text = "now please"}, .Steer))
	testing.expect_value(t, pty_test_trace(), `Esc "now please" Enter Enter`)
	testing.expect_value(t, len(bridge_task_notices.entries), 0)
	pty_test_reset()
	testing.expect(t, pty_runtime_execute("s", id, "go", .Steer, contracts.pty_delivery_resolve({interrupt_keys = {"ctrl_c", "esc"}, second_submit = "off", can_steer = "on"})))
	testing.expect_value(t, pty_test_trace(), `Ctrl_C Esc "go" Enter`)
	pty_test_reset()
	testing.expect(t, bridge_runtime_interrupt(id))
	testing.expect_value(t, pty_test_trace(), `Esc`)
	// An unreachable terminal keeps the input in the durable inbox.
	pty_test_reset(); pty_test_send_fail = true
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_late", text = "late"}, .Send_Now))
	testing.expect_value(t, len(bridge_task_notices.entries), 1)
}

@(test)
pty_send_now_delivers_frozen_fifo_batch_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-send-now"); defer pty_test_end(&env)
	id := "inst_pty_send_now"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	for m in ([]string{"msg_a", "msg_b", "msg_c"}) {
		testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = m, text = fmt.tprintf("text %s", m)}))
	}
	testing.expect(t, bridge_runtime_submit(id, {kind = .Notification, id = "cmd_n", text = "notice"}))
	rt := bridge_runtime_for(id)
	testing.expect(t, rt == &pty_agent_runtime)
	// Empty selection: a no-op that never interrupts.
	testing.expect(t, rt.send_now(id, {batch_id = "snb_empty", attempt = 1, message_ids = {"msg_gone"}}))
	testing.expect_value(t, len(pty_test_ops), 0)
	// The batch is the listed inputs still queued, in FIFO order, as one turn.
	testing.expect(t, rt.send_now(id, {batch_id = "snb_1", attempt = 1, message_ids = {"msg_c", "msg_a", "cmd_n"}}))
	testing.expect_value(t, pty_test_trace(), `Esc "text msg_a | text msg_c" Enter Enter`)
	testing.expect_value(t, len(bridge_task_notices.entries), 2) // msg_b and the notification stay queued
	pty_test_reset()
	testing.expect(t, rt.send_now(id, {batch_id = "snb_1", attempt = 2, message_ids = {"msg_b"}}), "idempotent by batch")
	testing.expect_value(t, len(pty_test_ops), 0)
	// Read inputs need no notice any more.
	testing.expect(t, rt.inputs_read(id, {"msg_b"}))
	testing.expect_value(t, len(bridge_task_notices.entries), 1)
	testing.expect_value(t, bridge_task_notices.entries[0].id, "cmd_n")
}

@(test)
pty_inbox_survives_restart :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-durable"); defer pty_test_end(&env)
	id := "inst_pty_durable"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_d", text = "durable"}))
	path := bridge_task_notice_path(); defer delete(path)
	raw, err := os.read_entire_file(path, context.allocator); defer delete(raw)
	restored: Bridge_Task_Notice_Queue; defer bridge_task_notice_queue_delete(&restored)
	testing.expect(t, err == nil && bridge_task_notice_restore(&restored, string(raw), bridge_runtime_now_ms()))
	testing.expect(t, len(restored.entries) == 1 && restored.entries[0].id == "msg_d" && restored.entries[0].kind == BRIDGE_NOTICE_USER_MESSAGE)
	testing.expect(t, bridge_task_notice_merge(&restored, restored.entries[0]), "a retried admission merges by id")
	testing.expect_value(t, len(restored.entries), 1)
}

// ---- shared interface policy -------------------------------------------------------

runtime_test_calls: [dynamic]string
runtime_test_steer: bool

runtime_test_submit :: proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool {
	append(&runtime_test_calls, fmt.aprintf("%v:%v", input.kind, mode, allocator = runtime.heap_allocator()))
	return true
}
runtime_test_can_steer :: proc(instance: string) -> bool { return runtime_test_steer }

@(test)
runtime_interface_policy_and_selection :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	fake := Agent_Runtime{transport = "fake_transport", submit = runtime_test_submit, can_steer = runtime_test_can_steer}
	_ = bridge_agent_runtime_list()
	sync.mutex_lock(&bridge_agent_runtimes_mu); append(&bridge_agent_runtimes, &fake); sync.mutex_unlock(&bridge_agent_runtimes_mu)
	defer { sync.mutex_lock(&bridge_agent_runtimes_mu); pop(&bridge_agent_runtimes); sync.mutex_unlock(&bridge_agent_runtimes_mu) }
	defer { for c in runtime_test_calls do delete(c); clear(&runtime_test_calls) }
	id := "inst_runtime_fake"
	bridge_runtime_set_status(id, "running", "idle")
	defer bridge_runtime_set_status(id, "stopped", "idle")
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == id do inst.runtime_transport = "fake_transport"
	sync.mutex_unlock(&bridge_runtime_mutex)
	testing.expect(t, bridge_runtime_for(id) == &fake, "selected by recorded transport")
	testing.expect(t, bridge_runtime_for("inst_runtime_unknown") == &pty_agent_runtime, "unknown instances are PTY")
	runtime_test_steer = false
	_ = bridge_runtime_submit(id, {kind = .User_Message}, .Steer)
	runtime_test_steer = true
	_ = bridge_runtime_submit(id, {kind = .User_Message}, .Steer)
	_ = bridge_runtime_submit(id, {kind = .User_Message})
	_ = bridge_runtime_submit(id, {kind = .Notification}, .Send_Now)
	testing.expect_value(t, len(runtime_test_calls), 4)
	if len(runtime_test_calls) == 4 {
		testing.expect_value(t, runtime_test_calls[0], "User_Message:Send_Now") // cannot steer: interrupt + prompt
		testing.expect_value(t, runtime_test_calls[1], "User_Message:Steer")
		testing.expect_value(t, runtime_test_calls[2], "User_Message:Queue") // queue is the default
		testing.expect_value(t, runtime_test_calls[3], "Notification:Queue") // notifications never interrupt
	}
	testing.expect(t, !bridge_runtime_interrupt(id), "a runtime without interrupt reports false")
}

runtime_test_events: [dynamic]Runtime_Event
runtime_test_event_sink :: proc(instance: string, event: Runtime_Event) {
	if instance == "inst_runtime_events" do append(&runtime_test_events, event)
}

@(test)
runtime_activity_transitions_emit_turn_events :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	prev := bridge_runtime_event_sink; bridge_runtime_event_sink = runtime_test_event_sink
	defer { bridge_runtime_event_sink = prev; delete(runtime_test_events); runtime_test_events = nil }
	id := "inst_runtime_events"
	bridge_runtime_set_status(id, "running", "idle")
	defer bridge_runtime_set_status(id, "stopped", "idle")
	clear(&runtime_test_events)
	bridge_runtime_set_status(id, "running", "active")
	bridge_runtime_set_status(id, "running", "idle")
	testing.expect_value(t, len(runtime_test_events), 3)
	if len(runtime_test_events) == 3 {
		testing.expect(t, runtime_test_events[0] == .Turn_Started && runtime_test_events[1] == .Turn_Ended && runtime_test_events[2] == .Idle)
	}
}
