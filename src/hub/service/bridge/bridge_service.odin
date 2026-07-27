package bridge

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"

Bridge_Service :: struct {
	repo: ^iface.Bridge_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
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

rename_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, label: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if strings.trim_space(label) == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "label is required")
	bridge.label = label
	bridge.label_is_user_customized = true
	bridge.updated_at = platform.clock_now(service.clock)
	return iface.bridge_save_bridge(service.repo, bridge)
}

bridge_runtime_connect :: proc(service: ^Bridge_Service, token: string, hostname, os_name, arch, capabilities_json: string) -> (domain.Bridge, bool, domain.Domain_Error) {
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
	now := platform.clock_now(service.clock)
	bridge.status = .Online
	bridge.last_seen_at = now
	bridge.updated_at = now
	return iface.bridge_save_bridge(service.repo, bridge)
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
