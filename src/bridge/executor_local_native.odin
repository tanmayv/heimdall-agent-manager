#+feature dynamic-literals
package main

import "core:crypto"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
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
    origin:Executor_Legacy_Origin,
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
    store:^executor.Store,generation:i64,
}

// The vault authority generation held across dispatch must not have rotated
// (lock/unlock) between the durable dispatch boundary and physical I/O.
bridge_executor_local_startup_current :: proc(p:^Executor_Local_Startup)->bool {
    return bridge_task_chain_search_generation()==p.generation
}
// Called after the durable dispatch boundary while startup, configuration and
// vault gates are held. Never re-entered by a lost-reply retry or after restart.
// A fresh Bridge has no <local-run-dir>/instances yet: create the missing
// parents (owner-only) before the private, non-recursive run directory.
bridge_executor_prepare_run_dir :: proc(run_dir:string)->bool {
    clean:=strings.trim_right(run_dir,"/")
    if slash:=strings.last_index_byte(clean,'/');slash>0 {
        if bridge_make_directory_all(clean[:slash],{.Read_User,.Write_User,.Execute_User})!=nil do return false
    }
    return bridge_os_prepare_private_dir(clean)
}

bridge_executor_local_startup :: proc(ctx:rawptr)->bool {
    p:=(^Executor_Local_Startup)(ctx)
    m:=p.m
    // A slow dispatch COMMIT must not carry a prior enrollment snapshot over
    // the first bootstrap/token mutation, or slow writes over the final Spawn.
    if !bridge_executor_local_startup_current(p) do return false
    descriptor:=bridge_executor_local_descriptor(m.command)
    if !bridge_legacy_apply_pack_locked(p.store,m.request.instance,"",descriptor.pack_json) do return false
    if !bridge_executor_prepare_run_dir(m.run_dir) do return false
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
    if !bridge_executor_prepare_run_dir(m.run_dir) do return false
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
    if m.origin.version!="" && (m.origin.account!=get(c,"account_id") || m.origin.instance!=m.request.instance || !bridge_legacy_origin_matches_native(m.origin,m.command)) do return {},false
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
    // "native" versions the source: a pre-upgrade device-approval draft for
    // the same generation is never reused or revived.
    return contracts.owner_payload_digest(executor.encode(struct{instance,purpose,authority:string,run:int}{descriptor.instance_id,kind,"native",run}))
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


// A launch that could not start reports a typed failure against the epoch the
// Hub is waiting on. It never declares a possibly live older child dead.
bridge_executor_local_note_failure :: proc(command,detail:string,err:Bridge_Error) {
    instance:=extract_json_string(command,"agent_instance_id","");defer delete(instance)
    status,activity,found:=bridge_runtime_status_snapshot(instance)
    defer {delete(status);delete(activity)}
    if found && (status=="running" || status=="starting" || status=="busy" || status=="idle") do return
    bridge_runtime_set_status(instance,"failed","idle")
    bridge_runtime_record_failure(instance,err,detail)
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

// Canonical existing project directory inside this Bridge's filesystem root.
// Unlike a signed mapping it needs no operator record: the same sandbox check
// used by project path validation is the only directory precondition.
bridge_executor_project_directory :: proc(path:string)->(string,bool) {
    canonical,within:=bridge_fs_resolve_within(path);defer delete(canonical)
    if !within || !bridge_validate_project_path_local(canonical,"","").ok do return "",false
    return strings.clone(canonical,context.temp_allocator),true
}

bridge_executor_local_directory_digest :: proc(path:string)->string {
    return "" if path=="" else contracts.owner_payload_digest(path)
}

// Every ordinary launch (manual, warm wake, task-dispatched worker/reviewer,
// provider test) arrives as a Hub command relayed from the user's trusted
// device. The Bridge stages one exact native generation (retained token and
// command), admits it itself and dispatches the exact child. No device
// approval, slot policy, capacity or signed directory mapping is consulted.
bridge_executor_local_stage :: proc(command:string,purpose:string,io:Executor_Local_IO={nil,bridge_executor_local_files,""},origin:Executor_Legacy_Origin={},observation_action:executor.Legacy_Action={},observation_entry_index:i64= -1,observation_entry_digest:string="")->(bool,string,Bridge_Error) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    self,identified:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !identified || account=="" do return false,"paired execution device required",bridge_error(.agent_launch_failed,.denied)
    kr,unlocked:=bridge_read_vault_keyring();vault.keyring_wipe(&kr)
    if !unlocked do return false,"unlock the execution device",bridge_error(.agent_launch_failed,.denied)
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,self) do return false,"local launch journal unavailable",bridge_error(.agent_launch_failed,.other)
    s:=&bridge_executor_store
    if origin.version!="" && !bridge_legacy_origin_matches_native(origin,command) do return false,"legacy_observation_mismatch",bridge_error(.agent_launch_failed,.denied)
    source:=bridge_executor_local_source(command,purpose)
    draft,found:=executor.local_draft_source(s,source)
    if found {
        if !bridge_executor_local_retry_matches(draft,command) do return false,"draft_generation_conflict",bridge_error(.agent_launch_failed,.denied)
    } else {
        staged,detail,err:=bridge_executor_local_stage_draft(s,command,purpose,source,account,origin,generation)
        if !staged.ok do return false,detail,err
        draft=staged.draft
    }
    if !bridge_legacy_observe_draft(s,origin,command,draft.id) || !bridge_legacy_action_observe_selected_draft(s,observation_action,command,draft.id,observation_entry_index,observation_entry_digest) do return false,"legacy_observation_unavailable",bridge_error(.agent_launch_failed,.denied)
    code:=bridge_executor_local_launch_native(s,draft,generation,io)
    switch code {
    case "ok": return true,"",{}
    case "vault_locked": return false,"unlock the execution device",bridge_error(.agent_launch_failed,.denied)
    case "instance_not_drained","executor_uncertain","child_absent","startup_identity_not_current":
        return false,code,bridge_error(.agent_launch_failed,.other,retry_after_ms=5_000)
    case "invalid_resources": return false,"provider profile or project directory changed; relaunch",bridge_error(.agent_launch_failed,.denied)
    case "launch_generation_closed": return false,"this launch generation already ran; relaunch the agent",bridge_error(.agent_launch_failed,.denied)
    case "superseded": return false,"superseded startup generation",bridge_error(.agent_launch_failed,.denied)
    }
    return false,code,bridge_error(.agent_launch_failed,.other)
}

Executor_Local_Staged :: struct {draft:executor.Local_Draft,ok:bool}

// Validate and persist one inert native generation. Caller holds executor_mutex.
bridge_executor_local_stage_draft :: proc(s:^executor.Store,command,purpose,source,account:string,origin:Executor_Legacy_Origin,generation:i64)->(Executor_Local_Staged,string,Bridge_Error) {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return {},"unlock the execution device",bridge_error(.agent_launch_failed,.denied)
    defer bridge_executor_authority_end()
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    d:=bridge_executor_local_descriptor(command)
    provider,model:=bridge_runtime_provider_model(command);defer {delete(provider);delete(model)}
    profile:=extract_json_string(command,"provider_profile","");defer delete(profile)
    permission:=extract_json_string(command,"permission_mode","");defer delete(permission)
    run,_:=bridge_provider_json_extract_int(command,"run_count")
    if !contracts.owner_field_valid(d.instance_id,"id") || run<=0 || provider=="" || model=="" {
        return {},"exact instance and positive launch generation required",bridge_error(.agent_launch_failed,.denied)
    }
    if run<bridge_agent_instance_run_count(d.instance_id) do return {},"superseded startup generation",bridge_error(.agent_launch_failed,.denied)
    if _,active:=bridge_provider_catalog_profile(provider);!active do return {},"provider unavailable",bridge_error(.agent_launch_failed,.unsupported)
    pp,e:=profile_lookup(provider,profile,prepare_runtime=false)
    if e!=.None || !pp.enabled || !profile_has_model(&pp,provider,model) do return {},"provider profile unavailable",bridge_error(.agent_launch_failed,.unsupported)
    path:=""
    if d.project_path!="" {
        canonical,within:=bridge_executor_project_directory(d.project_path)
        if !within do return {},"project path is not an existing directory inside this Bridge's filesystem root",bridge_error(.agent_launch_failed,.denied)
        path=canonical
    }
    seed:[32]byte
    if !random.fill(seed[:]) do return {},"startup entropy unavailable",bridge_error(.agent_launch_failed,.other)
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
    if !built do return {},"provider has no runnable command",bridge_error(.provider_missing)
    defer bridge_pty_host_spawn_request_delete(request)
    c:=make(json.Object,context.temp_allocator)
    for pair in ([][2]string{{"protocol_version","1"},{"account_id",account},{"executor_bridge_id",s.executor},
        {"instance_id",d.instance_id},{"launch_epoch",epoch},{"run_count",fmt.tprintf("%d",run)},
        {"token_generation",contracts.owner_payload_digest(token)},{"configuration_revision","1"},
        {"executor_incarnation",fmt.tprintf("%d",s.incarnation)},
        {"provider",provider},{"model",model},{"provider_profile",pp.profile_id},
        {"directory_digest",bridge_executor_local_directory_digest(path)},
        {"purpose",purpose},{"spawn_digest",bridge_executor_local_spawn_digest(request)}}) {c[pair[0]]=json.String(pair[1])}
    observed:=origin
    if observed.version!="" do observed.account=account
    material:=executor.encode(Executor_Local_Material{command,token,assertion,endpoint,run_dir,provider,model,pp.profile_id,permission,d.display_name,purpose,run,request,observed})
    defer crypto.zero_explicit(raw_data(material),len(material))
    draft,staged:=executor.stage_local_draft(s,source,executor.encode(c),material)
    if staged!="ok" do return {},staged,bridge_error(.agent_launch_failed,.other)
    return {draft,true},"",{}
}

// Release what a newer generation must not inherit: an undispatched admission
// has no child and is cancelled; a dispatched one is observed exactly so a
// child that is already gone stops holding the instance.
bridge_executor_local_drain_instance :: proc(s:^executor.Store,instance,keep:string,socket:string) {
    launches,read:=executor.local_instance_launches(s,instance)
    if !read do return
    for launch in launches {
        if launch.id==keep do continue
        if launch.state=="admitted" {_=executor.cancel_local_admission(s,launch.id);continue}
        _,_=bridge_executor_local_observe(s,launch,socket)
    }
}

// Caller owns executor_mutex. Slow bootstrap preparation releases it. The
// physical dispatch runs under startup I/O serialization and the vault
// authority gate; no SQLite transaction spans daemon I/O.
bridge_executor_local_launch_native :: proc(s:^executor.Store,draft:executor.Local_Draft,generation:i64,io:Executor_Local_IO)->string {
    m,valid:=bridge_executor_local_material(draft)
    if !valid do return "invalid_resources"
    first:=draft.launch_id==""
    if !first {
        launch,loaded:=executor.local_launch(s,draft.launch_id)
        if !loaded do return "storage_error"
        switch launch.state {
        case "admitted": first=true
        case "released","stopping": return "launch_generation_closed"
        }
    }
    if first && io.files==nil do return "startup_unavailable"
    files:[dynamic]Bridge_Bootstrap_File
    prepared:=true
    // Slow preparation and daemon start run without the journal mutex. A
    // fresh Bridge may not have its pty-host daemon yet: start it like every
    // other PTY operation instead of reporting an uncertain executor forever.
    socket:=io.socket
    daemon_ok:=true
    sync.mutex_unlock(&bridge_executor_mutex)
    if first {files,prepared=io.files(io.ctx,m)}
    if socket=="" && prepared {socket,daemon_ok=bridge_pty_host_ensure_daemon()}
    sync.mutex_lock(&bridge_executor_mutex)
    defer {if files!=nil do bridge_bootstrap_free_file_set(files)}
    if !prepared do return "bootstrap_prepare_failed"
    if !daemon_ok do return "executor_uncertain"
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return "vault_locked"
    defer bridge_executor_authority_end()
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    resources:=executor.Local_Resources{}
    if first {
        if m.run_count<bridge_agent_instance_run_count(m.request.instance) do return "superseded"
        if !bridge_executor_local_current_request(m) do return "invalid_resources"
        resources=bridge_executor_resolve_local(s,draft.configuration,m)
        if !resources.resolved do return "invalid_resources"
    }
    current,loaded:=executor.local_draft_native(s,draft.id)
    if !loaded do return "storage_error"
    if current.launch_id=="" {
        bridge_executor_local_drain_instance(s,m.request.instance,"",socket)
        admitted:=executor.authorize_native_local(s,current.id,bridge_executor_physical_clock(nil),resources)
        if admitted.code!="ok" do return admitted.code
        current,loaded=executor.local_draft_native(s,draft.id)
        if !loaded || current.launch_id=="" do return "storage_error"
    }
    launch,ready:=executor.local_launch(s,current.launch_id)
    if !ready do return "storage_error"
    if launch.state=="released" || launch.state=="stopping" do return "launch_generation_closed"
    if launch.state=="admitted" {
        listed,read:=bridge_pty_host_list(socket)
        if !read do return "executor_uncertain"
        occupied:=false
        for agent in listed.agents do if agent.instance_id==launch.instance {occupied=true;break}
        pty_host_reply_delete(listed)
        if occupied do return "instance_not_drained"
    }
    startup:=Executor_Local_Startup{m,files[:],s,generation}
    delivered,reason:=bridge_executor_local_dispatch(s,launch,m.request,resources,socket,
        prepare_ctx=&startup,prepare=bridge_executor_local_startup)
    if !delivered || reason!="child_present" do return reason
    pid,known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    if known && pid>0 {
        confirmed,queried:=bridge_startup_confirm_spawned_io_locked(socket,launch.instance,m.run_count)
        if !queried || !confirmed do return "startup_identity_not_current"
        descriptor:=bridge_bootstrap_descriptor_from_launch(m.command)
        bridge_runtime_set_pty_process_alive(launch.instance,true)
        bridge_startup_spawned(launch.instance,m.token,pid)
        bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_id=strings.clone(descriptor.agent_id,runtime.default_allocator()),agent_instance_id=strings.clone(launch.instance,runtime.default_allocator()),
            run_dir=strings.clone(m.run_dir,runtime.default_allocator()),project_path=strings.clone(descriptor.project_path,runtime.default_allocator()),agent_token=strings.clone(m.token,runtime.default_allocator()),
            pane_id=strings.clone(fmt.tprintf("pty-host:%d",pid),runtime.default_allocator()),provider_sym=contracts.bridge_log_provider_sym(m.provider),launched_at_ns=time.tick_now()._nsec})
        bridge_pty_host_events_ensure()
        bridge_task_wake_note_launched(launch.instance)
    }
    return "ok"
}
