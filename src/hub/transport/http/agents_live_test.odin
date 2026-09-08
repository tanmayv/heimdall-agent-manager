package http

// Unit tests for the GET /api/v1/agents/live tree builder + JSON serializer.
// build_agents_live_tree is pure (takes already-fetched data), so these lock the
// resolver semantics and wire shape without a DB: empty=all projects always,
// chains filtered to those with >=1 live agent, coordinator/live flags, project
// resolution via the coordinator instance, deterministic ordering, and the
// trailing Unassigned bucket.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// live_test_fixture builds a small owner graph:
//   projects: "Beta" (proj_b), "Alpha" (proj_a)  -> alphabetical => Alpha, Beta
//   chain_a (project proj_a): coordinator inst_coord (running) + inst_worker (running)
//   chain_b (project proj_b): only inst_dead (stopped) => NO live agent => omitted
//   chain_u (no project on coordinator, live worker has proj "" ) => Unassigned
// Returns caller-owned maps; delete via live_test_fixture_free.
live_test_fixture :: proc() -> (projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) {
	projects = make([]domain.Project, 2)
	projects[0] = domain.Project{project_id = "proj_b", name = "Beta"}
	projects[1] = domain.Project{project_id = "proj_a", name = "Alpha"}

	chains = make([]domain.Task_Chain, 3)
	chains[0] = domain.Task_Chain{chain_id = "chain_a", title = "Alpha chain", coordinator_agent_instance_id = "inst_coord"}
	chains[1] = domain.Task_Chain{chain_id = "chain_b", title = "Dead chain", coordinator_agent_instance_id = "inst_dead"}
	chains[2] = domain.Task_Chain{chain_id = "chain_u", title = "Unassigned chain", coordinator_agent_instance_id = "inst_ucoord"}

	members_by_chain = make(map[string][]domain.Task_Chain_Member)
	ma := make([]domain.Task_Chain_Member, 2)
	ma[0] = domain.Task_Chain_Member{chain_id = "chain_a", agent_instance_id = "inst_coord", role = "coordinator"}
	ma[1] = domain.Task_Chain_Member{chain_id = "chain_a", agent_instance_id = "inst_worker", role = "member"}
	members_by_chain["chain_a"] = ma
	mb := make([]domain.Task_Chain_Member, 1)
	mb[0] = domain.Task_Chain_Member{chain_id = "chain_b", agent_instance_id = "inst_dead", role = "coordinator"}
	members_by_chain["chain_b"] = mb
	mu := make([]domain.Task_Chain_Member, 2)
	mu[0] = domain.Task_Chain_Member{chain_id = "chain_u", agent_instance_id = "inst_ucoord", role = "coordinator"}
	mu[1] = domain.Task_Chain_Member{chain_id = "chain_u", agent_instance_id = "inst_ulive", role = "member"}
	members_by_chain["chain_u"] = mu

	instances_by_id = make(map[string]domain.Agent_Instance)
	instances_by_id["inst_coord"] = domain.Agent_Instance{agent_instance_id = "inst_coord", display_name = "Coordinator", project_id = "proj_a", runtime_status = "running", activity_status = "busy"}
	instances_by_id["inst_worker"] = domain.Agent_Instance{agent_instance_id = "inst_worker", display_name = "Worker", project_id = "proj_a", runtime_status = "idle", activity_status = "idle"}
	instances_by_id["inst_dead"] = domain.Agent_Instance{agent_instance_id = "inst_dead", display_name = "Dead", project_id = "proj_b", runtime_status = "stopped"}
	// chain_u: coordinator instance has no project; the live worker also has "".
	instances_by_id["inst_ucoord"] = domain.Agent_Instance{agent_instance_id = "inst_ucoord", display_name = "UCoord", project_id = "", runtime_status = "running"}
	instances_by_id["inst_ulive"] = domain.Agent_Instance{agent_instance_id = "inst_ulive", display_name = "ULive", project_id = "", runtime_status = "running"}
	return
}

live_test_fixture_free :: proc(projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) {
	delete(projects)
	delete(chains)
	mm := members_by_chain
	for _, v in mm do delete(v)
	delete(mm)
	im := instances_by_id
	delete(im)
}

@(test)
agents_live_tree_shape_and_ordering :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)

	// ALL projects present, alphabetical by name, plus trailing Unassigned.
	testing.expect_value(t, len(tree), 3)
	testing.expect_value(t, tree[0].name, "Alpha")
	testing.expect_value(t, tree[1].name, "Beta")
	testing.expect_value(t, tree[2].name, "Unassigned")
	testing.expect_value(t, tree[2].project_id, "")

	// Alpha carries chain_a (has live agents); Beta has none (chain_b omitted).
	testing.expect_value(t, len(tree[0].chains), 1)
	testing.expect_value(t, len(tree[1].chains), 0)
	testing.expect_value(t, len(tree[2].chains), 1)

	ca := tree[0].chains[0]
	testing.expect_value(t, ca.chain_id, "chain_a")
	testing.expect_value(t, ca.coordinator_agent_instance_id, "inst_coord")
	// Two live agents ordered by display_name: Coordinator, Worker.
	testing.expect_value(t, len(ca.live_agents), 2)
	testing.expect_value(t, ca.live_agents[0].display_name, "Coordinator")
	testing.expect_value(t, ca.live_agents[0].is_coordinator, true)
	testing.expect_value(t, ca.live_agents[1].display_name, "Worker")
	testing.expect_value(t, ca.live_agents[1].is_coordinator, false)
	testing.expect_value(t, len(ca.members), 2)
}

@(test)
agents_live_chain_filtered_when_no_live_agent :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	// Beta's only chain (chain_b) has a single stopped member -> omitted entirely.
	for p in tree {
		for c in p.chains {
			testing.expect(t, c.chain_id != "chain_b", "chain with no live agent must be omitted")
		}
	}
}

@(test)
agents_live_members_include_non_live :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	// Add a stopped member to chain_a; it must appear in members (is_live=false)
	// but NOT in live_agents.
	extra := make([]domain.Task_Chain_Member, 3)
	extra[0] = members_by_chain["chain_a"][0]
	extra[1] = members_by_chain["chain_a"][1]
	extra[2] = domain.Task_Chain_Member{chain_id = "chain_a", agent_instance_id = "inst_reviewer", role = "reviewer"}
	delete(members_by_chain["chain_a"])
	members_by_chain["chain_a"] = extra
	instances_by_id["inst_reviewer"] = domain.Agent_Instance{agent_instance_id = "inst_reviewer", display_name = "Reviewer", project_id = "proj_a", runtime_status = "stopped"}

	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	ca := tree[0].chains[0]
	testing.expect_value(t, len(ca.members), 3)
	testing.expect_value(t, len(ca.live_agents), 2)
	found_dead := false
	for m in ca.members {
		if m.agent_instance_id == "inst_reviewer" {
			found_dead = true
			testing.expect_value(t, m.is_live, false)
			testing.expect_value(t, m.role, "reviewer")
		}
	}
	testing.expect(t, found_dead, "non-live member present in members roster")
}

@(test)
agents_live_json_contract :: proc(t: ^testing.T) {
	projects, chains, members_by_chain, instances_by_id := live_test_fixture()
	defer live_test_fixture_free(projects, chains, members_by_chain, instances_by_id)
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	b := strings.builder_make(); defer strings.builder_destroy(&b)
	write_agents_live_json(&b, tree)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "\"projects\":["), "top-level projects array")
	testing.expect(t, strings.contains(out, "\"project_id\":\"proj_a\""), "project_id emitted")
	testing.expect(t, strings.contains(out, "\"name\":\"Alpha\""), "project name emitted")
	testing.expect(t, strings.contains(out, "\"chains\":["), "chains array")
	testing.expect(t, strings.contains(out, "\"coordinator_agent_instance_id\":\"inst_coord\""), "coordinator id emitted")
	testing.expect(t, strings.contains(out, "\"live_agents\":["), "live_agents array")
	testing.expect(t, strings.contains(out, "\"is_coordinator\":true"), "coordinator flag emitted")
	testing.expect(t, strings.contains(out, "\"is_live\":true"), "member is_live emitted")
	testing.expect(t, strings.contains(out, "\"activity_status\":\"busy\""), "activity_status emitted")
	// Alphabetical: Alpha's project object precedes Beta's.
	testing.expect(t, strings.index(out, "\"name\":\"Alpha\"") < strings.index(out, "\"name\":\"Beta\""), "projects alphabetical")
}
