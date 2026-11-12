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
import "core:strconv"
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
    if !within || canonical!=path {
        // The Bridge's own directories are not user paths: fs_root (the UI's
        // filesystem sandbox) may exclude them (fs_root=/srv/projects, an
        // isolated HOME), which refused every no-directory placement on
        // scratch with a silent invalid_resources (REQ-EXEC-NEVER-BLOCK, F5).
        if !bridge_executor_private_directory(path) do return "",false
    }
    if !bridge_validate_project_path_local(path,"","").ok do return "",false
    return strings.clone(path,context.temp_allocator),true
}
// bridge_executor_private_directory: path is canonical (symlink-free) and
// inside one of the two Bridge-owned work areas: the executor's per-chain
// scratch (<executor root>/scratch) or the agent run dirs (<endpoint run
// dir>/instances). Never the config dir, the vault material or the executor
// store itself, and never a whole endpoint run dir (it may be a shared parent
// such as /tmp): fs_root still guards everything else.
bridge_executor_private_directory :: proc(path:string)->bool {
    scratch:=""
    // Callers hold bridge_executor_mutex (or are the executor itself).
    account:=bridge_executor_store.account if bridge_executor_store.account!="" else bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    if account!="" {
        if root,rooted:=bridge_executor_root(account);rooted do scratch=fmt.tprintf("%s/scratch",root)
    }
    runs:=strings.trim_right(bridge_cfg().local_endpoint_run_dir,"/")
    if runs=="" do runs=bridge_scratch_local_default(context.temp_allocator) // as bridge_runtime_default_run_dir
    for root in ([2]string{scratch,fmt.tprintf("%s/instances",runs) if runs!="" else ""}) {
        if root=="" do continue
        real,tail:=bridge_fs_realpath_existing_prefix(root)
        defer {delete(real);delete(tail)}
        if real=="" || tail!="" do continue
        canonical,within:=bridge_fs_resolve_within(path,real)
        defer delete(canonical)
        if within && canonical==path && canonical!=real do return true
    }
    return false
}
// bridge_executor_refuse records why a resolver refused (the component that
// failed) for the caller's log line, and returns the unresolved resources.
bridge_executor_refuse :: proc(why:^string,format:string,args:..any)->executor.Issuance_Resources {
    reason:=fmt.tprintf(format,..args)
    if why!=nil do why^=reason
    fmt.eprintfln("bridge executor: %s",reason)
    return {}
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
// The account catalog decides, like a local launch: this Bridge's observed
// model list may name aliases only (claude 2.1.295 reports 'sonnet',
// 'claude-sonnet-5', not 'claude-sonnet-5-5'). Requiring an observed model
// refused placement (REQ-E2E-1 .12, task_18e70e69aca835a7) and then every
// prepare of the issued selection (.14, task_18e72ea85b7d4f43) with
// invalid_resources. An inactive or unknown model is still refused, logged.
// G4 round 1: issuance and prepare apply the launch rule to the SELECTED
// profile (its own snapshot and custom models), so they accept exactly what
// the launch of that profile accepts.
bridge_executor_model_allowed :: proc(p:^Provider_Profile,provider,model:string) -> bool {
    return profile_has_model(p,provider,model,"executor issuance/prepare")
}
// Refusals name the failing component (model, profile, slot, directory) in
// `why` and in the Bridge log.
bridge_executor_resolve_issuance :: proc(s:^executor.Store,selection_raw:string,why:^string=nil)->executor.Issuance_Resources {
    selection,valid:=contracts.executor_parse(selection_raw,"issuance_selection")
    if !valid do return bridge_executor_refuse(why,"selection: malformed issuance selection")
    get:=contracts.owner_string
    mapping,found:=executor.directory_mapping(s,get(selection,"directory_id"))
    if !found do return bridge_executor_refuse(why,"directory: %s is not mapped on this Bridge",get(selection,"directory_id"))
    canonical,within:=bridge_executor_canonical_directory(mapping.path)
    if !within do return bridge_executor_refuse(why,"directory: %s (%s) is missing or not a usable directory",get(selection,"directory_id"),mapping.path)
    if executor.directory_key(s.executor,canonical)!=mapping.key do return bridge_executor_refuse(why,"directory: %s no longer matches its mapped key",get(selection,"directory_id"))
    provider,model,profile:=get(selection,"provider"),get(selection,"model"),get(selection,"provider_profile")
    resolved,err:=profile_lookup(provider,profile)
    if err!=.None || !resolved.enabled || resolved.provider!=provider || resolved.profile_id!=profile {
        return bridge_executor_refuse(why,"profile: %s/%s is not an enabled profile on this Bridge",provider,profile)
    }
    if !bridge_executor_model_allowed(&resolved,provider,model) do return bridge_executor_refuse(why,"model: %s/%s is not a custom model of profile %s, not observed by it and not an active catalog model",provider,model,profile)
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
BRIDGE_EXECUTOR_AUTO_CAPACITY :: 4
Bridge_Executor_Slot :: struct{slot_id,provider_profile,enabled:string}
bridge_executor_resolve_auto_issuance :: proc(s:^executor.Store,consent:json.Object,selection_raw:string,self:contracts.Owner_Verified_Key,project_hint:="",why:^string=nil)->executor.Issuance_Resources {
    selection,valid:=contracts.executor_parse(selection_raw,"issuance_selection")
    if !valid || !contracts.executor_selection_auto(selection) do return bridge_executor_refuse(why,"selection: not an auto selection")
    if self.key_id!=s.operator_key do return bridge_executor_refuse(why,"selection: only this executor's own key provisions")
    get:=contracts.owner_string
    provider,model:=get(selection,"provider"),get(selection,"model")
    profile,err:=profile_lookup(provider,provider,context.temp_allocator,false)
    if err!=.None || !profile.enabled || profile.provider!=provider || !contracts.owner_field_valid(profile.profile_id,"id") {
        return bridge_executor_refuse(why,"profile: no enabled default %s profile on this Bridge",provider)
    }
    if !bridge_executor_model_allowed(&profile,provider,model) do return bridge_executor_refuse(why,"model: %s/%s is not a custom model of profile %s, not observed by it and not an active catalog model",provider,model,profile.profile_id)
    revision,slot,found:=executor.auto_slot(s,profile.profile_id)
    if !found {
        // No policy yet: this executor installs one with an auto slot for the
        // profile. An operator policy is extended with that slot (the operator
        // key is this executor's own), never replaced.
        slot_rows:=make([dynamic]Bridge_Executor_Slot,context.temp_allocator)
        capacity:=BRIDGE_EXECUTOR_AUTO_CAPACITY
        if revision!=0 {
            sync.mutex_lock(&s.mutex)
            rows,read:=executor.query(s.db,"SELECT slot_id,provider_profile,enabled FROM executor_slots WHERE enabled=1 ORDER BY slot_id")
            cap_rows,cap_read:=executor.query(s.db,"SELECT device_capacity FROM executor_runtime WHERE singleton=1")
            sync.mutex_unlock(&s.mutex)
            if !read || !cap_read || len(cap_rows)!=1 do return bridge_executor_refuse(why,"slot: the executor policy could not be read")
            for r in rows do append(&slot_rows,Bridge_Executor_Slot{r[0],r[1],r[2]})
            if n,parsed:=strconv.parse_int(cap_rows[0][0]);parsed && n>0 do capacity=n
        }
        append(&slot_rows,Bridge_Executor_Slot{fmt.tprintf("auto_%s",profile.profile_id),profile.profile_id,"1"})
        // The policy must hold its slots: capacity grows with the auto slot.
        if needed:=len(slot_rows);needed>capacity {
            if needed>contracts.EXECUTOR_CAPACITY_MAX do return bridge_executor_refuse(why,"slot: the executor policy is full (%d slots)",needed-1)
            capacity=needed
        }
        slots:=executor.encode(slot_rows[:])
        record:=executor.encode(struct{protocol_version,account_id,executor_bridge_id,policy_revision,device_capacity,slots_json,key_id,signature:string}{
            "1",s.account,s.executor,fmt.tprintf("%d",revision+1),fmt.tprintf("%d",capacity),slots,s.operator_key,strings.repeat("0",128,context.temp_allocator)})
        signed,code:=bridge_executor_operator_sign_record("policy",record)
        if code!="ok" do return bridge_executor_refuse(why,"slot: signing the auto-slot policy failed (%s)",code)
        installed:=executor.install_policy(s,signed,self,bridge_executor_physical_clock(nil))
        // A concurrent issuance may have installed the same slot first
        // (stale_revision here): use it when it is now there.
        revision,slot,found=executor.auto_slot(s,profile.profile_id)
        if installed.code!="ok" && !found {
            return bridge_executor_refuse(why,"slot: no enabled slot for profile %s and installing the auto slot failed (%s)",profile.profile_id,installed.code)
        }
        if !found do return bridge_executor_refuse(why,"slot: no enabled slot for profile %s after installing the auto slot",profile.profile_id)
    }
    canonical,directory_id,placed:=bridge_executor_auto_directory(s.account,get(consent,"chain_id"),project_hint)
    if !placed do return bridge_executor_refuse(why,"directory: the chain's scratch directory could not be created under this executor's root")
    key:=executor.directory_key(s.executor,canonical)
    mapping,mapped:=executor.directory_mapping(s,directory_id)
    if !mapped || mapping.path!=canonical || mapping.key!=key {
        latest,latest_ok:=executor.directory_latest_revision(s,directory_id)
        if !latest_ok do return bridge_executor_refuse(why,"directory: reading the mapping of %s failed",directory_id)
        next:=latest+1
        record:=executor.encode(struct{protocol_version,account_id,executor_bridge_id,directory_id,revision,directory_path,enabled,key_id,signature:string}{
            "1",s.account,s.executor,directory_id,fmt.tprintf("%d",next),canonical,"1",s.operator_key,strings.repeat("0",128,context.temp_allocator)})
        signed,code:=bridge_executor_operator_sign_record("directory",record)
        if code!="ok" do return bridge_executor_refuse(why,"directory: signing the mapping of %s failed (%s)",directory_id,code)
        if installed:=executor.install_directory(s,signed,self,bridge_executor_physical_clock(nil),canonical);installed.code!="ok" {
            return bridge_executor_refuse(why,"directory: mapping %s to %s failed (%s)",directory_id,canonical,installed.code)
        }
    }
    chosen:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{
        provider,model,profile.profile_id,directory_id,fmt.tprintf("%d",revision),slot})
    if _,chosen_ok:=contracts.executor_parse(chosen,"issuance_selection");!chosen_ok do return bridge_executor_refuse(why,"selection: the chosen selection is malformed")
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

// The scratch directory this executor placed a no-directory chain's work in
// ("" when the chain was not placed in scratch, e.g. it runs in a checkout).
bridge_executor_scratch_workdir :: proc(account,chain_id:string)->string {
    root,rooted:=bridge_executor_root(account)
    if !rooted || chain_id=="" do return ""
    path:=fmt.tprintf("%s/scratch/%s",root,contracts.owner_payload_digest(chain_id)[:24])
    if !os.is_dir(path) do return ""
    canonical,within:=bridge_executor_canonical_directory(path)
    return canonical if within else ""
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
    why:=""
    if device.kind=="bridge" {
        resources=bridge_executor_resolve_auto_issuance(s,consent,get(exchange,"selection"),self,wire.project_path,&why)
    } else {
        if contracts.executor_number(scope,"executor_incarnation")!=s.incarnation {reply.code="stale_incarnation";return}
        resources=bridge_executor_resolve_issuance(s,get(exchange,"selection"),&why)
    }
    // No transaction spans resolver filesystem/profile I/O. issue rechecks the
    // signed mapping/policy under its own transaction before generating facts.
    result:=executor.issue(s,verified,get(exchange,"selection"),device,self,time.to_unix_nanoseconds(time.now())/1000000,
        resources,executor.Signer{nil,bridge_executor_sign})
    reply.code=result.code
    if result.code!="ok" {
        bridge_executor_log_refusal("issuance",get(exchange,"request_id") if get(exchange,"request_id")!="" else get(scope,"request_id"),get(scope,"chain_id"),get(scope,"owner_bridge_id"),result.code,
            why if why!="" else ("the selection's resources changed while it was issued" if result.code=="invalid_resources" else ""))
        return
    }
    response_scope:=scope
    response_scope["direction"]=json.String("response")
    sealed,sealed_ok:=channel.seal(result.body,&kr,response_scope,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
    if !sealed_ok {reply.code="expired";return}
    reply.envelope=sealed
}
