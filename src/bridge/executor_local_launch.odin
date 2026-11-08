package main

import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

Executor_Local_Prepare :: #type proc(rawptr)->bool

// The immutable digest covers the full framed Spawn, including exact argv,
// environment, startup credentials, cwd, timeout and provider configuration.
// This is computed before Bridge-only exact-control fields are appended.
bridge_executor_local_spawn_digest :: proc(request:Pty_Host_Spawn_Request)->string {
    frame:=pty_host_encode_spawn(request);defer delete(frame)
    return contracts.owner_payload_digest(transmute(string)frame)
}

// Only trusted native launch code supplies the material. Never decode a Spawn
// from a relay. The project directory is canonicalized again before I/O and
// must still be the one the configuration bound (inside the filesystem root).
bridge_executor_resolve_local :: proc(s:^executor.Store,configuration:string,m:Executor_Local_Material)->executor.Local_Resources {
    resources,_:=bridge_executor_resolve_local_reason(s,configuration,m)
    return resources
}

// Returns the resolved resources, or the outcome code: resources_changed when
// the staged generation's bound facts (instance, Spawn or directory digest)
// no longer match; outside_root; and the transient profile_unavailable,
// model_unavailable or project_directory_unavailable.
bridge_executor_resolve_local_reason :: proc(s:^executor.Store,configuration:string,m:Executor_Local_Material)->(executor.Local_Resources,string) {
    c,valid:=contracts.executor_parse(configuration,"local_configuration")
    request:=m.request
    if !valid || request.instance!=contracts.owner_string(c,"instance_id") do return {},"resources_changed"
    get:=contracts.owner_string
    for pair in request.env do if strings.has_prefix(pair[0],"HEIMDALL_EXECUTOR_") {return {},"resources_changed"}
    path:=""
    if project:=bridge_executor_local_descriptor(m.command).project_path;project!="" {
        canonical,code:=bridge_executor_project_directory_reason(project)
        if code!="ok" do return {},code
        path=canonical
    }
    if bridge_executor_local_directory_digest(path)!=get(c,"directory_digest") do return {},"resources_changed"
    provider,model,profile:=get(c,"provider"),get(c,"model"),get(c,"provider_profile")
    // Provider enablement is global; model support belongs to the selected
    // profile (including its custom models and discovered account snapshot).
    if _,active:=bridge_provider_catalog_profile(provider);!active do return {},"profile_unavailable"
    resolved,err:=profile_lookup(provider,profile,prepare_runtime=false)
    if err!=.None || !resolved.enabled do return {},"profile_unavailable"
    if resolved.provider!=provider || resolved.profile_id!=profile do return {},"resources_changed"
    if !profile_has_model(&resolved,provider,model) do return {},"model_unavailable"
    digest:=bridge_executor_local_spawn_digest(request)
    if digest!=get(c,"spawn_digest") do return {},"resources_changed"
    return executor.Local_Resources{contracts.owner_payload_digest(configuration),digest,path,true},"ok"
}

// Caller holds startup I/O serialization and the shared vault authority gate.
// No SQL transaction spans daemon I/O. Once first permission is consumed every
// retry is exact query only.
bridge_executor_local_dispatch :: proc(s:^executor.Store,launch:executor.Local_Launch,
    request:Pty_Host_Spawn_Request,resources:executor.Local_Resources,socket:string,
    clock_ctx:rawptr=nil,clock:Executor_Now=bridge_executor_physical_clock,
    prepare_ctx:rawptr=nil,prepare:Executor_Local_Prepare=nil)->(bool,string) {
    if clock==nil do return false,"clock_required"
    current,found:=executor.local_launch(s,launch.id)
    if !found || current.incarnation!=launch.incarnation || current.instance!=launch.instance || current.launch_key!=launch.launch_key ||
       current.configuration!=launch.configuration || current.spawn_digest!=launch.spawn_digest {return false,"stale_local_launch"}
    if current.state!="admitted" do return bridge_executor_local_observe(s,current,socket)
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    // launch.instance is reloaded from the retained native configuration above, never selected by a caller-supplied chain.
    if !bridge_legacy_targets_allowed(s,[]executor.Legacy_Resource{{"instance",current.instance}}) do return false,"legacy_fenced"
    if request.instance!=launch.instance || bridge_executor_local_spawn_digest(request)!=launch.spawn_digest do return false,"invalid_resources"
    for pair in request.env do if strings.has_prefix(pair[0],"HEIMDALL_EXECUTOR_") {return false,"reserved_launch_key"}
    if !bridge_pty_host_local_executor_capable(socket) do return false,"local_executor_unsupported"
    if !executor.local_begin_dispatch(s,launch,clock(clock_ctx),resources) do return bridge_executor_local_observe(s,launch,socket)
    if !executor.local_dispatch_current(s,launch,clock(clock_ctx)) do return false,"local_admission_not_current"
    // Consume the durable first-I/O permission before any bootstrap/token
    // mutation. A crash or failed preparation remains charged and query-only.
    if prepare!=nil && !prepare(prepare_ctx) do return false,"startup_prepare_failed"
    if !executor.local_dispatch_current(s,launch,clock(clock_ctx)) do return false,"local_admission_not_current"
    req:=request
    env:=make([][2]string,len(request.env)+2,context.temp_allocator)
    copy(env,request.env)
    env[len(request.env)]={"HEIMDALL_EXECUTOR_LAUNCH_KEY",launch.launch_key}
    env[len(request.env)+1]={"HEIMDALL_EXECUTOR_LOCAL_LAUNCH","1"}
    req.env=env
    _,_=bridge_pty_host_spawn(socket,req)
    return bridge_executor_local_observe(s,launch,socket)
}

bridge_executor_local_observe :: proc(s:^executor.Store,launch:executor.Local_Launch,socket:string)->(bool,string) {
    _,current:=executor.local_observation_current(s,launch)
    if !current do return false,"stale_local_launch"
    pid,known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    if !known do return false,"executor_uncertain"
    if !executor.observe_local_child(s,launch,executor.Child_Observation{launch.instance,launch.launch_key,launch.incarnation,pid>0}) do return false,"observation_not_committed"
    return true,("child_present" if pid>0 else "child_absent")
}

bridge_executor_local_reconcile_batch :: proc(s:^executor.Store,socket,after:string)->(string,bool) {
    candidates,read:=executor.local_reconcile_candidates(s,after,executor.RECONCILE_BATCH_MAX)
    if !read do return after,false
    next:=""
    for launch in candidates {
        stop,current:=executor.local_observation_current(s,launch)
        next=launch.id
        if !current do continue
        if stop do _=bridge_pty_host_executor_close(socket,launch.instance,launch.launch_key)
        _,_=bridge_executor_local_observe(s,launch,socket)
    }
    _=executor.complete_recovery(s,bridge_executor_physical_clock(nil))
    return next,true
}
