package http

import "core:slice"
import "core:strings"
import "core:encoding/json"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

// GET /api/v1/agents/live. Chains are Bridge-owned: the Hub keeps no chain
// rows or rosters, so the chain groups are derived from the instances
// themselves (agent_instances.chain_id). Every instance bound to a chain is a
// member of that chain's group; the title is left to the client.
Agents_Live_Handlers :: struct {
	auth:     ^auth_service.Auth_Service,
	agents:   ^agent_service.Agent_Service,
	projects: ^project_service.Project_Service,
}

JSON_MARSHAL_OPT :: json.Marshal_Options{
	sort_maps_by_key = true,
}

Agents_Live_Response_Wire :: struct {
	projects: []Agents_Live_Project `json:"projects"`,
}

// ---- GET /api/v1/agents/live : project -> live-chains -> agents tree ---------
// One call that powers the sidebar rail. It returns EVERY project (alphabetical
// by name, even with nothing live), and a chain is listed under a project when
// the chain has any member (live or dead) in that project AND the chain has >=1
// RUNNING agent somewhere (chains with no running agent are omitted). Per project
// entry: live_agents = that project's running agents (may be empty for a
// dead-only project); members = the full chain roster (live or not). Each agent
// and member carries its own project_id. "live" mirrors the agent-instance live
// filter (agent_service.runtime_expected_active). Field names/casing reuse the
// existing project / chain-member wire contracts.
Agents_Live_Agent :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	display_name:      string `json:"display_name"`,
	is_coordinator:    bool   `json:"is_coordinator"`,
	runtime_status:    string `json:"runtime_status"`,
	activity_status:   string `json:"activity_status"`,
	project_id:        string `json:"project_id"`,
	created_at:        string `json:"created_at"`,
}

Agents_Live_Member :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	display_name:      string `json:"display_name"`,
	role:              string `json:"role"`,
	is_coordinator:    bool   `json:"is_coordinator"`,
	is_live:           bool   `json:"is_live"`,
	runtime_status:    string `json:"runtime_status"`,
	project_id:        string `json:"project_id"`,
	created_at:        string `json:"created_at"`,
}

Agents_Live_Chain :: struct {
	chain_id:                      string               `json:"chain_id"`,
	title:                         string               `json:"title"`,
	coordinator_agent_instance_id: string               `json:"coordinator_agent_instance_id"`,
	live_agents:                   []Agents_Live_Agent  `json:"live_agents"`,
	members:                       []Agents_Live_Member `json:"members"`,
	// group_created_at is the per-project ordering key: MIN(created_at) across this
	// chain's members that belong to THIS project (live AND dead). Not serialized;
	// used only to order chain groups within a project. Empty sorts last.
	group_created_at:              string               `json:"-"`,
}

Agents_Live_Project :: struct {
	project_id: string              `json:"project_id"`,
	name:       string              `json:"name"`,
	chains:     []Agents_Live_Chain `json:"chains"`,
}

// Deterministic orderings (user-finalized): chain GROUPS within a project by the
// group's earliest member creation time (empty created_at sorts LAST), tie-break
// chain_id; agents/members oldest-first by created_at, tie-break instance id.
agents_live_created_at_less :: proc(a_created, a_id, b_created, b_id: string) -> bool {
	if a_created != b_created {
		// Empty created_at (unknown) sorts after any known timestamp.
		if a_created == "" do return false
		if b_created == "" do return true
		return a_created < b_created
	}
	return a_id < b_id
}
agents_live_chain_less :: proc(a, b: Agents_Live_Chain) -> bool {
	return agents_live_created_at_less(a.group_created_at, a.chain_id, b.group_created_at, b.chain_id)
}
agents_live_agent_less :: proc(a, b: Agents_Live_Agent) -> bool {
	return agents_live_created_at_less(a.created_at, a.agent_instance_id, b.created_at, b.agent_instance_id)
}
agents_live_member_less :: proc(a, b: Agents_Live_Member) -> bool {
	return agents_live_created_at_less(a.created_at, a.agent_instance_id, b.created_at, b.agent_instance_id)
}

// build_agents_live_tree assembles the projects->live-chains->agents tree from
// already-fetched data. It is kept pure (no services) so it is unit-testable
// without a DB. Inputs:
//   projects          all of the owner's projects
//   chains            all of the owner's chains
//   members_by_chain  chain_id -> its canonical member roster (incl. non-live)
//   instances_by_id   agent_instance_id -> instance (liveness + project + labels)
// Cross-project (Option A): a chain is emitted under EVERY project that has >=1
// of its LIVE agents, and under a given project its live_agents are scoped to
// THAT project's live agents only. members[] on every entry is the FULL chain
// roster (all projects, live + non-live), each carrying its own project_id. A
// chain with no live agent anywhere is omitted. Projects are alphabetical by
// name; a trailing "Unassigned" bucket (project_id "") holds live agents whose
// instance has no resolvable project. String fields are VIEWS into the inputs;
// the JSON serializer copies them out. The returned tree is caller-owned — free
// it with free_agents_live_tree.
build_agents_live_tree :: proc(projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) -> []Agents_Live_Project {
	// Per-project buckets of chain entries. Each (chain, project) entry owns fresh
	// live_agents/members slices, so a chain appearing under multiple projects
	// never shares (and thus never double-frees) backing arrays.
	chains_by_project := make(map[string][dynamic]Agents_Live_Chain)
	defer { for _, bkt in chains_by_project do delete(bkt); delete(chains_by_project) }

	for chain in chains {
		members := members_by_chain[string(chain.chain_id)] or_else nil
		// Canonical coordinator (H9): the earliest member with role "coordinator";
		// members come ordered by created_at ASC. Fall back to the derived mirror.
		coordinator_id := chain.coordinator_agent_instance_id
		for m in members {
			if m.role == "coordinator" { coordinator_id = m.agent_instance_id; break }
		}
		// Full roster (members[]), built once and copied into each project entry.
		roster_src := make([dynamic]Agents_Live_Member); defer delete(roster_src)
		// Running agents grouped by their instance.project_id, plus the set of
		// DISTINCT project_ids across ALL members (live+dead) — that set decides which
		// projects the chain is emitted under (placement is member-based, not
		// live-agent-based). has_live gates inclusion: a chain with no running agent
		// anywhere is omitted entirely.
		live_by_project := make(map[string][dynamic]Agents_Live_Agent)
		defer { for _, bkt in live_by_project do delete(bkt); delete(live_by_project) }
		member_project_ids := make(map[string]bool); defer delete(member_project_ids)
		has_live := false
		for m in members {
			inst, has_inst := instances_by_id[m.agent_instance_id]
			live := has_inst && agent_service.runtime_expected_active(inst.runtime_status)
			is_coord := m.agent_instance_id == coordinator_id
			pid := string(inst.project_id) if has_inst else ""
			created_at := inst.created_at if has_inst else ""
			append(&roster_src, Agents_Live_Member{
				agent_instance_id = m.agent_instance_id,
				display_name = inst.display_name if has_inst else "",
				role = m.role,
				is_coordinator = is_coord,
				is_live = live,
				runtime_status = inst.runtime_status if has_inst else "",
				project_id = pid,
				created_at = created_at,
			})
			member_project_ids[pid] = true
			if live {
				has_live = true
				if pid not_in live_by_project do live_by_project[pid] = make([dynamic]Agents_Live_Agent)
				append(&live_by_project[pid], Agents_Live_Agent{
					agent_instance_id = m.agent_instance_id,
					display_name = inst.display_name,
					is_coordinator = is_coord,
					runtime_status = inst.runtime_status,
					activity_status = inst.activity_status,
					project_id = pid,
					created_at = created_at,
				})
			}
		}
		if !has_live do continue // no RUNNING agent anywhere -> omit the chain
		slice.sort_by(roster_src[:], agents_live_member_less)

		// One entry per project that has ANY member (live or dead) of this chain.
		// live_agents is scoped to that project's running agents (may be EMPTY for a
		// dead-only project); members[] is the full (copied) roster. Output order is
		// made deterministic by the project + per-project chain sorts below, so the
		// map iteration order here does not leak.
		for pid in member_project_ids {
			live_dyn, has_here := live_by_project[pid]
			n := len(live_dyn) if has_here else 0
			live_agents := make([]Agents_Live_Agent, n)
			if has_here {
				for a, i in live_dyn do live_agents[i] = a
			}
			slice.sort_by(live_agents, agents_live_agent_less)
			members_copy := make([]Agents_Live_Member, len(roster_src))
			for m, i in roster_src do members_copy[i] = m
			// Group ordering key: earliest created_at among THIS project's members
			// (live or dead). Empty timestamps are ignored unless none are known.
			group_created_at := ""
			for m in roster_src {
				if m.project_id != pid || m.created_at == "" do continue
				if group_created_at == "" || m.created_at < group_created_at do group_created_at = m.created_at
			}
			if pid not_in chains_by_project do chains_by_project[pid] = make([dynamic]Agents_Live_Chain)
			append(&chains_by_project[pid], Agents_Live_Chain{
				chain_id = string(chain.chain_id),
				title = chain.title,
				coordinator_agent_instance_id = coordinator_id,
				live_agents = live_agents,
				members = members_copy,
				group_created_at = group_created_at,
			})
		}
	}

	// Emit ALL projects alphabetically, attaching their live chains; then a
	//    trailing "Unassigned" bucket for live chains with no known project.
	out := make([dynamic]Agents_Live_Project)
	sorted_projects := make([]domain.Project, len(projects)); defer delete(sorted_projects)
	for p, i in projects do sorted_projects[i] = p
	slice.sort_by(sorted_projects, proc(a, b: domain.Project) -> bool {
		if a.name != b.name do return a.name < b.name
		return string(a.project_id) < string(b.project_id)
	})
	matched := make(map[string]bool); defer delete(matched)
	for p in sorted_projects {
		pid := string(p.project_id)
		matched[pid] = true
		bucket := chains_by_project[pid] or_else nil
		if p.state == .Archived {
			for lc in bucket {
				delete(lc.live_agents)
				delete(lc.members)
			}
			continue
		}
		append(&out, Agents_Live_Project{ project_id = pid, name = p.name, chains = agents_live_copy_sorted_chains(bucket[:]) })
	}
	unassigned := make([dynamic]Agents_Live_Chain); defer delete(unassigned)
	for pid, bucket in chains_by_project {
		if matched[pid] do continue
		for lc in bucket do append(&unassigned, lc)
	}
	if len(unassigned) > 0 {
		append(&out, Agents_Live_Project{ project_id = "", name = "Unassigned", chains = agents_live_copy_sorted_chains(unassigned[:]) })
	}
	return out[:]
}

// agents_live_copy_sorted_chains copies a bucket into a fresh owned slice sorted
// by agents_live_chain_less. The copied structs reference the per-entry
// live_agents/members arrays. Ownership stays single: the builder allocates fresh
// live_agents/members for EACH (chain, project) entry, so even a cross-project
// chain (present in multiple buckets) never shares backing arrays across entries.
agents_live_copy_sorted_chains :: proc(bucket: []Agents_Live_Chain) -> []Agents_Live_Chain {
	out := make([]Agents_Live_Chain, len(bucket))
	for c, i in bucket do out[i] = c
	slice.sort_by(out, agents_live_chain_less)
	return out
}

free_agents_live_tree :: proc(tree: []Agents_Live_Project) {
	for p in tree {
		for c in p.chains {
			delete(c.live_agents)
			delete(c.members)
		}
		delete(p.chains)
	}
	delete(tree)
}

write_agents_live_json :: proc(b: ^strings.Builder, tree: []Agents_Live_Project) {
	resp := Agents_Live_Response_Wire{projects = tree}
	data, _ := json.marshal(resp, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

// agents_live_handler serves GET /api/v1/agents/live. It gathers the owner's
// instances (labels + liveness + project in one query), chains, and projects,
// fetches members only for chains that actually have a live instance (bounded),
// then builds + serializes the tree.
agents_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agents_Live_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	instances, inst_err := agent_service.list_instances(h.agents, auth_ctx, 2000)
	if inst_err.code != .None do return respond_error(inst_err, req.request_id)
	instances_by_id := make(map[string]domain.Agent_Instance); defer delete(instances_by_id)
	members_by_chain := make(map[string][]domain.Task_Chain_Member)
	defer { for _, v in members_by_chain do delete(v); delete(members_by_chain) }
	grouped := make(map[string][dynamic]domain.Task_Chain_Member)
	defer { for _, v in grouped do delete(v); delete(grouped) }
	chains := make([dynamic]domain.Task_Chain); defer delete(chains)
	for inst in instances {
		instances_by_id[inst.agent_instance_id] = inst
		if inst.chain_id == "" do continue
		if inst.chain_id not_in grouped {
			grouped[inst.chain_id] = make([dynamic]domain.Task_Chain_Member)
			append(&chains, domain.Task_Chain{chain_id = domain.Task_Chain_ID(inst.chain_id)})
		}
		append(&grouped[inst.chain_id], domain.Task_Chain_Member{agent_instance_id = inst.agent_instance_id, role = "member"})
	}
	for chain_id, members in grouped do members_by_chain[chain_id] = slice.clone(members[:])
	projects: []domain.Project
	if h.projects != nil {
		ps, perr := project_service.list(h.projects, auth_ctx, 500)
		if perr.code != .None do return respond_error(perr, req.request_id)
		projects = ps
	}
	tree := build_agents_live_tree(projects, chains[:], members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	b := strings.builder_make(); write_agents_live_json(&b, tree)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}
