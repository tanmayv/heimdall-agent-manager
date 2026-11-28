package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// R7 rev 6: the bridge reports agent_notice_typed only after a typed batch with
// a user-message notice was committed, never when typing failed.

agent_notified_test_frames: [dynamic]string
agent_notified_test_fail: bool

agent_notified_test_send :: proc(conn: ^ws.Connection, text: string) -> bool {
	if agent_notified_test_fail do return false
	append(&agent_notified_test_frames, strings.clone(text, runtime.heap_allocator()))
	return true
}

agent_notified_test_pending :: proc(instance: string) -> (contracts.Agent_Notice_Typed_Frame, bool) {
	frames := bridge_agent_notified_take()
	found: contracts.Agent_Notice_Typed_Frame
	ok := false
	for f in frames {
		if f.agent_instance_id == instance { found = f; ok = true }
	}
	return found, ok
}

@(test)
pty_typed_user_notice_is_reported_after_commit_not_on_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-notified"); defer pty_test_end(&env)
	bridge_agent_notified_reset(); defer bridge_agent_notified_reset()
	id := "inst_pty_notified"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_forget_typed(id)
	pty_test_activity(id, "idle", "pane_diff")
	notice := bridge_pty_host_message_notice("User"); defer delete(notice)
	// Typing fails: the batch stays queued and nothing is reported.
	pty_test_send_fail = true
	testing.expect(t, bridge_runtime_submit(id, {kind = .User_Message, id = "msg_n1", text = notice, hub_message = true}))
	bridge_task_notice_tick(bridge_runtime_now_ms() + 1)
	testing.expect_value(t, len(pty_test_queued(id)), 1)
	_, reported := agent_notified_test_pending(id)
	testing.expect(t, !reported, "a failed delivery is not reported")
	// Typing succeeds: committed, then reported once with the bridge time.
	pty_test_send_fail = false
	before := bridge_now_unix_ms()
	bridge_task_notice_tick(bridge_runtime_now_ms() + 10_000)
	testing.expect_value(t, len(pty_test_queued(id)), 0)
	frame, ok := agent_notified_test_pending(id)
	testing.expect(t, ok, "the typed notice is reported")
	testing.expect(t, frame.typed_at_ms >= before && frame.typed_at_ms <= bridge_now_unix_ms())
	testing.expect_value(t, frame.type, contracts.AGENT_NOTICE_TYPED_FRAME)
	_, again := agent_notified_test_pending(id)
	testing.expect(t, !again, "taken once")
}

@(test)
pty_typed_task_notice_is_not_reported :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	env := pty_test_begin("pty-notified-task"); defer pty_test_end(&env)
	bridge_agent_notified_reset(); defer bridge_agent_notified_reset()
	id := "inst_pty_notified_task"
	defer bridge_runtime_set_status(id, "stopped", "idle")
	pty_test_forget_typed(id)
	pty_test_activity(id, "idle", "pane_diff")
	testing.expect(t, bridge_runtime_submit(id, {kind = .Notification, id = "cmd_1", text = "Shell run sh_1 exited.", origin = "shell_run"}))
	bridge_task_notice_tick(bridge_runtime_now_ms() + BRIDGE_TASK_NOTICE_WINDOW_MS + 1)
	testing.expect_value(t, pty_test_trace(), `"Shell run sh_1 exited." Enter Enter`)
	_, reported := agent_notified_test_pending(id)
	testing.expect(t, !reported)
}

@(test)
agent_notified_drain_sends_latest_and_keeps_it_on_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	bridge_agent_notified_reset(); defer bridge_agent_notified_reset()
	defer { for f in agent_notified_test_frames do delete(f); clear(&agent_notified_test_frames); agent_notified_test_fail = false }
	typed := []Bridge_Inbox_Typed{{id = "msg_1", key = PTY_UNREAD_NOTICE_KEY, kind = BRIDGE_NOTICE_USER_MESSAGE}}
	bridge_agent_notified_note("inst_drain", typed)
	agent_notified_test_fail = true
	bridge_agent_notified_drain_via(nil, agent_notified_test_send)
	testing.expect_value(t, len(agent_notified_test_frames), 0)
	agent_notified_test_fail = false
	bridge_agent_notified_drain_via(nil, agent_notified_test_send)
	if !testing.expect_value(t, len(agent_notified_test_frames), 1) do return
	frame: contracts.Agent_Notice_Typed_Frame
	testing.expect(t, json.unmarshal_string(agent_notified_test_frames[0], &frame, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, frame.type, "agent_notice_typed")
	testing.expect_value(t, frame.agent_instance_id, "inst_drain")
	bridge_agent_notified_drain_via(nil, agent_notified_test_send)
	testing.expect_value(t, len(agent_notified_test_frames), 1) // nothing left
}
