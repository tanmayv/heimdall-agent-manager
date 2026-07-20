package main

import "core:fmt"
import "core:strings"
import "core:sync"

// Edge-triggered agent-status propagation for remote proxies.
// See docs/plans/remote-proxy-stop-and-liveness.md Part B.
//
// HARD REQUIREMENT (B0): the origin daemon must NOT forward raw wrapper
// heartbeats to peers. Propagation is strictly transition-triggered off the same
// runtime_changed / lifecycle_changed edges that already gate local UI emits, and
// federation_propagate_agent_status self-suppresses when the derived status is
// unchanged vs the last value sent to a given proxy subscriber. A steady working
// or idle agent therefore generates zero cross-daemon traffic.

// ----------------------------------------------------------------------------
// Derived federation status enum (stable, coalesced view).
// ----------------------------------------------------------------------------

FEDERATION_AGENT_STATUS_STARTING :: "starting"
FEDERATION_AGENT_STATUS_IDLE :: "idle"
FEDERATION_AGENT_STATUS_WORKING :: "working"
FEDERATION_AGENT_STATUS_STOPPING :: "stopping"
FEDERATION_AGENT_STATUS_STOPPED :: "stopped"
FEDERATION_AGENT_STATUS_OFFLINE :: "offline"
FEDERATION_AGENT_STATUS_BLOCKED :: "startup_blocked"
FEDERATION_AGENT_STATUS_FAILED :: "startup_failed"

federation_agent_status_is_live :: proc(status: string) -> bool {
	switch status {
	case FEDERATION_AGENT_STATUS_STARTING, FEDERATION_AGENT_STATUS_IDLE, FEDERATION_AGENT_STATUS_WORKING:
		return true
	}
	return false
}

// federation_derive_agent_status maps the local runtime projection for a REAL
// agent to the small, stable federation status enum (B0). Only reads existing
// projection fields the local UI already uses. current_task_id is returned as a
// borrowed view into the instance record; callers must NOT free it.
federation_derive_agent_status :: proc(local_agent_instance_id: string) -> (status: string, connection_state: string, current_task_id: string, updated_unix_ms: i64) {
	now := router_now_unix_ms()
	idx := registry_find_agent(local_agent_instance_id)
	// Durable current task (used for working detection + payload). Borrowed, not
	// cloned: the JSON serializer copies it and no one retains the return value.
	if rec_idx := agent_record_index_by_instance(local_agent_instance_id); rec_idx >= 0 {
		current_task_id = agent_instance_records[rec_idx].current_task_id
	}
	if idx < 0 {
		// No live session: stopped/offline. Distinguish nothing further here.
		return FEDERATION_AGENT_STATUS_OFFLINE, "offline", current_task_id, now
	}
	agent := agents[idx]
	startup := agent.startup_status
	// Stop lifecycle takes precedence.
	if agent.stop_requested_unix_ms != 0 || startup == "stopping" {
		return FEDERATION_AGENT_STATUS_STOPPING, "connected" if agent.connected else "registered", current_task_id, now
	}
	if startup == "stopped" {
		return FEDERATION_AGENT_STATUS_STOPPED, "offline", current_task_id, now
	}
	if startup == "startup_blocked" {
		return FEDERATION_AGENT_STATUS_BLOCKED, "connected" if agent.connected else "registered", current_task_id, now
	}
	if startup == "startup_failed" {
		return FEDERATION_AGENT_STATUS_FAILED, "offline", current_task_id, now
	}
	if !agent.connected {
		return FEDERATION_AGENT_STATUS_OFFLINE, "offline", current_task_id, now
	}
	if startup == "starting" || startup == "" {
		return FEDERATION_AGENT_STATUS_STARTING, "connected", current_task_id, now
	}
	// Connected + ready: working vs idle.
	if agent.exec_state == "blocked" || agent.blocked_reason != "" {
		return FEDERATION_AGENT_STATUS_BLOCKED, "connected", current_task_id, now
	}
	if agent.activity_status == "active" || current_task_id != "" {
		return FEDERATION_AGENT_STATUS_WORKING, "connected", current_task_id, now
	}
	return FEDERATION_AGENT_STATUS_IDLE, "connected", current_task_id, now
}

// ----------------------------------------------------------------------------
// Origin side: reverse subscriber index (which peers proxy a given local agent).
// Transport/liveness projection per AGENTS.md — in-memory only.
// ----------------------------------------------------------------------------

Agent_Status_Subscriber :: struct {
	peer_id: string,
	proxy_agent_instance_id: string,
	local_agent_instance_id: string,
	last_sent_status: string,
	last_sent_unix_ms: i64,
}

agent_status_subscribers: [dynamic]Agent_Status_Subscriber
agent_status_subscriber_mutex: sync.Mutex

agent_status_subscriber_free :: proc(sub: Agent_Status_Subscriber) {
	delete(sub.peer_id)
	delete(sub.proxy_agent_instance_id)
	delete(sub.local_agent_instance_id)
	if sub.last_sent_status != "" do delete(sub.last_sent_status)
}

// agent_status_subscriber_set_last_sent_locked frees the prior cloned status
// before storing the new one so overwrites don't leak. Caller holds the mutex.
agent_status_subscriber_set_last_sent_locked :: proc(sub: ^Agent_Status_Subscriber, status: string, updated_unix_ms: i64) {
	if sub.last_sent_status != "" do delete(sub.last_sent_status)
	sub.last_sent_status = strings.clone(status)
	sub.last_sent_unix_ms = updated_unix_ms
}

// agent_status_subscriber_is_dead reports whether a subscriber can never receive
// another useful push: its peer link is gone, or the local real agent it tracks
// no longer exists on this daemon. Lazy pruning off this avoids hooking every
// proxy-archive / peer-removal site.
agent_status_subscriber_is_dead :: proc(sub: Agent_Status_Subscriber) -> bool {
	if _, ok := peer_link_find(sub.peer_id); !ok do return true
	if agent_record_index_by_instance(sub.local_agent_instance_id) < 0 do return true
	return false
}

// agent_status_subscriber_prune_locked compacts the subscriber array, freeing
// dead entries in place. Caller holds the mutex.
agent_status_subscriber_prune_locked :: proc() {
	kept := 0
	for i in 0..<len(agent_status_subscribers) {
		sub := agent_status_subscribers[i]
		if agent_status_subscriber_is_dead(sub) {
			agent_status_subscriber_free(sub)
			continue
		}
		if kept != i do agent_status_subscribers[kept] = sub
		kept += 1
	}
	resize(&agent_status_subscribers, kept)
}

// agent_status_subscriber_register records that `peer_id` holds a proxy
// (`proxy_agent_instance_id`) standing in for local `local_agent_instance_id`.
// Idempotent. Called from forwarded start/stop receivers where the peer identity
// and proxy id are both known and authenticated. Prunes dead subscribers first so
// the index cannot grow unbounded across proxy churn.
agent_status_subscriber_register :: proc(peer_id, proxy_agent_instance_id, local_agent_instance_id: string) {
	if peer_id == "" || proxy_agent_instance_id == "" || local_agent_instance_id == "" do return
	sync.mutex_lock(&agent_status_subscriber_mutex)
	defer sync.mutex_unlock(&agent_status_subscriber_mutex)
	agent_status_subscriber_prune_locked()
	for &sub in agent_status_subscribers {
		if sub.peer_id == peer_id && sub.proxy_agent_instance_id == proxy_agent_instance_id && sub.local_agent_instance_id == local_agent_instance_id {
			return
		}
	}
	append(&agent_status_subscribers, Agent_Status_Subscriber{
		peer_id = strings.clone(peer_id),
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		local_agent_instance_id = strings.clone(local_agent_instance_id),
		last_sent_status = "",
		last_sent_unix_ms = 0,
	})
}

federation_agent_runtime_provider_tier :: proc(local_agent_instance_id: string) -> (provider_profile, model_tier, project_id: string) {
	if idx := registry_find_agent(local_agent_instance_id); idx >= 0 {
		agent := agents[idx]
		provider_profile = strings.clone(agent.provider_profile)
		model_tier = strings.clone(agent.provider_tier)
		if rec_idx := agent_record_index_by_instance(local_agent_instance_id); rec_idx >= 0 {
			project_id = strings.clone(agent_instance_records[rec_idx].project_id)
		}
		return
	}
	if rec_idx := agent_record_index_by_instance(local_agent_instance_id); rec_idx >= 0 {
		rec := agent_instance_records[rec_idx]
		provider_profile = strings.clone(rec.provider_profile)
		model_tier = strings.clone(rec.model_tier)
		project_id = strings.clone(rec.project_id)
		return
	}
	return "", "", ""
}

federation_agent_status_callback_json :: proc(idempotency_key, proxy_agent_instance_id, status, connection_state, current_task_id, provider_profile, model_tier, project_id, reason: string, updated_unix_ms: i64) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"kind":"`); json_write_string(&b, FEDERATION_ENVELOPE_AGENT_STATUS)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","origin_daemon_id":"`); json_write_string(&b, server_daemon_id)
	strings.write_string(&b, `","proxy_agent_instance_id":"`); json_write_string(&b, proxy_agent_instance_id)
	strings.write_string(&b, `","status":"`); json_write_string(&b, status)
	strings.write_string(&b, `","connection_state":"`); json_write_string(&b, connection_state)
	strings.write_string(&b, `","current_task_id":"`); json_write_string(&b, current_task_id)
	strings.write_string(&b, `","provider_profile":"`); json_write_string(&b, provider_profile)
	strings.write_string(&b, `","model_tier":"`); json_write_string(&b, model_tier)
	strings.write_string(&b, `","project_id":"`); json_write_string(&b, project_id)
	strings.write_string(&b, `","reason":"`); json_write_string(&b, reason)
	strings.write_string(&b, `","updated_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", updated_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// federation_propagate_agent_status is the single transition-triggered entry
// point. It resolves the derived status for `local_agent_instance_id` and, for
// each proxy subscriber whose last-sent status differs, enqueues a retryable
// callback and updates that subscriber's last-sent status. Unchanged status is a
// no-op (self-suppression), so calling this from every existing emit edge is
// cheap and safe. Returns the number of callbacks enqueued.
federation_propagate_agent_status :: proc(local_agent_instance_id, reason: string) -> int {
	if local_agent_instance_id == "" do return 0
	// Never propagate for a proxy record itself (no relay-onward).
	if r_idx := agent_record_index_by_instance(local_agent_instance_id); r_idx >= 0 && agent_record_is_remote_proxy(agent_instance_records[r_idx]) {
		return 0
	}
	status, connection_state, current_task_id, updated_unix_ms := federation_derive_agent_status(local_agent_instance_id)
	provider_profile, model_tier, project_id := federation_agent_runtime_provider_tier(local_agent_instance_id)
	defer { if provider_profile != "" do delete(provider_profile); if model_tier != "" do delete(model_tier); if project_id != "" do delete(project_id) }

	// Snapshot the matching subscribers under lock; send outside the lock.
	Pending :: struct { peer_id, proxy_agent_instance_id: string }
	pendings := make([dynamic]Pending)
	defer {
		for p in pendings { delete(p.peer_id); delete(p.proxy_agent_instance_id) }
		delete(pendings)
	}
	sync.mutex_lock(&agent_status_subscriber_mutex)
	agent_status_subscriber_prune_locked()
	for i in 0..<len(agent_status_subscribers) {
		sub := &agent_status_subscribers[i]
		if sub.local_agent_instance_id != local_agent_instance_id do continue
		if sub.last_sent_status == status do continue
		agent_status_subscriber_set_last_sent_locked(sub, status, updated_unix_ms)
		append(&pendings, Pending{peer_id = strings.clone(sub.peer_id), proxy_agent_instance_id = strings.clone(sub.proxy_agent_instance_id)})
	}
	sync.mutex_unlock(&agent_status_subscriber_mutex)

	enqueued := 0
	for p in pendings {
		idempotency_key := federation_idempotency_key("agent_status", server_daemon_id, fmt.tprintf("%s:%s:%d", p.proxy_agent_instance_id, status, updated_unix_ms))
		payload := federation_agent_status_callback_json(idempotency_key, p.proxy_agent_instance_id, status, connection_state, current_task_id, provider_profile, model_tier, project_id, reason, updated_unix_ms)
		_ = federation_delivery_outbox_insert_pending(p.peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, payload)
		sent := federation_forward(p.peer_id, FEDERATION_ROUTE_CALLBACK, payload, idempotency_key)
		_ = federation_delivery_outbox_mark_attempt(p.peer_id, FEDERATION_ROUTE_CALLBACK, idempotency_key, sent)
		enqueued += 1
	}
	return enqueued
}

// federation_agent_status_resync_peer sends exactly one current-status snapshot
// per subscriber to `peer_id` on link (re)connect so the peer re-syncs after any
// missed transitions. Steady state remains transition-only. It forces a send by
// resetting last_sent_status so the next propagate emits once.
federation_agent_status_resync_peer :: proc(peer_id: string) -> int {
	if peer_id == "" do return 0
	locals := make([dynamic]string)
	defer { for v in locals do delete(v); delete(locals) }
	sync.mutex_lock(&agent_status_subscriber_mutex)
	agent_status_subscriber_prune_locked()
	for i in 0..<len(agent_status_subscribers) {
		sub := &agent_status_subscribers[i]
		if sub.peer_id != peer_id do continue
		if sub.last_sent_status != "" { delete(sub.last_sent_status); sub.last_sent_status = "" }
		already := false
		for v in locals { if v == sub.local_agent_instance_id { already = true; break } }
		if !already do append(&locals, strings.clone(sub.local_agent_instance_id))
	}
	sync.mutex_unlock(&agent_status_subscriber_mutex)
	count := 0
	for local_id in locals {
		count += federation_propagate_agent_status(local_id, "peer_resync")
	}
	return count
}

// ----------------------------------------------------------------------------
// Proxy side: store remote status pushed by the origin. In-memory projection.
// ----------------------------------------------------------------------------

Remote_Proxy_Status :: struct {
	proxy_agent_instance_id: string,
	status: string,
	connection_state: string,
	current_task_id: string,
	provider_profile: string,
	model_tier: string,
	project_id: string,
	last_seen_unix_ms: i64,
	updated_unix_ms: i64,
}

remote_proxy_status_records: [dynamic]Remote_Proxy_Status
remote_proxy_status_mutex: sync.Mutex

remote_proxy_status_get :: proc(proxy_agent_instance_id: string) -> (Remote_Proxy_Status, bool) {
	if proxy_agent_instance_id == "" do return Remote_Proxy_Status{}, false
	sync.mutex_lock(&remote_proxy_status_mutex)
	defer sync.mutex_unlock(&remote_proxy_status_mutex)
	for rec in remote_proxy_status_records {
		if rec.proxy_agent_instance_id == proxy_agent_instance_id {
			return Remote_Proxy_Status{
				proxy_agent_instance_id = strings.clone(rec.proxy_agent_instance_id),
				status = strings.clone(rec.status),
				connection_state = strings.clone(rec.connection_state),
				current_task_id = strings.clone(rec.current_task_id),
				provider_profile = strings.clone(rec.provider_profile),
				model_tier = strings.clone(rec.model_tier),
				project_id = strings.clone(rec.project_id),
				last_seen_unix_ms = rec.last_seen_unix_ms,
				updated_unix_ms = rec.updated_unix_ms,
			}, true
		}
	}
	return Remote_Proxy_Status{}, false
}

// remote_proxy_status_apply stores a pushed status. Drops stale/out-of-order
// updates using updated_unix_ms. Returns (changed, ok): changed is true only when
// the stored status value actually transitions (so callers emit local UI events
// only on transition, never per callback).
remote_proxy_status_apply :: proc(proxy_agent_instance_id, status, connection_state, current_task_id, provider_profile, model_tier, project_id: string, updated_unix_ms: i64) -> (changed: bool, ok: bool) {
	if proxy_agent_instance_id == "" || status == "" do return false, false
	sync.mutex_lock(&remote_proxy_status_mutex)
	defer sync.mutex_unlock(&remote_proxy_status_mutex)
	for i in 0..<len(remote_proxy_status_records) {
		rec := &remote_proxy_status_records[i]
		if rec.proxy_agent_instance_id != proxy_agent_instance_id do continue
		// Drop stale/out-of-order.
		if updated_unix_ms != 0 && rec.updated_unix_ms != 0 && updated_unix_ms < rec.updated_unix_ms {
			return false, true
		}
		status_changed := rec.status != status
		// Free prior clones before overwriting so repeated pushes don't leak.
		if rec.status != "" do delete(rec.status)
		if rec.connection_state != "" do delete(rec.connection_state)
		if rec.current_task_id != "" do delete(rec.current_task_id)
		if rec.provider_profile != "" do delete(rec.provider_profile)
		if rec.model_tier != "" do delete(rec.model_tier)
		if rec.project_id != "" do delete(rec.project_id)
		rec.status = strings.clone(status)
		rec.connection_state = strings.clone(connection_state)
		rec.current_task_id = strings.clone(current_task_id)
		rec.provider_profile = strings.clone(provider_profile)
		rec.model_tier = strings.clone(model_tier)
		rec.project_id = strings.clone(project_id)
		rec.last_seen_unix_ms = updated_unix_ms
		rec.updated_unix_ms = updated_unix_ms
		return status_changed, true
	}
	append(&remote_proxy_status_records, Remote_Proxy_Status{
		proxy_agent_instance_id = strings.clone(proxy_agent_instance_id),
		status = strings.clone(status),
		connection_state = strings.clone(connection_state),
		current_task_id = strings.clone(current_task_id),
		provider_profile = strings.clone(provider_profile),
		model_tier = strings.clone(model_tier),
		project_id = strings.clone(project_id),
		last_seen_unix_ms = updated_unix_ms,
		updated_unix_ms = updated_unix_ms,
	})
	return true, true
}

// federation_peer_reachable reports whether the peer link for `peer_id` is
// currently LINKED. Used by the proxy-side JSON serializer to override
// last-known status with offline when the link itself is down (B3).
federation_peer_reachable :: proc(peer_id: string) -> bool {
	if peer_id == "" do return false
	_, _, status, ok := federation_direct_peer_lookup_cached(peer_id, "")
	return ok && status == PEER_STATUS_LINKED
}

// agent_proxy_status_emit fans out a local agent_lifecycle_changed event for a
// remote proxy record so the proxy-holding daemon's own UI updates live on a
// status transition. Proxies are not in the live registry, so this builds the
// event straight from the durable proxy record + stored remote status rather than
// going through agent_lifecycle_emit (which requires registry_find_agent).
agent_proxy_status_emit :: proc(proxy_agent_instance_id, reason: string) {
	idx := agent_record_index_by_instance(proxy_agent_instance_id)
	if idx < 0 do return
	rec := agent_instance_records[idx]
	if !agent_record_is_remote_proxy(rec) do return
	remote, _ := remote_proxy_status_get(proxy_agent_instance_id)
	status := remote.status
	peer_reachable := federation_peer_reachable(rec.remote_peer_id)
	live := federation_agent_status_is_live(status) && peer_reachable
	connection_state := "connected" if live else "offline"
	// Prefer the project propagated from the origin; the local proxy record has
	// no project binding of its own (mirrors provider/tier handling).
	effective_project_id := remote.project_id if remote.project_id != "" else rec.project_id
	project_name := ""
	if effective_project_id != "" {
		if pj := project_index(effective_project_id); pj >= 0 do project_name = project_records[pj].name
	}
	// Build the proxy-specific remote block, then serialize the common event shape
	// through the shared writer so the wire format cannot drift from the live path.
	resolved_origin, _ := agent_remote_proxy_origin_daemon_id(rec)
	rb := strings.builder_make()
	strings.write_string(&rb, `"remote":{"peer_id":"`); json_write_string(&rb, rec.remote_peer_id)
	strings.write_string(&rb, `","origin_daemon_id":"`); json_write_string(&rb, resolved_origin)
	strings.write_string(&rb, `","remote_agent_instance_id":"`); json_write_string(&rb, rec.remote_agent_instance_id)
	strings.write_string(&rb, `","status":"`); json_write_string(&rb, status)
	strings.write_string(&rb, `","connection_state":"`); json_write_string(&rb, connection_state)
	strings.write_string(&rb, `","connected":`); strings.write_string(&rb, "true" if live else "false")
	strings.write_string(&rb, `,"current_task_id":"`); json_write_string(&rb, remote.current_task_id)
	strings.write_string(&rb, `","provider_profile":"`); json_write_string(&rb, remote.provider_profile)
	strings.write_string(&rb, `","model_tier":"`); json_write_string(&rb, remote.model_tier)
	strings.write_string(&rb, `","project_id":"`); json_write_string(&rb, effective_project_id)
	strings.write_string(&rb, `","last_seen_unix_ms":`); strings.write_string(&rb, fmt.tprintf("%d", remote.last_seen_unix_ms))
	strings.write_string(&rb, `,"peer_reachable":`); strings.write_string(&rb, "true" if peer_reachable else "false")
	strings.write_string(&rb, `}`)
	b := strings.builder_make()
	agent_lifecycle_changed_write(&b, Agent_Lifecycle_Event_Fields{
		agent_instance_id = rec.agent_instance_id,
		agent_class = rec.template_id,
		display_name = rec.display_name,
		connected = live,
		connection_state = connection_state,
		reason = reason,
		last_seen_unix_ms = remote.last_seen_unix_ms,
		startup_status = status,
		activity_status = "active" if status == FEDERATION_AGENT_STATUS_WORKING else "idle",
		project_id = effective_project_id,
		provider_profile = remote.provider_profile,
		project_name = project_name,
		model_tier = remote.model_tier,
		current_task_id = remote.current_task_id,
		state = status,
		agent_kind = AGENT_KIND_REMOTE_PROXY,
	}, strings.to_string(rb))
	user_client_fanout_all_ws_text(strings.to_string(b))
}
