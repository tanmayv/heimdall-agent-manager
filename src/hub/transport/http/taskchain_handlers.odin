package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import taskchain_service "odin_test:hub/service/taskchain"
import events "odin_test:hub/service/events"

Taskchain_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	agents: ^agent_service.Agent_Service,
	event_bus: ^events.User_Event_Bus,
}

// UI-BE-7: publish a lightweight resource_changed event to the owning user's
// live WebSocket clients so the browser can invalidate the smallest relevant
// RTK Query cache and update task/chain views without a manual refresh. These
// are fire-and-forget invalidation hints; the UI refetches authoritative state.
// event_bus may be nil in some test wirings, in which case publish is a no-op.
publish_chain_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, chain_id, change: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	summary := taskchain_resource_summary_json("chain_id", chain_id)
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, owner_user_id, "task_chain", chain_id, change, summary)
}

publish_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, task_id, chain_id, change: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	summary := taskchain_task_summary_json(task_id, chain_id)
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, owner_user_id, "task", task_id, change, summary)
}

// publish_instance_current_task_changed emits a live event on an agent instance's
// current-task pointer (CT-9) so the dashboard work-vs-review banner updates when
// a coordinator/user switches an agent's focus.
publish_instance_current_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, agent_instance_id, current_task_id, current_task_role: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"agent_instance_id":"`); write_handler_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`); write_handler_json_string(&b, current_task_id)
	strings.write_string(&b, `","current_task_role":"`); write_handler_json_string(&b, current_task_role)
	strings.write_string(&b, `"}`)
	events.publish_resource_changed(h.event_bus, owner_user_id, "agent_instance", agent_instance_id, "current_task_changed", strings.to_string(b))
}

taskchain_resource_summary_json :: proc(key, value: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	strings.write_byte(&b, '"')
	strings.write_string(&b, key)
	strings.write_string(&b, "\":\"")
	write_handler_json_string(&b, value)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

taskchain_task_summary_json :: proc(task_id, chain_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"task_id\":\"")
	write_handler_json_string(&b, task_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	write_handler_json_string(&b, chain_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// has_coordinated_by reports whether the query string carries a coordinated_by
// key (even empty), so an instance token can request "chains I coordinate" via
// ?coordinated_by (value defaults to the caller's own instance server-side).
has_coordinated_by :: proc(query: string) -> bool {
	parts := strings.split(query, "&"); defer delete(parts)
	for p in parts {
		if p == "coordinated_by" do return true
		if eq := strings.index_byte(p, '='); eq >= 0 && p[:eq] == "coordinated_by" do return true
	}
	return false
}

list_task_chains_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	// H9 R4: ?coordinated_by=<instance_id> returns the chains that agent instance
	// coordinates (single canonical source). An empty value with an instance token
	// defaults to the caller's own instance. Owner-scoped in the service.
	if has_coordinated_by(req.query) {
		coord_chains, coord_err := taskchain_service.list_chains_coordinated_by(h.taskchains, auth_ctx, query_value(req.query, "coordinated_by"))
		if coord_err.code != .None do return respond_error(coord_err, req.request_id)
		cb := strings.builder_make(); strings.write_byte(&cb, '[')
		for chain, i in coord_chains { if i > 0 do strings.write_byte(&cb, ','); write_chain_json(&cb, chain) }
		strings.write_byte(&cb, ']')
		return respond_list(strings.to_string(cb), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
	}
	chains, err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for chain, i in chains { if i > 0 do strings.write_byte(&b, ','); write_chain_json(&b, chain) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

create_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain, created, err := taskchain_service.create_chain(h.taskchains, auth_ctx, taskchain_service.Create_Chain_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), owner_user_id = json_string(req.body, "owner_user_id"), kind = json_string(req.body, "kind"), coordinator_agent_id = json_string(req.body, "coordinator_agent_id"), default_reviewer_refs_json = json_array_raw(req.body, "default_reviewer_refs")})
	if !created do return respond_error(err, req.request_id)
	if coord_agent_id := json_string(req.body, "coordinator_agent_id"); coord_agent_id != "" {
		if h.agents == nil do return respond_error(domain.domain_error(.Internal_Error, "agent service is not configured"), req.request_id)
		inst, inst_created, inst_err := agent_service.create_instance(h.agents, auth_ctx, agent_service.Create_Instance_Input{agent_id = coord_agent_id, bridge_id = json_string(req.body, "bridge_id"), provider = json_string(req.body, "provider"), tier = json_string(req.body, "tier"), project_id = domain.Project_ID(json_string(req.body, "project_id")), chain_id = string(chain.chain_id)})
		if !inst_created do return respond_error(inst_err, req.request_id)
		chain, created, err = taskchain_service.update_chain_coordinator(h.taskchains, auth_ctx, chain.chain_id, inst.agent_instance_id)
		if !created do return respond_error(err, req.request_id)
	}
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "created")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, updated, err := taskchain_service.update_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), taskchain_service.Update_Chain_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), status = json_string(req.body, "status"), coordinator_agent_instance_id = json_string(req.body, "coordinator_agent_instance_id"), has_coordinator = strings.contains(req.body, "\"coordinator_agent_instance_id\"")})
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

task_chain_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.get_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)

	tasks, _ := taskchain_service.list_tasks(h.taskchains, auth_ctx, chain.chain_id)
	members, _ := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain.chain_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain.chain_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"chain_id\":\""); write_handler_json_string(&b, string(chain.chain_id))
	strings.write_string(&b, "\",\"title\":\""); write_handler_json_string(&b, chain.title)
	strings.write_string(&b, "\",\"description\":\""); write_handler_json_string(&b, chain.description)
	strings.write_string(&b, "\",\"publish_state\":\""); write_handler_json_string(&b, publish_state_http(chain.publish_state))
	strings.write_string(&b, "\",\"status\":\""); write_handler_json_string(&b, chain_status_http(chain.status))
	strings.write_string(&b, "\",\"kind\":\""); write_handler_json_string(&b, chain.kind)
	strings.write_string(&b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(&b, chain.coordinator_agent_instance_id)
	strings.write_string(&b, "\",\"default_reviewer_refs\":"); strings.write_string(&b, json_or_empty_array(chain.default_reviewer_refs_json))
	strings.write_string(&b, ",\"created_at\":\""); write_handler_json_string(&b, chain.created_at)
	strings.write_string(&b, "\",\"updated_at\":\""); write_handler_json_string(&b, chain.updated_at)
	strings.write_string(&b, "\",\"members\":[")
	for m, i in members {
		if i > 0 do strings.write_byte(&b, ',')
		write_member_json(&b, m)
	}
	strings.write_string(&b, "],\"tasks\":[")
	for task, i in tasks {
		if i > 0 do strings.write_byte(&b, ',')
		write_task_detail_json(&b, h, auth_ctx, task, deps)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

publish_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.publish_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

complete_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.change_chain_status(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), .Completed)
	if !got do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_tasks_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if err.code != .None do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	b := strings.builder_make(); strings.write_byte(&b, '[')
	written := 0
	for task in tasks {
		if !task_matches_query(task, req.query) do continue
		if written > 0 do strings.write_byte(&b, ',')
		write_task_detail_json(&b, h, auth_ctx, task, deps)
		written += 1
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

create_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	deps := json_array_of_strings(req.body, "depends_on")
	task, created, err := taskchain_service.create_task(h.taskchains, auth_ctx, taskchain_service.Create_Task_Input{chain_id = domain.Task_Chain_ID(chain_id), title = json_string(req.body, "title"), description = json_string(req.body, "description"), owner_user_id = json_string(req.body, "owner_user_id"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), depends_on = deps})
	if !created do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "created")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	has_deps := strings.contains(req.body, "\"depends_on\"")
	deps := json_array_of_strings(req.body, "depends_on")
	has_priority := strings.contains(req.body, "\"priority\"")
	priority := domain.task_priority_from_string(json_string(req.body, "priority"))
	task, updated, err := taskchain_service.update_task(h.taskchains, auth_ctx, task_id, taskchain_service.Update_Task_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), priority = priority, has_priority = has_priority, depends_on = deps, has_depends_on = has_deps})
	if !updated do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

publish_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, got, err := taskchain_service.publish_task(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

change_task_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	status, status_ok := task_status_from_http(json_string(req.body, "status"))
	if !status_ok do return respond_error(domain.domain_error(.Validation_Failed, "invalid task status"), req.request_id)
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, status)
	if !changed do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

cancel_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, .Cancelled)
	if !changed do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

nudge_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	nudge, nudged, err := taskchain_service.manual_nudge(h.taskchains, auth_ctx, task_id, json_string(req.body, "message"))
	if !nudged do return respond_error(err, req.request_id)
	
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"task_id":"`)
	write_handler_json_string(&b, string(nudge.task_id))
	strings.write_string(&b, `","nudge_id":"`)
	write_handler_json_string(&b, nudge.nudge_id)
	strings.write_string(&b, `","delivery_state":"`)
	write_handler_json_string(&b, nudge.delivery_state)
	strings.write_string(&b, `","live_delivered":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.live_delivered))
	strings.write_string(&b, `,"durable_queued":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.durable_queued))
	strings.write_string(&b, `,"failed":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.failed))
	strings.write_string(&b, `,"target_role":"`)
	write_handler_json_string(&b, taskchain_service.target_string(nudge.target))
	strings.write_string(&b, `","created_at":"`)
	write_handler_json_string(&b, nudge.created_at)
	strings.write_string(&b, `","targets":`)
	strings.write_string(&b, nudge.targets_json)
	strings.write_string(&b, `}`)
	
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// set_task_current_task_handler lets a coordinator/user pin an agent instance's
// current task to this task (CT-9 manual override). Body: {"agent_instance_id"}.
// The service validates assignee/reviewer eligibility + actionability, persists
// the pointer, and notifies the target agent (work vs review label).
set_task_current_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	instance_id := json_string(req.body, "agent_instance_id")
	if strings.trim_space(instance_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "agent_instance_id is required"), req.request_id)
	inst, set_ok, err := taskchain_service.set_instance_current_task(h.taskchains, auth_ctx, instance_id, task_id)
	if !set_ok do return respond_error(err, req.request_id)
	publish_task_changed(h, string(inst.owner_user_id), string(task_id), string(chain_id), "current_task_set")
	publish_instance_current_task_changed(h, string(inst.owner_user_id), inst.agent_instance_id, inst.current_task_id, domain.current_task_role_string(inst.current_task_role))
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"agent_instance_id":"`)
	write_handler_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`)
	write_handler_json_string(&b, inst.current_task_id)
	strings.write_string(&b, `","current_task_role":"`)
	write_handler_json_string(&b, domain.current_task_role_string(inst.current_task_role))
	strings.write_string(&b, `"}`)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_task_comments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	comments, err := taskchain_service.list_task_comments(h.taskchains, auth_ctx, task_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for c, i in comments { if i > 0 do strings.write_byte(&b, ','); write_task_comment_json(&b, c) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

create_task_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	comment, saved, err := taskchain_service.comment_task(h.taskchains, auth_ctx, taskchain_service.Task_Comment_Input{task_id = task_id, body = json_string(req.body, "body")})
	if !saved do return respond_error(err, req.request_id)
	publish_task_changed(h, string(comment.owner_user_id), string(comment.task_id), string(comment.chain_id), "commented")
	b := strings.builder_make(); write_task_comment_json(&b, comment)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

list_task_votes_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	votes, err := taskchain_service.list_task_votes(h.taskchains, auth_ctx, task_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for v, i in votes { if i > 0 do strings.write_byte(&b, ','); write_task_vote_json(&b, v) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

vote_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	vote, recorded, err := taskchain_service.record_task_vote(h.taskchains, auth_ctx, taskchain_service.Vote_Input{task_id = task_id, vote = json_string(req.body, "vote"), comment = json_string(req.body, "comment")})
	if !recorded do return respond_error(err, req.request_id)
	publish_task_changed(h, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "voted")
	b := strings.builder_make(); write_task_vote_json(&b, vote)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

list_chain_members_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	members, err := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for m, i in members { if i > 0 do strings.write_byte(&b, ','); write_member_json(&b, m) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

add_chain_member_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	member, added, err := taskchain_service.add_chain_member(h.taskchains, auth_ctx, chain_id, json_string(req.body, "agent_instance_id"), json_string(req.body, "role"))
	if !added do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(member.owner_user_id), string(member.chain_id), "updated")
	b := strings.builder_make(); write_member_json(&b, member)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

remove_chain_member_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_instance_id := path_part(req.path, 6)
	removed, err := taskchain_service.remove_chain_member(h.taskchains, auth_ctx, chain_id, agent_instance_id)
	if !removed do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

write_chain_json :: proc(b: ^strings.Builder, c: domain.Task_Chain) {
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, c.title); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, c.description); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(c.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, chain_status_http(c.status)); strings.write_string(b, "\",\"kind\":\""); write_handler_json_string(b, c.kind); strings.write_string(b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(b, c.coordinator_agent_instance_id); strings.write_string(b, "\",\"default_reviewer_refs\":"); strings.write_string(b, json_or_empty_array(c.default_reviewer_refs_json)); strings.write_string(b, ",\"created_at\":\""); write_handler_json_string(b, c.created_at); strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, c.updated_at); strings.write_string(b, "\"}")
}

write_task_json :: proc(b: ^strings.Builder, t: domain.Task) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id)); strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, t.description); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(t.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status)); strings.write_string(b, "\",\"priority\":\""); write_handler_json_string(b, domain.task_priority_string(t.priority)); strings.write_string(b, "\",\"assignee_ref\":"); strings.write_string(b, json_or_empty_object(t.assignee_ref_json)); strings.write_string(b, ",\"reviewer_refs\":"); strings.write_string(b, json_or_empty_array(t.reviewer_refs_json)); strings.write_string(b, ",\"unblocks_dependents\":"); strings.write_string(b, "true" if domain.task_status_unblocks_dependents(t.status) else "false"); strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, t.updated_at); strings.write_string(b, "\"}")
}

write_task_detail_json :: proc(b: ^strings.Builder, h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, t: domain.Task, deps: []domain.Task_Dependency) {
	is_blocked := false
	dep_ids := make([dynamic]string)
	defer delete(dep_ids)
	for d in deps {
		if d.task_id == t.task_id {
			append(&dep_ids, string(d.depends_on_task_id))
			if parent, p_ok, _ := taskchain_service.get_task(h.taskchains, auth_ctx, d.depends_on_task_id); p_ok {
				if !domain.task_status_unblocks_dependents(parent.status) do is_blocked = true
			}
		}
	}

	comments, _ := taskchain_service.list_task_comments(h.taskchains, auth_ctx, t.task_id)
	votes, _ := taskchain_service.list_task_votes(h.taskchains, auth_ctx, t.task_id)

	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id))
	strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title)
	strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, t.description)
	strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(t.publish_state))
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status))
	strings.write_string(b, "\",\"assignee_ref\":"); strings.write_string(b, json_or_empty_object(t.assignee_ref_json))
	strings.write_string(b, ",\"reviewer_refs\":"); strings.write_string(b, json_or_empty_array(t.reviewer_refs_json))
	strings.write_string(b, ",\"blocked\":"); strings.write_string(b, "true" if is_blocked else "false")
	strings.write_string(b, ",\"unblocks_dependents\":"); strings.write_string(b, "true" if domain.task_status_unblocks_dependents(t.status) else "false")
	strings.write_string(b, ",\"depends_on\":[")
	for id, i in dep_ids {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "\""); write_handler_json_string(b, id); strings.write_string(b, "\"")
	}
	strings.write_string(b, "],\"comments\":[")
	for c, i in comments {
		if i > 0 do strings.write_byte(b, ',')
		write_task_comment_json(b, c)
	}
	strings.write_string(b, "],\"votes\":[")
	for v, i in votes {
		if i > 0 do strings.write_byte(b, ',')
		write_task_vote_json(b, v)
	}
	strings.write_string(b, "],\"created_at\":\""); write_handler_json_string(b, t.created_at)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, t.updated_at); strings.write_string(b, "\"}")
}

write_member_json :: proc(b: ^strings.Builder, m: domain.Task_Chain_Member) {
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, string(m.chain_id))
	strings.write_string(b, "\",\"agent_instance_id\":\""); write_handler_json_string(b, m.agent_instance_id)
	strings.write_string(b, "\",\"agent_id\":\""); write_handler_json_string(b, m.agent_id)
	strings.write_string(b, "\",\"role\":\""); write_handler_json_string(b, m.role)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, m.created_at)
	strings.write_string(b, "\"}")
}

write_task_vote_json :: proc(b: ^strings.Builder, v: domain.Task_Vote) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(v.task_id))
	strings.write_string(b, "\",\"reviewer_agent_instance_id\":\""); write_handler_json_string(b, v.reviewer_agent_instance_id)
	strings.write_string(b, "\",\"vote\":\""); write_handler_json_string(b, v.vote)
	strings.write_string(b, "\",\"comment\":\""); write_handler_json_string(b, v.comment)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, v.created_at)
	strings.write_string(b, "\"}")
}

write_task_comment_json :: proc(b: ^strings.Builder, c: domain.Task_Comment) {
	strings.write_string(b, "{\"comment_id\":\""); write_handler_json_string(b, c.comment_id)
	strings.write_string(b, "\",\"task_id\":\""); write_handler_json_string(b, string(c.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id))
	strings.write_string(b, "\",\"author_agent_instance_id\":\""); write_handler_json_string(b, c.author_agent_instance_id)
	strings.write_string(b, "\",\"body\":\""); write_handler_json_string(b, c.body)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\"}")
}

path_part :: proc(path: string, index: int) -> string {
	parts := strings.split(path, "/"); defer delete(parts)
	if index < 0 || index >= len(parts) do return ""
	return parts[index]
}

publish_state_http :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
chain_status_http :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; return "active" }
task_status_http :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .Queued: return "queued"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
task_status_from_http :: proc(status: string) -> (domain.Task_Status, bool) { if status == "assigned" do return .Assigned, true; if status == "queued" do return .Queued, true; if status == "in_progress" do return .In_Progress, true; if status == "in_validation" do return .In_Validation, true; if status == "validated_good" do return .Validated_Good, true; if status == "validated_not_good" do return .Validated_Not_Good, true; if status == "paused" do return .Paused, true; if status == "completed" do return .Completed, true; if status == "cancelled" do return .Cancelled, true; return .Assigned, false }


json_or_empty_array :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "[]"; return value }
json_or_empty_object :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "{}"; return value }
json_array_optional :: proc(body, key: string) -> string { start:=json_member_value_start(body,key); if start<0 do return ""; return json_array_from_value(body[start:]) }
json_object_or_empty :: proc(body, key: string) -> string { raw := json_object_raw(body, key); if strings.trim_space(raw) == "" do return ""; return raw }
json_object_raw :: proc(body, key: string) -> string { start:=json_member_value_start(body,key); if start<0 do return ""; return json_object_from_value(body[start:]) }
json_member_value_start :: proc(body,key:string)->int{ i:=0; for i<len(body){ if body[i]!='"' { i+=1; continue }; start:=i+1; j:=start; escaped:=false; for j<len(body){ ch:=body[j]; if escaped { escaped=false; j+=1; continue }; if ch=='\\' { escaped=true; j+=1; continue }; if ch=='"' do break; j+=1 }; if j>=len(body) do return -1; k:=j+1; for k<len(body)&&json_is_ws(body[k]) do k+=1; if body[start:j]==key && k<len(body) && body[k]==':' do return k+1; i=j+1 }; return -1 }
json_array_from_value :: proc(value:string)->string{ i:=0; for i<len(value)&&json_is_ws(value[i]) do i+=1; if i>=len(value)||value[i]!='[' do return "[]"; return json_balanced_from(value[i:], '[', ']') }
json_object_from_value :: proc(value:string)->string{ i:=0; for i<len(value)&&json_is_ws(value[i]) do i+=1; if i>=len(value)||value[i]!='{' do return ""; return json_balanced_from(value[i:], '{', '}') }
json_is_ws :: proc(ch: byte)->bool{ return ch==' ' || ch=='\t' || ch=='\r' || ch=='\n' }
json_balanced_from :: proc(value:string, open, close:byte)->string{ depth:=0; in_string:=false; escaped:=false; for i:=0; i<len(value); i+=1{ ch:=value[i]; if in_string { if escaped { escaped=false; continue }; if ch=='\\' { escaped=true; continue }; if ch=='"' do in_string=false; continue }; if ch=='"' { in_string=true; continue }; if ch==open do depth+=1; if ch==close { depth-=1; if depth==0 do return value[:i+1] } }; return "" }
task_matches_query :: proc(task: domain.Task, query: string) -> bool { assignee:=query_value(query,"assignee_agent_instance_id"); if assignee!="" && !strings.contains(task.assignee_ref_json, assignee) do return false; reviewer:=query_value(query,"reviewer_agent_instance_id"); if reviewer!="" && !strings.contains(task.reviewer_refs_json, reviewer) do return false; reviewer_user:=query_value(query,"reviewer_user_id"); if reviewer_user!="" && !strings.contains(task.reviewer_refs_json, reviewer_user) do return false; return true }

require_task_path_scope :: proc(h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, req: Request) -> (bool, Response) {
	task, ok, err := taskchain_service.get_task(h.taskchains, auth_ctx, task_id)
	if !ok do return false, respond_error(err, req.request_id)
	if task.chain_id != chain_id do return false, respond_error(domain.domain_error(.Not_Found, "task not found in chain"), req.request_id)
	return true, Response{}
}

json_array_of_strings :: proc(body: string, key: string) -> []domain.Task_ID {
	raw := json_array_optional(body, key)
	if raw == "" || raw == "[]" do return nil
	res := make([dynamic]domain.Task_ID)
	search := 0
	for search < len(raw) {
		q1 := strings.index_byte(raw[search:], '"')
		if q1 < 0 do break
		q2 := strings.index_byte(raw[search + q1 + 1:], '"')
		if q2 < 0 do break
		val := raw[search + q1 + 1 : search + q1 + 1 + q2]
		if val != "" do append(&res, domain.Task_ID(val))
		search = search + q1 + 1 + q2 + 1
	}
	return res[:]
}
