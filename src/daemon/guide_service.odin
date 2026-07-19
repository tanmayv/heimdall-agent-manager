package main

import "core:fmt"
import cfg_lib "odin_test:lib/config"

GUIDE_AGENT_DEFAULT_ID :: "guide@heimdall"
GUIDE_AGENT_DEFAULT_PROJECT_ID :: "heimdall-system"

guide_agent_instance_id :: proc() -> string {
	id := server_config.guide_agent.agent_instance_id
	if id == "" do return GUIDE_AGENT_DEFAULT_ID
	return id
}

guide_agent_template_id :: proc() -> string {
	template_id := server_config.guide_agent.template_id
	if template_id == "" do return "guide"
	return template_id
}

guide_agent_is_singleton :: proc(agent_instance_id: string) -> bool {
	return agent_instance_id == guide_agent_instance_id()
}

guide_service_start :: proc(cfg: cfg_lib.Guide_Agent_Config, source: string = "guide_startup") -> bool {
	if !cfg.enabled || !cfg.autostart {
		fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d stage=skip source=%s enabled=%t autostart=%t", router_now_unix_ms(), source, cfg.enabled, cfg.autostart)
		return false
	}
	agent_id := cfg.agent_instance_id
	if agent_id == "" do agent_id = GUIDE_AGENT_DEFAULT_ID
	template_id := cfg.template_id
	if template_id == "" do template_id = "guide"
	if durable := agent_id_from_instance_id(agent_id); durable != "" {
		if idx := agent_id_index(durable); idx >= 0 && agent_id_records[idx].template_id != "" do template_id = agent_id_records[idx].template_id
		delete(durable)
	}
	provider_profile := cfg.provider_profile
	if provider_profile == "" do provider_profile = server_config.daemon.default_agent_provider_profile
	if provider_profile == "" do provider_profile = "pi"
	model_tier := cfg.model_tier
	if model_tier == "" do model_tier = "smart"
	project_id := GUIDE_AGENT_DEFAULT_PROJECT_ID
	display_name := "Heimdall Guide"
	start_ms := router_now_unix_ms()
	fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d stage=record_upsert_begin source=%s target=%s template=%s provider=%s tier=%s project=%s", start_ms, source, agent_id, template_id, provider_profile, model_tier, project_id)
	rec_id, final_tier, upsert_ok := agent_record_upsert(agent_id, display_name, template_id, provider_profile, project_id, "", model_tier)
	if !upsert_ok || rec_id == "" {
		fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=record_upsert_failed source=%s target=%s", router_now_unix_ms(), router_now_unix_ms() - start_ms, source, agent_id)
		return false
	}
	agent_token := auth_db_get_token("agent", agent_id)
	if agent_token == "" do agent_token = generate_agent_token()
	if !agent_runtime_tracker_try_begin_launch(agent_id, agent_token, source, "", router_now_unix_ms()) {
		fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=skip source=%s target=%s skip_reason=agent_tracker", router_now_unix_ms(), router_now_unix_ms() - start_ms, source, agent_id)
		return false
	}
	registry_add_pending_agent_token(agent_id, agent_token)
	log_path := wrapper_log_path(agent_id)
	fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_spawn_request source=%s target=%s record=%s provider=%s tier=%s project=%s log=%s", router_now_unix_ms(), router_now_unix_ms() - start_ms, source, agent_id, rec_id, provider_profile, final_tier, project_id, log_path)
	ok := launch_wrapper_detached(agent_id, provider_profile, server_config_path, log_path, agent_token, display_name, final_tier, project_id, source)
	if !ok do agent_runtime_tracker_launch_failed(agent_id, agent_token, source)
	fmt.printfln("GUIDE_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_spawn_result source=%s target=%s ok=%t", router_now_unix_ms(), router_now_unix_ms() - start_ms, source, agent_id, ok)
	return ok
}
