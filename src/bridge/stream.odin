package main

import "base:runtime"

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import os_random "odin_test:lib/os_random"
import ws "odin_test:lib/ws"

Stream_Live :: struct {
	reg: contracts.Stream_Registration,
	port: u16,
	profile: string,
	run_count: int,
	registered, accepted, attached: bool,
	share_waiters: int,
	link: string,
	register_reject: string,
	reason, source_stage: string,
	worker: ^thread.Thread,
	worker_stop, worker_watching: bool,
	pending, sending: []byte,
	pending_session, sending_session: int,
	acked, ack_session, piece: int,
	seq: u64,
	budget: Stream_Budget,
	ack_stats: Stream_Ack_Stats,
	input: Stream_Input_Queue,
}

Stream_Ack_Stats :: struct {
	received, offered, sent, acked, discarded, budget_refused: u64,
	last_frame: time.Tick,
}

stream_mu: sync.Mutex
stream_live: [contracts.STREAM_MAX_PER_BRIDGE]^Stream_Live
stream_connected: bool

stream_local_method :: proc(method: string) -> bool {
	return method == "agent.stream.list" || method == "agent.stream.share" || method == "agent.stream.stop"
}

stream_find_locked :: proc(id: string) -> ^Stream_Live {
	for live in stream_live {
		if live != nil && live.reg.stream_id == id do return live
	}
	return nil
}

stream_instance_live :: proc(instance: string, run_count: int) -> bool {
	launch, active := bridge_runtime_instance_snapshot(instance)
	return active && launch.runtime_status == "running" && bridge_agent_instance_run_count(instance) == run_count
}

stream_local_call :: proc(id, method, raw: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	params: map[string]string
	if json.unmarshal_string(raw, &params, allocator = context.temp_allocator) != nil || len(params) != 1 {
		return bridge_local_response_error(id, "bad_request", "invalid stream request")
	}
	if !stream_instance_live(rec.agent_instance_id, rec.run_count) {
		return bridge_local_response_error(id, "forbidden", "agent instance is not running")
	}
	if method == "agent.stream.stop" {
		sync.mutex_lock(&stream_mu)
		defer sync.mutex_unlock(&stream_mu)
		live := stream_find_locked(params["stream_id"])
		if live == nil || live.reg.instance != rec.agent_instance_id || live.run_count != rec.run_count || live.reason != "" {
			return bridge_local_response_error(id, "not_found", "unknown stream")
		}
		live.reason = "stopped"
		live.worker_stop = true
		return bridge_local_response_data(id, `{"stopped":true}`)
	}
	if method == "agent.stream.list" && params["sources"] != "tabs" ||
	   method == "agent.stream.share" && !stream_cdp_target_valid(params["tab"]) {
		return bridge_local_response_error(id, "bad_request", "invalid source")
	}
	profile := bridge_browser_profile_dir(bridge_config.data_dir, bridge_config.daemon_id)
	defer delete(profile)
	tabs, port, occupied, discovered := stream_cdp_list(profile)
	if occupied {
		return bridge_local_response_error(id, "source_unavailable", "port owned by another browser profile (or profile identity unavailable); check browser_cdp_port")
	}
	if !discovered do return bridge_local_response_error(id, "source_error", "local Chromium endpoint did not respond")
	if method == "agent.stream.list" {
		encoded, err := json.marshal(struct { tabs: []Stream_Tab }{tabs}, allocator = context.temp_allocator)
		if err != nil do return bridge_local_response_error(id, "internal", "could not encode sources")
		return bridge_local_response_data(id, string(encoded))
	}
	tab: Stream_Tab
	for candidate in tabs {
		if candidate.id == params["tab"] { tab = candidate; break }
	}
	if tab.id == "" do return bridge_local_response_error(id, "not_found", "unknown tab")
	owner := bridge_enrolled_owner_user_id(bridge_config.daemon_id)
	origin, origin_ok := bridge_hub_canonical_base(bridge_config.daemon_url, context.temp_allocator)
	if owner == "" || !origin_ok do return bridge_local_response_error(id, "unavailable", "Bridge is not enrolled")
	sync.mutex_lock(&stream_mu)
	existing := stream_share_join_locked(owner, contracts.STREAM_SOURCE_BROWSER_TAB, tab.id)
	sync.mutex_unlock(&stream_mu)
	if existing != nil do return stream_share_wait(id, existing, false)

	task := ""
	path := [?]string{"api", "v1", "agent-actions", "context"}
	relay := bridge_local_relay_agent_envelope(path[:], "agent.context.get", "{}", rec, 5000)
	defer delete(relay.body)
	if !relay.ok || relay.status != 200 do return bridge_local_response_error(id, "unavailable", "agent context is unavailable")
	ctx := bridge_local_extract_json_object(relay.body, "data", context.temp_allocator)
	// Older Hubs omit ui_origin. Keep the enrolled Hub base as their fallback.
	if ui_origin := bridge_local_extract_json_string(ctx, "ui_origin", "", context.temp_allocator); ui_origin != "" {
		origin = ui_origin
	}
	current := bridge_local_extract_json_object(ctx, "current_task", context.temp_allocator)
	task = bridge_local_extract_json_string(current, "task_id", "", context.temp_allocator)
	random: [16]byte
	if !os_random.fill(random[:]) do return bridge_local_response_error(id, "internal", "could not generate stream ID")
	hex_id := hex.encode(random[:], context.temp_allocator)
	stream_id := string(hex_id)
	link := strings.concatenate({strings.trim_right(origin, "/"), "/#/streams/", stream_id}, context.temp_allocator)
	live, created := stream_local_register(stream_id, owner, rec, task, tab, port, profile, link)
	if live == nil {
		return bridge_local_response_error(id, "unavailable", "Bridge disconnected or stream limit reached")
	}
	return stream_share_wait(id, live, created)
}

// Waiters pin the record through ACK, timeout, or termination so cleanup
// cannot invalidate the original link or a rejection before it is read.
stream_share_wait :: proc(id: string, live: ^Stream_Live, created: bool, instance_live := stream_instance_live) -> string {
	defer {
		sync.mutex_lock(&stream_mu)
		live.share_waiters -= 1
		sync.mutex_unlock(&stream_mu)
	}
	started := time.tick_now()
	for time.tick_since(started) < 3 * time.Second {
		sync.mutex_lock(&stream_mu)
		eligible := stream_share_eligible_locked(live, u64(bridge_runtime_now_ms()), instance_live)
		accepted := stream_connected && eligible && live.accepted
		link := live.link // Immutable while pinned.
		sync.mutex_unlock(&stream_mu)
		if accepted {
			encoded, _ := json.marshal(struct {link: string}{link}, allocator = context.temp_allocator)
			return bridge_local_response_data(id, string(encoded))
		}
		if !eligible do break
		time.sleep(10 * time.Millisecond)
	}
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	if live.register_reject != "" {
		return bridge_local_response_error(id, live.register_reject, "Hub rejected stream registration")
	}
	if created && !live.accepted && live.reason == "" do live.reason = "stopped"
	return bridge_local_response_error(id, "unavailable", "Hub did not accept stream registration")
}

stream_share_eligible_locked :: proc(live: ^Stream_Live, now: u64, instance_live: proc(string, int) -> bool) -> bool {
	return live.reason == "" && live.reg.expires > now && instance_live(live.reg.instance, live.run_count)
}

// The registry is Bridge-local. The owner check additionally prevents reuse
// across enrollment changes, without transferring creator stop authority.
stream_share_join_locked :: proc(owner, kind, ref: string, instance_live := stream_instance_live) -> ^Stream_Live {
	if !stream_connected do return nil
	now := u64(bridge_runtime_now_ms())
	for live in stream_live {
		if live != nil && live.reg.owner == owner && live.reg.source.kind == kind && live.reg.source.ref == ref &&
		   stream_share_eligible_locked(live, now, instance_live) {
			live.share_waiters += 1
			return live
		}
	}
	return nil
}

stream_local_register :: proc(id, owner: string, rec: Bridge_Local_Agent_Token_Record, task: string, tab: Stream_Tab, port: u16, profile, link: string, instance_live := stream_instance_live) -> (live: ^Stream_Live, created: bool) {
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	// Recheck after context lookup. Pending shares reserve the source as well
	// as a slot, so only one request sends a registration for this tab.
	if existing := stream_share_join_locked(owner, contracts.STREAM_SOURCE_BROWSER_TAB, tab.id, instance_live); existing != nil {
		return existing, false
	}
	if !stream_connected || stream_find_locked(id) != nil || !instance_live(rec.agent_instance_id, rec.run_count) do return nil, false
	for &slot in stream_live {
		if slot != nil do continue
		allocator := runtime.heap_allocator()
		live = new(Stream_Live, allocator)
		live.reg = {stream_id = strings.clone(id, allocator), owner = strings.clone(owner, allocator), bridge = strings.clone(bridge_config.daemon_id, allocator),
			instance = strings.clone(rec.agent_instance_id, allocator), task = strings.clone(task, allocator),
			source = {kind = contracts.STREAM_SOURCE_BROWSER_TAB, ref = strings.clone(tab.id, allocator)},
			title = strings.clone(stream_cdp_title(tab.title), allocator), expires = u64(bridge_runtime_now_ms()) + contracts.STREAM_EXPIRY_MS}
		live.port = port
		live.profile = strings.clone(profile, allocator)
		live.run_count = rec.run_count
		live.share_waiters = 1
		live.link = strings.clone(link, allocator)
		slot = live
		return live, true
	}
	return nil, false
}

stream_free :: proc(live: ^Stream_Live) {
	stream_input_clear(&live.input)
	delete(live.reg.stream_id, runtime.heap_allocator())
	delete(live.reg.owner, runtime.heap_allocator())
	delete(live.reg.bridge, runtime.heap_allocator())
	delete(live.reg.instance, runtime.heap_allocator())
	delete(live.reg.task, runtime.heap_allocator())
	delete(live.reg.source.ref, runtime.heap_allocator())
	delete(live.reg.title, runtime.heap_allocator())
	delete(live.profile, runtime.heap_allocator())
	delete(live.link, runtime.heap_allocator())
	delete(live.register_reject, runtime.heap_allocator())
	delete(live.pending, runtime.heap_allocator())
	delete(live.sending, runtime.heap_allocator())
	free(live, runtime.heap_allocator())
}

stream_connection :: proc(connected: bool) {
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	stream_connected = connected
	for live in stream_live {
		if live == nil do continue
		live.registered = false
		live.accepted = false
		live.attached = false
		live.worker_stop = true
		stream_input_clear(&live.input)
	}
}

stream_hub_receive :: proc(raw: string) -> bool {
	if stream_input_receive(raw) do return true
	if len(raw) > contracts.STREAM_MAX_CONTROL_BYTES || !strings.contains(raw, "\"stream_") do return false
	control, ok := contracts.stream_decode_control(raw, u64(bridge_runtime_now_ms()))
	if !ok do return false
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	#partial switch frame in control {
	case contracts.Stream_Register_Ack:
		if live := stream_find_locked(frame.stream_id); live != nil && live.registered {
			live.accepted = frame.accepted
			if !frame.accepted {
				live.reason = "source_error"
				live.registered = false // A rejected registration owns no Hub route to end.
				if live.share_waiters > 0 do live.register_reject = strings.clone(frame.code, runtime.heap_allocator())
			}
		}
	case contracts.Stream_Attach:
		if live := stream_find_locked(frame.stream_id); live != nil && live.accepted {
			if !live.attached do fmt.eprintln("bridge stream: viewer attached")
			live.attached = true
			if live.worker_watching do live.worker_stop = true
		}
	case contracts.Stream_Detach:
		if live := stream_find_locked(frame.stream_id); live != nil {
			if live.attached do fmt.eprintln("bridge stream: viewer detached")
			live.attached = false
			live.worker_stop = true
			stream_input_clear(&live.input)
		}
	case contracts.Stream_Stop:
		if live := stream_find_locked(frame.stream_id); live != nil {
			live.reason = "stopped"
			live.worker_stop = true
			stream_input_clear(&live.input)
		}
	}
	return true
}

stream_send_control :: proc(conn: ^ws.Connection, control: contracts.Stream_Control) -> bool {
	encoded := contracts.stream_encode_control(control)
	defer delete(encoded)
	return len(encoded) != 0 && ws.send_text(conn, string(encoded))
}

stream_hub_drain :: proc(conn: ^ws.Connection, send_control := stream_send_control, instance_live := stream_instance_live) -> bool {
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	more := false
	now := u64(bridge_runtime_now_ms())
	for &slot in stream_live {
		live := slot
		if live == nil do continue
		if live.reason == "" {
			if live.reg.expires <= now do live.reason = "expired"
			if !instance_live(live.reg.instance, live.run_count) do live.reason = "instance_ended"
		}
		if live.reason != "" do live.worker_stop = true
		if live.worker != nil && thread.is_done(live.worker) {
			thread.destroy(live.worker)
			live.worker = nil
			stream_input_clear(&live.input)
			delete(live.pending, runtime.heap_allocator()); live.pending = nil
			delete(live.sending, runtime.heap_allocator()); live.sending = nil
			live.acked, live.piece = 0, 0
		}
		if live.reason != "" {
			if live.registered {
				fmt.eprintfln("bridge stream: ended reason=%s stage=%s", live.reason, live.source_stage)
				_ = send_control(conn, contracts.Stream_Ended{live.reg.stream_id, live.reason})
				live.registered = false
			}
			// The local caller may not have observed the rejection yet.
			if live.worker == nil && live.share_waiters == 0 { stream_free(live); slot = nil }
			continue
		}
		if !live.registered {
			live.registered = send_control(conn, live.reg)
			if !live.registered {
				live.reason = "source_error"
				continue
			}
		}
		if live.accepted {
			if live.worker == nil {
				live.worker_stop = false
				live.worker_watching = !live.attached
				live.ack_stats = {}
				if capture := stream_capture_provider(live.reg.source.kind); capture != nil {
					live.worker = thread.create_and_start_with_data(live, capture)
				}
				if live.worker == nil do live.reason = "source_error"
			}
			if live.attached && !live.worker_stop && stream_send_piece(conn, live) do more = true
		}
	}
	return more
}

stream_send_piece :: proc(conn: ^ws.Connection, live: ^Stream_Live, send := bridge_hub_send_binary, now: time.Tick = {}) -> bool {
	if live.sending == nil {
		if live.pending == nil do return false
		tick := time.tick_now() if now._nsec == 0 else now
		if !stream_budget_admit(&live.budget, tick, len(live.pending)) {
			live.ack_stats.budget_refused += 1
			return false
		}
		live.seq += 1
		live.sending, live.sending_session = live.pending, live.pending_session
		live.pending = nil
	}
	start := live.piece * contracts.STREAM_MAX_PIECE_BYTES
	stop := min(start + contracts.STREAM_MAX_PIECE_BYTES, len(live.sending))
	count := (len(live.sending) + contracts.STREAM_MAX_PIECE_BYTES - 1) / contracts.STREAM_MAX_PIECE_BYTES
	encoded := contracts.stream_encode_piece({live.reg.stream_id, live.seq, u16(live.piece), u16(count), contracts.STREAM_MIME_JPEG, live.sending[start:stop]})
	defer delete(encoded)
	if len(encoded) == 0 || !send(conn, encoded) {
		live.worker_stop = true
		return false
	}
	live.piece += 1
	if stop == len(live.sending) {
		live.ack_stats.sent += 1
		// Chromium shares one session ID across all frames from a given
		// startScreencast. Keep the count, not just the latest ID.
		live.ack_session = live.sending_session
		live.acked += 1
		delete(live.sending, runtime.heap_allocator())
		live.sending = nil
		live.piece = 0
	}
	return true
}

// Frame admissions use a monotonic rolling window. At 8 fps there can be at
// most eight still-chargeable frames, so no unbounded rate-limit bookkeeping.
Stream_Budget_Entry :: struct {stamp: time.Tick, size: int}
Stream_Budget :: struct {
	entries: [contracts.STREAM_MAX_FPS]Stream_Budget_Entry,
	last: time.Tick,
}
stream_budget_admit :: proc(b: ^Stream_Budget, now: time.Tick, size: int) -> bool {
	if size <= 0 || size > contracts.STREAM_MAX_BYTES_PER_SECOND do return false
	if b.last._nsec != 0 && time.tick_diff(b.last, now) < time.Second / contracts.STREAM_MAX_FPS do return false
	total := size
	free_slot := -1
	for entry, i in b.entries {
		if entry.size == 0 || time.tick_diff(entry.stamp, now) >= time.Second {
			free_slot = i
		} else {
			total += entry.size
		}
	}
	if free_slot < 0 || total > contracts.STREAM_MAX_BYTES_PER_SECOND do return false
	b.entries[free_slot] = {now, size}
	b.last = now
	return true
}

// Ownership of data transfers to the one-slot mailbox. The returned session
// belongs to a deliberately discarded frame and may be acknowledged at once.
stream_offer_frame :: proc(live: ^Stream_Live, data: []byte, session: int) -> int {
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	if live.worker_stop {
		live.ack_stats.discarded += 1
		delete(data, runtime.heap_allocator())
		return session
	}
	discard := 0
	if live.pending != nil {
		live.ack_stats.discarded += 1
		discard = live.pending_session
		delete(live.pending, runtime.heap_allocator())
	}
	live.pending, live.pending_session = data, session
	live.ack_stats.offered += 1
	return discard
}

// Capture sources own their local transport. Their worker hands encoded frames
// to the generic one-slot mailbox and consumes completed-frame acknowledgements.
// This preserves the S1 provider split while carrying CDP's extra ACK metadata.
Stream_Capture_Worker :: proc(rawptr)
stream_capture_provider :: proc(kind: string) -> Stream_Capture_Worker {
	if kind == contracts.STREAM_SOURCE_BROWSER_TAB do return stream_capture_worker
	return nil
}
