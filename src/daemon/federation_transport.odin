package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:strings"
import contracts "odin_test:contracts"
import http "odin_test:lib/http_client"
import mp "odin_test:lib/message_provider"

FEDERATION_ROUTE_INBOX :: "inbox"
FEDERATION_ROUTE_CALLBACK :: "callback"
FEDERATION_HTTP_TIMEOUT_MS :: 5000
FEDERATION_DEDUPE_SCOPE_INBOX :: "inbox"
FEDERATION_DEDUPE_SCOPE_CALLBACK :: "callback"
FEDERATION_ENVELOPE_NOTIFICATION :: "notification"
FEDERATION_ENVELOPE_INBOX_MESSAGE :: "inbox_message"
FEDERATION_ENVELOPE_READ_RECEIPT :: "read_receipt"
FEDERATION_ENVELOPE_TASK_COMMENT :: "comment"
FEDERATION_ENVELOPE_TASK_VOTE :: "vote"
FEDERATION_ENVELOPE_TASK_STATUS :: "status"
// Coordinator-authored administrative writes forwarded from an actor daemon (B)
// to the chain's owner daemon (A) when a local chain has a remote coordinator.
FEDERATION_ENVELOPE_TASK_CREATE :: "task_create"
FEDERATION_ENVELOPE_CHAIN_UPDATE :: "chain_update"
FEDERATION_ENVELOPE_TASK_ASSIGN :: "task_assign"
FEDERATION_ENVELOPE_USER_CHAT_MESSAGE :: "user_chat_message"
FEDERATION_ENVELOPE_USER_CHAT_REPLY :: "user_chat_reply"
FEDERATION_ENVELOPE_DELIVERY_ACK :: "delivery_ack"
FEDERATION_ENVELOPE_AGENT_STATUS :: "agent_status"
FEDERATION_REPLAY_LIMIT :: 100
FEDERATION_REPLAY_BACKOFF_MIN_MS :: i64(10 * 1000)
FEDERATION_REPLAY_BACKOFF_MAX_MS :: i64(5 * 60 * 1000)
FEDERATION_REPLAY_STUCK_ATTEMPTS :: 6

Federation_Remote_Message_Record :: struct {
	record_key: string,
	message_id: string,
	owner_peer_id: string,
	owner_daemon_id: string,
	local_agent_instance_id: string,
	remote_agent_instance_id: string,
	proxy_agent_instance_id: string,
	conversation_id: string,
	origin_conversation_id: string,
	body: string,
	body_available: bool,
	created_unix_ms: i64,
	read_unix_ms: i64,
}

federation_peer_id_for_request :: proc(peer_token, peer_daemon_id: string) -> (string, bool) {
	trimmed_token := strings.trim_space(peer_token)
	trimmed_daemon_id := strings.trim_space(peer_daemon_id)
	if trimmed_token == "" || trimmed_daemon_id == "" do return "", false
	for i in 0..<peer_link_record_count {
		rec := peer_link_records[i]
		if rec.removed_at_unix_ms != 0 do continue
		if rec.peer_token != trimmed_token do continue
		if rec.daemon_id != trimmed_daemon_id && rec.peer_id != trimmed_daemon_id do continue
		return strings.clone(rec.peer_id), true
	}
	return "", false
}

federation_peer_id_for_bridge_source :: proc(peer_daemon_id: string) -> (string, bool) {
	trimmed_daemon_id := strings.trim_space(peer_daemon_id)
	if trimmed_daemon_id == "" do return "", false
	if peer_id, _, _, ok := federation_direct_peer_lookup(trimmed_daemon_id, trimmed_daemon_id); ok do return peer_id, true
	return "", false
}

federation_peer_id_for_context :: proc(ctx: ^Route_Context) -> (string, string, bool) {
	if strings.trim_space(ctx.bridge_source_daemon_id) != "" {
		if peer_id, ok := federation_peer_id_for_bridge_source(ctx.bridge_source_daemon_id); ok {
			return peer_id, strings.clone(ctx.bridge_source_daemon_id), true
		}
	}
	peer_daemon_id := query_param_value(ctx.query, "peer_daemon_id")
	peer_id, ok := federation_peer_id_for_request(query_param_value(ctx.query, "peer_token"), peer_daemon_id)
	return peer_id, peer_daemon_id, ok
}

// Thin daemon -> ham-bridge loopback client.
//
// Result-state boundary (BR-4): bridge_send returning true means only that the
// local bridge accepted/queued the opaque payload for transport. It MUST NOT be
// treated as destination business success or as a durable outbox ACK. Durable
// completion is driven by the destination daemon acceptance callback/ACK path.
bridge_client_enabled :: proc() -> bool {
	return strings.trim_space(server_bridge_url) != ""
}

bridge_client_contract_routes_covered :: proc() -> bool {
	// Keep daemon bridge-client coverage tied to shared route constants so route
	// drift is caught by builds/smoke checks instead of duplicated string values.
	return contracts.bridge_loopback_route_supported(contracts.BRIDGE_HTTP_METHOD_POST, contracts.ROUTE_BRIDGE_SEND) &&
	       contracts.bridge_loopback_route_supported(contracts.BRIDGE_HTTP_METHOD_POST, contracts.ROUTE_BRIDGE_REQUEST) &&
	       contracts.bridge_loopback_route_supported(contracts.BRIDGE_HTTP_METHOD_GET, contracts.ROUTE_BRIDGE_REACHABLE) &&
	       contracts.bridge_loopback_route_supported(contracts.BRIDGE_HTTP_METHOD_GET, contracts.ROUTE_BRIDGE_HEALTH)
}

bridge_client_headers :: proc() -> []http.Header {
	headers := make([dynamic]http.Header)
	if strings.trim_space(server_config.daemon.bridge_token) != "" {
		append(&headers, http.Header{name = contracts.BRIDGE_LOOPBACK_AUTH_HEADER, value = strings.concatenate({contracts.BRIDGE_AUTH_BEARER_PREFIX, server_config.daemon.bridge_token})})
	}
	return headers[:]
}

bridge_send_route_kind :: proc(route_kind: string) -> string {
	if route_kind == FEDERATION_ROUTE_CALLBACK do return contracts.BRIDGE_SEND_ROUTE_FEDERATION_CALLBACK
	return contracts.BRIDGE_SEND_ROUTE_FEDERATION_INBOX
}

bridge_send :: proc(dest_daemon_id, route_kind, payload, idempotency_key: string) -> bool {
	if !bridge_client_enabled() do return false
	if !bridge_client_contract_routes_covered() do return false
	b := strings.builder_make()
	strings.write_string(&b, `{"contract_version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"src_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"`); json_write_string(&b, dest_daemon_id)
	strings.write_string(&b, `","route_kind":"`); json_write_string(&b, bridge_send_route_kind(route_kind))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","payload":"`); json_write_string(&b, payload)
	strings.write_string(&b, `","created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", router_now_unix_ms()))
	strings.write_string(&b, `}`)
	resp, ok := http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_POST, server_bridge_url, contracts.ROUTE_BRIDGE_SEND, strings.to_string(b), bridge_client_headers(), FEDERATION_HTTP_TIMEOUT_MS)
	if !ok || (resp.status != 200 && resp.status != 202) do return false
	acceptance := extract_json_string(resp.body, "acceptance", "")
	return acceptance == contracts.BRIDGE_SEND_ACCEPTANCE_ACCEPTED_QUEUED || acceptance == contracts.BRIDGE_SEND_ACCEPTANCE_DUPLICATE_QUEUED
}

bridge_request :: proc(dest_daemon_id, method, path, body, idempotency_key: string, timeout_ms: int) -> (http.Response, bool) {
	if !bridge_client_enabled() do return http.Response{}, false
	if !bridge_client_contract_routes_covered() do return http.Response{}, false

	actual_path := path
	if rec, found := peer_link_find_by_daemon_id(dest_daemon_id); found {
		sep := "?" if strings.index_byte(path, '?') < 0 else "&"
		actual_path = fmt.tprintf("%s%speer_token=%s&peer_daemon_id=%s", path, sep, rec.peer_token, server_daemon_id)
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"contract_version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"src_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"`); json_write_string(&b, dest_daemon_id)
	strings.write_string(&b, `","method":"`); json_write_string(&b, method)
	strings.write_string(&b, `","path":"`); json_write_string(&b, actual_path)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","body":"`); json_write_string(&b, body)
	strings.write_string(&b, `","timeout_ms":`); strings.write_string(&b, fmt.tprintf("%d", timeout_ms))
	strings.write_string(&b, `}`)
	resp, ok := http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_POST, server_bridge_url, contracts.ROUTE_BRIDGE_REQUEST, strings.to_string(b), bridge_client_headers(), timeout_ms)
	if !ok do return http.Response{}, false
	result_kind := extract_json_string(resp.body, "result_kind", "")
	if result_kind != contracts.BRIDGE_RESULT_DESTINATION_DAEMON_HTTP_RESPONSE do return resp, false
	status_code := extract_json_int(resp.body, "status_code", resp.status)
	return http.Response{status = status_code, body = extract_json_string(resp.body, "body", resp.body)}, true
}

registry_send_ws_text_or_remote :: proc(agent_instance_id, text: string) -> bool {
	if peer_id, remote_agent_instance_id, ok := agent_remote_proxy_lookup(agent_instance_id); ok {
		idempotency_key := extract_json_string(text, "event_id", "")
		if idempotency_key == "" do idempotency_key = notification_outbox_payload_event_id(agent_instance_id, text)
		payload := federation_inbox_notification_json(remote_agent_instance_id, text, idempotency_key)
		return federation_forward(peer_id, FEDERATION_ROUTE_INBOX, payload, idempotency_key)
	}
	return registry_send_ws_text(agent_instance_id, text)
}

registry_send_ws_text_or_remote_transport_accepted :: proc(agent_instance_id, text: string) -> bool {
	if peer_id, remote_agent_instance_id, ok := agent_remote_proxy_lookup(agent_instance_id); ok {
		idempotency_key := extract_json_string(text, "event_id", "")
		if idempotency_key == "" do idempotency_key = notification_outbox_payload_event_id(agent_instance_id, text)
		payload := federation_inbox_notification_json(remote_agent_instance_id, text, idempotency_key)
		return federation_forward_transport_accepted(peer_id, FEDERATION_ROUTE_INBOX, payload, idempotency_key)
	}
	return registry_send_ws_text(agent_instance_id, text)
}

federation_forward_transport_accepted :: proc(peer_id, route_kind, payload, idempotency_key: string) -> bool {
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok || status != PEER_STATUS_LINKED do return false
	if dest_daemon_id == "" || !bridge_send(dest_daemon_id, route_kind, payload, idempotency_key) do return false
	return true
}

federation_forward :: proc(peer_id, route_kind, payload, idempotency_key: string) -> bool {
	// BR-4: local bridge accepted/queued is only a transport attempt state.
	// The daemon durable outbox stays pending until the destination daemon's
	// acceptance is returned as a delivery_ack callback.
	_ = federation_forward_transport_accepted(peer_id, route_kind, payload, idempotency_key)
	return false
}

// federation_forward_start asks the owning peer to start the real agent that a
// local remote_proxy stands in for. Returns (ok, status_code, response_body).
// Synchronous request/response (not the delivery outbox) so the operator/UI gets
// immediate feedback on whether the remote start succeeded.
federation_forward_start :: proc(peer_id, remote_agent_instance_id, provider_profile, model_tier: string, proxy_agent_instance_id: string = "") -> (bool, int, string) {
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok do return false, 404, `{"ok":false,"message":"peer not found"}`
	if status != PEER_STATUS_LINKED {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"agent_instance_id":"`)
	json_write_string(&b, remote_agent_instance_id)
	if provider_profile != "" {
		strings.write_string(&b, `","provider_profile":"`)
		json_write_string(&b, provider_profile)
	}
	if model_tier != "" {
		strings.write_string(&b, `","model_tier":"`)
		json_write_string(&b, model_tier)
	}
	// Carry the caller's proxy id so the origin can register this peer as a
	// status subscriber for the real agent (Part B reverse subscriber index).
	if proxy_agent_instance_id != "" {
		strings.write_string(&b, `","proxy_agent_instance_id":"`)
		json_write_string(&b, proxy_agent_instance_id)
	}
	strings.write_string(&b, `"}`)
	payload := strings.to_string(b)
	path := contracts.ROUTE_FEDERATION_START
	if dest_daemon_id == "" {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	resp, forward_ok := bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_POST, path, payload, federation_idempotency_key("start", server_daemon_id, remote_agent_instance_id), FEDERATION_HTTP_TIMEOUT_MS)
	if !forward_ok {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	return resp.status == 200, resp.status, strings.clone(resp.body)
}

// federation_forward_subscribe registers this daemon's remote_proxy as a status
// subscriber on the owning peer and asks it to push one current-status snapshot
// back, without starting or stopping the real agent. This is the bind-time
// handshake that makes proxies for already-running remote agents report their
// live status immediately instead of sitting at an empty status until the next
// origin-side transition happens to be pushed. Best-effort: returns ok=false on
// unreachable peers so callers can ignore the result during passive binds.
federation_forward_subscribe :: proc(peer_id, remote_agent_instance_id, proxy_agent_instance_id: string) -> (bool, int, string) {
	if peer_id == "" || remote_agent_instance_id == "" || proxy_agent_instance_id == "" {
		return false, 400, `{"ok":false,"message":"peer_id, remote_agent_instance_id and proxy_agent_instance_id required"}`
	}
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok do return false, 404, `{"ok":false,"message":"peer not found"}`
	if status != PEER_STATUS_LINKED {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	if dest_daemon_id == "" {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"agent_instance_id":"`)
	json_write_string(&b, remote_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `"}`)
	payload := strings.to_string(b)
	resp, forward_ok := bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_POST, contracts.ROUTE_FEDERATION_SUBSCRIBE, payload, federation_idempotency_key("subscribe", server_daemon_id, proxy_agent_instance_id), FEDERATION_HTTP_TIMEOUT_MS)
	if !forward_ok {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	return resp.status == 200, resp.status, strings.clone(resp.body)
}

// federation_resubscribe_proxies_for_peer re-issues the subscribe handshake for
// every local remote_proxy whose owning peer is `peer_id`. Called on peer link
// (re)connect so that if the ORIGIN daemon restarted (wiping its in-memory
// subscriber index) each proxy re-registers and pulls a fresh status snapshot.
// Best-effort and idempotent on the origin. Returns the number of subscribes
// attempted. Snapshots the target ids first so the send loop does not hold any
// implicit store invariants across bridge I/O.
federation_resubscribe_proxies_for_peer :: proc(peer_id: string) -> int {
	if peer_id == "" do return 0
	Target :: struct { remote_agent_instance_id, proxy_agent_instance_id: string }
	targets := make([dynamic]Target)
	defer {
		for t in targets { delete(t.remote_agent_instance_id); delete(t.proxy_agent_instance_id) }
		delete(targets)
	}
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if !agent_record_is_remote_proxy(rec) do continue
		if rec.remote_peer_id != peer_id do continue
		if rec.remote_agent_instance_id == "" || rec.agent_instance_id == "" do continue
		append(&targets, Target{
			remote_agent_instance_id = strings.clone(rec.remote_agent_instance_id),
			proxy_agent_instance_id = strings.clone(rec.agent_instance_id),
		})
	}
	attempted := 0
	for t in targets {
		_, _, _ = federation_forward_subscribe(peer_id, t.remote_agent_instance_id, t.proxy_agent_instance_id)
		attempted += 1
	}
	return attempted
}

// federation_forward_stop asks the owning peer to stop the real agent that a
// local remote_proxy stands in for. Mirrors federation_forward_start: synchronous
// request/response over the bridge so the operator/UI gets immediate feedback on
// whether the remote stop succeeded. Returns (ok, status_code, response_body).
federation_forward_stop :: proc(peer_id, remote_agent_instance_id: string, time_in_sec: int, proxy_agent_instance_id: string = "") -> (bool, int, string) {
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok do return false, 404, `{"ok":false,"message":"peer not found"}`
	if status != PEER_STATUS_LINKED {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	if dest_daemon_id == "" {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"agent_instance_id":"`)
	json_write_string(&b, remote_agent_instance_id)
	strings.write_string(&b, `","time_in_sec":`)
	strings.write_string(&b, fmt.tprintf("%d", time_in_sec))
	if proxy_agent_instance_id != "" {
		strings.write_string(&b, `,"proxy_agent_instance_id":"`)
		json_write_string(&b, proxy_agent_instance_id)
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, `}`)
	payload := strings.to_string(b)
	resp, forward_ok := bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_POST, contracts.ROUTE_FEDERATION_STOP, payload, federation_idempotency_key("stop", server_daemon_id, remote_agent_instance_id), FEDERATION_HTTP_TIMEOUT_MS)
	if !forward_ok {
		return false, 503, `{"ok":false,"message":"peer unreachable"}`
	}
	return resp.status == 200, resp.status, strings.clone(resp.body)
}


federation_user_chat_synthetic_user_id :: proc(origin_daemon_id, proxy_agent_instance_id, origin_user_id: string) -> string {
	return fmt.tprintf("fed.%s.%s.%s", strings.trim_space(origin_daemon_id), strings.trim_space(proxy_agent_instance_id), strings.trim_space(origin_user_id))
}

federation_user_chat_parse_synthetic_user_id :: proc(user_id: string) -> (origin_daemon_id, proxy_agent_instance_id, origin_user_id: string, ok: bool) {
	trimmed := strings.trim_space(user_id)
	if !strings.has_prefix(trimmed, "fed.") do return "", "", "", false
	rest := trimmed[len("fed."):]
	first_dot := strings.index_byte(rest, '.')
	if first_dot <= 0 do return "", "", "", false
	origin := rest[:first_dot]
	rest2 := rest[first_dot + 1:]
	second_dot := strings.index_byte(rest2, '.')
	if second_dot <= 0 do return "", "", "", false
	proxy := rest2[:second_dot]
	origin_user := rest2[second_dot + 1:]
	if origin == "" || proxy == "" || origin_user == "" do return "", "", "", false
	return strings.clone(origin), strings.clone(proxy), strings.clone(origin_user), true
}

federation_user_chat_message_json :: proc(idempotency_key, origin_message_id, origin_user_id, synthetic_user_id, target_agent_instance_id, proxy_agent_instance_id, body: string, interrupt: bool, created_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"`); json_write_string(&b, FEDERATION_ENVELOPE_USER_CHAT_MESSAGE)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_message_id":"`); json_write_string(&b, origin_message_id)
	strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","origin_user_id":"`); json_write_string(&b, origin_user_id)
	strings.write_string(&b, `","synthetic_user_id":"`); json_write_string(&b, synthetic_user_id)
	strings.write_string(&b, `","target_agent_instance_id":"`); json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`); json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","body":"`); json_write_string(&b, body)
	strings.write_string(&b, `","interrupt":`); strings.write_string(&b, interrupt ? "true" : "false")
	strings.write_string(&b, `,"created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_user_chat_reply_json :: proc(idempotency_key, message_id, origin_user_id, proxy_agent_instance_id, from_agent_instance_id, body, chain_id: string, created_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"`); json_write_string(&b, FEDERATION_ENVELOPE_USER_CHAT_REPLY)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","message_id":"`); json_write_string(&b, message_id)
	strings.write_string(&b, `","origin_user_id":"`); json_write_string(&b, origin_user_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`); json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`); json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","body":"`); json_write_string(&b, body)
	strings.write_string(&b, `","chain_id":"`); json_write_string(&b, chain_id)
	strings.write_string(&b, `","created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_user_chat_send_to_remote_proxy :: proc(user_id, proxy_agent_instance_id, body: string, interrupt: bool) -> (message_id: string, fanout_count: int, ok: bool, status_code: int, message: string) {
	peer_id, origin_daemon_id, remote_agent_instance_id, mapped := agent_remote_proxy_identity_lookup(proxy_agent_instance_id)
	if !mapped do return "", 0, false, 404, "unknown remote proxy"
	if origin_daemon_id == "" {
		_, resolved_daemon_id, _, found := federation_direct_peer_lookup(peer_id, "")
		if found do origin_daemon_id = resolved_daemon_id
	}
	if origin_daemon_id == "" do origin_daemon_id = peer_id
	stored: bool
	message_id, stored = chat_store_append_message(user_id, proxy_agent_instance_id, "user_to_agent", body, interrupt)
	if !stored || message_id == "" do return "", 0, false, 500, "append chat failed"
	fanout_count = chat_event_fanout(user_id, proxy_agent_instance_id, message_id, "user_to_agent")
	created_unix_ms := chat_message_created(message_id)
	if created_unix_ms == 0 do created_unix_ms = router_now_unix_ms()
	idempotency_key := federation_idempotency_key("user_chat", server_daemon_id, message_id)
	synthetic_user_id := federation_user_chat_synthetic_user_id(server_daemon_id, proxy_agent_instance_id, user_id)
	payload := federation_user_chat_message_json(idempotency_key, message_id, user_id, synthetic_user_id, remote_agent_instance_id, proxy_agent_instance_id, body, interrupt, created_unix_ms)
	_ = federation_delivery_outbox_insert_pending(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key, payload)
	accepted := bridge_send(origin_daemon_id, FEDERATION_ROUTE_INBOX, payload, idempotency_key)
	_ = federation_delivery_outbox_mark_attempt(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key, accepted)
	if accepted do _ = chat_mark_delivered_and_fanout(user_id, proxy_agent_instance_id, message_id, "user_to_agent")
	return message_id, fanout_count, true, 200, "ok"
}

federation_user_chat_reply_to_origin :: proc(agent_instance_id, user_id, body, chain_id: string) -> (message_id: string, routed: bool, ok: bool) {
	origin_daemon_id, proxy_agent_instance_id, origin_user_id, parsed := federation_user_chat_parse_synthetic_user_id(user_id)
	if !parsed do return "", false, false
	stored: bool
	message_id, stored = chat_store_append_message_with_chain(user_id, agent_instance_id, "agent_to_user", body, false, chain_id)
	if !stored || message_id == "" do return "", true, false
	created_unix_ms := chat_message_created(message_id)
	if created_unix_ms == 0 do created_unix_ms = router_now_unix_ms()
	idempotency_key := federation_idempotency_key("user_chat_reply", server_daemon_id, message_id)
	payload := federation_user_chat_reply_json(idempotency_key, message_id, origin_user_id, proxy_agent_instance_id, agent_instance_id, body, chain_id, created_unix_ms)
	accepted := bridge_send(origin_daemon_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
	return message_id, true, accepted
}

federation_delivery_outbox_insert_pending :: proc(peer_id, route_kind, idempotency_key, payload: string) -> bool {
	if peer_id == "" || route_kind == "" || idempotency_key == "" || payload == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO federation_delivery_outbox (
		peer_id, route_kind, idempotency_key, payload, created_unix_ms,
		delivered_unix_ms, attempts, last_attempt_unix_ms
	) VALUES (?, ?, ?, ?, ?, 0, 0, 0)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	task_db_bind_text(stmt, 2, route_kind)
	task_db_bind_text(stmt, 3, idempotency_key)
	task_db_bind_text(stmt, 4, payload)
	sqlite3_bind_int64(stmt, 5, router_now_unix_ms())
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_delivery_outbox_mark_attempt :: proc(peer_id, route_kind, idempotency_key: string, delivered: bool) -> bool {
	if peer_id == "" || route_kind == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `UPDATE federation_delivery_outbox
		SET attempts = attempts + 1,
		    last_attempt_unix_ms = ?,
		    delivered_unix_ms = CASE WHEN ? != 0 THEN ? ELSE delivered_unix_ms END
		WHERE peer_id = ? AND route_kind = ? AND idempotency_key = ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	now := router_now_unix_ms()
	sqlite3_bind_int64(stmt, 1, now)
	sqlite3_bind_int64(stmt, 2, 1 if delivered else 0)
	sqlite3_bind_int64(stmt, 3, now)
	task_db_bind_text(stmt, 4, peer_id)
	task_db_bind_text(stmt, 5, route_kind)
	task_db_bind_text(stmt, 6, idempotency_key)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_delivery_outbox_mark_delivered_by_ack :: proc(peer_id, route_kind, idempotency_key: string) -> bool {
	return federation_delivery_outbox_mark_attempt(peer_id, route_kind, idempotency_key, true)
}

federation_delivery_outbox_pending_exists :: proc(peer_id, route_kind, idempotency_key: string) -> bool {
	if peer_id == "" || route_kind == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `SELECT 1 FROM federation_delivery_outbox WHERE peer_id = ? AND route_kind = ? AND idempotency_key = ? AND delivered_unix_ms = 0 LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	task_db_bind_text(stmt, 2, route_kind)
	task_db_bind_text(stmt, 3, idempotency_key)
	return sqlite3_step(stmt) == SQLITE_ROW
}

federation_delivery_outbox_retry_backoff_ms :: proc(attempts: int) -> i64 {
	if attempts <= 0 do return 0
	backoff_ms := FEDERATION_REPLAY_BACKOFF_MIN_MS
	for _ in 1..<attempts {
		if backoff_ms >= FEDERATION_REPLAY_BACKOFF_MAX_MS do return FEDERATION_REPLAY_BACKOFF_MAX_MS
		backoff_ms *= 2
		if backoff_ms > FEDERATION_REPLAY_BACKOFF_MAX_MS do backoff_ms = FEDERATION_REPLAY_BACKOFF_MAX_MS
	}
	return backoff_ms
}

federation_delivery_outbox_retry_eligible :: proc(attempts: int, last_attempt_unix_ms, now_unix_ms: i64) -> bool {
	if attempts <= 0 || last_attempt_unix_ms <= 0 do return true
	return now_unix_ms - last_attempt_unix_ms >= federation_delivery_outbox_retry_backoff_ms(attempts)
}

federation_delivery_outbox_log_stuck :: proc(peer_id, route_kind, idempotency_key: string, attempts: int, created_unix_ms, last_attempt_unix_ms, now_unix_ms, backoff_ms: i64) {
	age_ms := now_unix_ms - created_unix_ms
	fmt.printfln("FEDERATION_OUTBOX_STUCK ts_unix_ms=%d peer_id=%s route_kind=%s idempotency_key=%s attempts=%d age_ms=%d last_attempt_unix_ms=%d backoff_ms=%d", now_unix_ms, peer_id, route_kind, idempotency_key, attempts, age_ms, last_attempt_unix_ms, backoff_ms)
}

federation_delivery_outbox_drop_pending_agent_status :: proc(peer_id: string) -> bool {
	if peer_id == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `DELETE FROM federation_delivery_outbox
		WHERE peer_id = ? AND route_kind = ? AND delivered_unix_ms = 0 AND idempotency_key LIKE 'agent_status:%'`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	task_db_bind_text(stmt, 2, FEDERATION_ROUTE_CALLBACK)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_delivery_outbox_replay_peer :: proc(peer_id: string) -> int {
	if peer_id == "" || !task_db_ready do return 0
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup_cached(peer_id, "")
	if !ok || status != PEER_STATUS_LINKED || dest_daemon_id == "" do return 0
	// Agent status is a lossy/coalesced projection, not business state. Drop stale
	// pending status rows before replay so a previous bug cannot drain thousands of
	// old idle/working transitions on reconnect; federation_agent_status_resync_peer
	// sends one fresh current snapshot after reachability replay.
	_ = federation_delivery_outbox_drop_pending_agent_status(peer_id)
	route_kinds := make([dynamic]string)
	idempotency_keys := make([dynamic]string)
	payloads := make([dynamic]string)
	created_unix_ms := make([dynamic]i64)
	attempts := make([dynamic]int)
	last_attempt_unix_ms := make([dynamic]i64)
	defer {
		for v in route_kinds do delete(v)
		for v in idempotency_keys do delete(v)
		for v in payloads do delete(v)
		delete(route_kinds)
		delete(idempotency_keys)
		delete(payloads)
		delete(created_unix_ms)
		delete(attempts)
		delete(last_attempt_unix_ms)
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT route_kind, idempotency_key, payload, created_unix_ms, attempts, last_attempt_unix_ms
		FROM federation_delivery_outbox
		WHERE peer_id = ? AND delivered_unix_ms = 0
		ORDER BY created_unix_ms ASC, idempotency_key ASC
		LIMIT ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return 0
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, peer_id)
	sqlite3_bind_int64(stmt, 2, FEDERATION_REPLAY_LIMIT)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&route_kinds, strings.clone_from_cstring(sqlite3_column_text(stmt, 0)))
		append(&idempotency_keys, strings.clone_from_cstring(sqlite3_column_text(stmt, 1)))
		append(&payloads, strings.clone_from_cstring(sqlite3_column_text(stmt, 2)))
		append(&created_unix_ms, sqlite3_column_int64(stmt, 3))
		append(&attempts, int(sqlite3_column_int64(stmt, 4)))
		append(&last_attempt_unix_ms, sqlite3_column_int64(stmt, 5))
	}
	accepted_count := 0
	for i in 0..<len(route_kinds) {
		now := router_now_unix_ms()
		if !federation_delivery_outbox_retry_eligible(attempts[i], last_attempt_unix_ms[i], now) do continue
		accepted := bridge_send(dest_daemon_id, route_kinds[i], payloads[i], idempotency_keys[i])
		// Bridge accepted/queued is not durable delivery; delivery_ack marks delivered.
		_ = federation_delivery_outbox_mark_attempt(peer_id, route_kinds[i], idempotency_keys[i], false)
		if !accepted {
			next_attempts := attempts[i] + 1
			if next_attempts >= FEDERATION_REPLAY_STUCK_ATTEMPTS {
				federation_delivery_outbox_log_stuck(peer_id, route_kinds[i], idempotency_keys[i], next_attempts, created_unix_ms[i], now, now, federation_delivery_outbox_retry_backoff_ms(next_attempts))
				continue
			}
			break
		}
		accepted_count += 1
	}
	return accepted_count
}

// federation_delivery_outbox_replay_all_pending drains every peer that still has an
// undelivered outbox entry, regardless of the daemon's live reachability projection.
// federation_forward_transport_accepted is itself a no-op for peers that are not
// currently linked, so this is a cheap, self-limiting safety net that guarantees
// eventual consistency even when a callback was queued during a transient link bounce
// and no unreachable->linked transition fires afterwards.
federation_delivery_outbox_replay_all_pending :: proc() -> int {
	if !task_db_ready do return 0
	peer_ids := make([dynamic]string)
	defer {
		for v in peer_ids do delete(v)
		delete(peer_ids)
	}
	stmt: sqlite3_stmt = nil
	query := `SELECT DISTINCT peer_id FROM federation_delivery_outbox WHERE delivered_unix_ms = 0`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return 0
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&peer_ids, strings.clone_from_cstring(sqlite3_column_text(stmt, 0)))
	}
	sqlite3_finalize(stmt)
	accepted := 0
	for pid in peer_ids {
		if pid == "" do continue
		accepted += federation_delivery_outbox_replay_peer(pid)
		_ = peer_link_replay_remote_notifications(pid)
	}
	return accepted
}

federation_delivery_dedupe_scope :: proc(scope_kind, peer_id, kind: string) -> string {
	return fmt.tprintf("%s:%s:%s", scope_kind, peer_id, kind)
}

federation_delivery_dedupe_completed :: proc(scope, idempotency_key: string) -> bool {
	if scope == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `SELECT 1 FROM federation_delivery_dedupe WHERE scope = ? AND idempotency_key = ? LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, scope)
	task_db_bind_text(stmt, 2, idempotency_key)
	return sqlite3_step(stmt) == SQLITE_ROW
}

federation_delivery_dedupe_record_completed :: proc(scope, idempotency_key: string) -> bool {
	if scope == "" || idempotency_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO federation_delivery_dedupe (scope, idempotency_key, created_unix_ms) VALUES (?, ?, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, scope)
	task_db_bind_text(stmt, 2, idempotency_key)
	sqlite3_bind_int64(stmt, 3, router_now_unix_ms())
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_idempotency_key :: proc(kind, daemon_id, message_id: string) -> string {
	return fmt.tprintf("%s:%s:%s", kind, daemon_id, message_id)
}

federation_remote_message_record_key :: proc(owner_daemon_id, message_id: string) -> string {
	return fmt.tprintf("%s:%s", owner_daemon_id, message_id)
}

federation_remote_message_upsert :: proc(rec: Federation_Remote_Message_Record) -> bool {
	if rec.record_key == "" || rec.message_id == "" || rec.local_agent_instance_id == "" || rec.remote_agent_instance_id == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO federation_remote_messages (
		record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id,
		proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available,
		created_unix_ms, read_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, rec.record_key)
	task_db_bind_text(stmt, 2, rec.message_id)
	task_db_bind_text(stmt, 3, rec.owner_peer_id)
	task_db_bind_text(stmt, 4, rec.owner_daemon_id)
	task_db_bind_text(stmt, 5, rec.local_agent_instance_id)
	task_db_bind_text(stmt, 6, rec.remote_agent_instance_id)
	task_db_bind_text(stmt, 7, rec.proxy_agent_instance_id)
	task_db_bind_text(stmt, 8, rec.conversation_id)
	task_db_bind_text(stmt, 9, rec.origin_conversation_id)
	task_db_bind_text(stmt, 10, rec.body)
	sqlite3_bind_int64(stmt, 11, 1 if rec.body_available else 0)
	sqlite3_bind_int64(stmt, 12, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 13, rec.read_unix_ms)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_remote_message_get :: proc(record_key: string) -> (Federation_Remote_Message_Record, bool) {
	if record_key == "" || !task_db_ready do return Federation_Remote_Message_Record{}, false
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms FROM federation_remote_messages WHERE record_key = ? LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return Federation_Remote_Message_Record{}, false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, record_key)
	if sqlite3_step(stmt) != SQLITE_ROW do return Federation_Remote_Message_Record{}, false
	return Federation_Remote_Message_Record{
		record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		body_available = sqlite3_column_int64(stmt, 10) != 0,
		created_unix_ms = sqlite3_column_int64(stmt, 11),
		read_unix_ms = sqlite3_column_int64(stmt, 12),
	}, true
}

federation_remote_message_find_origin :: proc(owner_peer_id, message_id: string) -> (Federation_Remote_Message_Record, bool) {
	if owner_peer_id == "" || message_id == "" || !task_db_ready do return Federation_Remote_Message_Record{}, false
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms FROM federation_remote_messages WHERE owner_peer_id = ? AND message_id = ? LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return Federation_Remote_Message_Record{}, false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, owner_peer_id)
	task_db_bind_text(stmt, 2, message_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return Federation_Remote_Message_Record{}, false
	return Federation_Remote_Message_Record{
		record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		body_available = sqlite3_column_int64(stmt, 10) != 0,
		created_unix_ms = sqlite3_column_int64(stmt, 11),
		read_unix_ms = sqlite3_column_int64(stmt, 12),
	}, true
}

federation_remote_message_mark_read :: proc(record_key: string, read_unix_ms: i64) -> bool {
	if record_key == "" || !task_db_ready do return false
	stmt: sqlite3_stmt = nil
	query := `UPDATE federation_remote_messages SET read_unix_ms = ? WHERE record_key = ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, read_unix_ms)
	task_db_bind_text(stmt, 2, record_key)
	return sqlite3_step(stmt) == SQLITE_DONE
}

federation_remote_message_find_reply_route :: proc(local_agent_instance_id, remote_agent_instance_id: string) -> (Federation_Remote_Message_Record, bool) {
	if local_agent_instance_id == "" || remote_agent_instance_id == "" || !task_db_ready do return Federation_Remote_Message_Record{}, false
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms
		FROM federation_remote_messages
		WHERE local_agent_instance_id = ? AND remote_agent_instance_id = ? AND owner_daemon_id != ?
		ORDER BY created_unix_ms DESC
		LIMIT 1`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return Federation_Remote_Message_Record{}, false
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, local_agent_instance_id)
	task_db_bind_text(stmt, 2, remote_agent_instance_id)
	task_db_bind_text(stmt, 3, server_daemon_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return Federation_Remote_Message_Record{}, false
	return Federation_Remote_Message_Record{
		record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
		local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
		conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		body_available = sqlite3_column_int64(stmt, 10) != 0,
		created_unix_ms = sqlite3_column_int64(stmt, 11),
		read_unix_ms = sqlite3_column_int64(stmt, 12),
	}, true
}

federation_remote_messages_for_fetch :: proc(local_agent_instance_id, conversation_id: string, include_read: bool, limit: int) -> []Federation_Remote_Message_Record {
	rows := make([dynamic]Federation_Remote_Message_Record)
	if local_agent_instance_id == "" || conversation_id == "" || !task_db_ready do return rows[:]
	stmt: sqlite3_stmt = nil
	query := `SELECT record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available, created_unix_ms, read_unix_ms
		FROM federation_remote_messages
		WHERE local_agent_instance_id = ? AND conversation_id = ? AND owner_daemon_id != ?
		ORDER BY created_unix_ms ASC
		LIMIT ?`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return rows[:]
	defer sqlite3_finalize(stmt)
	task_db_bind_text(stmt, 1, local_agent_instance_id)
	task_db_bind_text(stmt, 2, conversation_id)
	task_db_bind_text(stmt, 3, server_daemon_id)
	sqlite3_bind_int64(stmt, 4, i64(limit if limit > 0 else 100))
	for sqlite3_step(stmt) == SQLITE_ROW {
		row := Federation_Remote_Message_Record{
			record_key = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			message_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			owner_peer_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			owner_daemon_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 3)),
			local_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			remote_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
			proxy_agent_instance_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
			conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
			origin_conversation_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
			body = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
			body_available = sqlite3_column_int64(stmt, 10) != 0,
			created_unix_ms = sqlite3_column_int64(stmt, 11),
			read_unix_ms = sqlite3_column_int64(stmt, 12),
		}
		if !include_read && row.read_unix_ms > 0 do continue
		append(&rows, row)
	}
	return rows[:]
}

federation_remote_message_body_fetch :: proc(peer_id, message_id: string) -> (string, bool) {
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok || status != PEER_STATUS_LINKED do return "", false
	path := fmt.tprintf("/federation/messages/%s", message_id)
	if dest_daemon_id == "" do return "", false
	resp, fetch_ok := bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_GET, path, "", federation_idempotency_key("message_fetch", server_daemon_id, message_id), FEDERATION_HTTP_TIMEOUT_MS)
	if !fetch_ok || resp.status != 200 do return "", false
	return extract_json_string(resp.body, "body", ""), true
}

federation_inbox_notification_json :: proc(target_agent_instance_id, payload, idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"notification","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","payload":"`)
	json_write_string(&b, payload)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

federation_inbox_message_json :: proc(message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"inbox_message","idempotency_key":"`)
	json_write_string(&b, federation_idempotency_key("msg", server_daemon_id, message_id))
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","message_id":"`)
	json_write_string(&b, message_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","from_native_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","origin_conversation_id":"`)
	json_write_string(&b, origin_conversation_id)
	// Inbox message bodies are immutable, single-recipient content: ship the body
	// on the daemon-to-daemon push (plain HTTP, no WS size limit) and store it
	// durably on the receiver so reads are offline-capable (store-and-forward).
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `","created_unix_ms":`)
	strings.write_string(&b, fmt.tprintf("%d", created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_callback_message_json :: proc(message_id, origin_message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"inbox_message","idempotency_key":"`)
	json_write_string(&b, federation_idempotency_key("reply", server_daemon_id, message_id))
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","message_id":"`)
	json_write_string(&b, message_id)
	strings.write_string(&b, `","origin_message_id":"`)
	json_write_string(&b, origin_message_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","from_native_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","origin_conversation_id":"`)
	json_write_string(&b, origin_conversation_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `","created_unix_ms":`)
	strings.write_string(&b, fmt.tprintf("%d", created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_callback_read_receipt_json :: proc(message_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, read_by_agent_instance_id: string, read_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"read_receipt","idempotency_key":"`)
	json_write_string(&b, federation_idempotency_key("read", server_daemon_id, message_id))
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","message_id":"`)
	json_write_string(&b, message_id)
	strings.write_string(&b, `","target_agent_instance_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","target_native_id":"`)
	json_write_string(&b, target_agent_instance_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","origin_conversation_id":"`)
	json_write_string(&b, origin_conversation_id)
	strings.write_string(&b, `","read_by_agent_instance_id":"`)
	json_write_string(&b, read_by_agent_instance_id)
	strings.write_string(&b, `","read_by_native_id":"`)
	json_write_string(&b, read_by_agent_instance_id)
	strings.write_string(&b, `","read_unix_ms":`)
	strings.write_string(&b, fmt.tprintf("%d", read_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_remote_message_receive_placeholder :: proc(owner_peer_id, owner_daemon_id, message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> bool {
	// Key the stored message by the RECIPIENT's conversation id so the recipient's
	// own fetch_messages (which queries registry_conversation_id(self)) finds it.
	// The local agent-to-agent model keys a message by the target's conversation;
	// mirror that here. Store the body inline (store-and-forward) so reads work even
	// when the origin daemon/link is down.
	return federation_remote_message_upsert(Federation_Remote_Message_Record{
		record_key = federation_remote_message_record_key(owner_daemon_id, message_id),
		message_id = strings.clone(message_id),
		owner_peer_id = strings.clone(owner_peer_id),
		owner_daemon_id = strings.clone(owner_daemon_id),
		local_agent_instance_id = strings.clone(target_agent_instance_id),
		remote_agent_instance_id = strings.clone(from_agent_instance_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		conversation_id = conversation_id_for_instance(target_agent_instance_id),
		origin_conversation_id = strings.clone(origin_conversation_id),
		body = strings.clone(body),
		body_available = strings.trim_space(body) != "",
		created_unix_ms = created_unix_ms,
		read_unix_ms = 0,
	})
}

federation_remote_message_store_origin_copy :: proc(peer_id, message_id, from_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> bool {
	return federation_remote_message_upsert(Federation_Remote_Message_Record{
		record_key = federation_remote_message_record_key(server_daemon_id, message_id),
		message_id = strings.clone(message_id),
		owner_peer_id = strings.clone(peer_id),
		owner_daemon_id = strings.clone(server_daemon_id),
		local_agent_instance_id = strings.clone(from_agent_instance_id),
		remote_agent_instance_id = strings.clone(remote_agent_instance_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		conversation_id = strings.clone(origin_conversation_id),
		origin_conversation_id = strings.clone(origin_conversation_id),
		body = strings.clone(body),
		body_available = true,
		created_unix_ms = created_unix_ms,
		read_unix_ms = 0,
	})
}

federation_remote_message_store_reply_if_absent :: proc(owner_peer_id, owner_daemon_id, message_id, remote_agent_instance_id, local_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, body: string, created_unix_ms: i64) -> (bool, bool) {
	if owner_peer_id == "" || owner_daemon_id == "" || message_id == "" || remote_agent_instance_id == "" || local_agent_instance_id == "" || proxy_agent_instance_id == "" || origin_conversation_id == "" || !task_db_ready {
		return false, false
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT OR IGNORE INTO federation_remote_messages (
		record_key, message_id, owner_peer_id, owner_daemon_id, local_agent_instance_id, remote_agent_instance_id,
		proxy_agent_instance_id, conversation_id, origin_conversation_id, body, body_available,
		created_unix_ms, read_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	rc := sqlite3_prepare_v2(task_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false, false
	defer sqlite3_finalize(stmt)
	record_key := federation_remote_message_record_key(owner_daemon_id, message_id)
	task_db_bind_text(stmt, 1, record_key)
	task_db_bind_text(stmt, 2, message_id)
	task_db_bind_text(stmt, 3, owner_peer_id)
	task_db_bind_text(stmt, 4, owner_daemon_id)
	task_db_bind_text(stmt, 5, local_agent_instance_id)
	task_db_bind_text(stmt, 6, remote_agent_instance_id)
	task_db_bind_text(stmt, 7, proxy_agent_instance_id)
	task_db_bind_text(stmt, 8, origin_conversation_id)
	task_db_bind_text(stmt, 9, origin_conversation_id)
	task_db_bind_text(stmt, 10, body)
	sqlite3_bind_int64(stmt, 11, 1)
	sqlite3_bind_int64(stmt, 12, created_unix_ms)
	sqlite3_bind_int64(stmt, 13, 0)
	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE do return false, false
	return sqlite3_changes(task_db.db) > 0, true
}

federation_remote_send_message :: proc(from_agent_instance_id, proxy_agent_instance_id, body: string) -> Service_Result {
	peer_id, remote_agent_instance_id, ok := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"unknown remote proxy"}`, status_code = 404, status_text = "Not Found"}
	}
	request := contracts.Send_Message_Request{
		from_agent_instance_id = contracts.Agent_Instance_ID(from_agent_instance_id),
		target_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
		conversation_id = contracts.Conversation_ID(conversation_id_for_instance(proxy_agent_instance_id)),
		body = body,
	}
	response := mp.send_message(&message_provider, request)
	if !response.ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"message provider send failed"}`, status_code = 500, status_text = "Internal Server Error", send_response = response}
	}
	if !federation_remote_message_store_origin_copy(peer_id, string(response.message_id), from_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, string(response.conversation_id), body, response.created_unix_ms) {
		return Service_Result{ok = false, message = `{"ok":false,"message":"failed to persist remote message body"}`, status_code = 500, status_text = "Internal Server Error"}
	}
	payload := federation_inbox_message_json(string(response.message_id), from_agent_instance_id, remote_agent_instance_id, proxy_agent_instance_id, string(response.conversation_id), body, response.created_unix_ms)
	idempotency_key := federation_idempotency_key("msg", server_daemon_id, string(response.message_id))
	_ = federation_delivery_outbox_insert_pending(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key, payload)
	sent := federation_forward(peer_id, FEDERATION_ROUTE_INBOX, payload, idempotency_key)
	_ = federation_delivery_outbox_mark_attempt(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key, sent)
	if !sent && !federation_delivery_outbox_pending_exists(peer_id, FEDERATION_ROUTE_INBOX, idempotency_key) {
		return Service_Result{ok = false, message = `{"ok":false,"message":"failed to queue remote message"}`, status_code = 503, status_text = "Service Unavailable"}
	}
	return Service_Result{ok = true, status_code = 202, status_text = "Accepted", send_response = response, pending_count = 1, notified = sent}
}

federation_remote_route_reply :: proc(from_agent_instance_id, target_agent_instance_id, body: string) -> Service_Result {
	route, ok := federation_remote_message_find_reply_route(from_agent_instance_id, target_agent_instance_id)
	if !ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"unknown target agent instance"}`, status_code = 404, status_text = "Not Found"}
	}
	request := contracts.Send_Message_Request{
		from_agent_instance_id = contracts.Agent_Instance_ID(from_agent_instance_id),
		target_agent_instance_id = contracts.Agent_Instance_ID(target_agent_instance_id),
		conversation_id = contracts.Conversation_ID(route.conversation_id),
		body = body,
	}
	response := mp.send_message(&message_provider, request)
	if !response.ok {
		return Service_Result{ok = false, message = `{"ok":false,"message":"message provider send failed"}`, status_code = 500, status_text = "Internal Server Error", send_response = response}
	}
	payload := federation_callback_message_json(string(response.message_id), route.message_id, from_agent_instance_id, target_agent_instance_id, route.proxy_agent_instance_id, route.origin_conversation_id, body, response.created_unix_ms)
	idempotency_key := federation_idempotency_key("reply", server_daemon_id, string(response.message_id))
	_ = federation_delivery_outbox_insert_pending(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
	sent := federation_forward(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
	_ = federation_delivery_outbox_mark_attempt(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, sent)
	if !sent && !federation_delivery_outbox_pending_exists(route.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key) {
		return Service_Result{ok = false, message = `{"ok":false,"message":"failed to queue remote reply"}`, status_code = 503, status_text = "Service Unavailable"}
	}
	return Service_Result{ok = true, status_code = 202, status_text = "Accepted", send_response = response, pending_count = 1, notified = sent}
}

federation_callback_origin_message_authorize :: proc(peer_id, origin_message_id, proxy_agent_instance_id, remote_agent_instance_id, local_agent_instance_id, origin_conversation_id: string) -> (Federation_Remote_Message_Record, bool) {
	if peer_id == "" || origin_message_id == "" || proxy_agent_instance_id == "" || remote_agent_instance_id == "" || local_agent_instance_id == "" || origin_conversation_id == "" {
		return Federation_Remote_Message_Record{}, false
	}
	rec, ok := federation_remote_message_find_origin(peer_id, origin_message_id)
	if !ok do return Federation_Remote_Message_Record{}, false
	if !rec.body_available do return Federation_Remote_Message_Record{}, false
	if rec.owner_peer_id != peer_id do return Federation_Remote_Message_Record{}, false
	if rec.proxy_agent_instance_id != proxy_agent_instance_id do return Federation_Remote_Message_Record{}, false
	if rec.remote_agent_instance_id != remote_agent_instance_id do return Federation_Remote_Message_Record{}, false
	if rec.local_agent_instance_id != local_agent_instance_id do return Federation_Remote_Message_Record{}, false
	if rec.origin_conversation_id != origin_conversation_id do return Federation_Remote_Message_Record{}, false
	if rec.conversation_id != origin_conversation_id do return Federation_Remote_Message_Record{}, false
	return rec, true
}

federation_remote_fetch_messages :: proc(request: contracts.Fetch_Messages_Request) -> contracts.Fetch_Messages_Response {
	rows := federation_remote_messages_for_fetch(string(request.agent_instance_id), string(request.conversation_id), request.include_read, request.limit)
	messages := make([dynamic]contracts.Message)
	for row in rows {
		body := row.body
		if !row.body_available {
			fetched_body, ok := federation_remote_message_body_fetch(row.owner_peer_id, row.message_id)
			if ok do body = fetched_body
		}
		read_unix_ms := row.read_unix_ms
		if !request.include_read && read_unix_ms == 0 {
			read_unix_ms = router_now_unix_ms()
			_ = federation_remote_message_mark_read(row.record_key, read_unix_ms)
			payload := federation_callback_read_receipt_json(row.message_id, row.remote_agent_instance_id, row.proxy_agent_instance_id, row.origin_conversation_id, row.local_agent_instance_id, read_unix_ms)
			idempotency_key := federation_idempotency_key("read", server_daemon_id, row.message_id)
			_ = federation_delivery_outbox_insert_pending(row.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
			sent := federation_forward(row.owner_peer_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
			_ = federation_delivery_outbox_mark_attempt(row.owner_peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, sent)
		}
		append(&messages, contracts.Message{
			id = contracts.Message_ID(strings.clone(row.record_key)),
			conversation_id = contracts.Conversation_ID(strings.clone(row.conversation_id)),
			from_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(row.remote_agent_instance_id)),
			target_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(row.local_agent_instance_id)),
			body = strings.clone(body),
			created_unix_ms = row.created_unix_ms,
			updated_unix_ms = row.created_unix_ms,
			read_unix_ms = read_unix_ms,
		})
	}
	return contracts.Fetch_Messages_Response{ok = true, message = "fetched", messages = messages[:], has_more = false}
}

federation_status_text :: proc(status_code: int) -> string {
	switch status_code {
	case 200, 201, 202:
		return "OK"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 409:
		return "Conflict"
	case 500:
		return "Internal Server Error"
	case 503:
		return "Service Unavailable"
	}
	return "OK"
}

federation_remote_get :: proc(peer_id, path: string) -> (http.Response, bool) {
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok || status != PEER_STATUS_LINKED do return http.Response{}, false
	if dest_daemon_id == "" do return http.Response{}, false
	resp, fetch_ok := bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_GET, path, "", federation_idempotency_key("remote_get", server_daemon_id, path), FEDERATION_HTTP_TIMEOUT_MS)
	if !fetch_ok do return http.Response{}, false
	return resp, true
}

federation_remote_post_callback :: proc(peer_id, payload, idempotency_key: string) -> (http.Response, bool) {
	_, dest_daemon_id, status, ok := federation_direct_peer_lookup(peer_id, "")
	if !ok || status != PEER_STATUS_LINKED do return http.Response{}, false
	if dest_daemon_id == "" || !bridge_send(dest_daemon_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key) {
		return http.Response{}, false
	}
	// Bridge accepted/queued is not destination durable acceptance; keep daemon
	// outbox entries pending until delivery_ack arrives over the callback path.
	return http.Response{status = 202, body = `{"ok":true,"accepted":true}`}, false
}

federation_write_forwarded_response :: proc(client: net.TCP_Socket, resp: http.Response, ok: bool) {
	if !ok {
		write_response(client, 503, "Service Unavailable", `{"ok":false,"message":"peer unreachable"}`)
		return
	}
	write_response(client, resp.status, federation_status_text(resp.status), resp.body)
}

federation_remote_work_track_notification :: proc(owner_peer_id, origin_daemon_id, local_agent_instance_id, payload: string) -> bool {
	if extract_json_string(payload, "type", "") != "task_event" do return true
	task_id := extract_json_string(payload, "task_id", extract_json_string(payload, "fetch_task_id", ""))
	if task_id == "" do return true
	proxy_agent_instance_id := extract_json_string(payload, "target_agent_instance_id", "")
	if proxy_agent_instance_id == "" do return false
	chain_id := extract_json_string(payload, "chain_id", extract_json_string(payload, "fetch_chain_id", ""))
	status := extract_json_string(payload, "status", "")
	owner_origin_daemon_id := extract_json_string(payload, "origin_daemon_id", origin_daemon_id)
	if owner_origin_daemon_id == "" do return false
	created_unix_ms := i64(extract_json_int(payload, "created_unix_ms", int(router_now_unix_ms())))
	if existing, ok := federation_remote_work_find_task(owner_origin_daemon_id, task_id, local_agent_instance_id); ok {
		if existing.created_unix_ms != 0 do created_unix_ms = existing.created_unix_ms
		federation_remote_work_delete_record(existing)
	}
	return federation_remote_work_upsert(Federation_Remote_Work_Record{
		task_id = strings.clone(task_id),
		chain_id = strings.clone(chain_id),
		owner_peer_id = strings.clone(owner_peer_id),
		origin_daemon_id = strings.clone(owner_origin_daemon_id),
		local_agent_instance_id = strings.clone(local_agent_instance_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		status = strings.clone(status),
		created_unix_ms = created_unix_ms,
		updated_unix_ms = router_now_unix_ms(),
	})
}

federation_remote_task_read_allowed :: proc(state: Task_State, proxy_agent_instance_id: string) -> bool {
	if proxy_agent_instance_id == "" do return false
	if task_actor_has_role(state, proxy_agent_instance_id, "assignee") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "coordinator") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_required") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_optional") do return true
	if task_actor_has_role(state, proxy_agent_instance_id, "subscriber") do return true
	if task_reviewer_agent_instance_id(state) == proxy_agent_instance_id do return true
	return false
}

federation_remote_task_authorized :: proc(peer_id, proxy_agent_instance_id, task_id, action: string) -> bool {
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id || remote_agent_instance_id == "" do return false
	state, found := store_get_task(task_id)
	if !found do return false
	switch action {
	case "read", "comment":
		return federation_remote_task_read_allowed(state, proxy_agent_instance_id)
	case "vote":
		if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_required") do return true
		if task_actor_has_role(state, proxy_agent_instance_id, "lgtm_optional") do return true
		return task_reviewer_agent_instance_id(state) == proxy_agent_instance_id
	case "status":
		return federation_remote_task_read_allowed(state, proxy_agent_instance_id)
	}
	return false
}

federation_remote_chain_authorized :: proc(peer_id, proxy_agent_instance_id, chain_id: string) -> bool {
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id || remote_agent_instance_id == "" do return false
	for state in store_tasks_in_chain(chain_id) {
		if federation_remote_task_read_allowed(state, proxy_agent_instance_id) do return true
	}
	return false
}

// federation_remote_chain_coordinator_authorized gates coordinator-only
// administrative writes (task create, chain update, assign) forwarded from a
// peer. The proxy must map to the requesting peer AND currently be the chain's
// coordinator on this owner daemon. This is stricter than
// federation_remote_chain_authorized (any chain role): only the coordinator may
// author chain administration remotely.
federation_remote_chain_coordinator_authorized :: proc(peer_id, proxy_agent_instance_id, chain_id: string) -> bool {
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id || remote_agent_instance_id == "" do return false
	chain, found := store_get_chain(chain_id)
	if !found do return false
	return chain.coordinator_agent_instance_id == proxy_agent_instance_id
}

federation_json_value_extract :: proc(body, key: string) -> (string, bool) {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return "", false
	start := idx + len(pattern)
	for start < len(body) && (body[start] == ' ' || body[start] == '\n' || body[start] == '\r' || body[start] == '\t') {
		start += 1
	}
	if start >= len(body) do return "", false
	open := body[start]
	close := byte('}')
	if open == '[' do close = ']'
	if open != '{' && open != '[' do return "", false
	depth := 0
	in_string := false
	escaped := false
	for i := start; i < len(body); i += 1 {
		ch := body[i]
		if in_string {
			if escaped {
				escaped = false
				continue
			}
			if ch == '\\' {
				escaped = true
				continue
			}
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' {
			in_string = true
			continue
		}
		if ch == open {
			depth += 1
		} else if ch == close {
			depth -= 1
			if depth == 0 do return strings.clone(body[start:i + 1]), true
		}
	}
	return "", false
}

federation_json_object_append_string :: proc(object_json, key, value: string) -> string {
	if object_json == "" || key == "" do return strings.clone(object_json)
	end := len(object_json) - 1
	for end >= 0 && (object_json[end] == ' ' || object_json[end] == '\n' || object_json[end] == '\r' || object_json[end] == '\t') {
		end -= 1
	}
	if end < 0 || object_json[end] != '}' do return strings.clone(object_json)
	b := strings.builder_make()
	strings.write_string(&b, object_json[:end])
	strings.write_string(&b, `,"`)
	strings.write_string(&b, key)
	strings.write_string(&b, `":"`)
	json_write_string(&b, value)
	strings.write_string(&b, `"`)
	strings.write_string(&b, object_json[end:])
	return strings.to_string(b)
}

federation_remote_task_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("%s/%s?as_agent_instance_id=%s", contracts.ROUTE_FEDERATION_TASKS_PREFIX, work.task_id, work.proxy_agent_instance_id))
}

federation_remote_task_comments_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("%s/%s/comments?as_agent_instance_id=%s", contracts.ROUTE_FEDERATION_TASKS_PREFIX, work.task_id, work.proxy_agent_instance_id))
}

federation_remote_chain_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("%s/%s?as_agent_instance_id=%s", contracts.ROUTE_FEDERATION_TASK_CHAINS_PREFIX, work.chain_id, work.proxy_agent_instance_id))
}

federation_remote_chain_tasks_fetch_response :: proc(work: Federation_Remote_Work_Record) -> (http.Response, bool) {
	return federation_remote_get(work.owner_peer_id, fmt.tprintf("%s/%s/tasks?as_agent_instance_id=%s", contracts.ROUTE_FEDERATION_TASK_CHAINS_PREFIX, work.chain_id, work.proxy_agent_instance_id))
}

federation_remote_tasks_state_json :: proc(local_agent_instance_id: string) -> string {
	rows := federation_remote_work_list_for_agent(local_agent_instance_id)
	defer {
		for row in rows {
			delete(row.task_id)
			delete(row.chain_id)
			delete(row.owner_peer_id)
			delete(row.origin_daemon_id)
			delete(row.local_agent_instance_id)
			delete(row.proxy_agent_instance_id)
			delete(row.status)
		}
		delete(rows)
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task_count":0,"chain_count":0,"event_count":0,"tasks":[`)
	first := true
	count := 0
	for row in rows {
		resp, ok := federation_remote_task_fetch_response(row)
		if !ok || resp.status != 200 do continue
		task_json, extracted := federation_json_value_extract(resp.body, "task")
		if !extracted do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, task_json)
		delete(task_json)
		count += 1
	}
	strings.write_string(&b, `],"participants":[],"chains":[]}`)
	out := strings.to_string(b)
	count_str := fmt.tprintf(`"task_count":%d`, count)
	replaced, _ := strings.replace_all(out, `"task_count":0`, count_str)
	return replaced
}

federation_remote_task_next_json :: proc(local_agent_instance_id: string) -> (string, bool) {
	rows := federation_remote_work_list_for_agent(local_agent_instance_id)
	defer {
		for row in rows {
			delete(row.task_id)
			delete(row.chain_id)
			delete(row.owner_peer_id)
			delete(row.origin_daemon_id)
			delete(row.local_agent_instance_id)
			delete(row.proxy_agent_instance_id)
			delete(row.status)
		}
		delete(rows)
	}
	for row in rows {
		resp, ok := federation_remote_task_fetch_response(row)
		if !ok || resp.status != 200 do continue
		status := extract_json_string(resp.body, "status", "")
		if status != "review_ready" && status != "in_progress" && status != "queued" do continue
		task_json, extracted := federation_json_value_extract(resp.body, "task")
		if !extracted do continue
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":true,"task":`)
		strings.write_string(&b, task_json)
		strings.write_string(&b, `}`)
		delete(task_json)
		return strings.to_string(b), true
	}
	return `{"ok":true,"task":null}`, true
}

federation_task_callback_pending_json :: proc(kind, ref_id: string) -> string {
	// ref_id is the task_id for task-scoped callbacks and the chain_id for
	// chain-scoped ones (task_create / chain_update). Emit it under both keys so
	// task-scoped clients keep the historical task_id field while chain-scoped
	// callers can read ref_id without misreading a chain id as a task id.
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"queued":true,"kind":"`)
		json_write_string(&b, kind)
	strings.write_string(&b, `","task_id":"`)
		json_write_string(&b, ref_id)
	strings.write_string(&b, `","ref_id":"`)
		json_write_string(&b, ref_id)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

federation_task_comment_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, body, idempotency_key: string, artifact: Artifact_Record) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"comment","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, work.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `"`)
	if artifact.artifact_id != "" {
		strings.write_string(&b, `,"artifact_ref":{`)
		strings.write_string(&b, `"artifact_id":"`); json_write_string(&b, artifact.artifact_id)
		strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
		strings.write_string(&b, `","name":"`); json_write_string(&b, artifact.name)
		strings.write_string(&b, `","kind":"`); json_write_string(&b, artifact.kind)
		strings.write_string(&b, `","mime":"`); json_write_string(&b, artifact.mime)
		strings.write_string(&b, `","ext":"`); json_write_string(&b, artifact.ext)
		strings.write_string(&b, `","sha256":"`); json_write_string(&b, artifact.sha256)
		strings.write_string(&b, `","description":"`); json_write_string(&b, artifact.description)
		strings.write_string(&b, `","size_bytes":`); strings.write_string(&b, fmt.tprintf("%d", artifact.size_bytes))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

federation_task_vote_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, comment, result, idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"vote","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, work.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","result":"`)
	json_write_string(&b, result)
	strings.write_string(&b, `","comment":"`)
	json_write_string(&b, comment)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

federation_task_status_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, status, body, idempotency_key: string, force: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"status","idempotency_key":"`)
	json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`)
	json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`)
	json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","task_id":"`)
	json_write_string(&b, work.task_id)
	strings.write_string(&b, `","chain_id":"`)
	json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`)
	json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`)
	json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","status":"`)
	json_write_string(&b, status)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, body)
	strings.write_string(&b, `","force":`)
	strings.write_string(&b, "true" if force else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// federation_task_create_callback_json forwards a coordinator-authored task
// create from the actor daemon (B) to the chain owner daemon (A). Chain-scoped:
// keyed by chain_id + coordinator proxy, since there is no pre-existing task id.
// The optional string fields carry the same knobs as a local /tasks create.
federation_task_create_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, title, description, acceptance_criteria, priority, status, assignee_ref, reviewer_ref, depends_on, idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"`); strings.write_string(&b, FEDERATION_ENVELOPE_TASK_CREATE)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","chain_id":"`); json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`); json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`); json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","title":"`); json_write_string(&b, title)
	strings.write_string(&b, `","description":"`); json_write_string(&b, description)
	strings.write_string(&b, `","acceptance_criteria":"`); json_write_string(&b, acceptance_criteria)
	strings.write_string(&b, `","priority":"`); json_write_string(&b, priority)
	strings.write_string(&b, `","status":"`); json_write_string(&b, status)
	strings.write_string(&b, `","assignee_agent_instance_id":"`); json_write_string(&b, assignee_ref)
	strings.write_string(&b, `","reviewer_agent_instance_id":"`); json_write_string(&b, reviewer_ref)
	strings.write_string(&b, `","depends_on":"`); json_write_string(&b, depends_on)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

// federation_chain_update_callback_json forwards a coordinator-authored chain
// metadata update (title/description/final_summary) from actor daemon (B) to the
// owner daemon (A). Coordinator/reviewer reassignment is intentionally NOT
// forwarded: those bind runtime identity on the owner and must be operated
// locally on A to avoid a remote coordinator retargeting its own chain.
federation_chain_update_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, title, description, final_summary, idempotency_key: string, title_present, description_present, final_summary_present: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"`); strings.write_string(&b, FEDERATION_ENVELOPE_CHAIN_UPDATE)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","chain_id":"`); json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`); json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`); json_write_string(&b, from_agent_instance_id)
	if title_present { strings.write_string(&b, `","title":"`); json_write_string(&b, title) }
	if description_present { strings.write_string(&b, `","description":"`); json_write_string(&b, description) }
	if final_summary_present { strings.write_string(&b, `","final_summary":"`); json_write_string(&b, final_summary) }
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

// federation_task_assign_callback_json forwards a coordinator-authored task
// assignment from actor daemon (B) to the owner daemon (A). Task-scoped: the
// coordinator must already know the task_id (from a chain tasks read).
federation_task_assign_callback_json :: proc(work: Federation_Remote_Work_Record, from_agent_instance_id, task_id, assignee_ref, idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"`); strings.write_string(&b, FEDERATION_ENVELOPE_TASK_ASSIGN)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, work.origin_daemon_id)
	strings.write_string(&b, `","actor_origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","chain_id":"`); json_write_string(&b, work.chain_id)
	strings.write_string(&b, `","task_id":"`); json_write_string(&b, task_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`); json_write_string(&b, work.proxy_agent_instance_id)
	strings.write_string(&b, `","from_agent_instance_id":"`); json_write_string(&b, from_agent_instance_id)
	strings.write_string(&b, `","agent_instance_id":"`); json_write_string(&b, assignee_ref)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

handle_get_federation_task :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "read") {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote task read"}`)
		return
	}
	state, found := store_get_task(task_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"task not found"}`)
		return
	}
	task_builder := strings.builder_make()
	task_write_state_json(&task_builder, state, true)
	task_json := strings.to_string(task_builder)
	annotated_task_json := federation_json_object_append_string(task_json, "origin_daemon_id", server_daemon_id)
	delete(task_json)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"task":`)
	strings.write_string(&b, annotated_task_json)
	strings.write_string(&b, `}`)
	delete(annotated_task_json)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_get_federation_task_comments :: proc(client: net.TCP_Socket, task_id: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "read") {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote task read"}`)
		return
	}
	unresolved_only := query_param_value(ctx.query, "unresolved") == "true"
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"comments":[`)
	first := true
	comments := store_comments_of(task_id)
	defer delete(comments)
	for c in comments {
		if unresolved_only && c.resolved do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, `{"comment_id":"`); json_write_string(&b, c.comment_id)
		strings.write_string(&b, `","body":"`); json_write_string(&b, c.body)
		strings.write_string(&b, `","author_agent_instance_id":"`); json_write_string(&b, c.author_agent_instance_id)
		strings.write_string(&b, `","resolved":`); strings.write_string(&b, "true" if c.resolved else "false")
		strings.write_string(&b, `,"created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", c.created_unix_ms))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_get_federation_task_chain :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_chain_authorized(peer_id, proxy_agent_instance_id, chain_id) {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote chain read"}`)
		return
	}
	chain, found := store_get_chain(chain_id)
	if !found {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"chain not found"}`)
		return
	}
	chain_builder := strings.builder_make()
	task_write_chain_json(&chain_builder, chain)
	chain_json := strings.to_string(chain_builder)
	annotated_chain_json := federation_json_object_append_string(chain_json, "origin_daemon_id", server_daemon_id)
	delete(chain_json)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chain":`)
	strings.write_string(&b, annotated_chain_json)
	delete(annotated_chain_json)
	strings.write_string(&b, `,"events":[`)
	first := true
	for event in store_all_events() {
		if event.chain_id != chain_id || event.task_id != "" do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		strings.write_string(&b, task_event_json(event))
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_get_federation_task_chain_tasks :: proc(client: net.TCP_Socket, chain_id: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	proxy_agent_instance_id := query_param_value(ctx.query, "as_agent_instance_id")
	if !federation_remote_chain_authorized(peer_id, proxy_agent_instance_id, chain_id) {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote chain read"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"chain_id":"`)
	json_write_string(&b, chain_id)
	strings.write_string(&b, `","tasks":[`)
	first := true
	for state in store_tasks_in_chain(chain_id) {
		if !federation_remote_task_read_allowed(state, proxy_agent_instance_id) do continue
		if !first do strings.write_string(&b, `,`)
		first = false
		task_builder := strings.builder_make()
		task_write_state_json(&task_builder, state)
		task_json := strings.to_string(task_builder)
		annotated_task_json := federation_json_object_append_string(task_json, "origin_daemon_id", server_daemon_id)
		delete(task_json)
		strings.write_string(&b, annotated_task_json)
		delete(annotated_task_json)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_post_federation_inbox :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	kind := extract_json_string(body, "kind", "")
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	if kind == "" || idempotency_key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"kind and idempotency_key required"}`)
		return
	}
	scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_INBOX, peer_id, kind)
	if federation_delivery_dedupe_completed(scope, idempotency_key) {
		write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
		return
	}
	switch kind {
	case FEDERATION_ENVELOPE_NOTIFICATION:
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		payload := extract_json_string(body, "payload", "")
		if target_agent_instance_id == "" || payload == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"notification target/payload required"}`)
			return
		}
		if !federation_remote_work_track_notification(peer_id, peer_daemon_id, target_agent_instance_id, payload) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist remote work mapping"}`)
			return
		}
		event_id := notification_outbox_insert_pending(target_agent_instance_id, payload)
		if event_id == "" {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to durably queue notification"}`)
			return
		}
		sent := registry_send_ws_text(target_agent_instance_id, payload)
		_ = notification_outbox_mark_attempt(target_agent_instance_id, event_id, sent)
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record notification dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_INBOX_MESSAGE:
		message_id := extract_json_string(body, "message_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", "")
		origin_conversation_id := extract_json_string(body, "origin_conversation_id", "")
		message_body := extract_json_string(body, "body", "")
		created_unix_ms := i64(extract_json_int(body, "created_unix_ms", int(router_now_unix_ms())))
		if !federation_remote_message_receive_placeholder(peer_id, peer_daemon_id, message_id, from_agent_instance_id, target_agent_instance_id, proxy_agent_instance_id, origin_conversation_id, message_body, created_unix_ms) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist remote placeholder"}`)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record inbox dedupe"}`)
			return
		}
		notified := message_bus_emit(Message_Event{
			kind = .Messages_Available,
			message_id = contracts.Message_ID(strings.clone(message_id)),
			conversation_id = contracts.Conversation_ID(conversation_id_for_instance(target_agent_instance_id)),
			from_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(from_agent_instance_id)),
			target_agent_instance_id = contracts.Agent_Instance_ID(strings.clone(target_agent_instance_id)),
			pending_count = 1,
			created_unix_ms = created_unix_ms,
		})
		_ = notified
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_USER_CHAT_MESSAGE:
		origin_user_id := extract_json_string(body, "origin_user_id", "")
		synthetic_user_id := extract_json_string(body, "synthetic_user_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		message_body := extract_json_string(body, "body", "")
		interrupt := extract_json_bool(body, "interrupt", false)
		if origin_user_id == "" || target_agent_instance_id == "" || message_body == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"user chat target/body required"}`)
			return
		}
		if synthetic_user_id == "" do synthetic_user_id = federation_user_chat_synthetic_user_id(peer_daemon_id, extract_json_string(body, "proxy_agent_instance_id", ""), origin_user_id)
		if !valid_user_id(synthetic_user_id) || !valid_agent_instance_id(target_agent_instance_id) || agent_record_index_by_instance(target_agent_instance_id) < 0 {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid federated user chat target"}`)
			return
		}
		message_id, stored := chat_store_append_message(synthetic_user_id, target_agent_instance_id, "user_to_agent", message_body, interrupt)
		if !stored || message_id == "" {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to append federated user chat"}`)
			return
		}
		chat_event_fanout(synthetic_user_id, target_agent_instance_id, message_id, "user_to_agent")
		if agent_chat_notify_user_message(target_agent_instance_id, synthetic_user_id, message_id) {
			_ = chat_mark_delivered_and_fanout(synthetic_user_id, target_agent_instance_id, message_id, "user_to_agent")
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record user chat dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case:
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported federation inbox kind"}`)
	}
}

handle_get_federation_message :: proc(client: net.TCP_Socket, message_id: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	rec, found := federation_remote_message_find_origin(peer_id, message_id)
	if !found || !rec.body_available {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"message not found"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message_id":"`)
	json_write_string(&b, rec.message_id)
	strings.write_string(&b, `","body":"`)
	json_write_string(&b, rec.body)
	strings.write_string(&b, `"}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

// handle_post_federation_start starts a REAL local agent on request from a peer
// that holds a remote_proxy pointing at it. Authenticated by the peer link. The
// target must be a genuine local agent (not itself a remote_proxy), preventing a
// peer from asking us to relay a start onward.
handle_post_federation_start :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, _, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	idx := agent_record_index_by_instance(agent_instance_id)
	if idx < 0 {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"target agent not found on owner daemon"}`)
		return
	}
	if agent_record_is_remote_proxy(agent_instance_records[idx]) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"target is itself a remote proxy; refusing to relay start"}`)
		return
	}
	// Register the requesting peer's proxy as a status subscriber for this real
	// agent so future status transitions are pushed back over the callback path.
	if proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", ""); proxy_agent_instance_id != "" {
		agent_status_subscriber_register(peer_id, proxy_agent_instance_id, agent_instance_id)
	}
	// Delegate to the normal local start path. It writes the /agents/start
	// response straight back to the requesting peer.
	handle_agents_start(client, body)
	// Push a current-status snapshot so the peer syncs immediately post-start.
	_ = federation_propagate_agent_status(agent_instance_id, "federation_start")
}

// handle_post_federation_stop stops a REAL local agent on request from a peer
// that holds a remote_proxy pointing at it. Authenticated by the peer link. The
// target must be a genuine local agent (not itself a remote_proxy), preventing a
// peer from asking us to relay a stop onward. Mirrors handle_post_federation_start.
handle_post_federation_stop :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, _, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	idx := agent_record_index_by_instance(agent_instance_id)
	if idx < 0 {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"target agent not found on owner daemon"}`)
		return
	}
	if agent_record_is_remote_proxy(agent_instance_records[idx]) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"target is itself a remote proxy; refusing to relay stop"}`)
		return
	}
	if proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", ""); proxy_agent_instance_id != "" {
		agent_status_subscriber_register(peer_id, proxy_agent_instance_id, agent_instance_id)
	}
	time_in_sec := extract_json_int(body, "time_in_sec", 0)
	if time_in_sec <= 0 do time_in_sec = 30
	// Delegate to the core local stop path and write its result back to the peer.
	stop_ok, status, msg := agents_stop_request(agent_instance_id, time_in_sec)
	if !stop_ok {
		write_response(client, status, federation_status_text(status), msg)
		return
	}
	write_response(client, 200, "OK", msg)
}

// handle_post_federation_subscribe registers the requesting peer's remote_proxy
// as a status subscriber for a REAL local agent and immediately pushes one
// current-status snapshot, WITHOUT starting or stopping it. This is the bind-time
// handshake for proxies attached to already-running remote agents: without it the
// proxy never becomes a subscriber and never receives an initial status, so it
// renders offline until the next unrelated transition happens to be pushed.
// Authenticated by the peer link; the target must be a genuine local agent (not
// itself a remote_proxy) so a peer cannot ask us to relay a subscribe onward.
handle_post_federation_subscribe :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, _, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	if agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_instance_id required"}`)
		return
	}
	proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", "")
	if proxy_agent_instance_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"proxy_agent_instance_id required"}`)
		return
	}
	idx := agent_record_index_by_instance(agent_instance_id)
	if idx < 0 {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"target agent not found on owner daemon"}`)
		return
	}
	if agent_record_is_remote_proxy(agent_instance_records[idx]) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"target is itself a remote proxy; refusing to relay subscribe"}`)
		return
	}
	agent_status_subscriber_register(peer_id, proxy_agent_instance_id, agent_instance_id)
	// Force a one-shot snapshot: reset this subscriber's last-sent status so the
	// propagate call below emits the current status even though nothing changed.
	federation_agent_status_reset_last_sent(peer_id, proxy_agent_instance_id, agent_instance_id)
	_ = federation_propagate_agent_status(agent_instance_id, "federation_subscribe")
	write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
}

handle_post_federation_callback :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	peer_id, peer_daemon_id, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	kind := extract_json_string(body, "kind", "")
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	if kind == "" || idempotency_key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"kind and idempotency_key required"}`)
		return
	}
	if kind == FEDERATION_ENVELOPE_DELIVERY_ACK {
		ack_route_kind := extract_json_string(body, "ack_route_kind", "")
		ack_idempotency_key := extract_json_string(body, "ack_idempotency_key", "")
		if ack_idempotency_key == "" || (ack_route_kind != FEDERATION_ROUTE_INBOX && ack_route_kind != FEDERATION_ROUTE_CALLBACK) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid delivery_ack"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, FEDERATION_ENVELOPE_DELIVERY_ACK)
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		_ = federation_delivery_outbox_mark_delivered_by_ack(peer_id, ack_route_kind, ack_idempotency_key)
		if ack_route_kind == FEDERATION_ROUTE_INBOX {
			_ = notification_outbox_mark_remote_ack(ack_idempotency_key)
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record delivery_ack dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
		return
	}
	proxy_agent_instance_id := extract_json_string(body, "proxy_agent_instance_id", "")
	mapped_peer_id, remote_agent_instance_id, mapped := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !mapped || mapped_peer_id != peer_id {
		write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
		return
	}
	switch kind {
	case FEDERATION_ENVELOPE_AGENT_STATUS:
		// Origin pushed a status transition for the real agent behind this proxy.
		// Authorization already confirmed proxy_agent_instance_id -> peer_id above.
		status_value := extract_json_string(body, "status", "")
		if status_value == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_status status required"}`)
			return
		}
		connection_state := extract_json_string(body, "connection_state", "")
		current_task_id := extract_json_string(body, "current_task_id", "")
		provider_profile := extract_json_string(body, "provider_profile", "")
		model_tier := extract_json_string(body, "model_tier", "")
		project_id := extract_json_string(body, "project_id", "")
		updated_unix_ms := i64(extract_json_int(body, "updated_unix_ms", int(router_now_unix_ms())))
		changed, apply_ok := remote_proxy_status_apply(proxy_agent_instance_id, status_value, connection_state, current_task_id, provider_profile, model_tier, project_id, updated_unix_ms)
		if !apply_ok {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to apply remote status"}`)
			return
		}
		// Emit local UI events only on a genuine transition, never per callback.
		if changed do agent_proxy_status_emit(proxy_agent_instance_id, "remote_status")
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_INBOX_MESSAGE:
		origin_message_id := extract_json_string(body, "origin_message_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		origin_conversation_id := extract_json_string(body, "origin_conversation_id", "")
		payload := extract_json_string(body, "body", "")
		if from_agent_instance_id == "" || target_agent_instance_id == "" || payload == "" || origin_conversation_id == "" || origin_message_id == "" || from_agent_instance_id != remote_agent_instance_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		origin_rec, authorized := federation_callback_origin_message_authorize(peer_id, origin_message_id, proxy_agent_instance_id, remote_agent_instance_id, target_agent_instance_id, origin_conversation_id)
		if !authorized {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, kind)
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		callback_message_id := extract_json_string(body, "message_id", "")
		created_unix_ms := i64(extract_json_int(body, "created_unix_ms", int(router_now_unix_ms())))
		if callback_message_id == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"callback message_id required"}`)
			return
		}
		inserted, stored := federation_remote_message_store_reply_if_absent(peer_id, peer_daemon_id, callback_message_id, remote_agent_instance_id, origin_rec.local_agent_instance_id, proxy_agent_instance_id, origin_rec.origin_conversation_id, payload, created_unix_ms)
		if !stored {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to store remote reply"}`)
			return
		}
		if !inserted {
			_ = federation_delivery_dedupe_record_completed(scope, idempotency_key)
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		_ = message_bus_emit(Message_Event{
			kind = .Messages_Available,
			message_id = contracts.Message_ID(federation_remote_message_record_key(peer_daemon_id, callback_message_id)),
			conversation_id = contracts.Conversation_ID(origin_rec.origin_conversation_id),
			from_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
			target_agent_instance_id = contracts.Agent_Instance_ID(origin_rec.local_agent_instance_id),
			pending_count = 1,
			created_unix_ms = created_unix_ms,
		})
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_READ_RECEIPT:
		message_id := extract_json_string(body, "message_id", "")
		target_agent_instance_id := extract_json_string(body, "target_agent_instance_id", "")
		origin_conversation_id := extract_json_string(body, "origin_conversation_id", "")
		read_by_agent_instance_id := extract_json_string(body, "read_by_agent_instance_id", "")
		read_unix_ms := i64(extract_json_int(body, "read_unix_ms", int(router_now_unix_ms())))
		if target_agent_instance_id == "" || origin_conversation_id == "" || message_id == "" || read_by_agent_instance_id != remote_agent_instance_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		origin_rec, authorized := federation_callback_origin_message_authorize(peer_id, message_id, proxy_agent_instance_id, remote_agent_instance_id, target_agent_instance_id, origin_conversation_id)
		if !authorized {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, kind)
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		mark := mp.mark_read(&message_provider, contracts.Mark_Read_Request{agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id), conversation_id = contracts.Conversation_ID(origin_rec.origin_conversation_id), through_message_id = contracts.Message_ID(origin_rec.message_id)})
		if !mark.ok {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to apply remote read receipt"}`)
			return
		}
		_ = message_bus_emit(Message_Event{
			kind = .Message_Read,
			message_id = contracts.Message_ID(message_id),
			conversation_id = contracts.Conversation_ID(origin_conversation_id),
			from_agent_instance_id = contracts.Agent_Instance_ID(target_agent_instance_id),
			target_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
			read_by_agent_instance_id = contracts.Agent_Instance_ID(proxy_agent_instance_id),
			read_unix_ms = read_unix_ms,
		})
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_USER_CHAT_REPLY:
		origin_user_id := extract_json_string(body, "origin_user_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		message_body := extract_json_string(body, "body", "")
		chain_id := extract_json_string(body, "chain_id", "")
		callback_message_id := extract_json_string(body, "message_id", "")
		if origin_user_id == "" || from_agent_instance_id == "" || message_body == "" || callback_message_id == "" || from_agent_instance_id != remote_agent_instance_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote user chat callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, kind)
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		local_message_id, stored := chat_store_append_message_with_chain(origin_user_id, proxy_agent_instance_id, "agent_to_user", message_body, false, chain_id)
		if !stored || local_message_id == "" {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to append remote user chat reply"}`)
			return
		}
		chat_event_fanout(origin_user_id, proxy_agent_instance_id, local_message_id, "agent_to_user", chain_id)
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record user chat callback dedupe"}`)
			return
		}
		write_response(client, 200, "OK", `{"ok":true,"accepted":true}`)
	case FEDERATION_ENVELOPE_TASK_COMMENT:
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		task_id := extract_json_string(body, "task_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		comment_body := extract_json_string(body, "body", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || task_id == "" || comment_body == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "comment") {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s", kind, task_id))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		if artifact_ref_json, has_artifact_ref := federation_json_value_extract(body, "artifact_ref"); has_artifact_ref {
			remote_artifact_id := extract_json_string(artifact_ref_json, "artifact_id", "")
			artifact_origin_daemon_id := extract_json_string(artifact_ref_json, "origin_daemon_id", "")
			project_id := ""
			if chain, found := store_get_chain(chain_id); found do project_id = chain.project_id
			local_artifact_id, upsert_ok := artifact_federation_reference_upsert(
				peer_id,
				artifact_origin_daemon_id,
				remote_artifact_id,
				extract_json_string(artifact_ref_json, "name", ""),
				extract_json_string(artifact_ref_json, "kind", ""),
				extract_json_string(artifact_ref_json, "mime", ""),
				extract_json_string(artifact_ref_json, "ext", ""),
				extract_json_string(artifact_ref_json, "description", ""),
				project_id,
				proxy_agent_instance_id,
				extract_json_i64(artifact_ref_json, "size_bytes", 0),
				extract_json_string(artifact_ref_json, "sha256", ""),
			)
			delete(artifact_ref_json)
			if !upsert_ok {
				write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist remote artifact reference"}`)
				return
			}
			if local_artifact_id != "" && local_artifact_id != remote_artifact_id {
				replaced, _ := strings.replace_all(comment_body, contracts.artifact_make_link(remote_artifact_id), contracts.artifact_make_link(local_artifact_id))
				comment_body = replaced
			}
		}
		result := task_service_comment(task_id, chain_id, comment_body, proxy_agent_instance_id)
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_TASK_VOTE:
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		task_id := extract_json_string(body, "task_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		result_str := extract_json_string(body, "result", "")
		comment_body := extract_json_string(body, "comment", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || task_id == "" || comment_body == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "vote") {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s", kind, task_id))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_review_vote(Task_Review_Vote_Command{task_id = task_id, chain_id = chain_id, approved = result_str == "lgtm" || result_str == "approved" || result_str == "true", comment = comment_body, author_agent_instance_id = proxy_agent_instance_id, author_is_user = false})
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_TASK_STATUS:
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		task_id := extract_json_string(body, "task_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		status_value := extract_json_string(body, "status", "")
		status_body := extract_json_string(body, "body", "")
		force := extract_json_bool(body, "force", false)
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"origin_mismatch"}`)
			return
		}
		if task_id == "" || status_value == "" || status_body == "" {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"task status callback requires task_id, status, and non-empty body","reason":"missing_status_fields"}`)
			return
		}
		if from_agent_instance_id != remote_agent_instance_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"remote_agent_mismatch"}`)
			return
		}
		if !federation_remote_task_authorized(peer_id, proxy_agent_instance_id, task_id, "status") {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"task_status_not_authorized"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s:%s", kind, task_id, status_value))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_status_command(Task_Status_Command{task_id = task_id, chain_id = chain_id, status = status_value, body = status_body, force = force, author_agent_instance_id = proxy_agent_instance_id})
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_TASK_CREATE:
		// Coordinator on peer B creates a task in an A-owned chain. Chain-scoped
		// authorization: the proxy must be A's current chain coordinator.
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		title := extract_json_string(body, "title", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || chain_id == "" || title == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_chain_coordinator_authorized(peer_id, proxy_agent_instance_id, chain_id) {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"task_create_not_authorized"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s", kind, chain_id))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_create_task(Task_Create_Command{
			chain_id                   = chain_id,
			title                      = title,
			description                = extract_json_string(body, "description", ""),
			acceptance_criteria        = extract_json_string(body, "acceptance_criteria", ""),
			priority                   = extract_json_string(body, "priority", ""),
			status                     = extract_json_string(body, "status", ""),
			assignee_agent_instance_id = extract_json_string(body, "assignee_agent_instance_id", ""),
			reviewer_agent_instance_id = extract_json_string(body, "reviewer_agent_instance_id", ""),
			depends_on                 = extract_json_string(body, "depends_on", ""),
			created_by                 = proxy_agent_instance_id,
			author_agent_instance_id   = proxy_agent_instance_id,
		})
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_CHAIN_UPDATE:
		// Coordinator on peer B updates A-owned chain metadata. Coordinator/reviewer
		// reassignment is intentionally not accepted over federation.
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || chain_id == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_chain_coordinator_authorized(peer_id, proxy_agent_instance_id, chain_id) {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"chain_update_not_authorized"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s", kind, chain_id))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_update_chain(Task_Chain_Update_Command{
			chain_id                 = chain_id,
			title                    = extract_json_string(body, "title", ""),
			description              = extract_json_string(body, "description", ""),
			final_summary            = extract_json_string(body, "final_summary", ""),
			author_agent_instance_id = proxy_agent_instance_id,
		})
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case FEDERATION_ENVELOPE_TASK_ASSIGN:
		// Coordinator on peer B assigns an A-owned task within its chain.
		target_origin_daemon_id := extract_json_string(body, "origin_daemon_id", "")
		chain_id := extract_json_string(body, "chain_id", "")
		task_id := extract_json_string(body, "task_id", "")
		assignee_ref := extract_json_string(body, "agent_instance_id", "")
		from_agent_instance_id := extract_json_string(body, "from_agent_instance_id", "")
		if target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || chain_id == "" || task_id == "" || assignee_ref == "" || from_agent_instance_id != remote_agent_instance_id || !federation_remote_chain_coordinator_authorized(peer_id, proxy_agent_instance_id, chain_id) {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"task_assign_not_authorized"}`)
			return
		}
		// The assigned task must belong to the coordinator's chain, or a
		// coordinator could retarget arbitrary tasks by id.
		if state, task_found := store_get_task(task_id); !task_found || state.chain_id != chain_id {
			write_response(client, 403, "Forbidden", `{"ok":false,"message":"unauthorized remote callback","reason":"task_not_in_chain"}`)
			return
		}
		scope := federation_delivery_dedupe_scope(FEDERATION_DEDUPE_SCOPE_CALLBACK, peer_id, fmt.tprintf("%s:%s:%s", kind, task_id, assignee_ref))
		if federation_delivery_dedupe_completed(scope, idempotency_key) {
			write_response(client, 200, "OK", `{"ok":true,"deduped":true}`)
			return
		}
		result := task_service_assign(task_id, chain_id, assignee_ref, proxy_agent_instance_id)
		if !result.ok {
			write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
			return
		}
		if !federation_delivery_dedupe_record_completed(scope, idempotency_key) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to record callback dedupe"}`)
			return
		}
		write_response(client, result.status_code, federation_status_text(result.status_code), result.message)
	case:
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported federation callback kind"}`)
	}
}
