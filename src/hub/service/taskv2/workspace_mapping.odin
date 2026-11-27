package taskv2

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

unmapped_workspace :: proc(dirs: []domain.Task_Chain_Directory) -> (dir: domain.Task_Chain_Directory, count: int) {
	for d in dirs {
		if d.bridge_id != "" do continue
		dir = d
		count += 1
	}
	return
}

Workspace_Mapping :: struct {
	task: domain.Task,
	chain: domain.Task_Chain,
	dir: domain.Task_Chain_Directory,
	placement: Placement,
}

// Read the candidate without side effects. Recheck under the UoW after the
// bridge replies so a stale preflight cannot overwrite a manual mapping.
workspace_mapping_candidate :: proc(svc: ^Service, task_id: domain.Task_ID) -> (Workspace_Mapping, bool) {
	task, found, _ := iface.taskchain_get_task(svc.repo, task_id)
	if !found || task.state != .Ready || task.kind == .Gate || task_is_held(task) do return {}, false
	chain, chain_ok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !chain_ok || chain.owner_user_id != task.owner_user_id || chain.status != .Active || chain.publish_state != .Published do return {}, false
	ctx, ok, _ := load_match_context(svc, chain, with_tasks = false)
	if !ok do return {}, false
	defer destroy_match_context(&ctx)
	if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do return {}, false
	dir, count := unmapped_workspace(ctx.dirs)
	if count != 1 do return {}, false
	assignee := brief_assignee(task.brief_json)
	for claim in ctx.leases {
		if claim.task_id != task.task_id || claim.kind != domain.LEASE_KIND_WORK do continue
		if holder, holder_ok, _ := iface.agent_get_instance(svc.agents, claim.holder_instance_id); holder_ok do assignee = holder.agent_id
	}
	if assignee == "" do return {}, false
	p: Placement
	resolved: bool
	if ctx.has_coordinator && assignee == ctx.coordinator.agent_id {
		p = coordinator_placement(&ctx)
		resolved = p.bridge_id != ""
	} else {
		fleet, row := fleet_row_for_agent(ctx.fleets[:], assignee)
		if !row || fleet.paused do return {}, false
		p, resolved = resolve_placement(&ctx, task, fleet, true)
	}
	if reason, _ := placement_problem(svc, &ctx, p, resolved, assignee); reason != "workspace_missing" do return {}, false
	// Match_Context owns these directory strings.
	dir.directory_id = strings.clone(dir.directory_id, context.temp_allocator)
	dir.path = strings.clone(dir.path, context.temp_allocator)
	dir.vcs_kind = strings.clone(dir.vcs_kind, context.temp_allocator)
	dir.vcs_info_json = strings.clone(dir.vcs_info_json, context.temp_allocator)
	dir.created_at = strings.clone(dir.created_at, context.temp_allocator)
	dir.updated_at = strings.clone(dir.updated_at, context.temp_allocator)
	p.bridge_id = strings.clone(p.bridge_id, context.temp_allocator)
	return {task = task, chain = chain, dir = dir, placement = p}, true
}

attempt_workspace_mapping :: proc(svc: ^Service, task_id: domain.Task_ID) {
	if svc.bridge_command_sink.validate_project_path == nil do return
	before, eligible := workspace_mapping_candidate(svc, task_id)
	if !eligible do return
	validation := project.validate_workspace_path(svc.bridges, svc.bridge_command_sink, svc.ids, before.chain.owner_user_id, before.placement.bridge_id, before.dir.path, before.dir.vcs_kind)
	u, began, _ := begin_uow(svc)
	if !began do return
	commit := false
	defer { _, _ = end_uow(svc, &u, commit) }
	current, current_ok := workspace_mapping_candidate(svc, task_id)
	if !current_ok || current.dir != before.dir || current.placement.bridge_id != before.placement.bridge_id do return
	if validation.code != .None {
		ctx, context_ok, _ := load_match_context(svc, current.chain, with_tasks = false)
		if !context_ok do return
		defer destroy_match_context(&ctx)
		commit, _ = reconcile_task_placement_in_uow(svc, &u, &ctx, current.task, nil, false, validation.message)
		return
	}
	current.dir.bridge_id = current.placement.bridge_id
	current.dir.updated_at = platform.clock_now(svc.clock)
	mapped, saved, _ := iface.taskchain_save_directory(svc.repo, current.dir)
	if !saved do return
	commit, _ = directory_added_in_uow(svc, &u, mapped)
	if commit do effect_publish_chain(&u, current.chain.chain_id, current.chain.owner_user_id, "updated")
}

arm_workspace_mapping :: proc(svc: ^Service, ctx: ^Match_Context, task: domain.Task, placement: Placement, assignee: string) {
	if svc.bridge_command_sink.validate_project_path == nil || placement.directory_id != "" || placement.bridge_id == "" do return
	if _, count := unmapped_workspace(ctx.dirs); count != 1 do return
	if reason, _ := placement_problem(svc, ctx, placement, true, assignee); reason != "workspace_missing" do return
	timers_arm(svc, .Workspace_Map, string(task.task_id), now_ms(svc.clock), "")
}
