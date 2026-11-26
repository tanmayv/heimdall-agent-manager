#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import mcp "odin_test:hub/service/mcp"
import fleet "odin_test:hub/service/fleet_application"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import http "odin_test:hub/transport/http"
import tv2 "odin_test:hub/service/taskv2"

@(test)
test_mcp_fleet_active_claim_shared_idempotency_cancel_and_revocation :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_runtime_v2.json",string),true,fleet_mode=true)
}

@(test)
test_mcp_fleet_claim_retry_recovery_and_acknowledged_readiness :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_runtime_v2.json",string),true,fleet_mode=true,fleet_lifecycle=true)
}

// Exercise the delegated HTTP tool boundary through a real native stop/start,
// including an ambiguous launch failure. No physical Bridge or live agent runs.
mcp_fleet_lifecycle_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View) {
	g.agents.clock=&g.clock;g.agents.ids=&g.ids;g.agents.taskchains=&g.repos.taskchains
	g.agents.hooks={ctx=&g.task_engine,on_terminal=task_engine_on_instance_terminal,launch_context=task_engine_launch_context}
	sink:=MCP_Runtime_Test_Sink{g=g,view=view};defer mcp_runtime_test_sink_destroy(&sink)
	g.agents.bridge_command_sink={ctx=&sink,send_runtime_command=mcp_runtime_test_send}
	g.agents.bridge_runtime_registry=&g.bridge_runtime_registry
	defer project.bridge_runtime_registry_destroy(&g.bridge_runtime_registry)
	// Placement fixture teardown clears its live-connection projection. Restore
	// only this synthetic bridge; native offline admission must stay enforced.
	_,_,live:=project.bridge_runtime_registry_accept_live(&g.bridge_runtime_registry,"brg_placement_b",false,"",view.owner)
	if !testing.expect(t,live,"synthetic Fleet destination is live") do return
	b,_,_:=iface.bridge_get_bridge(&g.repos.bridges,"brg_placement_b")
	b.capabilities_json=`{"features":["instance_reconfiguration_v1","start_agent_v1"]}`
	_,_,_=iface.bridge_save_bridge(&g.repos.bridges,b)
	iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id=b.bridge_id,provider="claude",state="present"})
	iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id=b.bridge_id,provider="claude",enabled=true})
	g.fleet={settings=agent.fleet_service(&g.agents),agents=&g.agents,factory=&g.uow_factory,clock=&g.clock,ids=&g.ids,authority_ctx=g,authority_check=fleet_authority_check}
	entry,_,_:=iface.provider_catalog_get(&g.provider_repo,"claude")
	model:="";for candidate in entry.models do if candidate.state=="active" {model=candidate.model_id;break}
	i,_,_:=iface.agent_get_instance(&g.repos.agents,"inst_placement_b")
	i.runtime_status="running";i.startup_status="ready"
	_,_,_=iface.agent_save_instance(&g.repos.agents,i)
	_=iface.fleet_scope_set(&g.repos.bridges,i,"chain")
	before,held,_:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,i.agent_instance_id)
	if !testing.expect(t,held && before.kind==domain.LEASE_KIND_WORK) do return
	task,_,_:=iface.taskchain_get_task(&g.repos.taskchains,before.task_id)
	task.requires_user_approval=true
	_,_,_=iface.taskchain_save_task(&g.repos.taskchains,task)
	_,_,_=iface.taskchain_save_directory(&g.repos.taskchains,{directory_id="dir_fleet_mcp",chain_id=before.chain_id,owner_user_id=i.owner_user_id,bridge_id=b.bridge_id,path="/fixture/fleet",vcs_kind="git"})
	other,_,_:=iface.agent_get_instance(&g.repos.agents,"inst_placement_a")
	draft:=json.Object{"bridge_id"=json.String(b.bridge_id),"request_id"=json.String("fleet_lifecycle"),"expected_revision"=json.Integer(0),"default_runtime"=json.Object{"provider"=json.String("claude"),"model"=json.String(model)},"overrides"=json.Array{}}
	result:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.apply",draft))
	if !testing.expectf(t,result!=nil && len(sink.commands)==1,"MCP Fleet initial Apply: commands=%d result=%v",len(sink.commands),result) do return
	app_id:=result["application_id"].(json.String)
	status_args:=json.Object{"bridge_id"=json.String(b.bridge_id),"application_id"=app_id}
	stored,found,_:=iface.fleet_application_get(&g.repos.bridges,i.owner_user_id,b.bridge_id,string(app_id))
	if !testing.expect(t,found && len(stored.application.targets)==1) do return
	defer domain.fleet_application_record_destroy(&stored)
	target:=stored.application.targets[0]
	testing.expect(t,target.agent_instance_id==i.agent_instance_id && target.lease_id==before.lease_id && result["state"].(json.String)=="restarting")
	tv2.on_instance_terminal(&g.task_engine,i.agent_instance_id)
	current,stillheld,_:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,i.agent_instance_id)
	testing.expect(t,stillheld && current.lease_id==before.lease_id && current.attempt_no==before.attempt_no,"MCP Fleet stop retains active responsibility")
	// Fail the first destination send, after its generation/frame is committed.
	sink.fail=true
	op,op_found,_:=iface.instance_reconfiguration_get(&g.repos.agents,view.owner,i.agent_instance_id,target.operation_key)
	if !testing.expect(t,op_found) do return
	initial_operation_id:=strings.clone(op.operation_id,context.temp_allocator)
	initial_stop_command_id:=strings.clone(op.stop_command_id,context.temp_allocator)
	agent.apply_reconfiguration_command_result(&g.agents,b.bridge_id,op.stop_command_id,`{"status":"succeeded"}`)
	domain.instance_reconfiguration_destroy(&op)
	fleet.reconcile(&g.fleet)
	status:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.status",status_args))
	if !testing.expect(t,status!=nil && len(sink.commands)==2) do return
	testing.expect(t,status["state"].(json.String)=="partial_failure","accepted launch is not acknowledged readiness")
	launch:=sink.commands[1].body_json
	testing.expect(t,strings.contains(launch,before.lease_id) && strings.contains(launch,"/fixture/fleet/.heimdall/worktrees/") && strings.contains(launch,`"role":"worker"`),"normal launch carries same claim, worktree and role")
	after,_,_:=iface.agent_get_instance(&g.repos.agents,i.agent_instance_id)
	testing.expect(t,after.configuration_revision==i.configuration_revision+1 && after.run_count==i.run_count+1 && after.conversation_id==i.conversation_id && after.chain_id==i.chain_id && after.permission_mode==i.permission_mode)
	// Recreate only the service to model Hub recovery over the same durable DB.
	g.fleet={settings=agent.fleet_service(&g.agents),agents=&g.agents,factory=&g.uow_factory,clock=&g.clock,ids=&g.ids,authority_ctx=g,authority_check=fleet_authority_check}
	fleet.reconcile(&g.fleet)
	testing.expect_value(t,len(sink.commands),2)
	sink.fail=false
	retried:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.retry",status_args))
	if !testing.expect(t,retried!=nil && len(sink.commands)==3) do return
	testing.expect_value(t,string(retried["state"].(json.String)),"restarting")
	// Explicit native retry uses fresh delivery IDs while keeping the accepted
	// operation and runtime generation. All other launch bytes must stay equal.
	first_id,retry_id:=sink.commands[1].command_id,sink.commands[2].command_id
	testing.expect(t,first_id!=retry_id && strings.has_prefix(retry_id,"cmd_reconfig_launch_retry_"))
	normalized_launch,_:=strings.replace_all(launch,first_id,retry_id,context.temp_allocator)
	testing.expect(t,sink.commands[2].body_json==normalized_launch,"explicit retry changes only command/message IDs, preserving the entire runtime/claim/worktree payload")
	op,_,_=iface.instance_reconfiguration_get(&g.repos.agents,view.owner,i.agent_instance_id,target.operation_key)
	testing.expect(t,op.operation_id==initial_operation_id && op.idempotency_key==target.operation_key && op.launch_epoch==after.launch_epoch && op.expected_revision==i.configuration_revision && op.source_stopped && op.stop_command_id==initial_stop_command_id)
	domain.instance_reconfiguration_destroy(&op)
	retry_inst,_,_:=iface.agent_get_instance(&g.repos.agents,i.agent_instance_id)
	testing.expect(t,retry_inst.agent_instance_id==after.agent_instance_id && retry_inst.configuration_revision==after.configuration_revision && retry_inst.run_count==after.run_count && retry_inst.launch_epoch==after.launch_epoch && retry_inst.provider==after.provider && retry_inst.provider_profile==after.provider_profile && retry_inst.model==after.model && retry_inst.conversation_id==after.conversation_id && retry_inst.permission_mode==after.permission_mode)
	// A redelivery of this accepted retry command is a different operation from
	// requesting another retry: it must reuse the persisted frame byte-for-byte.
	agent.reconcile_instance_reconfigurations(&g.agents,b.bridge_id)
	testing.expect(t,len(sink.commands)==4 && sink.commands[3].command_id==retry_id && sink.commands[3].body_json==sink.commands[2].body_json,"same-command redelivery is byte-frozen and does not repeat the acknowledged source stop")
	dup:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.apply",draft))
	testing.expect(t,dup!=nil && dup["application_id"].(json.String)==app_id && len(sink.commands)==4)
	op,_,_=iface.instance_reconfiguration_get(&g.repos.agents,view.owner,i.agent_instance_id,target.operation_key)
	testing.expect(t,op.launch_epoch==after.launch_epoch && op.expected_revision==i.configuration_revision)
	domain.instance_reconfiguration_destroy(&op)
	after.runtime_status="running";after.startup_status="ready"
	_,_,_=iface.agent_save_instance(&g.repos.agents,after)
	agent.reconcile_active_reconfigurations(&g.agents);fleet.reconcile(&g.fleet)
	status=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.status",status_args))
	testing.expect(t,status!=nil && status["state"].(json.String)=="ready" && len(sink.commands)==4)
	_=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.retry",status_args))
	testing.expect_value(t,len(sink.commands),4)
	current,stillheld,_=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,i.agent_instance_id)
	testing.expect(t,stillheld && current.lease_id==before.lease_id && current.attempt_no==before.attempt_no && current.provider=="claude" && current.model==model)
	task_after,_,_:=iface.taskchain_get_task(&g.repos.taskchains,before.task_id)
	testing.expect(t,task_after.requires_user_approval && task_after.brief_json==task.brief_json && task_after.state==task.state)
	untouched,_,_:=iface.agent_get_instance(&g.repos.agents,other.agent_instance_id)
	testing.expect(t,untouched.configuration_revision==other.configuration_revision && untouched.launch_epoch==other.launch_epoch && untouched.model==other.model,"second bridge remains isolated")
	testing.expect(t,!sink.inside_transaction && len(sink.commands)==4,"only native stop/start/retry/redelivery commands; no Fleet startup settings request")
}
mcp_fleet_cancel_after_save :: proc(ctx:rawptr)->bool {n:=(^int)(ctx);n^+=1;return n^>=3}
mcp_fleet_test :: proc(t:^testing.T,g:^App_Graph,h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,view:mcp.Access_View,raw:string) {
	g.agents.clock=&g.clock;g.agents.ids=&g.ids;g.agents.taskchains=&g.repos.taskchains
	g.agents.hooks={ctx=&g.task_engine,on_terminal=task_engine_on_instance_terminal,launch_context=task_engine_launch_context}
	sink:=MCP_Runtime_Test_Sink{g=g,view=view};defer mcp_runtime_test_sink_destroy(&sink)
	g.agents.bridge_command_sink={ctx=&sink,send_runtime_command=mcp_runtime_test_send,validate_project_path=mcp_runtime_test_validate}
	g.agents.bridge_runtime_registry=&g.bridge_runtime_registry
	defer project.bridge_runtime_registry_destroy(&g.bridge_runtime_registry)
	_,_,_=project.bridge_runtime_registry_accept_live(&g.bridge_runtime_registry,"brg_placement_b",false,"",view.owner)
	b,_,_:=iface.bridge_get_bridge(&g.repos.bridges,"brg_placement_b")
	b.capabilities_json=`{"features":["instance_reconfiguration_v1","start_agent_v1"]}`;_,_,_=iface.bridge_save_bridge(&g.repos.bridges,b)
	g.fleet={settings=agent.fleet_service(&g.agents),agents=&g.agents,factory=&g.uow_factory,clock=&g.clock,ids=&g.ids,authority_ctx=g,authority_check=fleet_authority_check}
	entry,_,_:=iface.provider_catalog_get(&g.provider_repo,"claude")
	model:="";for candidate in entry.models do if candidate.state=="active" {model=candidate.model_id;break}
	iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id=b.bridge_id,provider="claude",state="present"})
	iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id=b.bridge_id,provider="claude",enabled=true})
	i,_,_:=iface.agent_get_instance(&g.repos.agents,"inst_placement_b")
	i.runtime_status="running";i.startup_status="ready";_,_,_=iface.agent_save_instance(&g.repos.agents,i)
	_=iface.fleet_scope_set(&g.repos.bridges,i,"chain")
	before,held,_:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,i.agent_instance_id)
	if !testing.expect(t,held && mcp_runtime_idle(g,i)=="active_task_lease") do return
	read:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.read",json.Object{"bridge_id"=json.String(b.bridge_id)}))
	if !testing.expect(t,read!=nil) do return
	draft:=json.Object{"bridge_id"=json.String(b.bridge_id),"request_id"=json.String("fleet_mcp"),"expected_revision"=json.Integer(0),"default_runtime"=json.Object{"provider"=json.String("claude"),"provider_profile"=json.String("claude"),"model"=json.String(model)},"overrides"=json.Array{}}
	result:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.apply",draft))
	if !testing.expect(t,result!=nil) do return
	testing.expect(t,result["settings_saved"].(json.Boolean) && result["state"].(json.String)=="restarting" && len(sink.commands)==1 && !sink.inside_transaction,"active holder is accepted through shared native post-commit flow")
	app_id:=result["application_id"].(json.String)
	dup:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.apply",draft))
	testing.expect(t,dup!=nil && dup["application_id"].(json.String)==app_id && len(sink.commands)==1)
	status:=mcp_task_test_output(t,mcp_task_test_call(h,headers,"fleet.status",json.Object{"bridge_id"=json.String(b.bridge_id),"application_id"=app_id}))
	testing.expect(t,status!=nil && len(sink.commands)==1,"status reads never dispatch")
	current,stillheld,_:=iface.taskchain_get_lease_by_holder(&g.repos.taskchains,i.agent_instance_id)
	testing.expect(t,stillheld && current.lease_id==before.lease_id && current.attempt_no==before.attempt_no)
	// The native service recognizes the MCP request without a second receipt or restart.
	copy,accepted,ce:=fleet.apply(&g.fleet,mcp.control_auth(view.owner),b.bridge_id,{request_id="fleet_mcp",default_runtime={"claude","claude",model}})
	testing.expect(t,accepted && ce.code==.None && copy.application.application_id==string(app_id) && len(sink.commands)==1)
	domain.fleet_application_record_destroy(&copy)
	// Cancellation after settings acceptance prevents NEW native target work.
	cancel_args:=mcp.Fleet_Arguments{bridge_id=b.bridge_id,draft={request_id="fleet_cancel",expected_revision=1,default_runtime={"claude","claude",model}}}
	calls:=0;text,code:=mcp_fleet_call(g,raw,view,"fleet.apply",cancel_args,&calls,mcp_fleet_cancel_after_save)
	cancelled:domain.Fleet_Application
	json.unmarshal_string(text,&cancelled,.JSON,context.temp_allocator)
	testing.expect(t,code=="" && cancelled.settings_saved && cancelled.cancelled && len(sink.commands)==1)
	// Revoke while the native project preflight is waiting. Its final acceptance
	// guard must prevent the stop; no raw credential may be persisted for recovery.
	_,_,_=iface.project_save(&g.repos.projects,{project_id="proj_fleet",owner_user_id=domain.User_ID(view.owner),name="Fixture",slug="fixture",default_path="/workspace",state=.Active})
	_,_,_=iface.project_save_bridge_path(&g.repos.projects,{project_id="proj_fleet",bridge_id=b.bridge_id,owner_user_id=domain.User_ID(view.owner),path="/workspace"})
	_,_,_=iface.agent_save_instance(&g.repos.agents,{agent_instance_id="inst_fleet_revoke",owner_user_id=domain.User_ID(view.owner),agent_id=i.agent_id,bridge_id=b.bridge_id,project_id="proj_fleet",project_path="/workspace",provider=i.provider,provider_profile=i.provider_profile,model=i.model,runtime_status="running",startup_status="ready"})
	fresh,_,_:=iface.agent_get_instance(&g.repos.agents,"inst_fleet_revoke");_=iface.fleet_scope_set(&g.repos.bridges,fresh,"chain")
	sink.revoke=true
	revoke_args:=cancel_args;revoke_args.draft.request_id="fleet_revoke"
	text,code=mcp_fleet_call(g,raw,view,"fleet.apply",revoke_args,nil,nil)
	revoked:domain.Fleet_Application;json.unmarshal_string(text,&revoked,.JSON,context.temp_allocator)
	testing.expect(t,code=="" && revoked.settings_saved && len(sink.commands)==1,"revocation in preflight refuses native acceptance")
	stored,found,_:=iface.fleet_application_get(&g.repos.bridges,domain.User_ID(view.owner),b.bridge_id,revoked.application_id)
	if testing.expect(t,found) {testing.expect(t,stored.authority_json!="" && !strings.contains(stored.authority_json,"mcp1."));domain.fleet_application_record_destroy(&stored)}
	fleet.reconcile(&g.fleet)
	testing.expect_value(t,len(sink.commands),1)
	_,replay_code:=mcp_fleet_call(g,raw,view,"fleet.apply",revoke_args,nil,nil)
	testing.expect_value(t,replay_code,"invalid_token")
}
