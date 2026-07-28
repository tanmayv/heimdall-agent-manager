package hub_phase5_bridge_test

import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import platform "odin_test:hub/platform"

Fake_Bridge_Repo :: struct {
	enrollments: [8]domain.Bridge_Enrollment,
	enrollment_count: int,
	bridges: [8]domain.Bridge,
	bridge_count: int,
	seq: int,
}

fixed_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
fixed_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	repo := (^Fake_Bridge_Repo)(ctx)
	repo.seq += 1
	return fmt.tprintf("%s%d", prefix, repo.seq)
}

save_enrollment :: proc(ctx: rawptr, enrollment: domain.Bridge_Enrollment) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.enrollment_count {
		if repo.enrollments[i].enrollment_id == enrollment.enrollment_id || repo.enrollments[i].token_hash == enrollment.token_hash {
			repo.enrollments[i] = enrollment
			return enrollment, true, domain.Domain_Error{}
		}
	}
	repo.enrollments[repo.enrollment_count] = enrollment
	repo.enrollment_count += 1
	return enrollment, true, domain.Domain_Error{}
}

get_enrollment_by_token_hash :: proc(ctx: rawptr, token_hash: string) -> (domain.Bridge_Enrollment, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.enrollment_count { if repo.enrollments[i].token_hash == token_hash do return repo.enrollments[i], true, domain.Domain_Error{} }
	return domain.Bridge_Enrollment{}, false, domain.domain_error(.Not_Found, "enrollment not found")
}

save_bridge :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.bridge_count { if repo.bridges[i].bridge_id == bridge.bridge_id { repo.bridges[i] = bridge; return bridge, true, domain.Domain_Error{} } }
	repo.bridges[repo.bridge_count] = bridge
	repo.bridge_count += 1
	return bridge, true, domain.Domain_Error{}
}

get_bridge :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.bridge_count { if repo.bridges[i].bridge_id == bridge_id do return repo.bridges[i], true, domain.Domain_Error{} }
	return domain.Bridge{}, false, domain.domain_error(.Not_Found, "bridge not found")
}

get_bridge_by_token_hash :: proc(ctx: rawptr, token_hash: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.bridge_count { if repo.bridges[i].bridge_token_hash == token_hash do return repo.bridges[i], true, domain.Domain_Error{} }
	return domain.Bridge{}, false, domain.domain_error(.Not_Found, "bridge not found")
}

list_by_owner :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	out := make([dynamic]domain.Bridge)
	for i in 0..<repo.bridge_count { if repo.bridges[i].owner_user_id == owner_user_id do append(&out, repo.bridges[i]) }
	return out[:], domain.Domain_Error{}
}

main :: proc() {
	repo_data: Fake_Bridge_Repo
	repo := iface.Bridge_Repository{ctx = rawptr(&repo_data), save_enrollment = save_enrollment, get_enrollment_by_token_hash = get_enrollment_by_token_hash, save_bridge = save_bridge, get_bridge = get_bridge, get_bridge_by_token_hash = get_bridge_by_token_hash, list_by_owner = list_by_owner}
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&repo_data), generate = fixed_id_generate}
	service := bridge_service.new_bridge_service(&repo, &clock, &ids)
	auth_a := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	auth_b := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "bob"}

	created, ok, err := bridge_service.create_enrollment(&service, auth_a, bridge_service.Create_Enrollment_Input{})
	check(ok, err.message)
	check(created.token != "" && created.enrollment.owner_user_id == domain.User_ID("alice"), "enrollment must belong to authenticated user and return one-time token")
	enrolled, enroll_ok, enroll_err := bridge_service.enroll_bridge(&service, bridge_service.Enroll_Bridge_Input{enrollment_token = created.token, machine_hostname = "host-a", machine_os = "darwin", machine_arch = "arm64"})
	check(enroll_ok, enroll_err.message)
	check(enrolled.bridge.owner_user_id == domain.User_ID("alice"), "bridge must inherit enrollment owner")
	check(enrolled.bridge.label == "host-a" && !enrolled.bridge.label_is_user_customized, "default label must follow hostname")
	_, reuse_ok, reuse_err := bridge_service.enroll_bridge(&service, bridge_service.Enroll_Bridge_Input{enrollment_token = created.token, machine_hostname = "host-b"})
	check(!reuse_ok && reuse_err.code == .Conflict, "enrollment token must be one-time")
	expired, expired_create_ok, expired_create_err := bridge_service.create_enrollment(&service, auth_a, bridge_service.Create_Enrollment_Input{expires_at = "2000-01-01T00:00:00Z"})
	check(expired_create_ok, expired_create_err.message)
	_, expired_ok, expired_err := bridge_service.enroll_bridge(&service, bridge_service.Enroll_Bridge_Input{enrollment_token = expired.token, machine_hostname = "old-host"})
	check(!expired_ok && expired_err.code == .Conflict, "expired enrollment token must be rejected")
	list_a, list_a_err := bridge_service.list_bridges(&service, auth_a)
	check(list_a_err.code == .None && len(list_a) == 1, "owner should list own bridge")
	list_b, list_b_err := bridge_service.list_bridges(&service, auth_b)
	check(list_b_err.code == .None && len(list_b) == 0, "other user must not list bridge")
	_, b_get_ok, b_get_err := bridge_service.get_bridge(&service, auth_b, enrolled.bridge.bridge_id)
	check(!b_get_ok && b_get_err.code == .Not_Found, "cross-user bridge read must be hidden")
	ctx, token_ok, token_err := bridge_service.verify_bridge_token(&service, enrolled.bridge_token)
	check(token_ok && ctx.kind == .Bridge_Token && ctx.user_id == "alice" && ctx.bridge_id == enrolled.bridge.bridge_id, token_err.message)
	renamed, rename_ok, rename_err := bridge_service.rename_bridge(&service, auth_a, enrolled.bridge.bridge_id, "custom")
	check(rename_ok && renamed.label_is_user_customized && renamed.label == "custom", rename_err.message)
	refreshed := bridge_service.refresh_hostname(&service, renamed, "new-host")
	check(refreshed.label == "custom", "customized label must not be overwritten by hostname")
	plain := enrolled.bridge
	plain = bridge_service.refresh_hostname(&service, plain, "new-host")
	check(plain.label == "new-host", "non-custom label should follow hostname")
	revoked, revoke_ok, revoke_err := bridge_service.revoke_bridge(&service, auth_a, enrolled.bridge.bridge_id)
	check(revoke_ok && revoked.status == .Revoked, revoke_err.message)
	_, revoked_token_ok, revoked_token_err := bridge_service.verify_bridge_token(&service, enrolled.bridge_token)
	check(!revoked_token_ok && revoked_token_err.code == .Forbidden, "revoked bridge token must be rejected")
	fmt.println("PASS: hub phase5 bridge")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
