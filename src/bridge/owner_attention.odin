package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import owner "odin_test:lib/owner_local"
import ws "odin_test:lib/ws"

// Owner-chain attention (design B, user 18:40Z): the tasks of chains this
// Bridge owns that need the user (owner.user_attention_list: blocked on the
// user/human or agent_not_running, review awaiting the user's approval). The
// Hub keeps them in memory only and merges them into its Needs-attention deck
// (hub agent owner_attention.odin), so the Bridge sends its FULL snapshot on
// every Hub connect and heartbeat, and whenever it changes (checked every
// BRIDGE_OWNER_ATTENTION_POLL). Ids and flags only, never task content.

BRIDGE_OWNER_ATTENTION_POLL :: 2 * time.Second

// Hub-loop state (only the Hub runtime thread touches these).
@(private = "file")
bridge_owner_attention_last: string // heap; the last frame the Hub accepted from this connection
@(private = "file")
bridge_owner_attention_checked: time.Tick

// bridge_owner_attention_frame renders the owner_attention frame.
bridge_owner_attention_frame :: proc(items: []owner.User_Attention, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"type":"owner_attention","protocol_version":1,"items":[`)
	for it, i in items {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"chain_id":"`); bridge_runtime_write_json_string(&b, it.chain_id)
		strings.write_string(&b, `","task_id":"`); bridge_runtime_write_json_string(&b, it.task_id)
		strings.write_string(&b, `","attention":"`); bridge_runtime_write_json_string(&b, it.attention)
		strings.write_string(&b, `","badge":"`); bridge_runtime_write_json_string(&b, it.badge)
		strings.write_string(&b, `","state":"`); bridge_runtime_write_json_string(&b, it.state)
		strings.write_string(&b, `","attempt":"`); bridge_runtime_write_json_string(&b, it.attempt)
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// bridge_owner_attention_reset makes the next drain send the snapshot even if
// it is unchanged (Hub connect / heartbeat reconcile).
bridge_owner_attention_reset :: proc() {
	delete(bridge_owner_attention_last, runtime.default_allocator())
	bridge_owner_attention_last = ""
	bridge_owner_attention_checked = {}
}

// bridge_owner_attention_drain sends the snapshot when it changed. It never
// waits for the owner store: a busy store is checked again next turn.
bridge_owner_attention_drain :: proc(conn: ^ws.Connection) {
	if conn == nil || !conn.connected do return
	if bridge_owner_attention_checked != {} && time.tick_since(bridge_owner_attention_checked) < BRIDGE_OWNER_ATTENTION_POLL do return
	if !sync.mutex_try_lock(&bridge_owner_mutex) do return
	bridge_owner_attention_checked = time.tick_now()
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	frame := ""
	{
		defer sync.mutex_unlock(&bridge_owner_mutex)
		saved := context.allocator
		context.allocator = context.temp_allocator
		defer context.allocator = saved
		// Never create a store just for attention: no owner chains, nothing to send.
		if !bridge_owner_title_store_locked() do return
		items, ok := owner.user_attention_list(&bridge_owner_store)
		if !ok do return
		frame = bridge_owner_attention_frame(items, context.temp_allocator)
	}
	if frame == bridge_owner_attention_last do return
	if !bridge_hub_send(conn, frame) {
		conn.connected = false
		return
	}
	delete(bridge_owner_attention_last, runtime.default_allocator())
	bridge_owner_attention_last = strings.clone(frame, runtime.default_allocator())
}
