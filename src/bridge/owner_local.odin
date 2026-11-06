package main

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

bridge_owner_store:owner.Store
bridge_owner_mutex:sync.Mutex
// Protected by bridge_owner_mutex; retained across request allocator resets.
bridge_owner_completions:owner.Intent_Completions

bridge_owner_json :: proc(v:$T)->string { b,_:=json.marshal(v,allocator=context.temp_allocator);return string(b) }

bridge_owner_open :: proc(account,key_id:string)->bool {
    if bridge_owner_store.db!=nil do return bridge_owner_store.account==account && bridge_owner_store.owner_key==key_id
    dir,ok:=bridge_vault_bridge_dir(bridge_config.daemon_id,context.temp_allocator)
    if !ok do return false
    path:=fmt.tprintf("%sowner-local-%s",dir,contracts.owner_payload_digest(account))
    if err:=bridge_make_directory_all(path,{.Read_User,.Write_User,.Execute_User});err!=nil do return false
    when ODIN_OS != .Windows {
        if os.chmod(path,{.Read_User,.Write_User,.Execute_User})!=nil do return false
    }
    // Use the real allocator for the process-lifetime owner identity strings.
    saved:=context.allocator;context.allocator=runtime.default_allocator()
    opened:=owner.open(&bridge_owner_store,fmt.tprintf("%s/runtime.sqlite",path),account,bridge_config.daemon_id,key_id)
    context.allocator=saved
    return opened
}
bridge_owner_publish :: proc() {
    _=bridge_owner_publish_batch(&bridge_owner_store,&bridge_owner_completions,time.to_unix_nanoseconds(time.now())/1000000,nil,bridge_owner_publish_registry)
}

// The injected transport keeps result-persistence fault tests on the exact
// production delivery path. Caller serializes this queue for its Store.
bridge_owner_publish_batch :: proc(s:^owner.Store,q:^owner.Intent_Completions,now:i64,ctx:rawptr,
    send:proc(rawptr,^owner.Store,owner.Intent_Claim)->(bool,string,i64)) -> bool {
    // No new delivery while a previous outcome still cannot be persisted.
    if !owner.intent_completions_flush(s,q) do return false
    pending,ok:=owner.intent_claim_due(s,now)
    if !ok do return false
    for claim in pending {
        success,result,completed:=send(ctx,s,claim)
        if !owner.intent_completion_keep(q,claim,success,result,completed,runtime.default_allocator()) do panic("owner-local completion capacity invariant")
    }
    // Failure leaves every unresolved completion retained for the next request.
    return owner.intent_completions_flush(s,q)
}

bridge_owner_publish_registry :: proc(_:rawptr,s:^owner.Store,claim:owner.Intent_Claim) -> (bool,string,i64) {
    if claim.kind=="stop" || claim.kind=="checkpoint" do return bridge_owner_control_notice(s,claim)
    if claim.kind=="merge" do return bridge_owner_merge(s,claim)
    // Future consumers must validate their own execution fences before I/O.
    if claim.kind!="registry" do return false,"unsupported_kind",time.to_unix_nanoseconds(time.now())/1000000
    token:=bridge_credential_snapshot();defer delete(token)
    headers:=[?]httpc.Header{httpc.bearer(token)}
    genesis:=owner.genesis_for(s,claim.chain)
    publication:=contracts.Owner_Publication{genesis,claim.payload}
    response,err:=bridge_http_request_retry({method=.POST,url=bridge_hub_url(),path={"api","v1","owner-local","registry"},headers=headers[:],body=httpc.json_body(publication)})
    defer httpc.response_destroy(&response)
    return err==.None && response.status==200,fmt.tprintf("%d",response.status),time.to_unix_nanoseconds(time.now())/1000000
}
Owner_Bridge_Command :: struct {
    type,command_id,account_id,relay:string,
    directory:vault.Directory_Verification_Input,
}
Owner_Result_Plain :: struct {
    request_id,input_digest,code,body:string,
    commit_seq:string,
    replay:bool,
}
bridge_owner_handle :: proc(conn:^ws.Connection,text:string) {
    context.allocator=context.temp_allocator
    search_generation:=bridge_task_chain_search_generation()
    wire:Owner_Bridge_Command
    if json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    relay,valid:=contracts.owner_parse(wire.relay,"relay")
    if !valid do return
    request_id:=contracts.owner_string(relay,"request_id")
    reply:=struct {type,command_id,request_id,code,envelope:string}{"command_result",wire.command_id,request_id,"invalid_scope",""}
    defer {
        // Publication can perform I/O after sealing; lock may arrive meanwhile.
        if bridge_task_chain_search_generation()!=search_generation {reply.code="vault_locked";reply.envelope=""}
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    if wire.account_id!=account || contracts.owner_string(relay,"bridge_id")!=bridge_config.daemon_id do return
    expires,_:=strconv.parse_i64(contracts.owner_string(relay,"expires_ms"))
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if expires<=now || expires-now>60000 do return
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked { reply.code="vault_locked";return }
    plain,opened:=bridge_open_current_epoch_token(contracts.owner_string(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    request,parsed:=contracts.owner_parse(plain,"request")
    if !parsed do return
    command_raw,payload,genesis_raw:=contracts.owner_string(request,"command"),contracts.owner_string(request,"payload"),contracts.owner_string(request,"genesis")
    command,command_ok:=contracts.owner_parse(command_raw,"command")
    if !command_ok || contracts.owner_string(command,"chain_id")!=contracts.owner_string(relay,"chain_id") do return
    owner_pub:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    owner_id,id_ok:=vault.device_id_from_sign_pub(owner_pub,context.temp_allocator)
    if !id_ok do return
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,owner_id) {reply.code="storage_error";return}
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found || !floor.root.set do return
    pin_seq,pin_hash:=owner.directory_pin(&bridge_owner_store)
    key,owner_key,version,head,trusted:=owner.verify_directory(bridge_owner_json(wire.directory),account,bridge_config.daemon_id,owner_pub,contracts.owner_string(command,"principal_id"),contracts.owner_string(command,"key_id"),floor.root,pin_seq,pin_hash,&kr)
    if !trusted do return
    if !owner.observe_directory(&bridge_owner_store,version,head) do return
    if contracts.owner_string(command,"method")=="chain.create" {
        genesis,gvalid:=contracts.owner_parse(genesis_raw,"genesis")
        if !gvalid || contracts.owner_string(genesis,"owner_bridge_id")!=bridge_config.daemon_id || contracts.owner_string(genesis,"owner_key_id")!=owner_key.key_id || !contracts.owner_verify_signature("genesis",genesis,"creator_signature",key) do return
        signature,signed:=bridge_owner_sign(nil,"genesis",genesis)
        if !signed do return
        genesis["owner_signature"]=json.String(signature)
        genesis_raw=bridge_owner_json(genesis)
    }
    sync.mutex_lock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex)
    fleet_child:owner.Child
    if contracts.owner_string(command,"method")=="fleet.edit" {
        p,ok:=contracts.owner_parse(payload,"fleet_payload")
        if !ok { sync.mutex_unlock(&bridge_local_token_mutex);sync.mutex_unlock(&bridge_startup_io_mutex);return }
        current:bool
        fleet_child,current=bridge_owner_child_locked(contracts.owner_string(p,"instance_id"),"")
        if !current do fleet_child={} // Historical device receipts remain readable after child exit.
    }
    proof:owner.Lifecycle_Proof
    if contracts.owner_string(command,"method")=="lifecycle.configure" {
        if p,ok:=contracts.owner_parse(payload,"lifecycle_config_payload");ok {
            proof=bridge_owner_config_proof(&bridge_owner_store,p,contracts.owner_string(command,"chain_id"),contracts.owner_string(command,"task_id"))
        }
    }
    result:=owner.execute(&bridge_owner_store,command_raw,payload,genesis_raw,key,owner_key,version,head,now,&kr,owner.Signer{nil,bridge_owner_sign},fleet_child,proof)
    sync.mutex_unlock(&bridge_local_token_mutex)
    sync.mutex_unlock(&bridge_startup_io_mutex)
    digest,_:=contracts.owner_digest("command",command)
    response:=Owner_Result_Plain{request_id,digest,result.code,result.body,fmt.tprintf("%d",result.seq),result.replay}
    if bridge_task_chain_search_generation()!=search_generation {reply.code="vault_locked";return}
    sealed,sealed_ok:=bridge_encrypt_vault_text(bridge_owner_json(response),&kr,context.temp_allocator)
    if !sealed_ok {reply.code="storage_error";return}
    reply.code="ok";reply.envelope=sealed
    // Publication is after the durable owner transaction, never part of its
    // outcome. A failed publication stays in the outbox for a later request.
    bridge_owner_publish()
}
