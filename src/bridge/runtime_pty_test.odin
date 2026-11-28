package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
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
	data:    string,
	dir:     string,
}

// pty_test_queued lists an instance's queued input ids (temp-allocated).
pty_test_queued :: proc(instance: string) -> []string {
	ids := make([dynamic]string, context.temp_allocator)
	inbox := bridge_inbox_lock(instance)
	if inbox == nil do return nil
	defer bridge_inbox_unlock()
	for input in inbox.queue do append(&ids, strings.clone(input.id, context.temp_allocator))
	return ids[:]
}

// pty_test_begin installs the capture seams, an empty inbox registry and a
// private data dir. Hold bridge_test_config_mutex around begin/end.
pty_test_begin :: proc(name: string) -> Pty_Test_Env {
	env := Pty_Test_Env{daemon = pty_runtime_daemon, send = pty_runtime_send, sleep = pty_runtime_sleep, data = bridge_config.data_dir}
	pty_runtime_daemon = pty_test_daemon; pty_runtime_send = pty_test_send; pty_runtime_sleep = pty_test_sleep
	bridge_inbox_forget_all(); bridge_task_states_reset()
	env.dir = fmt.aprintf("%s/.cache/heimdall-tests/%s-%d", os.get_env("HOME", context.temp_allocator), name, sync.current_thread_id(), allocator = runtime.heap_allocator())
	bridge_config.data_dir = env.dir
	pty_test_reset(); pty_test_send_fail = false
	return env
}

pty_test_end :: proc(env: ^Pty_Test_Env) {
	pty_runtime_daemon = env.daemon; pty_runtime_send = env.send; pty_runtime_sleep = env.sleep
	bridge_inbox_forget_all(); bridge_task_states_reset()
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
		inst.runtime_transport = pty_agent_runtime.transport
		inst.activity_status = activity
		inst.activity_source = source
		inst.activity_source_kind = bridge_activity_source_kind(source)
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

@(test)
activity_source_kind_is_parsed_once_and_decides_trust :: proc(t: ^testing.T) {
	testing.expect(t, bridge_activity_source_kind("pane_diff") == .Pane_Diff)
	testing.expect(t, bridge_activity_source_kind("claude_extension") == .Extension)
	testing.expect(t, bridge_activity_source_kind("Codex_Extension ") == .Extension)
	testing.expect(t, bridge_activity_source_kind("acp") == .ACP)
	testing.expect(t, bridge_activity_source_kind("permission_gate") == .Permission_Gate)
	testing.expect(t, bridge_activity_source_kind("bridge") == .Bridge && bridge_activity_source_kind("wrapper") == .Wrapper)
	testing.expect(t, bridge_activity_source_kind("pane_diff_v2") == .Other)
	for kind in Bridge_Activity_Source {
		want := kind == .Extension || kind == .Pane_Diff
		testing.expect(t, bridge_activity_source_trusted_idle(kind) == want, fmt.tprintf("%v", kind))
	}
	testing.expect(t, bridge_runtime_activity_source_rank("claude_extension") > bridge_runtime_activity_source_rank("pane_diff"))
	testing.expect(t, bridge_runtime_activity_source_rank("pane_diff") == bridge_runtime_activity_source_rank("permission_gate"))
	// The recorded kind follows the accepted source.
	id := "inst_pty_kind"
	bridge_runtime_set_status(id, "running", "idle")
	defer bridge_runtime_set_status(id, "stopped", "idle")
	snap, _ := bridge_runtime_instance_snapshot(id)
	testing.expect(t, snap.activity_source_kind == .Bridge)
}

// ---- key data -------------------------------------------------------------------

@(test)
pty_delivery_modes_are_fixed_step_lists :: proc(t: ^testing.T) {
	testing.expect_value(t, len(pty_runtime_plan(.Queue)), 2)
	testing.expect(t, pty_runtime_plan(.Queue)[0] == .Type && pty_runtime_plan(.Queue)[1] == .Submit, "queue = type, submit")
	sn := pty_runtime_plan(.Send_Now)
	testing.expect(t, len(sn) == 3 && sn[0] == .Interrupt && sn[1] == .Type && sn[2] == .Submit, "send_now = interrupt, type, submit (no idle wait)")
	st := pty_runtime_plan(.Steer)
	testing.expect(t, len(st) == 3 && st[0] == .Interrupt_If_Busy && st[1] == .Type && st[2] == .Submit, "steer = interrupt only while busy, type, submit")
}

@(test)
pty_delivery_key_data_defaults_descriptor_then_profile :: proc(t: ^testing.T) {
	d := contracts.pty_delivery_resolve()
	testing.expect(t, len(d.interrupt_keys) == 1 && d.interrupt_keys[0] == "esc", "interrupt defaults to Esc")
	testing.expect(t, len(d.submit_keys) == 1 && d.submit_keys[0] == "enter" && d.second_submit, "submit defaults to Enter twice")
	testing.expect(t, d.paste_mode == .Raw && d.sanitize && d.can_steer, "every PTY runtime can steer by default")
	codex, _ := contracts.provider_descriptor("codex")
	testing.expect(t, contracts.pty_delivery_resolve(codex.pty_delivery).paste_mode == .Bracketed, "codex pastes bracketed (descriptor data)")
	profile := contracts.Pty_Delivery_Spec{interrupt_keys = {"ctrl_c"}, second_submit = "off", can_steer = "off", paste_mode = "raw", submit_delay_ms = -1}
	r := contracts.pty_delivery_resolve(codex.pty_delivery, profile)
	testing.expect(t, r.interrupt_keys[0] == "ctrl_c" && !r.second_submit && !r.can_steer && r.paste_mode == .Raw && r.submit_delay_ms == 0, "profile overrides the descriptor")
	testing.expect_value(t, r.submit_keys[0], "enter")
	bad := contracts.Pty_Delivery_Spec{interrupt_keys = {"rm -rf"}, can_steer = "off"}
	testing.expect(t, !contracts.pty_delivery_spec_valid(bad))
	testing.expect(t, contracts.pty_delivery_resolve(bad).can_steer, "an invalid layer is skipped whole")
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
	testing.expect_value(t, len(pty_test_queued(id)), 1) // admitted durably
	// A launch default "idle" is not a trusted idle.
	pty_test_activity(id, "idle", "bridge")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 5000)
	testing.expect_value(t, len(pty_test_ops), 0)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 10_000)
	testing.expect_value(t, pty_test_trace(), `"New message from User" Enter Enter`)
	testing.expect_value(t, len(pty_test_queued(id)), 0)
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
	testing.expect_value(t, len(pty_test_queued(id)), 3)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1)
	// One turn for the batch; the repeated line is typed once; no Esc anywhere.
	testing.expect_value(t, pty_test_trace(), `"Shell run sh_1 exited." Enter Enter`)
	testing.expect(t, bridge_runtime_effective_mode(&pty_agent_runtime, id, .Notification, .Send_Now) == .Queue)
}

@(test)
pty_steer_interrupts_only_while_busy :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-steer"); defer pty_test_end(&env)
	id := "inst_pty_steer"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	// Default key data can steer: steer stays steer (it is not send now).
	testing.expect(t, bridge_runtime_can_steer(id))
	testing.expect(t, bridge_runtime_effective_mode(&pty_agent_runtime, id, .User_Message, .Steer) == .Steer)
	// Busy: stop the turn, then the agent reads the current message.
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, text = "now please"}, .Steer))
	testing.expect_value(t, pty_test_trace(), `Esc "now please" Enter Enter`)
	testing.expect_value(t, len(pty_test_queued(id)), 0)
	// At a trusted idle: no interrupt key.
	pty_test_reset()
	pty_test_activity(id, "idle", "pane_diff")
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, text = "idle steer"}, .Steer))
	testing.expect_value(t, pty_test_trace(), `"idle steer" Enter Enter`)
	// The key data decides the interrupt keys and the submit.
	pty_test_reset()
	pty_test_activity(id, "active", "pane_diff")
	testing.expect(t, pty_runtime_execute("s", id, "go", .Steer, contracts.pty_delivery_resolve({interrupt_keys = {"ctrl_c", "esc"}, second_submit = "off"})))
	testing.expect_value(t, pty_test_trace(), `Ctrl_C Esc "go" Enter`)
	pty_test_reset()
	testing.expect(t, bridge_runtime_interrupt(id))
	testing.expect_value(t, pty_test_trace(), `Esc`)
	// An unreachable terminal keeps the input in the durable inbox.
	pty_test_reset(); pty_test_send_fail = true
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_late", text = "late"}, .Send_Now))
	testing.expect_value(t, len(pty_test_queued(id)), 1)
}

// A profile that turns steering off makes steer a send now (always Esc).
@(test)
pty_profile_can_steer_off_makes_steer_send_now :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&g_profile_test_mu); defer sync.mutex_unlock(&g_profile_test_mu)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-steer-off"); defer pty_test_end(&env)
	previous_profiles := g_profile_test_store_path
	defer g_profile_test_store_path = previous_profiles
	bridge_make_directory_all(env.dir)
	g_profile_test_store_path = strings.concatenate({env.dir, "/profiles.json"}, context.temp_allocator)
	pp := Provider_Profile{profile_id = "claude_nosteer", provider = "claude", enabled = true}
	pp.config.pty_delivery = {can_steer = "off"}
	raw, _ := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = {pp}}, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(g_profile_test_store_path, raw) == nil)
	id := "inst_pty_steer_off"
	bridge_pty_host_track_instance_provider(id, "claude", "claude_nosteer")
	defer bridge_pty_host_untrack_instance_provider(id)
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "idle", "pane_diff")
	testing.expect(t, !bridge_runtime_can_steer(id), "the profile turned steering off")
	testing.expect(t, bridge_runtime_effective_mode(&pty_agent_runtime, id, .User_Message, .Steer) == .Send_Now)
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, text = "steer"}, .Steer))
	testing.expect_value(t, pty_test_trace(), `Esc "steer" Enter Enter`)
}

// Several queued user messages leave ONE pending unread notice, typed once at
// the next trusted idle; notifications keep their own lane.
@(test)
pty_unread_messages_coalesce_into_one_notice :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-unread"); defer pty_test_end(&env)
	id := "inst_pty_unread"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_forget_typed(id)
	pty_test_activity(id, "active", "pane_diff")
	notice := bridge_pty_host_message_notice("User"); defer delete(notice)
	for m in ([]string{"msg_u1", "msg_u2", "msg_u3"}) {
		testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = m, text = notice, hub_message = true}))
	}
	bridge_task_notice_tick(bridge_runtime_now_ms() + 1)
	testing.expect_value(t, len(pty_test_ops), 0) // busy: never typed, never interrupted
	ids := pty_test_queued(id)
	testing.expect(t, len(ids) == 1 && ids[0] == "msg_u3", "one coalesced notice")
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_u1", text = notice, hub_message = true}), "a retried admission is acknowledged")
	testing.expect_value(t, len(pty_test_queued(id)), 1)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 10_000)
	testing.expect_value(t, pty_test_trace(), fmt.tprintf("%q Enter Enter", bridge_pty_host_unread_notice()))
	testing.expect_value(t, len(pty_test_queued(id)), 0)
}

@(test)
pty_send_now_types_the_notice_once_per_request :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-send-now"); defer pty_test_end(&env)
	id := "inst_pty_send_now"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	for m in ([]string{"msg_a", "msg_b"}) {
		testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = m, text = "New message from User", hub_message = true}))
	}
	testing.expect(t, bridge_runtime_submit(id, {kind = .Notification, id = "cmd_n", text = "notice", origin = "shell_run"}))
	rt := bridge_runtime_for(id)
	testing.expect(t, rt == &pty_agent_runtime)
	want := fmt.tprintf("Esc %q Enter Enter", bridge_pty_host_unread_notice())
	// Busy: Esc, the notice, Enter; no members needed. The pending unread
	// notice is consumed; the notification keeps its own lane.
	testing.expect(t, rt.send_now(id, {batch_id = "snb_1", attempt = 1}) == .Delivered)
	testing.expect_value(t, pty_test_trace(), want)
	ids := pty_test_queued(id)
	testing.expect(t, len(ids) == 1 && ids[0] == "cmd_n", "the unread notice was consumed")
	// A repeated request id is a no-op, also after a reload of the inbox.
	pty_test_reset()
	testing.expect(t, rt.send_now(id, {batch_id = "snb_1", attempt = 2}) == .Delivered, "idempotent by request")
	testing.expect_value(t, len(pty_test_ops), 0)
	bridge_inbox_forget_all()
	bridge_inbox_restore_all()
	testing.expect(t, rt.send_now(id, {batch_id = "snb_1", attempt = 1}) == .Delivered, "idempotent after reload")
	testing.expect_value(t, len(pty_test_ops), 0)
	// Idle: Send now still presses Esc (no idle wait, no skip).
	pty_test_activity(id, "idle", "pane_diff")
	testing.expect(t, rt.send_now(id, {batch_id = "snb_2", attempt = 1}) == .Delivered)
	testing.expect_value(t, pty_test_trace(), want)
	// A failed write is not remembered: the retry types.
	pty_test_reset(); pty_test_send_fail = true
	testing.expect(t, rt.send_now(id, {batch_id = "snb_3", attempt = 1}) == .Failed)
	pty_test_send_fail = false
	testing.expect(t, rt.send_now(id, {batch_id = "snb_3", attempt = 2}) == .Delivered)
	testing.expect_value(t, pty_test_trace(), want)
	testing.expect(t, rt.send_now(id, {batch_id = ""}) == .Failed, "a request id is required")
	// Read inputs need no notice any more.
	testing.expect(t, rt.inputs_read(id, {"cmd_n"}))
	testing.expect_value(t, len(pty_test_queued(id)), 0)
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
	testing.expect(t, bridge_runtime_submit(id, {kind = .Notification, id = "cmd_d", text = "notice", origin = "shell_run"}))
	// A bridge restart: memory is gone, the inbox file is the truth.
	bridge_inbox_forget_all()
	bridge_inbox_restore_all()
	testing.expect_value(t, len(pty_test_queued(id)), 2)
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_d", text = "durable"}), "a retried admission merges by id")
	ids := pty_test_queued(id)
	testing.expect(t, len(ids) == 2 && ids[0] == "msg_d" && ids[1] == "cmd_d")
	// The restored inputs replay as one turn at the next trusted idle, once.
	pty_test_forget_typed(id)
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1)
	testing.expect_value(t, pty_test_trace(), `"durable | notice" Enter Enter`)
	testing.expect_value(t, len(pty_test_queued(id)), 0)
	bridge_inbox_forget_all()
	bridge_inbox_restore_all()
	testing.expect_value(t, len(pty_test_queued(id)), 0)
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_d", text = "durable"}), "a delivered identity is acknowledged")
	testing.expect_value(t, len(pty_test_queued(id)), 0)
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
	runtimes := []^Agent_Runtime{&pty_agent_runtime, &fake}
	defer { for c in runtime_test_calls do delete(c); clear(&runtime_test_calls) }
	id := "inst_runtime_fake"
	testing.expect(t, bridge_runtime_lookup(runtimes, "fake_transport") == &fake, "selected by recorded transport")
	testing.expect(t, bridge_runtime_lookup(runtimes, "pty") == &pty_agent_runtime)
	runtime_test_steer = false
	_ = bridge_runtime_submit_to(&fake, id, {kind = .User_Message}, .Steer)
	runtime_test_steer = true
	_ = bridge_runtime_submit_to(&fake, id, {kind = .User_Message}, .Steer)
	_ = bridge_runtime_submit_to(&fake, id, {kind = .User_Message})
	_ = bridge_runtime_submit_to(&fake, id, {kind = .Notification}, .Send_Now)
	testing.expect_value(t, len(runtime_test_calls), 4)
	if len(runtime_test_calls) == 4 {
		testing.expect_value(t, runtime_test_calls[0], "User_Message:Send_Now") // cannot steer: interrupt + prompt
		testing.expect_value(t, runtime_test_calls[1], "User_Message:Steer")
		testing.expect_value(t, runtime_test_calls[2], "User_Message:Queue") // queue is the default
		testing.expect_value(t, runtime_test_calls[3], "Notification:Queue") // notifications never interrupt
	}
}

// No silent PTY fallback: an instance without a recognised transport has no
// runtime, and inputs for it are reported as not delivered.
@(test)
runtime_unknown_transport_is_not_routed_to_pty :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	list := bridge_agent_runtime_list()
	testing.expect(t, bridge_runtime_lookup(list[:], "") == nil, "no transport recorded")
	testing.expect(t, bridge_runtime_lookup(list[:], "tmux") == nil, "unrecognised transport")
	testing.expect(t, bridge_runtime_for("inst_runtime_never_seen") == nil, "unknown instance")
	id := "inst_runtime_untyped"
	bridge_runtime_set_status(id, "running", "idle")
	defer bridge_runtime_set_status(id, "stopped", "idle")
	testing.expect(t, bridge_runtime_owner(id) == nil, "a known instance without a recorded transport has no runtime")
	testing.expect(t, !bridge_runtime_submit(id, {kind = .User_Message, text = "hello"}), "not delivered")
	testing.expect(t, !bridge_runtime_interrupt(id))
	testing.expect(t, !bridge_runtime_can_steer(id))
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

// The interface stays narrow: the core methods plus the justified extras, and
// the inbox worker drives a PTY runtime through its delivery target.
@(test)
runtime_interface_is_narrow_and_inbox_driven :: proc(t: ^testing.T) {
	names := reflect.struct_field_names(Agent_Runtime)
	want := []string{"transport", "submit", "send_now", "interrupt", "stop", "can_steer", "usage", "inputs_read", "release", "child_exited", "raw_input"}
	testing.expect_value(t, len(names), len(want))
	for n in want do testing.expect(t, slice.contains(names, n), n)
	for rt in bridge_agent_runtime_list() {
		testing.expect(t, rt.submit != nil && rt.send_now != nil && rt.interrupt != nil && rt.can_steer != nil && rt.usage != nil, rt.transport)
	}
	testing.expect(t, pty_inbox_target.transport == pty_agent_runtime.transport)
	testing.expect(t, bridge_inbox_target("inst_runtime_never_seen") == nil, "no runtime, no delivery")
}

// pty_test_set_busy marks an instance's inbox as being typed (or not).
pty_test_set_busy :: proc(instance: string, busy: bool) {
	sync.mutex_lock(&bridge_inbox_mu); defer sync.mutex_unlock(&bridge_inbox_mu)
	if slot := bridge_inbox_slot_locked(instance); slot != nil do slot.busy = busy
}

// S3: an explicit steer goes through Send now's consume-and-busy section: it
// consumes the pending unread notice (typed once), commits its own identity,
// and never types while the worker is typing.
@(test)
pty_explicit_steer_consumes_the_pending_notice_and_respects_busy :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-explicit"); defer pty_test_end(&env)
	id := "inst_pty_explicit"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	notice := bridge_pty_host_unread_notice()
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_e1", text = notice, hub_message = true}))
	testing.expect_value(t, len(pty_test_queued(id)), 1)
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_e2", text = notice, hub_message = true}, .Steer))
	testing.expect_value(t, pty_test_trace(), fmt.tprintf("Esc %q Enter Enter", notice))
	testing.expect_value(t, len(pty_test_queued(id)), 0) // the pending notice was consumed
	// Nothing is left for the worker to type again.
	pty_test_reset()
	pty_test_activity(id, "idle", "pane_diff")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 20_000)
	testing.expect_value(t, len(pty_test_ops), 0)
	// The steered identity is completed: a retried admission is acknowledged.
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_e2", text = notice, hub_message = true}))
	testing.expect_value(t, len(pty_test_queued(id)), 0)
	// While a delivery is being typed, an explicit steer waits in the inbox.
	pty_test_set_busy(id, true)
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_e3", text = notice, hub_message = true}, .Steer))
	testing.expect_value(t, len(pty_test_ops), 0)
	testing.expect_value(t, len(pty_test_queued(id)), 1)
	pty_test_set_busy(id, false)
}

// pty_test_lifecycle overrides an instance's liveness facts.
pty_test_lifecycle :: proc(id: string, alive, started: bool, stop_intent: i64 = 0) {
	sync.mutex_lock(&bridge_runtime_mutex); defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == id {
		inst.pty_process_alive = alive; inst.start_success_seen = started; inst.stopped_intent_unix_ms = stop_intent
	}
}

// B1 (CONTRACT-10): Send now and explicit modes type only into a live,
// started agent without a stop in flight. Otherwise nothing is typed, the
// outcome is not delivered and the pending notice survives.
@(test)
pty_send_now_to_a_stopped_agent_is_not_delivered_and_keeps_the_notice :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-send-now-dead"); defer pty_test_end(&env)
	id := "inst_pty_send_now_dead"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_activity(id, "active", "pane_diff")
	notice := bridge_pty_host_unread_notice()
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_dead", text = notice, hub_message = true}))
	rt := bridge_runtime_for(id)
	cases := []struct{ alive, started: bool, stop: i64 }{{false, true, 0}, {true, true, 1}, {true, false, 0}}
	for c in cases {
		pty_test_lifecycle(id, c.alive, c.started, c.stop)
		testing.expect(t, rt.send_now(id, {batch_id = "snb_dead", attempt = 1}) == .Not_Running, fmt.tprintf("%v", c))
		testing.expect(t, !bridge_runtime_submit(id, {kind = .User_Message, id = "msg_dead_steer", text = notice, hub_message = true}, .Steer), "an explicit steer is not delivered")
		testing.expect_value(t, len(pty_test_ops), 0)
		ids := pty_test_queued(id)
		testing.expect(t, len(ids) == 1, "the pending notice survives (the steer coalesced into it)")
	}
	// Not applied: once the agent is back, the same request types.
	pty_test_lifecycle(id, true, true)
	testing.expect(t, rt.send_now(id, {batch_id = "snb_dead", attempt = 2}) == .Delivered)
	testing.expect_value(t, pty_test_trace(), fmt.tprintf("Esc %q Enter Enter", notice))
	testing.expect_value(t, len(pty_test_queued(id)), 0)
}

// The hub command reports a not-delivered Send now as a failed result whose
// cause names the outcome, so the Hub never records it as delivered.
@(test)
pty_send_now_command_result_carries_the_outcome_cause :: proc(t: ^testing.T) {
	for o in contracts.Runtime_Send_Now_Outcome {
		if o == .Delivered do continue
		raw := bridge_command_failed_json("cmd_x", bridge_cause_wire_error(contracts.RUNTIME_SEND_NOW_CAUSE[o], bridge_runtime_send_now_message(o)), "")
		defer delete(raw)
		werr, found := contracts.wire_error_parse(raw, context.temp_allocator)
		testing.expect(t, found && contracts.runtime_send_now_outcome_from_cause(werr.cause) == o, raw)
	}
}

pty_test_rollover_phase :: proc(id: string, phase: Bridge_Rollover_Phase) {
	sync.mutex_lock(&bridge_rollover_mutex); defer sync.mutex_unlock(&bridge_rollover_mutex)
	for &s in bridge_rollover_states do if s.agent_instance_id == id { s.phase = phase; return }
	append(&bridge_rollover_states, Bridge_Rollover_State{agent_instance_id = strings.clone(id, bridge_rollover_heap()), phase = phase})
}

// S1 (CONTRACT-13): during a context rollover Send now and explicit modes
// type nothing; the notice stays queued and the outcome is held.
@(test)
pty_send_now_during_a_rollover_types_nothing_and_reports_held :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-send-now-held"); defer pty_test_end(&env)
	id := "inst_pty_send_now_held"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	defer bridge_rollover_forget(id)
	pty_test_activity(id, "active", "pane_diff")
	notice := bridge_pty_host_unread_notice()
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_held", text = notice, hub_message = true}))
	rt := bridge_runtime_for(id)
	for phase in ([]Bridge_Rollover_Phase{.Requested, .Persisting, .Restarting}) {
		pty_test_rollover_phase(id, phase)
		testing.expect(t, rt.send_now(id, {batch_id = "snb_held", attempt = 1}) == .Held, fmt.tprintf("%v", phase))
		testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_held_steer", text = notice, hub_message = true}, .Steer), "an explicit steer stays queued")
		testing.expect_value(t, len(pty_test_ops), 0)
		testing.expect_value(t, len(pty_test_queued(id)), 1)
	}
	// The hold also keeps the queue drain from typing at an idle.
	pty_test_activity(id, "idle", "claude_extension")
	bridge_task_notice_tick(bridge_runtime_now_ms() + 20_000)
	testing.expect_value(t, len(pty_test_ops), 0)
	pty_test_rollover_phase(id, .Normal)
	testing.expect(t, rt.send_now(id, {batch_id = "snb_held", attempt = 2}) == .Delivered)
	testing.expect_value(t, pty_test_trace(), fmt.tprintf("Esc %q Enter Enter", notice))
	testing.expect_value(t, len(pty_test_queued(id)), 0)
}
