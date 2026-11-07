#+feature dynamic-literals
package main

import "core:crypto"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// This native-only document is persisted in the local journal. No relay or
// inspect result accepts or returns it, including its original random token.
Executor_Local_Material :: struct {
    command,token,assertion,endpoint,run_dir,provider,model,profile,permission,display,purpose:string,
    run_count:int,
    request:Pty_Host_Spawn_Request,
}

bridge_executor_local_descriptor :: proc(command:string)->Bridge_Bootstrap_Descriptor {
    d:=bridge_bootstrap_descriptor_from_launch(command)
    if d.instance_id=="" {
        d.instance_id=extract_json_string(command,"agent_instance_id","")
        d.display_name="Provider test"
    }
    return d
}

Executor_Local_IO :: struct {
    ctx:rawptr,
    directory:proc(rawptr,i64)->(vault.Directory_Verification_Input,bool),
    files:proc(rawptr,Executor_Local_Material)->([dynamic]Bridge_Bootstrap_File,bool),
    socket:string,
}

bridge_executor_local_files :: proc(_:rawptr,m:Executor_Local_Material)->([dynamic]Bridge_Bootstrap_File,bool) {
    if m.purpose=="provider_test" do return nil,true
    descriptor:=bridge_bootstrap_descriptor_from_launch(m.command)
    descriptor.provider=m.provider
    if descriptor.agent_id=="" do return nil,false
    credential:=bridge_credential_snapshot();defer delete(credential)
    manifest,result:=bridge_bootstrap_conditional_manifest(bridge_config.daemon_url,credential,m.provider,descriptor,&bootstrap_global_cache)
    if !result.ok do return nil,false
    defer delete(manifest)
    files,built:=bridge_bootstrap_build_file_set(manifest,descriptor,m.endpoint,m.token,m.provider,&bootstrap_global_cache)
    return files,built.ok
}

Executor_Local_Startup :: struct {
    m:Executor_Local_Material,files:[]Bridge_Bootstrap_File,
    store:^executor.Store,operation:json.Object,key:contracts.Owner_Verified_Key,
    kr:^vault.Vault_Keyring,generation:i64,io:Executor_Local_IO,
}

bridge_executor_local_startup_current :: proc(p:^Executor_Local_Startup)->bool {
    d,fetched:=p.io.directory(p.io.ctx,p.generation)
    if !fetched do return false
    key,current:=bridge_executor_local_keys(p.store,p.operation,d,p.kr)
    return current && key.public_key==p.key.public_key
}
// Called after the durable dispatch boundary while startup, configuration and
// vault gates are held. Never re-entered by a lost-reply retry or after restart.
bridge_executor_local_startup :: proc(ctx:rawptr)->bool {
    p:=(^Executor_Local_Startup)(ctx)
    m:=p.m
    // A slow dispatch COMMIT must not carry a prior enrollment snapshot over
    // the first bootstrap/token mutation, or slow writes over the final Spawn.
    if !bridge_executor_local_startup_current(p) do return false
    descriptor:=bridge_executor_local_descriptor(m.command)
    if !bridge_legacy_apply_pack_locked(p.store,m.request.instance,"",descriptor.pack_json) do return false
    if !bridge_os_prepare_private_dir(m.run_dir) do return false
    pp,e:=profile_lookup(m.provider,m.profile)
    if e!=.None do return false
    _=pp
    sync.mutex_lock(&bridge_runtime_mutex)
    endpoint,ready:=bridge_runtime_ensure_local_endpoint()
    sync.mutex_unlock(&bridge_runtime_mutex)
    if !ready || endpoint!=m.endpoint do return false
    _=bridge_ext_token_capture_final(m.request.instance,bridge_agent_instance_run_count(m.request.instance),reset_live=true,now=bridge_runtime_now_ms())
    if !bridge_agent_token_activate_retained(m.request.instance,m.assertion,m.token,m.run_count) do return false
    rec,current:=bridge_agent_token_verify(m.token)
    if !current do return false
    sync.mutex_lock(&bridge_runtime_mutex)
    bridge_startup_begin_locked(rec,bridge_runtime_now_ms())
    sync.mutex_unlock(&bridge_runtime_mutex)
    bridge_startup_worker_ensure_started()
    catalog,present:=bridge_provider_catalog_profile(m.provider)
    if !present do return false
    bridge_startup_set_expectation(m.request.instance,m.token,bridge_provider_launch_extension_expected(catalog,m.profile))
    bridge_pty_host_track_instance_provider(m.request.instance,m.provider)
    bridge_prespawn_clean_slate(m.run_dir)
    if !bridge_os_prepare_private_dir(m.run_dir) do return false
    if m.purpose=="provider_test" {
        if !bridge_bootstrap_materialize_local_provider_test(m.run_dir,m.endpoint,m.token,m.request.instance,m.provider) do return false
    } else {
        for file in p.files {
            // All paths originate from the trusted native bootstrap assembler.
            path:=fmt.tprintf("%s/%s",m.run_dir,file.relative_path)
            if at:=strings.last_index_byte(path,'/');at>0 {
                if bridge_make_directory_all(path[:at])!=nil do return false
            }
            if os.write_entire_file(path,transmute([]byte)file.content)!=nil do return false
            if file.mode==0o755 do bridge_os_make_owner_executable(path)
        }
    }
    bridge_runtime_clear_stop_intent(m.request.instance)
    bridge_rollover_note_launch(m.request.instance,descriptor.coordinator_id)
    bridge_ext_note_launch(m.request.instance,m.provider,m.model,m.profile)
    bridge_startup_arm(m.request.instance,m.token,bridge_runtime_now_ms())
    return bridge_executor_local_startup_current(p)
}

// Rebuild only from current native catalog/profile facts and the retained
// token, then compare the full frame with the signed immutable configuration.
bridge_executor_local_material :: proc(d:executor.Local_Draft)->(Executor_Local_Material,bool) {
    m:Executor_Local_Material
    if json.unmarshal_string(d.material,&m,.JSON,context.temp_allocator)!=nil do return {},false
    c,valid:=contracts.executor_parse(d.configuration,"local_configuration")
    get:=contracts.owner_string
    if !valid || get(c,"instance_id")!=m.request.instance || get(c,"token_generation")!=contracts.owner_payload_digest(m.token) ||
       get(c,"run_count")!=fmt.tprintf("%d",m.run_count) || get(c,"provider")!=m.provider || get(c,"model")!=m.model ||
       get(c,"provider_profile")!=m.profile || bridge_executor_local_spawn_digest(m.request)!=get(c,"spawn_digest") {return {},false}
    return m,true
}

bridge_executor_local_current_request :: proc(m:Executor_Local_Material)->bool {
    profile,e:=profile_lookup(m.provider,m.profile,prepare_runtime=false)
    if e!=.None do return false
    env:=bridge_prespawn_env(m.run_dir,m.endpoint,m.token,m.request.instance)
    defer {for item in env do delete(item);delete(env)}
    request,built:=bridge_pty_host_build_spawn(m.request.instance,m.run_dir,m.provider,m.model,m.token,env,m.display,m.request.timeout_seconds,m.permission,&profile,inert=true)
    if !built do return false
    defer bridge_pty_host_spawn_request_delete(request)
    return bridge_executor_local_spawn_digest(request)==bridge_executor_local_spawn_digest(m.request)
}

// A native generation is stable across manual/wake transport forms, command
// IDs and later task-pack delivery. The first native command and token stay
// immutable; a conflicting retry cannot replace either of them.
bridge_executor_local_source :: proc(command:string,purpose:string)->string {
    descriptor:=bridge_executor_local_descriptor(command)
    run,_:=bridge_provider_json_extract_int(command,"run_count")
    kind:="provider_test" if purpose=="provider_test" else "manual"
    return contracts.owner_payload_digest(executor.encode(struct{instance,purpose:string,run:int}{descriptor.instance_id,kind,run}))
}

bridge_executor_local_retry_matches :: proc(draft:executor.Local_Draft,command:string)->bool {
    m,valid:=bridge_executor_local_material(draft)
    if !valid do return false
    provider,model:=bridge_runtime_provider_model(command);defer {delete(provider);delete(model)}
    profile:=extract_json_string(command,"provider_profile","");defer delete(profile)
    permission:=extract_json_string(command,"permission_mode","");defer delete(permission)
    epoch:=extract_json_string(command,"launch_epoch","");defer delete(epoch)
    assertion:=extract_json_string(command,"instance_token","");defer delete(assertion)
    c,_:=contracts.executor_parse(draft.configuration,"local_configuration")
    current:=bridge_executor_local_descriptor(command)
    original:=bridge_executor_local_descriptor(m.command)
    return provider==m.provider && model==m.model && profile_effective_id(provider,profile)==m.profile &&
        permission==m.permission && current.project_path==original.project_path && current.agent_id==original.agent_id &&
        (epoch=="" || epoch==contracts.owner_string(c,"launch_epoch")) && (assertion=="" || assertion==m.assertion)
}

bridge_executor_local_pending :: proc(d:executor.Local_Draft)->string {
    return executor.encode(struct{code,executor_bridge_id,draft_id,draft_revision,configuration_digest,state:string}{
        "launch_authorization_required",bridge_config.daemon_id,d.id,fmt.tprintf("%d",d.revision),
        contracts.owner_payload_digest(d.configuration),d.state})
}

bridge_executor_local_note_pending :: proc(command,detail:string,err:Bridge_Error) {
    instance:=extract_json_string(command,"agent_instance_id","");defer delete(instance)
    status,activity,found:=bridge_runtime_status_snapshot(instance)
    defer {delete(status);delete(activity)}
    // A pending replacement cannot declare a possibly live older child dead.
    if found && (status=="running" || status=="starting" || status=="busy" || status=="idle") do return
    bridge_runtime_set_status(instance,"failed","idle")
    pending:=err
    pending.class=.recoverable
    bridge_runtime_record_failure(instance,pending,detail)
    epoch:=extract_json_string(command,"launch_epoch","");defer delete(epoch)
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances {
        if inst.agent_instance_id==instance {
            inst.pending_launch_epoch=strings.clone(epoch,runtime.default_allocator())
            break
        }
    }
    sync.mutex_unlock(&bridge_runtime_mutex)
}

// An unsigned Hub request can propose a draft only. It must not touch the
// previous generation's token, bootstrap, stop intent, startup state or child.
bridge_executor_local_stage :: proc(command:string,purpose:string,io:Executor_Local_IO={nil,bridge_executor_child_fetch,bridge_executor_local_files,""})->(bool,string,Bridge_Error) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    self,identified:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !identified || account=="" do return false,"paired execution device required",bridge_error(.agent_launch_failed,.denied)
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return false,"unlock the execution device",bridge_error(.agent_launch_failed,.denied)
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,self) do return false,"local launch journal unavailable",bridge_error(.agent_launch_failed,.other)
    s:=&bridge_executor_store
    source:=bridge_executor_local_source(command,purpose)
    if d,found:=executor.local_draft_source(s,source);found {
        if !bridge_executor_local_retry_matches(d,command) do return false,"draft_generation_conflict",bridge_error(.agent_launch_failed,.denied)
        // A retry may reuse the original exact signed consent, never an
        // unsigned Hub assertion or a replacement synthetic authorization.
        if raw,authorized:=executor.local_draft_consent(s,d);authorized {
            sync.mutex_unlock(&bridge_executor_mutex)
            directory,fetched:=io.directory(io.ctx,generation)
            sync.mutex_lock(&bridge_executor_mutex)
            o,parsed:=contracts.executor_parse(raw,"local_draft")
            if fetched && parsed {
                key,trusted:=bridge_executor_local_keys(s,o,directory,&kr)
                if trusted {
                    result:=bridge_executor_local_apply_io(s,raw,o,key,&kr,generation,io)
                    launch,loaded:=executor.local_launch(s,d.launch_id)
                    if result.code=="ok" && loaded && launch.state=="active" do return true,"",{}
                }
            }
        }
        return false,bridge_executor_local_pending(d),bridge_error(.agent_launch_failed,.denied)
    }
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return false,"vault_locked",bridge_error(.agent_launch_failed,.denied)
    defer bridge_executor_authority_end()
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    d:=bridge_executor_local_descriptor(command)
    provider,model:=bridge_runtime_provider_model(command);defer {delete(provider);delete(model)}
    profile:=extract_json_string(command,"provider_profile","");defer delete(profile)
    permission:=extract_json_string(command,"permission_mode","");defer delete(permission)
    run,_:=bridge_provider_json_extract_int(command,"run_count")
    if !contracts.owner_field_valid(d.instance_id,"id") || run<=0 || provider=="" || model=="" {
        return false,"exact instance and positive launch generation required",bridge_error(.agent_launch_failed,.denied)
    }
    if run<bridge_agent_instance_run_count(d.instance_id) do return false,"superseded startup generation",bridge_error(.agent_launch_failed,.denied)
    pp,e:=profile_lookup(provider,profile,prepare_runtime=false)
    if e!=.None || !profile_has_model(&pp,provider,model) do return false,"provider profile unavailable",bridge_error(.agent_launch_failed,.unsupported)
    path:=""
    if d.project_path!="" {
        canonical,within:=bridge_executor_canonical_directory(d.project_path)
        if !within do return false,"directory_selection_required",bridge_error(.agent_launch_failed,.denied)
        path=canonical
    }
    slot,directory,policy,mapping,code:=executor.local_draft_selection(s,pp.profile_id,path)
    if code!="ok" do return false,code,bridge_error(.agent_launch_failed,.denied)
    if _,within:=bridge_executor_canonical_directory(mapping.path);!within do return false,"directory_selection_required",bridge_error(.agent_launch_failed,.denied)
    seed:[32]byte
    if !random.fill(seed[:]) do return false,"startup entropy unavailable",bridge_error(.agent_launch_failed,.other)
    defer crypto.zero_explicit(&seed,size_of(seed))
    token:=strings.concatenate({"hlat_",vault.hex_encode_lower(seed[:],context.temp_allocator)},context.temp_allocator)
    defer crypto.zero_explicit(raw_data(token),len(token))
    assertion:=extract_json_string(command,"instance_token","");defer delete(assertion)
    // A missing Hub assertion stays missing; never manufacture hit_<instance>.
    epoch:=extract_json_string(command,"launch_epoch","");defer delete(epoch)
    if epoch=="" do epoch=fmt.tprintf("local_%s",source)
    run_dir:=bridge_runtime_default_run_dir(d.instance_id);defer delete(run_dir)
    config:=bridge_local_endpoint_config_default(bridge_config.local_endpoint_run_dir,bridge_config.local_endpoint_port)
    endpoint:=bridge_local_endpoint_env_value(config,ODIN_OS!=.Windows);defer delete(endpoint)
    env:=bridge_prespawn_env(run_dir,endpoint,token,d.instance_id)
    defer {for item in env do delete(item);delete(env)}
    timeout:u64=0
    if purpose=="provider_test" do timeout=PROVIDER_TEST_TIMEOUT_SECONDS
    request,built:=bridge_pty_host_build_spawn(d.instance_id,run_dir,provider,model,token,env,d.display_name,timeout,permission,&pp,inert=true)
    if !built do return false,"provider has no runnable command",bridge_error(.provider_missing)
    defer bridge_pty_host_spawn_request_delete(request)
    c:=make(json.Object,context.temp_allocator)
    for pair in ([][2]string{{"protocol_version","1"},{"account_id",account},{"executor_bridge_id",s.executor},
        {"instance_id",d.instance_id},{"launch_epoch",epoch},{"run_count",fmt.tprintf("%d",run)},
        {"token_generation",contracts.owner_payload_digest(token)},{"configuration_revision","1"},
        {"executor_incarnation",fmt.tprintf("%d",s.incarnation)},{"policy_revision",fmt.tprintf("%d",policy)},
        {"slot_id",slot},{"provider",provider},{"model",model},{"provider_profile",pp.profile_id},
        {"directory_id",directory},{"directory_revision",fmt.tprintf("%d",mapping.revision)},
        {"directory_key",mapping.key},{"purpose",purpose},{"spawn_digest",bridge_executor_local_spawn_digest(request)}}) {c[pair[0]]=json.String(pair[1])}
    material:=executor.encode(Executor_Local_Material{command,token,assertion,endpoint,run_dir,provider,model,pp.profile_id,permission,d.display_name,purpose,run,request})
    defer crypto.zero_explicit(raw_data(material),len(material))
    draft,staged:=executor.stage_local_draft(s,source,executor.encode(c),material)
    if staged!="ok" do return false,staged,bridge_error(.agent_launch_failed,.denied)
    return false,bridge_executor_local_pending(draft),bridge_error(.agent_launch_failed,.denied)
}
