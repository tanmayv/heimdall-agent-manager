#+feature dynamic-literals
package main

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:time"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

bridge_executor_store:executor.Store
bridge_executor_mutex:sync.Mutex

bridge_executor_open :: proc(account,key:string)->bool {
    if bridge_executor_store.db!=nil do return bridge_executor_store.account==account && bridge_executor_store.operator_key==key
    dir,ok:=bridge_vault_bridge_dir(bridge_config.daemon_id,context.temp_allocator)
    if !ok do return false
    path:=fmt.tprintf("%sexecutor-local-%s",dir,contracts.owner_payload_digest(account))
    if bridge_make_directory_all(path,{.Read_User,.Write_User,.Execute_User})!=nil do return false
    when ODIN_OS!=.Windows {
        if os.chmod(path,{.Read_User,.Write_User,.Execute_User})!=nil do return false
    }
    saved:=context.allocator;context.allocator=runtime.default_allocator()
    opened:=executor.open(&bridge_executor_store,fmt.tprintf("%s/runtime.sqlite",path),account,bridge_config.daemon_id,key)
    context.allocator=saved
    if opened do _=executor.complete_recovery(&bridge_executor_store,time.to_unix_nanoseconds(time.now())/1000000)
    return opened
}
bridge_executor_sign :: proc(_:rawptr,kind:string,o:json.Object)->(string,bool) {
    if kind!="enrollment" && kind!="issuance_receipt" && kind!="receipt" && kind!="fence_request" do return "",false
    return bridge_owner_sign(nil,fmt.tprintf("executor.%s",kind),o)
}
bridge_executor_canonical_directory :: proc(path:string)->(string,bool) {
    canonical,within:=bridge_fs_resolve_within(path);defer delete(canonical)
    if !within || canonical!=path || !bridge_validate_project_path_local(canonical,"","").ok do return "",false
    return strings.clone(canonical,context.temp_allocator),true
}
// Provisioning receives a host-operator-signed record, never a remote request to
// sign a path. This helper cannot manufacture the required host signature.
bridge_executor_install_directory :: proc(s:^executor.Store,raw:string,key:contracts.Owner_Verified_Key,now:i64)->executor.Result {
    o,valid:=contracts.executor_parse(raw,"directory")
    if !valid do return executor.Result{code="malformed"}
    verified:string
    if contracts.owner_string(o,"enabled")=="1" {verified,_=bridge_executor_canonical_directory(contracts.owner_string(o,"directory_path"))}
    return executor.install_directory(s,raw,key,now,verified)
}
bridge_executor_resolve_issuance :: proc(s:^executor.Store,selection_raw:string)->executor.Issuance_Resources {
    selection,valid:=contracts.executor_parse(selection_raw,"issuance_selection")
    if !valid do return {}
    get:=contracts.owner_string
    mapping,found:=executor.directory_mapping(s,get(selection,"directory_id"))
    if !found do return {}
    canonical,within:=bridge_executor_canonical_directory(mapping.path)
    if !within || executor.directory_key(s.executor,canonical)!=mapping.key do return {}
    provider,model,profile:=get(selection,"provider"),get(selection,"model"),get(selection,"provider_profile")
    if !bridge_provider_catalog_has_model(provider,model) do return {}
    resolved,err:=profile_lookup(provider,profile)
    if err!=.None || !resolved.enabled || resolved.provider!=provider || resolved.profile_id!=profile do return {}
    return executor.Issuance_Resources{contracts.owner_payload_digest(selection_raw),mapping.key,canonical,true}
}

Executor_Issuance_Wire :: struct {
    type,command_id,account_id,relay:string,
    directory:vault.Directory_Verification_Input,
}
bridge_executor_issuance_handle :: proc(conn:^ws.Connection,text:string) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    wire:Executor_Issuance_Wire
    if len(text)>3*1024*1024 || json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    relay,valid:=contracts.owner_parse(wire.relay,"relay")
    if !valid do return
    get:=contracts.owner_string
    reply:=struct{type,command_id,request_id,code,envelope:string}{"command_result",wire.command_id,get(relay,"request_id"),"invalid_scope",""}
    defer {
        if bridge_task_chain_search_generation()!=generation {reply.code="vault_locked";reply.envelope=""}
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    now:=time.to_unix_nanoseconds(time.now())/1000000
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    expires:=contracts.executor_number(relay,"expires_ms")
    if wire.account_id!=account || get(relay,"bridge_id")!=bridge_config.daemon_id ||
       expires<=now || expires-now>contracts.EXECUTOR_TRANSPORT_TTL_MS {return}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {reply.code="vault_locked";return}
    plain,opened:=bridge_open_current_epoch_token(get(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    defer crypto.zero_explicit(raw_data(plain),len(plain))
    exchange,parsed:=contracts.executor_parse(plain,"issuance_exchange")
    scope,scoped:=contracts.executor_parse(get(exchange,"scope"),"transport_scope")
    if !parsed || !scoped || get(scope,"method")!="enrollment" || get(scope,"direction")!="request" ||
       get(scope,"account_id")!=account || get(scope,"executor_bridge_id")!=bridge_config.daemon_id ||
       get(scope,"chain_id")!=get(relay,"chain_id") || get(scope,"request_id")!=get(relay,"request_id") ||
       contracts.executor_number(scope,"request_expires_ms")>expires {return}
    // Decryption grants no authority. Parse solely to choose the enrolled key,
    // then verify that key and the exact original signed consent below.
    raw,clear:=channel.open(get(exchange,"envelope"),&kr,scope,now,context.temp_allocator)
    if !clear do return
    defer crypto.zero_explicit(raw_data(raw),len(raw))
    consent,c_ok:=contracts.executor_parse(raw,"issuance_consent")
    if !c_ok do return
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key_id,k_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !k_ok || get(consent,"executor_key_id")!=key_id do return
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found || !floor.root.set do return
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,key_id) {reply.code="storage_error";return}
    s:=&bridge_executor_store
    dir,trusted:=bridge_executor_directory(s,wire.directory,&kr)
    if !trusted do return
    approved,device_ok:=dir.trusted[get(consent,"principal_id")]
    enrolled,self_ok:=dir.trusted[key_id]
    if !device_ok || approved.kind!="browser" || !self_ok || enrolled.kind!="bridge" || enrolled.sign_public_key!=public do return
    device:=contracts.Owner_Verified_Key{account,approved.id,approved.id,approved.sign_public_key,"device",true,false}
    self:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,key_id,public,"bridge",true,false}
    verified,authenticated:=channel.open_signed(get(exchange,"envelope"),&kr,scope,device,now,context.temp_allocator)
    if !authenticated do return
    defer crypto.zero_explicit(raw_data(verified),len(verified))
    if contracts.executor_number(scope,"executor_incarnation")!=s.incarnation {reply.code="stale_incarnation";return}
    resources:=bridge_executor_resolve_issuance(s,get(exchange,"selection"))
    // No transaction spans resolver filesystem/profile I/O. issue rechecks the
    // signed mapping/policy under its own transaction before generating facts.
    result:=executor.issue(s,verified,get(exchange,"selection"),device,self,time.to_unix_nanoseconds(time.now())/1000000,
        resources,executor.Signer{nil,bridge_executor_sign})
    reply.code=result.code
    if result.code!="ok" do return
    response_scope:=scope
    response_scope["direction"]=json.String("response")
    sealed,sealed_ok:=channel.seal(result.body,&kr,response_scope,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
    if !sealed_ok {reply.code="expired";return}
    reply.envelope=sealed
}
