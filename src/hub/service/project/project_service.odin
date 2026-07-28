package project

import "core:net"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"

Validate_Project_Path_Command :: struct {
	type: string,
	command_id: string,
	project_id: domain.Project_ID,
	bridge_id: string,
	path: string,
	vcs_kind: string,
	repo_url: string,
}

Project_Path_Validation_Result :: struct {
	type: string,
	command_id: string,
	project_id: domain.Project_ID,
	path: string,
	ok: bool,
	validation_error: string,
	details_json: string,
}

Bridge_Runtime_Registry :: struct {
	live_bridge_ids: [128]string,
	path_validation_adapter_registered: [128]bool,
	path_validation_urls: [128]string,
	connection_generations: [128]int,
	command_sockets: [128]net.TCP_Socket,
	live_bridge_count: int,
	command_ids: [256]string,
	command_results_json: [256]string,
	command_count: int,
	instance_ids: [256]string,
	instance_state_seq: [256]int,
	instance_runtime_status: [256]string,
	instance_activity_status: [256]string,
	instance_count: int,
	edge_event_count: int,
}

bridge_runtime_registry_mark_live :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, path_validation_adapter_registered: bool, path_validation_url: string) {
	if registry == nil || bridge_id == "" do return
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] == bridge_id {
			registry.path_validation_adapter_registered[i] = path_validation_adapter_registered
			registry.path_validation_urls[i] = path_validation_url
			return
		}
	}
	if registry.live_bridge_count < len(registry.live_bridge_ids) {
		registry.live_bridge_ids[registry.live_bridge_count] = bridge_id
		registry.path_validation_adapter_registered[registry.live_bridge_count] = path_validation_adapter_registered
		registry.path_validation_urls[registry.live_bridge_count] = path_validation_url
		registry.live_bridge_count += 1
	}
}

bridge_runtime_registry_has_live :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> bool {
	if registry == nil || bridge_id == "" do return false
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return true }
	return false
}

bridge_runtime_registry_mark_offline :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, generation: int) {
	if registry == nil || bridge_id == "" do return
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] != bridge_id do continue
		if generation != 0 && registry.connection_generations[i] != generation do return
		last := registry.live_bridge_count - 1
		registry.live_bridge_ids[i] = registry.live_bridge_ids[last]
		registry.path_validation_adapter_registered[i] = registry.path_validation_adapter_registered[last]
		registry.path_validation_urls[i] = registry.path_validation_urls[last]
		registry.connection_generations[i] = registry.connection_generations[last]
		registry.command_sockets[i] = registry.command_sockets[last]
		registry.live_bridge_ids[last] = ""
		registry.path_validation_adapter_registered[last] = false
		registry.path_validation_urls[last] = ""
		registry.connection_generations[last] = 0
		registry.command_sockets[last] = net.TCP_Socket(0)
		registry.live_bridge_count -= 1
		return
	}
}

bridge_runtime_registry_has_path_validation_adapter :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> bool {
	if registry == nil || bridge_id == "" do return false
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.path_validation_adapter_registered[i] || registry.path_validation_urls[i] != "" }
	return false
}

bridge_runtime_registry_path_validation_url :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> string {
	if registry == nil || bridge_id == "" do return ""
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.path_validation_urls[i] }
	return ""
}

bridge_runtime_registry_generation :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> int {
	if registry == nil || bridge_id == "" do return 0
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.connection_generations[i] }
	return 0
}

bridge_runtime_registry_set_command_socket :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, socket: net.TCP_Socket) {
	if registry == nil || bridge_id == "" do return
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id { registry.command_sockets[i] = socket; return } }
}

bridge_runtime_registry_command_socket :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> (net.TCP_Socket, bool) {
	if registry == nil || bridge_id == "" do return {}, false
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id && registry.command_sockets[i] != net.TCP_Socket(0) do return registry.command_sockets[i], true }
	return {}, false
}

Runtime_Command :: struct {
	bridge_id: string,
	command_id: string,
	body_json: string,
}

Bridge_Validate_Project_Path_Proc :: proc(ctx: rawptr, command: Validate_Project_Path_Command) -> (Project_Path_Validation_Result, bool, domain.Domain_Error)
Bridge_Send_Runtime_Command_Proc :: proc(ctx: rawptr, command: Runtime_Command) -> (bool, domain.Domain_Error)

Bridge_Command_Sink :: struct {
	ctx: rawptr,
	validate_project_path: Bridge_Validate_Project_Path_Proc,
	send_runtime_command: Bridge_Send_Runtime_Command_Proc,
}

Project_Service :: struct {
	projects: ^iface.Project_Repository,
	bridges: ^iface.Bridge_Repository,
	bridge_command_sink: Bridge_Command_Sink,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
}

Create_Project_Input :: struct {
	name, slug, description, repo_url, vcs_kind, default_path: string,
	owner_user_id: string, // ignored; authoritative owner comes from AuthContext
}
Update_Project_Input :: struct {
	name, slug, description, repo_url, vcs_kind, default_path: string,
	owner_user_id: string, // if present and different, rejected as immutable
}
Bridge_Path_Input :: struct { path: string }
Validation_Result :: struct { path: domain.Project_Bridge_Path, effective_path: string }

new_project_service :: proc(projects: ^iface.Project_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Project_Service {
	return Project_Service{projects = projects, bridges = bridges, clock = clock, ids = ids}
}

new_project_service_with_command_sink :: proc(projects: ^iface.Project_Repository, bridges: ^iface.Bridge_Repository, sink: Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Project_Service {
	return Project_Service{projects = projects, bridges = bridges, bridge_command_sink = sink, clock = clock, ids = ids}
}

bridge_command_validate_project_path :: proc(sink: Bridge_Command_Sink, command: Validate_Project_Path_Command) -> (Project_Path_Validation_Result, bool, domain.Domain_Error) {
	if sink.validate_project_path == nil do return Project_Path_Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return sink.validate_project_path(sink.ctx, command)
}

bridge_command_send_runtime :: proc(sink: Bridge_Command_Sink, command: Runtime_Command) -> (bool, domain.Domain_Error) {
	if sink.send_runtime_command == nil do return false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return sink.send_runtime_command(sink.ctx, command)
}


create :: proc(service: ^Project_Service, auth: contracts.Auth_Context, input: Create_Project_Input) -> (domain.Project, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Project{}, false, err
	if input.name == "" do return domain.Project{}, false, domain.domain_error(.Validation_Failed, "project name is required")
	if input.default_path == "" do return domain.Project{}, false, domain.domain_error(.Validation_Failed, "default_path is required")
	now := platform.clock_now(service.clock)
	slug := input.slug; if slug == "" do slug = input.name
	project := domain.Project{project_id = domain.Project_ID(platform.generate_id(service.ids, "proj_")), owner_user_id = owner, name = input.name, slug = slug, description = input.description, repo_url = input.repo_url, vcs_kind = input.vcs_kind, default_path = input.default_path, created_at = now, updated_at = now}
	return iface.project_save(service.projects, project)
}

get :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	project, ok, err := iface.project_get(service.projects, project_id)
	if !ok do return domain.Project{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, project.owner_user_id); !owner_ok do return domain.Project{}, false, owner_err
	return project, true, domain.Domain_Error{}
}

list :: proc(service: ^Project_Service, auth: contracts.Auth_Context, limit: int = 50, cursor: string = "") -> ([]domain.Project, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.project_list_by_owner(service.projects, owner, limit, cursor)
}

update :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, input: Update_Project_Input) -> (domain.Project, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return domain.Project{}, false, err
	if mutation_ok, mutation_err := ownership.reject_owner_mutation(project.owner_user_id, domain.User_ID(input.owner_user_id)); !mutation_ok do return domain.Project{}, false, mutation_err
	if input.name != "" do project.name = input.name
	if input.slug != "" do project.slug = input.slug
	if input.description != "" do project.description = input.description
	if input.repo_url != "" do project.repo_url = input.repo_url
	if input.vcs_kind != "" do project.vcs_kind = input.vcs_kind
	if input.default_path != "" do project.default_path = input.default_path
	project.updated_at = platform.clock_now(service.clock)
	return iface.project_update(service.projects, project)
}

set_bridge_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string, input: Bridge_Path_Input) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return domain.Project_Bridge_Path{}, false, err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return domain.Project_Bridge_Path{}, false, bridge_err
	if bridge.owner_user_id != project.owner_user_id do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if input.path == "" do return domain.Project_Bridge_Path{}, false, domain.domain_error(.Validation_Failed, "path is required")
	now := platform.clock_now(service.clock)
	existing, existing_ok, _ := iface.project_get_bridge_path(service.projects, project_id, bridge_id)
	created_at := now; if existing_ok do created_at = existing.created_at
	path := domain.Project_Bridge_Path{project_id = project.project_id, bridge_id = bridge_id, owner_user_id = project.owner_user_id, path = input.path, is_validated = false, created_at = created_at, updated_at = now}
	return iface.project_save_bridge_path(service.projects, path)
}

delete_bridge_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string) -> (bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return false, err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return false, bridge_err
	if bridge.owner_user_id != project.owner_user_id do return false, domain.domain_error(.Not_Found, "bridge not found")
	return iface.project_delete_bridge_path(service.projects, project.project_id, bridge_id, project.owner_user_id)
}

list_bridge_paths :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> ([]domain.Project_Bridge_Path, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return nil, err
	return iface.project_list_bridge_paths(service.projects, project.project_id, project.owner_user_id)
}

resolve_effective_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string) -> (string, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return "", false, err
	path, path_ok, _ := iface.project_get_bridge_path(service.projects, project.project_id, bridge_id)
	if path_ok do return path.path, true, domain.Domain_Error{}
	return project.default_path, true, domain.Domain_Error{}
}

validate_bridge_path :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_id: string) -> (Validation_Result, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return Validation_Result{}, false, err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !bridge_ok do return Validation_Result{}, false, bridge_err
	if bridge.owner_user_id != project.owner_user_id do return Validation_Result{}, false, domain.domain_error(.Not_Found, "bridge not found")
	if bridge.status == .Revoked do return Validation_Result{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if bridge.status != .Online do return Validation_Result{}, false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	effective, effective_ok, effective_err := resolve_effective_path(service, auth, project_id, bridge_id)
	if !effective_ok do return Validation_Result{}, false, effective_err
	command_id := strings.concatenate({platform.generate_id(service.ids, "cmd_"), "_", string(project.project_id), "_", bridge.bridge_id})
	command := Validate_Project_Path_Command{type = "validate_project_path", command_id = command_id, project_id = project.project_id, bridge_id = bridge.bridge_id, path = effective, vcs_kind = project.vcs_kind, repo_url = project.repo_url}
	result, result_ok, result_err := bridge_command_validate_project_path(service.bridge_command_sink, command)
	if !result_ok do return Validation_Result{}, false, result_err
	now := platform.clock_now(service.clock)
	path, path_ok, _ := iface.project_get_bridge_path(service.projects, project.project_id, bridge_id)
	if !path_ok { path = domain.Project_Bridge_Path{project_id = project.project_id, bridge_id = bridge_id, owner_user_id = project.owner_user_id, path = effective, created_at = now} }
	path.is_validated = result.ok
	path.last_validated_at = now
	path.validation_error = result.validation_error
	path.validation_details_json = result.details_json
	path.updated_at = now
	saved, saved_ok, save_err := iface.project_save_bridge_path(service.projects, path)
	if !saved_ok do return Validation_Result{}, false, save_err
	return Validation_Result{path = saved, effective_path = effective}, true, domain.Domain_Error{}
}
