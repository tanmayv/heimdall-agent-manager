package agent

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import project_service "odin_test:hub/service/project"
import platform "odin_test:hub/platform"

Agent_Service :: struct {
	agents: ^iface.Agent_Repository,
	bridges: ^iface.Bridge_Repository,
	projects: ^iface.Project_Repository,
	content: ^iface.Content_Repository,
	taskchains: ^iface.Taskchain_Repository,
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
}

Create_Agent_Input :: struct {
	name: string,
	slug: string,
	template_id: string,
	default_provider: string,
	default_tier: string,
	instructions: string,
	has_default_provider: bool,
	has_default_tier: bool,
}

Support_Input :: struct {
	bridge_id: string,
	enabled: bool,
	provider: string,
	tier: string,
	priority: int,
	max_instances: int,
}

Run_Request :: struct {
	provider: string,
	tier: string,
}

List_Instances_Filter :: struct {
	agent_id: string,
	bridge_id: string,
	runtime_status: string,
}

Create_Instance_Input :: struct {
	agent_id: string,
	bridge_id: string,
	provider: string,
	tier: string,
	project_id: domain.Project_ID,
	chain_id: string,
}

Stop_Instance_Input :: struct { reason: string }
Reconfigure_Instance_Input :: struct { provider, tier, agent_id, bridge_id, chain_id, conversation_id: string, project_id: domain.Project_ID, has_agent_id, has_bridge_id, has_project_id, has_chain_id, has_conversation_id: bool }

new_agent_service :: proc(agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	return Agent_Service{agents = agents, bridges = bridges, clock = clock, ids = ids}
}

new_agent_service_with_runtime :: proc(agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, projects: ^iface.Project_Repository, content: ^iface.Content_Repository, taskchains: ^iface.Taskchain_Repository, sink: project_service.Bridge_Command_Sink, registry: ^project_service.Bridge_Runtime_Registry, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	return Agent_Service{agents = agents, bridges = bridges, projects = projects, content = content, taskchains = taskchains, bridge_command_sink = sink, bridge_runtime_registry = registry, clock = clock, ids = ids}
}

create_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Agent_Input) -> (domain.Agent, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Agent{}, false, err
	if strings.trim_space(input.name) == "" do return domain.Agent{}, false, domain.domain_error(.Validation_Failed, "agent name is required")
	slug := input.slug
	if slug == "" do slug = input.name
	now := platform.clock_now(service.clock)
	agent := domain.Agent{agent_id = platform.generate_id(service.ids, "agt_"), owner_user_id = owner, name = input.name, slug = slug, template_id = input.template_id, default_provider = input.default_provider, default_tier = input.default_tier, instructions = input.instructions, state = .Active, created_at = now, updated_at = now}
	return iface.agent_save(service.agents, agent)
}

list_agents :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, limit: int = 50, cursor: string = "") -> ([]domain.Agent, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.agent_list_by_owner(service.agents, owner, limit, cursor)
}

get_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := iface.agent_get(service.agents, agent_id)
	if !ok do return domain.Agent{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, agent.owner_user_id); !owner_ok do return domain.Agent{}, false, owner_err
	return agent, true, domain.Domain_Error{}
}

update_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string, input: Create_Agent_Input) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent{}, false, err
	if input.name != "" do agent.name = input.name
	if input.slug != "" do agent.slug = input.slug
	if input.has_default_provider || input.default_provider != "" do agent.default_provider = input.default_provider
	if input.has_default_tier || input.default_tier != "" do agent.default_tier = input.default_tier
	if input.instructions != "" do agent.instructions = input.instructions
	agent.updated_at = platform.clock_now(service.clock)
	return iface.agent_save(service.agents, agent)
}

archive_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent{}, false, err
	agent.state = .Archived
	agent.updated_at = platform.clock_now(service.clock)
	return iface.agent_save(service.agents, agent)
}

list_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> ([]domain.Agent_Bridge_Support, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return nil, err
	return iface.agent_list_support(service.agents, agent.agent_id, agent.owner_user_id)
}

upsert_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string, input: Support_Input) -> (domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Agent_Bridge_Support{}, false, err
	if valid, validate_err := validate_support_input(service, auth, agent, input); !valid do return domain.Agent_Bridge_Support{}, false, validate_err
	now := platform.clock_now(service.clock)
	existing, existing_ok, _ := iface.agent_get_support(service.agents, agent_id, input.bridge_id)
	created_at := now
	if existing_ok do created_at = existing.created_at
	support := domain.Agent_Bridge_Support{agent_id = agent.agent_id, bridge_id = input.bridge_id, owner_user_id = agent.owner_user_id, enabled = input.enabled, provider = input.provider, tier = input.tier, priority = input.priority, max_instances = input.max_instances, created_at = created_at, updated_at = now}
	return iface.agent_save_support(service.agents, support)
}

validate_support_input :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent: domain.Agent, input: Support_Input) -> (bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, input.bridge_id)
	if !bridge_ok do return false, bridge_err
	if owner_ok, owner_err := ownership.require_owner(auth, bridge.owner_user_id); !owner_ok do return false, owner_err
	if bridge.owner_user_id != agent.owner_user_id do return false, domain.domain_error(.Not_Found, "bridge not found")
	if input.max_instances < 0 do return false, domain.domain_error(.Validation_Failed, "max_instances must be positive")
	if !input.enabled do return true, domain.Domain_Error{}
	// AgentBridgeSupport does not allowlist provider/tier. Enabling a bridge is
	// allowed even when the agent's global default is not supported there; runtime
	// resolution will return provider_unavailable and the UI can prompt for an
	// override. Only validate explicit support-level preferred defaults against
	// the bridge's real capability matrix.
	if strings.trim_space(input.provider) != "" {
		if !bridge_supports_provider(bridge, input.provider) do return false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("bridge does not support provider %s", input.provider))
		if strings.trim_space(input.tier) != "" && !bridge_supports_provider_tier(bridge, input.provider, input.tier) do return false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("bridge does not support provider/tier %s/%s", input.provider, input.tier))
		return true, domain.Domain_Error{}
	}
	if strings.trim_space(input.tier) != "" && !bridge_supports_any_provider_tier(bridge, input.tier) do return false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("bridge does not support tier %s for any configured provider", input.tier))
	return true, domain.Domain_Error{}
}

replace_supports :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string, inputs: []Support_Input) -> ([]domain.Agent_Bridge_Support, bool, domain.Domain_Error) {
	agent, agent_ok, agent_err := get_agent(service, auth, agent_id)
	if !agent_ok do return nil, false, agent_err
	for input in inputs {
		if valid, validate_err := validate_support_input(service, auth, agent, input); !valid do return nil, false, validate_err
	}
	existing, list_err := iface.agent_list_support(service.agents, agent.agent_id, agent.owner_user_id)
	if list_err.code != .None do return nil, false, list_err
	for support in existing {
		_, delete_err := iface.agent_delete_support(service.agents, agent.agent_id, support.bridge_id, agent.owner_user_id)
		if delete_err.code != .None do return nil, false, delete_err
	}
	out := make([dynamic]domain.Agent_Bridge_Support)
	for input in inputs {
		support, saved, save_err := upsert_support(service, auth, agent_id, input)
		if !saved do return nil, false, save_err
		append(&out, support)
	}
	return out[:], true, domain.Domain_Error{}
}

delete_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id, bridge_id: string) -> (bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return false, err
	return iface.agent_delete_support(service.agents, agent.agent_id, bridge_id, agent.owner_user_id)
}

default_support_for_agent_bridge :: proc(agent: domain.Agent, bridge_id: string) -> domain.Agent_Bridge_Support {
	return domain.Agent_Bridge_Support{agent_id = agent.agent_id, bridge_id = bridge_id, owner_user_id = agent.owner_user_id, enabled = true}
}

create_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, input: Create_Instance_Input) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	owner, owner_ok, owner_err := ownership.owner_from_auth(auth)
	if !owner_ok do return domain.Agent_Instance{}, false, owner_err
	agent, agent_ok, agent_err := get_agent(service, auth, input.agent_id)
	if !agent_ok do return domain.Agent_Instance{}, false, agent_err
	bridge_id := strings.trim_space(input.bridge_id)
	if bridge_id == "" do return domain.Agent_Instance{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required; choose the bridge to run this agent on")
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return domain.Agent_Instance{}, false, bridge_err
	if bridge.owner_user_id != owner || bridge.owner_user_id != agent.owner_user_id do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, bridge.bridge_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	resolved, resolved_ok, resolved_err := resolve_provider_tier(service, auth, agent.agent_id, bridge.bridge_id, Run_Request{provider = input.provider, tier = input.tier})
	if !resolved_ok do return domain.Agent_Instance{}, false, resolved_err
	chain_id, chain_ok, chain_err := resolve_instance_chain(service, owner, input.chain_id, agent.name)
	if !chain_ok do return domain.Agent_Instance{}, false, chain_err
	project_path := ""
	if input.project_id != "" {
		path, path_ok, path_err := resolve_project_path_for_launch(service, owner, input.project_id, bridge.bridge_id)
		if !path_ok do return domain.Agent_Instance{}, false, path_err
		project_path = path
	}
	now := platform.clock_now(service.clock)
	instance_id := platform.generate_id(service.ids, "inst_")
	conversation_id := platform.generate_id(service.ids, "chat_")
	instance := domain.Agent_Instance{agent_instance_id = instance_id, owner_user_id = owner, agent_id = agent.agent_id, bridge_id = bridge.bridge_id, provider = resolved.provider, tier = resolved.tier, project_id = input.project_id, project_path = project_path, chain_id = chain_id, conversation_id = conversation_id, runtime_status = "launching", startup_status = "starting", activity_status = "unknown", last_applied_seq = 0, run_count = 1, created_at = now, updated_at = now, started_at = now, last_seen_at = now}
	saved, saved_ok, save_err := iface.agent_save_instance(service.agents, instance)
	if !saved_ok do return domain.Agent_Instance{}, false, save_err
	conv, conv_ok, conv_err := ensure_instance_conversation(service, saved)
	if !conv_ok do return domain.Agent_Instance{}, false, conv_err
	if saved.conversation_id == "" { saved.conversation_id = conv.conversation_id; saved, saved_ok, save_err = iface.agent_save_instance(service.agents, saved); if !saved_ok do return domain.Agent_Instance{}, false, save_err }
	if input.chain_id == "" { update_private_chain_coordinator(service, saved) }
	if service.taskchains != nil && saved.chain_id != "" {
		members, _ := iface.taskchain_list_members_by_chain(service.taskchains, domain.Task_Chain_ID(saved.chain_id), saved.owner_user_id)
		role := "coordinator" if len(members) == 0 else "worker"
		now_m := platform.clock_now(service.clock)
		member := domain.Task_Chain_Member{chain_id = domain.Task_Chain_ID(saved.chain_id), agent_instance_id = saved.agent_instance_id, agent_id = saved.agent_id, owner_user_id = saved.owner_user_id, role = role, created_at = now_m}
		iface.taskchain_save_member(service.taskchains, member)
	}
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_launch_"), "_", saved.agent_instance_id})
	command := project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = command_id, body_json = launch_command_json(command_id, saved)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent do return domain.Agent_Instance{}, false, send_err
	return saved, true, domain.Domain_Error{}
}

list_instances :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	return list_instances_filtered(service, auth, List_Instances_Filter{}, limit, cursor)
}

list_instances_filtered :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, filter: List_Instances_Filter, limit: int = 50, cursor: string = "") -> ([]domain.Agent_Instance, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	has_filter := filter.agent_id != "" || filter.bridge_id != "" || filter.runtime_status != ""
	fetch_limit := limit if !has_filter else max(limit * 10, 500)
	instances, list_err := iface.agent_list_instances_by_owner(service.agents, owner, fetch_limit, cursor)
	if list_err.code != .None do return nil, list_err
	out := make([dynamic]domain.Agent_Instance)
	for inst in instances {
		if filter.agent_id != "" && inst.agent_id != filter.agent_id do continue
		if filter.bridge_id != "" && inst.bridge_id != filter.bridge_id do continue
		if filter.runtime_status != "" {
			if filter.runtime_status == "live" || filter.runtime_status == "active" {
				if !runtime_expected_active(inst.runtime_status) do continue
			} else if inst.runtime_status != filter.runtime_status {
				continue
			}
		}
		append(&out, inst)
		if len(out) >= limit do break
	}
	return out[:], domain.Domain_Error{}
}

active_instance_count_for_bridge :: proc(service: ^Agent_Service, bridge_id: string) -> int {
	if service == nil || service.agents == nil || bridge_id == "" do return 0
	instances, err := iface.agent_list_instances_by_bridge(service.agents, bridge_id)
	if err.code != .None do return 0
	count := 0
	for inst in instances { if runtime_expected_active(inst.runtime_status) do count += 1 }
	return count
}

active_instance_count_for_agent :: proc(service: ^Agent_Service, agent: domain.Agent) -> int {
	if service == nil || service.agents == nil do return 0
	instances, err := iface.agent_list_instances_by_owner(service.agents, agent.owner_user_id, 1000, "")
	if err.code != .None do return 0
	count := 0
	for inst in instances { if inst.agent_id == agent.agent_id && runtime_expected_active(inst.runtime_status) do count += 1 }
	return count
}

supported_bridge_count_for_agent :: proc(service: ^Agent_Service, agent: domain.Agent) -> int {
	if service == nil || service.bridges == nil do return 0
	bridges, err := iface.bridge_list_by_owner(service.bridges, agent.owner_user_id)
	if err.code != .None do return 0
	count := 0
	for bridge in bridges {
		if bridge.status == .Online && bridge.capabilities_json != "" do count += 1
	}
	return count
}

get_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, inst.owner_user_id); !owner_ok do return domain.Agent_Instance{}, false, owner_err
	return inst, true, domain.Domain_Error{}
}

verify_instance_token :: proc(service: ^Agent_Service, token: string) -> (contracts.Auth_Context, domain.Agent_Instance, bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent service is not configured")
	if !strings.has_prefix(token, "hit_") do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, domain.domain_error(.Unauthenticated, "instance bearer token is required")
	instance_id := strings.trim_space(token[len("hit_"):])
	if instance_id == "" do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, domain.domain_error(.Unauthenticated, "instance bearer token is invalid")
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return contracts.Auth_Context{}, domain.Agent_Instance{}, false, err
	return contracts.Auth_Context{kind = .Instance_Token, user_id = string(inst.owner_user_id), agent_instance_id = inst.agent_instance_id, bridge_id = inst.bridge_id}, inst, true, domain.Domain_Error{}
}

mark_instance_start_success :: proc(service: ^Agent_Service, auth: contracts.Auth_Context) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return domain.Agent_Instance{}, false, domain.domain_error(.Forbidden, "instance token is required")
	inst, ok, err := iface.agent_get_instance(service.agents, auth.agent_instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if inst.owner_user_id != domain.User_ID(auth.user_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found")
	now := platform.clock_now(service.clock)
	inst.runtime_status = "running"
	inst.startup_status = "ready"
	inst.activity_status = "idle"
	inst.last_applied_seq += 1
	inst.last_seen_at = now
	inst.stopped_at = ""
	inst.updated_at = now
	return iface.agent_save_instance(service.agents, inst)
}

bootstrap_json_for_bridge :: proc(service: ^Agent_Service, owner: domain.User_ID, bridge_id, instance_id: string) -> (string, bool, domain.Domain_Error) {
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return "", false, err
	if inst.bridge_id != bridge_id || inst.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "agent instance not found")
	if !(inst.runtime_status == "launching" || inst.runtime_status == "starting" || inst.runtime_status == "running" || inst.runtime_status == "idle" || inst.runtime_status == "busy") do return "", false, domain.domain_error(.Conflict, "agent instance is not launchable")
	agent, agent_ok, agent_err := iface.agent_get(service.agents, inst.agent_id)
	if !agent_ok do return "", false, agent_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return "", false, bridge_err
	project_name := ""
	project_repo := ""
	project_vcs := ""
	project_desc := ""
	project_path := inst.project_path
	if inst.project_id != "" && service.projects != nil {
		if project, project_ok, _ := iface.project_get(service.projects, inst.project_id); project_ok {
			project_name = project.name
			project_repo = project.repo_url
			project_vcs = project.vcs_kind
			project_desc = project.description
			if strings.trim_space(project_path) == "" do project_path = project.default_path
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\""); write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"chain_id\":\""); write_service_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"conversation_id\":\""); write_service_json_string(&b, inst.conversation_id)
	strings.write_string(&b, "\",\"agent\":{\"agent_id\":\""); write_service_json_string(&b, agent.agent_id)
	strings.write_string(&b, "\",\"name\":\""); write_service_json_string(&b, agent.name)
	strings.write_string(&b, "\",\"instructions\":\""); write_service_json_string(&b, agent.instructions)
	strings.write_string(&b, "\"},\"owner_user\":{\"user_id\":\""); write_service_json_string(&b, string(owner))
	strings.write_string(&b, "\"},\"bridge\":{\"bridge_id\":\""); write_service_json_string(&b, bridge.bridge_id)
	strings.write_string(&b, "\",\"label\":\""); write_service_json_string(&b, bridge.label)
	strings.write_string(&b, "\",\"machine_hostname\":\""); write_service_json_string(&b, bridge.machine_hostname)
	strings.write_string(&b, "\"},\"runtime\":{\"provider\":\""); write_service_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"tier\":\""); write_service_json_string(&b, inst.tier)
	strings.write_string(&b, "\",\"project_id\":\""); write_service_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"project_path\":\""); write_service_json_string(&b, inst.project_path)
	strings.write_string(&b, "\"},\"project\":{\"project_id\":\""); write_service_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"name\":\""); write_service_json_string(&b, project_name)
	strings.write_string(&b, "\",\"repo_url\":\""); write_service_json_string(&b, project_repo)
	strings.write_string(&b, "\",\"vcs_kind\":\""); write_service_json_string(&b, project_vcs)
	chain := domain.Task_Chain{}
	chain_ok := false
	if inst.chain_id != "" && service.taskchains != nil { chain, chain_ok, _ = iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id)) }
	strings.write_string(&b, "\",\"chain_id\":\""); write_service_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"conversation_id\":\""); write_service_json_string(&b, inst.conversation_id)
	strings.write_string(&b, "\"},\"chain\":{\"chain_id\":\""); write_service_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"kind\":\""); if chain_ok { write_service_json_string(&b, chain.kind) }
	strings.write_string(&b, "\",\"title\":\""); if chain_ok { write_service_json_string(&b, chain.title) }
	strings.write_string(&b, "\",\"coordinator_agent_instance_id\":\""); if chain_ok { write_service_json_string(&b, chain.coordinator_agent_instance_id) }
	strings.write_string(&b, "\",\"default_reviewer_refs\":"); if chain_ok { strings.write_string(&b, json_or_empty_array(chain.default_reviewer_refs_json)) } else { strings.write_string(&b, "[]") }
	strings.write_string(&b, ",\"publish_state\":\""); if chain_ok { write_service_json_string(&b, publish_state_string(chain.publish_state)) }
	strings.write_string(&b, "\",\"status\":\""); if chain_ok { write_service_json_string(&b, chain_status_string(chain.status)) }
	strings.write_string(&b, "\"},\"task_context\":")
	write_bootstrap_task_context(&b, service, inst, chain, chain_ok)
	strings.write_string(&b, ",\"conversation\":{\"conversation_id\":\""); write_service_json_string(&b, inst.conversation_id)
	strings.write_string(&b, "\",\"summary\":\"\",\"recent_messages\":[")
	write_bootstrap_messages(&b, service, inst)
	strings.write_string(&b, "],\"messages\":[")
	write_bootstrap_messages(&b, service, inst)
	strings.write_string(&b, "]},\"memory\":[")
	write_bootstrap_memories(&b, service, owner, inst)
	strings.write_string(&b, "],\"files\":[{\"kind\":\"AGENTS_MD\",\"relative_path\":\"AGENTS.md\",\"content\":\"# Agent bootstrap\\n\\nAgent: "); write_service_json_string(&b, agent.name)
	strings.write_string(&b, "\\nInstance: "); write_service_json_string(&b, inst.agent_instance_id)
	if chain_ok {
		strings.write_string(&b, "\\nTask chain: "); write_service_json_string(&b, chain.title); strings.write_string(&b, " ("); write_service_json_string(&b, string(chain.chain_id)); strings.write_string(&b, ")")
		strings.write_string(&b, "\\nCoordinator: "); if chain.coordinator_agent_instance_id == inst.agent_instance_id { strings.write_string(&b, "you (coordinator)") } else { write_service_json_string(&b, chain.coordinator_agent_instance_id) }
	}
	if strings.trim_space(project_name) != "" || strings.trim_space(project_path) != "" {
		strings.write_string(&b, "\\n\\n## Project\\nThis agent is associated with a project. You run in your own managed working directory (not the project directory). Work against the project checkout below when the task requires it.\\n")
		if strings.trim_space(project_name) != "" { strings.write_string(&b, "\\n- Name: "); write_service_json_string(&b, project_name) }
		if strings.trim_space(project_path) != "" { strings.write_string(&b, "\\n- Path: "); write_service_json_string(&b, project_path) }
		if strings.trim_space(project_repo) != "" { strings.write_string(&b, "\\n- Repo: "); write_service_json_string(&b, project_repo) }
		if strings.trim_space(project_vcs) != "" { strings.write_string(&b, "\\n- VCS: "); write_service_json_string(&b, project_vcs) }
		if strings.trim_space(project_desc) != "" { strings.write_string(&b, "\\n- Description: "); write_service_json_string(&b, project_desc) }
	}
	strings.write_string(&b, "\\n\\n## Working with tasks (REQUIRED)\\nYou MUST track all substantial work as tasks in this task chain. This is not optional.\\n\\nRules you must follow:\\n1. Before starting work, ALWAYS run ./.heimdall/bin/ham-ctl agent tasks fetch to see the current tasks in your chain.\\n2. Do NOT do meaningful work that is not represented by a task. If a task does not exist for what you are about to do, create one (coordinator) or ask the coordinator to create one.\\n3. When you begin a task, move it to in_progress: ./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_progress\\n4. As you make progress, you MUST post a comment on the task describing what you did, what changed, and what is next: ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body \\\"<progress update>\\\". Add a comment at every meaningful step, on blockers, and before handing off for review.\\n5. When the work is complete, submit it for review: ./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_validation (or ./.heimdall/bin/ham-ctl agent tasks done --task-id <id>). Include a summary comment of what to review.\\n6. Reviewers vote with ./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment \\\"<feedback>\\\". If you receive ngtm, address the feedback, comment what you changed, and re-submit.\\n7. Use ./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id> to request attention on a stalled task.\\n\\nKeep task status and comments current at all times so the whole chain reflects real progress.")
	write_bootstrap_memory_markdown(&b, service, owner, inst)
	strings.write_string(&b, "\"}]")
	write_bootstrap_skill_fields(&b, service, owner, inst)
	strings.write_string(&b, ",\"instance_token\":\"hit_"); write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"hub_url\":\""); write_service_json_string(&b, bridge.hub_url); strings.write_string(&b, "\"}")
	return strings.to_string(b), true, domain.Domain_Error{}
}

write_bootstrap_skill_fields :: proc(b: ^strings.Builder, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) {
	strings.write_string(b, ",\"skills\":[")
	written := 0
	default_name := ""
	default_content := ""
	if service != nil && service.content != nil {
		memories, err := iface.content_list_memories(service.content, owner)
		if err.code == .None {
			for m in memories {
				if !bootstrap_memory_applies(m, service, owner, inst) || m.type != .Skill do continue
				name := bootstrap_skill_name(m)
				content := bootstrap_skill_file_content(m, name)
				if written > 0 do strings.write_byte(b, ',')
				write_bootstrap_skill_json(b, name, content)
				if default_name == "" { default_name = name; default_content = content }
				written += 1
			}
		}
	}
	if written == 0 {
		name, content := bootstrap_fallback_skill()
		write_bootstrap_skill_json(b, name, content)
		default_name = name
		default_content = content
	}
	strings.write_string(b, "]")
	strings.write_string(b, ",\"default_skill_name\":\""); write_service_json_string(b, default_name)
	strings.write_string(b, "\",\"default_skill_content\":\""); write_service_json_string(b, default_content)
	strings.write_string(b, "\"")
}

write_bootstrap_skill_json :: proc(b: ^strings.Builder, name, content: string) {
	strings.write_string(b, "{\"name\":\""); write_service_json_string(b, name)
	strings.write_string(b, "\",\"content\":\""); write_service_json_string(b, content)
	strings.write_string(b, "\"}")
}

bootstrap_fallback_skill :: proc() -> (string, string) {
	content := "---\nname: heimdall-ctl-communication\ndescription: Use Heimdall CLI for agent startup, chat communication, task coordination, and concise status reporting. Load when communicating through Heimdall or reacting to message notifications.\n---\n\n# Heimdall CLI communication basics\n\nUse the managed Heimdall CLI wrapper from the agent run directory for all Heimdall communication: `./.heimdall/bin/ham-ctl`.\n\nStartup: after you are fully ready, report readiness with `./.heimdall/bin/ham-ctl agent start-success`.\n\nRead inbound messages with `./.heimdall/bin/ham-ctl agent chat read` and reply to the user with `./.heimdall/bin/ham-ctl agent chat send --body \"...\"`. Keep replies concise and include blockers, concrete results, and next steps."
	return "heimdall-ctl-communication", content
}

bootstrap_skill_file_content :: proc(m: domain.Memory, name: string) -> string {
	body := m.body
	if strings.index(body, "\\n") >= 0 {
		replaced, _ := strings.replace_all(body, "\\n", "\n")
		body = replaced
	}
	trimmed := strings.trim_space(body)
	if strings.has_prefix(trimmed, "---\n") || strings.has_prefix(trimmed, "---\r\n") do return trimmed
	content := strings.builder_make()
	strings.write_string(&content, "---\nname: "); strings.write_string(&content, name)
	strings.write_string(&content, "\ndescription: ")
	if strings.trim_space(m.title) != "" { strings.write_string(&content, m.title) } else { strings.write_string(&content, name) }
	strings.write_string(&content, "\nheimdall_managed: true\n---\n\n# ")
	if strings.trim_space(m.title) != "" { strings.write_string(&content, m.title) } else { strings.write_string(&content, name) }
	strings.write_string(&content, "\n\n")
	strings.write_string(&content, body)
	return strings.to_string(content)
}

bootstrap_skill_name :: proc(m: domain.Memory) -> string {
	if name := bootstrap_skill_frontmatter_value(m.body, "name"); name != "" do return bootstrap_safe_slug(name)
	if slug := bootstrap_safe_slug(m.title); slug != "" do return slug
	return bootstrap_safe_slug(m.memory_id)
}

bootstrap_skill_frontmatter_value :: proc(body, key: string) -> string {
	text := body
	if strings.index(text, "\\n") >= 0 { replaced, _ := strings.replace_all(text, "\\n", "\n"); text = replaced }
	trimmed := strings.trim_space(text)
	if !strings.has_prefix(trimmed, "---") do return ""
	prefix := strings.concatenate({key, ":"})
	defer delete(prefix)
	idx := 0
	for line in strings.split_lines_iterator(&trimmed) {
		line_trimmed := strings.trim_space(line)
		if idx == 0 {
			if line_trimmed != "---" do return ""
			idx += 1
			continue
		}
		if line_trimmed == "---" do break
		if strings.has_prefix(line_trimmed, prefix) do return strings.trim(strings.trim_space(line_trimmed[len(prefix):]), " \t\"'")
		idx += 1
	}
	return ""
}

bootstrap_safe_slug :: proc(value: string) -> string {
	b := strings.builder_make()
	last_dash := false
	for ch in strings.to_lower(strings.trim_space(value)) {
		switch ch {
		case 'a'..='z', '0'..='9':
			strings.write_rune(&b, ch); last_dash = false
		case '-', '_', ' ', '.', '/', ':':
			if !last_dash { strings.write_byte(&b, '-'); last_dash = true }
		case:
		}
	}
	return strings.trim(strings.to_string(b), "-")
}

write_bootstrap_memories :: proc(b: ^strings.Builder, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) {
	if service == nil || service.content == nil do return
	memories, err := iface.content_list_memories(service.content, owner)
	if err.code != .None do return
	written := 0
	for m in memories {
		if !bootstrap_memory_applies(m, service, owner, inst) do continue
		if written > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "{\"memory_id\":\""); write_service_json_string(b, m.memory_id)
		strings.write_string(b, "\",\"agent_id\":\""); write_service_json_string(b, m.agent_id)
		strings.write_string(b, "\",\"project_id\":\""); write_service_json_string(b, string(m.project_id))
		strings.write_string(b, "\",\"template_id\":\""); write_service_json_string(b, m.template_id)
		strings.write_string(b, "\",\"bridge_id\":\""); write_service_json_string(b, m.bridge_id)
		strings.write_string(b, "\",\"type\":\""); write_service_json_string(b, domain.memory_type_string(m.type))
		strings.write_string(b, "\",\"status\":\""); write_service_json_string(b, m.status)
		strings.write_string(b, "\",\"title\":\""); write_service_json_string(b, m.title)
		strings.write_string(b, "\",\"body\":\""); write_service_json_string(b, m.body)
		strings.write_string(b, "\",\"evidence\":\""); write_service_json_string(b, m.evidence)
		strings.write_string(b, "\"}")
		written += 1
	}
}

write_bootstrap_memory_markdown :: proc(b: ^strings.Builder, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) {
	if service == nil || service.content == nil do return
	memories, err := iface.content_list_memories(service.content, owner)
	if err.code != .None do return
	written := 0
	for m in memories {
		if !bootstrap_memory_applies(m, service, owner, inst) do continue
		if written == 0 do strings.write_string(b, "\\n\\n## Applicable Memories / Skills")
		strings.write_string(b, "\\n\\n### "); write_service_json_string(b, m.title)
		strings.write_string(b, "\\nType: "); write_service_json_string(b, domain.memory_type_string(m.type))
		strings.write_string(b, "\\n\\n"); write_bootstrap_markdown_json_string(b, m.body)
		written += 1
	}
}

write_bootstrap_markdown_json_string :: proc(b: ^strings.Builder, value: string) {
	text := value
	if strings.index(text, "\\n") >= 0 {
		replaced, _ := strings.replace_all(text, "\\n", "\n")
		text = replaced
	}
	write_service_json_string(b, text)
}

bootstrap_memory_applies :: proc(m: domain.Memory, service: ^Agent_Service, owner: domain.User_ID, inst: domain.Agent_Instance) -> bool {
	if m.status != "active" do return false
	if strings.trim_space(m.agent_id) != "" && m.agent_id != inst.agent_id do return false
	if string(m.project_id) != "" && m.project_id != inst.project_id do return false
	if strings.trim_space(m.template_id) != "" {
		if service == nil || service.agents == nil || strings.trim_space(inst.agent_id) == "" do return false
		agent, ok, _ := iface.agent_get(service.agents, inst.agent_id)
		if !ok || agent.owner_user_id != owner || agent.template_id != m.template_id do return false
	}
	if strings.trim_space(m.bridge_id) != "" && m.bridge_id != inst.bridge_id do return false
	return true
}

write_bootstrap_task_context :: proc(b: ^strings.Builder, service: ^Agent_Service, inst: domain.Agent_Instance, chain: domain.Task_Chain, chain_ok: bool) {
	reviewers := "[]"
	if chain_ok do reviewers = json_or_empty_array(chain.default_reviewer_refs_json)
	strings.write_string(b, "{\"effective_assignee_ref\":{\"type\":\"agent_instance\",\"agent_instance_id\":\""); write_service_json_string(b, inst.agent_instance_id)
	strings.write_string(b, "\"},\"effective_reviewer_refs\":"); strings.write_string(b, reviewers)
	strings.write_string(b, ",\"current_task\":")
	current_written := false
	if service.taskchains != nil && chain_ok {
		tasks, err := iface.taskchain_list_tasks_by_chain(service.taskchains, chain.chain_id, chain.owner_user_id)
		if err.code == .None {
			for task in tasks {
				if strings.contains(task.assignee_ref_json, inst.agent_instance_id) && (task.status == .In_Progress || task.status == .Assigned) {
					write_bootstrap_task_json(b, task)
					current_written = true
					break
				}
			}
			if !current_written do strings.write_string(b, "null")
			strings.write_string(b, ",\"runnable_frontier\":[")
			written := 0
			for task in tasks {
				if task.publish_state != .Published || task.started_at != "" || task.status != .Assigned || !strings.contains(task.assignee_ref_json, inst.agent_instance_id) do continue
				if written > 0 do strings.write_string(b, ",")
				write_bootstrap_task_json(b, task)
				written += 1
				if written >= 10 do break
			}
			strings.write_string(b, "]}")
			return
		}
	}
	if !current_written do strings.write_string(b, "null")
	strings.write_string(b, ",\"runnable_frontier\":[]}")
}

write_bootstrap_task_json :: proc(b: ^strings.Builder, task: domain.Task) {
	strings.write_string(b, "{\"task_id\":\""); write_service_json_string(b, string(task.task_id))
	strings.write_string(b, "\",\"title\":\""); write_service_json_string(b, task.title)
	strings.write_string(b, "\",\"status\":\""); write_service_json_string(b, task_status_string(task.status))
	strings.write_string(b, "\"}")
}

write_bootstrap_messages :: proc(b: ^strings.Builder, service: ^Agent_Service, inst: domain.Agent_Instance) {
	if service.content == nil || inst.conversation_id == "" do return
	messages, err := iface.content_list_messages(service.content, inst.conversation_id, inst.owner_user_id, 20, "")
	if err.code != .None do return
	for m, i in messages {
		if i > 0 do strings.write_string(b, ",")
		strings.write_string(b, "{\"message_id\":\""); write_service_json_string(b, m.message_id)
		strings.write_string(b, "\",\"direction\":\""); write_service_json_string(b, m.direction)
		strings.write_string(b, "\",\"body\":\""); write_service_json_string(b, m.body)
		strings.write_string(b, "\",\"created_at\":\""); write_service_json_string(b, m.created_at)
		strings.write_string(b, "\"}")
	}
}

stop_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, input: Stop_Instance_Input) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	reason := input.reason; if reason == "" do reason = "user_requested"
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_stop_"), "_", inst.agent_instance_id})
	command := project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = command_id, body_json = stop_command_json(command_id, inst.agent_instance_id, reason)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent do return domain.Agent_Instance{}, false, send_err
	inst.runtime_status = "stopping"
	inst.updated_at = platform.clock_now(service.clock)
	return iface.agent_save_instance(service.agents, inst)
}

restart_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	return relaunch_instance(service, auth, inst, inst.provider, inst.tier)
}

reconfigure_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, input: Reconfigure_Instance_Input) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if input.has_agent_id || input.has_bridge_id || input.has_project_id || input.has_chain_id || input.has_conversation_id do return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "agent_id, bridge_id, project_id, chain_id, and conversation_id are immutable for an instance; changing them requires a new instance")
	provider := input.provider; if provider == "" do provider = inst.provider
	tier := input.tier; if tier == "" do tier = inst.tier
	resolved, resolved_ok, resolved_err := validate_pinned_provider_tier(service, auth, inst, provider, tier)
	if !resolved_ok do return domain.Agent_Instance{}, false, resolved_err
	inst.provider = resolved.provider
	inst.tier = resolved.tier
	if runtime_expected_active(inst.runtime_status) do return relaunch_instance(service, auth, inst, resolved.provider, resolved.tier)
	inst.updated_at = platform.clock_now(service.clock)
	return iface.agent_save_instance(service.agents, inst)
}

relaunch_instance :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance, provider, tier: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	_, auth_ok, auth_err := validate_pinned_provider_tier(service, auth, inst, provider, tier)
	if !auth_ok do return domain.Agent_Instance{}, false, auth_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !bridge_ok do return domain.Agent_Instance{}, false, bridge_err
	if bridge.owner_user_id != inst.owner_user_id do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, inst.bridge_id) do return domain.Agent_Instance{}, false, domain.domain_error(.Bridge_Offline, "pinned bridge is offline")
	now := platform.clock_now(service.clock)
	next := inst
	next.provider = provider
	next.tier = tier
	next.runtime_status = "launching"
	next.startup_status = "starting"
	next.activity_status = "unknown"
	next.run_count += 1
	next.started_at = now
	next.stopped_at = ""
	next.updated_at = now
	next.last_seen_at = now
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_launch_"), "_", next.agent_instance_id})
	command := project_service.Runtime_Command{bridge_id = next.bridge_id, command_id = command_id, body_json = launch_command_json(command_id, next)}
	if sent, send_err := project_service.bridge_command_send_runtime(service.bridge_command_sink, command); !sent do return domain.Agent_Instance{}, false, send_err
	return iface.agent_save_instance(service.agents, next)
}

apply_bridge_status_report :: proc(service: ^Agent_Service, bridge_id, instance_id: string, state_seq: int, runtime_status, activity_status: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return domain.Agent_Instance{}, false, err
	if inst.bridge_id != bridge_id do return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "agent instance not found on bridge")
	effective_state_seq := state_seq
	if effective_state_seq <= inst.last_applied_seq {
		// Bridge runtime state is in-memory and can restart while ham-wrapper
		// processes keep running. A wrapper reconnect/liveness report with a reset
		// bridge-local seq is authoritative for recovery from non-live Hub states.
		if runtime_expected_active(runtime_status) && (inst.runtime_status == "unreachable" || inst.runtime_status == "launching" || inst.runtime_status == "starting") {
			effective_state_seq = inst.last_applied_seq + 1
		} else {
			return inst, false, domain.Domain_Error{}
		}
	}
	now := platform.clock_now(service.clock)
	inst.last_applied_seq = effective_state_seq
	if runtime_status != "" do inst.runtime_status = runtime_status
	if activity_status != "" do inst.activity_status = activity_status
	inst.last_seen_at = now
	inst.updated_at = now
	apply_runtime_startup_projection(&inst, now)
	return iface.agent_save_instance(service.agents, inst)
}

reconcile_bridge_heartbeat :: proc(service: ^Agent_Service, bridge_id: string, active_instance_ids: []string) -> int {
	instances, err := iface.agent_list_instances_by_bridge(service.agents, bridge_id)
	if err.code != .None do return 0
	changed := 0
	now := platform.clock_now(service.clock)
	for i in 0..<len(instances) {
		inst := instances[i]
		if runtime_expected_active(inst.runtime_status) && !string_slice_contains(active_instance_ids, inst.agent_instance_id) {
			inst.runtime_status = "unreachable"
			inst.updated_at = now
			apply_runtime_startup_projection(&inst, now)
			_, saved, _ := iface.agent_save_instance(service.agents, inst)
			if saved do changed += 1
		}
	}
	return changed
}

require_enabled_support :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id: string) -> (bool, domain.Domain_Error) {
	supports, err := list_support(service, auth, agent_id)
	if err.code != .None do return false, err
	for s in supports { if s.enabled do return true, domain.Domain_Error{} }
	return false, domain.domain_error(.Provider_Unavailable, "agent has no enabled bridge support")
}

update_private_chain_coordinator :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) {
	if service.taskchains == nil || inst.chain_id == "" do return
	chain, ok, _ := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(inst.chain_id))
	if !ok || chain.owner_user_id != inst.owner_user_id || chain.coordinator_agent_instance_id != "" do return
	chain.coordinator_agent_instance_id = inst.agent_instance_id
	chain.updated_at = inst.updated_at
	_, _, _ = iface.taskchain_save_chain(service.taskchains, chain)
}

resolve_instance_chain :: proc(service: ^Agent_Service, owner: domain.User_ID, chain_id: string, agent_name: string) -> (string, bool, domain.Domain_Error) {
	if service.taskchains == nil do return "", false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	if chain_id != "" {
		chain, ok, err := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(chain_id))
		if !ok do return "", false, err
		if chain.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "task chain not found")
		return string(chain.chain_id), true, domain.Domain_Error{}
	}
	now := platform.clock_now(service.clock)
	title := agent_name; if title == "" do title = "Private conversation"
	chain := domain.Task_Chain{chain_id = domain.Task_Chain_ID(platform.generate_id(service.ids, "chain_")), owner_user_id = owner, title = title, publish_state = .Published, status = .Active, kind = "private_conversation", default_reviewer_refs_json = "[]", created_at = now, updated_at = now, published_at = now}
	created, saved, save_err := iface.taskchain_save_chain(service.taskchains, chain)
	if !saved do return "", false, save_err
	return string(created.chain_id), true, domain.Domain_Error{}
}

ensure_instance_conversation :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	if service.content == nil do return domain.Chat_Conversation{}, false, domain.domain_error(.Internal_Error, "content repository is not configured")
	existing, list_err := iface.content_list_conversations(service.content, inst.owner_user_id, 512, "")
	if list_err.code != .None do return domain.Chat_Conversation{}, false, list_err
	for c in existing {
		if c.agent_instance_id == inst.agent_instance_id {
			if c.agent_id != inst.agent_id do return domain.Chat_Conversation{}, false, domain.domain_error(.Conflict, "conversation agent binding is inconsistent")
			if c.chain_id != inst.chain_id do return domain.Chat_Conversation{}, false, domain.domain_error(.Conflict, "conversation chain binding is inconsistent")
			if inst.conversation_id != "" && c.conversation_id != inst.conversation_id do return domain.Chat_Conversation{}, false, domain.domain_error(.Conflict, "conversation identity is inconsistent")
			return c, true, domain.Domain_Error{}
		}
	}
	now := platform.clock_now(service.clock)
	conv_id := inst.conversation_id; if conv_id == "" do conv_id = platform.generate_id(service.ids, "chat_")
	title := agent_display_name_for_id(service, inst.owner_user_id, inst.agent_id)
	conv := domain.Chat_Conversation{conversation_id = conv_id, owner_user_id = inst.owner_user_id, agent_id = inst.agent_id, agent_instance_id = inst.agent_instance_id, project_id = inst.project_id, chain_id = inst.chain_id, title = title, created_at = now, updated_at = now}
	return iface.content_save_conversation(service.content, conv)
}

agent_display_name_for_id :: proc(service: ^Agent_Service, owner: domain.User_ID, agent_id: string) -> string {
	fallback := strings.trim_space(agent_id)
	if service != nil && service.agents != nil && strings.trim_space(agent_id) != "" {
		if agent, ok, _ := iface.agent_get(service.agents, agent_id); ok && agent.owner_user_id == owner {
			if name := strings.trim_space(agent.name); name != "" do return name
			if slug := strings.trim_space(agent.slug); slug != "" do return slug
		}
	}
	return fallback
}

resolve_provider_tier :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent_id, bridge_id: string, req: Run_Request) -> (domain.Resolved_Provider_Tier, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, agent_id)
	if !ok do return domain.Resolved_Provider_Tier{}, false, err
	support := default_support_for_agent_bridge(agent, bridge_id)
	if stored, stored_ok, _ := iface.agent_get_support(service.agents, agent_id, bridge_id); stored_ok {
		if stored.owner_user_id != agent.owner_user_id do return domain.Resolved_Provider_Tier{}, false, domain.domain_error(.Not_Found, "support not found")
		support = stored
	}
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return domain.Resolved_Provider_Tier{}, false, bridge_err
	// Resolution order: request > per-bridge override > agent default tier > Bridge default.
	provider := first_non_empty(req.provider, support.provider, default_provider_from_bridge(bridge), "")
	tier := first_non_empty(req.tier, support.tier, agent.default_tier, default_tier_for_provider_from_bridge(bridge, provider))
	return validate_provider_tier_intersection(bridge, support, provider, tier)
}

validate_pinned_provider_tier :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance, provider, tier: string) -> (domain.Resolved_Provider_Tier, bool, domain.Domain_Error) {
	agent, ok, err := get_agent(service, auth, inst.agent_id)
	if !ok do return domain.Resolved_Provider_Tier{}, false, err
	if agent.owner_user_id != inst.owner_user_id do return domain.Resolved_Provider_Tier{}, false, domain.domain_error(.Not_Found, "agent not found")
	support := default_support_for_agent_bridge(agent, inst.bridge_id)
	if stored, stored_ok, _ := iface.agent_get_support(service.agents, inst.agent_id, inst.bridge_id); stored_ok {
		if stored.owner_user_id != inst.owner_user_id do return domain.Resolved_Provider_Tier{}, false, domain.domain_error(.Not_Found, "support not found")
		support = stored
	}
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, inst.bridge_id)
	if !bridge_ok do return domain.Resolved_Provider_Tier{}, false, bridge_err
	resolved_provider := first_non_empty(provider, support.provider, default_provider_from_bridge(bridge), "")
	resolved_tier := first_non_empty(tier, support.tier, agent.default_tier, default_tier_for_provider_from_bridge(bridge, resolved_provider))
	return validate_provider_tier_intersection(bridge, support, resolved_provider, resolved_tier)
}

validate_provider_tier_intersection :: proc(bridge: domain.Bridge, support: domain.Agent_Bridge_Support, provider, tier: string) -> (domain.Resolved_Provider_Tier, bool, domain.Domain_Error) {
	// The Bridge capability matrix is the ONLY hard constraint. AgentBridgeSupport
	// no longer allowlists provider/tier — its provider/tier are just an optional
	// preferred default (used earlier in resolution order), never a whitelist. An
	// agent may run any provider/tier the Bridge actually supports.
	if strings.trim_space(provider) == "" do return domain.Resolved_Provider_Tier{}, false, domain.domain_error(.Provider_Unavailable, "no provider is available on bridge")
	if strings.trim_space(tier) == "" do return domain.Resolved_Provider_Tier{}, false, domain.domain_error(.Provider_Unavailable, "no tier is available for resolved provider")
	if !bridge_supports_provider_tier(bridge, provider, tier) do return domain.Resolved_Provider_Tier{}, false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("bridge does not support provider/tier %s/%s; pick a supported provider/tier or set an agent override for this bridge", provider, tier))
	return domain.Resolved_Provider_Tier{provider = provider, tier = tier}, true, domain.Domain_Error{}
}

bridge_supports_provider_tier :: proc(bridge: domain.Bridge, provider, tier: string) -> bool {
	if provider == "" do return false
	caps := bridge.capabilities_json
	if caps == "" do return false
	search_from := 0
	for search_from < len(caps) {
		rel := strings.index(caps[search_from:], "\"provider\"")
		if rel < 0 do return false
		idx := search_from + rel
		value := json_value_at(caps, "provider", idx)
		if value == provider {
			if tier == "" do return true
			next_rel := strings.index(caps[idx + len("\"provider\""):], "\"provider\"")
			end := len(caps)
			if next_rel >= 0 do end = idx + len("\"provider\"") + next_rel
			return json_tiers_array_contains(caps[idx:end], tier)
		}
		search_from = idx + len("\"provider\"")
	}
	return false
}

bridge_supports_provider :: proc(bridge: domain.Bridge, provider: string) -> bool {
	return bridge_supports_provider_tier(bridge, provider, "")
}

bridge_supports_any_provider_tier :: proc(bridge: domain.Bridge, tier: string) -> bool {
	if strings.trim_space(tier) == "" do return false
	caps := bridge.capabilities_json
	if caps == "" do return false
	search_from := 0
	for search_from < len(caps) {
		rel := strings.index(caps[search_from:], "\"provider\"")
		if rel < 0 do return false
		idx := search_from + rel
		next_rel := strings.index(caps[idx + len("\"provider\""):], "\"provider\"")
		end := len(caps)
		if next_rel >= 0 do end = idx + len("\"provider\"") + next_rel
		if json_tiers_array_contains(caps[idx:end], tier) do return true
		search_from = idx + len("\"provider\"")
	}
	return false
}

json_value_at :: proc(body, key: string, start: int) -> string {
	if start < 0 || start >= len(body) do return ""
	return json_value(body[start:], key)
}

json_tiers_array_contains :: proc(body, tier: string) -> bool {
	tiers_idx := strings.index(body, "\"tiers\"")
	if tiers_idx < 0 do return false
	rest := body[tiers_idx + len("\"tiers\""):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return false
	rest = rest[colon + 1:]
	open := strings.index_byte(rest, '[')
	if open < 0 do return false
	rest = rest[open + 1:]
	close := strings.index_byte(rest, ']')
	if close < 0 do return false
	return json_string_literal_present(rest[:close], tier)
}

json_string_literal_present :: proc(body, value: string) -> bool {
	needle := strings.concatenate({"\"", value, "\""})
	defer delete(needle)
	return strings.contains(body, needle)
}

select_bridge_for_agent :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, agent: domain.Agent, req: Run_Request) -> (domain.Bridge, bool, domain.Domain_Error) {
	supports, err := list_support(service, auth, agent.agent_id)
	if err.code != .None do return domain.Bridge{}, false, err
	best: domain.Bridge
	best_priority := -2147483648
	found := false
	online_enabled_found := false
	last_provider := ""
	last_tier := ""
	for support in supports {
		if !support.enabled do continue
		bridge, bridge_ok, _ := iface.bridge_get_bridge(service.bridges, support.bridge_id)
		if !bridge_ok || bridge.status != .Online || !project_service.bridge_runtime_registry_has_live(service.bridge_runtime_registry, bridge.bridge_id) do continue
		online_enabled_found = true
		provider := first_non_empty(req.provider, support.provider, agent.default_provider, default_provider_from_bridge(bridge))
		tier := first_non_empty(req.tier, support.tier, agent.default_tier, default_tier_for_provider_from_bridge(bridge, provider))
		last_provider = provider
		last_tier = tier
		if !bridge_supports_provider_tier(bridge, provider, tier) do continue
		if !found || support.priority > best_priority {
			best = bridge
			best_priority = support.priority
			found = true
		}
	}
	if !found && online_enabled_found do return domain.Bridge{}, false, domain.domain_error(.Provider_Unavailable, fmt.tprintf("no enabled online bridge supports resolved provider/tier %s/%s; pick a supported provider/tier or set an agent override for that bridge", last_provider, last_tier))
	if !found do return domain.Bridge{}, false, domain.domain_error(.Bridge_Offline, "no online supported bridge is available")
	return best, true, domain.Domain_Error{}
}

resolve_project_path_for_launch :: proc(service: ^Agent_Service, owner: domain.User_ID, project_id: domain.Project_ID, bridge_id: string) -> (string, bool, domain.Domain_Error) {
	if service.projects == nil do return "", false, domain.domain_error(.Internal_Error, "project repository is not configured")
	project, ok, err := iface.project_get(service.projects, project_id)
	if !ok do return "", false, err
	if project.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "project not found")
	path, path_ok, _ := iface.project_get_bridge_path(service.projects, project.project_id, bridge_id)
	if path_ok do return path.path, true, domain.Domain_Error{}
	return project.default_path, true, domain.Domain_Error{}
}

publish_state_string :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
chain_status_string :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; return "active" }
task_status_string :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
json_or_empty_array :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "[]"; return value }

apply_runtime_startup_projection :: proc(inst: ^domain.Agent_Instance, now: string) {
	if inst == nil do return
	switch inst.runtime_status {
	case "running", "idle", "busy":
		inst.startup_status = "ready"
	case "launching", "starting":
		inst.startup_status = "starting"
	case "failed":
		inst.startup_status = "startup_failed"
		inst.stopped_at = now
	case "stopped", "unreachable":
		inst.startup_status = "stopped"
		inst.stopped_at = now
	}
}

runtime_expected_active :: proc(runtime_status: string) -> bool {
	return runtime_status == "launching" || runtime_status == "starting" || runtime_status == "running" || runtime_status == "idle" || runtime_status == "busy" || runtime_status == "stopping"
}

string_slice_contains :: proc(values: []string, needle: string) -> bool {
	for value in values { if strings.trim_space(value) == needle do return true }
	return false
}

launch_command_json :: proc(command_id: string, inst: domain.Agent_Instance) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"launch_agent\",\"protocol_version\":1,\"message_id\":\""); write_service_json_string(&b, strings.concatenate({"msg_", command_id}))
	strings.write_string(&b, "\",\"command_id\":\""); write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"agent_instance_id\":\""); write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"agent_id\":\""); write_service_json_string(&b, inst.agent_id)
	strings.write_string(&b, "\",\"project_id\":\""); write_service_json_string(&b, string(inst.project_id))
	strings.write_string(&b, "\",\"project_path\":\""); write_service_json_string(&b, inst.project_path)
	strings.write_string(&b, "\",\"chain_id\":\""); write_service_json_string(&b, inst.chain_id)
	strings.write_string(&b, "\",\"conversation_id\":\""); write_service_json_string(&b, inst.conversation_id)
	strings.write_string(&b, "\",\"provider\":\""); write_service_json_string(&b, inst.provider)
	strings.write_string(&b, "\",\"tier\":\""); write_service_json_string(&b, inst.tier)
	strings.write_string(&b, "\",\"bootstrap_url\":\"/api/v1/bridge/agent-instances/"); write_service_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "/bootstrap\"}}")
	return strings.to_string(b)
}

stop_command_json :: proc(command_id, instance_id, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"stop_agent\",\"protocol_version\":1,\"message_id\":\""); write_service_json_string(&b, strings.concatenate({"msg_", command_id}))
	strings.write_string(&b, "\",\"command_id\":\""); write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"agent_instance_id\":\""); write_service_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"reason\":\""); write_service_json_string(&b, reason)
	strings.write_string(&b, "\",\"grace_seconds\":10,\"force\":false}}")
	return strings.to_string(b)
}

write_service_json_string :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case: strings.write_rune(b, ch)
		}
	}
}

default_provider_from_bridge :: proc(bridge: domain.Bridge) -> string { return json_value(bridge.capabilities_json, "provider") }
default_tier_from_bridge :: proc(bridge: domain.Bridge) -> string { return json_value(bridge.capabilities_json, "default_tier") }
default_tier_for_provider_from_bridge :: proc(bridge: domain.Bridge, provider: string) -> string {
	if provider == "" do return default_tier_from_bridge(bridge)
	caps := bridge.capabilities_json
	search_from := 0
	for search_from < len(caps) {
		rel := strings.index(caps[search_from:], "\"provider\"")
		if rel < 0 do break
		idx := search_from + rel
		value := json_value_at(caps, "provider", idx)
		if value == provider {
			next_rel := strings.index(caps[idx + len("\"provider\""):], "\"provider\"")
			end := len(caps)
			if next_rel >= 0 do end = idx + len("\"provider\"") + next_rel
			return json_value(caps[idx:end], "default_tier")
		}
		search_from = idx + len("\"provider\"")
	}
	return default_tier_from_bridge(bridge)
}
first_non_empty :: proc(a, b, c, d: string) -> string { if a != "" do return a; if b != "" do return b; if c != "" do return c; return d }

json_value :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""}); defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}
