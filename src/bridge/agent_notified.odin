package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// agent_notice_typed reports (contracts.Agent_Notice_Typed_Frame): after the
// shared inbox drain committed a typed batch that carried the unread-messages
// notice, the agent was pointed at its unread messages up to the hub message
// that notice entry stands for (the coalesced entry carries the newest id,
// bridge_inbox_admit). The drain only notes it here (never I/O under the inbox
// lock); the hub-runtime loop sends the newest id per instance and keeps it
// pending while a send fails. Pending reports live in memory only: a bridge
// restart loses them, and the Hub's tray stays "waiting" until the next
// typed notice reports again. Reporting never changes delivery.

@(private = "file")
bridge_agent_notified_mu: sync.Mutex
@(private = "file")
bridge_agent_notified_pending: map[string]string // instance -> last message id (heap)

BRIDGE_AGENT_NOTIFIED_MAX :: 4096

// bridge_agent_notified_note records a committed typed batch (call after the
// commit, in commit order; with or without bridge_inbox_mu held). Only the
// unread-messages notice is reported; task notices and shell exits are not.
bridge_agent_notified_note :: proc(instance: string, typed: []Bridge_Inbox_Typed) {
	if instance == "" do return
	last := ""
	for t in typed do if t.kind == BRIDGE_NOTICE_USER_MESSAGE && t.key == PTY_UNREAD_NOTICE_KEY && t.id != "" do last = t.id
	if last != "" do bridge_agent_notified_put(instance, last)
}

// A later note for the same instance replaces the pending one: notes arrive in
// commit order, and the Hub ignores any id that is not later anyway.
@(private = "file")
bridge_agent_notified_put :: proc(instance, message_id: string, keep_newer := false) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_agent_notified_mu); defer sync.mutex_unlock(&bridge_agent_notified_mu)
	if bridge_agent_notified_pending == nil do bridge_agent_notified_pending = make(map[string]string, allocator = heap)
	if previous, exists := bridge_agent_notified_pending[instance]; exists {
		if keep_newer do return // a failed send never overwrites a newer note
		delete(previous, heap)
		bridge_agent_notified_pending[instance] = strings.clone(message_id, heap)
		return
	}
	if len(bridge_agent_notified_pending) >= BRIDGE_AGENT_NOTIFIED_MAX do return
	bridge_agent_notified_pending[strings.clone(instance, heap)] = strings.clone(message_id, heap)
}

// bridge_agent_notified_take removes and returns every pending report (temp).
bridge_agent_notified_take :: proc() -> []contracts.Agent_Notice_Typed_Frame {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_agent_notified_mu); defer sync.mutex_unlock(&bridge_agent_notified_mu)
	frames := make([dynamic]contracts.Agent_Notice_Typed_Frame, context.temp_allocator)
	for instance, message_id in bridge_agent_notified_pending {
		append(&frames, contracts.Agent_Notice_Typed_Frame{type = contracts.AGENT_NOTICE_TYPED_FRAME, agent_instance_id = strings.clone(instance, context.temp_allocator), last_message_id = strings.clone(message_id, context.temp_allocator)})
		delete(instance, heap); delete(message_id, heap)
	}
	clear(&bridge_agent_notified_pending)
	return frames[:]
}

// bridge_agent_notified_drain sends the pending reports on the hub-runtime
// socket; a failed send keeps the rest pending for the next connection.
bridge_agent_notified_drain :: proc(conn: ^ws.Connection) {
	bridge_agent_notified_drain_via(conn, bridge_hub_send)
}

bridge_agent_notified_drain_via :: proc(conn: ^ws.Connection, send: proc(conn: ^ws.Connection, text: string) -> bool) {
	frames := bridge_agent_notified_take()
	for frame, i in frames {
		data, err := json.marshal(frame, allocator = context.temp_allocator)
		if err != nil do continue
		if !send(conn, string(data)) {
			for rest in frames[i:] do bridge_agent_notified_put(rest.agent_instance_id, rest.last_message_id, keep_newer = true)
			return
		}
	}
}

// bridge_agent_notified_reset drops pending reports (tests).
bridge_agent_notified_reset :: proc() {
	_ = bridge_agent_notified_take()
}
