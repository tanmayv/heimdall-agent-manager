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

bridge_executor_root :: proc(account:string)->(string,bool) {
    dir,ok:=bridge_vault_bridge_dir(bridge_cfg().daemon_id,context.temp_allocator)
    if !ok do return "",false
    return fmt.tprintf("%sexecutor-local-%s",dir,contracts.owner_payload_digest(account)),true
}
bridge_executor_open :: proc(account,key:string)->bool {
    if bridge_executor_store.db!=nil do return bridge_executor_store.account==account && bridge_executor_store.operator_key==key
    path,ok:=bridge_executor_root(account)
    if !ok do return false
    if bridge_make_directory_all(path,{.Read_User,.Write_User,.Execute_User})!=nil do return false
    when ODIN_OS!=.Windows {
        if os.chmod(path,{.Read_User,.Write_User,.Execute_User})!=nil do return false
    }
    saved:=context.allocator;context.allocator=runtime.default_allocator()
    opened:=executor.open(&bridge_executor_store,fmt.tprintf("%s/runtime.sqlite",path),account,bridge_cfg().daemon_id,key)
    context.allocator=saved
    if opened do _=executor.complete_recovery(&bridge_executor_store,time.to_unix_nanoseconds(time.now())/1000000)
    return opened
}
bridge_executor_sign :: proc(_:rawptr,kind:string,o:json.Object)->(string,bool) {
    if kind!="notification_result" && kind!="notification_fence_request" && kind!="local_result" && kind!="enrollment" && kind!="issuance_receipt" && kind!="receipt" && kind!="fence_request" && kind!="child_request" do return "",false
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
    return executor.Issuance_Resources{selection_digest=contracts.owner_payload_digest(selection_raw),directory_key=mapping.key,directory_path=canonical,resolved=true}
}

// Owner-Bridge consent (cross-Bridge placement, user decision 15:30Z option b):
// the consent names only provider and model. This executor chooses for itself,
// with no operator mapping:
//   - profile: the provider's default profile on this Bridge (enabled);
//   - policy/slot: the current policy's first enabled slot for that profile.
//     With no policy at all, it installs revision 1 with one slot for the
//     profile, signed by its own operator key. An operator policy without a
//     slot for the profile is kept (the operator owns it; refused);
//   - directory: this Bridge's own checkout of the owner chain's repository
//     when the Hub names one (project_hint, user 15:30Z: git tickets run in
//     B's checkout, no merge-back) and it is a valid project directory inside
//     this Bridge's file root; otherwise a per-chain scratch directory under
//     this executor's private root. Either is self-mapped with its own
//     operator key. A bad or missing hint falls back to scratch, never a
//     refusal. Nothing in the signed request names a path.
// The chosen selectors go back in the signed remote_configuration.
BRIDGE_EXECUTOR_AUTO_CAPACITY :: "4"
bridge_executor_resolve_auto_issuance :: proc(s:^executor.Store,consent:json.Object,selection_raw:string,self:contracts.Owner_Verified_Key,project_hint:="")->executor.Issuance_Resources {
    selection,valid:=contracts.executor_parse(selection_raw,"issuance_selection")
    if !valid || !contracts.executor_selection_auto(selection) || self.key_id!=s.operator_key do return {}
    get:=contracts.owner_string
    provider,model:=get(selection,"provider"),get(selection,"model")
    // The account catalog decides, like a local launch: this Bridge's observed
    // model list may name aliases only (claude 2.1.295 reports 'sonnet',
    // 'claude-sonnet-5', not 'claude-sonnet-5-5'), which refused every placement
    // with invalid_resources (REQ-E2E-1 dawnstar-b, task_18e70e69aca835a7).
    if !bridge_provider_catalog_has_model(provider,model) {
        if _,_,active:=bridge_owner_agent_model_resolve(provider,model);!active || model=="" {
            fmt.eprintfln("bridge executor: placement refused: %s/%s is neither observed on this Bridge nor an active catalog model",provider,model)
            return {}
        }
    }
    profile,err:=profile_lookup(provider,provider,context.temp_allocator,false)
    if err!=.None || !profile.enabled || profile.provider!=provider || !contracts.owner_field_valid(profile.profile_id,"id") {
        fmt.eprintfln("bridge executor: placement refused: no enabled default %s profile on this Bridge",provider)
        return {}
    }
    revision,slot,found:=executor.auto_slot(s,profile.profile_id)
    if !found {
        if revision!=0 do return {}
        slots:=executor.encode([1]struct{slot_id,provider_profile,enabled:string}{{fmt.tprintf("auto_%s",profile.profile_id),profile.profile_id,"1"}})
        record:=executor.encode(struct{protocol_version,account_id,executor_bridge_id,policy_revision,device_capacity,slots_json,key_id,signature:string}{
            "1",s.account,s.executor,"1",BRIDGE_EXECUTOR_AUTO_CAPACITY,slots,s.operator_key,strings.repeat("0",128,context.temp_allocator)})
        signed,code:=bridge_executor_operator_sign_record("policy",record)
        if code!="ok" || executor.install_policy(s,signed,self,bridge_executor_physical_clock(nil)).code!="ok" do return {}
        revision,slot,found=executor.auto_slot(s,profile.profile_id)
        if !found do return {}
    }
    canonical,directory_id,placed:=bridge_executor_auto_directory(s.account,get(consent,"chain_id"),project_hint)
    if !placed do return {}
    key:=executor.directory_key(s.executor,canonical)
    mapping,mapped:=executor.directory_mapping(s,directory_id)
    if !mapped || mapping.path!=canonical || mapping.key!=key {
        latest,latest_ok:=executor.directory_latest_revision(s,directory_id)
        if !latest_ok do return {}
        next:=latest+1
        record:=executor.encode(struct{protocol_version,account_id,executor_bridge_id,directory_id,revision,directory_path,enabled,key_id,signature:string}{
            "1",s.account,s.executor,directory_id,fmt.tprintf("%d",next),canonical,"1",s.operator_key,strings.repeat("0",128,context.temp_allocator)})
        signed,code:=bridge_executor_operator_sign_record("directory",record)
        if code!="ok" || executor.install_directory(s,signed,self,bridge_executor_physical_clock(nil),canonical).code!="ok" do return {}
    }
    chosen:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{
        provider,model,profile.profile_id,directory_id,fmt.tprintf("%d",revision),slot})
    if _,chosen_ok:=contracts.executor_parse(chosen,"issuance_selection");!chosen_ok do return {}
    return executor.Issuance_Resources{selection_digest=contracts.owner_payload_digest(selection_raw),directory_key=key,
        directory_path=canonical,selection=chosen,resolved=true}
}

// The directory an owner-Bridge consent runs in: the hinted project checkout
// when it is a valid project directory inside this Bridge's file root, else
// the chain's scratch directory (created on demand).
bridge_executor_auto_directory :: proc(account,chain_id,project_hint:string)->(canonical,directory_id:string,ok:bool) {
    if project_hint!="" {
        if project,valid:=bridge_executor_project_directory(project_hint);valid {
            if c,within:=bridge_executor_canonical_directory(project);within {
                return c,fmt.tprintf("project_%s",contracts.owner_payload_digest(c)[:24]),true
            }
        }
    }
    root,rooted:=bridge_executor_root(account)
    if !rooted do return "","",false
    chain:=contracts.owner_payload_digest(chain_id)[:24]
    path:=fmt.tprintf("%s/scratch/%s",root,chain)
    if bridge_make_directory_all(path,{.Read_User,.Write_User,.Execute_User})!=nil do return "","",false
    c,within:=bridge_executor_canonical_directory(path)
    if !within do return "","",false
    return c,fmt.tprintf("scratch_%s",chain),true
}

// The key that may consent to an issuance on this executor, from the verified
// paired directory (approved, unrevoked, this account):
//   - a browser device of the account (principal_id is its key id), or
//   - the chain's owner Bridge (origin/main parity: its coordinator places work
//     on any Bridge of the account, with no device prompt). The Hub must have
//     relayed the request from that Bridge's token (from_bridge_id), the consent
//     must name it as owner_bridge_id and principal_id, it must be an approved
//     Bridge key whose id derives from its public key, and it is never this
//     executor's own key (a Bridge cannot consent to work for itself).
// executor_verify then checks the signature against the returned key.
bridge_executor_consent_key :: proc(dir:^vault.Verified_Directory,consent:json.Object,account,self_key_id,from_bridge:string)->(contracts.Owner_Verified_Key,bool) {
    get:=contracts.owner_string
    if device,found:=dir.trusted[get(consent,"principal_id")];found && device.kind=="browser" {
        return contracts.Owner_Verified_Key{account,device.id,device.id,device.sign_public_key,"device",true,false},true
    }
    key_id,principal:=get(consent,"key_id"),get(consent,"principal_id")
    bridge,found:=dir.trusted[key_id]
    if !found || bridge.kind!="bridge" || key_id==self_key_id || principal=="" || principal!=from_bridge || principal!=get(consent,"owner_bridge_id") ||
       principal==get(consent,"executor_bridge_id") {return {},false}
    derived,derived_ok:=vault.device_id_from_sign_pub(bridge.sign_public_key,context.temp_allocator)
    if !derived_ok || derived!=key_id do return {},false
    return contracts.Owner_Verified_Key{account,principal,key_id,bridge.sign_public_key,"bridge",true,false},true
}

Executor_Issuance_Wire :: struct {
    // from_bridge_id: set by the Hub from the relaying Bridge's token, "" when
    // the user relayed it (bridge_executor_consent_key). project_path: the
    // Hub's unsigned hint for an owner-Bridge consent, this Bridge's checkout
    // of the owner chain's repository ("" when none); re-validated here.
    type,command_id,account_id,from_bridge_id,relay,project_path:string,
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
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    expires:=contracts.executor_number(relay,"expires_ms")
    if wire.account_id!=account || get(relay,"bridge_id")!=bridge_cfg().daemon_id ||
       expires<=now || expires-now>contracts.EXECUTOR_TRANSPORT_TTL_MS {return}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {reply.code="vault_locked";return}
    plain,opened:=bridge_open_current_epoch_token(get(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    defer crypto.zero_explicit(raw_data(plain),len(plain))
    exchange,parsed:=contracts.executor_parse(plain,"issuance_exchange")
    scope,scoped:=contracts.executor_parse(get(exchange,"scope"),"transport_scope")
    if !parsed || !scoped || get(scope,"method")!="enrollment" || get(scope,"direction")!="request" ||
       get(scope,"account_id")!=account || get(scope,"executor_bridge_id")!=bridge_cfg().daemon_id ||
       get(scope,"chain_id")!=get(relay,"chain_id") || get(scope,"request_id")!=get(relay,"request_id") ||
       contracts.executor_number(scope,"request_expires_ms")>expires {return}
    // Decryption grants no authority. Parse solely to choose the enrolled key,
    // then verify that key and the exact original signed consent below.
    raw,clear:=channel.open(get(exchange,"envelope"),&kr,scope,now,context.temp_allocator)
    if !clear do return
    defer crypto.zero_explicit(raw_data(raw),len(raw))
    consent,c_ok:=contracts.executor_parse(raw,"issuance_consent")
    if !c_ok do return
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    key_id,k_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !k_ok || get(consent,"executor_key_id")!=key_id do return
    floor,status:=keystore_read_epoch_floor(bridge_cfg().daemon_id)
    if status!=.Found || !floor.root.set do return
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,key_id) {reply.code="storage_error";return}
    s:=&bridge_executor_store
    dir,trusted:=bridge_executor_directory(s,wire.directory,&kr)
    if !trusted do return
    enrolled,self_ok:=dir.trusted[key_id]
    if !self_ok || enrolled.kind!="bridge" || enrolled.sign_public_key!=public do return
    device,consenter_ok:=bridge_executor_consent_key(&dir,consent,account,key_id,wire.from_bridge_id)
    if !consenter_ok do return
    self:=contracts.Owner_Verified_Key{account,bridge_cfg().daemon_id,key_id,public,"bridge",true,false}
    verified,authenticated:=channel.open_signed(get(exchange,"envelope"),&kr,scope,device,now,context.temp_allocator)
    if !authenticated do return
    defer crypto.zero_explicit(raw_data(verified),len(verified))
    // An owner-Bridge consent cannot know this executor's incarnation (its
    // auto selection asks this executor to choose); the signed configuration
    // names it and every later launch fence binds it.
    resources:executor.Issuance_Resources
    if device.kind=="bridge" {
        resources=bridge_executor_resolve_auto_issuance(s,consent,get(exchange,"selection"),self,wire.project_path)
    } else {
        if contracts.executor_number(scope,"executor_incarnation")!=s.incarnation {reply.code="stale_incarnation";return}
        resources=bridge_executor_resolve_issuance(s,get(exchange,"selection"))
    }
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
