package bridge

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

Bridge_Service :: struct {
	repo: ^iface.Bridge_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	catalog: ^Bridge_Update_Catalog,
}

Create_Enrollment_Result :: struct {
	enrollment: domain.Bridge_Enrollment,
	token: string,
}

Enroll_Bridge_Result :: struct {
	bridge: domain.Bridge,
	bridge_token: string,
}

Create_Enrollment_Input :: struct {
	label: string,
	expires_at: string,
}

List_Enrollments_Result :: struct {
	enrollments: []domain.Bridge_Enrollment,
}

Enroll_Bridge_Input :: struct {
	enrollment_token: string, // must come from Authorization: Bearer or equivalent auth context in transport
	machine_hostname: string,
	machine_os: string,
	machine_arch: string,
	capabilities_json: string,
	hub_url: string,
}

new_bridge_service :: proc(repo: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Bridge_Service {
	return Bridge_Service{repo = repo, clock = clock, ids = ids}
}

new_bridge_service_with_runtime :: proc(repo: ^iface.Bridge_Repository, bridge_command_sink: project_service.Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Bridge_Service {
	return Bridge_Service{repo = repo, bridge_command_sink = bridge_command_sink, clock = clock, ids = ids}
}

create_enrollment :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, input: Create_Enrollment_Input) -> (Create_Enrollment_Result, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return Create_Enrollment_Result{}, false, err
	token := platform.generate_id(service.ids, "hbe_")
	now := platform.clock_now(service.clock)
	enrollment := domain.Bridge_Enrollment{
		enrollment_id = platform.generate_id(service.ids, "benr_"),
		owner_user_id = owner,
		label = input.label,
		token_hash = hash_token(token),
		status = .Pending,
		expires_at = input.expires_at,
		created_at = now,
		updated_at = now,
	}
	saved, save_ok, save_err := iface.bridge_save_enrollment(service.repo, enrollment)
	if !save_ok do return Create_Enrollment_Result{}, false, save_err
	return Create_Enrollment_Result{enrollment = saved, token = token}, true, domain.Domain_Error{}
}

list_enrollments :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context) -> ([]domain.Bridge_Enrollment, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.bridge_list_enrollments_by_owner(service.repo, owner)
}

revoke_enrollment :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, enrollment_id: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	enrollment, ok, err := iface.bridge_get_enrollment(service.repo, enrollment_id)
	if !ok do return domain.Bridge_Enrollment{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, enrollment.owner_user_id); !owner_ok do return domain.Bridge_Enrollment{}, false, owner_err
	if enrollment.status != .Pending do return domain.Bridge_Enrollment{}, false, domain.domain_error(.Conflict, "enrollment is not pending")
	enrollment.status = .Revoked
	enrollment.updated_at = platform.clock_now(service.clock)
	return iface.bridge_save_enrollment(service.repo, enrollment)
}

enroll_bridge :: proc(service: ^Bridge_Service, input: Enroll_Bridge_Input) -> (Enroll_Bridge_Result, bool, domain.Domain_Error) {
	if input.enrollment_token == "" do return Enroll_Bridge_Result{}, false, domain.domain_error(.Unauthenticated, "enrollment token is required")
	hub_url := strings.trim_space(input.hub_url)
	if hub_url != "" && !valid_hub_base_url(hub_url) do return Enroll_Bridge_Result{}, false, domain.domain_error(.Validation_Failed, "hub_url must be a valid http(s) base URL")
	enrollment, ok, err := iface.bridge_get_enrollment_by_token_hash(service.repo, hash_token(input.enrollment_token))
	if !ok do return Enroll_Bridge_Result{}, false, err
	if enrollment.status != .Pending do return Enroll_Bridge_Result{}, false, domain.domain_error(.Conflict, "enrollment token has already been used or revoked")
	now := platform.clock_now(service.clock)
	if enrollment.expires_at != "" && now != "" && enrollment.expires_at <= now do return Enroll_Bridge_Result{}, false, domain.domain_error(.Conflict, "enrollment token has expired")
	hostname := strings.trim_space(input.machine_hostname)
	if hostname == "" do hostname = "unknown-host"
	bridge_token := platform.generate_id(service.ids, "hbr_")
	label := enrollment.label
	customized := label != ""
	if label == "" do label = hostname
	bridge := domain.Bridge{
		bridge_id = platform.generate_id(service.ids, "brg_"),
		owner_user_id = enrollment.owner_user_id,
		label = label,
		label_is_user_customized = customized,
		machine_hostname = hostname,
		machine_os = input.machine_os,
		machine_arch = input.machine_arch,
		capabilities_json = input.capabilities_json,
		hub_url = hub_url,
		status = .Offline,
		bridge_token_hash = hash_token(bridge_token),
		created_at = now,
		updated_at = now,
		last_seen_at = now,
	}
	saved_bridge, bridge_ok, bridge_err := iface.bridge_save_bridge(service.repo, bridge)
	if !bridge_ok do return Enroll_Bridge_Result{}, false, bridge_err
	enrollment.status = .Consumed
	enrollment.consumed_at = now
	enrollment.consumed_by_bridge_id = saved_bridge.bridge_id
	enrollment.updated_at = now
	_, consume_ok, consume_err := iface.bridge_save_enrollment(service.repo, enrollment)
	if !consume_ok do return Enroll_Bridge_Result{}, false, consume_err
	return Enroll_Bridge_Result{bridge = saved_bridge, bridge_token = bridge_token}, true, domain.Domain_Error{}
}

list_bridges :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context) -> ([]domain.Bridge, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.bridge_list_by_owner(service.repo, owner)
}

get_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, bridge.owner_user_id); !owner_ok do return domain.Bridge{}, false, owner_err
	return bridge, true, domain.Domain_Error{}
}

bridge_owner_user_id :: proc(service: ^Bridge_Service, bridge_id: string) -> string {
	bridge, ok, _ := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return ""
	return string(bridge.owner_user_id)
}

// bridge_absence_marker reports when a bridge was last HEARD FROM, and whether it is
// eligible to be judged absent at all. Unauthenticated and internal, like
// bridge_owner_user_id above and for the same reason: the caller is the hub's own
// periodic sweep, which acts for no user.
//
// WHY last_seen_at IS THE RIGHT CLOCK, and it is not obvious from the column name.
// It is refreshed on EVERY heartbeat, ~45s: the bridge writes "capabilities" into
// every bridge_heartbeat frame unconditionally (bridge/hub_runtime_client.odin), the
// heartbeat handler therefore always calls update_runtime_capabilities, and that
// proc sets last_seen_at unconditionally. So it tracks LIVENESS, not the moment the
// connection was established.
// And mark_bridge_offline deliberately does NOT touch it, which is what makes it an
// absence clock rather than a proxy for one: on disconnect the value FREEZES at the
// last heartbeat and nothing moves it until the bridge genuinely returns. `now` minus
// this is therefore "how long since we last had this bridge".
//
// eligible is false for a REVOKED bridge: revocation is an administrative end, its
// sessions are not "maybe still running somewhere", and aging out a revoked bridge
// would be a second mechanism acting on a decision already taken.
// THE RETURNED STRING IS A CLONE AND THE CALLER OWNS IT. The repository's row reader
// hands back thirteen owned strings; this proc destroys the bridge before returning, so
// the one value that escapes cannot alias freed memory. That matters more than usual
// here because the caller runs on the reaper's process-scoped thread with no
// per-request arena — returning a borrowed field, as bridge_owner_user_id does, would
// leak the other twelve on every sweep.
bridge_absence_marker :: proc(service: ^Bridge_Service, bridge_id: string) -> (last_seen_at: string, eligible: bool) {
	if service == nil || service.repo == nil || bridge_id == "" do return "", false
	bridge, ok, _ := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return "", false
	defer { b := bridge; domain.bridge_destroy(&b) }
	if bridge.status == .Revoked do return "", false
	if bridge.last_seen_at == "" do return "", false
	return strings.clone(bridge.last_seen_at), true
}

patch_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string, label: string, has_label: bool, telemetry_enabled: string, has_telemetry: bool) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if has_label {
		if strings.trim_space(label) == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "label is required")
		bridge.label = label
		bridge.label_is_user_customized = true
	}
	if has_telemetry {
		val := strings.trim_space(telemetry_enabled)
		if val != "inherit" && val != "enabled" && val != "disabled" {
			return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "telemetry_enabled must be 'inherit', 'enabled', or 'disabled'")
		}
		bridge.telemetry_enabled = val
	}
	bridge.updated_at = platform.clock_now(service.clock)
	return iface.bridge_save_bridge(service.repo, bridge)
}

rename_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, label: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	return patch_bridge(service, auth, bridge_id, label, true, "", false)
}

bridge_runtime_connect :: proc(service: ^Bridge_Service, token: string, hostname, os_name, arch, capabilities_json: string, version: string = "", commit_sha: string = "", build_timestamp: string = "") -> (domain.Bridge, bool, domain.Domain_Error) {
	auth, auth_ok, auth_err := verify_bridge_token(service, token)
	if !auth_ok do return domain.Bridge{}, false, auth_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, auth.bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	if bridge.status == .Revoked do return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if hostname != "" {
		bridge.machine_hostname = hostname
		if !bridge.label_is_user_customized do bridge.label = hostname
	}
	if os_name != "" do bridge.machine_os = os_name
	if arch != "" do bridge.machine_arch = arch
	if capabilities_json != "" && strings.contains(capabilities_json, "\"capabilities\"") do bridge.capabilities_json = capabilities_json
	if version != "" do bridge.version = version
	if commit_sha != "" do bridge.commit_sha = commit_sha
	if build_timestamp != "" do bridge.build_timestamp = build_timestamp
	if bridge.update_status == "updating" do bridge.update_status = "idle"
	now := platform.clock_now(service.clock)
	bridge.status = .Online
	bridge.last_seen_at = now
	bridge.updated_at = now
	return iface.bridge_save_bridge(service.repo, bridge)
}

// mark_bridge_offline flips a bridge's durable status to .Offline on a WS
// disconnect. bridge_runtime_connect sets .Online but nothing symmetric marked
// the durable record offline when the control WS dropped, so the bridge row
// stayed .Online forever. Idempotent: a .Revoked bridge is left untouched, and
// re-marking an already-.Offline bridge is a cheap no-op save. Returns the
// bridge + whether the status actually changed so the caller can avoid a
// spurious event when nothing moved.
mark_bridge_offline :: proc(service: ^Bridge_Service, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	// Never override a terminal revoked state, and skip the write if already offline.
	if bridge.status == .Revoked || bridge.status == .Offline do return bridge, false, domain.Domain_Error{}
	now := platform.clock_now(service.clock)
	bridge.status = .Offline
	bridge.updated_at = now
	saved, ok, err := iface.bridge_save_bridge(service.repo, bridge)
	if !ok do return domain.Bridge{}, false, err
	return saved, true, domain.Domain_Error{}
}

update_runtime_capabilities :: proc(service: ^Bridge_Service, bridge_id, capabilities_json: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	if bridge.status == .Revoked do return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if capabilities_json != "" && strings.contains(capabilities_json, "\"capabilities\"") do bridge.capabilities_json = capabilities_json
	now := platform.clock_now(service.clock)
	bridge.status = .Online
	bridge.last_seen_at = now
	bridge.updated_at = now
	return iface.bridge_save_bridge(service.repo, bridge)
}

// BRIDGE_VAULT_STATUS_VALUES are the only values a bridge may report (REQ-BVS-1),
// matching bridge_vault_status_string on the bridge side. Anything else is dropped
// rather than stored: the field is rendered straight into the UI, and a bridge is
// free to send whatever it likes down the WS, so the hub pins the vocabulary here.
BRIDGE_VAULT_STATUS_VALUES :: [3]string{"unlocked", "locked", "disabled"}

bridge_vault_status_valid :: proc(value: string) -> bool {
	for allowed in BRIDGE_VAULT_STATUS_VALUES {
		if value == allowed do return true
	}
	return false
}

// update_vault_status stores a bridge's self-reported vault tri-state (REQ-BVS-1).
//
// changed is true ONLY when the stored value actually moved, and the DB write is
// skipped entirely when it did not. That is what makes the "invalidate on change, not
// on every heartbeat" requirement true at the source rather than at each call site:
// a bridge reports this in every heartbeat, ~45s, forever, and a caller that had to
// remember to diff first would eventually forget and flood every connected browser.
//
// An empty or unrecognised value is a no-op, NOT an error and NOT a write: an older
// bridge omits the field, and that must leave an existing reported value alone rather
// than erasing it to "".
//
// Unauthenticated and internal, like update_runtime_capabilities above and for the
// same reason: the caller is the bridge's own WS frame handler, already authenticated
// as this bridge by its token.
//
// THE RETURNED ROW IS FULLY OWNED ON EVERY SUCCESSFUL PATH and the caller must
// destroy it with domain.bridge_destroy.
//
// NOTHING MAY GATE ON THE RESULT. See the field comment on domain.Bridge.vault_status.
update_vault_status :: proc(service: ^Bridge_Service, bridge_id, vault_status: string) -> (bridge: domain.Bridge, changed: bool, err: domain.Domain_Error) {
	if service == nil || service.repo == nil || bridge_id == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	if !bridge_vault_status_valid(vault_status) do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "vault_status must be 'unlocked', 'locked', or 'disabled'")
	existing, ok, get_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return domain.Bridge{}, false, get_err
	if existing.status == .Revoked {
		e := existing
		domain.bridge_destroy(&e)
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if existing.vault_status == vault_status {
		// Unchanged: hand the row back so a caller can still read owner_user_id, but
		// report changed=false so no event is published and no row is rewritten.
		// The row is owned on every path out of here, so the caller destroys it
		// without having to know which path it came from.
		return existing, false, domain.Domain_Error{}
	}
	// CLONED, not borrowed. patch_bridge and update_runtime_capabilities both assign
	// the caller's string straight into the row, which leaves the returned row a mix of
	// owned and borrowed fields that nothing can safely destroy — so their callers
	// leak the whole row instead. Cloning here keeps every field owned, which is what
	// lets the caller do the obvious thing and call domain.bridge_destroy on it.
	if len(existing.vault_status) > 0 do delete(existing.vault_status)
	existing.vault_status = strings.clone(vault_status)
	// updated_at is CLONED for the same reason, and this one is a trap worth naming:
	// platform.clock_now returns a fmt.tprintf string, so it lives in the TEMP
	// allocator, not the heap. Every other service proc here assigns it straight into
	// the row — which is safe only because none of them destroy the row afterwards.
	// Pairing that idiom with a bridge_destroy frees a temp pointer, and the test
	// suite reports it as `bad free @ bridge.odin:76`.
	if len(existing.updated_at) > 0 do delete(existing.updated_at)
	existing.updated_at = strings.clone(platform.clock_now(service.clock))
	saved, save_ok, save_err := iface.bridge_save_bridge(service.repo, existing)
	if !save_ok do return domain.Bridge{}, false, save_err
	return saved, true, domain.Domain_Error{}
}

revoke_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	now := platform.clock_now(service.clock)
	bridge.status = .Revoked
	bridge.updated_at = now
	bridge.revoked_at = now
	return iface.bridge_save_bridge(service.repo, bridge)
}

valid_hub_base_url :: proc(value: string) -> bool {
	if strings.has_prefix(value, "http://") do return valid_hub_authority(value[len("http://"):])
	if strings.has_prefix(value, "https://") do return valid_hub_authority(value[len("https://"):])
	return false
}

valid_hub_authority :: proc(value: string) -> bool {
	if strings.trim_space(value) == "" do return false
	if strings.contains(value, "?") || strings.contains(value, "#") do return false
	if strings.contains(value, "/") do return false
	return true
}

verify_bridge_token :: proc(service: ^Bridge_Service, token: string) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if token == "" do return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bridge token is required")
	bridge, ok, err := iface.bridge_get_bridge_by_token_hash(service.repo, hash_token(token))
	if !ok do return contracts.Auth_Context{}, false, err
	if bridge.status == .Revoked do return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "bridge is revoked")
	return contracts.Auth_Context{kind = .Bridge_Token, user_id = string(bridge.owner_user_id), bridge_id = bridge.bridge_id}, true, domain.Domain_Error{}
}

refresh_hostname :: proc(service: ^Bridge_Service, bridge: domain.Bridge, hostname: string) -> domain.Bridge {
	updated := bridge
	if hostname == "" do return updated
	updated.machine_hostname = hostname
	if !updated.label_is_user_customized do updated.label = hostname
	updated.updated_at = platform.clock_now(service.clock)
	return updated
}

hash_token :: proc(token: string) -> string {
	// Deterministic non-cryptographic placeholder for the repository boundary/tests;
	// replace with platform.hash argon2/sha before production secrets are stored.
	acc: u64 = 1469598103934665603
	for b in transmute([]byte)token {
		acc = (acc ~ u64(b)) * 1099511628211
	}
	return fmt.tprintf("h_%016x", acc)
}

write_service_json_string :: proc(b: ^strings.Builder, value: string) {
	contracts.write_json_string(b, value)
}

shell_pty_input_command_json :: proc(command_id, shell_id, data: string, enc_b64: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_pty_input\",\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"data\":\"")
	write_service_json_string(&b, data)
	strings.write_string(&b, "\"")
	if enc_b64 != "" {
		strings.write_string(&b, ",\"enc_b64\":\"")
		write_service_json_string(&b, enc_b64)
		strings.write_string(&b, "\"")
		armored := enc_b64 if strings.has_prefix(enc_b64, "vault:v1:") else strings.concatenate({"vault:v1:", enc_b64}, context.temp_allocator)
		strings.write_string(&b, ",\"data_b64\":\"")
		write_service_json_string(&b, armored)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

shell_pty_resize_command_json :: proc(command_id, shell_id: string, rows, cols: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_pty_resize\",\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"rows\":")
	strings.write_int(&b, rows)
	strings.write_string(&b, ",\"cols\":")
	strings.write_int(&b, cols)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

send_shell_input :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, shell_id, data: string, enc_b64: string = "", sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	if strings.trim_space(shell_id) == "" {
		return false, domain.domain_error(.Validation_Failed, "shell_id is required")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return false, err

	if bridge.status == .Revoked {
		return false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}

	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_sh_input_")
	}

	cmd_json := shell_pty_input_command_json(cmd_id, shell_id, data, enc_b64)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command{
			bridge_id = bridge.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

send_shell_resize :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, shell_id: string, rows, cols: int, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	if strings.trim_space(shell_id) == "" {
		return false, domain.domain_error(.Validation_Failed, "shell_id is required")
	}
	if rows < 1 || cols < 1 {
		return false, domain.domain_error(.Validation_Failed, "rows and cols must be at least 1")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return false, err

	if bridge.status == .Revoked {
		return false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}

	r := rows
	c := cols
	if r > 65535 do r = 65535
	if c > 65535 do c = 65535

	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_sh_resize_")
	}

	cmd_json := shell_pty_resize_command_json(cmd_id, shell_id, r, c)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command{
			bridge_id = bridge.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

// --- LSP session commands (REQ-LSP-RLY-1) ------------------------------------
//
// These mirror send_shell_input/send_shell_resize above: same bridge lookup, same
// revoked/offline gating, same command sink. The frame types are the ones the
// bridge's bridge_lsp_handle_command dispatches (src/bridge/lsp_session.odin).
//
// session_id here is the HUB WIRE ID, not the client-supplied session id. The
// bridge keys its own session map by this string alone, so two users choosing the
// same client session id must not collide on it; the relay allocates an opaque
// wire id per session and that is what crosses this boundary.

lsp_start_command_json :: proc(cmd_id, session_id, language, cmd, args, cwd, owner_user_id: string, root_markers: string = "", file_path: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_start\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"language\":\"")
	contracts.write_json_string(&b, language)
	strings.write_string(&b, "\",\"cmd\":\"")
	contracts.write_json_string(&b, cmd)
	strings.write_string(&b, "\",\"args\":\"")
	contracts.write_json_string(&b, args)
	strings.write_string(&b, "\",\"cwd\":\"")
	contracts.write_json_string(&b, cwd)
	strings.write_string(&b, "\",\"owner_user_id\":\"")
	contracts.write_json_string(&b, owner_user_id)
	strings.write_string(&b, "\"")
	if strings.trim_space(root_markers) != "" {
		strings.write_string(&b, ",\"root_markers\":\"")
		contracts.write_json_string(&b, root_markers)
		strings.write_string(&b, "\"")
	}
	if strings.trim_space(file_path) != "" {
		strings.write_string(&b, ",\"file_path\":\"")
		contracts.write_json_string(&b, file_path)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

lsp_send_command_json :: proc(session_id, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_send\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"message\":\"")
	contracts.write_json_string(&b, message)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

lsp_stop_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_stop\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// lsp_bridge_ready resolves the bridge and rejects revoked/offline ones. Shared by
// the three senders below so the gating cannot drift between them.
lsp_bridge_ready :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, session_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	if strings.trim_space(session_id) == "" {
		return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "session_id is required")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if bridge.status == .Revoked {
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}
	return bridge, true, domain.Domain_Error{}
}

lsp_sink_for :: proc(service: ^Bridge_Service, sink_override: project_service.Bridge_Command_Sink) -> project_service.Bridge_Command_Sink {
	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}
	return sink
}

send_lsp_start :: proc(
	service: ^Bridge_Service,
	auth: contracts.Auth_Context,
	bridge_id, session_id, language, cmd, args, cwd, owner_user_id: string,
	root_markers: string = "",
	file_path: string = "",
	sink_override: project_service.Bridge_Command_Sink = {},
) -> (bool, domain.Domain_Error) {
	if strings.trim_space(cmd) == "" {
		return false, domain.domain_error(.Validation_Failed, "cmd is required")
	}
	bridge, ok, err := lsp_bridge_ready(service, auth, bridge_id, session_id)
	if !ok do return false, err

	cmd_id := ""
	if service.ids != nil do cmd_id = platform.generate_id(service.ids, "cmd_lsp_start_")

	cmd_json := lsp_start_command_json(cmd_id, session_id, language, cmd, args, cwd, owner_user_id, root_markers, file_path)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		lsp_sink_for(service, sink_override),
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

send_lsp_message :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, session_id, message: string, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	if strings.trim_space(message) == "" {
		return false, domain.domain_error(.Validation_Failed, "message is required")
	}
	bridge, ok, err := lsp_bridge_ready(service, auth, bridge_id, session_id)
	if !ok do return false, err

	// lsp_send carries no command_id: it is a stream of JSON-RPC traffic, not a
	// request/result pair, and the bridge's handler does not read one.
	cmd_json := lsp_send_command_json(session_id, message)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		lsp_sink_for(service, sink_override),
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = "", body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

send_lsp_stop :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, session_id: string, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	bridge, ok, err := lsp_bridge_ready(service, auth, bridge_id, session_id)
	if !ok do return false, err

	cmd_id := ""
	if service.ids != nil do cmd_id = platform.generate_id(service.ids, "cmd_lsp_stop_")

	cmd_json := lsp_stop_command_json(cmd_id, session_id)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		lsp_sink_for(service, sink_override),
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

bridge_update_command_json :: proc(cmd_id, target_version, download_url, sha256: string, force: bool, drain_timeout_seconds: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_update\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"target_version\":\"")
	contracts.write_json_string(&b, target_version)
	strings.write_string(&b, "\",\"download_url\":\"")
	contracts.write_json_string(&b, download_url)
	strings.write_string(&b, "\",\"sha256\":\"")
	contracts.write_json_string(&b, sha256)
	strings.write_string(&b, "\",\"force\":")
	strings.write_string(&b, "true" if force else "false")
	strings.write_string(&b, ",\"drain_timeout_seconds\":")
	strings.write_string(&b, fmt.tprintf("%d", drain_timeout_seconds))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

send_bridge_update :: proc(
	service: ^Bridge_Service,
	auth: contracts.Auth_Context,
	bridge_id: string,
	target_version: string = "latest",
	force: bool = false,
	drain_timeout_seconds: int = 60,
	sink_override: project_service.Bridge_Command_Sink = {},
) -> (string, bool, domain.Domain_Error) {
	if strings.trim_space(bridge_id) == "" {
		return "", false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	}
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy {
		return "", false, domain.domain_error(.Forbidden, "user authentication required to update bridge")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return "", false, err

	if bridge.status == .Revoked {
		return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return "", false, domain.domain_error(.Unprocessable_Entity, fmt.tprintf("Bridge %s is not online", bridge.bridge_id))
	}

	info := resolve_bridge_update_info(service.catalog, bridge)
	effective_version := target_version
	if effective_version == "" || effective_version == "latest" {
		effective_version = info.latest_version
	}
	download_url := info.download_url
	sha256 := info.sha256

	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_upd_")
	} else {
		cmd_id = "cmd_upd_default"
	}

	cmd_json := bridge_update_command_json(cmd_id, effective_version, download_url, sha256, force, drain_timeout_seconds)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command{
			bridge_id = bridge.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)
	if !sent do return "", false, send_err

	bridge.update_status = "updating"
	bridge.updated_at = platform.clock_now(service.clock)
	iface.bridge_save_bridge(service.repo, bridge)

	return strings.clone(cmd_id), true, domain.Domain_Error{}
}

