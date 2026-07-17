package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "core:net"
import contracts "odin_test:contracts"
import http "odin_test:lib/http_client"
import config_lib "odin_test:lib/config"

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

peer_link_store_init :: proc(data_dir: string, config_peers: []config_lib.Peer_Config) {
	peer_link_record_count = 0
	peer_link_event_count = 0
	peer_link_store_sequence = 0
	peer_link_store_dir = strings.clone(fmt.tprintf("%s/federation", expand_home(data_dir)))
	peer_link_events_path = strings.clone(fmt.tprintf("%s/peer-links.jsonl", peer_link_store_dir))
	_ = os.make_directory_all(peer_link_store_dir)
	peer_link_store_replay()
	for cfg in config_peers {
		peer_id := peer_id_normalize(cfg.name)
		peer_url := peer_url_normalize(cfg.endpoint)
		peer_token := strings.trim_space(cfg.token)
		if peer_id == "" || peer_url == "" || peer_token == "" do continue
		_, _, _ = peer_link_create_or_update(peer_id, peer_url, peer_token, "config_bootstrap")
	}
	peer_link_poll_start()
}

peer_link_poll_start :: proc() {
	if peer_link_poll_started do return
	peer_link_poll_started = true
	thread.run(peer_link_poll_worker)
}

peer_link_poll_worker :: proc() {
	for {
		peer_link_probe_all()
		time.sleep(30 * time.Second)
	}
}

peer_link_probe_all :: proc() {
	for i in 0..<peer_link_record_count {
		if peer_link_records[i].removed_at_unix_ms != 0 do continue
		peer_link_probe(peer_link_records[i].peer_id)
	}
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
		if strings.trim_space(rec.daemon_id) == trimmed_daemon_id do return rec, true
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
		if rec.daemon_id != trimmed_daemon_id do continue
		return true
	}
	return false
}

peer_link_probe :: proc(peer_id: string) -> bool {
	rec, ok := peer_link_find(peer_id)
	if !ok do return false
	was_linked := rec.status == PEER_STATUS_LINKED
	now := router_now_unix_ms()
	health, health_ok := http.get_with_timeout(rec.peer_url, "/health", FEDERATION_HTTP_TIMEOUT_MS)
	if !health_ok || health.status != 200 {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.daemon_id = ""
		rec.version = ""
		rec.last_checked_unix_ms = now
		return false
	}
	info, info_ok := http.get_with_timeout(rec.peer_url, "/daemon/info", FEDERATION_HTTP_TIMEOUT_MS)
	if !info_ok || info.status != 200 {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.daemon_id = ""
		rec.version = ""
		rec.last_checked_unix_ms = now
		return false
	}
	daemon_id := extract_json_string(info.body, "daemon_id", "")
	version := extract_json_string(info.body, "version", "")
	if daemon_id == "" {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.daemon_id = ""
		rec.version = ""
		rec.last_checked_unix_ms = now
		return false
	}
	rec.status = strings.clone(PEER_STATUS_LINKED)
	rec.daemon_id = strings.clone(daemon_id)
	rec.version = strings.clone(version)
	rec.last_checked_unix_ms = now
	if !was_linked {
		for i in 0..<agent_instance_record_count {
			agent := agent_instance_records[i]
			if !agent_record_is_remote_proxy(agent) do continue
			if agent.remote_peer_id != peer_id do continue
			_ = notification_outbox_replay_pending(agent.agent_instance_id)
		}
		_ = federation_delivery_outbox_replay_peer(peer_id)
	}
	return true
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

federation_peer_record_json :: proc(builder: ^strings.Builder, rec: Peer_Link_Record) {
	strings.write_string(builder, `{"peer_record_id":"`); json_write_string(builder, rec.peer_record_id)
	strings.write_string(builder, `","peer_id":"`); json_write_string(builder, rec.peer_id)
	strings.write_string(builder, `","peer_url":"`); json_write_string(builder, rec.peer_url)
	strings.write_string(builder, `","daemon_id":"`); json_write_string(builder, rec.daemon_id)
	strings.write_string(builder, `","version":"`); json_write_string(builder, rec.version)
	status := rec.status
	if status == "" do status = PEER_STATUS_UNREACHABLE
	strings.write_string(builder, `","status":"`); json_write_string(builder, status)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"last_checked_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.last_checked_unix_ms))
	strings.write_string(builder, `}`)
}

federation_peers_list_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"peers":[`)
	wrote := 0
	for i in 0..<peer_link_record_count {
		rec := peer_link_records[i]
		if rec.removed_at_unix_ms != 0 do continue
		if wrote > 0 do strings.write_string(&b, `,`)
		federation_peer_record_json(&b, rec)
		wrote += 1
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
	rec, found := peer_link_find(peer_id)
	if !found || rec.peer_id == "" {
		return Agent_Instance_Record{}, false, "peer not found"
	}
	remote_id := strings.trim_space(remote_agent_instance_id)
	if remote_id == "" do return Agent_Instance_Record{}, false, "remote_agent_instance_id required"
	resolved_origin_daemon_id := strings.trim_space(origin_daemon_id)
	if resolved_origin_daemon_id == "" do resolved_origin_daemon_id = strings.trim_space(rec.daemon_id)
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
	if existing, ok := agent_remote_proxy_find(peer_id, remote_id); ok {
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
	local_id := agent_generated_instance_id(fmt.tprintf("%s-%s", remote_id, peer_id))
	rec_id, _, ok := agent_record_upsert(local_id, local_display_name, local_template_id, local_provider, "", "", local_tier, AGENT_IDENTITY_STATE_PROVISIONED, AGENT_SCOPE_DURABLE, local_role, false, AGENT_KIND_REMOTE_PROXY, peer_id, resolved_origin_daemon_id, remote_id)
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
	author, ok := rest_authorize_user(client, ctx)
	if !ok do return
	rec, save_ok, message := peer_link_create_or_update(
		extract_json_string(body, "peer_id", extract_json_string(body, "name", "")),
		extract_json_string(body, "peer_url", extract_json_string(body, "endpoint", "")),
		extract_json_string(body, "peer_token", extract_json_string(body, "token", "")),
		author,
	)
	if !save_ok {
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":false,"message":"`)
		json_write_string(&b, message)
		strings.write_string(&b, `"}`)
		write_response(client, 400, "Bad Request", strings.to_string(b))
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"peer":`)
	federation_peer_record_json(&b, rec)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_post_federation_peer_reconnect :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	peer_id := peer_id_normalize(extract_json_string(body, "peer_id", ""))
	rec, found := peer_link_find(peer_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"peer not found"}`)
		return
	}
	_ = peer_link_probe(peer_id)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"peer":`)
	federation_peer_record_json(&b, rec^)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_post_federation_peer_remove :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, ok := rest_authorize_user(client, ctx)
	if !ok do return
	peer_id := peer_id_normalize(extract_json_string(body, "peer_id", ""))
	if peer_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"peer_id required"}`)
		return
	}
	if !peer_link_remove(peer_id, author) {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"peer not found"}`)
		return
	}
	write_response(client, 200, "OK", `{"ok":true,"message":"removed"}`)
}

handle_get_federation_peer_agents :: proc(client: net.TCP_Socket, peer_id: string, ctx: ^Route_Context) {
	_, ok := rest_authorize_user(client, ctx)
	if !ok do return
	rec, found := peer_link_find(peer_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"peer not found"}`)
		return
	}
	path := fmt.tprintf("/federation/agents?peer_token=%s&peer_daemon_id=%s", rec.peer_token, server_daemon_id)
	resp, fetch_ok := http.get_with_timeout(rec.peer_url, path, FEDERATION_HTTP_TIMEOUT_MS)
	if !fetch_ok || resp.status != 200 {
		rec.status = strings.clone(PEER_STATUS_UNREACHABLE)
		rec.daemon_id = ""
		rec.version = ""
		rec.last_checked_unix_ms = router_now_unix_ms()
		write_response(client, 503, "Service Unavailable", `{"ok":false,"message":"peer unreachable"}`)
		return
	}
	rec.status = strings.clone(PEER_STATUS_LINKED)
	rec.last_checked_unix_ms = router_now_unix_ms()
	remote_daemon_id := extract_json_string(resp.body, "daemon_id", "")
	remote_version := extract_json_string(resp.body, "version", "")
	if remote_daemon_id != "" do rec.daemon_id = strings.clone(remote_daemon_id)
	if remote_version != "" do rec.version = strings.clone(remote_version)
	write_response(client, 200, "OK", resp.body)
}
