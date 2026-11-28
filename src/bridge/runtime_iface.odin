package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// One turn-based runtime interface for agents (G8, REQ R5).
//
// An agent runtime takes user messages and notifications as inputs and runs
// turns. Input while the agent is busy is queued by default; steer (inject into
// the running turn) and send now (interrupt, then start) are explicit modes,
// and notifications never interrupt (CONTRACT-05/06/07). Shared bridge code
// talks to an agent only through this interface; each transport (ACP, PTY)
// implements it in its own files (runtime_acp.odin, runtime_pty.odin), and
// differences between transports are adapter methods or descriptor data, never
// a transport compare in shared code (G9).

Runtime_Input_Kind :: enum u8 { User_Message, Notification }

// Queue: strict FIFO, delivered only at trusted idle, never interrupts a turn.
// Steer: inject into the running turn (only when the runtime can steer).
// Send_Now: interrupt the running turn once, then start a turn with the input.
Runtime_Mode :: enum u8 { Queue, Steer, Send_Now }

// All strings are borrowed for the duration of the call.
Runtime_Input :: struct {
	kind:        Runtime_Input_Kind,
	id:          string, // stable admission identity (hub message/command id); "" = generated
	text:        string, // what the agent reads
	key:         string, // coalescing key (task id, shell session, "title")
	origin:      string, // why it was sent (shell_run, title_nudge, a task state, ...)
	// The body lives in the hub conversation and text is only the notice that
	// points at it; a runtime that reads the conversation itself fetches it.
	hub_message: bool,
	// A notification that must get a turn of its own at the next idle (task
	// and lease wakes), never only ride along as context.
	wake:        bool,
	// Deliver only while the hub task is still in expected_state (checked at
	// delivery, task_notice_queue.odin). Empty: always relevant.
	task, expected_state: string,
}

// Turn lifecycle events every runtime reports through bridge_runtime_emit.
Runtime_Event :: enum u8 { Turn_Started, Turn_Output, Turn_Ended, Idle }

// A user's Send now over queued unread inputs (CONTRACT-06). The batch is the
// FIFO subset of message_ids still queued; empty is a no-op; a repeated
// batch_id/attempt is idempotent.
Runtime_Send_Now :: struct {
	launch_epoch, batch_id: string,
	attempt:                i64,
	message_ids:            []string,
}

// The interface proper is submit / send_now / interrupt / stop / can_steer /
// usage. The other methods each have a stated need. The durable inbox is not
// part of it: every runtime admits its queued input to the one bridge inbox
// (bridge_inbox.odin) and drains it at a trusted idle.
Agent_Runtime :: struct {
	transport:    string,
	submit:       proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool,
	send_now:     proc(instance: string, req: Runtime_Send_Now) -> bool,
	interrupt:    proc(instance: string) -> bool,
	// Ends the runtime's turn handling before lifecycle closes the process.
	// nil: nothing to stop.
	stop:         proc(instance: string),
	can_steer:    proc(instance: string) -> bool,
	usage:        proc(instance: string) -> (contracts.Ext_Usage, bool),
	// Why: the hub reports inputs the user has read; their queued notices must
	// not be delivered afterwards (acp_inputs_read).
	inputs_read:  proc(instance: string, ids: []string) -> bool,
	// Why: a relaunch must join the old runtime owner (an ACP dispatcher holds
	// the pipe) without sending stop into the session being replaced.
	release:      proc(instance: string),
	// Why: ham-pty-host reports the child's exit; a runtime with a pending turn
	// must fail it instead of waiting forever.
	child_exited: proc(instance: string),
	// Why: the UI terminal pane sends keystrokes; a runtime without a terminal
	// (ACP) maps them to interrupt / steer. nil: the bytes are typed as is.
	raw_input:    proc(instance: string, data: []byte) -> bool,
}

// The runtimes, keyed by the transport recorded for an instance. Built per
// call: no mutable registry is shared between threads.
bridge_agent_runtime_list :: proc() -> [2]^Agent_Runtime {
	return {&pty_agent_runtime, &acp_agent_runtime}
}

// bridge_runtime_transport returns the transport recorded for an instance
// (temp-allocated; "" when none is recorded) and whether the instance is known.
bridge_runtime_transport :: proc(instance: string) -> (transport: string, known: bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for inst in bridge_runtime_instances {
		if inst.agent_instance_id == instance do return strings.clone(inst.runtime_transport, context.temp_allocator), true
	}
	return "", false
}

// bridge_runtime_lookup finds the runtime for a transport; nil when none matches.
bridge_runtime_lookup :: proc(runtimes: []^Agent_Runtime, transport: string) -> ^Agent_Runtime {
	if transport == "" do return nil
	for rt in runtimes do if rt != nil && rt.transport == transport do return rt
	return nil
}

// bridge_runtime_owner selects the runtime that owns an instance, or nil when
// the instance is unknown or has no recognised transport recorded. There is
// no default transport: a caller that gets nil reports the input as not
// delivered instead of typing it into a terminal that may not exist.
bridge_runtime_owner :: proc(instance: string) -> ^Agent_Runtime {
	transport, _ := bridge_runtime_transport(instance)
	list := bridge_agent_runtime_list()
	return bridge_runtime_lookup(list[:], transport)
}

// bridge_runtime_for is bridge_runtime_owner for delivery paths: a miss is
// logged, so an input that cannot be routed is visible, never silently dropped.
bridge_runtime_for :: proc(instance: string) -> ^Agent_Runtime {
	rt := bridge_runtime_owner(instance)
	if rt == nil {
		transport, known := bridge_runtime_transport(instance)
		fmt.eprintfln("bridge runtime: no agent runtime for instance=%q known=%t transport=%q; input not delivered", instance, known, transport)
	}
	return rt
}

// bridge_runtime_effective_mode applies the shared delivery policy:
// notifications always queue (CONTRACT-07), and steer is used only when the
// runtime reports it can steer; otherwise the input is sent now, which
// interrupts once and starts a turn with it (CONTRACT-06/15).
bridge_runtime_effective_mode :: proc(rt: ^Agent_Runtime, instance: string, kind: Runtime_Input_Kind, mode: Runtime_Mode) -> Runtime_Mode {
	if kind == .Notification || rt == nil do return .Queue
	if mode == .Steer && (rt.can_steer == nil || !rt.can_steer(instance)) do return .Send_Now
	return mode
}

bridge_runtime_submit_to :: proc(rt: ^Agent_Runtime, instance: string, input: Runtime_Input, mode: Runtime_Mode = .Queue) -> bool {
	if rt == nil || rt.submit == nil || strings.trim_space(instance) == "" do return false
	return rt.submit(instance, input, bridge_runtime_effective_mode(rt, instance, input.kind, mode))
}

bridge_runtime_submit :: proc(instance: string, input: Runtime_Input, mode: Runtime_Mode = .Queue) -> bool {
	return bridge_runtime_submit_to(bridge_runtime_for(instance), instance, input, mode)
}

// bridge_runtime_notify admits a notification, or wakes a local agent that no
// runtime here can accept it for (it reads its notices on boot).
bridge_runtime_notify :: proc(instance: string, input: Runtime_Input) -> bool {
	if bridge_runtime_submit(instance, input, .Queue) do return true
	return bridge_task_status_notify_wake_local(instance)
}

bridge_runtime_interrupt :: proc(instance: string) -> bool {
	rt := bridge_runtime_for(instance)
	return rt != nil && rt.interrupt != nil && rt.interrupt(instance)
}

bridge_runtime_stop :: proc(instance: string) {
	rt := bridge_runtime_owner(instance)
	if rt != nil && rt.stop != nil do rt.stop(instance)
}

bridge_runtime_release :: proc(instance: string) {
	rt := bridge_runtime_owner(instance)
	if rt != nil && rt.release != nil do rt.release(instance)
}

bridge_runtime_child_exited :: proc(instance: string) {
	rt := bridge_runtime_owner(instance)
	if rt != nil && rt.child_exited != nil do rt.child_exited(instance)
}

bridge_runtime_can_steer :: proc(instance: string) -> bool {
	rt := bridge_runtime_owner(instance)
	return rt != nil && rt.can_steer != nil && rt.can_steer(instance)
}

bridge_runtime_usage :: proc(instance: string) -> (contracts.Ext_Usage, bool) {
	rt := bridge_runtime_owner(instance)
	if rt == nil || rt.usage == nil do return {}, false
	return rt.usage(instance)
}

// ---- events -----------------------------------------------------------------

// The sink may be called with bridge_runtime_mutex held: it must only take
// leaf locks. Tests replace it to observe events.
bridge_runtime_event_sink: proc(instance: string, event: Runtime_Event) = bridge_runtime_event_default

bridge_runtime_emit :: proc(instance: string, event: Runtime_Event) {
	if bridge_runtime_event_sink != nil && instance != "" do bridge_runtime_event_sink(instance, event)
}

// A trusted idle ends the inbox collection window at once (task_notice_queue.odin).
bridge_runtime_event_default :: proc(instance: string, event: Runtime_Event) {
	if event == .Idle do bridge_task_notice_kick(instance)
}

// bridge_runtime_emit_activity maps an accepted activity transition to turn
// events; every transport's activity (ACP results, hooks, pane diff) arrives
// through the same arbitrated status.
bridge_runtime_emit_activity :: proc(instance, previous, activity: string) {
	if previous == activity do return
	switch activity {
	case "active":
		bridge_runtime_emit(instance, .Turn_Started)
	case "idle":
		if previous == "active" do bridge_runtime_emit(instance, .Turn_Ended)
		bridge_runtime_emit(instance, .Idle)
	}
}

// ---- hub delivery commands ---------------------------------------------------

// Hub runtime commands for user input delivery. The batch command id is
// attempt-specific, and only a success is cached, so neither a duplicate frame
// re-executes nor a cached failure blocks an explicit retry. The runtime
// re-validates the batch regardless.
bridge_runtime_delivery_command :: proc(conn: ^ws.Connection, type, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	defer delete(command_id)
	if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return }
	ok := false
	if type == contracts.ACP_SEND_NOW_BATCH_COMMAND {
		cmd: contracts.ACP_Send_Now_Batch_Command
		if json.unmarshal_string(text, &cmd, allocator = context.temp_allocator) == nil {
			rt := bridge_runtime_for(cmd.agent_instance_id)
			ok = rt != nil && rt.send_now != nil && rt.send_now(cmd.agent_instance_id, {launch_epoch = cmd.launch_epoch, batch_id = cmd.batch_id, attempt = cmd.attempt, message_ids = cmd.message_ids})
		}
	} else {
		cmd: contracts.ACP_Inputs_Read_Command
		if json.unmarshal_string(text, &cmd, allocator = context.temp_allocator) == nil {
			rt := bridge_runtime_for(cmd.agent_instance_id)
			ok = rt != nil && rt.inputs_read != nil && rt.inputs_read(cmd.agent_instance_id, cmd.message_ids)
		}
	}
	if command_id == "" do return
	final := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error("acp_runtime_unavailable", "the agent runtime did not accept the command"), "")
	defer delete(final)
	if ok do bridge_runtime_cache_command(command_id, final)
	_ = bridge_hub_send(conn, final)
}
