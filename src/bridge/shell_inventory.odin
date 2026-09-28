package main

// REQ-SHELL-10: the FULL SESSION INVENTORY the bridge sends on every hub-WS
// (re)connect, and the safety net half of the convergence protocol.
//
// WHY A SNAPSHOT RATHER THAN MORE EVENTS. Convergence used to be pursued
// leak-by-leak: the reconcile pass covers reconnect, the REQ-SHELL-4 outbox covers
// disconnect, REQ-SHELL-3 covers kill intent. Each is sound, but the set is only as
// complete as our list of failure modes. An inventory needs no such list: it states
// the bridge's WHOLE truth, so the hub can diff against it and converge whatever any
// event path lost, including modes nobody has thought of yet.
//
// RELATIONSHIP TO THE EXIT OUTBOX (REQ-SHELL-4) — the outbox STAYS, and the two
// cannot disagree. The outbox is the FAST path: an exit is reported promptly rather
// than waiting for a reconnect. This is the SLOW, COMPLETE one. They cannot produce
// conflicting statuses for three reasons, in order of how much weight they carry:
//
//  1. DISJOINT BY CONSTRUCTION. The inventory is built AFTER the reconcile pass that
//     enqueues that pass's exits, and it lists only LIVE sessions. A session the
//     bridge has just concluded is dead is already terminal in the map and is
//     therefore ABSENT from the inventory. Neither path ever describes one session
//     as both live and dead.
//  2. ORDERED ON THE WIRE. The drain below runs immediately after
//     bridge_shell_exited_drain_outgoing on one ordered connection, so the fast
//     path's exits precede this snapshot.
//  3. GUARDED ON APPLY, which is the actual correctness argument. Ordering is an
//     optimisation, NOT the correctness argument — (2) buys promptness and nothing
//     more, because the outbox explicitly makes no cross-restart ordering promise. Outbox exits are OBSERVED (they carry exit_code_set; the bridge
//     waited on the child) and win permanently. Statuses the hub's diff synthesizes
//     from a missing inventory entry are NOT observed and yield to a later observed
//     exit — see domain.shell_session_terminal_is_observed, which already encodes
//     exactly this rule for REQ-SHELL-4 and REQ-SHELL-14. So a late real exit
//     corrects a diff's guess, and a diff's guess can never overwrite a real exit.
//
// NOT DISK-BACKED, deliberately, and this is the one place it differs from the
// outbox it sits beside. An exit is a FACT: it stays true however long delivery
// takes, so losing one strands a session forever and it must survive a restart. An
// inventory is a SNAPSHOT OF NOW: an undelivered one is not valuable later, it is
// merely stale, and the next reconnect regenerates a strictly better one. Persisting
// it would buy nothing and could only ever deliver an out-of-date truth.

import "core:strconv"
import "core:strings"
import "core:sync"
import ws "odin_test:lib/ws"

// BRIDGE_SHELL_INVENTORY_MAX_ENTRIES bounds one inventory (work item 5: a bridge
// with many sessions must not produce an unbounded burst on reconnect).
//
// A BACKSTOP, not a budget. Live sessions are already capped by REQ-SHELL-2 §11 at
// 32 runs per agent instance and 16 servers per chain, so a bridge reaching this
// number has a bug — which is what the truncation flag exists to surface rather than
// hide.
//
// TRUNCATION IS NOT SILENT, and the hub must not treat a truncated inventory as a
// complete one. A truncated list cannot prove a session's ABSENCE, so the hub's
// "live here, missing there -> it died" branch would conclude death from nothing
// more than a full buffer. The frame therefore carries `truncated`, and
// shell_session_apply_inventory disables that one branch when it is set.
BRIDGE_SHELL_INVENTORY_MAX_ENTRIES :: 512

// bridge_shell_inventory_outgoing holds at most one pending inventory frame.
//
// A ONE-SLOT QUEUE, not a list, and for the same reason the store is not disk-backed:
// two queued inventories are not two facts to deliver, they are an old snapshot and a
// newer one. Keeping the older would send the hub a truth we already know is out of
// date, so a second enqueue REPLACES the first. Reconnect flapping therefore produces
// one frame per delivery opportunity rather than a backlog (work item 5).
@(private = "file")
_bridge_shell_inventory_pending: string
@(private = "file")
_bridge_shell_inventory_mu: sync.Mutex

// bridge_shell_inventory_enqueue queues a frame for the next drain, replacing and
// freeing any snapshot that has not gone out yet.
bridge_shell_inventory_enqueue :: proc(frame_json: string) {
	if strings.trim_space(frame_json) == "" do return
	sync.mutex_lock(&_bridge_shell_inventory_mu)
	defer sync.mutex_unlock(&_bridge_shell_inventory_mu)
	if _bridge_shell_inventory_pending != "" do delete(_bridge_shell_inventory_pending)
	_bridge_shell_inventory_pending = strings.clone(frame_json)
}

// bridge_shell_inventory_drain_outgoing sends the pending inventory, if any. Called
// from bridge_hub_runtime_loop right after bridge_shell_exited_drain_outgoing, so
// the fast path's exits are on the wire ahead of this snapshot.
//
// ON SEND FAILURE THE FRAME IS DROPPED, NOT RE-QUEUED — the opposite of the exit
// drain a few lines above it in the loop, and the difference is the point. A failed
// send means the connection is gone; by the time there is another one, this snapshot
// describes a bridge state that is potentially minutes old, while the reconnect
// itself will run a fresh reconcile and build a current one. Re-queueing would
// deliver the stale truth first and let the hub act on it.
bridge_shell_inventory_drain_outgoing :: proc(conn: ^ws.Connection) {
	frame: string
	sync.mutex_lock(&_bridge_shell_inventory_mu)
	frame = _bridge_shell_inventory_pending
	_bridge_shell_inventory_pending = ""
	sync.mutex_unlock(&_bridge_shell_inventory_mu)
	if frame == "" do return
	defer delete(frame)
	// bridge_hub_send chunks anything over the frame cap and the hub reassembles it,
	// so a large inventory needs no splitting of its own here.
	if !bridge_hub_send(conn, frame) do conn.connected = false
}

// bridge_shell_inventory_reset drops any pending frame (for tests).
bridge_shell_inventory_reset :: proc() {
	sync.mutex_lock(&_bridge_shell_inventory_mu)
	defer sync.mutex_unlock(&_bridge_shell_inventory_mu)
	if _bridge_shell_inventory_pending != "" do delete(_bridge_shell_inventory_pending)
	_bridge_shell_inventory_pending = ""
}

// bridge_shell_inventory_pending_frame returns the queued frame WITHOUT consuming it
// (for tests and diagnostics). The result is a clone the caller owns.
bridge_shell_inventory_pending_frame :: proc() -> (string, bool) {
	sync.mutex_lock(&_bridge_shell_inventory_mu)
	defer sync.mutex_unlock(&_bridge_shell_inventory_mu)
	if _bridge_shell_inventory_pending == "" do return "", false
	return strings.clone(_bridge_shell_inventory_pending), true
}

// bridge_shell_inventory_build renders the bridge's LIVE sessions as one
// shell_inventory frame. Caller owns the result.
//
// LIVE ONLY (Starting | Running), by bridge_shell_session_status_is_terminal — the
// bridge's own mirror of the hub's terminal table, so "still running" means the same
// thing on both sides of the wire. Including terminal sessions would defeat the
// diff's central rule: the hub reads absence as "this ended while we were away", and
// a list that also carried the dead would never let it conclude anything.
//
// EVERY SCOPE COLUMN IS CARRIED, not just the identifying ones, because an entry the
// hub has no row for must be ADOPTABLE: the hub validates it through
// domain.shell_session_validate_scope and can only do that with the whole set. A
// session the bridge cannot describe completely is one the hub will refuse rather
// than store as a row that names no scope.
bridge_shell_inventory_build :: proc(m: ^Bridge_Shell_Session_Map) -> string {
	sessions := bridge_shell_session_list_snapshot(m)
	defer bridge_shell_session_list_destroy(m, sessions)

	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_inventory\",\"sessions\":[")
	written := 0
	truncated := false
	for s in sessions {
		if bridge_shell_session_status_is_terminal(s.status) do continue
		if written >= BRIDGE_SHELL_INVENTORY_MAX_ENTRIES {
			truncated = true
			break
		}
		if written > 0 do strings.write_byte(&b, ',')
		bridge_shell_inventory_write_entry(&b, s)
		written += 1
	}
	strings.write_string(&b, "],\"truncated\":")
	strings.write_string(&b, truncated ? "true" : "false")
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// bridge_shell_inventory_write_entry renders one session. Field spellings match the
// session spec store (bridge_shell_session_save_spec) and the hub's column names, so
// the adopt path maps them across with no translation table to drift.
@(private = "file")
bridge_shell_inventory_write_entry :: proc(b: ^strings.Builder, s: Bridge_Shell_Session) {
	write_str :: proc(b: ^strings.Builder, key, value: string) {
		strings.write_byte(b, '"')
		strings.write_string(b, key)
		strings.write_string(b, "\":\"")
		bridge_local_write_json_string(b, value)
		strings.write_string(b, "\",")
	}
	write_int :: proc(b: ^strings.Builder, key: string, value: int, last := false) {
		strings.write_byte(b, '"')
		strings.write_string(b, key)
		strings.write_string(b, "\":")
		buf: [24]byte
		strings.write_string(b, strconv.write_int(buf[:], i64(value), 10))
		if !last do strings.write_byte(b, ',')
	}

	strings.write_byte(b, '{')
	write_str(b, "session_id", s.session_id)
	write_str(b, "kind", bridge_shell_session_kind_str(s.kind))
	write_str(b, "status", bridge_shell_session_status_str(s.status))
	write_str(b, "shell_id", s.shell_id)
	write_str(b, "started_at", s.started_at)
	write_str(b, "label", s.label)
	write_str(b, "cmd", s.cmd)
	write_str(b, "cwd", s.cwd)
	write_str(b, "owner_user_id", s.owner_user_id)
	write_str(b, "project_id", s.project_id)
	write_str(b, "chain_id", s.chain_id)
	write_str(b, "agent_instance_id", s.agent_instance_id)
	strings.write_string(b, "\"background\":")
	strings.write_string(b, s.background ? "true" : "false")
	strings.write_byte(b, ',')
	write_int(b, "pid", s.pid)
	write_int(b, "server_port", s.server_port)
	write_int(b, "run_seq", s.run_seq, last = true)
	strings.write_byte(b, '}')
}
