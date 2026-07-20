package main

import "core:fmt"
import "core:net"
import "core:strings"
import contracts "odin_test:contracts"
import mp "odin_test:lib/message_provider"

handle_register :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "unknown")
	agent_class := extract_json_string(body, "agent_class", "")
	if agent_class == "" do agent_class = derive_agent_class(agent_instance_id)
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id; use class@suffix with only letters, numbers, and dash in each part"}`)
		return
	}
	if !valid_agent_id_part(agent_class) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_class; use only letters, numbers, and dash"}`)
		return
	}
	if agent_class != derive_agent_class(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_class must match agent_instance_id prefix"}`)
		return
	}
	if registry_agent_exists(agent_instance_id) && registry_agent_active_for_duplicate(agent_instance_id) {
		write_response(client, 409, "Conflict", `{"ok":false,"error":"active_duplicate","message":"agent_instance_id already registered and active"}`)
		return
	}

	requested_agent_token := extract_json_string(body, "agent_token", "")
	if requested_agent_token != "" && !agent_runtime_tracker_register_allowed(agent_instance_id, requested_agent_token) {
		write_response(client, 409, "Conflict", `{"ok":false,"error":"superseded_launch","message":"agent launch was superseded by a newer runtime generation"}`)
		return
	}
	// Daemon-spawned wrappers keep their issued token across daemon restarts, but a
	// stale wrapper must not be able to recreate durable agent records after the
	// DB/auth store was intentionally reset. A pre-generated token is trusted only
	// when it is still pending from this daemon process, or when both the durable
	// agent record and persisted auth-token mapping already exist.
	durable_agent_exists := agent_record_index_by_instance(agent_instance_id) >= 0
	if requested_agent_token != "" {
		trusted_preissued_token := false
		if registry_consume_pending_agent_token(agent_instance_id, requested_agent_token) {
			trusted_preissued_token = true
		} else if durable_agent_exists {
			itype, iid := auth_db_get_identity(requested_agent_token)
			if itype == "agent" && iid == agent_instance_id do trusted_preissued_token = true
		}
		if !trusted_preissued_token {
			write_response(client, 401, "Unauthorized", `{"ok":false,"error":"stale_agent_token","message":"pre-generated agent token is not pending or persisted for this agent; stop this wrapper and start the agent again"}`)
			return
		}
		if registry_agent_exists(agent_instance_id) {
			idx := registry_find_agent(agent_instance_id)
			if idx >= 0 && agents[idx].agent_token != requested_agent_token {
				write_response(client, 401, "Unauthorized", `{"ok":false,"error":"token_mismatch","message":"pre-generated agent token does not match active registry token"}`)
				return
			}
		}
	}

	display_name := extract_json_string(body, "display_name", "")
	if durable_agent_exists {
		if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 && agent_record_is_remote_proxy(agent_instance_records[idx]) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"remote_proxy instances cannot register local wrapper sessions"}`)
			return
		}
	}
	if !durable_agent_exists {
		stored_display := display_name
		if stored_display == "" do stored_display = agent_instance_id
		if _, _, ok := agent_record_upsert(agent_instance_id, stored_display, agent_class, "", "", "", "normal", AGENT_IDENTITY_STATE_RUNNING); !ok {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent identity"}`)
			return
		}
	} else {
		_ = agent_store_set_identity_state(agent_instance_id, AGENT_IDENTITY_STATE_RUNNING, "register")
	}

	record := registry_register(
		agent_class,
		agent_instance_id,
		display_name,
		requested_agent_token,
	)
	agent_runtime_tracker_observe_register(agent_instance_id, record.agent_token)
	router_adapter_announce_local_agent(agent_instance_id, agent_class)
	agent_lifecycle_emit(agent_instance_id, "registered", "register")
	// Look up template persona + instructions so the wrapper can include them in the bootstrap.
	template_persona := ""
	template_instructions := ""
	if si := agent_record_index_by_instance(agent_instance_id); si >= 0 {
		if ti := agent_template_index(agent_instance_records[si].template_id); ti >= 0 {
			template_persona = agent_template_records[ti].persona
			template_instructions = agent_template_records[ti].instructions
		}
	}

	user_id := server_config.daemon.user_id
	if active_user := user_client_get_first_registered_user_id(); active_user != "" {
		user_id = active_user
	}
	prefs_json := serialize_all_preferences_json(user_id, agent_class)
	defer delete(prefs_json)

	agent_unread := mp.unread_count(&message_provider, contracts.Unread_Count_Request{
		agent_instance_id = contracts.Agent_Instance_ID(agent_instance_id),
	}).unread_count
	user_unread := chat_unread_count(user_id, agent_instance_id)
	unread_count := agent_unread + user_unread

	assigned_task_id, _ := task_store_get_active_task_for_agent(agent_instance_id)

	write_response(client, 200, "OK", register_response_json(record, template_persona, template_instructions, prefs_json, unread_count, assigned_task_id))
}

handle_startup_report :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	status := extract_json_string(body, "startup_status", extract_json_string(body, "status", ""))
	if !valid_agent_instance_id(agent_instance_id) || status == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"startup report requires agent_instance_id and status"}`)
		return
	}
	if status != "starting" && status != "ready" && status != "startup_blocked" && status != "startup_failed" && status != "startup_unknown" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid startup status"}`)
		return
	}
	reason_code := extract_json_string(body, "reason_code", "")
	safe_diagnostic := extract_json_string(body, "safe_diagnostic", "")
	// Startup reports come from the wrapper/provider probe. Final readiness must
	// come from the agent itself via start-success, not from wrapper launch/probe
	// assumptions. Normalize legacy wrapper "ready/launch_success" to starting.
	if status == "ready" && reason_code != "start_success" {
		status = "starting"
		if reason_code == "" || reason_code == "launch_success" do reason_code = "awaiting_start_success"
		if safe_diagnostic == "" || strings.contains(safe_diagnostic, "assuming ready") do safe_diagnostic = "Agent process launched; waiting for agent start-success RPC"
	}
	provider_profile := extract_json_string(body, "provider_profile", "")
	run_dir := extract_json_string(body, "run_dir", "")
	if !agent_runtime_tracker_apply_startup_report(agent_instance_id, status, reason_code, safe_diagnostic, provider_profile, run_dir, extract_json_string(body, "tmux_pane", "")) {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"unknown agent instance"}`)
		return
	}
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 && (provider_profile != "" || run_dir != "") {
		rec := agent_instance_records[idx]
		if provider_profile != "" do rec.provider_profile = provider_profile
		if run_dir != "" do rec.run_dir = run_dir
		// Preserve stored model_tier — startup_report doesn't carry tier and
		// emitting with empty tier would clobber the value set at /agents/start.
		_ = agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = rec.display_name, template_id = rec.template_id, provider_profile = rec.provider_profile, project_id = rec.project_id, run_dir = rec.run_dir, model_tier = rec.model_tier, agent_kind = rec.agent_kind, remote_peer_id = rec.remote_peer_id, remote_origin_daemon_id = rec.remote_origin_daemon_id, remote_agent_instance_id = rec.remote_agent_instance_id, author = "startup_report"})
	}
	write_response(client, 200, "OK", `{"ok":true}`)
}

// handle_heartbeat is the single sync point between wrapper, daemon, and UI.
// Behavior:
//   - Required fields (display_name, agent_instance_id, provider_profile,
//     provider_tier) must be present; missing → 400.
//   - If agent_store has no record for instance_id, daemon inserts from the
//     wrapper payload. This is the ONLY write-from-wrapper path. project_id,
//     when non-empty, must reference an existing project — otherwise reject
//     with project_not_found and do not insert.
//   - If agent_store has a record, daemon does not write. It compares
//     identity/config fields and returns daemon's values as `corrections`.
//     The wrapper logs corrections; behavior beyond logging is deferred.
//   - Token must match the registry token for the instance; if registry has no
//     entry, the heartbeat reconstructs it (covers daemon-restart-with-live-
//     wrappers).
//   - Runtime fields (pid, tmux_pane, exec_state, ...) update the in-memory
//     registry only. If any changed, fan out agent.runtime_changed.
handle_heartbeat :: proc(client: net.TCP_Socket, body: string) {
	snap := Heartbeat_Snapshot{
		agent_instance_id        = extract_json_string(body, "agent_instance_id", ""),
		agent_token              = extract_json_string(body, "agent_token", ""),
		display_name             = extract_json_string(body, "display_name", ""),
		provider_profile         = extract_json_string(body, "provider_profile", ""),
		provider_tier            = extract_json_string(body, "provider_tier", ""),
		project_id               = extract_json_string(body, "project_id", ""),
		tmux_pane                = extract_json_string(body, "tmux_pane", ""),
		pid                      = extract_json_int(body, "pid", 0),
		exec_state               = extract_json_string(body, "exec_state", ""),
		exec_state_since_unix_ms = i64(extract_json_int(body, "exec_state_since_unix_ms", 0)),
		blocked_reason           = extract_json_string(body, "blocked_reason", ""),
		run_dir                  = extract_json_string(body, "run_dir", ""),
		startup_status           = extract_json_string(body, "startup_status", ""),
		startup_reason_code      = extract_json_string(body, "startup_reason_code", ""),
		startup_safe_diagnostic  = extract_json_string(body, "startup_safe_diagnostic", ""),
		activity_status          = extract_json_string(body, "activity_status", ""),
		activity_checked_unix_ms = i64(extract_json_int(body, "activity_checked_unix_ms", 0)),
		activity_source          = extract_json_string(body, "activity_source", ""),
	}

	if !valid_agent_instance_id(snap.agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}
	if snap.display_name == "" || snap.provider_profile == "" || snap.provider_tier == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"error":"missing_required","message":"heartbeat requires display_name, provider_profile, provider_tier"}`)
		return
	}
	if snap.activity_status != "" && snap.activity_status != "active" && snap.activity_status != "idle" && snap.activity_status != "unknown" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid activity_status"}`)
		return
	}
	if snap.provider_tier != "cheap" && snap.provider_tier != "normal" && snap.provider_tier != "smart" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid provider_tier; expected cheap, normal, or smart"}`)
		return
	}

	// Token validation. Registry is the source of truth; if the token is not
	// found, try to recover from persistent database (daemon restart case).
	if reg_idx := registry_find_agent(snap.agent_instance_id); reg_idx >= 0 {
		if agents[reg_idx].has_agent_token && snap.agent_token != "" && agents[reg_idx].agent_token != snap.agent_token {
			write_response(client, 409, "Conflict", `{"ok":false,"error":"token_mismatch","message":"agent_token does not match registry"}`)
			return
		}
	} else if snap.agent_token != "" {
		// Agent not in runtime registry. Try to recover from persistent storage.
		itype, iid := auth_db_get_identity(snap.agent_token)
		if itype == "agent" && iid == snap.agent_instance_id {
			fmt.println("HEARTBEAT RECOVERY: Recovering agent", snap.agent_instance_id, "from persistent token")
			// Re-register in runtime registry using persistent token
			_ = registry_register("", snap.agent_instance_id, snap.display_name, snap.agent_token)
		} else {
			// Token not in registry and not found in persistent storage
			write_response(client, 401, "Unauthorized", `{"ok":false,"error":"token_not_found","message":"agent token not in registry; call /agents/register to obtain a fresh token"}`)
			return
		}
	} else {
		write_response(client, 401, "Unauthorized", `{"ok":false,"error":"token_not_found","message":"agent token not in registry; call /agents/register to obtain a fresh token"}`)
		return
	}

	store_idx := agent_record_index_by_instance(snap.agent_instance_id)
	inserted := false

	// Wrapper-test agents (token prefix agt_test_) are ephemeral. They keep
	// their in-memory registry presence so the test runner can track them,
	// but they never write to agent_store, never appear in the sidebar (gated
	// by is_test_token in handle_agents_list), and never enter the
	// insert-from-heartbeat path.
	is_test := is_test_token(snap.agent_token)

	if store_idx < 0 && !is_test {
		// Insert path — the only place a wrapper-supplied value lands in the DB.
		if snap.project_id != "" && project_index(snap.project_id) < 0 {
			write_response(client, 400, "Bad Request", `{"ok":false,"error":"project_not_found","message":"project_id does not exist; agent not persisted"}`)
			return
		}
		rec_id, _, ok := agent_record_upsert(snap.agent_instance_id, snap.display_name, derive_agent_class(snap.agent_instance_id), snap.provider_profile, snap.project_id, snap.run_dir, snap.provider_tier)
		if !ok || rec_id == "" {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`)
			return
		}
		inserted = true
		store_idx = agent_record_index_by_instance(snap.agent_instance_id)
	}

	// Build corrections from stored record — wrapper-supplied values that
	// disagree with daemon are NOT persisted. Empty stored project_id is a
	// valid configuration (unassigned) and is sent back as a correction so
	// the wrapper learns about it.
	corrections_b := strings.builder_make()
	have_corrections := false

	add_correction :: proc(b: ^strings.Builder, have: ^bool, field, value: string) {
		if have^ do strings.write_string(b, ",")
		strings.write_string(b, `"`); json_write_string(b, field); strings.write_string(b, `":"`); json_write_string(b, value); strings.write_string(b, `"`)
		have^ = true
	}

	if store_idx >= 0 {
		stored := agent_instance_records[store_idx]
		if !inserted {
			if snap.display_name != stored.display_name && stored.display_name != "" {
				add_correction(&corrections_b, &have_corrections, "display_name", stored.display_name)
			}
			if snap.provider_profile != stored.provider_profile && stored.provider_profile != "" {
				add_correction(&corrections_b, &have_corrections, "provider_profile", stored.provider_profile)
			}
			if snap.provider_tier != stored.model_tier && stored.model_tier != "" {
				add_correction(&corrections_b, &have_corrections, "provider_tier", stored.model_tier)
			}
			if snap.project_id != stored.project_id {
				add_correction(&corrections_b, &have_corrections, "project_id", stored.project_id)
			}
		}
		registry_refresh_identity_cache(snap.agent_instance_id, stored.display_name, stored.provider_profile, stored.model_tier, stored.project_id)
	} else {
		// Test agent (or otherwise unpersisted) — cache wrapper-supplied identity
		// so registry-backed views render. Nothing hits disk.
		registry_refresh_identity_cache(snap.agent_instance_id, snap.display_name, snap.provider_profile, snap.provider_tier, snap.project_id)
	}

	// Dynamic startup status corrections
	if reg_idx := registry_find_agent(snap.agent_instance_id); reg_idx >= 0 {
		reg_agent := agents[reg_idx]
		if snap.startup_status != "" && reg_agent.startup_status != snap.startup_status {
			add_correction(&corrections_b, &have_corrections, "startup_status", reg_agent.startup_status)
			add_correction(&corrections_b, &have_corrections, "startup_reason_code", reg_agent.startup_reason_code)
			add_correction(&corrections_b, &have_corrections, "startup_safe_diagnostic", reg_agent.startup_safe_diagnostic)
		}
	}

	_, _ = agent_runtime_tracker_apply_heartbeat_snapshot(snap)

	resp := strings.builder_make()
	strings.write_string(&resp, `{"ok":true,"inserted":`)
	strings.write_string(&resp, "true" if inserted else "false")
	strings.write_string(&resp, `,"corrections":{`)
	if have_corrections do strings.write_string(&resp, strings.to_string(corrections_b))
	strings.write_string(&resp, `}}`)
	_ = fmt.tprintf("") // keep fmt import live if downstream edits remove uses
	write_response(client, 200, "OK", strings.to_string(resp))
}
