package main

import "core:time"

// PTY implementation of the turn-based runtime interface (runtime_iface.odin):
// inputs are typed into the provider CLI's terminal through ham-pty-host.

pty_agent_runtime := Agent_Runtime{
	transport       = "pty",
	submit          = pty_agent_submit,
	interrupt       = pty_agent_interrupt,
	usage           = bridge_ext_usage_snapshot,
	notices_ready   = pty_agent_notices_ready,
	deliver_notices = pty_agent_deliver_notices,
}

pty_agent_submit :: proc(instance: string, input: Runtime_Input, mode: Runtime_Mode) -> bool {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	if input.kind == .User_Message {
		esc := pty_host_encode_key(instance, .Esc)
		defer delete(esc)
		if !bridge_pty_host_send_oneway(socket, esc) do return false
		time.sleep(300 * time.Millisecond)
	}
	return bridge_pty_host_deliver_line(socket, instance, input.text)
}

pty_agent_interrupt :: proc(instance: string) -> bool {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	esc := pty_host_encode_key(instance, .Esc)
	defer delete(esc)
	return bridge_pty_host_send_oneway(socket, esc)
}

pty_agent_notices_ready :: proc(instance: string) -> bool {
	return true
}

pty_agent_deliver_notices :: proc(instance, text: string) -> bool {
	socket, ok := bridge_task_notice_daemon()
	if !ok do return false
	return bridge_task_notice_pty_deliver(socket, instance, "", "", text, "", false)
}
