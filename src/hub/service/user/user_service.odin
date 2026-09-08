package user

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

User_Service :: struct {
	users:  ^iface.User_Repository,
	// agents lets provisioning seed a durable 'coordinator' agent for new users so
	// first-time users always have an agent to start. Optional (nil in tests that
	// only exercise user CRUD); seeding is skipped when nil.
	agents: ^iface.Agent_Repository,
	clock:  ^platform.Clock,
	ids:    ^platform.ID_Generator,
}

new_user_service :: proc(users: ^iface.User_Repository, agents: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> User_Service {
	return User_Service{users = users, agents = agents, clock = clock, ids = ids}
}

// COORDINATOR_AGENT_SLUG is the slug of the durable agent seeded for every user
// so first-time users always have an agent to start.
COORDINATOR_AGENT_SLUG :: "coordinator"

// ensure_coordinator_agent seeds a durable 'coordinator' agent for owner if none
// exists yet. Idempotent (guarded by the existing-slug check) and best-effort:
// provisioning a user must never fail because agent seeding did. No-op when the
// agent repository is not wired.
ensure_coordinator_agent :: proc(service: ^User_Service, owner: domain.User_ID) {
	if service == nil || service.agents == nil || service.clock == nil || service.ids == nil do return
	if string(owner) == "" do return
	existing, list_err := iface.agent_list_by_owner(service.agents, owner, 200, "")
	if list_err.code != .None do return
	for a in existing {
		if a.slug == COORDINATOR_AGENT_SLUG do return
	}
	now := platform.clock_now(service.clock)
	agent := domain.Agent{
		agent_id = platform.generate_id(service.ids, "agt_"),
		owner_user_id = owner,
		name = COORDINATOR_AGENT_SLUG,
		slug = COORDINATOR_AGENT_SLUG,
		template_id = domain.TEMPLATE_EMPTY_ID,
		state = .Active,
		created_at = now,
		updated_at = now,
	}
	iface.agent_save(service.agents, agent)
}

get_user :: proc(service: ^User_Service, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	if string(user_id) == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "user_id is required")
	}
	return iface.user_get_by_id(service.users, user_id)
}

create_user_stub :: proc(service: ^User_Service, display_name, email: string) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.clock == nil || service.ids == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	if display_name == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "display_name is required")
	}
	now := platform.clock_now(service.clock)
	user_id := platform.generate_id(service.ids, "usr_")
	created := domain.User{
		user_id = domain.User_ID(user_id),
		name = user_id,
		display_name = display_name,
		email = email,
		status = .Active,
		created_at = now,
		updated_at = now,
	}
	return iface.user_save(service.users, created)
}

Create_User_Input :: struct {
	name: string,
	email: string,
	display_name: string,
}

// create_user is the explicit user-creation path used by `ham-hub users create`.
// name AND email are mandatory. The user_id is operator-independent: a fresh
// `usr_...` id is generated so issuance never depends on caller-supplied input.
create_user :: proc(service: ^User_Service, input: Create_User_Input) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.clock == nil || service.ids == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	name := strings.trim_space(input.name)
	email := strings.trim_space(input.email)
	if name == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "name is required")
	}
	if email == "" {
		return domain.User{}, false, domain.domain_error(.Validation_Failed, "email is required")
	}
	display := strings.trim_space(input.display_name)
	if display == "" do display = name
	now := platform.clock_now(service.clock)
	user_id := platform.generate_id(service.ids, "usr_")
	created := domain.User{
		user_id = domain.User_ID(user_id),
		name = name,
		display_name = display,
		email = email,
		status = .Active,
		created_at = now,
		updated_at = now,
	}
	saved, ok, save_err := iface.user_save(service.users, created)
	if !ok do return saved, ok, save_err
	ensure_coordinator_agent(service, saved.user_id)
	return saved, ok, save_err
}

ensure_user_from_auth :: proc(service: ^User_Service, user_id, display_name, email: string, auto_provision: bool) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.clock == nil {
		return domain.User{}, false, domain.domain_error(.Internal_Error, "user service is not configured")
	}
	normalized := normalize_user_id(user_id)
	if normalized == "" {
		return domain.User{}, false, domain.domain_error(.Unauthenticated, "trusted proxy identity is missing")
	}
	found, ok, err := iface.user_get_by_id(service.users, domain.User_ID(normalized))
	if ok {
		if found.status == .Disabled {
			return domain.User{}, false, domain.domain_error(.Forbidden, "user is disabled")
		}
		return found, true, domain.Domain_Error{}
	}
	if err.code != .Not_Found {
		return domain.User{}, false, err
	}
	if !auto_provision {
		return domain.User{}, false, domain.domain_error(.Not_Found, "user not found")
	}
	name := normalized
	display := strings.trim_space(display_name)
	if display == "" do display = name
	now := platform.clock_now(service.clock)
	created := domain.User{
		user_id = domain.User_ID(normalized),
		name = name,
		display_name = display,
		email = strings.trim_space(email),
		status = .Active,
		created_at = now,
		updated_at = now,
	}
	saved, saved_ok, save_err := iface.user_save(service.users, created)
	if !saved_ok do return saved, saved_ok, save_err
	ensure_coordinator_agent(service, saved.user_id)
	return saved, saved_ok, save_err
}

normalize_user_id :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	builder := strings.builder_make()
	for ch in trimmed {
		switch ch {
		case 'A'..='Z': strings.write_rune(&builder, ch + 32)
		case 'a'..='z', '0'..='9', '_', '-', '.', '@': strings.write_rune(&builder, ch)
		case ' ', '\t': strings.write_rune(&builder, '-')
		case:
			// Drop unsupported characters rather than trusting caller-supplied IDs verbatim.
		}
	}
	return strings.to_string(builder)
}
