#+feature dynamic-literals
package app

import "core:encoding/json"
import "core:testing"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import mcp "odin_test:hub/service/mcp"
import auth "odin_test:hub/service/auth"
import vault "odin_test:lib/vault"
import vd "odin_test:hub/service/vault_directory"
import http "odin_test:hub/transport/http"
import contracts "odin_test:contracts"

MCP_Task_Test_Vector :: struct {
	now_ms:i64,
	request:struct {owner,client,redirect,resource,scope,grant,family:string,revision,expires_ms:i64},
	directory:struct {version,current_epoch:i64,root_device_id,head_hash:string,devices:[]struct {device_id,kind,sign_alg,wrap_alg,sign_public_key,ecdh_public_key:string},log:[]struct {seq:i64,statement:string,signature:struct {alg,sig:string}}},
	hosted:mcp.Consent_Input,
}
mcp_task_test_seed :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	v:=(^MCP_Task_Test_Vector)(ctx)
	if err:=tx.put(tx.ctx,{kind="client",id=v.request.client,redirect=v.request.redirect});err.code!=.None do return err
	return tx.put(tx.ctx,{kind="pending",id=auth.sha256_hex(v.hosted.request),owner=v.request.owner,client=v.request.client,redirect=v.request.redirect,resource=v.request.resource,scope=v.request.scope,grant=v.request.grant,family=v.request.family,revision=1,created_ms=v.now_ms,expires_ms=v.request.expires_ms,challenge=auth.pkce_challenge_s256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")})
}
mcp_task_test_now :: proc(ctx:rawptr)->string {return "2026-10-31T07:00:00Z"}

mcp_task_test_call :: proc(h:^http.MCP_Control_Handlers,headers:[]contracts.HTTP_Header,tool:string,input:json.Object)->http.Response {
	args:=input
	encoded,_:=json.marshal(struct {jsonrpc:string,id:int,method:string,params:struct {name:string,arguments:json.Object}}{"2.0",1,"tools/call",{tool,args}},allocator=context.temp_allocator)
	return http.mcp_control_handler(h,{method="POST",path="/api/v1/mcp",headers=headers,body=string(encoded)})
}
mcp_task_test_output :: proc(t:^testing.T,response:http.Response,loc:=#caller_location)->json.Object {
	outer:struct {result:struct {content:[]struct {text:string},isError:bool}}
	if !testing.expectf(t,json.unmarshal_string(response.body,&outer,.JSON,context.temp_allocator)==nil && !outer.result.isError && len(outer.result.content)==1,"MCP result: %s",response.body,loc=loc) do return nil
	value,err:=json.parse_string(outer.result.content[0].text,parse_integers=true,allocator=context.temp_allocator)
	obj,typed:=value.(json.Object)
	testing.expect(t,err==nil && typed)
	return obj
}

MCP_Task_Attention_Probe :: struct {factory:^iface.Unit_Of_Work_Factory,notices:int,inside_transaction:bool}
mcp_task_attention_probe :: proc(ctx:rawptr,owner,kind,id:string) {
	p:=(^MCP_Task_Attention_Probe)(ctx)
	uow,ok,_:=iface.unit_of_work_begin(p.factory)
	if !ok {p.inside_transaction=true;return}
	p.inside_transaction=p.inside_transaction || uow.nested
	p.notices+=1
	iface.unit_of_work_rollback(&uow)
}

@(test)
test_mcp_catalog_native_crud_targets_scopes_and_retries :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_catalog_v2.json",string),true)
}

@(test)
test_mcp_runtime_native_lifecycle_intents_and_moves :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_runtime_v2.json",string),true,true)
}

@(test)
test_mcp_resource_native_lifecycle_approval_paging_and_retries :: proc(t:^testing.T) {
	mcp_task_test_fixture(t,#load("../../../tests/fixtures/mcp_resources_v2.json",string),true,false,true)
}

// Hosted MCP fixture (synthetic vault directory, consented grant, live access
// view) for the catalog, runtime, resource and artifact write tools.
mcp_task_test_fixture :: proc(t:^testing.T,vector:string,catalog:bool,runtime:bool=false,resources:bool=false,artifacts:bool=false) {
	context.allocator=context.temp_allocator
	g:=new(App_Graph,context.temp_allocator)
	v:MCP_Task_Test_Vector
	if !testing.expect(t,json.unmarshal_string(vector,&v,.JSON,context.temp_allocator)==nil) do return
	repo,rerr:=sqlite.open_mcp_repository(&g.mcp_repository_impl,":memory:")
	if !testing.expect(t,rerr.code==.None) do return
	defer sqlite.close(&g.mcp_repository_impl.conn)
	g.mcp_repository=repo;g.db=g.mcp_repository_impl.conn
	upgraded,uerr:=sqlite.run_migrations(&g.db)
	if !testing.expect(t,upgraded && uerr.code==.None) do return
	g.clock={now=mcp_task_test_now};g.ids=platform.real_id_generator()
	ui:sqlite.User_Repo_SQLite
	ur:=sqlite.new_user_repository(&ui,&g.db)
	g.repos.users=ur
	_,saved,_:=iface.user_save(&ur,{user_id=domain.User_ID(v.request.owner),status=.Active,name="Synthetic MCP task test"})
	testing.expect(t,saved)
	vi:sqlite.Vault_Directory_Repo_SQLite
	vr:=sqlite.new_vault_directory_repository(&vi,&g.db)
	root:=v.directory.devices[0];log:=v.directory.log[0]
	sig,_:=vault.signature_text_from_parts(log.signature.alg,log.signature.sig,context.temp_allocator)
	now:=mcp_task_test_now(nil)
	genesis:=domain.Vault_Genesis{
		directory={user_id=v.request.owner,version=1,current_epoch=1,root_device_id=root.device_id,head_hash=v.directory.head_hash,genesis_statement=log.statement,genesis_signature=sig,created_at=now,updated_at=now},
		device={user_id=v.request.owner,device_id=root.device_id,kind=root.kind,sign_alg=root.sign_alg,wrap_alg=root.wrap_alg,sign_public_key=root.sign_public_key,ecdh_public_key=root.ecdh_public_key,status=.Approved,created_at=now,approved_at=now},
		epoch={user_id=v.request.owner,epoch=1,statement=log.statement,signature=sig,created_at=now},
		log={user_id=v.request.owner,seq=1,statement=log.statement,signature=sig,entry_hash=v.directory.head_hash,created_at=now},
		wrap={user_id=v.request.owner,device_id=root.device_id,directory_version=1,current_epoch=1,wrap_json="{}",updated_at=now},
	}
	if !testing.expect(t,iface.vault_create_genesis(&vr,genesis).code==.None) do return
	directory:=vd.Service{repo=&vr,clock=&g.clock}
	authority:=MCP_Task_Authority{conn=&g.db,directory=&directory}
	keys:[1]mcp.Envelope_Key;keys[0].id="synthetic";keys[0].bytes[0]=7
	g.mcp_delegation={repo=&g.mcp_repository,keys=keys[:],clock=&g.clock,issuer="https://hub.example",resource=v.request.resource,authority=mcp_task_authority,authority_ctx=&authority}
	testing.expect(t,iface.mcp_transaction(&g.mcp_repository,mcp_task_test_seed,&v).code==.None)
	code,_,_,cerr:=mcp.delegation_consent(&g.mcp_delegation,&directory,v.request.owner,root.device_id,v.hosted,v.now_ms)
	if !testing.expectf(t,cerr.code==.None,"consent: %s",cerr.message) do return
	tokens:=mcp.delegation_redeem(&g.mcp_delegation,code,"code",v.request.client,v.request.redirect,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",v.now_ms)
	var_tokens:mcp.Tokens
	if !testing.expect(t,tokens.error=="" && json.unmarshal_string(tokens.response,&var_tokens,.JSON,context.temp_allocator)==nil) do return
	view,live:=mcp.access_view(&g.mcp_delegation,&directory,var_tokens.access_token)
	if !testing.expect(t,live) do return
	g.repos.taskchains=sqlite.new_taskchain_repository(&g.sqlite_taskchains,&g.db)
	g.uow_factory=sqlite.new_unit_of_work_factory(&g.sqlite_uow_factory,&g.db,&g.repos)
	delegation:=http.MCP_Delegation_Handlers{service=&g.mcp_delegation,directory=&directory,grant_directory=&directory,origin=g.mcp_delegation.issuer}
	h:=http.MCP_Control_Handlers{delegation=&delegation,create_ctx=g}
	headers:=[]contracts.HTTP_Header{{"Authorization",strings.concatenate({"Bearer ",var_tokens.access_token},context.temp_allocator)},{"Content-Type","application/json"}}
	if !catalog do return
	mcp_task_test_machines(t,g,view)
	h.control.agents=&g.agents;h.control.bridges=&g.repos.bridges;h.control.providers=&g.providers;h.mutate_catalog=mcp_mutate_catalog
	if artifacts {mcp_artifact_test(t,g,&h,headers,view,var_tokens.access_token);return}
	if resources {mcp_resource_test(t,g,&h,headers,view,var_tokens.access_token);return}
	if runtime {h.runtime=mcp_runtime_call;mcp_runtime_test(t,g,&h,headers,view,var_tokens.access_token);return}
	mcp_catalog_test(t,g,&h,headers,view,var_tokens.access_token)
}

// Synthetic agent, machines and running instances the catalog, runtime and
// resource write tests target (formerly seeded by the removed chain-placement
// test, which then configured a Hub chain fleet on them).
mcp_task_test_machines :: proc(t:^testing.T,g:^App_Graph,view:mcp.Access_View) {
	now:=mcp_task_test_now(nil)
	g.repos.agents=sqlite.new_agent_repository(&g.sqlite_agents,&g.db)
	g.repos.bridges=sqlite.new_bridge_repository(&g.sqlite_bridges,&g.db)
	g.provider_repo=sqlite.new_provider_repository(&g.sqlite_providers,&g.db)
	g.agents.agents=&g.repos.agents;g.agents.bridges=&g.repos.bridges;g.agents.providers=&g.provider_repo
	owner:=domain.User_ID(view.owner)
	// The chains these tools reference are Bridge-owned: owner-registry routes.
	for chain in ([]string{"chain_placement","chain_comment"}) {
		testing.expect(t,sqlite.exec(&g.db,strings.concatenate({"INSERT INTO owner_local_chains VALUES('",chain,"','",view.owner,"','brg_placement_a','key_placement','dev_placement','",strings.repeat("0",64,context.temp_allocator),"','{}')"},context.temp_allocator)))
	}
	_,ok,_:=iface.agent_save(&g.repos.agents,{agent_id="agt_placement",owner_user_id=owner,name="Synthetic placement",slug="synthetic-placement",template_id=domain.TEMPLATE_EMPTY_ID,state=.Active,created_at=now,updated_at=now})
	if !testing.expect(t,ok) do return
	entry,known,err:=iface.provider_catalog_get(&g.provider_repo,"codex")
	if !testing.expect(t,known && err.code==.None && len(entry.models)>0) do return
	defer domain.provider_catalog_entry_destroy(entry)
	model:=entry.models[0].model_id
	for bridge in ([]string{"brg_placement_a","brg_placement_b","brg_placement_offline"}) {
		status:=domain.Bridge_Status.Online;if bridge=="brg_placement_offline" do status=.Offline
		_,saved,_:=iface.bridge_save_bridge(&g.repos.bridges,{bridge_id=bridge,owner_user_id=owner,label=bridge,status=status,created_at=now,updated_at=now})
		testing.expect(t,saved)
		status_ok,_:=iface.bridge_provider_status_upsert(&g.provider_repo,{bridge_id=bridge,provider="codex",state="present",checked_at=now})
		setting_ok,_:=iface.bridge_provider_setting_upsert(&g.provider_repo,{bridge_id=bridge,provider="codex",enabled=true,updated_at=now})
		testing.expect(t,status_ok && setting_ok)
	}
	foreign_owner:=domain.User_ID("foreign_owner")
	_,user_ok,_:=iface.user_save(&g.repos.users,{user_id=foreign_owner,name="Synthetic foreign owner",status=.Active})
	testing.expect(t,user_ok)
	_,foreign_saved,_:=iface.bridge_save_bridge(&g.repos.bridges,{bridge_id="brg_placement_foreign",owner_user_id=foreign_owner,label="Synthetic foreign bridge",status=.Online,created_at=now,updated_at=now})
	testing.expect(t,foreign_saved)
	for bridge in ([]string{"brg_placement_a","brg_placement_b"}) {
		instance:="inst_placement_a";if bridge=="brg_placement_b" do instance="inst_placement_b"
		_,instance_ok,_:=iface.agent_save_instance(&g.repos.agents,{agent_instance_id=instance,owner_user_id=owner,agent_id="agt_placement",bridge_id=bridge,display_name=instance,provider="codex",model=model,chain_id="chain_placement",runtime_status="running",activity_status="idle",created_at=now,updated_at=now,last_seen_at=now})
		testing.expect(t,instance_ok)
	}
}
