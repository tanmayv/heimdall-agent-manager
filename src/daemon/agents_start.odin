package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

valid_model_tier :: proc(tier: string) -> bool {
	return tier == "cheap" || tier == "normal" || tier == "smart"
}

// agents_invalid_project_json is the shared 400 body used whenever an agent
// create/update/associate/start attempts to bind to a project id that does not
// exist. Keeping the message uniform makes the failure obvious in ctl/UI.
agents_invalid_project_json :: proc(project_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"message":"project '`)
	json_write_string(&b, project_id)
	strings.write_string(&b, `' does not exist; create it first or use a valid project_id"}`)
	return strings.to_string(b)
}

normalize_model_tier :: proc(tier: string) -> string {
	if tier == "" do return "normal"
	return tier
}

agent_provider_profile_supported :: proc(profile: string) -> bool {
	clean := strings.trim_space(profile)
	if clean == "" do return true
	if server_config.wrapper.default_agent == clean do return true
	for cmd in server_config.wrapper.agent_commands {
		if cmd.name == clean do return true
	}
	return false
}

agents_invalid_provider_profile_json :: proc(profile: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"message":"invalid provider_profile: provider '`)
	json_write_string(&b, profile)
	strings.write_string(&b, `' is not supported on this daemon"}`)
	return strings.to_string(b)
}

agent_defaults_write_default :: proc(builder: ^strings.Builder, wrote: ^int, default_use, fallback_agent_id: string, custom_prefs: map[string]User_Preference) {
	if default_use == "" do return
	pref_key := agent_default_pref_key(default_use)
	agent_id := fallback_agent_id
	source := "config"
	is_custom := false
	if pref, found := custom_prefs[pref_key]; found {
		agent_id = pref.value
		source = "preference"
		is_custom = true
	}
	if wrote^ > 0 do strings.write_string(builder, `,`)
	strings.write_string(builder, `{"use":"`); json_write_string(builder, default_use)
	strings.write_string(builder, `","agent_id":"`); json_write_string(builder, agent_id)
	strings.write_string(builder, `","source":"`); json_write_string(builder, source)
	strings.write_string(builder, `","is_custom":`); strings.write_string(builder, "true" if is_custom else "false")
	strings.write_string(builder, `}`)
	wrote^ += 1
}

handle_agents_defaults_get :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	_, auth_ok := rest_authorize(client, ctx)
	if !auth_ok do return
	requested_use := strings.to_lower(strings.trim_space(query_param_value(ctx.query, "use")))
	custom_prefs, db_ok := user_pref_db_load_all(agent_default_pref_user_id())
	if !db_ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to load default-agent preferences"}`)
		return
	}
	defer {
		for key, value in custom_prefs {
			delete(custom_prefs[key].value)
			_ = value
		}
		delete(custom_prefs)
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"defaults":[`)
	wrote := 0
	if requested_use != "" {
		agent_defaults_write_default(&builder, &wrote, requested_use, agent_default_id_configured(requested_use), custom_prefs)
	} else {
		for entry in server_config.daemon.default_agent_ids {
			agent_defaults_write_default(&builder, &wrote, entry.use, entry.agent_id, custom_prefs)
		}
		for key, pref in custom_prefs {
			if !strings.has_prefix(key, "default_agent_id_") do continue
			default_use := key[len("default_agent_id_"):]
			already := false
			for entry in server_config.daemon.default_agent_ids {
				if entry.use == default_use { already = true; break }
			}
			if already do continue
			agent_defaults_write_default(&builder, &wrote, default_use, pref.value, custom_prefs)
		}
	}
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_defaults_set :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, auth_ok := rest_authorize(client, ctx)
	if !auth_ok do return
	default_use := strings.to_lower(strings.trim_space(extract_json_string(body, "use", extract_json_string(body, "role", ""))))
	agent_id := strings.trim_space(extract_json_string(body, "agent_id", extract_json_string(body, "default_agent_id", "")))
	if default_use == "" || safe_agent_id_part(default_use) != default_use {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"valid use required"}`)
		return
	}
	if agent_id == "" || (agent_id != USER_PROXY_AGENT_INSTANCE_ID && agent_id != HUMAN_RECIPIENT_ID && safe_agent_id_part(agent_id) != agent_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"valid durable agent_id required"}`)
		return
	}
	pref_key := agent_default_pref_key(default_use)
	if !user_pref_db_set(agent_default_pref_user_id(), pref_key, agent_id, false) {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to save default-agent mapping"}`)
		return
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"default":{"use":"`); json_write_string(&builder, default_use)
	strings.write_string(&builder, `","agent_id":"`); json_write_string(&builder, agent_id)
	strings.write_string(&builder, `","source":"preference","is_custom":true}}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_providers :: proc(client: net.TCP_Socket) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"providers":[`)
	
	first := true
	for cfg in server_agent_cmd_configs {
		if !first do strings.write_string(&builder, `,`)
		first = false
		
		strings.write_string(&builder, `{"name":"`)
		json_write_string(&builder, cfg.name)
		strings.write_string(&builder, `","command":[`)
		for cmd, idx in cfg.command {
			if idx > 0 do strings.write_string(&builder, `,`)
			strings.write_string(&builder, `"`)
			json_write_string(&builder, cmd)
			strings.write_string(&builder, `"`)
		}
		strings.write_string(&builder, `],"tiers":{`)
		strings.write_string(&builder, `"cheap":"`)
		json_write_string(&builder, cfg.models.cheap)
		strings.write_string(&builder, `","normal":"`)
		json_write_string(&builder, cfg.models.normal)
		strings.write_string(&builder, `","smart":"`)
		json_write_string(&builder, cfg.models.smart)
		strings.write_string(&builder, `"}}`)
	}
	
	// Fallback if empty
	if first && len(server_agent_providers) > 0 {
		for p, idx in server_agent_providers {
			if idx > 0 do strings.write_string(&builder, `,`)
			fmt.sbprintf(&builder, `{"name":"%s","command":["%s"],"tiers":{"cheap":"","normal":"","smart":""}}`, p, p)
		}
	}
	
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_templates :: proc(client: net.TCP_Socket) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"templates":[`)
	wrote := 0
	for i in 0..<agent_template_record_count {
		rec := agent_template_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if wrote > 0 do strings.write_string(&builder, `,`)
		agent_template_record_json(&builder, rec)
		wrote += 1
	}
	if wrote == 0 {
		strings.write_string(&builder, `{"template_id":"conversation","display_name":"Conversation","default_provider_profile":"pi","memory_templates":[]},{"template_id":"worker","display_name":"Worker","default_provider_profile":"pi","memory_templates":[]},{"template_id":"reviewer","display_name":"Reviewer","default_provider_profile":"pi","memory_templates":[]},{"template_id":"coordinator","display_name":"Coordinator","default_provider_profile":"pi","memory_templates":[]}`)
	}
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_list :: proc(client: net.TCP_Socket, request: string) {
	project_id := query_param(request, "project_id")
	limit_str := query_param(request, "limit")
	offset_str := query_param(request, "offset")
	include_identities := query_param(request, "include_identities") == "true"
	_ = query_param(request, "include_conversations") // concrete conversation instances are already part of /agents
	limit := 0
	offset := 0
	if limit_str != "" {
		if val, parse_ok := strconv.parse_int(limit_str); parse_ok && val > 0 do limit = int(val)
	}
	if offset_str != "" {
		if val, parse_ok := strconv.parse_int(offset_str); parse_ok && val > 0 do offset = int(val)
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"agents":[`)
	wrote := 0
	matched := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.archived_at_unix_ms != 0 do continue
		if project_id != "" && rec.project_id != project_id do continue
		if matched < offset { matched += 1; continue }
		if limit > 0 && wrote >= limit { matched += 1; continue }
		if wrote > 0 do strings.write_string(&builder, `,`)
		agent_instance_record_json(&builder, rec)
		wrote += 1
		matched += 1
	}
	// Preserve existing live-registry visibility for callers that used /clients only.
	if project_id == "" {
		for i in 0..<agent_count {
			ag := agents[i]
			if is_test_token(ag.agent_token) do continue
			if agent_record_index_by_instance(ag.agent_instance_id) >= 0 do continue
			if matched < offset { matched += 1; continue }
			if limit > 0 && wrote >= limit { matched += 1; continue }
			if wrote > 0 do strings.write_string(&builder, `,`)
			strings.write_string(&builder, `{"agent_record_id":"`); json_write_string(&builder, ag.agent_instance_id)
			strings.write_string(&builder, `","display_name":"`); json_write_string(&builder, ag.display_name)
			// provider_profile is set on startup report; fall back to agent_class (always set on register)
			live_pp := ag.provider_profile; if live_pp == "" do live_pp = ag.agent_class
			live_template := derive_agent_class(ag.agent_instance_id)
			strings.write_string(&builder, `","template_id":"`); json_write_string(&builder, live_template)
			strings.write_string(&builder, `","provider_profile":"`); json_write_string(&builder, live_pp)
			strings.write_string(&builder, `","project_id":"","project_name":"","run_dir":"`); json_write_string(&builder, ag.run_dir)
			strings.write_string(&builder, `","conversation_id":"`); json_write_string(&builder, ag.conversation_id)
			strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, ag.tmux_pane)
			strings.write_string(&builder, `","connected":`); strings.write_string(&builder, "true" if ag.connected else "false")
			strings.write_string(&builder, `,"last_seen_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", ag.last_seen_unix_ms))
			strings.write_string(&builder, `,"startup_status":"`); json_write_string(&builder, ag.startup_status)
			strings.write_string(&builder, `","startup_reason_code":"`); json_write_string(&builder, ag.startup_reason_code)
			strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, ag.startup_safe_diagnostic)
			strings.write_string(&builder, `","startup_updated_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", ag.startup_updated_unix_ms))
			strings.write_string(&builder, `,"activity_status":"`); json_write_string(&builder, ag.activity_status)
			strings.write_string(&builder, `","activity_source":"`); json_write_string(&builder, ag.activity_source)
			strings.write_string(&builder, `","activity_checked_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", ag.activity_checked_unix_ms)); strings.write_string(&builder, `}`)
			wrote += 1
			matched += 1
		}
	}
	has_more := limit > 0 && matched > offset + wrote
	next_offset := offset + wrote
	strings.write_string(&builder, `],"total":`); strings.write_string(&builder, fmt.tprintf("%d", matched))
	strings.write_string(&builder, `,"limit":`); strings.write_string(&builder, fmt.tprintf("%d", limit))
	strings.write_string(&builder, `,"offset":`); strings.write_string(&builder, fmt.tprintf("%d", offset))
	strings.write_string(&builder, `,"next_offset":`); strings.write_string(&builder, fmt.tprintf("%d", next_offset))
	strings.write_string(&builder, `,"has_more":`); strings.write_string(&builder, "true" if has_more else "false")
	if include_identities {
		// Defensive backfill for old/migrated stores: if the durable agent_id log is
		// incomplete, ensure every non-reserved concrete instance contributes a
		// durable identity record before serializing picker identities.
		for i in 0..<agent_instance_record_count {
			rec := agent_instance_records[i]
			if rec.archived_at_unix_ms != 0 do continue
			if rec.agent_instance_id == "" do continue
			resolved_agent_id := rec.agent_id
			if resolved_agent_id == "" do resolved_agent_id = agent_id_from_instance_id(rec.agent_instance_id)
			agent_id_ensure_backfill(resolved_agent_id, rec.display_name, rec.template_id, rec.provider_profile, rec.model_tier, rec.project_id, rec.created_unix_ms)
		}
		strings.write_string(&builder, `,"identities":[`)
		identity_wrote := 0
		for i in 0..<agent_id_record_count {
			rec := agent_id_records[i]
			if rec.archived_at_unix_ms != 0 do continue
			if agent_instance_id_is_reserved(rec.agent_id) do continue
			if identity_wrote > 0 do strings.write_string(&builder, `,`)
			agent_id_record_json(&builder, rec)
			identity_wrote += 1
		}
		strings.write_string(&builder, `]`)
	}
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_agents_associate :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	project_id := extract_json_string(body, "project_id", "")
	if project_id == "" { write_response(client, 400, "Bad Request", `{"ok":false,"message":"project_id required"}`); return }
	if !project_exists(project_id) { write_response(client, 400, "Bad Request", agents_invalid_project_json(project_id)); return }
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	rec.project_id = strings.clone(project_id)
	assoc_tier := normalize_model_tier(rec.model_tier)
	assoc_provider := rec.provider_profile
	if agent_record_is_remote_proxy(rec) { assoc_tier = ""; assoc_provider = "" }
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = rec.display_name, template_id = rec.template_id, provider_profile = assoc_provider, project_id = rec.project_id, run_dir = rec.run_dir, model_tier = assoc_tier, agent_kind = rec.agent_kind, remote_peer_id = rec.remote_peer_id, remote_origin_daemon_id = rec.remote_origin_daemon_id, remote_agent_instance_id = rec.remote_agent_instance_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent association"}`); return }
	write_agent_ok_response(client, "associated", agent_instance_records[agent_record_index(rec.agent_record_id)])
}

handle_agents_disassociate :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	rec.project_id = ""
	disassoc_tier := normalize_model_tier(rec.model_tier)
	disassoc_provider := rec.provider_profile
	if agent_record_is_remote_proxy(rec) { disassoc_tier = ""; disassoc_provider = "" }
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = rec.display_name, template_id = rec.template_id, provider_profile = disassoc_provider, project_id = "", run_dir = rec.run_dir, model_tier = disassoc_tier, agent_kind = rec.agent_kind, remote_peer_id = rec.remote_peer_id, remote_origin_daemon_id = rec.remote_origin_daemon_id, remote_agent_instance_id = rec.remote_agent_instance_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent disassociation"}`); return }
	write_agent_ok_response(client, "disassociated", agent_instance_records[agent_record_index(rec.agent_record_id)])
}

// Upsert an agent instance record. If the instance already exists the record_id and run_dir are
// preserved; caller-supplied non-empty fields override stored ones. Returns the resolved
// agent_record_id and the final model_tier, or ("", "") on failure.
agent_record_upsert :: proc(
	agent_instance_id, display_label, template_id, provider_profile, project_id, run_dir_override, model_tier: string,
	identity_state: string = "",
	project_id_set: bool = false,
	agent_kind: string = "",
	remote_peer_id: string = "",
	remote_origin_daemon_id: string = "",
	remote_agent_instance_id: string = "",
) -> (agent_record_id: string, final_tier: string, ok: bool) {
	if guide_agent_is_singleton(agent_instance_id) && template_id != "" {
		expected_template := guide_agent_template_id()
		durable_for_guide := agent_id_from_instance_id(agent_instance_id)
		if idx := agent_id_index(durable_for_guide); idx >= 0 && agent_id_records[idx].template_id != "" do expected_template = agent_id_records[idx].template_id
		delete(durable_for_guide)
		if template_id != expected_template {
			fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d stage=record_upsert_rejected target=%s template=%s reason=guide_singleton_template_mismatch", router_now_unix_ms(), agent_instance_id, template_id)
			return "", "", false
		}
	}
	rec_id := agent_new_record_id()
	run_dir := run_dir_override
	tier := normalize_model_tier(model_tier)
	pp := provider_profile
	resolved_project_id := project_id
	state := identity_state
	kind := agent_kind
	remote_peer := remote_peer_id
	remote_origin := remote_origin_daemon_id
	remote_agent := remote_agent_instance_id
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		rec_id = agent_instance_records[idx].agent_record_id
		if run_dir == "" do run_dir = agent_instance_records[idx].run_dir
		if pp == "" do pp = agent_instance_records[idx].provider_profile
		if state == "" do state = agent_instance_records[idx].state
		if kind == "" do kind = agent_instance_records[idx].agent_kind
		if remote_peer == "" do remote_peer = agent_instance_records[idx].remote_peer_id
		if remote_origin == "" do remote_origin = agent_instance_records[idx].remote_origin_daemon_id
		if remote_agent == "" do remote_agent = agent_instance_records[idx].remote_agent_instance_id
		// Empty project_id from caller (e.g. /agents/start with no body project_id)
		// must NOT clobber the stored association. Use the stored value as the
		// fallback; explicit disassociation goes through /agents/disassociate.
		// However, an explicit project_id_set (e.g. runtime restart selecting
		// "Project: none") applies the caller value verbatim, including clearing it.
		if resolved_project_id == "" && !project_id_set do resolved_project_id = agent_instance_records[idx].project_id
	} else if resolved_project_id == "" {
		resolved_project_id = agent_id_default_project_id(agent_id_from_instance_id(agent_instance_id))
	}
	if state == "" do state = AGENT_IDENTITY_STATE_PROVISIONED
	kind = agent_kind_normalize(kind)
	if kind == AGENT_KIND_REMOTE_PROXY {
		if strings.trim_space(remote_peer) == "" || strings.trim_space(remote_agent) == "" do return "", "", false
		// Remote proxies never launch local wrappers. Do not persist local
		// provider/tier defaults on the proxy record; runtime provider/tier is owned
		// by the remote daemon and returned from propagated remote runtime status.
		pp = ""
		tier = ""
		run_dir = ""
		resolved_project_id = ""
	}
	ev := Agent_Instance_Event{
		kind = .Agent_Instance_Upserted,
		agent_record_id = rec_id,
		agent_instance_id = agent_instance_id,
		display_name = display_label,
		template_id = template_id,
		provider_profile = pp,
		project_id = resolved_project_id,
		run_dir = run_dir,
		model_tier = tier,
		agent_kind = kind,
		remote_peer_id = strings.trim_space(remote_peer),
		remote_origin_daemon_id = strings.trim_space(remote_origin),
		remote_agent_instance_id = strings.trim_space(remote_agent),
		state = agent_identity_state_normalize(state),
		author = "api",
	}
	if !agent_store_append_event(ev) do return "", "", false
	return rec_id, tier, true
}

handle_agents_start :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", extract_json_string(body, "persona", ""))
	project_id := extract_json_string(body, "project_id", "")
	// Explicit runtime restart with a project override (including clearing to
	// "none") sets project_id_set so an empty value applies verbatim instead of
	// preserving the stored instance project.
	project_id_set := extract_json_bool(body, "project_id_set", false)
	// Reject binding a launch to a non-existent project up front. Without this the
	// wrapper spawns, fails project validation, and the agent silently sticks at
	// startup_unknown on every reconcile.
	if strings.trim_space(project_id) != "" && !project_exists(project_id) {
		write_response(client, 400, "Bad Request", agents_invalid_project_json(project_id))
		return
	}
	provider_profile := extract_json_string(body, "provider_profile", extract_json_string(body, "agent", ""))
	display_name := extract_json_string(body, "display_name", extract_json_string(body, "alias", ""))
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	agent_id_ref := extract_json_string(body, "agent_id", "")
	config_path := extract_json_string(body, "config_path", server_config_path)
	// Starting by durable agent_id creates a fresh concrete instance. Supplying an
	// existing concrete/legacy agent_instance_id resumes that exact instance.
	if agent_id_ref == "" && agent_instance_id != "" && strings.index_byte(agent_instance_id, '@') < 0 && agent_record_index_by_instance(agent_instance_id) < 0 {
		agent_id_ref = agent_instance_id
		agent_instance_id = ""
	}
	if agent_id_ref != "" && agent_instance_id == "" {
		if task_service_agent_ref_looks_indexed_slot(agent_id_ref) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"indexed role slots are not durable agent_id values"}`)
			return
		}
		if safe_agent_id_part(agent_id_ref) != agent_id_ref {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_id"}`)
			return
		}
		agent_instance_id = agent_instance_id_new(agent_id_ref)
		if display_name == "" do display_name = agent_id_ref
		if template_id == "" {
			template_id = agent_id_template_id(agent_id_ref)
		}
	} else if agent_instance_id == "" {
		id_base := display_name if display_name != "" else template_id
		agent_instance_id = agent_generated_instance_id(id_base)
	}
	if display_name == "" do display_name = agent_instance_id
	if template_id == "" do template_id = derive_agent_class(agent_instance_id)
	if !valid_agent_instance_id(agent_instance_id) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`)
		return
	}
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 && agent_record_is_remote_proxy(agent_instance_records[idx]) {
		// Starting a remote_proxy must start the REAL agent on the owning peer,
		// not launch a local wrapper. Forward only explicit runtime overrides from
		// this request; local proxy records intentionally do not persist provider/tier.
		proxy := agent_instance_records[idx]
		start_ok, status_code, resp_body := federation_forward_start(proxy.remote_peer_id, proxy.remote_agent_instance_id, provider_profile, extract_json_string(body, "model_tier", ""), proxy.agent_instance_id)
		_ = start_ok
		write_response(client, status_code, federation_status_text(status_code), resp_body)
		return
	}
	if provider_profile != "" && !agent_provider_profile_supported(provider_profile) {
		write_response(client, 400, "Bad Request", agents_invalid_provider_profile_json(provider_profile))
		return
	}

	// Model tier is runtime-only launch info. Capture just the explicit request
	// override (if any); the durable value used to persist the instance is the
	// resolved operator/config default, not a per-instance memory.
	request_tier := extract_json_string(body, "model_tier", "")
	if request_tier != "" && !valid_model_tier(request_tier) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`)
		return
	}
	launch_model_tier := agent_resolve_model_tier(request_tier)

	log_path := wrapper_log_path(agent_instance_id)
	// /agents/start accepts provider/tier as launch overrides only. Never persist
	// explicit request provider/tier from a start call. Existing durable identities
	// keep their stored provider/tier; first-start records get operator/config
	// defaults so runtime roster choices do not become durable identity memory.
	persisted_provider_profile := agent_resolve_provider_profile("")
	persisted_model_tier := agent_resolve_model_tier("")
	if existing_idx := agent_record_index_by_instance(agent_instance_id); existing_idx >= 0 {
		persisted_provider_profile = agent_instance_records[existing_idx].provider_profile
		persisted_model_tier = agent_instance_records[existing_idx].model_tier
	} else if aid_idx := agent_id_index(agent_id_from_instance_id(agent_instance_id)); aid_idx >= 0 {
		identity := agent_id_records[aid_idx]
		if identity.default_provider_profile != "" do persisted_provider_profile = identity.default_provider_profile
		if identity.default_model_tier != "" do persisted_model_tier = identity.default_model_tier
	}
	agent_record_id, _, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, persisted_provider_profile, project_id, "", persisted_model_tier, "", project_id_set)
	if !upsert_ok {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`)
		return
	}
	// Reload project_id as resolved by upsert (may have fallen back to the stored
	// value if the caller didn't provide a fresh one). Provider is runtime-only
	// and intentionally NOT reloaded from the instance record here.
	resolved_project_id := project_id
	if idx := agent_record_index(agent_record_id); idx >= 0 {
		resolved_project_id = agent_instance_records[idx].project_id
	}
	// Provider and tier are runtime-only launch info: request override, else the
	// operator/config default. Neither is sourced from the durable instance record.
	provider_profile = agent_resolve_provider_profile(provider_profile)
	final_tier := launch_model_tier

	agent_token := auth_db_get_token("agent", agent_instance_id)
	if agent_token == "" do agent_token = generate_agent_token()
	if !agent_runtime_tracker_try_begin_launch(agent_instance_id, agent_token, "manual_agent_start", "", router_now_unix_ms()) {
		builder := strings.builder_make()
		strings.write_string(&builder, `{"ok":true,"mode":"remote_detached","message":"already running or launch in progress","agent_record_id":"`)
		json_write_string(&builder, agent_record_id)
		strings.write_string(&builder, `","agent_instance_id":"`)
		json_write_string(&builder, agent_instance_id)
		strings.write_string(&builder, `"}`)
		write_response(client, 200, "OK", strings.to_string(builder))
		return
	}
	registry_add_pending_agent_token(agent_instance_id, agent_token)
	ok := launch_wrapper_detached(agent_instance_id, provider_profile, config_path, log_path, agent_token, display_name, final_tier, resolved_project_id, "manual_agent_start")
	if !ok {
		agent_runtime_tracker_launch_failed(agent_instance_id, agent_token, "manual_agent_start")
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to start wrapper"}`)
		return
	}

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"mode":"remote_detached","message":"started","agent_record_id":"`)
	json_write_string(&builder, agent_record_id)
	strings.write_string(&builder, `","agent_instance_id":"`)
	json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","display_name":"`)
	json_write_string(&builder, display_name)
	strings.write_string(&builder, `","template_id":"`)
	json_write_string(&builder, template_id)
	strings.write_string(&builder, `","provider_profile":"`)
	json_write_string(&builder, provider_profile)
	strings.write_string(&builder, `","model_tier":"`)
	json_write_string(&builder, final_tier)
	strings.write_string(&builder, `","project_id":"`)
	json_write_string(&builder, resolved_project_id)
	strings.write_string(&builder, `","conversation_id":"`)
	json_write_string(&builder, conversation_id_for_instance(agent_instance_id))
	strings.write_string(&builder, `","agent_token":"`)
	json_write_string(&builder, agent_token)
	strings.write_string(&builder, `","wrapper_log":"`)
	json_write_string(&builder, log_path)
	strings.write_string(&builder, `"}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

agent_instance_record_json :: proc(builder: ^strings.Builder, rec: Agent_Instance_Record) {
	strings.write_string(builder, `{"agent_record_id":"`); json_write_string(builder, rec.agent_record_id)
	strings.write_string(builder, `","agent_instance_id":"`); json_write_string(builder, rec.agent_instance_id)
	// teams-v2: durable identity id (resolves to the Agent_Id_Record).
	agent_id_value := rec.agent_id; if agent_id_value == "" do agent_id_value = agent_id_from_instance_id(rec.agent_instance_id)
	strings.write_string(builder, `","agent_id":"`); json_write_string(builder, agent_id_value)
	strings.write_string(builder, `","display_name":"`); json_write_string(builder, rec.display_name)
	strings.write_string(builder, `","template_id":"`); json_write_string(builder, rec.template_id)
	agent_kind := agent_kind_normalize(rec.agent_kind)
	remote_status_for_json := Remote_Proxy_Status{}
	if agent_kind == AGENT_KIND_REMOTE_PROXY {
		remote_status_for_json, _ = remote_proxy_status_get(rec.agent_instance_id)
	}
	provider_profile_json := rec.provider_profile
	if agent_kind == AGENT_KIND_REMOTE_PROXY do provider_profile_json = remote_status_for_json.provider_profile
	strings.write_string(builder, `","agent_kind":"`); json_write_string(builder, agent_kind)
	strings.write_string(builder, `","provider_profile":"`); json_write_string(builder, provider_profile_json)
	strings.write_string(builder, `","project_id":"`); json_write_string(builder, rec.project_id)
	project_name := ""
	if rec.project_id != "" {
		if pidx := project_index(rec.project_id); pidx >= 0 do project_name = project_records[pidx].name
	}
	strings.write_string(builder, `","project_name":"`); json_write_string(builder, project_name)
	strings.write_string(builder, `","run_dir":"`); json_write_string(builder, rec.run_dir)
	model_tier := normalize_model_tier(rec.model_tier)
	if agent_kind == AGENT_KIND_REMOTE_PROXY {
		model_tier = remote_status_for_json.model_tier
	}
	strings.write_string(builder, `","model_tier":"`); json_write_string(builder, model_tier)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"archived_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.archived_at_unix_ms))
	strings.write_string(builder, `,"identity_state":"`); json_write_string(builder, agent_record_identity_state(rec)); strings.write_string(builder, `"`)
	strings.write_string(builder, `,"current_task_id":"`); json_write_string(builder, rec.current_task_id)
	strings.write_string(builder, `","current_task_since":`); strings.write_string(builder, fmt.tprintf("%d", rec.current_task_since))
	strings.write_string(builder, `,"last_needed_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.last_needed_at_unix_ms))
	strings.write_string(builder, `,"state":"`); json_write_string(builder, agent_store_agent_state(rec)); strings.write_string(builder, `"`)
	strings.write_string(builder, `,"order":`); strings.write_string(builder, fmt.tprintf("%d", rec.order))
	if agent_kind == AGENT_KIND_REMOTE_PROXY {
		resolved_origin_daemon_id, _ := agent_remote_proxy_origin_daemon_id(rec)
		strings.write_string(builder, `,"remote":{"peer_id":"`); json_write_string(builder, rec.remote_peer_id)
		strings.write_string(builder, `","origin_daemon_id":"`); json_write_string(builder, resolved_origin_daemon_id)
		strings.write_string(builder, `","remote_agent_instance_id":"`); json_write_string(builder, rec.remote_agent_instance_id)
		// Real liveness/runtime metadata propagated from the origin (Part B). Peer-link
		// reachability overrides last-known status: a proxy to an unreachable peer reads offline.
		peer_reachable := federation_peer_reachable(rec.remote_peer_id)
		remote_status := remote_status_for_json
		effective_status := remote_status.status
		if !peer_reachable do effective_status = FEDERATION_AGENT_STATUS_OFFLINE
		remote_live := peer_reachable && federation_agent_status_is_live(remote_status.status)
		strings.write_string(builder, `","status":"`); json_write_string(builder, effective_status)
		strings.write_string(builder, `","connection_state":"`); json_write_string(builder, "connected" if remote_live else "offline")
		strings.write_string(builder, `","connected":`); strings.write_string(builder, "true" if remote_live else "false")
		strings.write_string(builder, `,"current_task_id":"`); json_write_string(builder, remote_status.current_task_id)
		strings.write_string(builder, `","provider_profile":"`); json_write_string(builder, remote_status.provider_profile)
		strings.write_string(builder, `","model_tier":"`); json_write_string(builder, remote_status.model_tier)
		strings.write_string(builder, `","last_seen_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", remote_status.last_seen_unix_ms))
		strings.write_string(builder, `,"peer_reachable":`); strings.write_string(builder, "true" if peer_reachable else "false")
		strings.write_string(builder, `}`)
	}
	strings.write_string(builder, `,"conversation_id":"`); json_write_string(builder, conversation_id_for_instance(rec.agent_instance_id))
	if live_idx := registry_find_agent(rec.agent_instance_id); live_idx >= 0 {
		agent := agents[live_idx]
		strings.write_string(builder, `","tmux_pane":"`); json_write_string(builder, agent.tmux_pane)
		strings.write_string(builder, `","connected":`); strings.write_string(builder, "true" if agent.connected else "false")
		strings.write_string(builder, `,"connection_state":"`); json_write_string(builder, "connected" if agent.connected else "registered")
		strings.write_string(builder, `","last_seen_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.last_seen_unix_ms))
		strings.write_string(builder, `,"startup_status":"`); json_write_string(builder, agent.startup_status)
		strings.write_string(builder, `","startup_reason_code":"`); json_write_string(builder, agent.startup_reason_code)
		strings.write_string(builder, `","safe_diagnostic":"`); json_write_string(builder, agent.startup_safe_diagnostic)
		strings.write_string(builder, `","startup_updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.startup_updated_unix_ms))
		strings.write_string(builder, `,"activity_status":"`); json_write_string(builder, agent.activity_status)
		strings.write_string(builder, `","activity_source":"`); json_write_string(builder, agent.activity_source)
		strings.write_string(builder, `","activity_checked_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.activity_checked_unix_ms))
		strings.write_string(builder, `,"exec_state":"`); json_write_string(builder, agent.exec_state)
		strings.write_string(builder, `","exec_state_since_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", agent.exec_state_since_unix_ms))
		strings.write_string(builder, `,"blocked_reason":"`); json_write_string(builder, agent.blocked_reason); strings.write_string(builder, `"`)
	} else {
		strings.write_string(builder, `","tmux_pane":"","connected":false,"connection_state":"offline","activity_status":"unknown","activity_source":"","activity_checked_unix_ms":0,"exec_state":"","exec_state_since_unix_ms":0,"blocked_reason":""`)
	}
	strings.write_string(builder, `}`)
}

write_agent_ok_response :: proc(client: net.TCP_Socket, message: string, rec: Agent_Instance_Record) {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"message":"`); json_write_string(&b, message); strings.write_string(&b, `","agent":`); agent_instance_record_json(&b, rec); strings.write_string(&b, `}`); write_response(client, 200, "OK", strings.to_string(b))
}

agent_id_record_json :: proc(builder: ^strings.Builder, rec: Agent_Id_Record) {
	strings.write_string(builder, `{"kind":"identity","agent_id":"`); json_write_string(builder, rec.agent_id)
	strings.write_string(builder, `","display_name":"`); json_write_string(builder, rec.display_name if rec.display_name != "" else rec.agent_id)
	strings.write_string(builder, `","template_id":"`); json_write_string(builder, rec.template_id)
	strings.write_string(builder, `","default_provider_profile":"`); json_write_string(builder, rec.default_provider_profile)
	strings.write_string(builder, `","default_model_tier":"`); json_write_string(builder, normalize_model_tier(rec.default_model_tier if rec.default_model_tier != "" else "normal"))
	strings.write_string(builder, `","default_project_id":"`); json_write_string(builder, rec.default_project_id)
	strings.write_string(builder, `","state":"`); json_write_string(builder, rec.state if rec.state != "" else AGENT_ID_STATE_ACTIVE)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `}`)
}

query_param :: proc(request, name: string) -> string {
	first := strings.index_byte(request, ' ')
	if first < 0 do return ""
	second := strings.index_byte(request[first + 1:], ' ')
	if second < 0 do return ""
	path := request[first + 1:first + 1 + second]
	q := strings.index_byte(path, '?')
	if q < 0 do return ""
	query := path[q + 1:]
	key := fmt.tprintf("%s=", name)
	idx := strings.index(query, key)
	if idx < 0 do return ""
	start := idx + len(key)
	end := strings.index_byte(query[start:], '&')
	if end < 0 do return query[start:]
	return query[start:start + end]
}

launch_wrapper_detached :: proc(agent_instance_id, selected_agent, config_path, log_path, agent_token, display_name, model_tier, project_id: string, launch_source: string = "", chain_id: string = "", task_id: string = "") -> bool {
	spawn_start_ms := router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=wrapper_spawn_build_begin source=%s chain=%s task=%s target=%s provider=%s tier=%s project=%s log=%s", spawn_start_ms, launch_source, chain_id, task_id, agent_instance_id, selected_agent, model_tier, project_id, log_path)
	_ = os.make_directory_all(parent_dir(log_path))
	wrapper_bin := default_wrapper_bin()

	builder := strings.builder_make()
	strings.write_string(&builder, "nohup ")
	strings.write_string(&builder, shell_quote(wrapper_bin))
	strings.write_string(&builder, " --overwrite --config ")
	strings.write_string(&builder, shell_quote(config_path))
	if selected_agent != "" {
		strings.write_string(&builder, " --agent ")
		strings.write_string(&builder, shell_quote(selected_agent))
	}
	if agent_token != "" {
		strings.write_string(&builder, " --agent-token ")
		strings.write_string(&builder, shell_quote(agent_token))
	}
	if display_name != "" {
		strings.write_string(&builder, " --display-name ")
		strings.write_string(&builder, shell_quote(display_name))
	}
	tier := normalize_model_tier(model_tier)
	strings.write_string(&builder, " --tier ")
	strings.write_string(&builder, shell_quote(tier))
	if project_id != "" {
		strings.write_string(&builder, " --project-id ")
		strings.write_string(&builder, shell_quote(project_id))
	}
	if task_id != "" {
		strings.write_string(&builder, " --current-task-id ")
		strings.write_string(&builder, shell_quote(task_id))
	}
	strings.write_string(&builder, " ")
	strings.write_string(&builder, shell_quote(agent_instance_id))
	strings.write_string(&builder, " > ")
	strings.write_string(&builder, shell_quote(log_path))
	strings.write_string(&builder, " 2>&1 < /dev/null &")

	cmd := strings.to_string(builder)
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_process_start_begin source=%s chain=%s task=%s target=%s wrapper_bin=%s", router_now_unix_ms(), router_now_unix_ms() - spawn_start_ms, launch_source, chain_id, task_id, agent_instance_id, wrapper_bin)
	process, err := os.process_start(os.Process_Desc{command = []string{"sh", "-c", cmd}})
	if err != nil {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_process_start_failed source=%s chain=%s task=%s target=%s", router_now_unix_ms(), router_now_unix_ms() - spawn_start_ms, launch_source, chain_id, task_id, agent_instance_id)
		fmt.println("wrapper launch failed")
		return false
	}
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_process_start_done source=%s chain=%s task=%s target=%s shell_pid=%v", router_now_unix_ms(), router_now_unix_ms() - spawn_start_ms, launch_source, chain_id, task_id, agent_instance_id, process.handle)
	_ = process
	return true
}

default_wrapper_bin :: proc() -> string {
	if server_wrapper_bin != "" do return server_wrapper_bin
	if len(os.args) > 0 {
		exe := os.args[0]
		slash := strings.last_index_byte(exe, '/')
		if slash >= 0 do return fmt.tprintf("%s/ham-wrapper", exe[:slash])
	}
	return "ham-wrapper"
}

wrapper_log_path :: proc(agent_instance_id: string) -> string {
	data_dir := expand_home(server_data_dir)
	return fmt.tprintf("%s/logs/wrapper-%s.log", data_dir, safe_path_part(agent_instance_id))
}

parent_dir :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 do return "."
	return path[:slash]
}

expand_home :: proc(path: string) -> string {
	home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if home == "" {
		home = os.get_env_alloc("HOME", context.allocator)
	}
	if path == "~" {
		if home != "" do return home
	}
	if strings.has_prefix(path, "~/") {
		if home != "" do return fmt.tprintf("%s/%s", home, path[2:])
	}
	return path
}

safe_path_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

shell_quote :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "'")
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "'\\''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	strings.write_string(&builder, "'")
	return strings.to_string(builder)
}

handle_agent_template_create_update :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", "")
	if template_id == "" { write_response(client, 400, "Bad Request", `{"ok":false,"message":"template_id required"}`); return }
	ev: Agent_Template_Event
	ev.kind = .Agent_Template_Upserted
	ev.template_id = template_id
	ev.display_name = extract_json_string(body, "display_name", template_id)
	ev.description = extract_json_string(body, "description", "")
	ev.persona = extract_json_string(body, "persona", "")
	ev.instructions = extract_json_string(body, "instructions", "")
	ev.parent_template_id = extract_json_string(body, "parent_template_id", "")
	ev.default_provider_profile = extract_json_string(body, "default_provider_profile", extract_json_string(body, "provider_profile", ""))
	ev.bootstrap_defaults = extract_json_string(body, "bootstrap_defaults", "")
	ev.suggested_model_tier = extract_json_string(body, "suggested_model_tier", "normal")
	ev.author = "api"
	agent_parse_string_array_field(body, "memory_templates", &ev.memory_templates, &ev.memory_template_count)
	if !agent_template_append_event(ev) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent template"}`); return }
	idx := agent_template_index(template_id)
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"template":`); agent_template_record_json(&b, agent_template_records[idx]); strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agent_template_show :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", query_param(body, "template_id"))
	idx := agent_template_index(template_id)
	if idx < 0 || agent_template_records[idx].archived_at_unix_ms != 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"template not found"}`); return }
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"template":`); agent_template_record_json(&b, agent_template_records[idx]); strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agent_template_archive :: proc(client: net.TCP_Socket, body: string) {
	template_id := extract_json_string(body, "template_id", "")
	if agent_template_index(template_id) < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"template not found"}`); return }
	if !agent_template_append_event(Agent_Template_Event{kind = .Agent_Template_Archived, template_id = template_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to archive agent template"}`); return }
	write_response(client, 200, "OK", `{"ok":true,"message":"archived"}`)
}

handle_agent_instance_show :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 || agent_instance_records[idx].archived_at_unix_ms != 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	write_agent_ok_response(client, "ok", agent_instance_records[idx])
}

handle_agent_instance_update :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	display_name := extract_json_string(body, "display_name", rec.display_name)
	template_id := extract_json_string(body, "template_id", rec.template_id)
	provider_profile := extract_json_string(body, "provider_profile", rec.provider_profile)
	project_id := extract_json_string(body, "project_id", rec.project_id)
	if strings.trim_space(project_id) != "" && !project_exists(project_id) { write_response(client, 400, "Bad Request", agents_invalid_project_json(project_id)); return }
	run_dir := extract_json_string(body, "run_dir", rec.run_dir)
	model_tier := normalize_model_tier(rec.model_tier)
	if req_tier := extract_json_string(body, "model_tier", ""); req_tier != "" {
		if !valid_model_tier(req_tier) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`); return }
		model_tier = normalize_model_tier(req_tier)
	}
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Upserted, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, display_name = display_name, template_id = template_id, provider_profile = provider_profile, project_id = project_id, run_dir = run_dir, model_tier = model_tier, agent_kind = rec.agent_kind, remote_peer_id = rec.remote_peer_id, remote_origin_daemon_id = rec.remote_origin_daemon_id, remote_agent_instance_id = rec.remote_agent_instance_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`); return }
	// Agents tab identity edits update the durable agent_id defaults (provider /
	// tier / default project) that seed every future concrete instance. The flag
	// keeps ordinary per-instance updates from mutating shared identity defaults.
	if extract_json_bool(body, "update_agent_id_defaults", false) {
		resolved_agent_id := agent_id_from_instance_id(rec.agent_instance_id)
		_ = agent_id_update_defaults(resolved_agent_id, display_name, provider_profile, model_tier, project_id, "api")
	}
	write_agent_ok_response(client, "updated", agent_instance_records[agent_record_index(rec.agent_record_id)])
}

// handle_agent_id_update edits a DURABLE agent identity (agent_id) directly,
// without needing a concrete running instance. This is the identity-level edit:
// it changes the shared defaults (display name, provider, tier, default project)
// that seed every FUTURE instance of this agent_id. It does NOT touch existing
// instance records — per-instance overrides live on the instance and are changed
// via /agents/update. Separation of concerns:
//   /agent-ids/update  -> durable identity defaults (this handler)
//   /agents/update      -> one concrete agent_instance's own settings
handle_agent_id_update :: proc(client: net.TCP_Socket, body: string) {
	agent_id := strings.trim_space(extract_json_string(body, "agent_id", ""))
	if agent_id == "" { write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_id required"}`); return }
	idx := agent_id_index(agent_id)
	if idx < 0 || agent_id_records[idx].archived_at_unix_ms != 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent_id not found"}`); return }
	rec := agent_id_records[idx]
	display_name := extract_json_string(body, "display_name", rec.display_name)
	provider_profile := extract_json_string(body, "provider_profile", rec.default_provider_profile)
	model_tier := normalize_model_tier(rec.default_model_tier)
	if req_tier := extract_json_string(body, "model_tier", extract_json_string(body, "default_model_tier", "")); req_tier != "" {
		if !valid_model_tier(req_tier) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`); return }
		model_tier = normalize_model_tier(req_tier)
	}
	// default_project: applied verbatim (empty clears) so this endpoint can both
	// set and unset a durable default project. Reject a non-existent, non-empty id.
	project_id := extract_json_string(body, "default_project_id", extract_json_string(body, "project_id", rec.default_project_id))
	if strings.trim_space(project_id) != "" && !project_exists(project_id) { write_response(client, 400, "Bad Request", agents_invalid_project_json(project_id)); return }
	if !agent_id_update_defaults(agent_id, display_name, provider_profile, model_tier, project_id, "api") {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to update agent identity"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message":"updated","identity":`)
	if new_idx := agent_id_index(agent_id); new_idx >= 0 { agent_id_record_json(&b, agent_id_records[new_idx]) } else { strings.write_string(&b, `null`) }
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agent_instance_create :: proc(client: net.TCP_Socket, body: string) {
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	agent_id_ref := extract_json_string(body, "agent_id", "")
	display_name := extract_json_string(body, "display_name", extract_json_string(body, "name", ""))
	provider_profile := extract_json_string(body, "provider_profile", extract_json_string(body, "agent", ""))
	template_id := extract_json_string(body, "template_id", "")
	project_id := extract_json_string(body, "project_id", "")
	model_tier := extract_json_string(body, "model_tier", "")

	created_from_agent_id := false
	if agent_id_ref != "" && agent_instance_id == "" {
		if task_service_agent_ref_looks_indexed_slot(agent_id_ref) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"indexed role slots are not durable agent_id values"}`)
			return
		}
		if safe_agent_id_part(agent_id_ref) != agent_id_ref {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_id"}`)
			return
		}
		if agent_instance_id_is_reserved(agent_id_ref) {
			write_response(client, 400, "Bad Request", `{"ok":false,"message":"reserved agent_id cannot be created"}`)
			return
		}
		created_from_agent_id = true
		agent_instance_id = agent_instance_id_new(agent_id_ref)
		if idx := agent_id_index(agent_id_ref); idx >= 0 {
			identity := agent_id_records[idx]
			if identity.archived_at_unix_ms != 0 { write_response(client, 400, "Bad Request", `{"ok":false,"message":"agent_id is archived"}`); return }
			if display_name == "" do display_name = identity.display_name
			if template_id == "" do template_id = identity.template_id
			if provider_profile == "" do provider_profile = identity.default_provider_profile
			if model_tier == "" do model_tier = identity.default_model_tier
			if project_id == "" do project_id = identity.default_project_id
		}
	}

	if strings.trim_space(project_id) != "" && !project_exists(project_id) { write_response(client, 400, "Bad Request", agents_invalid_project_json(project_id)); return }
	if model_tier == "" do model_tier = "normal"
	if !valid_model_tier(model_tier) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid model_tier; expected cheap, normal, or smart"}`); return }
	model_tier = normalize_model_tier(model_tier)
	if agent_instance_id == "" {
		id_base := display_name if display_name != "" else template_id
		agent_instance_id = agent_generated_instance_id(id_base)
	}
	if display_name == "" do display_name = agent_id_ref if agent_id_ref != "" else agent_instance_id
	if template_id == "" do template_id = agent_id_template_id(agent_id_ref) if agent_id_ref != "" else derive_agent_class(agent_instance_id)
	// teams-v2: reserved identities (operator@local, user_proxy) are not creatable.
	if agent_instance_id_is_reserved(agent_instance_id) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"reserved agent_instance_id cannot be created"}`); return }
	if !valid_agent_instance_id(agent_instance_id) { write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid agent_instance_id"}`); return }
	resolved_agent_id := agent_id_from_instance_id(agent_instance_id)
	// Explicit instance creation remains an identity-default create/update. Creating
	// a new instance from an existing durable agent_id must not rewrite that
	// identity's defaults with a one-off picker provider/tier override.
	if !created_from_agent_id || !agent_id_exists(resolved_agent_id) {
		agent_id_upsert(resolved_agent_id, display_name, template_id, provider_profile, model_tier, project_id, "api")
	}
	agent_record_id, _, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, provider_profile, project_id, "", model_tier, AGENT_IDENTITY_STATE_PROVISIONED)
	if !upsert_ok { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent instance"}`); return }
	rec := agent_instance_records[agent_record_index(agent_record_id)]
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"message":"created","started":false,"agent_id":"`); json_write_string(&b, resolved_agent_id)
	strings.write_string(&b, `","agent_instance_id":"`); json_write_string(&b, rec.agent_instance_id)
	strings.write_string(&b, `","agent":`); agent_instance_record_json(&b, rec)
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agent_instance_archive :: proc(client: net.TCP_Socket, body: string) {
	agent_record_id := extract_json_string(body, "agent_record_id", "")
	agent_instance_id := extract_json_string(body, "agent_instance_id", "")
	idx := agent_record_index(agent_record_id)
	if idx < 0 && agent_instance_id != "" do idx = agent_record_index_by_instance(agent_instance_id)
	if idx < 0 { write_response(client, 404, "Not Found", `{"ok":false,"message":"agent not found"}`); return }
	rec := agent_instance_records[idx]
	if !agent_store_append_event(Agent_Instance_Event{kind = .Agent_Instance_Archived, agent_record_id = rec.agent_record_id, agent_instance_id = rec.agent_instance_id, author = "api"}) { write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to archive agent instance"}`); return }
	write_response(client, 200, "OK", `{"ok":true,"message":"archived"}`)
}

agent_template_record_json :: proc(builder: ^strings.Builder, rec: Agent_Template_Record) {
	strings.write_string(builder, `{"template_id":"`); json_write_string(builder, rec.template_id)
	strings.write_string(builder, `","display_name":"`); json_write_string(builder, rec.display_name)
	strings.write_string(builder, `","description":"`); json_write_string(builder, rec.description)
	strings.write_string(builder, `","persona":"`); json_write_string(builder, rec.persona)
	strings.write_string(builder, `","instructions":"`); json_write_string(builder, rec.instructions)
	strings.write_string(builder, `","parent_template_id":"`); json_write_string(builder, rec.parent_template_id)
	strings.write_string(builder, `","default_provider_profile":"`); json_write_string(builder, rec.default_provider_profile)
	strings.write_string(builder, `","bootstrap_defaults":"`); json_write_string(builder, rec.bootstrap_defaults)
	strings.write_string(builder, `","suggested_model_tier":"`); json_write_string(builder, rec.suggested_model_tier)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"archived_at_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.archived_at_unix_ms))
	strings.write_string(builder, `,"memory_templates":[`)
	for i in 0..<rec.memory_template_count { if i > 0 do strings.write_string(builder, `,`); strings.write_string(builder, `"`); json_write_string(builder, rec.memory_templates[i]); strings.write_string(builder, `"`) }
	strings.write_string(builder, `]}`)
}

handle_agents_test_connectivity :: proc(client: net.TCP_Socket, body: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"results":[`)
	
	target_providers_str := extract_json_string(body, "providers", "")
	
	first := true
	
	// Helper to check if a provider should be tested
	should_test := proc(name: string, filter: string) -> bool {
		if filter == "" do return true
		
		// Simple comma-separated substring check
		parts := strings.split(filter, ",")
		defer delete(parts)
		for part in parts {
			if strings.trim_space(part) == name do return true
		}
		return false
	}
	
	if len(server_config.wrapper.agent_commands) > 0 {
		for cmd in server_config.wrapper.agent_commands {
			if !should_test(cmd.name, target_providers_str) do continue
			
			if !first do strings.write_string(&b, ",")
			first = false
			
			success, err_msg := test_single_agent_command(cmd.name, cmd.command)
			fmt.sbprintf(&b, `{"name":"%s","ok":%t,"message":"%s"}`, cmd.name, success, err_msg)
		}
	}
	
	if len(server_config.wrapper.command) > 0 {
		if should_test("default", target_providers_str) {
			if !first do strings.write_string(&b, ",")
			success, err_msg := test_single_agent_command("default", server_config.wrapper.command)
			fmt.sbprintf(&b, `{"name":"default","ok":%t,"message":"%s"}`, success, err_msg)
		}
	}
	
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

test_single_agent_command :: proc(name: string, command_slice: []string) -> (ok: bool, message: string) {
	if len(command_slice) == 0 do return false, "No command configured"
	
	exe := command_slice[0]
	
	desc := os.Process_Desc{
		command = []string{"which", exe},
	}
	
	process, err := os.process_start(desc)
	if err != nil {
		return false, fmt.tprintf("Failed to execute check: %v", err)
	}
	
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		return false, fmt.tprintf("Failed to wait for check: %v", wait_err)
	}
	
	if !state.success {
		return false, fmt.tprintf("Executable '%s' not found or not runnable on this system.", exe)
	}
	
	return true, fmt.tprintf("Executable verified: %s", exe)
}

handle_agent_reorder :: proc(client: net.TCP_Socket, body: string) {
	agent_ids := extract_json_string_array(body, "agent_ids")
	defer {
		for s in agent_ids do delete(s)
		delete(agent_ids)
	}
	for id, order in agent_ids {
		idx := agent_record_index_by_instance(id)
		if idx < 0 do continue
		rec := agent_instance_records[idx]
		event := Agent_Instance_Event{
			kind = .Agent_Instance_Upserted,
			agent_record_id = rec.agent_record_id,
			agent_instance_id = rec.agent_instance_id,
			display_name = rec.display_name,
			template_id = rec.template_id,
			provider_profile = rec.provider_profile,
			project_id = rec.project_id,
			run_dir = rec.run_dir,
			model_tier = rec.model_tier,
			agent_kind = rec.agent_kind,
			remote_peer_id = rec.remote_peer_id,
			remote_origin_daemon_id = rec.remote_origin_daemon_id,
			remote_agent_instance_id = rec.remote_agent_instance_id,
			state = rec.state,
			current_task_id = rec.current_task_id,
			current_task_since = rec.current_task_since,
			last_needed_at_unix_ms = rec.last_needed_at_unix_ms,
			order = order,
			author = "api",
		}
		if !agent_store_append_event(event) {
			write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to persist agent reorder event"}`)
			return
		}
	}
	write_response(client, 200, "OK", `{"ok":true,"message":"agents reordered"}`)
}
