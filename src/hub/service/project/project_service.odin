package project

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
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
	public_keys: [128]string,
	connection_generations: [128]int,
	command_sockets: [128]net.TCP_Socket,
	live_bridge_count: int,
	// Eight terminal observations per admitted live Bridge. Results are short-lived
	// transport state, so a bounded 128 * 8 slab avoids an unbounded map while still
	// preventing one Bridge from consuming another Bridge's retention share.
	command_ids: [1024]string,
	command_bridge_ids: [1024]string,
	command_results_json: [1024]string,
	command_results_terminal: [1024]bool,
	command_result_sequence: [1024]u64,
	command_count: int,
	command_slots_used: int,
	// Stable per-Bridge writer locks. These are never compacted with live connection
	// slots, so a slow write for one Bridge cannot block any other Bridge and a slot
	// swap during disconnect cannot move a mutex while it is held.
	writer_bridge_ids: [256]string,
	writer_mutexes: [256]sync.Mutex,
	writer_count: int,
	instance_ids: [256]string,
	instance_state_seq: [256]int,
	instance_runtime_status: [256]string,
	instance_activity_status: [256]string,
	instance_count: int,
	edge_event_count: int,
	// command_mutex protects registry bookkeeping and the shared command-result
	// cache. It is never held across network IO. Socket writes use writer_mutexes,
	// isolated by durable bridge id.
	command_mutex: sync.Mutex,
	command_cond: sync.Cond,
	// metadata_mutex protects the compact live-connection arrays. It is separate
	// from both the result cache and per-Bridge writers so Bridge admission and
	// disconnect churn cannot stall unrelated result delivery.
	metadata_mutex: sync.Mutex,
}

// bridge_runtime_registry_command_lock/unlock guard registry metadata and the
// command cache. They are never held across network IO, blocking polls, or sleeps.
bridge_runtime_registry_command_lock :: proc(registry: ^Bridge_Runtime_Registry) {
	if registry != nil do sync.lock(&registry.command_mutex)
}

bridge_runtime_registry_command_unlock :: proc(registry: ^Bridge_Runtime_Registry) {
	if registry != nil do sync.unlock(&registry.command_mutex)
}

// Returns a stable lock dedicated to bridge_id. The mapping is process-lifetime
// and explicitly bounded; live-connection slot compaction never moves these locks.
bridge_runtime_registry_writer_mutex :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> ^sync.Mutex {
	if registry == nil || bridge_id == "" do return nil
	bridge_runtime_registry_command_lock(registry)
	defer bridge_runtime_registry_command_unlock(registry)
	for i in 0..<registry.writer_count {
		if registry.writer_bridge_ids[i] == bridge_id do return &registry.writer_mutexes[i]
	}
	if registry.writer_count >= len(registry.writer_bridge_ids) do return nil
	i := registry.writer_count
	registry.writer_bridge_ids[i] = strings.clone(bridge_id, runtime.default_allocator())
	registry.writer_mutexes[i] = sync.Mutex{}
	registry.writer_count += 1
	return &registry.writer_mutexes[i]
}

bridge_runtime_registry_mark_live :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, path_validation_adapter_registered: bool, path_validation_url: string) -> bool {
	if registry == nil || bridge_id == "" do return false
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	return bridge_runtime_registry_mark_live_locked(registry, bridge_id, path_validation_adapter_registered, path_validation_url)
}

bridge_runtime_registry_mark_live_locked :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, path_validation_adapter_registered: bool, path_validation_url: string) -> bool {
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] == bridge_id {
			registry.path_validation_adapter_registered[i] = path_validation_adapter_registered
			registry.path_validation_urls[i] = path_validation_url
			return true
		}
	}
	if registry.live_bridge_count < len(registry.live_bridge_ids) {
		registry.live_bridge_ids[registry.live_bridge_count] = bridge_id
		registry.path_validation_adapter_registered[registry.live_bridge_count] = path_validation_adapter_registered
		registry.path_validation_urls[registry.live_bridge_count] = path_validation_url
		registry.live_bridge_count += 1
		return true
	}
	return false
}

// Atomically admits/replaces a live Bridge and assigns its generation. Two
// concurrent hello frames for the same durable id cannot both observe generation
// N and accidentally become current.
bridge_runtime_registry_accept_live :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, path_validation_adapter_registered: bool, path_validation_url: string) -> (replaced: bool, generation: int, ok: bool) {
	if registry == nil || bridge_id == "" do return false, 0, false
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] != bridge_id do continue
		generation = registry.connection_generations[i] + 1
		registry.connection_generations[i] = generation
		registry.path_validation_adapter_registered[i] = path_validation_adapter_registered
		registry.path_validation_urls[i] = path_validation_url
		return true, generation, true
	}
	if !bridge_runtime_registry_mark_live_locked(registry, bridge_id, path_validation_adapter_registered, path_validation_url) do return false, 0, false
	registry.connection_generations[registry.live_bridge_count - 1] = 1
	return false, 1, true
}

bridge_runtime_registry_has_live :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> bool {
	if registry == nil || bridge_id == "" do return false
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return true }
	return false
}

bridge_runtime_registry_mark_offline :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, generation: int) {
	if registry == nil || bridge_id == "" do return
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] != bridge_id do continue
		if generation != 0 && registry.connection_generations[i] != generation do return
		if registry.public_keys[i] != "" do delete(registry.public_keys[i])
		last := registry.live_bridge_count - 1
		registry.live_bridge_ids[i] = registry.live_bridge_ids[last]
		registry.path_validation_adapter_registered[i] = registry.path_validation_adapter_registered[last]
		registry.path_validation_urls[i] = registry.path_validation_urls[last]
		registry.public_keys[i] = registry.public_keys[last]
		registry.connection_generations[i] = registry.connection_generations[last]
		registry.command_sockets[i] = registry.command_sockets[last]
		registry.live_bridge_ids[last] = ""
		registry.path_validation_adapter_registered[last] = false
		registry.path_validation_urls[last] = ""
		registry.public_keys[last] = ""
		registry.connection_generations[last] = 0
		registry.command_sockets[last] = net.TCP_Socket(0)
		registry.live_bridge_count -= 1
		return
	}
}

bridge_runtime_registry_set_public_key :: proc(registry: ^Bridge_Runtime_Registry, bridge_id, public_key: string) {
	if registry == nil || bridge_id == "" do return
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] == bridge_id {
			if registry.public_keys[i] != "" do delete(registry.public_keys[i])
			registry.public_keys[i] = strings.clone(public_key)
			return
		}
	}
	if registry.live_bridge_count < len(registry.live_bridge_ids) {
		registry.live_bridge_ids[registry.live_bridge_count] = bridge_id
		registry.public_keys[registry.live_bridge_count] = strings.clone(public_key)
		registry.live_bridge_count += 1
	}
}

bridge_runtime_registry_public_key :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> string {
	if registry == nil || bridge_id == "" do return ""
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] == bridge_id do return registry.public_keys[i]
	}
	return ""
}

bridge_runtime_registry_has_path_validation_adapter :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> bool {
	if registry == nil || bridge_id == "" do return false
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.path_validation_adapter_registered[i] || registry.path_validation_urls[i] != "" }
	return false
}

bridge_runtime_registry_path_validation_url :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> string {
	if registry == nil || bridge_id == "" do return ""
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.path_validation_urls[i] }
	return ""
}

bridge_runtime_registry_generation :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> int {
	if registry == nil || bridge_id == "" do return 0
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id do return registry.connection_generations[i] }
	return 0
}

bridge_runtime_registry_set_command_socket :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string, socket: net.TCP_Socket) {
	if registry == nil || bridge_id == "" do return
	writer_mu := bridge_runtime_registry_writer_mutex(registry, bridge_id)
	if writer_mu == nil do return
	sync.lock(writer_mu)
	defer sync.unlock(writer_mu)
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count { if registry.live_bridge_ids[i] == bridge_id { registry.command_sockets[i] = socket; return } }
}

// bridge_runtime_registry_shutdown_command_socket tears down a bridge's LIVE control
// connection (audit F6, design §7.5). Returns whether there was one to tear down.
//
// `net.shutdown`, NOT `net.close`, AND THAT CHOICE IS LOAD-BEARING. The socket is
// OWNED by the connection's own reader thread, which spends its life parked in a
// 120-second blocking read (bridge_ws_runtime_loop). Calling `close` from a
// different thread frees a file descriptor that another thread is actively reading:
// the read may return EBADF, or — the real hazard — the descriptor number may be
// reused by the next `accept()` while the old reader still holds it, at which point
// one connection reads another's bytes. `shutdown` instead marks the connection's
// ends down WITHOUT releasing the descriptor, so the parked read returns
// IMMEDIATELY, the owning thread runs its normal teardown path
// (bridge_ws_disconnect -> mark_offline) and closes its own descriptor exactly once.
// Revocation therefore takes effect in milliseconds rather than at the next read
// deadline, with no shared-descriptor race.
//
// The per-Bridge writer mutex is held because every other writer to this socket
// holds it; a shutdown racing a partially-written frame would otherwise interleave.
// The registry entry is deliberately NOT removed here: the owning thread's
// generation-guarded mark_offline is what retires it, and removing it from under
// that thread would make a reconnect look like a replacement of a live connection.
bridge_runtime_registry_shutdown_command_socket :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> bool {
	if registry == nil || bridge_id == "" do return false
	writer_mu := bridge_runtime_registry_writer_mutex(registry, bridge_id)
	if writer_mu == nil do return false
	sync.lock(writer_mu)
	defer sync.unlock(writer_mu)
	socket := net.TCP_Socket(0)
	sync.lock(&registry.metadata_mutex)
	for i in 0..<registry.live_bridge_count {
		if registry.live_bridge_ids[i] != bridge_id do continue
		socket = registry.command_sockets[i]
		break
	}
	sync.unlock(&registry.metadata_mutex)
	if socket == net.TCP_Socket(0) do return false
	// Both directions: `Send` alone would leave the bridge's own writes buffered
	// and the parked read still parked, which is the exact failure this exists to
	// avoid. An error is ignored on purpose — an already-dead socket is the outcome
	// we wanted. No registry metadata lock is held across this syscall.
	_ = net.shutdown(net.Any_Socket(socket), net.Shutdown_Manner.Both)
	return true
}

bridge_runtime_registry_command_socket :: proc(registry: ^Bridge_Runtime_Registry, bridge_id: string) -> (net.TCP_Socket, bool) {
	if registry == nil || bridge_id == "" do return {}, false
	sync.lock(&registry.metadata_mutex)
	defer sync.unlock(&registry.metadata_mutex)
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
Bridge_Send_Runtime_Command_Wait_Proc :: proc(ctx: rawptr, command: Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error)

Bridge_Command_Sink :: struct {
	ctx: rawptr,
	validate_project_path: Bridge_Validate_Project_Path_Proc,
	send_runtime_command: Bridge_Send_Runtime_Command_Proc,
	send_runtime_command_wait: Bridge_Send_Runtime_Command_Wait_Proc,
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

bridge_command_send_runtime_wait :: proc(sink: Bridge_Command_Sink, command: Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	if sink.send_runtime_command_wait == nil do return "", false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return sink.send_runtime_command_wait(sink.ctx, command, timeout_ms)
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

// archive_project soft-archives a project (reversible), mirroring archive_agent:
// ownership is enforced via get(), state flips to Archived, and the row is
// persisted (never removed). No cascade to chains/tasks/instances.
archive_project :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return domain.Project{}, false, err
	project.state = .Archived
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

Fs_Target :: struct { bridge_id: string, root_path: string }

// resolve_fs_target maps a project (owned by the caller) to the (bridge_id, root)
// pair the FS browser should operate against. When bridge_hint is supplied it is
// honored (must be a configured path for this project); otherwise the project's
// single configured bridge path is used. Ambiguous (multiple paths, no hint) or
// unconfigured projects are rejected so a browse never silently targets the wrong
// machine. Ownership is enforced via get().
resolve_fs_target :: proc(service: ^Project_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID, bridge_hint: string = "") -> (Fs_Target, bool, domain.Domain_Error) {
	project, ok, err := get(service, auth, project_id)
	if !ok do return Fs_Target{}, false, err
	paths, list_err := iface.project_list_bridge_paths(service.projects, project.project_id, project.owner_user_id)
	if list_err.code != .None do return Fs_Target{}, false, list_err
	if bridge_hint != "" {
		// Prefer an explicit per-bridge path override for this bridge.
		for p in paths {
			if p.bridge_id == bridge_hint && strings.trim_space(p.path) != "" {
				return Fs_Target{bridge_id = p.bridge_id, root_path = p.path}, true, domain.Domain_Error{}
			}
		}
		// No override (or an empty one) for this bridge: fall back to the project's
		// default_path so the file browser still works on a bridge that just uses the
		// default checkout location. The bridge re-sandboxes to this root; if the dir
		// doesn't exist there the listing simply reports path_not_found.
		if strings.trim_space(project.default_path) != "" {
			return Fs_Target{bridge_id = bridge_hint, root_path = project.default_path}, true, domain.Domain_Error{}
		}
		return Fs_Target{}, false, domain.domain_error(.Validation_Failed, "project has no path configured on this bridge and no default_path")
	}
	configured := 0
	chosen := domain.Project_Bridge_Path{}
	for p in paths {
		if strings.trim_space(p.path) == "" do continue
		configured += 1
		chosen = p
	}
	if configured == 0 do return Fs_Target{}, false, domain.domain_error(.Validation_Failed, "project has no bridge path configured")
	if configured > 1 do return Fs_Target{}, false, domain.domain_error(.Validation_Failed, "project is configured on multiple bridges; specify bridge_id")
	return Fs_Target{bridge_id = chosen.bridge_id, root_path = chosen.path}, true, domain.Domain_Error{}
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
