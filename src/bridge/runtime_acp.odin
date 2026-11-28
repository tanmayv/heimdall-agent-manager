package main

import "core:encoding/json"
import "core:strings"
import "core:sync"

// ACP implementation of the turn-based runtime interface (runtime_iface.odin).
// It wraps the ACP runtime dispatcher: its durable inbox (acp_inbox.odin), the
// conversation-level Send now batch (acp_delivery.odin) and the protocol
// driver's steering readiness and usage (acp_driver.odin).

// The inbox's delivery target for this transport (task_notice_queue.odin).
acp_inbox_target := Bridge_Inbox_Target{transport = "acp", ready = acp_agent_notices_ready, deliver = acp_agent_deliver_notices}

acp_agent_runtime := Agent_Runtime{
	transport       = "acp",
	submit          = acp_agent_submit,
	send_now        = acp_agent_send_now,
	inputs_read     = acp_agent_inputs_read,
	interrupt       = acp_agent_interrupt,
	stop            = acp_agent_stop,
	release         = acp_runtime_detach,
	child_exited    = acp_agent_child_exited,
	can_steer       = acp_agent_can_steer,
	usage           = bridge_ext_usage_snapshot,
	raw_input       = acp_agent_raw_input,
}

// A queued user input waits for the next turn; the inbox never steers it.
ACP_NEXT_TURN_KIND :: "append_next_turn"

acp_agent_submit :: proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool {
	// The ACP runtime reads hub conversation messages itself; their delivery
	// mode is the hub's (queued rows, Send now batches).
	if input.hub_message do return acp_chat_notify(instance)
	text := bridge_decrypt_embedded_vault_tokens(input.text)
	defer delete(text)
	if input.kind == .Notification {
		return acp_runtime_deliver(instance, text, input.id, acp_inbox_lane(input.origin), input.key, input.origin)
	}
	switch mode {
	case .Steer:
		return acp_runtime_deliver(instance, text, input.id)
	case .Send_Now:
		// Idle runtimes refuse the cancel; the input then simply starts a turn.
		_ = acp_runtime_command(instance, "interrupt")
		return acp_runtime_deliver(instance, text, input.id, kind = ACP_NEXT_TURN_KIND)
	case .Queue:
		return acp_runtime_deliver(instance, text, input.id, kind = ACP_NEXT_TURN_KIND)
	}
	return false
}

acp_agent_send_now :: proc(instance: string, req: Runtime_Send_Now) -> bool {
	if !acp_runtime_owned(instance) do return false
	raw := acp_event_json(ACP_Send_Now_Request{launch_epoch = req.launch_epoch, batch_id = req.batch_id, attempt = req.attempt, message_ids = req.message_ids})
	return acp_runtime_command(instance, strings.concatenate({"send_now_batch:", raw}, context.temp_allocator))
}

acp_agent_inputs_read :: proc(instance: string, ids: []string) -> bool {
	if !acp_runtime_owned(instance) do return false
	return acp_runtime_command(instance, strings.concatenate({"inputs_read:", acp_event_json(ids)}, context.temp_allocator))
}

acp_agent_interrupt :: proc(instance: string) -> bool {
	return acp_runtime_command(instance, "interrupt")
}

acp_agent_stop :: proc(instance: string) {
	acp_runtime_command(instance, "stop")
	acp_runtime_detach(instance)
}

acp_agent_child_exited :: proc(instance: string) {
	acp_runtime_command(instance, "exit")
}

acp_agent_can_steer :: proc(instance: string) -> bool {
	return acp_runtime_command(instance, "can_steer")
}

// Viewer keystrokes: Esc / Ctrl-C interrupt the turn, typed text is an explicit
// user steer.
acp_agent_raw_input :: proc(instance: string, data: []byte) -> bool {
	if string(data) == "\x1b" || string(data) == "\x03" do return acp_runtime_command(instance, "interrupt")
	return acp_runtime_deliver(instance, string(data))
}

acp_agent_notices_ready :: proc(instance: string) -> bool {
	return acp_runtime_command(instance, "task_notices_ready")
}

acp_agent_deliver_notices :: proc(instance, text: string) -> bool {
	raw, err := json.marshal(ACP_Task_Notice_Input{text = text}, allocator = context.temp_allocator)
	if err != nil do return false
	return acp_runtime_command(instance, strings.concatenate({"task_notices:", string(raw)}, context.temp_allocator))
}

// bridge_runtime_is_acp reports whether the ACP runtime owns an instance.
// Shared code selects a runtime with bridge_runtime_for instead; the bot
// delivery path (out of scope for the runtime refactor) still asks directly.
bridge_runtime_is_acp :: proc(instance: string) -> bool {
	sync.mutex_lock(&bridge_runtime_mutex); defer sync.mutex_unlock(&bridge_runtime_mutex)
	for inst in bridge_runtime_instances do if inst.agent_instance_id == instance do return inst.runtime_transport == acp_agent_runtime.transport
	return false
}
