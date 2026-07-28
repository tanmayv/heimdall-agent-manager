package taskchain

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"

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
}

Taskchain_Service :: struct {
	repo: ^iface.Taskchain_Repository,
	agents: ^iface.Agent_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	nudges: [dynamic]Manual_Nudge,
}

Create_Chain_Input :: struct {
	title: string,
	owner_user_id: string, // ignored; authoritative owner comes from AuthContext
	kind: string,
	coordinator_agent_id: string,
	default_reviewer_refs_json: string,
}

Create_Task_Input :: struct {
	chain_id: domain.Task_Chain_ID,
	title: string,
	owner_user_id: string, // rejected if not equal to parent/auth owner
	assignee_ref_json: string,
	reviewer_refs_json: string,
}

Task_Comment_Input :: struct {
	task_id: domain.Task_ID,
	body: string,
}

Comment_Input :: struct {
	task_id: domain.Task_ID,
	body: string,
}

new_taskchain_service :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Taskchain_Service {
	return Taskchain_Service{repo = repo, agents = agents, clock = clock, ids = ids, nudges = make([dynamic]Manual_Nudge)}
}

list_chains :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context) -> ([]domain.Task_Chain, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.taskchain_list_chains_by_owner(service.repo, owner)
}

get_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
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
	chain := domain.Task_Chain{
		chain_id = domain.Task_Chain_ID(platform.generate_id(service.ids, "chain_")),
		owner_user_id = owner,
		title = input.title,
		publish_state = .Draft,
		status = .Active,
		kind = kind,
		default_reviewer_refs_json = default_reviewers,
		created_at = now,
		updated_at = now,
	}
	return iface.taskchain_save_chain(service.repo, chain)
}

publish_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
	if chain.publish_state != .Draft do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "chain is already published")
	now := platform.clock_now(service.clock)
	chain.publish_state = .Published
	chain.status = .Active
	chain.published_at = now
	chain.updated_at = now
	return iface.taskchain_save_chain(service.repo, chain)
}

change_chain_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, next: domain.Task_Chain_Status) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
	if chain.publish_state != .Published do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "draft chain has no execution status")
	if !valid_chain_transition(chain.status, next) do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "invalid chain status transition")
	now := platform.clock_now(service.clock)
	chain.status = next
	chain.updated_at = now
	if next == .Completed || next == .Cancelled do chain.completed_at = now
	return iface.taskchain_save_chain(service.repo, chain)
}

valid_chain_transition :: proc(current, next: domain.Task_Chain_Status) -> bool {
	if current == next do return true
	switch current {
	case .Active: return next == .Completed || next == .Cancelled
	case .Completed, .Cancelled: return false
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
	if refs_ok, refs_err := validate_actor_refs(service, chain, assignee_ref, reviewer_refs); !refs_ok do return domain.Task{}, false, refs_err
	now := platform.clock_now(service.clock)
	task := domain.Task{
		task_id = domain.Task_ID(platform.generate_id(service.ids, "task_")),
		chain_id = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		title = input.title,
		publish_state = .Draft,
		status = .Assigned,
		assignee_ref_json = assignee_ref,
		reviewer_refs_json = reviewer_refs,
		created_at = now,
		updated_at = now,
	}
	return iface.taskchain_save_task(service.repo, task)
}

publish_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err
	if chain.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "cannot publish task before chain is published")
	if task.publish_state != .Draft do return domain.Task{}, false, domain.domain_error(.Conflict, "task is already published")
	now := platform.clock_now(service.clock)
	task.publish_state = .Published
	task.status = .Assigned
	task.published_at = now
	task.updated_at = now
	return iface.taskchain_save_task(service.repo, task)
}

change_task_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, next: domain.Task_Status) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if task.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "draft task has no execution status")
	if !valid_task_transition(task.status, next) do return domain.Task{}, false, domain.domain_error(.Conflict, "invalid task status transition")
	now := platform.clock_now(service.clock)
	task.status = next
	task.updated_at = now
	if next == .In_Progress && task.started_at == "" do task.started_at = now
	if next == .Completed || next == .Cancelled do task.completed_at = now
	return iface.taskchain_save_task(service.repo, task)
}

valid_task_transition :: proc(current, next: domain.Task_Status) -> bool {
	if current == next do return true
	switch current {
	case .Assigned: return next == .In_Progress || next == .Paused || next == .Cancelled
	case .In_Progress: return next == .In_Validation || next == .Paused || next == .Cancelled
	case .In_Validation: return next == .Validated_Good || next == .Validated_Not_Good || next == .Paused || next == .Cancelled
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
	if auth.kind == .Instance_Token {
		if auth.agent_instance_id == "" do return domain.Task_Comment{}, false, domain.domain_error(.Forbidden, "instance token is required")
		if same, same_err := agent_instance_same_chain(service, auth.agent_instance_id, string(task.chain_id), task.owner_user_id); !same do return domain.Task_Comment{}, false, same_err
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

manual_nudge :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, message: string) -> (Manual_Nudge, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return Manual_Nudge{}, false, err
	if task.publish_state != .Published do return Manual_Nudge{}, false, domain.domain_error(.Conflict, "draft task cannot be nudged")
	if task.status == .Completed || task.status == .Cancelled do return Manual_Nudge{}, false, domain.domain_error(.Conflict, "terminal task cannot be nudged")
	nudge := Manual_Nudge{task_id = task.task_id, owner_user_id = task.owner_user_id, target = nudge_target_for_status(task.status), message = message, created_at = platform.clock_now(service.clock)}
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
		if !(strings.contains(task.assignee_ref_json, auth.agent_instance_id) || strings.contains(task.reviewer_refs_json, auth.agent_instance_id)) do return domain.Task_Comment{}, false, domain.domain_error(.Forbidden, "instance token is not assigned to this task")
	}
	now := platform.clock_now(service.clock)
	comment := domain.Task_Comment{comment_id = platform.generate_id(service.ids, "cmt_"), task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, author_agent_instance_id = auth.agent_instance_id, body = input.body, created_at = now, updated_at = now}
	return iface.taskchain_save_comment(service.repo, comment)
}

list_task_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_comments_by_task(service.repo, task.task_id, task.owner_user_id)
}

nudge_target_for_status :: proc(status: domain.Task_Status) -> Nudge_Target {
	switch status {
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
	return task, true, domain.Domain_Error{}
}

update_chain_coordinator :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, coordinator_agent_instance_id: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if coordinator_agent_instance_id != "" {
		if same, same_err := agent_instance_same_chain(service, coordinator_agent_instance_id, string(chain.chain_id), chain.owner_user_id); !same do return domain.Task_Chain{}, false, same_err
	}
	chain.coordinator_agent_instance_id = coordinator_agent_instance_id
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
			if same, same_err := agent_instance_same_chain(service, id, string(chain.chain_id), chain.owner_user_id); !same do return false, same_err
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

agent_instance_same_chain :: proc(service: ^Taskchain_Service, instance_id, chain_id: string, owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	if service.agents == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return false, err
	if inst.owner_user_id != owner || inst.chain_id != chain_id do return false, domain.domain_error(.Conflict, "agent instance ref must belong to the same chain")
	return true, domain.Domain_Error{}
}

agent_instance_ref_json :: proc(instance_id: string) -> string { return strings.concatenate({"{\"type\":\"agent_instance\",\"agent_instance_id\":\"", instance_id, "\"}"}) }
user_ref_json :: proc(user_id: string) -> string { return strings.concatenate({"{\"type\":\"user\",\"user_id\":\"", user_id, "\"}"}) }

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
