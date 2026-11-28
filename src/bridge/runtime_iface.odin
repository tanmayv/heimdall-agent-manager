package main

import "base:runtime"
import "core:encoding/json"
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

Agent_Runtime :: struct {
	transport:       string,
	submit:          proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool,
	send_now:        proc(instance: string, req: Runtime_Send_Now) -> bool,
	inputs_read:     proc(instance: string, ids: []string) -> bool,
	interrupt:       proc(instance: string) -> bool,
	// Ends the runtime's turn handling before the process is closed (lifecycle
	// owns the process itself). nil: nothing to stop.
	stop:            proc(instance: string),
	// Releases transport ownership before a relaunch. nil: nothing owned.
	release:         proc(instance: string),
	child_exited:    proc(instance: string),
	can_steer:       proc(instance: string) -> bool,
	usage:           proc(instance: string) -> (contracts.Ext_Usage, bool),
	// Raw viewer keystrokes. nil: the bytes go to the agent's terminal as typed.
	raw_input:       proc(instance: string, data: []byte) -> bool,
	// The durable notice queue (task_notice_queue.odin) asks whether a batch can
	// start a turn now, then hands it over as one text.
	notices_ready:   proc(instance: string) -> bool,
	deliver_notices: proc(instance, text: string) -> bool,
}

// The registered runtimes, keyed by the transport recorded for an instance.
// A test may register a fake runtime here.
bridge_agent_runtimes: [dynamic]^Agent_Runtime
bridge_agent_runtimes_mu: sync.Mutex

bridge_agent_runtime_list :: proc() -> []^Agent_Runtime {
	sync.mutex_lock(&bridge_agent_runtimes_mu)
	defer sync.mutex_unlock(&bridge_agent_runtimes_mu)
	if len(bridge_agent_runtimes) == 0 {
		bridge_agent_runtimes = make([dynamic]^Agent_Runtime, runtime.heap_allocator())
		append(&bridge_agent_runtimes, &pty_agent_runtime, &acp_agent_runtime)
	}
	return bridge_agent_runtimes[:]
}

// bridge_runtime_transport returns the transport recorded for an instance
// (temp-allocated; "" when unknown).
bridge_runtime_transport :: proc(instance: string) -> string {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for inst in bridge_runtime_instances {
		if inst.agent_instance_id == instance do return strings.clone(inst.runtime_transport, context.temp_allocator)
	}
	return ""
}

// bridge_runtime_for selects the runtime that owns an instance. Unknown or
// unrecorded transports are PTY, the only launch path without a runtime owner.
bridge_runtime_for :: proc(instance: string) -> ^Agent_Runtime {
	transport := bridge_runtime_transport(instance)
	for rt in bridge_agent_runtime_list() do if rt.transport == transport do return rt
	return &pty_agent_runtime
}

// bridge_runtime_effective_mode applies the shared delivery policy:
// notifications always queue (CONTRACT-07), and steer is used only when the
// runtime reports it can steer; otherwise the input is sent now, which
// interrupts once and starts a turn with it (CONTRACT-06/15).
bridge_runtime_effective_mode :: proc(rt: ^Agent_Runtime, instance: string, kind: Runtime_Input_Kind, mode: Runtime_Mode) -> Runtime_Mode {
	if kind == .Notification do return .Queue
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
	return rt.interrupt != nil && rt.interrupt(instance)
}

bridge_runtime_stop :: proc(instance: string) {
	rt := bridge_runtime_for(instance)
	if rt.stop != nil do rt.stop(instance)
}

bridge_runtime_release :: proc(instance: string) {
	rt := bridge_runtime_for(instance)
	if rt.release != nil do rt.release(instance)
}

bridge_runtime_child_exited :: proc(instance: string) {
	rt := bridge_runtime_for(instance)
	if rt.child_exited != nil do rt.child_exited(instance)
}

bridge_runtime_can_steer :: proc(instance: string) -> bool {
	rt := bridge_runtime_for(instance)
	return rt.can_steer != nil && rt.can_steer(instance)
}

bridge_runtime_usage :: proc(instance: string) -> (contracts.Ext_Usage, bool) {
	rt := bridge_runtime_for(instance)
	if rt.usage == nil do return {}, false
	return rt.usage(instance)
}

// ---- events -----------------------------------------------------------------

// The sink may be called with bridge_runtime_mutex held: it must only take
// leaf locks. Tests replace it to observe events.
bridge_runtime_event_sink: proc(instance: string, event: Runtime_Event) = bridge_runtime_event_default

bridge_runtime_emit :: proc(instance: string, event: Runtime_Event) {
	if bridge_runtime_event_sink != nil && instance != "" do bridge_runtime_event_sink(instance, event)
}

// A trusted idle drains the durable queue at once instead of at its retry tick.
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
			ok = rt.send_now != nil && rt.send_now(cmd.agent_instance_id, {launch_epoch = cmd.launch_epoch, batch_id = cmd.batch_id, attempt = cmd.attempt, message_ids = cmd.message_ids})
		}
	} else {
		cmd: contracts.ACP_Inputs_Read_Command
		if json.unmarshal_string(text, &cmd, allocator = context.temp_allocator) == nil {
			rt := bridge_runtime_for(cmd.agent_instance_id)
			ok = rt.inputs_read != nil && rt.inputs_read(cmd.agent_instance_id, cmd.message_ids)
		}
	}
	if command_id == "" do return
	final := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error("acp_runtime_unavailable", "the agent runtime did not accept the command"), "")
	defer delete(final)
	if ok do bridge_runtime_cache_command(command_id, final)
	_ = bridge_hub_send(conn, final)
}
