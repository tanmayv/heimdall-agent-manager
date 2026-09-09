package agent

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Minimal in-memory agent store backing a fake Agent_Repository so create_agent
// can be exercised without sqlite.
Fake_Agent_Store :: struct {
	agents: [dynamic]domain.Agent,
}

fake_agent_save :: proc(ctx: rawptr, a: domain.Agent) -> (domain.Agent, bool, domain.Domain_Error) {
	store := cast(^Fake_Agent_Store)ctx
	append(&store.agents, a)
	return a, true, {}
}

fake_agent_list_by_owner :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Agent, domain.Domain_Error) {
	store := cast(^Fake_Agent_Store)ctx
	out := make([dynamic]domain.Agent)
	for a in store.agents do if a.owner_user_id == owner do append(&out, a)
	return out[:], {}
}

fake_agent_service :: proc(store: ^Fake_Agent_Store, repo: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	repo^ = iface.Agent_Repository{ctx = store, save = fake_agent_save, list_by_owner = fake_agent_list_by_owner}
	clock^ = platform.real_clock()
	ids^ = platform.real_id_generator()
	return new_agent_service(repo, nil, clock, ids)
}

@(test)
test_create_agent_defaults_empty_template :: proc(t: ^testing.T) {
	store: Fake_Agent_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := fake_agent_service(&store, &repo, &clock, &ids)
	defer delete(store.agents)

	// No template supplied -> defaults to the built-in 'empty' template.
	agent, ok, err := create_agent(&service, contracts.Auth_Context{user_id = "user_1"}, Create_Agent_Input{name = "worker"})
	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, agent.template_id, domain.TEMPLATE_EMPTY_ID)

	// Whitespace-only template id is also treated as unset.
	blank, blank_ok, _ := create_agent(&service, contracts.Auth_Context{user_id = "user_1"}, Create_Agent_Input{name = "blanky", template_id = "   "})
	testing.expect_value(t, blank_ok, true)
	testing.expect_value(t, blank.template_id, domain.TEMPLATE_EMPTY_ID)
}

@(test)
test_create_agent_preserves_explicit_template :: proc(t: ^testing.T) {
	store: Fake_Agent_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := fake_agent_service(&store, &repo, &clock, &ids)
	defer delete(store.agents)

	agent, ok, _ := create_agent(&service, contracts.Auth_Context{user_id = "user_1"}, Create_Agent_Input{name = "custom", template_id = "tmpl_custom"})
	testing.expect_value(t, ok, true)
	testing.expect_value(t, agent.template_id, "tmpl_custom")
}
