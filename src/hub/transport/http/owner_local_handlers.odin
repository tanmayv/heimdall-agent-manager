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
owner_registry_rows :: proc(h:^Bridge_Handlers,account,chain,after_chain,after_task:string,limit:int)->([]domain.Owner_Registry_Record,domain.Domain_Error) {
    return h.taskchains.repo.owner_registry_list(h.taskchains.repo.ctx,account,chain,after_chain,after_task,limit)
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
    d,available:=owner_directory(h,account)
    dir,verified:=vault.directory_verify(d)
    creator,approved:=dir.trusted[contracts.owner_string(genesis,"creator_id")]
    owner,enrolled:=dir.trusted[contracts.owner_string(genesis,"owner_key_id")]
    if !available || !verified || !approved || creator.kind!="browser" || !enrolled || owner.kind!="bridge" do return respond_error(domain.domain_error(.Forbidden,"unapproved signer"),req.request_id)
    // The enrolled Bridge row must name this exact directory signing identity.
    snapshot,serr:=vd.get_directory(h.vault,account)
    bound:=false
    for dev in snapshot.devices { if dev.bridge_id==auth.bridge_id && dev.device_id==owner.id && dev.sign_public_key==owner.sign_public_key && dev.status==.Approved do bound=true }
    if serr.code!=.None || !bound do return respond_error(domain.domain_error(.Forbidden,"owner identity mismatch"),req.request_id)
    ck:=contracts.Owner_Verified_Key{account,creator.id,creator.id,creator.sign_public_key,"device",true,false}
    bk:=contracts.Owner_Verified_Key{account,auth.bridge_id,owner.id,owner.sign_public_key,"bridge",true,false}
    digest,_:=contracts.owner_digest("genesis",genesis)
    signatures_ok:=contracts.owner_verify_genesis(genesis,account,auth.bridge_id,ck,bk)==.None && contracts.owner_verify_registry(registry,account,auth.bridge_id,digest,bk)==.None
    if !signatures_ok || contracts.owner_string(registry,"chain_id")!=contracts.owner_string(genesis,"chain_id") { return respond_error(domain.domain_error(.Forbidden,"invalid owner signatures"),req.request_id) }
    chain:=contracts.owner_string(genesis,"chain_id")
    if _,exists,_:=h.taskchains.repo.get_chain(h.taskchains.repo.ctx,domain.Task_Chain_ID(chain));exists do return respond_error(domain.domain_error(.Conflict,"legacy chain requires explicit migration"),req.request_id)
    revision,_:=strconv.parse_i64(contracts.owner_string(registry,"metadata_revision"))
    r:=domain.Owner_Registry_Record{account_id=account,chain_id=chain,owner_bridge_id=auth.bridge_id,owner_key_id=owner.id,creator_id=creator.id,genesis_digest=digest,genesis_json=contracts.owner_string(publication,"genesis"),task_id=contracts.owner_string(registry,"task_id"),registry_json=contracts.owner_string(publication,"registry"),metadata_revision=revision}
    err:=h.taskchains.repo.owner_registry_publish(h.taskchains.repo.ctx,r)
    if err.code!=.None do return respond_error(err,req.request_id)
    return respond_success(`{"published":true}`,req.request_id,auth_ctx_server_time(req))
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
    rows,err:=owner_registry_rows(h,auth.user_id,chain,query_value(req.query,"after_chain"),query_value(req.query,"after_task"),101)
    if err.code!=.None do return respond_error(err,req.request_id)
    out:=make([dynamic]Owner_Listing,context.temp_allocator)
    for row in rows {
        if row.registry_json=="" do continue
        append(&out,Owner_Listing{row.chain_id,row.owner_bridge_id,row.owner_key_id,row.task_id,row.registry_json,project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,row.owner_bridge_id)})
    }
    return respond_success(owner_json(out[:]),req.request_id,auth_ctx_server_time(req))
}
