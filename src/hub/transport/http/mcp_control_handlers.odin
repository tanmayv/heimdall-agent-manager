#+feature dynamic-literals
package http

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import events "odin_test:hub/service/events"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

MCP_Control_Handlers :: struct {
	delegation:^MCP_Delegation_Handlers,
	control:mcp.Control_Service,
	bus:^events.User_Event_Bus,
	workers:mcp.Worker_Broker,
	registrations:mcp.Worker_Registrations,
	requests:mcp.Request_Registry,
	create_ctx:rawptr,
	mutate_catalog:mcp.Catalog_Mutate_Proc,
	runtime:mcp.Runtime_Proc,
	mutate_resource:mcp.Resource_Mutate_Proc,
	// Optional approved enrolled-bridge transport. It receives no client token.
	bridge_ctx:rawptr,
	bridge_transform:proc(ctx:rawptr,job:vault.Control_Job)->(string,bool),
}
// 64KiB agent instructions may expand sixfold when JSON-escaped; typed tool
// field limits remain stricter than this bounded transport envelope.
MCP_CONTROL_MAX_BODY_BYTES :: 512*1024
// artifacts.create with entry/files only: 15 MiB of decoded bundle content as
// base64 (x4/3) or JSON-escaped text, plus metadata. Every other method/tool is
// still refused above MCP_CONTROL_MAX_BODY_BYTES after the parse.
MCP_CONTROL_MAX_ARTIFACT_BODY_BYTES :: 48*1024*1024
#assert(MCP_CONTROL_MAX_ARTIFACT_BODY_BYTES<=MAX_HTTP_REQUEST_BYTES)
mcp_control_register_routes :: proc(r:^Router,h:^MCP_Control_Handlers) {
	router_add(r,"ANY",MCP_PATH,h,mcp_control_handler)
	router_add(r,"GET",MCP_OAUTH+"/jobs",h,mcp_worker_handler)
	router_add(r,"POST",MCP_OAUTH+"/jobs",h,mcp_worker_handler)
	router_add(r,"POST",MCP_OAUTH+"/worker",h,mcp_worker_registration_handler)
}
mcp_parse_object :: proc(text:string)->(json.Object,bool) {
	if !utf8.valid_string(text) do return nil,false
	parser:=json.make_parser_from_string(text,.JSON,true,context.temp_allocator)
	value,err:=json.parse_value(&parser)
	obj,ok:=value.(json.Object)
	return obj,err==nil && ok && parser.curr_token.kind==.EOF
}
mcp_rpc_error :: proc(id:json.Value,code:int,message:string)->Response {
	return mcp_json(struct {jsonrpc:string,id:json.Value,error:struct {code:int,message:string}}{"2.0",id,{code,message}})
}
mcp_rpc_result :: proc(id,result:json.Value)->Response {
	return mcp_json(struct {jsonrpc:string,id:json.Value,result:json.Value}{"2.0",id,result})
}
mcp_id_ok :: proc(id:json.Value)->bool {
	#partial switch v in id {
	case json.String:return len(v)>0 && len(v)<=128
	case json.Integer:return v>=-9007199254740991 && v<=9007199254740991
	}
	return false
}
mcp_arguments :: proc(name:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	if mcp.resource_tool(name) do return mcp_resource_arguments(name,value)
	if mcp.runtime_tool(name) do return mcp_runtime_arguments(name,value)
	if mcp.catalog_tool(name) do return mcp_catalog_arguments(name,value)
	return {},false
}
// Hub task chains are removed: the former chain/task tools (and events.wait,
// which only watched a Hub chain) answer the typed refusal.
mcp_hub_chain_tool :: proc(name:string)->bool {
	return strings.has_prefix(name,"chains.") || strings.has_prefix(name,"tasks.") || name=="events.wait"
}
mcp_tool_result :: proc(id:json.Value,text:string,is_error:bool)->Response {
	resp:=mcp_json(struct {jsonrpc:string,id:json.Value,result:struct {content:[]struct {type,text:string},isError:bool}}{"2.0",id,{[]struct {type,text:string}{{"text",text}},is_error}})
	resp.sensitive=true
	return resp
}
mcp_unauthorized :: proc(h:^MCP_Control_Handlers)->Response {
	resp:=mcp_oauth_error("invalid_token",401)
	headers:=make([]contracts.HTTP_Header,len(resp.headers)+1,context.temp_allocator);copy(headers,resp.headers)
	headers[len(resp.headers)]={"WWW-Authenticate",mcp_join("Bearer resource_metadata=\"",h.delegation.origin,"/.well-known/oauth-protected-resource/api/v1/mcp\", scope=\"",mcp.supported_scope_string(),"\"")}
	resp.headers=headers;return resp
}
// Cheap substring screen run before parsing a body over MCP_CONTROL_MAX_BODY_BYTES.
// It only rejects; the parsed-tree check after it stays authoritative.
mcp_large_body_plausible :: proc(body:string)->bool {
	return strings.contains(body,"\"artifacts.create\"") && strings.contains(body,"\"files\"") && strings.contains(body,"\"tools/call\"")
}
mcp_control_handler :: proc(ctx:rawptr,req:Request)->(response:Response) {
	h:=(^MCP_Control_Handlers)(ctx)
	started:=time.tick_now()
	defer response.write_timeout_ms=max(1,min(5000,int((30*time.Second-time.tick_since(started))/time.Millisecond)))
	if origin:=header_value(req.headers,"Origin");origin!="" && origin!=h.delegation.origin do return mcp_oauth_error("access_denied",403)
	bearer:=header_value(req.headers,"Authorization")
	if !strings.has_prefix(bearer,"Bearer ") || len(bearer)>16384 do return mcp_unauthorized(h)
	raw:=strings.trim_prefix(bearer,"Bearer ")
	view,valid:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw)
	if !valid do return mcp_unauthorized(h)
	if req.method!="POST" do return plain_response(405,"method not allowed",{"Allow","POST"})
	if len(req.body)>MCP_CONTROL_MAX_ARTIFACT_BODY_BYTES || !strings.has_prefix(header_value(req.headers,"Content-Type"),"application/json") do return mcp_oauth_error("invalid_request")
	defer if req.body!="" do crypto.zero_explicit(raw_data(req.body),len(req.body))
	// Pre-parse gate: only an artifacts.create bundle may exceed 512 KiB, so a large
	// body that cannot name that tool or carry files is refused before the JSON parse.
	if len(req.body)>MCP_CONTROL_MAX_BODY_BYTES && !mcp_large_body_plausible(req.body) do return mcp_rpc_error(nil,-32602,"request_too_large: only artifacts.create with entry/files accepts more than 512 KiB")
	rpc,parsed:=mcp_parse_object(req.body)
	defer vault.control_wipe_value(rpc)
	version,vok:=rpc["jsonrpc"].(json.String)
	method,mok:=rpc["method"].(json.String)
	if !parsed || !vok || string(version)!="2.0" || !mok do return mcp_rpc_error(nil,-32600,"Invalid Request")
	id,has_id:=rpc["id"]
	if has_id && !mcp_id_ok(id) do return mcp_rpc_error(nil,-32600,"Invalid request id")
	if len(req.body)>MCP_CONTROL_MAX_BODY_BYTES && (!has_id || string(method)!="tools/call") do return mcp_rpc_error(id,-32602,"request_too_large: only artifacts.create with entry/files accepts more than 512 KiB")
	params,_:=rpc["params"].(json.Object)
	key:=auth.sha256_hex(raw)
	if !has_id {
		if string(method)=="notifications/cancelled" {
			cancel_id:=params["requestId"]
			if mcp_id_ok(cancel_id) {encoded,_:=json.marshal(cancel_id,allocator=context.temp_allocator);mcp.request_cancel(&h.requests,key,string(encoded))}
		}
		return mcp_json(struct {}{},202)
	}
	switch string(method) {
	case "initialize":
		requested,ok:=params["protocolVersion"].(json.String)
		if !ok do return mcp_rpc_error(id,-32602,"Invalid initialization")
		protocol:="2025-11-25"
		if requested=="2025-03-26" || requested=="2025-06-18" || requested=="2024-11-05" do protocol=string(requested)
		return mcp_rpc_result(id,json.Object{"protocolVersion"=json.String(protocol),"capabilities"=json.Object{"tools"=json.Object{}},"serverInfo"=json.Object{"name"=json.String("heimdall-control"),"version"=json.String("0.2.0")},"instructions"=json.String("Act as the connected user within the tools and permissions advertised by tools/list. Runtime writes can dispatch work on owned machines. Reuse a stable request_id with identical arguments after ambiguous write results; refresh instances.get revision before a new update. Runtime acceptance is not readiness; poll instances.operations. Task chains are Bridge-owned and are not exposed through this server. Default decryption requires an approved unlocked device; hosted decryption requires explicit connection consent.")})
	case "ping":return mcp_rpc_result(id,json.Object{})
	case "tools/list":
		tools,err:=json.parse_string(#load("mcp_tools.json",string),parse_integers=true,allocator=context.temp_allocator)
		if err!=nil do return mcp_rpc_error(id,-32603,"Tool metadata unavailable")
		catalog,typed:=tools.(json.Array)
		if !typed do return mcp_rpc_error(id,-32603,"Tool metadata unavailable")
		visible:=make(json.Array,0,len(catalog),context.temp_allocator)
		for value in catalog {
			tool,object:=value.(json.Object);name,named:=tool["name"].(json.String)
			if object && named && mcp.scope_allows_tool(view.scope,string(name)) do append(&visible,value)
		}
		return mcp_rpc_result(id,json.Object{"tools"=visible})
	case "tools/call":
	case:return mcp_rpc_error(id,-32601,"Method not found")
	}
	name,nok:=params["name"].(json.String)
	if len(req.body)>MCP_CONTROL_MAX_BODY_BYTES {
		// Two-value assertions only: a failed single-value assertion panics the Hub.
		arguments,args_object:=params["arguments"].(json.Object)
		files_object:=false
		if args_object {files,has_files:=arguments["files"];if has_files {_,files_object=files.(json.Object)}}
		if !nok || string(name)!="artifacts.create" || !files_object do return mcp_rpc_error(id,-32602,"request_too_large: only artifacts.create with entry/files accepts more than 512 KiB")
	}
	if nok && mcp_hub_chain_tool(string(name)) do return mcp_tool_result(id,"hub_chains_removed",true)
	args,args_ok:=mcp_arguments(string(name),params["arguments"])
	defer {
		for text in ([]string{args.catalog.name,args.catalog.slug,args.catalog.instructions}) do if text!="" do crypto.zero_explicit(raw_data(text),len(text))
	}
	if !nok || !args_ok {
		return mcp_rpc_error(id,-32602,"Unknown tool or invalid arguments")
	}
	if !mcp.scope_allows_tool(view.scope,string(name)) do return mcp_tool_result(id,"scope_missing",true)
	encoded_id,_:=json.marshal(id,allocator=context.temp_allocator)
	handle,admitted:=mcp.request_begin(&h.requests,key,string(encoded_id))
	if !admitted do return mcp_tool_result(id,"busy: request is already active or capacity is exhausted",true)
	defer mcp.request_end(&h.requests,handle)
	if mcp.resource_write(string(name)) do return mcp_resource_write_call(h,id,raw,view,string(name),args.resource,handle,started)
	if mcp.runtime_tool(string(name)) {
		if h.runtime==nil do return mcp_tool_result(id,"request_failed",true)
		cancellation:=MCP_Runtime_Cancellation{h=h,handle=handle,started=started}
		result,code:=h.runtime(h.create_ctx,raw,view,string(name),args.runtime,&cancellation,mcp_runtime_cancelled)
		if code=="invalid_token" do return mcp_unauthorized(h)
		if code!="" do return mcp_tool_result(id,code,true)
		return mcp_tool_result(id,result,false)
	}
	if mcp.catalog_write(string(name)) do return mcp_catalog_write_call(h,id,raw,view,string(name),args.catalog,handle,started)
	data:mcp.Control_Data
	bundle_slot:=false
	defer if bundle_slot do mcp_bundle_slot_release()
	if mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	// A fresh read and credential check after waiting, never a pre-wait cache.
	fresh,fresh_ok:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw)
	if !fresh_ok do return mcp_unauthorized(h)
	view=fresh
	op:mcp.Control_Transform
	if mcp.catalog_tool(string(name)) do op.tool=string(name)
	if mcp.resource_tool(string(name)) do op.tool=string(name)
	defer if mcp.resource_kind(string(name))=="artifact" {for row in data.records {for key in ([]string{"name","description","content","content_base64"}) {if text,typed:=row[key].(json.String);typed && len(text)>0 do crypto.zero_explicit(raw_data(text),len(text))}}}
	{
		code:string
		data,code=mcp.control_read(&h.control,view.owner,string(name),args)
		if code!="" do return mcp_tool_result(id,code,true)
		op.data=data
		if !mcp.control_payload_ok(data) do return mcp_tool_result(id,"result_too_large",true)
		// An html-bundle download (one artifact record with content_base64) shares
		// the Hub-wide bundle bound with bundle creates.
		if vault.control_data_payload_max(data)>vault.CONTROL_JOB_PAYLOAD_MAX {
			if !mcp_bundle_slot_acquire() do return mcp_tool_result(id,MCP_BUNDLE_BUSY,true)
			bundle_slot=true
		}
	}
	result:mcp.Delegation_Result
	if view.mode=="hosted" {
		result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)
	} else {
		result=mcp_device_transform(h,view,&op,handle,started)
	}
	defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
	if result.error=="invalid_token" do return mcp_unauthorized(h)
	if result.error!="" {
		if _,still_valid:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw);!still_valid do return mcp_unauthorized(h)
		return mcp_tool_result(id,result.error,true)
	}
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	final,final_ok:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw)
	if !final_ok do return mcp_unauthorized(h)
	if !mcp.access_same(view,final) do return mcp_tool_result(id,"decryption_unavailable",true)
	if !mcp.control_result_ok(data,result.response) do return mcp_tool_result(id,"decryption_unavailable",true)
	return mcp_tool_result(id,result.response,false)
}
