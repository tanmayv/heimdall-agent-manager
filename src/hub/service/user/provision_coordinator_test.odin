package user

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// In-memory user + agent stores so provisioning can be exercised without sqlite.
User_Store :: struct {
	users: [dynamic]domain.User,
}

fake_user_get_by_id :: proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	store := cast(^User_Store)ctx
	for u in store.users do if u.user_id == id do return u, true, {}
	return domain.User{}, false, domain.domain_error(.Not_Found, "user not found")
}

fake_user_save :: proc(ctx: rawptr, u: domain.User) -> (domain.User, bool, domain.Domain_Error) {
	store := cast(^User_Store)ctx
	append(&store.users, u)
	return u, true, {}
}

Prov_Agent_Store :: struct {
	agents: [dynamic]domain.Agent,
}

fake_prov_agent_save :: proc(ctx: rawptr, a: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Prov_Agent_Store)ctx
	append(&store.agents, a)
	return a, true, {}
}

fake_prov_agent_list_by_owner :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent, domain.Domain_Error) {
	store := cast(^Prov_Agent_Store)ctx
	out := make([dynamic]domain.Agent)
	for a in store.agents do if a.owner_user_id == owner do append(&out, a)
	return out[:], {}
}

count_coordinators :: proc(store: ^Prov_Agent_Store, owner: domain.User_ID) -> int {
	count := 0
	for a in store.agents do if a.owner_user_id == owner && a.slug == COORDINATOR_AGENT_SLUG do count += 1
	return count
}

@(test)
test_provision_seeds_coordinator_agent :: proc(t: ^testing.T) {
	ustore: User_Store
	urepo := iface.User_Repository{ctx = &ustore, get_by_id = fake_user_get_by_id, save = fake_user_save}
	astore: Prov_Agent_Store
	arepo := iface.Agent_Repository{ctx = &astore, save = fake_prov_agent_save, list_by_owner = fake_prov_agent_list_by_owner}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_user_service(&urepo, &arepo, &clock, &ids)
	defer delete(ustore.users)
	defer delete(astore.agents)

	created, ok, err := ensure_user_from_auth(&service, "alice", "Alice", "", true)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, count_coordinators(&astore, created.user_id), 1)

	// The seeded coordinator uses the built-in default template.
	for a in astore.agents {
		if a.owner_user_id == created.user_id && a.slug == COORDINATOR_AGENT_SLUG {
			testing.expect_value(t, a.template_id, domain.TEMPLATE_EMPTY_ID)
		}
	}
}

@(test)
test_ensure_coordinator_agent_idempotent :: proc(t: ^testing.T) {
	astore: Prov_Agent_Store
	arepo := iface.Agent_Repository{ctx = &astore, save = fake_prov_agent_save, list_by_owner = fake_prov_agent_list_by_owner}
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_user_service(nil, &arepo, &clock, &ids)
	defer delete(astore.agents)

	ensure_coordinator_agent(&service, "user_x")
	ensure_coordinator_agent(&service, "user_x")
	testing.expect_value(t, count_coordinators(&astore, "user_x"), 1)
}
