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

@(test)
test_mcp_fleet_active_claim_shared_idempotency_cancel_and_revocation :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_runtime_v2.json",string),true,fleet_mode=true)
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
