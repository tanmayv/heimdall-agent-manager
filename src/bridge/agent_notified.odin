package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// agent_notice_typed reports (contracts.Agent_Notice_Typed_Frame): after the
// shared inbox drain committed a typed batch that carried a user-message notice,
// the agent was pointed at its unread messages. The drain only notes it here
// (never I/O under the inbox lock); the hub-runtime loop sends the latest time
// per instance and keeps it pending while the socket is down.

@(private = "file")
bridge_agent_notified_mu: sync.Mutex
@(private = "file")
bridge_agent_notified_pending: map[string]i64 // instance -> typed_at_ms (heap)

BRIDGE_AGENT_NOTIFIED_MAX :: 4096

// bridge_agent_notified_note records a committed typed batch (call after the
// commit, with or without bridge_inbox_mu held). Batches without a user-message
// notice (task notices, shell exits) are not reported.
bridge_agent_notified_note :: proc(instance: string, typed: []Bridge_Inbox_Typed) {
	has_user := false
	for t in typed do if t.kind == BRIDGE_NOTICE_USER_MESSAGE { has_user = true; break }
	if !has_user || instance == "" do return
	bridge_agent_notified_put(instance, bridge_now_unix_ms())
}

@(private = "file")
bridge_agent_notified_put :: proc(instance: string, at: i64) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_agent_notified_mu); defer sync.mutex_unlock(&bridge_agent_notified_mu)
	if bridge_agent_notified_pending == nil do bridge_agent_notified_pending = make(map[string]i64, allocator = heap)
	if previous, exists := bridge_agent_notified_pending[instance]; exists {
		if at > previous do bridge_agent_notified_pending[instance] = at
		return
	}
	if len(bridge_agent_notified_pending) >= BRIDGE_AGENT_NOTIFIED_MAX do return
	bridge_agent_notified_pending[strings.clone(instance, heap)] = at
}

// bridge_agent_notified_take removes and returns every pending report (temp).
bridge_agent_notified_take :: proc() -> []contracts.Agent_Notice_Typed_Frame {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_agent_notified_mu); defer sync.mutex_unlock(&bridge_agent_notified_mu)
	frames := make([dynamic]contracts.Agent_Notice_Typed_Frame, context.temp_allocator)
	for instance, at in bridge_agent_notified_pending {
		append(&frames, contracts.Agent_Notice_Typed_Frame{type = contracts.AGENT_NOTICE_TYPED_FRAME, agent_instance_id = strings.clone(instance, context.temp_allocator), typed_at_ms = at})
		delete(instance, heap)
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
			for rest in frames[i:] do bridge_agent_notified_put(rest.agent_instance_id, rest.typed_at_ms)
			return
		}
	}
}

// bridge_agent_notified_reset drops pending reports (tests).
bridge_agent_notified_reset :: proc() {
	_ = bridge_agent_notified_take()
}
