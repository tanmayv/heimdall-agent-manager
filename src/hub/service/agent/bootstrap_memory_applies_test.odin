package agent

import "core:testing"
import domain "odin_test:hub/domain"

// These tests cover the list-based memory targeting semantics: an empty list for
// a dimension means "applies to all"; a non-empty list means the instance value
// must be a member; dimensions are ANDed together. The template dimension is
// exercised separately (it needs an agent repository) — here we keep template_ids
// empty so a nil service is valid.

@(test)
test_bootstrap_memory_applies_empty_lists_apply_to_all :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1"), bridge_id = "brg_1"}
	m := domain.Memory{status = "active"} // all lists empty
	testing.expect_value(t, bootstrap_memory_applies(m, nil, "user_1", inst), true)
}

@(test)
test_bootstrap_memory_applies_inactive_never_matches :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1"}
	m := domain.Memory{status = "pending"}
	testing.expect_value(t, bootstrap_memory_applies(m, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_agent_membership :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1"), bridge_id = "brg_1"}

	member := domain.Memory{status = "active", agent_ids = []string{"agt_0", "agt_1"}}
	testing.expect_value(t, bootstrap_memory_applies(member, nil, "user_1", inst), true)

	non_member := domain.Memory{status = "active", agent_ids = []string{"agt_2"}}
	testing.expect_value(t, bootstrap_memory_applies(non_member, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_project_membership :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1")}

	member := domain.Memory{status = "active", project_ids = []domain.Project_ID{domain.Project_ID("proj_1")}}
	testing.expect_value(t, bootstrap_memory_applies(member, nil, "user_1", inst), true)

	non_member := domain.Memory{status = "active", project_ids = []domain.Project_ID{domain.Project_ID("proj_9")}}
	testing.expect_value(t, bootstrap_memory_applies(non_member, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_bridge_membership :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", bridge_id = "brg_1"}

	member := domain.Memory{status = "active", bridge_ids = []string{"brg_1"}}
	testing.expect_value(t, bootstrap_memory_applies(member, nil, "user_1", inst), true)

	non_member := domain.Memory{status = "active", bridge_ids = []string{"brg_2"}}
	testing.expect_value(t, bootstrap_memory_applies(non_member, nil, "user_1", inst), false)
}

@(test)
test_bootstrap_memory_applies_dimensions_are_anded :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{agent_id = "agt_1", project_id = domain.Project_ID("proj_1"), bridge_id = "brg_1"}

	// agent matches but project does not -> excluded.
	m := domain.Memory{status = "active", agent_ids = []string{"agt_1"}, project_ids = []domain.Project_ID{domain.Project_ID("proj_9")}}
	testing.expect_value(t, bootstrap_memory_applies(m, nil, "user_1", inst), false)

	// both agent and project match -> included.
	m2 := domain.Memory{status = "active", agent_ids = []string{"agt_1"}, project_ids = []domain.Project_ID{domain.Project_ID("proj_1")}}
	testing.expect_value(t, bootstrap_memory_applies(m2, nil, "user_1", inst), true)
}

@(test)
test_bootstrap_memory_applies_agent_variant_excludes_bridge_scoped :: proc(t: ^testing.T) {
	agent := domain.Agent{agent_id = "agt_1", owner_user_id = "user_1", template_id = "tmpl_1"}

	// Bridge-scoped memories cannot be resolved for the agent-keyed manifest.
	bridge_scoped := domain.Memory{status = "active", bridge_ids = []string{"brg_1"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(bridge_scoped, agent, "user_1", domain.Project_ID("proj_1")), false)

	// Empty bridge list still resolves; agent + project membership honored.
	global := domain.Memory{status = "active"}
	testing.expect_value(t, bootstrap_memory_applies_agent(global, agent, "user_1", domain.Project_ID("proj_1")), true)

	// Template membership via the agent's template_id.
	tmpl_member := domain.Memory{status = "active", template_ids = []string{"tmpl_1"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(tmpl_member, agent, "user_1", domain.Project_ID("proj_1")), true)
	tmpl_miss := domain.Memory{status = "active", template_ids = []string{"tmpl_9"}}
	testing.expect_value(t, bootstrap_memory_applies_agent(tmpl_miss, agent, "user_1", domain.Project_ID("proj_1")), false)
}
