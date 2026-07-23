package http

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import taskchain_service "odin_test:hub/service/taskchain"

Taskchain_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	agents: ^agent_service.Agent_Service,
}

list_task_chains_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chains, err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for chain, i in chains { if i > 0 do strings.write_byte(&b, ','); write_chain_json(&b, chain) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

create_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain, created, err := taskchain_service.create_chain(h.taskchains, auth_ctx, taskchain_service.Create_Chain_Input{title = json_string(req.body, "title"), owner_user_id = json_string(req.body, "owner_user_id"), kind = json_string(req.body, "kind"), coordinator_agent_id = json_string(req.body, "coordinator_agent_id"), default_reviewer_refs_json = json_array_raw(req.body, "default_reviewer_refs")})
	if !created do return respond_error(err, req.request_id)
	if coord_agent_id := json_string(req.body, "coordinator_agent_id"); coord_agent_id != "" {
		if h.agents == nil do return respond_error(domain.domain_error(.Internal_Error, "agent service is not configured"), req.request_id)
		inst, inst_created, inst_err := agent_service.create_instance(h.agents, auth_ctx, agent_service.Create_Instance_Input{agent_id = coord_agent_id, bridge_id = json_string(req.body, "bridge_id"), provider = json_string(req.body, "provider"), tier = json_string(req.body, "tier"), project_id = domain.Project_ID(json_string(req.body, "project_id")), chain_id = string(chain.chain_id)})
		if !inst_created do return respond_error(inst_err, req.request_id)
		chain, created, err = taskchain_service.update_chain_coordinator(h.taskchains, auth_ctx, chain.chain_id, inst.agent_instance_id)
		if !created do return respond_error(err, req.request_id)
	}
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

task_chain_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.get_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

publish_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.publish_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

complete_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.change_chain_status(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), .Completed)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_tasks_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	written := 0
	for task in tasks { if !task_matches_query(task, req.query) do continue; if written > 0 do strings.write_byte(&b, ','); write_task_json(&b, task); written += 1 }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

create_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	task, created, err := taskchain_service.create_task(h.taskchains, auth_ctx, taskchain_service.Create_Task_Input{chain_id = domain.Task_Chain_ID(chain_id), title = json_string(req.body, "title"), owner_user_id = json_string(req.body, "owner_user_id"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs")})
	if !created do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

publish_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, got, err := taskchain_service.publish_task(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

change_task_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	status, status_ok := task_status_from_http(json_string(req.body, "status"))
	if !status_ok do return respond_error(domain.domain_error(.Validation_Failed, "invalid task status"), req.request_id)
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, status)
	if !changed do return respond_error(err, req.request_id)
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

nudge_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	nudge, nudged, err := taskchain_service.manual_nudge(h.taskchains, auth_ctx, task_id, json_string(req.body, "message"))
	if !nudged do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"task_id\":\""); write_handler_json_string(&b, string(nudge.task_id)); strings.write_string(&b, "\",\"nudged\":true,\"target\":\""); write_handler_json_string(&b, nudge_target_string(nudge.target)); strings.write_string(&b, "\",\"created_at\":\""); write_handler_json_string(&b, nudge.created_at); strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

require_task_path_scope :: proc(h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, req: Request) -> (bool, Response) {
	task, ok, err := taskchain_service.get_task(h.taskchains, auth_ctx, task_id)
	if !ok do return false, respond_error(err, req.request_id)
	if task.chain_id != chain_id do return false, respond_error(domain.domain_error(.Not_Found, "task not found in chain"), req.request_id)
	return true, Response{}
}

write_chain_json :: proc(b: ^strings.Builder, c: domain.Task_Chain) {
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, c.title); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(c.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, chain_status_http(c.status)); strings.write_string(b, "\",\"kind\":\""); write_handler_json_string(b, c.kind); strings.write_string(b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(b, c.coordinator_agent_instance_id); strings.write_string(b, "\",\"default_reviewer_refs\":"); strings.write_string(b, json_or_empty_array(c.default_reviewer_refs_json)); strings.write_string(b, ",\"created_at\":\""); write_handler_json_string(b, c.created_at); strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, c.updated_at); strings.write_string(b, "\"}")
}

write_task_json :: proc(b: ^strings.Builder, t: domain.Task) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id)); strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(t.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status)); strings.write_string(b, "\",\"assignee_ref\":"); strings.write_string(b, json_or_empty_object(t.assignee_ref_json)); strings.write_string(b, ",\"reviewer_refs\":"); strings.write_string(b, json_or_empty_array(t.reviewer_refs_json)); strings.write_string(b, ",\"unblocks_dependents\":"); strings.write_string(b, "true" if domain.task_status_unblocks_dependents(t.status) else "false"); strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, t.updated_at); strings.write_string(b, "\"}")
}

path_part :: proc(path: string, index: int) -> string {
	parts := strings.split(path, "/"); defer delete(parts)
	if index < 0 || index >= len(parts) do return ""
	return parts[index]
}

publish_state_http :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
chain_status_http :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; return "active" }
task_status_http :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
task_status_from_http :: proc(status: string) -> (domain.Task_Status, bool) { if status == "assigned" do return .Assigned, true; if status == "in_progress" do return .In_Progress, true; if status == "in_validation" do return .In_Validation, true; if status == "validated_good" do return .Validated_Good, true; if status == "validated_not_good" do return .Validated_Not_Good, true; if status == "paused" do return .Paused, true; if status == "completed" do return .Completed, true; if status == "cancelled" do return .Cancelled, true; return .Assigned, false }
nudge_target_string :: proc(target: taskchain_service.Nudge_Target) -> string { switch target { case .Assignee: return "assignee"; case .Reviewer: return "reviewer"; case .Coordinator: return "coordinator"; case .None: return "none" }; return "none" }

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
