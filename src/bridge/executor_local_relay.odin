#+feature dynamic-literals
package main

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

// Resolve the preparing browser and this execution Bridge against the newest
// verified paired directory, never a draft-time key snapshot or account AEAD.
bridge_executor_local_keys :: proc(s:^executor.Store,o:json.Object,d:vault.Directory_Verification_Input,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,bool) {
    dir,trusted:=bridge_executor_directory(s,d,kr)
    if !trusted do return {},false
    own,self_ok:=dir.trusted[s.operator_key]
    peer,device_ok:=dir.trusted[contracts.owner_string(o,"principal_id")]
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    if !self_ok || own.kind!="bridge" || own.sign_public_key!=public || !device_ok || peer.kind!="browser" ||
       peer.id!=contracts.owner_string(o,"key_id") {return {},false}
    key:=contracts.Owner_Verified_Key{s.account,peer.id,peer.id,peer.sign_public_key,"device",true,false}
    return key,contracts.executor_verify("local_draft",o,key)
}

Executor_Local_Apply :: #type proc(^executor.Store,string,json.Object,contracts.Owner_Verified_Key,^vault.Vault_Keyring,i64)->executor.Result

// Request and reply are encrypted with the current account epoch. Both sides
// additionally verify enrolled signatures and exact request/result digests.
// The Hub only routes bounded ciphertext and supplies paired-directory proof.
bridge_executor_local_handle :: proc(conn:^ws.Connection,text:string,apply:Executor_Local_Apply=bridge_executor_local_apply) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    wire:Executor_Issuance_Wire
    if len(text)>3*1024*1024 || json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    relay,valid:=contracts.executor_parse(wire.relay,"local_relay")
    if !valid do return
    get:=contracts.owner_string
    reply:=struct{type,command_id,request_id,code,envelope:string}{"command_result",wire.command_id,get(relay,"request_id"),"invalid_scope",""}
    defer {
        if bridge_task_chain_search_generation()!=generation {reply.code="vault_locked";reply.envelope=""}
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    now:=bridge_executor_physical_clock(nil)
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    expires:=contracts.executor_number(relay,"expires_ms")
    if account=="" || wire.account_id!=account || get(relay,"bridge_id")!=bridge_config.daemon_id ||
       expires<=now || expires-now>contracts.EXECUTOR_TRANSPORT_TTL_MS {return}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {reply.code="vault_locked";return}
    raw,opened:=bridge_open_current_epoch_token(get(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    defer crypto.zero_explicit(raw_data(raw),len(raw))
    o,parsed:=contracts.executor_parse(raw,"local_draft")
    if !parsed || get(o,"account_id")!=account || get(o,"executor_bridge_id")!=bridge_config.daemon_id do return
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !key_ok do return
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,key_id) {reply.code="storage_error";return}
    s:=&bridge_executor_store
    key,authenticated:=bridge_executor_local_keys(s,o,wire.directory,&kr)
    if !authenticated do return
    // Startup serialization also covers explicit cancellation versus first I/O.
    // The production apply wrapper re-resolves resources and keys after any
    // delayed preparation and holds the vault gate through physical dispatch.
    result:=apply(s,raw,o,key,&kr,generation)
    reply.code=result.code
    body:=bridge_owner_json(struct{code,body:string}{result.code,result.body})
    issued:=time.to_unix_nanoseconds(time.now())/1000000
    if issued>=expires {reply.code="expired";return}
    receipt:=make(json.Object,context.temp_allocator)
    for pair in ([12][2]string{{"protocol_version","1"},{"account_id",account},{"executor_bridge_id",s.executor},
        {"principal_id",key.principal_id},{"operation_id",get(o,"operation_id")},{"request_id",get(relay,"request_id")},
        {"request_digest",""},{"result_digest",contracts.owner_payload_digest(body)},{"issued_ms",executor.encode(issued)},
        {"request_expires_ms",get(relay,"expires_ms")},{"key_id",key_id},{"signature",""}}) {
        receipt[pair[0]]=json.String(pair[1])
    }
    digest,_:=contracts.executor_digest("local_draft",o)
    receipt["request_digest"]=json.String(digest)
    // Signer validates shape, including its placeholder signature.
    receipt["signature"]=json.String("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    signature,signed:=bridge_executor_sign(nil,"local_result",receipt)
    if !signed {reply.code="signing_failed";return}
    receipt["signature"]=json.String(signature)
    bundle:=bridge_owner_json(struct{receipt,body:string}{bridge_owner_json(receipt),body})
    reply.envelope,_=bridge_encrypt_vault_text(bundle,&kr,context.temp_allocator)
}

// Installed production entrypoint for lifecycle methods. Authorization is
// admitted by the same transaction as the draft and never implies readiness.
bridge_executor_local_apply :: proc(s:^executor.Store,raw:string,o:json.Object,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,generation:i64)->executor.Result {
    return bridge_executor_local_apply_io(s,raw,o,key,kr,generation,{nil,bridge_executor_child_fetch,bridge_executor_local_files,""})
}

// Caller owns executor_mutex. Slow bootstrap preparation releases it. The final
// bounded directory GET runs under startup/vault serialization; it has no
// reverse Bridge callback and no SQLite transaction spans that request.
bridge_executor_local_apply_io :: proc(s:^executor.Store,raw:string,o:json.Object,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,generation:i64,io:Executor_Local_IO)->executor.Result {
    method:=contracts.owner_string(o,"method")
    if method!="authorize" {
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        if !bridge_executor_authority_begin(generation) do return executor.Result{code="vault_locked"}
        defer bridge_executor_authority_end()
        current_key:=key
        if method=="cancel" {
            // A relay-time key may have been revoked while this request waited
            // for startup/vault serialization. Refresh before either committing
            // cancellation or invalidating the token/closing the exact child.
            if io.directory==nil do return executor.Result{code="directory_unavailable"}
            directory,fetched:=io.directory(io.ctx,generation)
            if !fetched do return executor.Result{code="directory_unavailable"}
            fresh,authenticated:=bridge_executor_local_keys(s,o,directory,kr)
            if !authenticated || fresh.public_key!=key.public_key do return executor.Result{code="invalid_scope"}
            current_key=fresh
        }
        result:=executor.local_draft_command(s,raw,current_key,bridge_executor_physical_clock(nil))
        if result.code=="ok" && method=="cancel" {
            draft,found:=executor.local_draft_native(s,contracts.owner_string(o,"draft_id"))
            if found && draft.launch_id!="" {
                material,valid:=bridge_executor_local_material(draft)
                if valid {
                    if _,active:=bridge_agent_token_verify(material.token);active {
                        _=bridge_agent_token_invalidate(material.token)
                        bridge_runtime_mark_stop_intent_io_locked(material.request.instance)
                    }
                }
                launch,loaded:=executor.local_launch(s,draft.launch_id)
                if loaded && launch.state=="stopping" {
                    socket:=io.socket
                    if socket=="" do socket=pty_host_socket_path()
                    if io.socket=="" {defer delete(socket)}
                    _=bridge_pty_host_executor_close(socket,launch.instance,launch.launch_key)
                    _,_=bridge_executor_local_observe(s,launch,socket)
                }
            }
        }
        return result
    }
    draft,found:=executor.local_draft_native(s,contracts.owner_string(o,"draft_id"))
    if !found do return executor.Result{code="draft_not_found"}
    if draft.principal!=key.principal_id || draft.key!=key.key_id do return executor.Result{code="draft_not_owned"}
    if contracts.owner_string(o,"draft_revision")!=fmt.tprintf("%d",draft.revision) ||
       contracts.owner_string(o,"configuration_digest")!=contracts.owner_payload_digest(draft.configuration) {return executor.Result{code="draft_conflict"}}
    m,valid:=bridge_executor_local_material(draft)
    if !valid do return executor.Result{code="invalid_resources"}
    first:=draft.launch_id==""
    if !first {
        launch,loaded:=executor.local_launch(s,draft.launch_id)
        if !loaded do return executor.Result{code="storage_error"}
        first=launch.state=="admitted"
    }
    if io.directory==nil || first && io.files==nil do return executor.Result{code="startup_unavailable"}
    files:[dynamic]Bridge_Bootstrap_File
    prepared:=true
    sync.mutex_unlock(&bridge_executor_mutex)
    if first {files,prepared=io.files(io.ctx,m)}
    sync.mutex_lock(&bridge_executor_mutex)
    defer {if files!=nil do bridge_bootstrap_free_file_set(files)}
    if !prepared do return executor.Result{code="bootstrap_prepare_failed"}
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return executor.Result{code="vault_locked"}
    defer bridge_executor_authority_end()
    directory,fetched:=io.directory(io.ctx,generation)
    if !fetched do return executor.Result{code="directory_unavailable"}
    fresh,authenticated:=bridge_executor_local_keys(s,o,directory,kr)
    if !authenticated || fresh.public_key!=key.public_key do return executor.Result{code="invalid_scope"}
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    resources:=executor.Local_Resources{}
    if first {
        if !bridge_executor_local_current_request(m) do return executor.Result{code="invalid_resources"}
        resources=bridge_executor_resolve_local(s,draft.configuration,m.request)
        if !resources.resolved do return executor.Result{code="invalid_resources"}
    }
    result:=executor.local_draft_command(s,raw,fresh,bridge_executor_physical_clock(nil),resources)
    if result.code!="ok" do return result
    current,loaded:=executor.local_draft_native(s,draft.id)
    // A historical success can never revive a cancelled/released generation.
    if !loaded || current.state!="authorized" || current.launch_id=="" do return result
    launch,ready:=executor.local_launch(s,current.launch_id)
    if !ready do return executor.Result{code="storage_error"}
    if launch.state=="released" || launch.state=="stopping" do return result
    socket:=io.socket
    if socket=="" do socket=pty_host_socket_path()
    if io.socket=="" {defer delete(socket)}
    if first {
        listed,read:=bridge_pty_host_list(socket)
        if !read do return executor.Result{code="executor_uncertain"}
        occupied:=false
        for agent in listed.agents do if agent.instance_id==launch.instance {occupied=true;break}
        pty_host_reply_delete(listed)
        if occupied do return executor.Result{code="instance_not_drained"}
    }
    startup:=Executor_Local_Startup{m,files[:],s,o,fresh,kr,generation,io}
    delivered,reason:=bridge_executor_local_dispatch(s,launch,fresh,m.request,resources,socket,
        prepare_ctx=&startup,prepare=bridge_executor_local_startup)
    if !delivered || reason!="child_present" do return executor.Result{code=reason}
    pid,known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    if known && pid>0 {
        confirmed,queried:=bridge_startup_confirm_spawned_io_locked(socket,launch.instance,m.run_count)
        if !queried || !confirmed do return executor.Result{code="startup_identity_not_current"}
        descriptor:=bridge_bootstrap_descriptor_from_launch(m.command)
        bridge_runtime_set_pty_process_alive(launch.instance,true)
        bridge_startup_spawned(launch.instance,m.token,pid)
        bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_id=strings.clone(descriptor.agent_id,runtime.default_allocator()),agent_instance_id=strings.clone(launch.instance,runtime.default_allocator()),
            run_dir=strings.clone(m.run_dir,runtime.default_allocator()),project_path=strings.clone(descriptor.project_path,runtime.default_allocator()),agent_token=strings.clone(m.token,runtime.default_allocator()),
            pane_id=strings.clone(fmt.tprintf("pty-host:%d",pid),runtime.default_allocator()),provider_sym=contracts.bridge_log_provider_sym(m.provider),launched_at_ns=time.tick_now()._nsec})
        bridge_pty_host_events_ensure()
        bridge_task_wake_note_launched(launch.instance)
    }
    return result
}
