package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:net"
import contracts "odin_test:contracts"
import http "odin_test:lib/http_client"

PEER_MAX_RECORDS :: 256
PEER_MAX_EVENTS :: 2048

PEER_STATUS_LINKED :: "linked"
PEER_STATUS_UNREACHABLE :: "unreachable"

Peer_Link_Record :: struct {
	peer_record_id: string,
	peer_id: string,
	peer_url: string,
	peer_token: string,
	daemon_id: string,
	version: string,
	status: string,
	created_unix_ms: i64,
	updated_unix_ms: i64,
	removed_at_unix_ms: i64,
	last_checked_unix_ms: i64,
}

Peer_Link_Event_Kind :: enum { Peer_Link_Upserted, Peer_Link_Removed }

Peer_Link_Event :: struct {
	event_id: string,
	kind: Peer_Link_Event_Kind,
	peer_record_id: string,
	peer_id: string,
	peer_url: string,
	peer_token: string,
	author: string,
	created_unix_ms: i64,
}

peer_link_records: [PEER_MAX_RECORDS]Peer_Link_Record
peer_link_record_count: int
peer_link_events: [PEER_MAX_EVENTS]Peer_Link_Event
peer_link_event_count: int
peer_link_store_sequence: i64
peer_link_store_dir: string
peer_link_events_path: string
peer_link_poll_started: bool
peer_link_poll_sleep_duration: time.Duration

Reachable_Daemon_Record :: struct {
	daemon_id: string,
	peer_id: string,
	reach: string,
	next_hop_daemon_id: string,
	hops: int,
	status: string,
	last_seen_unix_ms: i64,
	updated_unix_ms: i64,
}

reachable_daemon_records: [PEER_MAX_RECORDS]Reachable_Daemon_Record
reachable_daemon_count: int
reachable_daemon_mutex: sync.Mutex

peer_link_store_init :: proc(data_dir: string) {
	peer_link_record_count = 0
	peer_link_event_count = 0
	peer_link_store_sequence = 0
	peer_link_store_dir = strings.clone(fmt.tprintf("%s/federation", expand_home(data_dir)))
	peer_link_events_path = strings.clone(fmt.tprintf("%s/peer-links.jsonl", peer_link_store_dir))
	_ = os.make_directory_all(peer_link_store_dir)
	reachable_daemon_count = 0
	reachable_daemon_mutex = sync.Mutex{}
	peer_link_store_replay()
	// Federation v2 Phase 1 moves [[peer]] endpoint/token config and live
	// link/session state to ham-bridge. The daemon still replays legacy peer-link
	// records for compatibility, but it no longer bootstraps links from config or
	// starts URL/token health polling. When a bridge is configured, this poller is
	// loopback-only and exists to replay daemon durable outboxes when bridge WS
	// reachability returns.
	if bridge_client_enabled() do peer_link_poll_start()
}

peer_link_poll_start :: proc() {
	if peer_link_poll_started do return
	peer_link_poll_started = true
	peer_link_poll_sleep_duration = peer_link_poll_interval()
	thread.run(peer_link_poll_worker)
}

FEDERATION_POLL_INTERVAL_DEFAULT_SECONDS :: 10
FEDERATION_POLL_INTERVAL_MIN_SECONDS :: 5
FEDERATION_POLL_INTERVAL_MAX_SECONDS :: 300

peer_link_poll_interval :: proc() -> time.Duration {
	interval_seconds := server_config.daemon.federation_poll_interval_seconds
	if interval_seconds <= 0 {
		fmt.printfln("FEDERATION_POLL_INTERVAL_INVALID ts_unix_ms=%d configured_seconds=%d effective_seconds=%d", router_now_unix_ms(), interval_seconds, FEDERATION_POLL_INTERVAL_DEFAULT_SECONDS)
		interval_seconds = FEDERATION_POLL_INTERVAL_DEFAULT_SECONDS
	}
	if interval_seconds < FEDERATION_POLL_INTERVAL_MIN_SECONDS {
		fmt.printfln("FEDERATION_POLL_INTERVAL_CLAMP ts_unix_ms=%d configured_seconds=%d effective_seconds=%d", router_now_unix_ms(), interval_seconds, FEDERATION_POLL_INTERVAL_MIN_SECONDS)
		interval_seconds = FEDERATION_POLL_INTERVAL_MIN_SECONDS
	}
	if interval_seconds > FEDERATION_POLL_INTERVAL_MAX_SECONDS {
		fmt.printfln("FEDERATION_POLL_INTERVAL_CLAMP ts_unix_ms=%d configured_seconds=%d effective_seconds=%d", router_now_unix_ms(), interval_seconds, FEDERATION_POLL_INTERVAL_MAX_SECONDS)
		interval_seconds = FEDERATION_POLL_INTERVAL_MAX_SECONDS
	}
	return time.Duration(interval_seconds) * time.Second
}

peer_link_poll_worker :: proc() {
	for {
		peer_link_probe_all()
		time.sleep(peer_link_poll_sleep_duration)
	}
}

peer_link_probe_all :: proc() {
	_ = reachable_daemon_hydrate_from_bridge()
	for i in 0..<peer_link_record_count {
		if peer_link_records[i].removed_at_unix_ms != 0 do continue
		peer_link_probe(peer_link_records[i].peer_id)
	}
	// Periodic safety-net replay for durable federation outboxes.
	//
	// Transition-driven replay (reachable_daemon_apply_entry_locked) only fires on an
	// unreachable->linked flip or a last_seen change. In bridge mode the daemon's
	// peer_link_records are empty (peers live in bridge config), and the bridge only
	// advances last_seen on session connect/disconnect -- so a callback that landed in
	// the outbox undelivered while the link was briefly bounced (e.g. the startup
	// dual-dial race) would otherwise sit forever while the link stays continuously
	// linked. Draining pending entries for every currently-linked daemon each poll gives
	// true eventual consistency without depending on a status edge.
	_ = federation_delivery_outbox_replay_all_pending()
}

peer_link_append_event :: proc(event: Peer_Link_Event) -> bool {
	ev := peer_link_event_clone(event)
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("peer_evt_%d_%d", router_now_unix_ms(), peer_link_next_sequence()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	file, err := os.open(peer_link_events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return false
	defer os.close(file)
	os.write_string(file, peer_link_event_json(ev))
	os.write_string(file, "\n")
	return peer_link_apply_event(ev)
}

peer_link_store_replay :: proc() {
	data, err := os.read_entire_file(peer_link_events_path, context.allocator)
	if err != nil do return
	for line in strings.split(string(data), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		if ev, ok := peer_link_event_from_json(trimmed); ok do peer_link_apply_event(ev)
	}
}

peer_link_apply_event :: proc(event: Peer_Link_Event) -> bool {
	if peer_link_event_count < PEER_MAX_EVENTS {
		peer_link_events[peer_link_event_count] = peer_link_event_clone(event)
		peer_link_event_count += 1
	}
	idx := peer_link_index_by_record_id(event.peer_record_id)
	if idx < 0 && event.peer_id != "" do idx = peer_link_index(event.peer_id)
	if idx < 0 {
		if peer_link_record_count >= PEER_MAX_RECORDS do return false
		idx = peer_link_record_count
		peer_link_record_count += 1
		peer_link_records[idx].peer_record_id = strings.clone(event.peer_record_id)
		peer_link_records[idx].created_unix_ms = event.created_unix_ms
		peer_link_records[idx].status = strings.clone(PEER_STATUS_UNREACHABLE)
	}
	rec := &peer_link_records[idx]
	if event.kind == .Peer_Link_Removed {
		rec.removed_at_unix_ms = event.created_unix_ms
		rec.updated_unix_ms = event.created_unix_ms
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		return true
	}
	rec.peer_record_id = strings.clone(event.peer_record_id)
	rec.peer_id = strings.clone(peer_id_normalize(event.peer_id))
	rec.peer_url = strings.clone(peer_url_normalize(event.peer_url))
	rec.peer_token = strings.clone(strings.trim_space(event.peer_token))
	rec.updated_unix_ms = event.created_unix_ms
	if rec.created_unix_ms == 0 do rec.created_unix_ms = event.created_unix_ms
	rec.removed_at_unix_ms = 0
	if rec.status == "" do rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
	return true
}

peer_link_index :: proc(peer_id: string) -> int {
	for i in 0..<peer_link_record_count {
		if peer_link_records[i].peer_id == peer_id do return i
	}
	return -1
}

peer_link_index_by_record_id :: proc(peer_record_id: string) -> int {
	for i in 0..<peer_link_record_count {
		if peer_link_records[i].peer_record_id == peer_record_id do return i
	}
	return -1
}

peer_link_find :: proc(peer_id: string) -> (^Peer_Link_Record, bool) {
	idx := peer_link_index(peer_id)
	if idx < 0 do return nil, false
	if peer_link_records[idx].removed_at_unix_ms != 0 do return nil, false
	return &peer_link_records[idx], true
}

peer_link_find_by_daemon_id :: proc(daemon_id: string) -> (^Peer_Link_Record, bool) {
	trimmed_daemon_id := strings.trim_space(daemon_id)
	if trimmed_daemon_id == "" do return nil, false
	for i in 0..<peer_link_record_count {
		rec := &peer_link_records[i]
		if rec.removed_at_unix_ms != 0 do continue
		if strings.trim_space(rec.daemon_id) == trimmed_daemon_id || strings.trim_space(rec.peer_id) == trimmed_daemon_id do return rec, true
	}
	return nil, false
}

peer_link_validate_request :: proc(peer_token, peer_daemon_id: string) -> bool {
	trimmed_token := strings.trim_space(peer_token)
	trimmed_daemon_id := strings.trim_space(peer_daemon_id)
	if trimmed_token == "" || trimmed_daemon_id == "" do return false
	for i in 0..<peer_link_record_count {
		rec := peer_link_records[i]
		if rec.removed_at_unix_ms != 0 do continue
		if rec.peer_token != trimmed_token do continue
		if rec.daemon_id != trimmed_daemon_id && rec.peer_id != trimmed_daemon_id do continue
		return true
	}
	return false
}

peer_link_bridge_reachable_body :: proc() -> (string, bool) {
	if !bridge_client_enabled() do return "", false
	resp, ok := http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_GET, server_bridge_url, contracts.ROUTE_BRIDGE_REACHABLE, "", bridge_client_headers(), FEDERATION_HTTP_TIMEOUT_MS)
	if !ok || resp.status != 200 do return "", false
	return strings.clone(resp.body), true
}

reachable_daemon_status_normalize :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	if trimmed == contracts.BRIDGE_REACHABILITY_STATUS_LINKED do return PEER_STATUS_LINKED
	return PEER_STATUS_UNREACHABLE
}

reachable_daemon_index_locked :: proc(daemon_id: string) -> int {
	for i in 0..<reachable_daemon_count {
		if reachable_daemon_records[i].daemon_id == daemon_id do return i
	}
	return -1
}

reachable_daemon_apply_entry_locked :: proc(entry: string, changed_ids: ^strings.Builder, changed_count: ^int, replay_peer_ids: []string, replay_count: ^int) {
	daemon_id := strings.trim_space(extract_json_string(entry, "daemon_id", ""))
	if daemon_id == "" do return
	status := reachable_daemon_status_normalize(extract_json_string(entry, "status", contracts.BRIDGE_REACHABILITY_STATUS_UNREACHABLE))
	idx := reachable_daemon_index_locked(daemon_id)
	if idx < 0 {
		if reachable_daemon_count >= PEER_MAX_RECORDS do return
		idx = reachable_daemon_count
		reachable_daemon_count += 1
		reachable_daemon_records[idx].daemon_id = strings.clone(daemon_id)
		reachable_daemon_records[idx].peer_id = strings.clone(daemon_id)
	}
	rec := &reachable_daemon_records[idx]
	old_status := rec.status
	if old_status == "" do old_status = PEER_STATUS_UNREACHABLE
	old_last_seen_unix_ms := rec.last_seen_unix_ms
	new_last_seen_unix_ms := i64(extract_json_int(entry, "last_seen_unix_ms", 0))
	rec.reach = strings.clone(extract_json_string(entry, "reach", contracts.DAEMON_FEDERATION_PEER_KIND_DIRECT))
	rec.next_hop_daemon_id = strings.clone(extract_json_string(entry, "next_hop_daemon_id", daemon_id))
	rec.hops = extract_json_int(entry, "hops", 1)
	rec.status = strings.clone(status)
	rec.last_seen_unix_ms = new_last_seen_unix_ms
	rec.updated_unix_ms = router_now_unix_ms()
	if old_status != status {
		if changed_count^ > 0 do strings.write_string(changed_ids, `,`)
		strings.write_string(changed_ids, `"`); json_write_string(changed_ids, daemon_id); strings.write_string(changed_ids, `"`)
		changed_count^ += 1
	}
	if status == PEER_STATUS_LINKED && (old_status != PEER_STATUS_LINKED || old_last_seen_unix_ms != new_last_seen_unix_ms) {
		peer_id := rec.peer_id
		if peer_id == "" do peer_id = daemon_id
		if rec_ptr, found := peer_link_find_by_daemon_id(daemon_id); found do peer_id = rec_ptr.peer_id
		if peer_id != "" && replay_count^ < PEER_MAX_RECORDS && !reachable_daemon_id_seen(replay_peer_ids, replay_count^, peer_id) {
			replay_peer_ids[replay_count^] = strings.clone(peer_id)
			replay_count^ += 1
		}
	}
}

reachable_daemon_id_seen :: proc(seen_ids: []string, seen_count: int, daemon_id: string) -> bool {
	for i in 0..<seen_count {
		if seen_ids[i] == daemon_id do return true
	}
	return false
}

reachable_daemon_apply_body :: proc(body: string, emit_event: bool) -> int {
	changed_ids := strings.builder_make()
	changed_count := 0
	seen_ids: [PEER_MAX_RECORDS]string
	seen_count := 0
	replay_peer_ids: [PEER_MAX_RECORDS]string
	replay_count := 0
	defer {
		for i in 0..<replay_count do delete(replay_peer_ids[i])
	}
	now := router_now_unix_ms()
	sync.mutex_lock(&reachable_daemon_mutex)
	search := body
	for {
		idx := strings.index(search, `"daemon_id":"`)
		if idx < 0 do break
		entry := search[idx:]
		end := strings.index_byte(entry, '}')
		if end < 0 do break
		entry_body := entry[:end]
		daemon_id := strings.trim_space(extract_json_string(entry_body, "daemon_id", ""))
		if daemon_id != "" && seen_count < PEER_MAX_RECORDS && !reachable_daemon_id_seen(seen_ids[:], seen_count, daemon_id) {
			seen_ids[seen_count] = strings.clone(daemon_id)
			seen_count += 1
		}
		reachable_daemon_apply_entry_locked(entry_body, &changed_ids, &changed_count, replay_peer_ids[:], &replay_count)
		search = entry[end + 1:]
	}
	// A successful /bridge/reachable response is authoritative for Phase 1 direct
	// peers. Any projected daemon omitted from that successful snapshot is no
	// longer present in bridge WS session/config state, so it must not remain
	// linked in the daemon's public live projection.
	for i in 0..<reachable_daemon_count {
		if reachable_daemon_records[i].status != PEER_STATUS_LINKED do continue
		if reachable_daemon_id_seen(seen_ids[:], seen_count, reachable_daemon_records[i].daemon_id) do continue
		if changed_count > 0 do strings.write_string(&changed_ids, `,`)
		strings.write_string(&changed_ids, `"`); json_write_string(&changed_ids, reachable_daemon_records[i].daemon_id); strings.write_string(&changed_ids, `"`)
		changed_count += 1
		reachable_daemon_records[i].status = strings.clone(PEER_STATUS_UNREACHABLE)
		reachable_daemon_records[i].updated_unix_ms = now
	}
	sync.mutex_unlock(&reachable_daemon_mutex)
	for i in 0..<replay_count {
		_ = federation_delivery_outbox_replay_peer(replay_peer_ids[i])
		_ = peer_link_replay_remote_notifications(replay_peer_ids[i])
	}
	if emit_event && changed_count > 0 do federation_reachability_emit_event(strings.to_string(changed_ids), changed_count)
	return changed_count
}

reachable_daemon_mark_all_unreachable :: proc(emit_event: bool) -> int {
	changed_ids := strings.builder_make()
	changed_count := 0
	now := router_now_unix_ms()
	sync.mutex_lock(&reachable_daemon_mutex)
	for i in 0..<reachable_daemon_count {
		old_status := reachable_daemon_records[i].status
		if old_status == "" do old_status = PEER_STATUS_UNREACHABLE
		if old_status == PEER_STATUS_LINKED {
			if changed_count > 0 do strings.write_string(&changed_ids, `,`)
			strings.write_string(&changed_ids, `"`); json_write_string(&changed_ids, reachable_daemon_records[i].daemon_id); strings.write_string(&changed_ids, `"`)
			changed_count += 1
		}
		reachable_daemon_records[i].status = strings.clone(PEER_STATUS_UNREACHABLE)
		reachable_daemon_records[i].updated_unix_ms = now
	}
	sync.mutex_unlock(&reachable_daemon_mutex)
	if emit_event && changed_count > 0 do federation_reachability_emit_event(strings.to_string(changed_ids), changed_count)
	return changed_count
}

reachable_daemon_hydrate_from_bridge :: proc() -> bool {
	body, ok := peer_link_bridge_reachable_body()
	if !ok {
		_ = reachable_daemon_mark_all_unreachable(true)
		return false
	}
	_ = reachable_daemon_apply_body(body, true)
	return true
}

federation_direct_peer_lookup_cached :: proc(peer_id, origin_daemon_id: string) -> (resolved_peer_id: string, daemon_id: string, status: string, found: bool) {
	trimmed_peer_id := strings.trim_space(peer_id)
	trimmed_origin := strings.trim_space(origin_daemon_id)
	if bridge_client_enabled() {
		sync.mutex_lock(&reachable_daemon_mutex)
		// Origin daemon id is the scoped authority when supplied. If both peer_id
		// and origin are supplied, require them to identify the same projected direct
		// peer so bridge-only multi-peer setups cannot bind/route to the wrong peer.
		if trimmed_origin != "" {
			for i in 0..<reachable_daemon_count {
				rec := reachable_daemon_records[i]
				if rec.peer_id != trimmed_origin && rec.daemon_id != trimmed_origin do continue
				if trimmed_peer_id != "" && rec.peer_id != trimmed_peer_id && rec.daemon_id != trimmed_peer_id {
					sync.mutex_unlock(&reachable_daemon_mutex)
					return "", "", "", false
				}
				resolved := rec.peer_id
				if resolved == "" do resolved = rec.daemon_id
				st := rec.status
				if st == "" do st = PEER_STATUS_UNREACHABLE
				sync.mutex_unlock(&reachable_daemon_mutex)
				return strings.clone(resolved), strings.clone(rec.daemon_id), strings.clone(st), true
			}
			sync.mutex_unlock(&reachable_daemon_mutex)
			return "", "", "", false
		}
		if trimmed_peer_id != "" {
			for i in 0..<reachable_daemon_count {
				rec := reachable_daemon_records[i]
				if rec.peer_id != trimmed_peer_id && rec.daemon_id != trimmed_peer_id do continue
				resolved := rec.peer_id
				if resolved == "" do resolved = rec.daemon_id
				st := rec.status
				if st == "" do st = PEER_STATUS_UNREACHABLE
				sync.mutex_unlock(&reachable_daemon_mutex)
				return strings.clone(resolved), strings.clone(rec.daemon_id), strings.clone(st), true
			}
		}
		sync.mutex_unlock(&reachable_daemon_mutex)
	}
	if trimmed_origin != "" {
		if rec, ok := peer_link_find_by_daemon_id(trimmed_origin); ok {
			if trimmed_peer_id != "" && rec.peer_id != trimmed_peer_id && rec.daemon_id != trimmed_peer_id do return "", "", "", false
			dest := peer_link_destination_daemon_id(rec)
			return strings.clone(rec.peer_id), strings.clone(dest), strings.clone(rec.status), true
		}
		return "", "", "", false
	}
	if trimmed_peer_id != "" {
		if rec, ok := peer_link_find(trimmed_peer_id); ok {
			dest := peer_link_destination_daemon_id(rec)
			return strings.clone(rec.peer_id), strings.clone(dest), strings.clone(rec.status), true
		}
	}
	return "", "", "", false
}

federation_direct_peer_lookup :: proc(peer_id, origin_daemon_id: string) -> (resolved_peer_id: string, daemon_id: string, status: string, found: bool) {
	if bridge_client_enabled() {
		_ = reachable_daemon_hydrate_from_bridge()
	}
	return federation_direct_peer_lookup_cached(peer_id, origin_daemon_id)
}

federation_reachability_emit_event :: proc(changed_ids_json: string, changed_count: int) {
	linked := 0
	unreachable := 0
	sync.mutex_lock(&reachable_daemon_mutex)
	for i in 0..<reachable_daemon_count {
		if reachable_daemon_records[i].status == PEER_STATUS_LINKED {
			linked += 1
		} else {
			unreachable += 1
		}
	}
	sync.mutex_unlock(&reachable_daemon_mutex)
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"federation_event","event":"`); json_write_string(&b, contracts.DAEMON_FEDERATION_REACHABILITY_EVENT)
	strings.write_string(&b, `","changed_daemon_ids":[`); strings.write_string(&b, changed_ids_json)
	strings.write_string(&b, `],"changed_count":`); strings.write_string(&b, fmt.tprintf("%d", changed_count))
	strings.write_string(&b, `,"linked_count":`); strings.write_string(&b, fmt.tprintf("%d", linked))
	strings.write_string(&b, `,"unreachable_count":`); strings.write_string(&b, fmt.tprintf("%d", unreachable))
	strings.write_string(&b, `,"changed_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", router_now_unix_ms()))
	strings.write_string(&b, `}`)
	user_client_fanout_all_ws_text(strings.to_string(b))
}

peer_link_bridge_entry_for_daemon :: proc(body, daemon_id: string) -> (string, bool) {
	trimmed := strings.trim_space(daemon_id)
	if trimmed == "" do return "", false
	needle := fmt.tprintf(`"daemon_id":"%s"`, trimmed)
	idx := strings.index(body, needle)
	if idx < 0 do return "", false
	entry := body[idx:]
	if end := strings.index_byte(entry, '}'); end >= 0 do entry = entry[:end]
	return entry, true
}

peer_link_bridge_resolve_daemon_id :: proc(peer_id, current_daemon_id: string) -> string {
	body, ok := peer_link_bridge_reachable_body()
	if !ok do return strings.trim_space(current_daemon_id)
	if _, found := peer_link_bridge_entry_for_daemon(body, current_daemon_id); found do return strings.trim_space(current_daemon_id)
	if _, found := peer_link_bridge_entry_for_daemon(body, peer_id); found do return strings.trim_space(peer_id)
	return strings.trim_space(current_daemon_id)
}

peer_link_destination_daemon_id :: proc(rec: ^Peer_Link_Record) -> string {
	if rec == nil do return ""
	resolved := peer_link_bridge_resolve_daemon_id(rec.peer_id, rec.daemon_id)
	if strings.trim_space(resolved) != "" && strings.trim_space(rec.daemon_id) == "" {
		rec.daemon_id = strings.clone(resolved)
	}
	return resolved
}

peer_link_bridge_reachable :: proc(rec: ^Peer_Link_Record) -> bool {
	if rec == nil do return false
	body, ok := peer_link_bridge_reachable_body()
	if !ok do return false
	daemon_id := strings.trim_space(rec.daemon_id)
	entry, found := peer_link_bridge_entry_for_daemon(body, daemon_id)
	if !found {
		entry, found = peer_link_bridge_entry_for_daemon(body, rec.peer_id)
		if found && daemon_id == "" {
			rec.daemon_id = strings.clone(strings.trim_space(rec.peer_id))
		}
	}
	if !found do return false
	// Phase 1 /bridge/reachable is direct-only and secret-free; linked status is
	// sourced from bridge WebSocket session state. A lightweight per-entry string
	// check keeps daemon business logic from learning peer endpoint/token/session details.
	return strings.contains(entry, `"status":"linked"`)
}

peer_link_replay_remote_notifications :: proc(peer_id: string) -> int {
	replayed := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if !agent_record_is_remote_proxy(rec) do continue
		if rec.remote_peer_id != peer_id do continue
		replayed += notification_outbox_replay_pending(rec.agent_instance_id)
	}
	return replayed
}

peer_link_probe :: proc(peer_id: string) -> bool {
	rec, ok := peer_link_find(peer_id)
	if !ok do return false
	was_linked := rec.status == PEER_STATUS_LINKED
	linked := peer_link_bridge_reachable(rec)
	rec.status = strings.clone(PEER_STATUS_LINKED if linked else PEER_STATUS_UNREACHABLE)
	rec.last_checked_unix_ms = router_now_unix_ms()
	if linked {
		_ = federation_delivery_outbox_replay_peer(peer_id)
		_ = peer_link_replay_remote_notifications(peer_id)
		_ = was_linked
		return true
	}
	return false
}

peer_link_create_or_update :: proc(peer_id, peer_url, peer_token, author: string) -> (Peer_Link_Record, bool, string) {
	clean_id := peer_id_normalize(peer_id)
	clean_url := peer_url_normalize(peer_url)
	clean_token := strings.trim_space(peer_token)
	if clean_id == "" do return Peer_Link_Record{}, false, "peer_id required"
	if clean_url == "" do return Peer_Link_Record{}, false, "peer_url required"
	if clean_token == "" do return Peer_Link_Record{}, false, "peer_token required"
	record_id := peer_link_new_record_id()
	if existing, ok := peer_link_find(clean_id); ok {
		record_id = existing.peer_record_id
		if existing.peer_url == clean_url && existing.peer_token == clean_token {
			_ = peer_link_probe(clean_id)
			return existing^, true, ""
		}
	}
	if !peer_link_append_event(Peer_Link_Event{
		kind = .Peer_Link_Upserted,
		peer_record_id = record_id,
		peer_id = clean_id,
		peer_url = clean_url,
		peer_token = clean_token,
		author = author,
	}) {
		return Peer_Link_Record{}, false, "failed to persist peer link"
	}
	_ = peer_link_probe(clean_id)
	rec, ok := peer_link_find(clean_id)
	if !ok do return Peer_Link_Record{}, false, "peer link not found after save"
	return rec^, true, ""
}

peer_link_remove :: proc(peer_id, author: string) -> bool {
	rec, ok := peer_link_find(peer_id)
	if !ok do return false
	return peer_link_append_event(Peer_Link_Event{
		kind = .Peer_Link_Removed,
		peer_record_id = rec.peer_record_id,
		peer_id = rec.peer_id,
		author = author,
	})
}

peer_link_event_clone :: proc(event: Peer_Link_Event) -> Peer_Link_Event {
	out := event
	out.event_id = strings.clone(event.event_id)
	out.peer_record_id = strings.clone(event.peer_record_id)
	out.peer_id = strings.clone(event.peer_id)
	out.peer_url = strings.clone(event.peer_url)
	out.peer_token = strings.clone(event.peer_token)
	out.author = strings.clone(event.author)
	return out
}

peer_link_event_json :: proc(event: Peer_Link_Event) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"event_id":"`); json_write_string(&b, event.event_id)
	strings.write_string(&b, `","kind":"`); json_write_string(&b, fmt.tprintf("%v", event.kind))
	strings.write_string(&b, `","peer_record_id":"`); json_write_string(&b, event.peer_record_id)
	strings.write_string(&b, `","peer_id":"`); json_write_string(&b, peer_id_normalize(event.peer_id))
	strings.write_string(&b, `","peer_url":"`); json_write_string(&b, peer_url_normalize(event.peer_url))
	strings.write_string(&b, `","peer_token":"`); json_write_string(&b, event.peer_token)
	strings.write_string(&b, `","author":"`); json_write_string(&b, event.author)
	strings.write_string(&b, `","created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

peer_link_event_from_json :: proc(line: string) -> (Peer_Link_Event, bool) {
	kind := Peer_Link_Event_Kind.Peer_Link_Upserted
	if extract_json_string(line, "kind", "") == "Peer_Link_Removed" do kind = .Peer_Link_Removed
	ev := Peer_Link_Event{
		event_id = extract_json_string(line, "event_id", ""),
		kind = kind,
		peer_record_id = extract_json_string(line, "peer_record_id", ""),
		peer_id = extract_json_string(line, "peer_id", ""),
		peer_url = extract_json_string(line, "peer_url", ""),
		peer_token = extract_json_string(line, "peer_token", ""),
		author = extract_json_string(line, "author", ""),
		created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0)),
	}
	return ev, ev.peer_record_id != "" || ev.peer_id != ""
}

peer_link_next_sequence :: proc() -> i64 {
	peer_link_store_sequence += 1
	return peer_link_store_sequence
}

peer_link_new_record_id :: proc() -> string {
	return fmt.tprintf("peer_rec_%d_%d", router_now_unix_ms(), peer_link_next_sequence())
}

peer_id_normalize :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return ""
	return safe_agent_id_part(trimmed)
}

peer_url_normalize :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	for len(trimmed) > 1 && strings.has_suffix(trimmed, "/") {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	return trimmed
}

federation_peer_record_json :: proc(builder: ^strings.Builder, rec: Reachable_Daemon_Record) {
	strings.write_string(builder, `{"peer_id":"`); json_write_string(builder, rec.peer_id)
	strings.write_string(builder, `","daemon_id":"`); json_write_string(builder, rec.daemon_id)
	strings.write_string(builder, `","kind":"`); json_write_string(builder, contracts.DAEMON_FEDERATION_PEER_KIND_DIRECT)
	reach := rec.reach
	if reach == "" do reach = contracts.DAEMON_FEDERATION_PEER_KIND_DIRECT
	next_hop := rec.next_hop_daemon_id
	if next_hop == "" do next_hop = rec.daemon_id
	strings.write_string(builder, `","reach":"`); json_write_string(builder, reach)
	strings.write_string(builder, `","next_hop":"`); json_write_string(builder, next_hop)
	strings.write_string(builder, `","hops":`); strings.write_string(builder, fmt.tprintf("%d", rec.hops))
	strings.write_string(builder, `,"via":[]`)
	status := rec.status
	if status == "" do status = PEER_STATUS_UNREACHABLE
	strings.write_string(builder, `,"status":"`); json_write_string(builder, status)
	strings.write_string(builder, `","last_seen_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.last_seen_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `}`)
}

federation_peers_list_json :: proc() -> string {
	bridge_reachable := false
	if bridge_client_enabled() {
		bridge_reachable = reachable_daemon_hydrate_from_bridge()
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"self_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","bridge_configured":`); strings.write_string(&b, "true" if bridge_client_enabled() else "false")
	strings.write_string(&b, `,"bridge_reachable":`); strings.write_string(&b, "true" if bridge_reachable else "false")
	strings.write_string(&b, `,"peers":[`)
	wrote := 0
	if bridge_client_enabled() {
		sync.mutex_lock(&reachable_daemon_mutex)
		for i in 0..<reachable_daemon_count {
			rec := reachable_daemon_records[i]
			if wrote > 0 do strings.write_string(&b, `,`)
			federation_peer_record_json(&b, rec)
			wrote += 1
		}
		sync.mutex_unlock(&reachable_daemon_mutex)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

federation_agent_is_advertised :: proc(agent_instance_id: string) -> bool {
	// Empty allow-list means "advertise all" (all agents that already pass the
	// scope/role filters in federation_advertised_agents_json). A non-empty list
	// is an explicit allow-list restricting advertisement to those ids.
	has_allow_entry := false
	for allowed in server_config.daemon.federation_advertised_agent_instance_ids {
		if strings.trim_space(allowed) == "" do continue
		has_allow_entry = true
		if strings.trim_space(allowed) == agent_instance_id do return true
	}
	return !has_allow_entry
}

federation_advertised_agents_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","version":"`)
	json_write_string(&b, contracts.APP_VERSION)
	strings.write_string(&b, `","agents":[`)
	wrote := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if agent_scope_normalize(rec.agent_scope) != AGENT_SCOPE_DURABLE do continue
		if rec.agent_role == "conversation" do continue
		if !federation_agent_is_advertised(rec.agent_instance_id) do continue
		if wrote > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"agent_instance_id":"`); json_write_string(&b, rec.agent_instance_id)
		strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
		strings.write_string(&b, `","native_id":"`); json_write_string(&b, rec.agent_instance_id)
		strings.write_string(&b, `","display_name":"`); json_write_string(&b, rec.display_name)
		strings.write_string(&b, `","template_id":"`); json_write_string(&b, rec.template_id)
		strings.write_string(&b, `","agent_role":"`); json_write_string(&b, rec.agent_role)
		strings.write_string(&b, `","provider_profile":"`); json_write_string(&b, rec.provider_profile)
		strings.write_string(&b, `","model_tier":"`); json_write_string(&b, normalize_model_tier(rec.model_tier))
		strings.write_string(&b, `","identity_state":"`); json_write_string(&b, agent_record_identity_state(rec))
		strings.write_string(&b, `"}`)
		wrote += 1
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

handle_get_federation_agents :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	peer_token := query_param_value(ctx.query, "peer_token")
	peer_daemon_id := query_param_value(ctx.query, "peer_daemon_id")
	if !peer_link_validate_request(peer_token, peer_daemon_id) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	write_response(client, 200, "OK", federation_advertised_agents_json())
}

federation_remote_proxy_bind :: proc(peer_id, origin_daemon_id, remote_agent_instance_id, display_name, template_id, provider_profile, model_tier, agent_role: string) -> (Agent_Instance_Record, bool, string) {
	resolved_peer_id, bridge_daemon_id, _, found := federation_direct_peer_lookup(peer_id, origin_daemon_id)
	if !found || strings.trim_space(resolved_peer_id) == "" {
		return Agent_Instance_Record{}, false, "peer not found"
	}
	remote_id := strings.trim_space(remote_agent_instance_id)
	if remote_id == "" do return Agent_Instance_Record{}, false, "remote_agent_instance_id required"
	resolved_origin_daemon_id := strings.trim_space(origin_daemon_id)
	if resolved_origin_daemon_id == "" do resolved_origin_daemon_id = strings.trim_space(bridge_daemon_id)
	if resolved_origin_daemon_id != "" {
		if existing, ok := agent_remote_proxy_find_absolute(resolved_origin_daemon_id, remote_id); ok {
			if strings.trim_space(existing.remote_origin_daemon_id) == "" {
				_, _, backfill_ok := agent_record_upsert(existing.agent_instance_id, existing.display_name, existing.template_id, existing.provider_profile, existing.project_id, existing.run_dir, existing.model_tier, existing.state, existing.agent_scope, existing.agent_role, false, existing.agent_kind, existing.remote_peer_id, resolved_origin_daemon_id, existing.remote_agent_instance_id)
				if backfill_ok {
					if idx := agent_record_index(existing.agent_record_id); idx >= 0 do return agent_instance_records[idx], true, ""
				}
			}
			return existing, true, ""
		}
	}
	if existing, ok := agent_remote_proxy_find(resolved_peer_id, remote_id); ok {
		if resolved_origin_daemon_id != "" && strings.trim_space(existing.remote_origin_daemon_id) == "" {
			_, _, backfill_ok := agent_record_upsert(existing.agent_instance_id, existing.display_name, existing.template_id, existing.provider_profile, existing.project_id, existing.run_dir, existing.model_tier, existing.state, existing.agent_scope, existing.agent_role, false, existing.agent_kind, existing.remote_peer_id, resolved_origin_daemon_id, existing.remote_agent_instance_id)
			if backfill_ok {
				if idx := agent_record_index(existing.agent_record_id); idx >= 0 do return agent_instance_records[idx], true, ""
			}
		}
		return existing, true, ""
	}
	local_display_name := strings.trim_space(display_name)
	if local_display_name == "" do local_display_name = remote_id
	local_template_id := strings.trim_space(template_id)
	if local_template_id == "" do local_template_id = derive_agent_class(remote_id)
	local_role := strings.trim_space(agent_role)
	if local_role == "" do local_role = agent_role_from_template(local_template_id)
	local_provider := strings.trim_space(provider_profile)
	if local_provider == "" do local_provider = agent_resolve_provider_profile("")
	local_tier := normalize_model_tier(model_tier)
	local_id := agent_generated_instance_id(fmt.tprintf("%s-%s", remote_id, resolved_peer_id))
	rec_id, _, ok := agent_record_upsert(local_id, local_display_name, local_template_id, local_provider, "", "", local_tier, AGENT_IDENTITY_STATE_PROVISIONED, AGENT_SCOPE_DURABLE, local_role, false, AGENT_KIND_REMOTE_PROXY, resolved_peer_id, resolved_origin_daemon_id, remote_id)
	if !ok || rec_id == "" {
		return Agent_Instance_Record{}, false, "failed to persist remote proxy"
	}
	idx := agent_record_index(rec_id)
	if idx < 0 do return Agent_Instance_Record{}, false, "remote proxy not found after save"
	return agent_instance_records[idx], true, ""
}

handle_get_federation_peers :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	write_response(client, 200, "OK", federation_peers_list_json())
}

handle_post_federation_reachability :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	if strings.trim_space(server_config.daemon.bridge_token) == "" || ctx.token != server_config.daemon.bridge_token {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"bridge reachability push unauthorized"}`)
		return
	}
	changed := reachable_daemon_apply_body(body, true)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"changed_count":`); strings.write_string(&b, fmt.tprintf("%d", changed))
	strings.write_string(&b, `}`)
	write_response(client, 202, "Accepted", strings.to_string(b))
}

handle_post_federation_proxy_bind :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	rec, bind_ok, message := federation_remote_proxy_bind(
		peer_id_normalize(extract_json_string(body, "peer_id", "")),
		extract_json_string(body, "origin_daemon_id", ""),
		extract_json_string(body, "remote_agent_instance_id", ""),
		extract_json_string(body, "display_name", ""),
		extract_json_string(body, "template_id", ""),
		extract_json_string(body, "provider_profile", ""),
		extract_json_string(body, "model_tier", "normal"),
		extract_json_string(body, "agent_role", extract_json_string(body, "role", "")),
	)
	if !bind_ok {
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":false,"message":"`)
		json_write_string(&b, message)
		strings.write_string(&b, `"}`)
		write_response(client, 400, "Bad Request", strings.to_string(b))
		return
	}
	write_agent_ok_response(client, "remote proxy bound", rec)
}

handle_post_federation_peer_link :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	_ = body
	write_response(client, 410, "Gone", `{"ok":false,"message":"peer link endpoint moved to ham-bridge config"}`)
}

handle_post_federation_peer_reconnect :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	_ = body
	write_response(client, 410, "Gone", `{"ok":false,"message":"peer reconnect moved to ham-bridge websocket dialer"}`)
}

handle_post_federation_peer_remove :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	_ = body
	write_response(client, 410, "Gone", `{"ok":false,"message":"peer removal moved to ham-bridge config"}`)
}

handle_get_federation_peer_agents :: proc(client: net.TCP_Socket, peer_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	_ = peer_id
	write_response(client, 410, "Gone", `{"ok":false,"message":"peer agent discovery moved to ham-bridge"}`)
}
