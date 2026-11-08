package taskv2

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

task_agent_delegation_available :: proc(svc: ^Service, task: domain.Task) -> bool {
	if svc == nil || task.workflow_run_id != "" || task.stage_key != "" || task_is_held(task) || !is_agent_not_running_block(task.blocked_on_json) do return false
	evs, err := task_fold_events(svc, task)
	if err.code != .None do return false
	return !fold_task(evs, fold_input_for_task(task, true)).in_review
}

// Called only after start_task_agent has checked user authority and the exact
// displayed block under the UoW. Assignment and the first lease commit together:
// a queued/unlaunchable selection leaves the old assignment and consent intact.
delegate_task_agent_in_uow :: proc(svc: ^Service, u: ^Uow, auth: contracts.Auth_Context, task_in: domain.Task, replacement_id: string) -> (bool, domain.Domain_Error) {
	task := task_in
	if task.workflow_run_id != "" || task.stage_key != "" do return false, domain.domain_error(.Conflict, "change workflow workers through workflow configuration")
	if task_is_held(task) do return false, domain.domain_error(.Conflict, "release the task hold before delegating")
	evs, eerr := task_fold_events(svc, task)
	if eerr.code != .None do return false, eerr
	view := fold_task(evs, fold_input_for_task(task, true))
	if view.in_review do return false, domain.domain_error(.Conflict, "this failure belongs to a reviewer; worker delegation is unavailable")
	id := strings.trim_space(replacement_id)
	failed_id := jsonx.extract_string(task.blocked_on_json, "agent_id", "", true, context.temp_allocator)
	if !strings.has_prefix(id, "agt_") || id == failed_id || id == brief_assignee(task.brief_json) do return false, domain.domain_error(.Validation_Failed, "choose a different durable worker")
	a, found, aerr := iface.agent_get(svc.agents, id)
	if aerr.code != .None do return false, aerr
	if !found || a.owner_user_id != task.owner_user_id || a.state != .Active do return false, domain.domain_error(.Validation_Failed, "replacement must be an owned active durable agent")
	chain, exists, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !exists do return false, cerr
	ctx, loaded, lerr := load_match_context(svc, chain)
	if !loaded do return false, lerr
	defer destroy_match_context(&ctx)
	if chain.status != .Active || chain.publish_state != .Published do return false, domain.domain_error(.Conflict, "the chain is not active")
	if ctx.has_coordinator && ctx.coordinator.agent_id == id do return false, domain.domain_error(.Validation_Failed, "the coordinator cannot be a delegated worker")
	// No worker or reviewer lease may be displaced by a worker reassignment.
	for l in ctx.leases do if l.task_id == task.task_id do return false, domain.domain_error(.Conflict, "task has a live lease; use checkpoint/hold before delegating")
	fleet, eligible := fleet_row_for_agent(ctx.fleets[:], id)
	if !eligible || !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) || domain.fleet_role_paused(fleet, domain.FLEET_ROLE_WORKER) do return false, domain.domain_error(.Validation_Failed, "replacement must have an unpaused worker fleet role")
	// Delegation must not silently remove a required reviewer by making it author.
	for reviewer in brief_named_reviewers(task.brief_json, context.temp_allocator) do if reviewer == id do return false, domain.domain_error(.Validation_Failed, "a required reviewer cannot become this task's worker")
	for role in brief_review_roles(task.brief_json, context.temp_allocator) do if fleet_row_has_role(fleet, role) do return false, domain.domain_error(.Validation_Failed, "a required role reviewer cannot become this task's worker")
	p, resolved := resolve_placement(&ctx, task, fleet, true)
	if reason, message := placement_problem(svc, &ctx, p, resolved, id); reason != "" do return false, domain.domain_error(.Validation_Failed, message)
	value, jerr := json.parse_string(task.brief_json, allocator = context.temp_allocator)
	root, object := value.(json.Object)
	if jerr != nil || !object do return false, domain.domain_error(.Internal_Error, "invalid task brief")
	root["assignee"] = json.String(id)
	encoded, enc_err := json.marshal(root, allocator = context.temp_allocator)
	if enc_err != nil do return false, domain.domain_error(.Internal_Error, "could not encode delegation")
	task.brief_json = string(encoded)
	task.updated_at = platform.clock_now(svc.clock)
	if _, saved, serr := iface.taskchain_save_task(svc.repo, task); !saved do return false, serr
	payload := json_begin()
	json_raw(&payload, "fields", `["assignee"]`)
	json_str(&payload, "action", "delegate_and_start")
	json_str(&payload, "replacement_agent_id", id)
	json_str(&payload, "previous_agent_id", failed_id)
	if _, _, recorded, rerr := record_event(svc, u, task, actor_from_auth(auth), EV_UPDATED, json_end(&payload)); !recorded do return false, rerr
	ready, _, answered, answer_err := record_event(svc, u, task, actor_from_auth(auth), EV_ANSWERED, `{}`)
	if !answered do return false, answer_err
	if granted, gerr := grant_selected_worker(svc, u, &ctx, ready, fleet, p); !granted do return false, gerr
	return after_chain_change(svc, u, task.chain_id, task.owner_user_id, .Task_Updated)
}
