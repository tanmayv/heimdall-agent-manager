package http

import "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

owner_directory :: proc(h:^Bridge_Handlers,account:string)->(vault.Directory_Verification_Input,bool) {
    snapshot,err:=vd.get_directory(h.vault,account)
    if err.code!=.None do return {},false
    d:=vault.Directory_Verification_Input{owner=account,root_device_id=snapshot.directory.root_device_id,head_hash=snapshot.directory.head_hash,version=snapshot.directory.version,current_epoch=snapshot.directory.current_epoch}
    d.log=make([]vault.Directory_Log_Item,len(snapshot.log),context.temp_allocator)
    for entry,i in snapshot.log do d.log[i]={entry.seq,entry.statement,entry.signature}
    d.devices=make([]vault.Directory_Device_Item,len(snapshot.devices),context.temp_allocator)
    for device,i in snapshot.devices do d.devices[i]={device.device_id,device.kind,device.sign_alg,device.wrap_alg,device.sign_public_key,device.ecdh_public_key,device.status==.Approved,device.status==.Pending}
    return d,true
}
owner_json :: proc(v:$T)->string { b,_:=json.marshal(v,allocator=context.temp_allocator);return string(b) }
owner_registry_rows :: proc(h:^Bridge_Handlers,account,chain,after_chain,after_task:string,limit:int,headers_only:bool=false)->([]domain.Owner_Registry_Record,domain.Domain_Error) {
    return h.taskchains.repo.owner_registry_list(h.taskchains.repo.ctx,account,chain,after_chain,after_task,limit,headers_only)
}
Owner_Relay_Command :: struct {
    type,command_id,account_id,relay:string,
    directory:vault.Directory_Verification_Input,
}
owner_local_relay_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_any(h.auth,req)
    if !ok do return resp
    if !contracts.is_user_auth(auth) && auth.kind!=.Instance_Token do return respond_error(domain.domain_error(.Forbidden,"user authentication required"),req.request_id)
    relay,valid:=contracts.owner_parse(req.body,"relay")
    if !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid owner relay"),req.request_id)
    bridge_id,chain:=contracts.owner_string(relay,"bridge_id"),contracts.owner_string(relay,"chain_id")
    expires,_:=strconv.parse_i64(contracts.owner_string(relay,"expires_ms"))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if expires<=now || expires-now>60000 do return respond_error(domain.domain_error(.Validation_Failed,"relay expired"),req.request_id)
    rows,err:=owner_registry_rows(h,auth.user_id,chain,"","",1)
    if err.code!=.None do return respond_error(err,req.request_id)
    if len(rows)>0 && rows[0].owner_bridge_id!=bridge_id do return respond_error(domain.domain_error(.Forbidden,"immutable owner mismatch"),req.request_id)
    // An absent route is admitted solely for creation: the recipient must verify
    // signed genesis and refuses every other operation without a local grant.
    bridge,owned,berr:=bridge_service.get_bridge(h.bridges,auth,bridge_id)
    if !owned do return respond_error(berr,req.request_id)
    if bridge.status!=.Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,bridge_id) do return respond_success(`{"code":"owner_unavailable"}`,req.request_id,auth_ctx_server_time(req))
    directory,available:=owner_directory(h,auth.user_id)
    if !available do return respond_error(domain.domain_error(.Forbidden,"current directory unavailable"),req.request_id)
    id:=fmt.tprintf("cmd_owner_%d",time.to_unix_nanoseconds(time.now()))
    command:=Owner_Relay_Command{"owner_local",id,auth.user_id,req.body,directory}
    reply,received,rerr:=bridge_runtime.send_runtime_command_wait(h.bridge_runtime_registry,project_service.Runtime_Command{bridge_id=bridge_id,command_id=id,body_json=owner_json(command)},10000)
    if !received do return respond_error(rerr,req.request_id)
    defer delete(reply,runtime.default_allocator())
    return respond_success(reply,req.request_id,auth_ctx_server_time(req))
}
owner_local_publish_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_or_bridge_token(h.auth,req)
    if !ok do return resp
    if auth.kind!=.Bridge_Token do return respond_error(domain.domain_error(.Forbidden,"owner Bridge required"),req.request_id)
    publication,valid:=contracts.owner_parse(req.body,"publication")
    if !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid publication"),req.request_id)
    genesis,gok:=contracts.owner_parse(contracts.owner_string(publication,"genesis"),"genesis")
    registry,rok:=contracts.owner_parse(contracts.owner_string(publication,"registry"),"registry")
    if !gok || !rok do return respond_error(domain.domain_error(.Validation_Failed,"invalid registry documents"),req.request_id)
    account:=contracts.owner_string(genesis,"account_id")
    if auth.user_id!=account || auth.bridge_id!=contracts.owner_string(genesis,"owner_bridge_id") do return respond_error(domain.domain_error(.Forbidden,"publication owner mismatch"),req.request_id)
    chain:=contracts.owner_string(genesis,"chain_id")
    existing,read_err:=owner_registry_rows(h,account,chain,"","",1)
    if read_err.code!=.None do return respond_error(read_err,req.request_id)
    d,available:=owner_directory(h,account)
    dir,verified:=vault.directory_verify(d)
    creator,approved:=dir.trusted[contracts.owner_string(genesis,"creator_id")]
    owner,enrolled:=dir.trusted[contracts.owner_string(genesis,"owner_key_id")]
    if !available || !verified || !enrolled || owner.kind!="bridge" do return respond_error(domain.domain_error(.Forbidden,"unapproved signer"),req.request_id)
    // The enrolled Bridge row must name this exact directory signing identity.
    snapshot,serr:=vd.get_directory(h.vault,account)
    bound:=false
    for dev in snapshot.devices { if dev.bridge_id==auth.bridge_id && dev.device_id==owner.id && dev.sign_public_key==owner.sign_public_key && dev.status==.Approved do bound=true }
    if serr.code!=.None || !bound do return respond_error(domain.domain_error(.Forbidden,"owner identity mismatch"),req.request_id)
    bk:=contracts.Owner_Verified_Key{account,auth.bridge_id,owner.id,owner.sign_public_key,"bridge",true,false}
    digest,_:=contracts.owner_digest("genesis",genesis)
    ck:=contracts.Owner_Verified_Key{account,creator.id,creator.id,creator.sign_public_key,"device",approved && creator.kind=="browser",false}
    if !owner_publication_verified(genesis,registry,contracts.owner_string(publication,"genesis"),account,auth.bridge_id,ck,bk,existing) do return respond_error(domain.domain_error(.Forbidden,"invalid owner signatures"),req.request_id)
    if _,exists,_:=h.taskchains.repo.get_chain(h.taskchains.repo.ctx,domain.Task_Chain_ID(chain));exists do return respond_error(domain.domain_error(.Conflict,"legacy chain requires explicit migration"),req.request_id)
    revision,_:=strconv.parse_i64(contracts.owner_string(registry,"metadata_revision"))
    r:=domain.Owner_Registry_Record{account_id=account,chain_id=chain,owner_bridge_id=auth.bridge_id,owner_key_id=owner.id,creator_id=contracts.owner_string(genesis,"creator_id"),genesis_digest=digest,genesis_json=contracts.owner_string(publication,"genesis"),task_id=contracts.owner_string(registry,"task_id"),registry_json=contracts.owner_string(publication,"registry"),metadata_revision=revision}
    err:=h.taskchains.repo.owner_registry_publish(h.taskchains.repo.ctx,r)
    if err.code!=.None do return respond_error(err,req.request_id)
    return respond_success(`{"published":true}`,req.request_id,auth_ctx_server_time(req))
}
// A bound genesis is authenticated historical evidence. Never reconstruct it
// using a different key or promote a revoked creator into a current command key.
owner_publication_verified :: proc(genesis,registry:json.Object,raw_genesis,account,bridge:string,creator,owner:contracts.Owner_Verified_Key,existing:[]domain.Owner_Registry_Record)->bool {
    digest,ok:=contracts.owner_digest("genesis",genesis)
    if !ok || contracts.owner_string(genesis,"account_id")!=account || contracts.owner_string(genesis,"owner_bridge_id")!=bridge || contracts.owner_string(genesis,"owner_key_id")!=owner.key_id do return false
    if len(existing)>0 {
        r:=existing[0]
        if r.account_id!=account || r.chain_id!=contracts.owner_string(genesis,"chain_id") || r.owner_bridge_id!=bridge || r.owner_key_id!=owner.key_id || r.creator_id!=contracts.owner_string(genesis,"creator_id") || r.genesis_digest!=digest || r.genesis_json!=raw_genesis do return false
    } else {
        // First publication after creator revocation fails closed. It needs a
        // separate authenticated recovery policy; a submitted genesis is no proof.
        if contracts.owner_verify_genesis(genesis,account,bridge,creator,owner)!=.None do return false
    }
    return contracts.owner_string(registry,"chain_id")==contracts.owner_string(genesis,"chain_id") && contracts.owner_verify_registry(registry,account,bridge,digest,owner)==.None
}

Owner_Listing_Cursor :: struct {
    after_chain,after_task:string,
}
Owner_Listing_Page :: struct {
    items:[]Owner_Listing,
    next_cursor:Owner_Listing_Cursor,
    terminal:bool,
}
Owner_Listing :: struct {
    chain_id,owner_bridge_id,owner_key_id,task_id,registry_json:string,
    online:bool,
}
owner_local_list_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth(h.auth,req)
    if !ok do return resp
    if !contracts.is_user_auth(auth) do return respond_error(domain.domain_error(.Forbidden,"user authentication required"),req.request_id)
    chain:=query_value(req.query,"chain_id")
    rows,err:=owner_registry_rows(h,auth.user_id,chain,query_value(req.query,"after_chain"),query_value(req.query,"after_task"),101,query_value(req.query,"headers_only")=="1")
    if err.code!=.None do return respond_error(err,req.request_id)
    paged:=query_value(req.query,"page")=="1"
    out:=make([dynamic]Owner_Listing,context.temp_allocator)
    cursor:=Owner_Listing_Cursor{}
    terminal:=true
    for row,i in rows {
        if i==(101 if !paged && query_value(req.query,"headers_only")=="1" else 100) { terminal=false;break }
        registry,valid:=contracts.owner_parse(row.registry_json,"registry")
        live:=valid && contracts.owner_string(registry,"deleted")!="1"
        if live {
            entry:=Owner_Listing{row.chain_id,row.owner_bridge_id,row.owner_key_id,row.task_id,row.registry_json,project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,row.owner_bridge_id)}
            append(&out,entry)
            if paged && len(owner_json(Owner_Listing_Page{out[:],Owner_Listing_Cursor{row.chain_id,row.task_id},false}))>262144 {
                resize(&out,len(out)-1)
                if i==0 do return respond_error(domain.domain_error(.Validation_Failed,"registry entry exceeds page byte limit"),req.request_id)
                terminal=false
                break
            }
        }
        // Advance over examined raw rows, including tombstones. The extra row
        // is lookahead only; never advance over a byte-limited unreturned row.
        cursor={row.chain_id,row.task_id}
    }
    if !paged do return respond_success(owner_json(out[:]),req.request_id,auth_ctx_server_time(req))
    if terminal do cursor={}
    return respond_success(owner_json(Owner_Listing_Page{out[:],cursor,terminal}),req.request_id,auth_ctx_server_time(req))
}

Executor_Issuance_Command :: struct {
    type,command_id,account_id,relay:string,
    directory:vault.Directory_Verification_Input,
}
// The Hub transports opaque bytes and enrolled directory evidence only. The
// executor verifies device consent and owns identity allocation; no task state
// is granted or changed here.
executor_issuance_relay_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth(h.auth,req)
    if !ok do return resp
    if !contracts.is_user_auth(auth) do return respond_error(domain.domain_error(.Forbidden,"user authentication required"),req.request_id)
    relay,valid:=contracts.owner_parse(req.body,"relay")
    if !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid executor relay"),req.request_id)
    bridge_id:=contracts.owner_string(relay,"bridge_id")
    expires,_:=strconv.parse_i64(contracts.owner_string(relay,"expires_ms"))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if expires<=now || expires-now>60000 do return respond_error(domain.domain_error(.Validation_Failed,"relay expired"),req.request_id)
    bridge,owned,err:=bridge_service.get_bridge(h.bridges,auth,bridge_id)
    if !owned do return respond_error(err,req.request_id)
    if bridge.status!=.Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,bridge_id) do return respond_success(`{"code":"executor_unavailable"}`,req.request_id,auth_ctx_server_time(req))
    directory,available:=owner_directory(h,auth.user_id)
    if !available do return respond_error(domain.domain_error(.Forbidden,"current directory unavailable"),req.request_id)
    id:=fmt.tprintf("cmd_executor_issuance_%d",time.to_unix_nanoseconds(time.now()))
    command:=Executor_Issuance_Command{"executor_issuance",id,auth.user_id,req.body,directory}
    reply,received,rerr:=bridge_runtime.send_runtime_command_wait(h.bridge_runtime_registry,project_service.Runtime_Command{bridge_id=bridge_id,command_id=id,body_json=owner_json(command)},10000)
    if !received do return respond_error(rerr,req.request_id)
    defer delete(reply,runtime.default_allocator())
    return respond_success(reply,req.request_id,auth_ctx_server_time(req))
}

Executor_Relay_Command :: struct {
    type,command_id,account_id,relay,genesis:string,
    directory:vault.Directory_Verification_Input,
}
Executor_Relay_Result :: struct {reply:string,directory:vault.Directory_Verification_Input}
Executor_Fence_Command :: struct {
    type,command_id,account_id,executor_bridge_id,relay:string,
    directory:vault.Directory_Verification_Input,
}
// Reverse relay: an enrolled account Bridge can ask only the immutable owner.
// The owner verifies the enrolled executor signature and exact claimed intent;
// this routing check neither grants work nor attests a current execution fence.
executor_fence_relay_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_or_bridge_token(h.auth,req)
    if !ok do return resp
    if auth.kind!=.Bridge_Token do return respond_error(domain.domain_error(.Forbidden,"executor Bridge authentication required"),req.request_id)
    relay,valid:=contracts.owner_parse(req.body,"relay")
    if !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid fence relay"),req.request_id)
    get:=contracts.owner_string
    expires:=contracts.executor_number(relay,"expires_ms")
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if expires<=now || expires-now>contracts.EXECUTOR_FENCE_TTL_MS do return respond_error(domain.domain_error(.Validation_Failed,"fence relay expired"),req.request_id)
    rows,read:=owner_registry_rows(h,auth.user_id,get(relay,"chain_id"),"","",1)
    if read.code!=.None do return respond_error(read,req.request_id)
    target:=get(relay,"bridge_id")
    if len(rows)!=1 || rows[0].owner_bridge_id!=target do return respond_error(domain.domain_error(.Forbidden,"immutable owner target required"),req.request_id)
    bridge,owned,err:=bridge_service.get_bridge(h.bridges,auth,target)
    if !owned do return respond_error(err,req.request_id)
    if bridge.status!=.Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,target) do return respond_success(`{"code":"owner_unavailable"}`,req.request_id,auth_ctx_server_time(req))
    directory,available:=owner_directory(h,auth.user_id)
    if !available do return respond_error(domain.domain_error(.Forbidden,"current directory unavailable"),req.request_id)
    id:=fmt.tprintf("cmd_executor_fence_%d",time.to_unix_nanoseconds(time.now()))
    command:=Executor_Fence_Command{"owner_executor_fence",id,auth.user_id,auth.bridge_id,req.body,directory}
    reply,received,rerr:=bridge_runtime.send_runtime_command_wait(h.bridge_runtime_registry,project_service.Runtime_Command{bridge_id=target,command_id=id,body_json=owner_json(command)},5000)
    if !received do return respond_error(rerr,req.request_id)
    defer delete(reply,runtime.default_allocator())
    return respond_success(owner_json(Executor_Relay_Result{reply,directory}),req.request_id,auth_ctx_server_time(req))
}
// Only the immutable registered owner Bridge may request remote resources.
// This reads signed routing metadata, never task eligibility/grant state.
executor_relay_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_or_bridge_token(h.auth,req)
    if !ok do return resp
    if auth.kind!=.Bridge_Token do return respond_error(domain.domain_error(.Forbidden,"owner Bridge authentication required"),req.request_id)
    relay,valid:=contracts.owner_parse(req.body,"relay")
    if !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid executor relay"),req.request_id)
    get:=contracts.owner_string
    expires:=contracts.executor_number(relay,"expires_ms")
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if expires<=now || expires-now>contracts.EXECUTOR_TRANSPORT_TTL_MS do return respond_error(domain.domain_error(.Validation_Failed,"relay expired"),req.request_id)
    rows,read:=owner_registry_rows(h,auth.user_id,get(relay,"chain_id"),"","",1)
    if read.code!=.None do return respond_error(read,req.request_id)
    if len(rows)!=1 || rows[0].owner_bridge_id!=auth.bridge_id do return respond_error(domain.domain_error(.Forbidden,"immutable owner Bridge required"),req.request_id)
    target:=get(relay,"bridge_id")
    bridge,owned,err:=bridge_service.get_bridge(h.bridges,auth,target)
    if !owned do return respond_error(err,req.request_id)
    if bridge.status!=.Online || !project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,target) do return respond_success(`{"code":"executor_unavailable"}`,req.request_id,auth_ctx_server_time(req))
    directory,available:=owner_directory(h,auth.user_id)
    if !available do return respond_error(domain.domain_error(.Forbidden,"current directory unavailable"),req.request_id)
    id:=fmt.tprintf("cmd_executor_%d",time.to_unix_nanoseconds(time.now()))
    command:=Executor_Relay_Command{"executor_exchange",id,auth.user_id,req.body,rows[0].genesis_json,directory}
    reply,received,rerr:=bridge_runtime.send_runtime_command_wait(h.bridge_runtime_registry,project_service.Runtime_Command{bridge_id=target,command_id=id,body_json=owner_json(command)},10000)
    if !received do return respond_error(rerr,req.request_id)
    defer delete(reply,runtime.default_allocator())
    return respond_success(owner_json(Executor_Relay_Result{reply,directory}),req.request_id,auth_ctx_server_time(req))
}
