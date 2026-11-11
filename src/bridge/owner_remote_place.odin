#+feature dynamic-literals
package main

// Cross-Bridge placement, owner side (#9/#10, origin/main parity, user
// 13:28Z/15:30Z): the coordinator of a chain this Bridge owns assigns a task
// to an agent whose fleet policy names another Bridge of the account. This
// Bridge consents in its own name (owner-Bridge consent, auto selection),
// relays it through the Hub to the executor Bridge, which picks its own
// policy/slot/profile and per-chain directory and returns them in a signed
// remote_configuration plus its enrollment attestation. The owner store then
// records the reservation (fleet.reserve signed for the coordinator), whose
// attestation remote_assignment_child checks against the executor's approved,
// same-account, unrevoked key. No operator mapping and no device signature
// are needed; git work on the executor is never merged back (user 14:49Z).
//
// The directory fetch, the consent relay and the reply all run with no lock
// held; the owner store is entered twice (directory pin + task revision, then
// fleet.reserve), each time in the order owner -> startup_io -> token.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// A placement decided under the locks and finished after them.
Owner_Remote_Place :: struct {
    active:bool,
    chain,task,agent,executor_bridge,provider,model:string,
    // The chain's git repository on this Bridge ("" for a non-git chain): a
    // hint so the executor runs in its own checkout of the same project.
    repository:string,
    // The task's reviewer (a live member here), paired with the reserved
    // remote author by lifecycle.configure after fleet.reserve.
    reviewer:owner.Child,
}

// Whether the agent is placed on another Bridge: its fleet policy names a
// Bridge other than this one. provider/model come from the policy, or its
// per-Bridge override for the executor Bridge; both must be concrete because
// the consent binds them (the executor picks only profile, slot and directory).
// code "" means not remote (resolve a local child as before).
// Placement order: the task's run Bridge (pinned: "" or this Bridge runs it
// here), else the fleet row's Bridge, else this (the owner) Bridge.
bridge_owner_remote_target :: proc(s:^owner.Store,chain,agent:string,run_bridge:="",pinned:=false) -> (place:Owner_Remote_Place,code,message:string) {
    policy,found,ok:=owner.agent_fleet_policy(s,chain,agent)
    if !ok do return {},"storage_error","owner store could not be read"
    executor:=run_bridge if pinned else policy.bridge_id
    if executor=="" || executor==s.owner do return {},"",""
    provider,model:=policy.provider,policy.model
    if models,m_ok:=contracts.owner_fleet_models(policy.bridge_models_json);found && m_ok {
        if override,has:=models[executor];has {provider=override.provider;model=override.model}
    }
    if provider=="" || model=="" {
        return {},"invalid_scope",fmt.tprintf("agent %s runs on Bridge %s but its fleet policy names no provider and model for it; set them with `ham-ctl task-chain fleet set --agent %s --provider <p> --model <m>` (or a --bridge-models entry for %s)",agent,executor,agent,executor)
    }
    repository:=""
    if template,code:=owner.agent_assignment_template(s,chain);code=="ok" && template.merge_policy=="git" do repository=template.repository
    return Owner_Remote_Place{true,chain,"",agent,executor,provider,model,repository,{}},"ok",""
}

// The owner-side facts a consent and its reply are checked against, read
// under the locks: this Bridge's key at the current directory pin, the
// executor's approved key at the same pin, the next fleet revision of the
// task and the owner incarnation.
Owner_Remote_Pin :: struct {
    owner_key,remote_key:contracts.Owner_Verified_Key,
    account,owner_key_id,configuration_revision,owner_incarnation:string,
}

bridge_owner_remote_pin :: proc(request_id:string,place:Owner_Remote_Place,dir:vault.Directory_Verification_Input,executor_key:string,rec:Bridge_Local_Agent_Token_Record) -> (pin:Owner_Remote_Pin,code,message:string) {
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    key_id,_:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,key_id) do return {},"storage_error","owner store unavailable"
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return {},"vault_locked","owner Bridge vault is locked"
    s:=&bridge_owner_store
    owner_key,version,head,trusted:=bridge_owner_fence_directory(s,dir,&kr)
    if !trusted do return {},"directory_unverified","the account directory could not be verified at the owner pin"
    floor,status:=keystore_read_epoch_floor(bridge_cfg().daemon_id)
    if status!=.Found do return {},"directory_unverified","no paired root"
    remote,r_version,r_head,approved:=owner.verify_executor_directory(bridge_owner_json(dir),account,place.executor_bridge,executor_key,floor.root,version,head,&kr)
    if !approved || r_version!=version || r_head!=head {
        return {},"invalid_scope",fmt.tprintf("Bridge %s has no approved key of this account (paired, not revoked)",place.executor_bridge)
    }
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
    if _,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash);!current do return {},"invalid_scope","owner chain: current launched child required"
    st,found,ok:=owner.agent_task_state(s,place.chain,place.task)
    if !ok do return {},"storage_error","owner store could not be read"
    if !found do return {},"not_found","task not found"
    revision,_:=strconv.parse_i64(st.fleet_revision)
    return Owner_Remote_Pin{owner_key,remote,account,s.owner_key,fmt.tprintf("%d",revision+1),fmt.tprintf("%d",s.incarnation)},"ok",""
}

// The reservation as fleet.reserve stores it: the executor's configuration
// and attestation from a verified issuance bundle.
bridge_owner_remote_reservation :: proc(bundle:string) -> (reservation,instance:string,ok:bool) {
    b,valid:=contracts.executor_parse(bundle,"issuance_bundle")
    if !valid do return
    configuration:=contracts.owner_string(b,"configuration")
    c,c_ok:=contracts.owner_parse(configuration,"remote_configuration")
    if !c_ok do return
    reservation=bridge_owner_json(map[string]string{"configuration"=configuration,"attestation"=contracts.owner_string(b,"attestation")})
    if _,r_ok:=contracts.owner_parse(reservation,"remote_reservation");!r_ok do return "","",false
    return reservation,contracts.owner_string(c,"instance_id"),true
}

// fleet.reserve signed for the calling coordinator (exact live child).
bridge_owner_remote_reserve :: proc(request_id:string,place:Owner_Remote_Place,pin:Owner_Remote_Pin,reservation,instance:string,rec:Bridge_Local_Agent_Token_Record) -> (string,string) {
    key_id,_:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(pin.account,key_id) do return "storage_error","owner store unavailable"
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return "vault_locked","owner Bridge vault is locked"
    code,message:="invalid_scope","owner chain: current launched child required"
    {
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        caller,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
        if current {
            ctx:=Owner_Agent_Ctx{request_id=request_id,store=&bridge_owner_store,child=caller,key=pin.owner_key,kr=&kr,now=time.to_unix_nanoseconds(time.now())/1000000,rec=rec}
            code,message=bridge_owner_remote_reserve_locked(&ctx,place,pin,reservation,instance)
        }
    }
    // The new remote member republishes registry_members.
    if code=="ok" do bridge_owner_coordinator_refresh_locked(place.chain)
    bridge_owner_publish()
    return code,message
}

bridge_owner_remote_reserve_locked :: proc(ctx:^Owner_Agent_Ctx,place:Owner_Remote_Place,pin:Owner_Remote_Pin,reservation,instance:string) -> (string,string) {
    st,ok:=bridge_owner_reload(ctx,place.chain,place.task)
    if !ok do return "storage_error","owner store could not be read"
    // The consent bound this revision; a concurrent assignment wins.
    revision,_:=strconv.parse_i64(st.fleet_revision)
    if fmt.tprintf("%d",revision+1)!=pin.configuration_revision do return "operation_conflict","the task's assignment changed while Bridge placement was in flight; retry"
    body,sealed:=bridge_owner_cipher(ctx,reservation)
    if !sealed do return "storage_error","reservation could not be sealed"
    payload:=bridge_owner_json(map[string]string{"instance_id"=instance,"configuration_revision"=pin.configuration_revision,"enabled"="1","body_cipher"=body})
    r:=bridge_owner_run_command(ctx,"fleet.reserve",place.chain,place.task,st.task_revision,payload,remote_key=pin.remote_key)
    if r.code!="ok" do return r.code,"the owner store refused the remote reservation"
    return bridge_owner_remote_configure(ctx,place)
}

// lifecycle.configure for a remote author, as bridge_owner_assign does for a
// local one. The author is the child fleet.reserve recorded from the
// executor's verified enrollment (the store re-checks it against local_fleet);
// the reviewer must be a live member here. A remote author's commits stay in
// the executor Bridge's checkout (no merge-back, user 15:30Z), so the
// configuration is merge_policy none: the owner never inspects a worktree it
// does not have.
bridge_owner_remote_configure :: proc(ctx:^Owner_Agent_Ctx,place:Owner_Remote_Place) -> (string,string) {
    if place.reviewer.instance=="" do return "ok",""
    st,ok:=bridge_owner_reload(ctx,place.chain,place.task)
    if !ok do return "storage_error","owner store could not be read"
    rows,read:=owner.query(ctx.store.db,"SELECT instance_id,launch_epoch,run_count,token_generation,enabled FROM local_fleet WHERE chain_id=? AND task_id=?",place.chain,place.task)
    if !read || len(rows)!=1 || rows[0][4]!="1" do return "storage_error","the remote reservation is not recorded"
    run_count,_:=strconv.parse_i64(rows[0][2])
    author:=owner.Child{instance=rows[0][0],epoch=rows[0][1],token_generation=rows[0][3],run_count=run_count,agent_id=place.agent}
    reviewer,live:=bridge_owner_live_child(place.reviewer.instance)
    if !live || reviewer.agent_id!=place.reviewer.agent_id do return "invalid_scope",fmt.tprintf("reviewer %s is no longer running; the worker is placed on %s but not paired (retry with `ham-ctl task update %s --reviewer %s`)",place.reviewer.agent_id,place.executor_bridge,place.task,place.reviewer.agent_id)
    revision,_:=strconv.parse_i64(st.config_max_revision)
    config:=map[string]string{"configuration_revision"=fmt.tprintf("%d",revision+1),"author_agent_id"=author.agent_id,
        "reviewer_agent_id"=reviewer.agent_id,"reviewer_instance_id"=reviewer.instance,"directory_id"="owner_none","merge_policy"="none",
        "repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}
    raw:=bridge_owner_json(config)
    if _,valid:=contracts.owner_parse(raw,"lifecycle_config_payload");!valid do return "invalid_content","derived lifecycle configuration is invalid"
    r:=bridge_owner_run_command(ctx,"lifecycle.configure",place.chain,place.task,st.task_revision,raw,proof=owner.Lifecycle_Proof{author,reviewer,true})
    if r.code!="ok" do return r.code,"pairing the remote worker with its reviewer was refused"
    return "ok",""
}

// The whole placement, called with no lock held. Returns the reserved
// instance on the executor Bridge.
bridge_owner_remote_place :: proc(request_id:string,place:Owner_Remote_Place,rec:Bridge_Local_Agent_Token_Record) -> (code,message,instance:string) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    dir,executor_key,fetched:=bridge_executor_directory_bridge_key(generation,place.executor_bridge)
    if !fetched do return "executor_unavailable",fmt.tprintf("the Hub did not name an enrolled key for Bridge %s",place.executor_bridge),""
    pin,pin_code,pin_message:=bridge_owner_remote_pin(request_id,place,dir,executor_key,rec)
    if pin_code!="ok" do return pin_code,pin_message,""
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return "vault_locked","owner Bridge vault is locked",""
    now:=time.to_unix_nanoseconds(time.now())/1000000
    input:=Executor_Issuance_Request_Input{account=pin.account,owner_bridge=bridge_cfg().daemon_id,owner_key_id=pin.owner_key_id,
        executor_bridge=place.executor_bridge,executor_key_id=executor_key,chain_id=place.chain,task_id=place.task,agent_id=place.agent,
        configuration_revision=pin.configuration_revision,owner_incarnation=pin.owner_incarnation,provider=place.provider,model=place.model,now=now}
    request,built:=bridge_executor_issuance_request(input,&kr,{nil,bridge_executor_consent_sign})
    if !built do return "storage_error","the issuance consent could not be built",""
    reply_code,reply_request,envelope,sent:=bridge_executor_issuance_send(request,place.repository)
    if !sent do return "executor_unavailable",fmt.tprintf("Bridge %s did not answer the placement request",place.executor_bridge),""
    if reply_code!="ok" do return reply_code,fmt.tprintf("Bridge %s refused the placement (%s)",place.executor_bridge,reply_code),""
    bundle,opened:=bridge_executor_issuance_reply_open(request,reply_code,reply_request,envelope,&kr,pin.owner_key,pin.remote_key,time.to_unix_nanoseconds(time.now())/1000000)
    if !opened do return "invalid_scope",fmt.tprintf("Bridge %s returned an issuance that does not verify",place.executor_bridge),""
    reservation,reserved,valid:=bridge_owner_remote_reservation(bundle)
    if !valid do return "invalid_content","the executor's configuration is invalid",""
    code,message=bridge_owner_remote_reserve(request_id,place,pin,reservation,reserved,rec)
    if code!="ok" do return code,message,""
    return "ok","",reserved
}

// The reply of a create/update whose assignee was placed on another Bridge.
bridge_owner_remote_place_reply :: proc(request_id,response:string,place:Owner_Remote_Place,rec:Bridge_Local_Agent_Token_Record) -> string {
    code,message,instance:=bridge_owner_remote_place(request_id,place,rec)
    if code!="ok" {
        return bridge_local_response_error(request_id,code,fmt.tprintf("task %s saved; placing agent %s on Bridge %s failed: %s (retry with `ham-ctl task update %s --assignee %s`)",place.task,place.agent,place.executor_bridge,message,place.task,place.agent))
    }
    envelope:=bridge_owner_result_object(response)
    data,_:=envelope["data"].(json.Object)
    if data==nil do data=make(json.Object,context.temp_allocator)
    data["assignee_bridge_id"]=json.String(place.executor_bridge)
    data["assignee_instance_id"]=json.String(instance)
    return bridge_local_response_data(request_id,bridge_owner_json(data))
}

// A task's run Bridge (--bridge) must be an approved, unrevoked Bridge key of
// this account in the verified account directory, the same check a remote
// placement makes. Runs before the task route, with no lock held, so a
// refused Bridge leaves nothing saved. Tests replace it.
@(thread_local)
bridge_owner_run_bridge_check_hook:proc(bridge:string) -> (string,string)
bridge_owner_run_bridge_check :: proc(bridge:string) -> (code,message:string) {
    if bridge_owner_run_bridge_check_hook!=nil do return bridge_owner_run_bridge_check_hook(bridge)
    context.allocator=context.temp_allocator
    refused:=fmt.tprintf("--bridge %s is not a paired, unrevoked Bridge of this account",bridge)
    dir,executor_key,fetched:=bridge_executor_directory_bridge_key(bridge_task_chain_search_generation(),bridge)
    if !fetched do return "invalid_scope",refused
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    key_id,_:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,key_id) do return "storage_error","owner store unavailable"
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return "vault_locked","owner Bridge vault is locked"
    _,version,head,trusted:=bridge_owner_fence_directory(&bridge_owner_store,dir,&kr)
    if !trusted do return "directory_unverified","the account directory could not be verified at the owner pin"
    floor,status:=keystore_read_epoch_floor(bridge_cfg().daemon_id)
    if status!=.Found do return "directory_unverified","no paired root"
    _,_,_,approved:=owner.verify_executor_directory(bridge_owner_json(dir),account,bridge,executor_key,floor.root,version,head,&kr)
    if !approved do return "invalid_scope",refused
    return "ok",""
}

bridge_owner_response_ok :: proc(response:string) -> bool {
    ok,_:=bridge_owner_result_object(response)["ok"].(json.Boolean)
    return bool(ok)
}
