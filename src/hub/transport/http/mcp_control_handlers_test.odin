package http

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:net"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import auth "odin_test:hub/service/auth"
import events "odin_test:hub/service/events"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

MCP_Control_Fixture :: struct {
	base:^MCP_Test_Fixture,
	state:MCP_HTTP_State,
	impl:sqlite.MCP_Repo_SQLite,
	repo:iface.MCP_Repository,
	keys:[1]mcp.Envelope_Key,
	service:mcp.Delegation_Service,
	vrepo:iface.Vault_Directory_Repository,
	directory:vd.Service,
	ids:platform.ID_Generator,
	delegation:MCP_Delegation_Handlers,
	h:MCP_Control_Handlers,
	bus:events.User_Event_Bus,
	token:string,
}
mcp_control_fixture :: proc(t:^testing.T,use_device:=false)->^MCP_Control_Fixture {
	f:=new(MCP_Control_Fixture,context.temp_allocator)
	f.base=mcp_test_fixture(t)
	vectors:struct {alice:struct {initial:MCP_HTTP_Vector,content:json.Object}}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_hosted_v1.json",string),&vectors,.JSON,context.temp_allocator)==nil)
	f.state.vector=vectors.alice.initial
	if use_device {
		device:struct {initial:MCP_HTTP_Vector,job:vault.Control_Job}
		testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&device,.JSON,context.temp_allocator)==nil)
		f.state.vector=device.initial
		payload:mcp.Control_Data
		testing.expect(t,json.unmarshal_string(device.job.payload,&payload,.JSON,context.temp_allocator)==nil)
		vectors.alice.content=payload.chain
	}
	v:=&f.state.vector
	_,saved,_:=iface.user_save(&f.base.user_repo,domain.User{user_id=domain.User_ID(v.request.owner),name=v.request.owner,status=.Active,created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	testing.expect(t,saved)
	repo,err:=sqlite.open_mcp_repository(&f.impl,":memory:");f.repo=repo
	testing.expect(t,err.code==.None)
	migrated,_:=sqlite.run_migrations(&f.impl.conn);testing.expect(t,migrated)
	ui:sqlite.User_Repo_SQLite
	ur:=sqlite.new_user_repository(&ui,&f.impl.conn)
	for owner in ([]string{v.request.owner,"alice"}) {
		_,user_ok,_:=iface.user_save(&ur,{user_id=domain.User_ID(owner),name=owner,status=.Active,created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
		testing.expect(t,user_ok)
	}
	testing.expect(t,iface.mcp_transaction(&f.repo,mcp_http_seed,&f.state).code==.None)
	f.keys[0].id="control-test";f.keys[0].bytes[0]=7
	f.service={repo=&f.repo,keys=f.keys[:],issuer="https://hub.example",resource=v.request.resource,clock=&f.base.clock,authority=proc(ctx:rawptr,g:domain.MCP_Record)->(bool,domain.Domain_Error){return true,{}}}
	f.vrepo={ctx=&f.state,get_directory=mcp_http_directory,list_devices=mcp_http_devices,list_log=mcp_http_log}
	f.directory=vd.new_service(&f.vrepo,&f.base.clock)
	f.delegation={auth=&f.base.auth,directory=&f.directory,grant_directory=&f.directory,service=&f.service,origin=f.service.issuer}
	code,_,_,cerr:=mcp.delegation_consent(&f.service,&f.directory,v.request.owner,v.directory.root_device_id,v.hosted,v.now_ms)
	testing.expect(t,cerr.code==.None)
	token_result:=mcp.delegation_redeem(&f.service,code,"code",v.request.client,v.request.redirect,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",v.now_ms)
	tokens:mcp.Tokens
	testing.expect(t,token_result.error=="" && json.unmarshal_string(token_result.response,&tokens,.JSON,context.temp_allocator)==nil)
	f.token=tokens.access_token
	f.ids=platform.real_id_generator()
	f.h={delegation=&f.delegation,bus=&f.bus}
	return f
}
mcp_control_close :: proc(f:^MCP_Control_Fixture) {mcp.worker_registrations_free(&f.h.registrations);vd.service_free(&f.directory);sqlite.close(&f.impl.conn);sqlite.close(&f.base.conn)}
mcp_control_request :: proc(h:^MCP_Control_Handlers,token,body:string)->Response {
	headers:=[]contracts.HTTP_Header{{"Authorization",mcp_join("Bearer ",token)},{"Content-Type","application/json"}}
	return mcp_control_handler(h,{method="POST",path=MCP_PATH,body=strings.clone(body,context.temp_allocator),headers=headers})
}
@(test)
test_mcp_control_hosted_four_tools_ownership_creation_and_stateless_restart :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	mcp_resource_legacy_assertions(t,f)
	init:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`)
	testing.expect(t,init.status==200 && strings.contains(init.body,"2025-06-18"))
	list:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	testing.expect(t,list.status==200 && !strings.contains(list.body,"chains.") && !strings.contains(list.body,"tasks.") && !strings.contains(list.body,"events.wait") && !strings.contains(list.body,"lease.next"))
	// Hub task chains are removed: every former chain/task tool, and events.wait,
	// answers the typed refusal before argument parsing or scope checks.
	for call in ([]string{
		`{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"chains.get","arguments":{"chain_id":"chain_fixture"}}}`,
		`{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"chains.list","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"chains.create","arguments":{"title":"x","coordinator_agent_id":"agt_fixture","bridge_id":"brg_fixture"}}}`,
		`{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"chains.message","arguments":{"chain_id":"chain_fixture","request_id":"r","body":"hi"}}}`,
		`{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"chains.configure","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"tasks.get","arguments":{"chain_id":"chain_fixture","task_id":"task_fixture"}}}`,
		`{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"tasks.create","arguments":{"chain_id":"chain_fixture","request_id":"r","title":"t","goal":"g","acceptance":["a"]}}}`,
		`{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"events.wait","arguments":{"chain_id":"chain_fixture"}}}`,
	}) {
		resp:=mcp_control_request(&f.h,f.token,call)
		testing.expectf(t,resp.status==200 && strings.contains(resp.body,"hub_chains_removed") && strings.contains(resp.body,`"isError":true`),"chain tool: %s",resp.body)
	}
	for call in ([]string{
		`{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"agents.list","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"instances.list","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"bridges.list","arguments":{}}}`,
	}) {
		testing.expect(t,strings.contains(mcp_control_request(&f.h,f.token,call).body,"scope_missing"))
	}
	unauthorized:=mcp_control_request(&f.h,"hut_wrong",`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	testing.expect(t,unauthorized.status==401)
	// The challenge advertises every supported scope so spec-following clients
	// request (and the consent page offers) all capabilities.
	testing.expect_value(t,header_value(unauthorized.headers,"WWW-Authenticate"),mcp_join("Bearer resource_metadata=\"",f.delegation.origin,"/.well-known/oauth-protected-resource/api/v1/mcp\", scope=\"",strings.join(mcp.supported_scopes()," ",context.temp_allocator),"\""))
	testing.expect(t,strings.contains(header_value(unauthorized.headers,"WWW-Authenticate"),"scope=\"mcp:chains mcp:tasks:read "))
}
@(test)
test_mcp_control_rpc_grammar_and_device_reply_binding :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	disabled:MCP_Control_Handlers
	mcp_bridge_result(&Bridge_Handlers{mcp_control=&disabled},"brg_disabled",strings.clone("{}",context.temp_allocator),1)
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	for body in ([]string{`[]`,`{"jsonrpc":"2.0","id":true,"method":"tools/list"}`,`{"jsonrpc":"2.0","id":1,"method":"tools/list"} trailing`}) {
		resp:=mcp_control_request(&f.h,f.token,body);testing.expect(t,strings.contains(resp.body,"error"))
	}
	v:struct {now_ms:i64,device_id,bridge_device_id:string,job:vault.Control_Job,reply,bridge_reply:vault.Control_Reply}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&v,.JSON,context.temp_allocator)==nil)
	testing.expect(t,mcp_verify_reply(v.job,v.reply,v.device_id,v.now_ms))
	testing.expect(t,mcp_verify_reply(v.job,v.bridge_reply,v.bridge_device_id,v.now_ms))
	bad:=v.reply;bad.result="tampered";testing.expect(t,!mcp_verify_reply(v.job,bad,v.device_id,v.now_ms))
	bad=v.reply;bad.generation="late";testing.expect(t,!mcp_verify_reply(v.job,bad,v.device_id,v.now_ms))
	testing.expect(t,!mcp_verify_reply(v.job,v.reply,v.bridge_device_id,v.now_ms))
	testing.expect(t,!mcp_verify_reply(v.job,v.reply,v.device_id,v.job.deadline_ms))
}

@(test)
test_mcp_control_browser_worker_requires_signed_device_and_bound_reply :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t,true);defer mcp_control_close(f)
	v:struct {job:vault.Control_Job,reply:vault.Control_Reply,get_jobs_headers,post_jobs_headers:map[string]string,post_body:string}
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_worker_v1.json",string),&v,.JSON,context.temp_allocator)==nil)
	testing.expect(t,mcp.worker_begin(&f.h.workers,v.job));defer mcp.worker_end(&f.h.workers,v.job.request_id,v.job.generation)
	cookie:=http_test_login_cookie(t,&f.base.auth,v.job.owner)
	testing.expect(t,mcp.worker_register(&f.h.registrations,v.job.owner,v.reply.device_id,"tab_fixture",true,v.job.deadline_ms+1000,1793430000000))
	unsigned:=mcp_worker_handler(&f.h,{method="GET",path=MCP_OAUTH+"/jobs",headers=mcp_http_headers(cookie,nil,f.delegation.origin)})
	testing.expect(t,unsigned.status!=200)
	get:=mcp_worker_handler(&f.h,{method="GET",path=MCP_OAUTH+"/jobs",query="generation=tab_fixture",headers=mcp_http_headers(cookie,v.get_jobs_headers,f.delegation.origin)})
	testing.expect(t,get.status==200 && get.sensitive && strings.contains(get.body,v.job.request_id) && !strings.contains(get.body,"private_capability") && !strings.contains(get.body,"mcp1."))
	post:=mcp_worker_handler(&f.h,{method="POST",path=MCP_OAUTH+"/jobs",query="generation=tab_fixture",body=strings.clone(v.post_body,context.temp_allocator),headers=mcp_http_headers(cookie,v.post_jobs_headers,f.delegation.origin)})
	testing.expectf(t,post.status==200,"signed worker reply status %d",post.status)
	result,done:=mcp.worker_result(&f.h.workers,v.job.request_id,v.job.generation)
	testing.expect(t,done && strings.contains(result,"worker secret title"))
	testing.expect(t,mcp.public_job_live(&f.service,&f.directory,v.job))
	testing.expect(t,mcp.delegation_revoke(&f.service,v.job.owner,v.job.grant).code==.None)
	testing.expect(t,!mcp.public_job_live(&f.service,&f.directory,v.job))
}

mcp_large_body :: proc(prefix,suffix:string)->string {
	pad:=strings.repeat("x",MCP_CONTROL_MAX_BODY_BYTES+1024,context.temp_allocator)
	return strings.concatenate({prefix,pad,suffix},context.temp_allocator)
}
// Bodies over 512 KiB that are not an artifacts.create bundle are refused with
// -32602 and never reach a single-value type assertion (which would panic the Hub).
@(test)
test_mcp_control_large_body_non_bundle_shapes_are_refused_without_panic :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=mcp_control_fixture(t);defer mcp_control_close(f)
	bodies:=[]string{
		// (a) no arguments at all (passes the substring pre-gate via params.files)
		mcp_large_body(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"artifacts.create","files":{},"pad":"`,`"}}`),
		// (b) arguments is a string
		mcp_large_body(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"artifacts.create","arguments":"x","files":{},"pad":"`,`"}}`),
		// (c) another tool carrying a files object
		mcp_large_body(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tasks.get","arguments":{"files":{}},"tag":"artifacts.create","pad":"`,`"}}`),
		// (d) artifacts.create without files in arguments
		mcp_large_body(`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"artifacts.create","arguments":{"request_id":"r","name":"n"},"files":0,"pad":"`,`"}}`),
		// (e) arguments.files is not an object
		mcp_large_body(`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"artifacts.create","arguments":{"files":"x"},"pad":"`,`"}}`),
		// (f) name is a huge string: refused by the pre-parse gate
		mcp_large_body(`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"`,`"}}`),
		// (g) non-call method over 512 KiB: refused by the pre-parse gate
		mcp_large_body(`{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"pad":"`,`"}}`),
	}
	for body,i in bodies {
		resp:=mcp_control_request(&f.h,f.token,body)
		testing.expectf(t,resp.status==200 && strings.contains(resp.body,"-32602") && strings.contains(resp.body,"request_too_large"),"case %d: %d %s",i,resp.status,resp.body)
	}
	// A small call with non-object arguments is still the ordinary invalid-arguments error.
	small:=mcp_control_request(&f.h,f.token,`{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"artifacts.create","arguments":"x"}}`)
	testing.expectf(t,strings.contains(small.body,"-32602"),"small: %s",small.body)
}
// The Anthropic Messages API rejects input_schema with oneOf/allOf/anyOf (and not)
// at the top level; claude.ai passes MCP tool schemas through to it.
@(test)
test_mcp_tools_catalog_has_no_top_level_schema_combinators :: proc(t:^testing.T) {
	tools,err:=json.parse_string(#load("mcp_tools.json",string),parse_integers=true,allocator=context.temp_allocator)
	testing.expect(t,err==nil)
	catalog,_:=tools.(json.Array)
	testing.expect(t,len(catalog)>0)
	for value in catalog {
		tool,_:=value.(json.Object)
		name,_:=tool["name"].(json.String)
		schema,typed:=tool["inputSchema"].(json.Object)
		testing.expectf(t,typed,"%s: inputSchema missing",name)
		for key in ([]string{"oneOf","anyOf","allOf","not","if","then","else"}) {
			_,present:=schema[key]
			testing.expectf(t,!present,"%s: top-level %s in inputSchema",name,key)
		}
		kind,_:=schema["type"].(json.String)
		testing.expectf(t,string(kind)=="object","%s: inputSchema type %s",name,kind)
	}
}
