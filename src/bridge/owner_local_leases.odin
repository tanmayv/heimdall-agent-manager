#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:fmt"
import vault "odin_test:lib/vault"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

// Caller holds startup I/O then token mutex through the owner commit, so stop/rotation/relaunch
// cannot race admission after exact-child validation.
// The exact live child of an instance for an owner decision about ANOTHER
// instance (assignment, lifecycle proof, review dispatch). Tests substitute
// bridge_owner_live_probe (no PTY host); caller holds the child locks.
bridge_owner_live_probe:proc(instance:string) -> (owner.Child,bool)
bridge_owner_live_child :: proc(instance:string) -> (owner.Child,bool) {
    if bridge_owner_live_probe!=nil do return bridge_owner_live_probe(instance)
    return bridge_owner_child_locked(instance,"")
}

bridge_owner_child_locked :: proc(instance,token_hash:string) -> (owner.Child,bool) {
    inst,found:=bridge_runtime_instance_snapshot(instance)
    if !found || inst.stopped_intent_unix_ms!=0 || !inst.pty_process_alive || !bridge_runtime_status_active(inst.runtime_status) do return {},false
    for i:=len(bridge_local_token_records)-1;i>=0;i-=1 {
        r:=bridge_local_token_records[i]
        if r.agent_instance_id!=instance || r.role!=.Agent || r.invalidated_at_unix_ms!=0 do continue
        if token_hash!="" && r.token_hash!=token_hash do return {},false
        separator:=strings.index(r.instance_token,"~")
        if r.run_count<=0 do return {},false
        // Query the actual daemon child by its exact launch key. A cached
        // running flag or a copied token cannot stand in for a live PTY child.
        socket:=pty_host_socket_path()
        launch_key:=inst.startup.launch_key
        if launch_key=="" || inst.startup.rec.token_hash!=r.token_hash { delete(socket);return {},false }
        pid,queried:=bridge_pty_host_startup_launch(socket,instance,launch_key)
        delete(socket)
        if !queried || pid==0 do return {},false
        generation:=contracts.owner_payload_digest(r.token_hash)
        epoch:=fmt.tprintf("local_%s",contracts.owner_payload_digest(launch_key))
        // Initial legacy Hub launches have no migration epoch. Their unique
        // local launch key supplies a durable Bridge-defined launch identity.
        if separator>=0 do epoch=r.instance_token[separator+1:]
        if !contracts.owner_field_valid(epoch,"id") do return {},false
        launch,has_launch:=bridge_runtime_get_launch(instance)
        if !has_launch do return {},false
        return owner.Child{instance,epoch,generation,i64(r.run_count),launch.agent_id},true
    }
    return {},false
}

bridge_owner_agent :: proc(request_id,params:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    input,valid:=contracts.owner_parse(params,"lease_input")
    lifecycle:=false
    if !valid { input,valid=contracts.owner_parse(params,"lifecycle_input");lifecycle=valid }
    if !valid do return bridge_local_response_error(request_id,"malformed","invalid owner-local lease input")
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    pub:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(pub,context.temp_allocator)
    if !key_ok do return bridge_local_response_error(request_id,"invalid_scope","owner identity unavailable")
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,key_id) do return bridge_local_response_error(request_id,"storage_error","owner store unavailable")
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    if !current do return bridge_local_response_error(request_id,"invalid_scope","current launched child required")
    now:=time.to_unix_nanoseconds(time.now())/1000000
    cap:=contracts.owner_string(input,"capability")
    command:=make(json.Object,context.temp_allocator)
    for f in ([10]string{"chain_id","task_id","lease_id","configuration_revision","expected_revision","operation_id","method","request_expires_ms","protocol_version","capability_digest"}) {
        if f=="capability_digest" {command[f]=json.String(contracts.owner_payload_digest(cap))} else {command[f]=input[f]}
    }
    command["account_id"]=json.String(account);command["owner_bridge_id"]=json.String(bridge_cfg().daemon_id)
    command["instance_id"]=json.String(child.instance);command["launch_epoch"]=json.String(child.epoch)
    command["run_count"]=json.String(fmt.tprintf("%d",child.run_count));command["token_generation"]=json.String(child.token_generation)
    command["key_id"]=json.String(key_id);command["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    kind:="lease_command"
    payload:=""
    if lifecycle {
        kind="lifecycle_command"
        payload=contracts.owner_string(input,"payload")
        command["payload_digest"]=json.String(contracts.owner_payload_digest(payload))
    }
    signature,signed:=bridge_owner_sign(nil,kind,command)
    if !signed do return bridge_local_response_error(request_id,"storage_error","attestation signing failed")
    command["signature"]=json.String(signature)
    key:=contracts.Owner_Verified_Key{account,bridge_cfg().daemon_id,key_id,pub,"bridge",true,false}
    result:owner.Result
    if lifecycle {
        proof:=bridge_owner_source_proof(&bridge_owner_store,contracts.owner_string(command,"chain_id"),contracts.owner_string(command,"task_id"))
        result=owner.execute_lifecycle(&bridge_owner_store,bridge_owner_json(command),payload,cap,child,key,now,owner.Signer{nil,bridge_owner_sign},proof)
    } else { result=owner.execute_lease(&bridge_owner_store,bridge_owner_json(command),cap,child,key,now,owner.Signer{nil,bridge_owner_sign}) }
    if result.code!="ok" do return bridge_local_response_error(request_id,result.code,"owner-local lease rejected")
    if lifecycle && contracts.owner_string(command,"method")=="requirements.present" && !result.replay {
        launch,launched:=bridge_runtime_get_launch(child.instance)
        if !launched || !bridge_owner_materialize_context(launch.run_dir,command,result.body) {
            // The source commit and receipt already exist. Never imply a file
            // was delivered when the atomic write failed.
            return bridge_local_response_error(request_id,"context_delivery_failed","requirements committed; TASK.md write failed; retry with a new requirements.present operation")
        }
    }
    return bridge_local_response_data(request_id,bridge_owner_json(result))
}

// Separate worker: expiry and registry retries also run when nobody is making
// requests or the Hub connection is down.
bridge_owner_maintenance_once :: proc() {
    context.allocator=context.temp_allocator
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    pub:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    key_id,ok:=vault.device_id_from_sign_pub(pub,context.temp_allocator)
    if !ok || account=="" do return
    {
        sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
        if !bridge_owner_open(account,key_id) do return
        _=bridge_owner_maintenance_batch(&bridge_owner_store,&bridge_owner_completions,time.to_unix_nanoseconds(time.now())/1000000,nil,bridge_owner_publish_registry)
    }
    // M1 matcher after lease expiry; the first pass after Bridge start is
    // forced (origin/main boot recovery), later passes back off per task.
    booted:=sync.atomic_exchange(&bridge_owner_match_booted,true)
    bridge_owner_match_run("",!booted)
}
bridge_owner_maintenance_batch :: proc(s:^owner.Store,q:^owner.Intent_Completions,now:i64,ctx:rawptr,
    send:proc(rawptr,^owner.Store,owner.Intent_Claim)->(bool,string,i64)) -> bool {
    if !owner.execution_expire_preparations(s,now) do return false
    if !owner.expire_leases(s,now) do return false
    return bridge_owner_publish_batch(s,q,now,ctx,send)
}
bridge_owner_maintenance_worker :: proc() {
    for {
        if sync.atomic_load(&bridge_hub_traffic_stopped) do return
        bridge_owner_maintenance_once()
        free_all(context.temp_allocator)
        time.sleep(30*time.Second)
    }
}
bridge_owner_maintenance_start :: proc() { bridge_thread_run(bridge_owner_maintenance_worker) }
