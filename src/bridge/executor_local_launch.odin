package main

import "core:strings"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// The immutable digest covers the full framed Spawn, including exact argv,
// environment, startup credentials, cwd, timeout and provider configuration.
// This is computed before Bridge-only exact-control fields are appended.
bridge_executor_local_spawn_digest :: proc(request:Pty_Host_Spawn_Request)->string {
    frame:=pty_host_encode_spawn(request);defer delete(frame)
    return contracts.owner_payload_digest(transmute(string)frame)
}

// Only trusted native launch code supplies request. Never decode a Spawn from
// a relay. The current signed directory is canonicalized again before I/O.
bridge_executor_resolve_local :: proc(s:^executor.Store,configuration:string,request:Pty_Host_Spawn_Request)->executor.Local_Resources {
    c,valid:=contracts.executor_parse(configuration,"local_configuration")
    if !valid || request.instance!=contracts.owner_string(c,"instance_id") do return {}
    get:=contracts.owner_string
    for pair in request.env do if strings.has_prefix(pair[0],"HEIMDALL_EXECUTOR_") {return {}}
    mapping,found:=executor.directory_mapping(s,get(c,"directory_id"))
    if !found || mapping.revision!=contracts.executor_number(c,"directory_revision") || mapping.key!=get(c,"directory_key") do return {}
    canonical,within:=bridge_executor_canonical_directory(mapping.path)
    if !within || executor.directory_key(s.executor,canonical)!=mapping.key do return {}
    provider,model,profile:=get(c,"provider"),get(c,"model"),get(c,"provider_profile")
    if !bridge_provider_catalog_has_model(provider,model) do return {}
    resolved,err:=profile_lookup(provider,profile)
    if err!=.None || !resolved.enabled || resolved.provider!=provider || resolved.profile_id!=profile || !profile_has_model(&resolved,provider,model) do return {}
    digest:=bridge_executor_local_spawn_digest(request)
    if digest!=get(c,"spawn_digest") do return {}
    return executor.Local_Resources{contracts.owner_payload_digest(configuration),digest,canonical,true}
}

// Caller holds startup I/O serialization and the shared vault authority gate,
// with keys freshly resolved from paired enrollment. No SQL transaction spans
// daemon I/O. Once first permission is consumed every retry is exact query only.
bridge_executor_local_dispatch :: proc(s:^executor.Store,launch:executor.Local_Launch,key:contracts.Owner_Verified_Key,
    request:Pty_Host_Spawn_Request,resources:executor.Local_Resources,socket:string,
    clock_ctx:rawptr=nil,clock:Executor_Now=bridge_executor_physical_clock)->(bool,string) {
    if clock==nil do return false,"clock_required"
    current,found:=executor.local_launch(s,launch.id)
    if !found || current.incarnation!=launch.incarnation || current.instance!=launch.instance || current.launch_key!=launch.launch_key ||
       current.configuration!=launch.configuration || current.spawn_digest!=launch.spawn_digest {return false,"stale_local_launch"}
    if current.state!="admitted" do return bridge_executor_local_observe(s,current,socket)
    if request.instance!=launch.instance || bridge_executor_local_spawn_digest(request)!=launch.spawn_digest do return false,"invalid_resources"
    for pair in request.env do if strings.has_prefix(pair[0],"HEIMDALL_EXECUTOR_") {return false,"reserved_launch_key"}
    if !bridge_pty_host_local_executor_capable(socket) do return false,"local_executor_unsupported"
    if !executor.local_begin_dispatch(s,launch,key,clock(clock_ctx),resources) do return bridge_executor_local_observe(s,launch,socket)
    if !executor.local_dispatch_current(s,launch,key,clock(clock_ctx)) do return false,"local_admission_not_current"
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
