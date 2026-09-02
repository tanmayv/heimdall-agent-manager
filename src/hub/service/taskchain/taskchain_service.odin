package taskchain

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

Nudge_Target :: enum {
	None,
	Assignee,
	Reviewer,
	Coordinator,
}

Manual_Nudge :: struct {
	task_id: domain.Task_ID,
	owner_user_id: domain.User_ID,
	target: Nudge_Target,
	message: string,
	created_at: string,
	nudge_id: string,
	delivery_state: string,
	live_delivered: int,
	durable_queued: int,
	failed: int,
	targets_json: string,
}

Taskchain_Service :: struct {
	repo: ^iface.Taskchain_Repository,
	agents: ^iface.Agent_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	nudges: [dynamic]Manual_Nudge,
	bridge_command_sink: project.Bridge_Command_Sink,
	// replay_last_unix_ms throttles orphan-recovery replays per bridge so a
	// flapping bridge (rapid reconnects) does not re-fan-out the whole actionable
	// set on every connect. Guarded by replay_mutex.
	replay_mutex: sync.Mutex,
	replay_last_unix_ms: map[string]i64,
}

Create_Chain_Input :: struct {
	title: string,
	description: string,
	owner_user_id: string,
	kind: string,
	coordinator_agent_id: string,
	default_reviewer_refs_json: string,
}

Update_Chain_Input :: struct {
	title: string,
	description: string,
	status: string,
	// coordinator_agent_instance_id sets/changes the chain's designated coordinator
	// after creation (H5 finding: chains created via a user token had an empty
	// coordinator and PATCH could not set one). has_coordinator distinguishes
	// "absent" from "explicitly clear". The target must belong to the same chain.
	coordinator_agent_instance_id: string,
	has_coordinator: bool,
	// title_source records who set the title ("default"|"agent"|"user"). When an
	// agent or user explicitly renames the chain we stamp this so the activity-
	// gated title-nudge engine (T2) stops nudging. Empty = leave unchanged.
	title_source: string,
}

Create_Task_Input :: struct {
	chain_id: domain.Task_Chain_ID,
	title: string,
	description: string,
	owner_user_id: string,
	assignee_ref_json: string,
	reviewer_refs_json: string,
	depends_on: []domain.Task_ID,
}

Update_Task_Input :: struct {
	title: string,
	description: string,
	assignee_ref_json: string,
	reviewer_refs_json: string,
	// priority sets the task priority (P0/P1/P2). has_priority distinguishes an
	// explicit change from "field absent" so a PATCH that omits priority leaves it
	// untouched. A priority change re-orders the auto-promotion selection.
	priority: domain.Task_Priority,
	has_priority: bool,
	depends_on: []domain.Task_ID,
	has_depends_on: bool,
}

Task_Comment_Input :: struct {
	task_id: domain.Task_ID,
	body: string,
}

Comment_Input :: struct {
	task_id: domain.Task_ID,
	body: string,
}

Vote_Input :: struct {
	task_id: domain.Task_ID,
	vote: string, // "lgtm" or "ngtm"
	comment: string,
}

new_taskchain_service :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Taskchain_Service {
	return Taskchain_Service{repo = repo, agents = agents, clock = clock, ids = ids, nudges = make([dynamic]Manual_Nudge)}
}

new_taskchain_service_with_runtime :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, bridge_command_sink: project.Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Taskchain_Service {
	return Taskchain_Service{repo = repo, agents = agents, clock = clock, ids = ids, nudges = make([dynamic]Manual_Nudge), bridge_command_sink = bridge_command_sink}
}

// is_instance_member_or_coordinator: membership OR coordinator authority, read
// from the SINGLE canonical source (H9) — the task_chain_members table. The
// coordinator is just a member whose role is "coordinator"; both notions live in
// one table, so there is no dual-source drift.
is_instance_member_or_coordinator :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members {
		if m.agent_instance_id == instance_id do return true
	}
	return false
}

// is_chain_coordinator (H9): the SINGLE canonical source of who coordinates a
// chain is the task_chain_members table (a member with role == "coordinator").
// The task_chains.coordinator_agent_instance_id column is now only a DERIVED
// MIRROR kept for API/UI back-compat (stamped by coordinator_sync_mirror on
// write) and is NEVER consulted for authority here. This removes the dual-source
// drift where an empty column + a coordinator member locked the real coordinator
// out. Because it reads the members table, one agent can coordinate multiple
// chains and multiple agents could hold the coordinator role on a chain.
is_chain_coordinator :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members {
		if m.agent_instance_id == instance_id && m.role == "coordinator" do return true
	}
	return false
}

// coordinator_primary_instance returns the current coordinator instance id from
// the canonical members table (the earliest-created coordinator member if more
// than one holds the role), or "" if the chain has no coordinator member. Used to
// stamp the derived mirror column and to serialize coordinator identity.
coordinator_primary_instance :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> string {
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain_id, owner)
	if err.code != .None do return ""
	// list_members_by_chain is ordered by created_at ASC, so the first coordinator
	// encountered is the earliest-designated one.
	for m in members {
		if m.role == "coordinator" do return m.agent_instance_id
	}
	return ""
}

// coordinator_sync_mirror recomputes the derived coordinator_agent_instance_id
// mirror column from the canonical members table and persists the chain if it
// changed. Call after any coordinator-member mutation so the back-compat column
// always reflects the single source (never independently authoritative).
coordinator_sync_mirror :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain) -> domain.Task_Chain {
	primary := coordinator_primary_instance(service, chain.chain_id, chain.owner_user_id)
	if chain.coordinator_agent_instance_id == primary do return chain
	updated := chain
	updated.coordinator_agent_instance_id = primary
	saved, ok, _ := iface.taskchain_save_chain(service.repo, updated)
	if ok do return saved
	return updated
}

// set_chain_coordinator changes the coordinator via the canonical members table:
// demote any existing coordinator member(s) to "member", upsert the target as a
// "coordinator" member, then sync the derived mirror. An empty target clears the
// coordinator (all coordinators demoted). Returns the chain with the mirror
// stamped. Same-chain/same-owner validation of a non-empty target is the caller's
// responsibility (mirrors the existing agent_instance_same_chain check).
set_chain_coordinator :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, target_instance_id: string) -> domain.Task_Chain {
	now := platform.clock_now(service.clock)
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code == .None {
		for m in members {
			if m.role == "coordinator" && m.agent_instance_id != target_instance_id {
				demoted := m
				demoted.role = "member"
				iface.taskchain_save_member(service.repo, demoted)
			}
		}
	}
	if target_instance_id != "" {
		coordinator := domain.Task_Chain_Member{
			chain_id = chain.chain_id,
			agent_instance_id = target_instance_id,
			owner_user_id = chain.owner_user_id,
			role = "coordinator",
			created_at = now,
		}
		iface.taskchain_save_member(service.repo, coordinator)
	}
	return coordinator_sync_mirror(service, chain)
}

list_chains :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context) -> ([]domain.Task_Chain, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	chains, list_err := iface.taskchain_list_chains_by_owner(service.repo, owner)
	if list_err.code != .None do return nil, list_err
	if auth.kind == .Instance_Token {
		filtered := make([dynamic]domain.Task_Chain)
		for c in chains {
			if is_instance_member_or_coordinator(service, c, auth.agent_instance_id) {
				append(&filtered, c)
			}
		}
		return filtered[:], domain.Domain_Error{}
	}
	return chains, domain.Domain_Error{}
}

// list_chains_coordinated_by (H9 R4): the chains an agent instance coordinates,
// from the single canonical source (members table, role='coordinator'). When the
// caller is an Instance_Token and no explicit target is given, defaults to the
// caller's own instance. Owner-scoped: an instance token can only ever see its
// own owner's chains.
list_chains_coordinated_by :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, agent_instance_id: string) -> ([]domain.Task_Chain, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	target := agent_instance_id
	if target == "" && auth.kind == .Instance_Token do target = auth.agent_instance_id
	if target == "" do return nil, domain.domain_error(.Validation_Failed, "agent_instance_id is required")
	return iface.taskchain_list_chains_by_coordinator(service.repo, target, owner)
}

get_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
	if auth.kind == .Instance_Token {
		if !is_instance_member_or_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "agent instance is not a member or coordinator of this chain")
		}
	}
	return chain, true, domain.Domain_Error{}
}

list_tasks :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

create_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Create_Chain_Input) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Task_Chain{}, false, err
	if input.title == "" do return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "chain title is required")
	now := platform.clock_now(service.clock)
	kind := input.kind; if kind == "" do kind = "team_work"
	default_reviewers := input.default_reviewer_refs_json; if default_reviewers == "" do default_reviewers = "[]"
	coordinator_id := input.coordinator_agent_id
	if auth.kind == .Instance_Token && coordinator_id == "" {
		coordinator_id = auth.agent_instance_id
	}
	chain := domain.Task_Chain{
		chain_id = domain.Task_Chain_ID(platform.generate_id(service.ids, "chain_")),
		owner_user_id = owner,
		title = input.title,
		description = input.description,
		publish_state = .Draft,
		status = .Active,
		kind = kind,
		// coordinator_agent_instance_id is a DERIVED MIRROR (H9): it is stamped from
		// the canonical members table below, never set as an independent authority.
		coordinator_agent_instance_id = "",
		default_reviewer_refs_json = default_reviewers,
		created_at = now,
		updated_at = now,
	}
	saved_chain, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	if !save_ok do return domain.Task_Chain{}, false, save_err

	// Write the coordinator to the SINGLE canonical source (members table), then
	// stamp the derived mirror column. An instance creator defaults to coordinator;
	// a user-token creator may name one via coordinator_agent_id.
	if coordinator_id != "" {
		member := domain.Task_Chain_Member{
			chain_id = saved_chain.chain_id,
			agent_instance_id = coordinator_id,
			owner_user_id = owner,
			role = "coordinator",
			created_at = now,
		}
		iface.taskchain_save_member(service.repo, member)
		saved_chain = coordinator_sync_mirror(service, saved_chain)
	}

	return saved_chain, true, domain.Domain_Error{}
}

update_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, input: Update_Chain_Input) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if input.title != "" do chain.title = input.title
	if input.title_source == "agent" || input.title_source == "user" || input.title_source == "default" do chain.title_source = input.title_source
	if input.description != "" do chain.description = input.description
	if input.has_coordinator {
		// Setting/changing the coordinator goes through the SINGLE canonical source
		// (members table) via set_chain_coordinator; the column is only the derived
		// mirror. A non-empty target must belong to this chain (same-owner+membership).
		if input.coordinator_agent_instance_id != "" {
			if same, same_err := agent_instance_same_chain(service, input.coordinator_agent_instance_id, chain); !same do return domain.Task_Chain{}, false, same_err
		}
		chain = set_chain_coordinator(service, chain, input.coordinator_agent_instance_id)
	}
	if input.status != "" {
		st := chain_status_from_string(input.status)
		if st != chain.status {
			if !valid_chain_transition(chain.status, st) do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "invalid chain status transition")
			chain.status = st
			if st == .Completed || st == .Cancelled {
				chain.completed_at = platform.clock_now(service.clock)
			} else if st == .Active {
				// Reopening clears the terminal completion timestamp.
				chain.completed_at = ""
			}
		}
	}
	chain.updated_at = platform.clock_now(service.clock)
	return iface.taskchain_save_chain(service.repo, chain)
}

// set_own_chain_title lets an authenticated agent instance rename the chain it
// belongs to (T3/REQ-3), stamping title_source="agent" so the activity-gated
// nudge engine (T2) stops nudging. The instance must be the chain coordinator
// (enforced by update_chain for instance tokens); for a private-conversation
// chain the instance is its own coordinator.
set_own_chain_title :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id, title: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "instance token is required")
	next := strings.trim_space(title)
	if next == "" do return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "chain title is required")
	if len(next) > 120 do return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "chain title is too long")
	return update_chain(service, auth, domain.Task_Chain_ID(chain_id), Update_Chain_Input{title = next, title_source = "agent"})
}

publish_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if chain.publish_state != .Draft do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "chain is already published")
	now := platform.clock_now(service.clock)
	chain.publish_state = .Published
	chain.status = .Active
	chain.published_at = now
	chain.updated_at = now
	saved_chain, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	if !save_ok do return domain.Task_Chain{}, false, save_err

	tasks, err_t := iface.taskchain_list_tasks_by_chain(service.repo, chain_id, chain.owner_user_id)
	if err_t.code == .None {
		for t in tasks {
			t_copy := t
			t_copy.publish_state = .Published
			if t_copy.published_at == "" do t_copy.published_at = now
			t_copy.updated_at = now
			_, _, _ = iface.taskchain_save_task(service.repo, t_copy)
		}
	}
	// Auto-promotion on publish: any task with satisfied deps and a free assignee
	// auto-claims into In_Progress so a manual refresh shows the work as started.
	_ = recompute_chain_promotions(service, saved_chain)
	return saved_chain, true, domain.Domain_Error{}
}

change_chain_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, next: domain.Task_Chain_Status) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if chain.publish_state != .Published do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "draft chain has no execution status")
	if !valid_chain_transition(chain.status, next) do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "invalid chain status transition")
	now := platform.clock_now(service.clock)
	chain.status = next
	chain.updated_at = now
	if next == .Completed || next == .Cancelled {
		chain.completed_at = now
	} else if next == .Active {
		chain.completed_at = ""
	}
	return iface.taskchain_save_chain(service.repo, chain)
}

valid_chain_transition :: proc(current, next: domain.Task_Chain_Status) -> bool {
	if current == next do return true
	switch current {
	case .Active: return next == .Completed || next == .Cancelled
	// Recovery path: a completed chain can be reopened to Active by its
	// coordinator so an accidental completion is not permanently terminal.
	// Cancelled remains terminal.
	case .Completed: return next == .Active
	case .Cancelled: return false
	}
	return false
}

create_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Create_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, input.chain_id)
	if !ok do return domain.Task{}, false, err
	requested_owner := domain.User_ID(input.owner_user_id)
	if requested_owner == "" do requested_owner = chain.owner_user_id
	if same_ok, same_err := ownership.require_same_owner(chain.owner_user_id, requested_owner); !same_ok do return domain.Task{}, false, same_err
	if input.title == "" do return domain.Task{}, false, domain.domain_error(.Validation_Failed, "task title is required")
	assignee_ref := input.assignee_ref_json
	if assignee_ref == "" && chain.coordinator_agent_instance_id != "" do assignee_ref = agent_instance_ref_json(chain.coordinator_agent_instance_id)
	if assignee_ref == "" do assignee_ref = user_ref_json(string(chain.owner_user_id))
	reviewer_refs := input.reviewer_refs_json
	if reviewer_refs == "" do reviewer_refs = chain.default_reviewer_refs_json
	if reviewer_refs == "" do reviewer_refs = "[]"
	// Resolve any durable agent_id refs into concrete agent_instance refs (reuse or,
	// in Phase 2, launch) before validation so callers can assign/review by agent_id.
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, assignee_ref); norm_ok { assignee_ref = norm } else { return domain.Task{}, false, norm_err }
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, reviewer_refs); norm_ok { reviewer_refs = norm } else { return domain.Task{}, false, norm_err }
	if refs_ok, refs_err := validate_actor_refs(service, chain, assignee_ref, reviewer_refs); !refs_ok do return domain.Task{}, false, refs_err
	now := platform.clock_now(service.clock)
	task := domain.Task{
		task_id = domain.Task_ID(platform.generate_id(service.ids, "task_")),
		chain_id = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		title = input.title,
		description = input.description,
		publish_state = chain.publish_state,
		status = .Assigned,
		// Tasks default to the lowest priority (P2) unless explicitly escalated.
		priority = .P2,
		assignee_ref_json = assignee_ref,
		reviewer_refs_json = reviewer_refs,
		created_at = now,
		updated_at = now,
	}
	saved_task, save_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if !save_ok do return domain.Task{}, false, save_err

	for dep_id in input.depends_on {
		if _, dep_ok, dep_err := add_task_dependency(service, auth, saved_task.task_id, dep_id); !dep_ok {
			return domain.Task{}, false, dep_err
		}
	}

	// Reconcile current_task pointers: a new Published+Assigned task on an active
	// chain is immediately actionable, so recompute keeps the persisted pointer
	// authoritative (the Phase-3 gate depends on it) and lets a higher-priority
	// new task preempt a busy assignee per Phase-2 ordering.
	_ = recompute_promotions_for_chain_id(service, chain.chain_id)

	return saved_task, true, domain.Domain_Error{}
}

update_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Update_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err

	if auth.kind == .Instance_Token {
		is_coord := is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_assignee := strings.contains(task.assignee_ref_json, auth.agent_instance_id)
		if !is_coord && !is_assignee {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only assignee or coordinator can update task")
		}
	}

	// Remember the prior assignee so a reassign-away can clear that instance's
	// current_task pointer if it no longer holds the task (CT-7 consistency).
	prev_assignee := primary_assignee_instance(task.assignee_ref_json)
	defer delete(prev_assignee)

	if input.title != "" do task.title = input.title
	if input.description != "" do task.description = input.description
	if input.assignee_ref_json != "" do task.assignee_ref_json = input.assignee_ref_json
	if input.reviewer_refs_json != "" do task.reviewer_refs_json = input.reviewer_refs_json
	if input.has_priority do task.priority = input.priority

	// Resolve durable agent_id refs into concrete agent_instance refs before validation.
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, task.assignee_ref_json); norm_ok { task.assignee_ref_json = norm } else { return domain.Task{}, false, norm_err }
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, task.reviewer_refs_json); norm_ok { task.reviewer_refs_json = norm } else { return domain.Task{}, false, norm_err }
	if refs_ok, refs_err := validate_actor_refs(service, chain, task.assignee_ref_json, task.reviewer_refs_json); !refs_ok do return domain.Task{}, false, refs_err
	task.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if !save_ok do return domain.Task{}, false, save_err

	// CT-7: if the assignee changed, the previous assignee may have been focused on
	// this task. If its stale current_task now points at a task it no longer owns,
	// clear it; the chain recompute below re-selects a focus for everyone still
	// referenced (including the new assignee).
	new_assignee := primary_assignee_instance(saved.assignee_ref_json)
	defer delete(new_assignee)
	if prev_assignee != "" && prev_assignee != new_assignee && service.agents != nil {
		if inst, inst_ok, _ := iface.agent_get_instance(service.agents, prev_assignee); inst_ok {
			if inst.current_task_id == string(saved.task_id) do clear_instance_current_task(service, prev_assignee)
		}
	}

	if input.has_depends_on {
		// clear existing deps and add new ones
		existing_deps, _ := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		for ed in existing_deps {
			if ed.task_id == task.task_id {
				iface.taskchain_remove_dependency(service.repo, task.task_id, ed.depends_on_task_id, chain.owner_user_id)
			}
		}
		for dep_id in input.depends_on {
			if _, dep_ok, dep_err := add_task_dependency(service, auth, task.task_id, dep_id); !dep_ok {
				return domain.Task{}, false, dep_err
			}
		}
	}

	// Reconcile current-task focus after any assignee/reviewer/dependency change.
	_ = recompute_promotions_for_chain_id(service, chain.chain_id)

	return saved, true, domain.Domain_Error{}
}

publish_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err
	if chain.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "cannot publish task before chain is published")
	if task.publish_state != .Draft do return domain.Task{}, false, domain.domain_error(.Conflict, "task is already published")
	if auth.kind == .Instance_Token {
		is_coord := is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_assignee := strings.contains(task.assignee_ref_json, auth.agent_instance_id)
		if !is_coord && !is_assignee {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only assignee or coordinator can publish task")
		}
	}
	now := platform.clock_now(service.clock)
	task.publish_state = .Published
	task.status = .Assigned
	task.published_at = now
	task.updated_at = now
	saved, save_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if !save_ok do return domain.Task{}, false, save_err
	// A freshly-published task is immediately actionable; reconcile pointers so the
	// gate stays authoritative and the assignee is surfaced/preempted correctly.
	_ = recompute_promotions_for_chain_id(service, chain.chain_id)
	return saved, true, domain.Domain_Error{}
}

change_task_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, next: domain.Task_Status) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if task.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "draft task has no execution status")
	if !valid_task_transition(task.status, next) do return domain.Task{}, false, domain.domain_error(.Conflict, "invalid task status transition")

	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err
	if auth.kind == .Instance_Token {
		is_coord := is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_assignee := strings.contains(task.assignee_ref_json, auth.agent_instance_id)
		if !is_coord && !is_assignee {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only assignee or coordinator can change task status")
		}
	}

	// Dependency Gating: reject transition to In_Progress if any dependency is blocked
	if next == .In_Progress {
		deps, dep_err := iface.taskchain_list_dependencies_by_chain(service.repo, task.chain_id, task.owner_user_id)
		if dep_err.code == .None {
			for dep in deps {
				if dep.task_id == task.task_id {
					parent_task, p_ok, _ := iface.taskchain_get_task(service.repo, dep.depends_on_task_id)
					if p_ok {
						if !domain.task_status_unblocks_dependents(parent_task.status) {
							return domain.Task{}, false, domain.domain_error(.Conflict, "task is blocked by dependencies")
						}
					}
				}
			}
		}
	}

	now := platform.clock_now(service.clock)
	task.status = next
	task.updated_at = now
	if next == .In_Progress && task.started_at == "" do task.started_at = now
	if next == .Completed || next == .Cancelled do task.completed_at = now
	task_ret, saved_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if saved_ok {
		// Auto-promotion + auto-advance (CT-4/CT-5) runs FIRST so every instance's
		// persisted current_task pointer is up to date before we notify: a terminal
		// transition unblocks dependents, entering/leaving In_Progress frees or
		// claims the work slot, and entering In_Validation makes the task a review
		// focus for its reviewers. recompute persists focus + wakes any newly
		// promoted assignees. Then the gated status-change notify (CT-6) wakes only
		// the recipients whose current_task is THIS task, with the correct action
		// label (R8). Ordering matters: gating reads the persisted pointer.
		_ = recompute_chain_promotions(service, chain)
		notify_task_status_change(service, auth, task_ret, chain)
	}
	return task_ret, saved_ok, save_err
}

notify_task_status_change :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task: domain.Task, chain: domain.Task_Chain) {
	if service.bridge_command_sink.send_runtime_command == nil do return
	actor_agent_instance_id := auth.agent_instance_id if auth.kind == .Instance_Token else ""

	// CT-6 gating: the bridge derives its wake targets from the assignee/reviewer
	// id arrays by status. We gate those arrays here through the recipient's
	// persisted current_task so only instances whose current task is THIS task are
	// woken (fail-open when the pointer is unset/unknown). The explicit "action"
	// field states work-vs-review per R8 for unambiguous messaging.
	all_assignees := extract_instances_from_ref_blob(task.assignee_ref_json)
	defer delete(all_assignees)
	all_reviewers := extract_instances_from_ref_blob(task.reviewer_refs_json)
	defer delete(all_reviewers)
	all_def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
	defer delete(all_def_reviewers)

	assignees := make([dynamic]string)
	defer delete(assignees)
	for id in all_assignees { if allowed, _ := notification_allowed_for_recipient(service, id, task); allowed do append(&assignees, id) }
	reviewers := make([dynamic]string)
	defer delete(reviewers)
	for id in all_reviewers { if allowed, _ := notification_allowed_for_recipient(service, id, task); allowed do append(&reviewers, id) }
	def_reviewers := make([dynamic]string)
	defer delete(def_reviewers)
	for id in all_def_reviewers { if allowed, _ := notification_allowed_for_recipient(service, id, task); allowed do append(&def_reviewers, id) }

	action := action_for_status(task.status)
	// R8: never fire a wake with an empty action — those statuses (assigned/queued/
	// paused/validated_good/terminal) do not wake anyone here, so a notify would
	// carry no actionable meaning. The status change still persists + recomputes;
	// this only suppresses a meaningless wake command.
	if action == "" do return
	message := status_notify_message(task, action)
	defer delete(message)

	// Bridges to notify: the union of gated recipients' bridges plus the
	// coordinator's (kept for cross-bridge fan-out parity). A bridge that ends up
	// with no gated local target simply wakes no one — harmless.
	instance_ids := make([dynamic]string)
	defer delete(instance_ids)
	if chain.coordinator_agent_instance_id != "" do append(&instance_ids, chain.coordinator_agent_instance_id)
	for id in assignees do append(&instance_ids, id)
	for id in reviewers do append(&instance_ids, id)
	for id in def_reviewers do append(&instance_ids, id)

	bridge_ids := make(map[string]bool)
	defer delete(bridge_ids)
	for id in instance_ids {
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, id)
		if inst_ok && inst.bridge_id != "" do bridge_ids[inst.bridge_id] = true
	}

	for bridge_id in bridge_ids {
		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		strings.write_string(&b, `{"type":"task_status_changed_notify","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","task_id":"`)
		contracts.write_json_string(&b, string(task.task_id))
		strings.write_string(&b, `","chain_id":"`)
		contracts.write_json_string(&b, string(task.chain_id))
		strings.write_string(&b, `","new_status":"`)
		contracts.write_json_string(&b, task_status_string(task.status))
		strings.write_string(&b, `","action":"`)
		contracts.write_json_string(&b, action)
		strings.write_string(&b, `","message":"`)
		contracts.write_json_string(&b, message)
		strings.write_string(&b, `","assignee_instance_ids":[`)
		for id, i in assignees { if i>0 do strings.write_string(&b, ","); strings.write_string(&b, `"`); contracts.write_json_string(&b, id); strings.write_string(&b, `"`) }
		strings.write_string(&b, `],"reviewer_instance_ids":[`)
		for id, i in reviewers { if i>0 do strings.write_string(&b, ","); strings.write_string(&b, `"`); contracts.write_json_string(&b, id); strings.write_string(&b, `"`) }
		strings.write_string(&b, `],"default_reviewer_instance_ids":[`)
		for id, i in def_reviewers { if i>0 do strings.write_string(&b, ","); strings.write_string(&b, `"`); contracts.write_json_string(&b, id); strings.write_string(&b, `"`) }
		strings.write_string(&b, `],"mutation_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","actor_agent_instance_id":"`)
		contracts.write_json_string(&b, actor_agent_instance_id)
		strings.write_string(&b, `","updated_at":"`)
		contracts.write_json_string(&b, task.updated_at)
		strings.write_string(&b, `"}`)
		
		sent, err := project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id=bridge_id, command_id=cmd_id, body_json=strings.to_string(b)})
		strings.builder_destroy(&b)
	}
}

// notify_task_comment wakes the task's current actionable owner when a NEW comment
// is posted, so a comment asking the assignee/reviewer to act actually reaches the
// agent (previously only status changes notified; comments were UI-only). It
// resolves the actionable target for the task's current status (assignee for
// assigned/in_progress/validated_not_good, reviewer for in_validation, coordinator
// for validated_good), skips the comment's own author, and pushes a notify_task_nudge
// command to that target's bridge (the bridge coalesces/pushes to the live wrapper).
// Fire-and-forget: comment creation succeeds regardless of delivery.
notify_task_comment :: proc(service: ^Taskchain_Service, author_agent_instance_id: string, task: domain.Task) {
	if service.bridge_command_sink.send_runtime_command == nil do return
	if service.agents == nil do return
	chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return

	// R4: a comment notifies ALL assignees + participants (assignees, reviewers,
	// chain default reviewers), but per-recipient GATED on CT-6 — a participant is
	// only woken if this task is THAT participant's persisted current task. The
	// author is never self-notified, and each recipient is notified at most once.
	candidates := make([dynamic]string)
	defer delete(candidates)
	seen := make(map[string]bool)
	defer delete(seen)
	add_candidate :: proc(candidates: ^[dynamic]string, seen: ^map[string]bool, id: string) {
		t := strings.trim_space(id)
		if t == "" do return
		if seen[t] do return
		seen[t] = true
		append(candidates, t)
	}
	assignees := extract_instances_from_ref_blob(task.assignee_ref_json)
	defer delete(assignees)
	for id in assignees do add_candidate(&candidates, &seen, id)
	reviewers := extract_instances_from_ref_blob(task.reviewer_refs_json)
	defer delete(reviewers)
	for id in reviewers do add_candidate(&candidates, &seen, id)
	def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
	defer delete(def_reviewers)
	for id in def_reviewers do add_candidate(&candidates, &seen, id)

	now := platform.clock_now(service.clock)

	for target in candidates {
		// Don't notify the author about their own comment.
		if target == author_agent_instance_id do continue
		// CT-6 gate: only wake a participant whose current task is this task.
		action, gated_ok := notification_gate_action(service, target, task.task_id)
		if !gated_ok do continue
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, target)
		if !inst_ok || inst.bridge_id == "" do continue
		// R8: human-readable message states the action (work vs review) + title.
		message := comment_notify_message(task, action)
		defer delete(message)
		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		strings.write_string(&b, `{"type":"notify_task_nudge","origin":"comment","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","agent_instance_id":"`)
		contracts.write_json_string(&b, target)
		strings.write_string(&b, `","task_id":"`)
		contracts.write_json_string(&b, string(task.task_id))
		strings.write_string(&b, `","chain_id":"`)
		contracts.write_json_string(&b, string(task.chain_id))
		strings.write_string(&b, `","target_instance_id":"`)
		contracts.write_json_string(&b, target)
		strings.write_string(&b, `","target_role":"`)
		contracts.write_json_string(&b, action)
		strings.write_string(&b, `","action":"`)
		contracts.write_json_string(&b, action)
		strings.write_string(&b, `","task_status":"`)
		contracts.write_json_string(&b, task_status_string(task.status))
		strings.write_string(&b, `","message":"`)
		contracts.write_json_string(&b, message)
		strings.write_string(&b, `","created_at":"`)
		contracts.write_json_string(&b, now)
		strings.write_string(&b, `"}`)
		_, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id=inst.bridge_id, command_id=cmd_id, body_json=strings.to_string(b)})
		strings.builder_destroy(&b)
	}
}

valid_task_transition :: proc(current, next: domain.Task_Status) -> bool {
	if current == next do return true
	switch current {
	case .Assigned: return next == .Queued || next == .In_Progress || next == .Paused || next == .Cancelled
	// Queued is a holding state managed by the auto-promotion engine: it may be
	// promoted back to Assigned/In_Progress when the instance is free, or paused/
	// cancelled.
	case .Queued: return next == .Assigned || next == .In_Progress || next == .Paused || next == .Cancelled
	case .In_Progress: return next == .In_Validation || next == .Paused || next == .Cancelled
	// In_Validation -> Completed is legal: it is the quorum auto-finalize path
	// (evaluate_task_quorum advances a fully-approved task straight to Completed).
	case .In_Validation: return next == .Validated_Good || next == .Validated_Not_Good || next == .Completed || next == .Paused || next == .Cancelled
	case .Validated_Not_Good: return next == .In_Progress || next == .Paused || next == .Cancelled
	case .Validated_Good: return next == .Completed || next == .Paused || next == .Cancelled
	case .Paused: return next == .In_Progress || next == .Cancelled
	case .Completed, .Cancelled: return false
	}
	return false
}

create_comment :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Comment_Input) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	if strings.trim_space(input.body) == "" do return domain.Task_Comment{}, false, domain.domain_error(.Validation_Failed, "comment body is required")
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Comment{}, false, err
	chain, chain_ok, chain_err := get_chain(service, auth, task.chain_id)
	if !chain_ok do return domain.Task_Comment{}, false, chain_err
	if auth.kind == .Instance_Token {
		if auth.agent_instance_id == "" do return domain.Task_Comment{}, false, domain.domain_error(.Forbidden, "instance token is required")
		if same, same_err := agent_instance_same_chain(service, auth.agent_instance_id, chain); !same do return domain.Task_Comment{}, false, same_err
	}
	now := platform.clock_now(service.clock)
	comment := domain.Task_Comment{comment_id = platform.generate_id(service.ids, "cmt_"), task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, author_agent_instance_id = auth.agent_instance_id, body = input.body, created_at = now, updated_at = now}
	return iface.taskchain_save_comment(service.repo, comment)
}

list_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_comments_by_task(service.repo, task.task_id, task.owner_user_id)
}

target_string :: proc(target: Nudge_Target) -> string {
	switch target {
	case .Assignee: return "assignee"
	case .Reviewer: return "reviewer"
	case .Coordinator: return "coordinator"
	case .None: return "none"
	}
	return "none"
}

// nudge_target_action maps a Nudge_Target to the canonical R8 action label used
// consistently across every task notification ("work" for assignee, "review" for
// reviewer, "coordinate" for coordinator, "" for none). This keeps the wrapper's
// parsing uniform: every task notify carries an "action" field.
nudge_target_action :: proc(target: Nudge_Target) -> string {
	switch target {
	case .Assignee:    return "work"
	case .Reviewer:    return "review"
	case .Coordinator: return "coordinate"
	case .None:        return ""
	}
	return ""
}

// current_task_role_action maps a persisted Current_Task_Role to the R8 action
// label the notification must state: "work" (assignee) or "review" (reviewer).
// Returns "" for None (the instance has no current task).
current_task_role_action :: proc(role: domain.Current_Task_Role) -> string {
	switch role {
	case .Work:   return "work"
	case .Review: return "review"
	case .None:   return ""
	}
	return ""
}

// notification_gate_action is the STRICT CT-6 gate used for comment fan-out (R4):
// it returns (action, true) ONLY when `task_id` is exactly `instance_id`'s
// persisted current task, deriving the work-vs-review action from the persisted
// role. Any other case — pointer unset, different task, no role, or no agent repo
// — returns ("", false). Unlike notification_allowed_for_recipient (used for
// status-change wakes, which fail open on an unknown pointer), comments are purely
// informational and must never wake a participant who is not currently focused on
// the task, so this variant fails CLOSED.
notification_gate_action :: proc(service: ^Taskchain_Service, instance_id: string, task_id: domain.Task_ID) -> (string, bool) {
	if service == nil || service.agents == nil do return "", false
	if strings.trim_space(instance_id) == "" do return "", false
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return "", false
	if inst.current_task_id != string(task_id) do return "", false
	action := current_task_role_action(inst.current_task_role)
	if action == "" do return "", false
	return action, true
}

// action_for_status is the R8 action label implied by a status-change wake: the
// bridge wakes the ASSIGNEE (work) when a task enters In_Progress or bounces back
// Validated_Not_Good (rework), and the REVIEWER (review) when it enters
// In_Validation. Other statuses do not wake anyone here.
action_for_status :: proc(status: domain.Task_Status) -> string {
	#partial switch status {
	case .In_Progress, .Validated_Not_Good: return "work"
	case .In_Validation:                     return "review"
	}
	return ""
}

// task_display_name returns the task's human title, falling back to its id when
// the title is empty, so notification messages are always readable.
task_display_name :: proc(task: domain.Task) -> string {
	t := strings.trim_space(task.title)
	if t != "" do return t
	return string(task.task_id)
}

// status_notify_message builds the natural-language wake message for a
// status-change notify, derived from the R8 action + task title (R8: every notify
// must say WORK / REVIEW unambiguously). Validated_Not_Good is phrased as a rework
// request so the assignee knows changes were requested.
status_notify_message :: proc(task: domain.Task, action: string) -> string {
	name := task_display_name(task)
	switch action {
	case "review": return strings.concatenate({"Review requested: ", name})
	case "work":
		if task.status == .Validated_Not_Good do return strings.concatenate({"Rework requested (changes requested): ", name})
		return strings.concatenate({"Work ready: ", name})
	}
	return strings.concatenate({"Task updated: ", name})
}

// comment_notify_message builds the natural-language wake message for a comment
// notify, stating whether the recipient should now work or review (R8) + title.
comment_notify_message :: proc(task: domain.Task, action: string) -> string {
	name := task_display_name(task)
	switch action {
	case "review": return strings.concatenate({"New comment on \"", name, "\" — please REVIEW"})
	case "work":   return strings.concatenate({"New comment on \"", name, "\" — please continue WORK"})
	}
	return strings.concatenate({"New comment on \"", name, "\""})
}

// notification_allowed_for_recipient implements CT-6 gating with a fail-open bias:
// a recipient is SUPPRESSED only when we positively know its persisted current
// task is a DIFFERENT task. When the instance's current_task is this task we allow
// with the persisted role's action label; when the pointer is unset/unknown (or no
// agent repo is wired) we allow with the status-implied action, so legitimate
// cross-bridge/replay/promotion wakes are never dropped just because a pointer has
// not been computed yet. The net effect is the intended noise reduction: an
// instance actively focused on task B is never woken for an event on task A, while
// still guaranteeing an agent is woken for its own current task.
notification_allowed_for_recipient :: proc(service: ^Taskchain_Service, instance_id: string, task: domain.Task) -> (bool, string) {
	status_action := action_for_status(task.status)
	if service == nil || service.agents == nil do return true, status_action
	if strings.trim_space(instance_id) == "" do return true, status_action
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return true, status_action
	if inst.current_task_id == "" do return true, status_action
	if inst.current_task_id != string(task.task_id) do return false, ""
	// Positively this recipient's current task: prefer the persisted role's label.
	action := current_task_role_action(inst.current_task_role)
	if action == "" do action = status_action
	return true, action
}

task_status_string :: proc(status: domain.Task_Status) -> string {
	switch status {
	case .Assigned: return "assigned"
	case .Queued: return "queued"
	case .In_Progress: return "in_progress"
	case .In_Validation: return "in_validation"
	case .Validated_Good: return "validated_good"
	case .Validated_Not_Good: return "validated_not_good"
	case .Paused: return "paused"
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	}
	return "assigned"
}

extract_instances_from_ref_blob :: proc(blob: string) -> [dynamic]string {
	instances := make([dynamic]string)
	search := 0
	for search < len(blob) {
		rel := strings.index(blob[search:], "agent_instance_id")
		if rel < 0 do break
		idx := search + rel
		id := json_string_value_after(blob, idx)
		if id != "" {
			append(&instances, id)
		}
		search = idx + len("agent_instance_id")
	}
	return instances
}

manual_nudge :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, message: string) -> (Manual_Nudge, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return Manual_Nudge{}, false, err
	if task.publish_state != .Published do return Manual_Nudge{}, false, domain.domain_error(.Conflict, "draft task cannot be nudged")
	if task.status == .Completed || task.status == .Cancelled do return Manual_Nudge{}, false, domain.domain_error(.Conflict, "terminal task cannot be nudged")
	
	target := nudge_target_for_status(task.status)
	nudge_id := platform.generate_id(service.ids, "ndg_")
	now := platform.clock_now(service.clock)
	nudge := Manual_Nudge{task_id = task.task_id, owner_user_id = task.owner_user_id, target = target, message = message, created_at = now, nudge_id = nudge_id}
	
	instance_ids := make([dynamic]string)
	defer delete(instance_ids)
	
	if target == .Assignee {
		extracted := extract_instances_from_ref_blob(task.assignee_ref_json)
		for id in extracted do append(&instance_ids, id)
		delete(extracted)
	} else if target == .Reviewer {
		extracted := extract_instances_from_ref_blob(task.reviewer_refs_json)
		for id in extracted do append(&instance_ids, id)
		delete(extracted)
	} else if target == .Coordinator {
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		if chain_ok && chain.coordinator_agent_instance_id != "" {
			append(&instance_ids, chain.coordinator_agent_instance_id)
		}
	}
	
	if target == .None || len(instance_ids) == 0 {
		nudge.delivery_state = "no_targets"
		nudge.targets_json = "[]"
		append(&service.nudges, nudge)
		return nudge, true, domain.Domain_Error{}
	}
	
	live_delivered := 0
	durable_queued := 0
	failed := 0
	targets_b := strings.builder_make()
	defer strings.builder_destroy(&targets_b)
	strings.write_string(&targets_b, "[")
	
	for id, i in instance_ids {
		if i > 0 do strings.write_string(&targets_b, ",")
		strings.write_string(&targets_b, `{"agent_instance_id":"`)
		contracts.write_json_string(&targets_b, id)
		strings.write_string(&targets_b, `","role":"`)
		contracts.write_json_string(&targets_b, target_string(target))
		
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, id)
		if !inst_ok || inst.bridge_id == "" {
			failed += 1
			strings.write_string(&targets_b, `","state":"failed"}`)
			continue
		}
		
		strings.write_string(&targets_b, `","bridge_id":"`)
		contracts.write_json_string(&targets_b, inst.bridge_id)
		
		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, `{"type":"notify_task_nudge","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","agent_instance_id":"`)
		contracts.write_json_string(&b, id)
		strings.write_string(&b, `","task_id":"`)
		contracts.write_json_string(&b, string(task.task_id))
		strings.write_string(&b, `","chain_id":"`)
		contracts.write_json_string(&b, string(task.chain_id))
		strings.write_string(&b, `","nudge_id":"`)
		contracts.write_json_string(&b, nudge_id)
		strings.write_string(&b, `","target_role":"`)
		contracts.write_json_string(&b, target_string(target))
		strings.write_string(&b, `","action":"`)
		contracts.write_json_string(&b, nudge_target_action(target))
		strings.write_string(&b, `","task_status":"`)
		contracts.write_json_string(&b, task_status_string(task.status))
		strings.write_string(&b, `","body":"`)
		contracts.write_json_string(&b, message)
		strings.write_string(&b, `","created_at":"`)
		contracts.write_json_string(&b, now)
		strings.write_string(&b, `"}`)
		
		sent := false
		if service.bridge_command_sink.send_runtime_command_wait != nil {
			result_json, sent, _ := project.bridge_command_send_runtime_wait(service.bridge_command_sink, project.Runtime_Command{bridge_id=inst.bridge_id, command_id=cmd_id, body_json=strings.to_string(b)}, 1000)
			if sent {
				if strings.contains(result_json, `"status":"succeeded"`) {
					live_delivered += 1
					strings.write_string(&targets_b, `","state":"delivered"}`)
				} else {
					durable_queued += 1
					strings.write_string(&targets_b, `","state":"queued"}`)
				}
			} else {
				failed += 1
				strings.write_string(&targets_b, `","state":"failed"}`)
			}
		} else {
			if service.bridge_command_sink.send_runtime_command != nil {
				sent, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id=inst.bridge_id, command_id=cmd_id, body_json=strings.to_string(b)})
			}
			if sent {
				durable_queued += 1
				strings.write_string(&targets_b, `","state":"queued"}`)
			} else {
				failed += 1
				strings.write_string(&targets_b, `","state":"failed"}`)
			}
		}
	}
	strings.write_string(&targets_b, "]")
	
	nudge.targets_json = strings.clone(strings.to_string(targets_b))
	nudge.live_delivered = live_delivered
	nudge.durable_queued = durable_queued
	nudge.failed = failed
	
	if live_delivered > 0 {
		nudge.delivery_state = "delivered"
	} else if durable_queued > 0 {
		nudge.delivery_state = "queued"
	} else {
		nudge.delivery_state = "failed"
	}
	
	append(&service.nudges, nudge)
	return nudge, true, domain.Domain_Error{}
}

comment_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Task_Comment_Input) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	if strings.trim_space(input.body) == "" do return domain.Task_Comment{}, false, domain.domain_error(.Validation_Failed, "comment body is required")
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Comment{}, false, err
	if task.publish_state != .Published do return domain.Task_Comment{}, false, domain.domain_error(.Conflict, "draft task cannot be commented on")
	if auth.kind == .Instance_Token {
		if auth.agent_instance_id == "" do return domain.Task_Comment{}, false, domain.domain_error(.Forbidden, "instance token is required")
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		is_coord := chain_ok && is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_actor := strings.contains(task.assignee_ref_json, auth.agent_instance_id) || strings.contains(task.reviewer_refs_json, auth.agent_instance_id)
		if !is_coord && !is_actor do return domain.Task_Comment{}, false, domain.domain_error(.Forbidden, "instance token is not assigned to or coordinator of this task")
	}
	now := platform.clock_now(service.clock)
	comment := domain.Task_Comment{comment_id = platform.generate_id(service.ids, "cmt_"), task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, author_agent_instance_id = auth.agent_instance_id, body = input.body, created_at = now, updated_at = now}
	saved, ok2, err2 := iface.taskchain_save_comment(service.repo, comment)
	if ok2 {
		// Wake the task's current actionable owner so a comment actually reaches the
		// agent (not just the UI). author = the commenter (empty for user comments).
		notify_task_comment(service, auth.agent_instance_id if auth.kind == .Instance_Token else "", task)
	}
	return saved, ok2, err2
}

list_task_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_comments_by_task(service.repo, task.task_id, task.owner_user_id)
}

// --- Member Management ---

add_chain_member :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_instance_id: string, role: string) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain_Member{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain_Member{}, false, domain.domain_error(.Forbidden, "only chain coordinator can add members")
	}
	if agent_instance_id == "" do return domain.Task_Chain_Member{}, false, domain.domain_error(.Validation_Failed, "agent_instance_id is required")

	agent_id := ""
	if service.agents != nil {
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, agent_instance_id)
		if inst_ok {
			if inst.owner_user_id != chain.owner_user_id do return domain.Task_Chain_Member{}, false, domain.domain_error(.Conflict, "agent instance owner mismatch")
			agent_id = inst.agent_id
		}
	}

	member_role := role
	if member_role == "" do member_role = "worker"
	now := platform.clock_now(service.clock)

	member := domain.Task_Chain_Member{
		chain_id = chain.chain_id,
		agent_instance_id = agent_instance_id,
		agent_id = agent_id,
		owner_user_id = chain.owner_user_id,
		role = member_role,
		created_at = now,
	}

	saved_member, saved_ok, save_err := iface.taskchain_save_member(service.repo, member)
	// If a coordinator member was added/updated, keep the derived mirror column in
	// sync with the canonical members table (H9).
	if saved_ok && member_role == "coordinator" do _ = coordinator_sync_mirror(service, chain)
	return saved_member, saved_ok, save_err
}

remove_chain_member :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_instance_id: string) -> (bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return false, domain.domain_error(.Forbidden, "only chain coordinator can remove members")
	}

	members, list_err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if list_err.code != .None do return false, list_err

	// Disallow removing sole coordinator
	is_target_coordinator := false
	coordinator_count := 0
	for m in members {
		if m.role == "coordinator" {
			coordinator_count += 1
			if m.agent_instance_id == agent_instance_id do is_target_coordinator = true
		}
	}

	if is_target_coordinator && coordinator_count <= 1 {
		return false, domain.domain_error(.Conflict, "cannot remove sole coordinator from task chain")
	}

	removed, remove_err := iface.taskchain_remove_member(service.repo, chain.chain_id, agent_instance_id, chain.owner_user_id)
	// If a coordinator member was removed, resync the derived mirror column from
	// the canonical members table (H9).
	if removed && is_target_coordinator do _ = coordinator_sync_mirror(service, chain)
	return removed, remove_err
}

list_chain_members :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

// --- Task Dependencies ---

add_task_dependency :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task_Dependency{}, false, err
	dep_task, dep_ok, dep_err := get_task(service, auth, depends_on_task_id)
	if !dep_ok do return domain.Task_Dependency{}, false, dep_err

	if task.chain_id != dep_task.chain_id do return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "dependencies must be in the same chain")
	if task.task_id == dep_task.task_id do return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "task cannot depend on itself")

	// Cycle detection
	if has_dependency_cycle(service, task.chain_id, task.owner_user_id, task.task_id, dep_task.task_id) {
		return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "circular dependency detected")
	}

	now := platform.clock_now(service.clock)
	dep := domain.Task_Dependency{
		task_id = task.task_id,
		depends_on_task_id = dep_task.task_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		created_at = now,
	}

	saved_dep, dep_save_ok, dep_save_err := iface.taskchain_save_dependency(service.repo, dep)
	if !dep_save_ok do return domain.Task_Dependency{}, false, dep_save_err
	// Adding a dependency can make a task non-actionable (newly blocked); reconcile
	// pointers so a task that WAS a current focus but is now blocked is advanced off
	// and the gate stays authoritative.
	_ = recompute_promotions_for_chain_id(service, task.chain_id)
	return saved_dep, true, domain.Domain_Error{}
}

remove_task_dependency :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return false, err
	removed, remove_err := iface.taskchain_remove_dependency(service.repo, task.task_id, depends_on_task_id, task.owner_user_id)
	if remove_err.code != .None do return removed, remove_err
	// Removing a dependency can UNBLOCK a task (make it actionable); reconcile
	// pointers so the freshly-unblocked task is promoted/surfaced to its assignee
	// instead of being gated out behind a stale pointer.
	_ = recompute_promotions_for_chain_id(service, task.chain_id)
	return removed, remove_err
}

list_chain_dependencies :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

has_dependency_cycle :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, target_task_id, current_dep_id: domain.Task_ID) -> bool {
	if target_task_id == current_dep_id do return true
	deps, err := iface.taskchain_list_dependencies_by_chain(service.repo, chain_id, owner)
	if err.code != .None do return false
	for d in deps {
		if d.task_id == current_dep_id {
			if has_dependency_cycle(service, chain_id, owner, target_task_id, d.depends_on_task_id) do return true
		}
	}
	return false
}

// --- Reviewer Voting & Quorum ---

record_task_vote :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Vote_Input) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Vote{}, false, err
	if task.publish_state != .Published do return domain.Task_Vote{}, false, domain.domain_error(.Conflict, "draft task cannot receive votes")

	voter_instance_id := ""
	if auth.kind == .Instance_Token {
		voter_instance_id = auth.agent_instance_id
	}

	// Assignee cannot vote on own task
	if voter_instance_id != "" && strings.contains(task.assignee_ref_json, voter_instance_id) {
		return domain.Task_Vote{}, false, domain.domain_error(.Forbidden, "assignee cannot vote on their own task")
	}

	if auth.kind == .Instance_Token {
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		is_reviewer := strings.contains(task.reviewer_refs_json, voter_instance_id)
		if !is_reviewer && chain_ok {
			is_reviewer = strings.contains(chain.default_reviewer_refs_json, voter_instance_id)
		}
		if !is_reviewer {
			return domain.Task_Vote{}, false, domain.domain_error(.Forbidden, "voter is not a designated reviewer for this task")
		}
	}

	now := platform.clock_now(service.clock)
	v := input.vote
	if v != "lgtm" && v != "ngtm" do return domain.Task_Vote{}, false, domain.domain_error(.Validation_Failed, "vote must be lgtm or ngtm")

	vote := domain.Task_Vote{
		task_id = task.task_id,
		reviewer_agent_instance_id = voter_instance_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		vote = v,
		comment = input.comment,
		created_at = now,
		updated_at = now,
	}

	saved_vote, save_ok, save_err := iface.taskchain_save_vote(service.repo, vote)
	if !save_ok do return domain.Task_Vote{}, false, save_err

	// Evaluate Quorum and auto-promote task status
	evaluate_task_quorum(service, task)

	return saved_vote, true, domain.Domain_Error{}
}

evaluate_task_quorum :: proc(service: ^Taskchain_Service, task: domain.Task) {
	if task.status != .In_Validation do return

	votes, err := iface.taskchain_list_votes_by_task(service.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return

	has_ngtm := false
	lgtm_count := 0
	for v in votes {
		if v.vote == "ngtm" do has_ngtm = true
		if v.vote == "lgtm" do lgtm_count += 1
	}

	// Determine the quorum outcome. Any ngtm fails the task; otherwise a
	// satisfied lgtm quorum means the task is fully approved.
	updated_status := task.status
	quorum_approved := false
	if has_ngtm {
		updated_status = .Validated_Not_Good
	} else {
		required_count := count_required_reviewers(task.reviewer_refs_json)
		if required_count <= 1 && lgtm_count >= 1 {
			quorum_approved = true
		} else if required_count > 1 && lgtm_count >= required_count {
			quorum_approved = true
		}
	}

	// When all required reviewers approve (no ngtm), auto-finalize the task all
	// the way to Completed rather than lingering in Validated_Good. This is the
	// only path that unblocks dependents: task_status_unblocks_dependents treats
	// just Completed/Cancelled as clearing — Validated_Good does NOT unblock. We
	// go In_Validation -> Completed directly (a legal transition here since the
	// quorum is satisfied) and set completed_at exactly once. Idempotency: the
	// early return above (status != In_Validation) makes late/duplicate votes a
	// no-op, so completion side-effects run once.
	if quorum_approved {
		updated_status = .Completed
	}

	if updated_status != task.status {
		now := platform.clock_now(service.clock)
		t := task
		t.status = updated_status
		t.updated_at = now
		if updated_status == .Completed do t.completed_at = now
		saved, ok, _ := iface.taskchain_save_task(service.repo, t)
		// CT-10: recompute whenever a review RESOLVES the task, not just on the
		// Completed path. Both outcomes change an instance's current focus:
		//   * Completed (LGTM quorum): frees the reviewer + unblocks dependents so
		//     downstream tasks auto-claim.
		//   * Validated_Not_Good (any NGTM): the reviewer is done reviewing and must
		//     advance to its next focus, AND the not-good task re-enters the
		//     assignee's promotable pool (work_status_is_actionable includes
		//     Validated_Not_Good) so auto-promotion flows the rework back to the
		//     assignee without a manual bump.
		// Guarding on updated_status != task.status keeps this a single recompute
		// per real resolution and a no-op for idempotent/duplicate votes.
		if ok && updated_status != task.status {
			chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, saved.chain_id)
			if chain_ok do _ = recompute_chain_promotions(service, chain)
		}
	}
}

count_required_reviewers :: proc(reviewer_refs_json: string) -> int {
	if reviewer_refs_json == "" || reviewer_refs_json == "[]" do return 0
	count := 0
	search := 0
	for search < len(reviewer_refs_json) {
		rel := strings.index(reviewer_refs_json[search:], "agent_instance_id")
		if rel < 0 do break
		count += 1
		search += rel + len("agent_instance_id")
	}
	search = 0
	for search < len(reviewer_refs_json) {
		rel := strings.index(reviewer_refs_json[search:], "user_id")
		if rel < 0 do break
		count += 1
		search += rel + len("user_id")
	}
	return count
}

list_task_votes :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_votes_by_task(service.repo, task.task_id, task.owner_user_id)
}

nudge_target_for_status :: proc(status: domain.Task_Status) -> Nudge_Target {
	switch status {
	// Queued tasks are held back deliberately, so they do not target a nudge.
	case .Queued: return .None
	case .Assigned, .In_Progress, .Validated_Not_Good, .Paused: return .Assignee
	case .In_Validation: return .Reviewer
	case .Validated_Good: return .Coordinator
	case .Completed, .Cancelled: return .None
	}
	return .None
}

get_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := iface.taskchain_get_task(service.repo, task_id)
	if !ok do return domain.Task{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, task.owner_user_id); !owner_ok do return domain.Task{}, false, owner_err
	if auth.kind == .Instance_Token {
		chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
		if !chain_ok do return domain.Task{}, false, chain_err
		if !is_instance_member_or_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "agent instance is not a member or coordinator of this task's chain")
		}
	}
	return task, true, domain.Domain_Error{}
}

update_chain_coordinator :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, coordinator_agent_instance_id: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can change the coordinator")
	}
	if coordinator_agent_instance_id != "" {
		if same, same_err := agent_instance_same_chain(service, coordinator_agent_instance_id, chain); !same do return domain.Task_Chain{}, false, same_err
	}
	// Change the coordinator through the SINGLE canonical source (members table);
	// set_chain_coordinator demotes the old coordinator, promotes the target, and
	// stamps the derived mirror column.
	chain = set_chain_coordinator(service, chain, coordinator_agent_instance_id)
	chain.updated_at = platform.clock_now(service.clock)
	return iface.taskchain_save_chain(service.repo, chain)
}

validate_actor_refs :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, assignee_ref_json, reviewer_refs_json: string) -> (bool, domain.Domain_Error) {
	if ok, err := validate_ref_blob(service, chain, assignee_ref_json); !ok do return false, err
	if ok, err := validate_ref_blob(service, chain, reviewer_refs_json); !ok do return false, err
	return true, domain.Domain_Error{}
}

validate_ref_blob :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, blob: string) -> (bool, domain.Domain_Error) {
	search := 0
	for search < len(blob) {
		rel := strings.index(blob[search:], "agent_instance_id")
		if rel < 0 do break
		idx := search + rel
		id := json_string_value_after(blob, idx)
		if id != "" {
			if same, same_err := agent_instance_same_chain(service, id, chain); !same do return false, same_err
		}
		search = idx + len("agent_instance_id")
	}
	search = 0
	for search < len(blob) {
		rel := strings.index(blob[search:], "user_id")
		if rel < 0 do break
		idx := search + rel
		id := json_string_value_after(blob, idx)
		if id != "" && id != string(chain.owner_user_id) do return false, domain.domain_error(.Not_Found, "task actor ref not found")
		search = idx + len("user_id")
	}
	return true, domain.Domain_Error{}
}

agent_instance_same_chain :: proc(service: ^Taskchain_Service, instance_id: string, chain: domain.Task_Chain) -> (bool, domain.Domain_Error) {
	if service.agents == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return false, err
	if inst.owner_user_id != chain.owner_user_id do return false, domain.domain_error(.Conflict, "agent instance ref must belong to the same chain owner")
	if inst.chain_id == string(chain.chain_id) || instance_id == chain.coordinator_agent_instance_id || is_instance_member_or_coordinator(service, chain, instance_id) {
		return true, domain.Domain_Error{}
	}
	return false, domain.domain_error(.Conflict, "agent instance ref must belong to the same chain")
}

agent_instance_ref_json :: proc(instance_id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, instance_id, `"}`}) }
user_ref_json :: proc(user_id: string) -> string { return strings.concatenate({`{"type":"user","user_id":"`, user_id, `"}`}) }

// normalize_actor_refs rewrites any {"type":"agent_id","agent_id":"..."} ref into a
// concrete {"type":"agent_instance",...} ref by resolving a reusable instance of that
// durable agent_id for the chain owner (Phase 1: resolve-by-reuse). The resolved
// instance is added to the chain members (idempotently) so downstream
// validate_actor_refs / agent_instance_same_chain pass. Refs of type agent_instance
// and user are returned unchanged. Returns the rewritten blob.
//
// Reuse policy (default "chain"): prefer an instance already in this chain
// (coordinator or member) of the requested agent_id; otherwise any active instance of
// that agent_id owned by the chain owner. If none is found we return a clear error
// (Phase 2 will launch a new instance via agent_service.create_instance).
normalize_actor_refs :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, blob: string) -> (string, bool, domain.Domain_Error) {
	if blob == "" do return blob, true, domain.Domain_Error{}
	if !strings.contains(blob, "\"agent_id\"") do return blob, true, domain.Domain_Error{}
	result := blob
	search := 0
	for search < len(result) {
		rel := strings.index(result[search:], "\"type\"")
		if rel < 0 do break
		type_idx := search + rel
		type_val := json_string_value_after(result, type_idx)
		if type_val != "agent_id" { search = type_idx + len("\"type\""); continue }
		// Find the agent_id value belonging to this ref object.
		id_rel := strings.index(result[type_idx:], "agent_id")
		if id_rel < 0 do break
		id_idx := type_idx + id_rel
		agent_id := json_string_value_after(result, id_idx)
		if agent_id == "" { search = id_idx + len("agent_id"); continue }
		instance_id, resolve_ok, resolve_err := resolve_agent_id_instance(service, chain, agent_id)
		if !resolve_ok do return blob, false, resolve_err
		// Ensure it is a chain member so the ref validates.
		if !is_instance_member_or_coordinator(service, chain, instance_id) {
			ensure_chain_member(service, chain, instance_id, agent_id)
		}
		// Replace the whole ref object {...} that contains this type with an
		// agent_instance ref.
		obj_start := strings.last_index_byte(result[:type_idx], '{')
		if obj_start < 0 do return blob, false, domain.domain_error(.Validation_Failed, "malformed agent_id ref")
		obj_end := strings.index_byte(result[type_idx:], '}')
		if obj_end < 0 do return blob, false, domain.domain_error(.Validation_Failed, "malformed agent_id ref")
		obj_end = type_idx + obj_end + 1
		replacement := agent_instance_ref_json(instance_id)
		result = strings.concatenate({result[:obj_start], replacement, result[obj_end:]})
		search = obj_start + len(replacement)
	}
	return result, true, domain.Domain_Error{}
}

// resolve_agent_id_instance finds a reusable instance of the durable agent_id for the
// chain owner. Prefers in-chain instances, then any owner-owned instance.
resolve_agent_id_instance :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, agent_id: string) -> (string, bool, domain.Domain_Error) {
	if service.agents == nil do return "", false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	// 1) Prefer an instance already in this chain (coordinator or member).
	if chain.coordinator_agent_instance_id != "" {
		if inst, ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); ok && inst.agent_id == agent_id {
			return inst.agent_instance_id, true, domain.Domain_Error{}
		}
	}
	if members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); err.code == .None {
		for m in members {
			if m.agent_id == agent_id && m.agent_instance_id != "" do return m.agent_instance_id, true, domain.Domain_Error{}
		}
	}
	// 2) Any active instance of this agent_id owned by the chain owner.
	instances, list_err := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 1000, "")
	if list_err.code == .None {
		for inst in instances {
			if inst.agent_id != agent_id do continue
			if inst.runtime_status == "stopped" || inst.runtime_status == "failed" do continue
			return inst.agent_instance_id, true, domain.Domain_Error{}
		}
	}
	return "", false, domain.domain_error(.Not_Found, strings.concatenate({"no reusable instance found for agent_id '", agent_id, "'; launch one or add it to the chain"}))
}

// ensure_chain_member adds instance_id to the chain members with a worker role if not
// already present. Best-effort: failures are non-fatal because the ref will still be
// validated by agent_instance_same_chain (owner + chain checks).
ensure_chain_member :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, instance_id, agent_id: string) {
	now := platform.clock_now(service.clock)
	member := domain.Task_Chain_Member{
		chain_id = chain.chain_id,
		agent_instance_id = instance_id,
		agent_id = agent_id,
		owner_user_id = chain.owner_user_id,
		role = "worker",
		created_at = now,
	}
	_, _, _ = iface.taskchain_save_member(service.repo, member)
}

json_string_value_after :: proc(body: string, key_idx: int) -> string {
	if key_idx < 0 || key_idx >= len(body) do return ""
	rest := body[key_idx:]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return ""
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '"' do return ""
	for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
	return ""
}

chain_status_from_string :: proc(status: string) -> domain.Task_Chain_Status {
	if status == "completed" do return .Completed
	if status == "cancelled" do return .Cancelled
	return .Active
}
