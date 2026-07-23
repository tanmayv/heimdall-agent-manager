package user

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

User_Service :: struct {
	users: ^iface.User_Repository,
	clock: ^platform.Clock,
	ids:   ^platform.ID_Generator,
}

new_user_service :: proc(users: ^iface.User_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> User_Service {
	return User_Service{users = users, clock = clock, ids = ids}
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
	return iface.user_save(service.users, created)
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
