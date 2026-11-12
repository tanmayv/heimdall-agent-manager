package main

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// Caller holds launch-configuration read serialization. This read-only pin
// binds the signed selection to the current profile, catalog and directory
// identity; it neither rematerializes bootstrap nor mutates runtime settings.
bridge_executor_launch_resource_pin :: proc(s:^executor.Store,intent:executor.Intent,now:i64)->(string,bool) {
    material,ready:=executor.launch_material(s,intent,now)
    if !ready do return "",false
    defer crypto.zero_explicit(raw_data(material.token_secret),len(material.token_secret))
    c,valid:=contracts.owner_parse(material.configuration,"remote_configuration")
    if !valid do return "",false
    mapping,found:=executor.directory_mapping(s,contracts.owner_string(c,"directory_id"))
    if !found do return "",false
    canonical,within:=bridge_executor_canonical_directory(mapping.path)
    if !within || mapping.key!=contracts.owner_string(c,"directory_key") || executor.directory_key(s.executor,canonical)!=mapping.key do return "",false
    identity,exists:=bridge_os_socket_file_identity(canonical)
    if !exists do return "",false
    // Directory contents may legitimately change during bootstrap preparation
    // or owner journaling. Device/inode identify the selected directory itself.
    identity.ctime_sec=0;identity.ctime_nsec=0
    provider,model:=contracts.owner_string(c,"provider"),contracts.owner_string(c,"model")
    catalog,active:=bridge_provider_catalog_profile(provider)
    profile,err:=profile_lookup(provider,contracts.owner_string(c,"provider_profile"),prepare_runtime=false)
    if !active || err!=.None || !profile.enabled || !profile_has_model(&profile,provider,model) do return "",false
    binary,_:=bridge_provider_catalog_binary(provider,context.temp_allocator)
    bridge_provider_paths_init()
    path,state:="",""
    sync.rw_mutex_shared_lock(&bridge_provider_paths_mutex)
    for item in bridge_provider_paths {
        if item.provider==provider && profile_effective_id(provider,item.profile_id)==provider {
            path=strings.clone(item.resolved_path,context.temp_allocator);state=strings.clone(item.state,context.temp_allocator);break
        }
    }
    sync.rw_mutex_shared_unlock(&bridge_provider_paths_mutex)
    return contracts.owner_payload_digest(bridge_owner_json(struct {
        selection:string,profile:Provider_Profile,catalog:Bridge_Provider_Profile,identity:Pty_Host_Daemon_Identity,
        binary,path,state:string,
    }{material.configuration,profile,catalog,identity,binary,path,state})),true
}

// Only an exact first launch claim may materialize. Invalidation and all spawn
// I/O share startup_io_mutex. A retry after begin_dispatch queries the exact
// daemon child; it must never clean a possibly running child's directory.
bridge_executor_prepare_spawn :: proc(s:^executor.Store,intent:executor.Intent,now:i64,endpoint:string,resource_pin:^string=nil)->(Pty_Host_Spawn_Request,bool) {
    when ODIN_OS==.Windows {return {},false}
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    pin,current_resources:=bridge_executor_launch_resource_pin(s,intent,now)
    if !current_resources do return {},false
    if resource_pin!=nil do resource_pin^=pin
    material,ready:=executor.launch_material(s,intent,now)
    if !ready do return {},false
    defer crypto.zero_explicit(raw_data(material.token_secret),len(material.token_secret))
    c,configured:=contracts.owner_parse(material.configuration,"remote_configuration")
    b,signed:=contracts.executor_parse(material.bootstrap,"bootstrap")
    if !configured || !signed do return {},false
    selection:=make(json.Object,context.temp_allocator)
    for field in contracts.executor_schema("issuance_selection") do selection[field.name]=c[field.name]
    local:=bridge_executor_resolve_issuance(s,executor.encode(selection))
    if !local.resolved || local.directory_key!=contracts.owner_string(c,"directory_key") do return {},false
    provider,model:=contracts.owner_string(c,"provider"),contracts.owner_string(c,"model")
    profile,err:=profile_lookup(provider,contracts.owner_string(c,"provider_profile"))
    if err!=.None || !profile.enabled do return {},false
    // Discovery publishes under the configuration write gate. Never invoke it
    // while holding this read gate; use the current previously discovered path.
    if profile.config.binary_path=="" {
        path,found:=bridge_provider_resolve_launch_path(provider,true)
        if !found do return {},false
        profile.config.binary_path=path
    }
    dir,within:=bridge_fs_run_dir_root(intent.instance)
    if !within do return {},false
    defer delete(dir)
    result,ok:=bridge_executor_materialize(dir,endpoint,material,provider)
    if !ok do return {},false
    defer bridge_prespawn_result_delete(result)
    remaining,current:=executor.intent_current(s,intent,now)
    if !current || remaining<1000 do return {},false
    request,built:=bridge_pty_host_build_spawn(intent.instance,result.run_dir,provider,model,material.token_secret,result.env,"",u64(remaining/1000),"",&profile)
    if !built do return {},false
    // Executor activation (remote placement) gets the same startup record,
    // expectation and fallback arming as a local native launch, instead of
    // relying on later rediscovery.
    bridge_startup_record_activation(intent.instance,material.token_secret,provider,profile.profile_id,bridge_runtime_now_ms())
    // The signed mapping selects the working directory, never a remote argv or
    // path assertion. Agent instructions live in the local run directory.
    // Keep cwd at run_dir; TASK.md carries the authoritative task workdir.
    if !bridge_executor_bind_notification_spawn(&request,b,material.token_secret) {
        bridge_pty_host_spawn_request_delete(request)
        return {},false
    }
    return request,true
}

// Called only for an undispatched claim under the startup I/O mutex. Paths are
// fixed files or locally selected skill directories; remote executable content
// and caller-selected absolute paths are not part of the content contract.
bridge_executor_materialize :: proc(dir,endpoint:string,m:executor.Launch_Material,provider:string)->(Bridge_Prespawn_Result,bool) {
    get:=contracts.owner_string
    b,b_ok:=contracts.executor_parse(m.bootstrap,"bootstrap")
    c,c_ok:=contracts.owner_parse(m.configuration,"remote_configuration")
    body,valid:=contracts.executor_parse(m.body,"bootstrap_content")
    if !b_ok || !c_ok || !valid || get(b,"configuration_digest")!=contracts.owner_payload_digest(m.configuration) ||
       get(b,"body_digest")!=contracts.owner_payload_digest(m.body) || get(b,"token_generation")!=contracts.owner_payload_digest(m.token_secret) ||
       get(b,"instance_id")!=get(c,"instance_id") || endpoint=="" || dir=="" {return {},false}
    files:=make([dynamic]Bridge_Bootstrap_File,context.temp_allocator)
    names:=[3]string{bridge_bootstrap_agents_md_name(provider),"MEMORY.md","TASK.md"}
    if names[0]=="TASK.md" || names[0]=="MEMORY.md" || names[0]=="heimdall-executor-bootstrap.json" do return {},false
    fields:=[3]string{"agents_md","memory_md","task_md"}
    for name,i in names {
        field:=fields[i]
        append(&files,Bridge_Bootstrap_File{relative_path=name,content=get(body,field)})
    }
    value,_:=contracts.owner_content_document(get(body,"skills_json"));skills,_:=value.(json.Array)
    for item in skills {
        skill,_:=item.(json.Object)
        path:=bridge_bootstrap_skill_relative_path(provider,get(skill,"name"))
        if path=="" do return {},false
        defer delete(path)
        // Local catalog paths also have to remain relative and below run_dir.
        for part in strings.split(path,"/",context.temp_allocator) {
            if part=="" || part=="." || part==".." || strings.contains(part,"\\") do return {},false
        }
        if strings.has_prefix(path,"/") do return {},false
        append(&files,Bridge_Bootstrap_File{relative_path=strings.clone(path,context.temp_allocator),content=get(skill,"content")})
    }
    for local in BRIDGE_EXECUTOR_SKILLS {
        named:=false
        for item in skills {
            skill,_:=item.(json.Object)
            if strings.to_lower(get(skill,"name"),context.temp_allocator)==local.name {named=true;break}
        }
        if named do continue
        // A provider with no skill directory gets none, as for a local launch.
        path:=bridge_bootstrap_skill_relative_path(provider,local.name)
        if path=="" do continue
        append(&files,Bridge_Bootstrap_File{relative_path=strings.clone(path,context.temp_allocator),content=local.content})
        delete(path)
    }
    // Reject a planted root symlink before the existing clean-slate helper.
    if bridge_make_directory_all(dir)!=nil || !bridge_os_prepare_private_dir(dir) do return {},false
    bridge_prespawn_clean_slate(dir)
    if !bridge_os_prepare_private_dir(dir) do return {},false
    for file in files {
        path:=fmt.tprintf("%s/%s",dir,file.relative_path)
        if at:=strings.last_index_byte(path,'/');at>0 {
            if bridge_make_directory_all(path[:at])!=nil do return {},false
        }
        if os.write_entire_file(path,transmute([]byte)file.content)!=nil do return {},false
    }
    if !bridge_bootstrap_write_ham_ctl_wrapper(dir,endpoint,m.token_secret,get(b,"instance_id")) do return {},false
    if os.write_entire_file(fmt.tprintf("%s/heimdall-executor-bootstrap.json",dir),transmute([]byte)m.bootstrap)!=nil do return {},false
    return Bridge_Prespawn_Result{strings.clone(dir),bridge_prespawn_env(dir,endpoint,m.token_secret,get(b,"instance_id"))},true
}

// Bootstrap admission has already verified the owner signature and exact
// reservation. Remote tokens are not local token-store records: carry the
// admitted epoch/count directly instead of falling back to the legacy empty
// identity. Only this internal launch path may replace the derived env values.
bridge_executor_bind_notification_spawn :: proc(request:^Pty_Host_Spawn_Request,b:json.Object,secret:string)->bool {
    get:=contracts.owner_string
    if !contracts.executor_valid(b,"bootstrap") || request.instance!=get(b,"instance_id") ||
       contracts.owner_payload_digest(secret)!=get(b,"token_generation") {return false}
    env:=make([dynamic][2]string,0,len(request.env)+3)
    for pair in request.env {
        if pair[0]=="HEIMDALL_STARTUP_KEY" || pair[0]=="HEIMDALL_NOTIFICATION_EPOCH" || pair[0]=="HEIMDALL_NOTIFICATION_RUN_COUNT" {
            delete(pair[0]);delete(pair[1])
        } else {append(&env,pair)}
    }
    delete(request.env)
    // Notification IPC uses the startup key (token digest); executor query,
    // close and renewal retain the separate reservation launch key.
    append(&env,[2]string{strings.clone("HEIMDALL_STARTUP_KEY"),strings.clone(get(b,"token_generation"))})
    append(&env,[2]string{strings.clone("HEIMDALL_NOTIFICATION_EPOCH"),strings.clone(get(b,"launch_epoch"))})
    append(&env,[2]string{strings.clone("HEIMDALL_NOTIFICATION_RUN_COUNT"),strings.clone(get(b,"run_count"))})
    request.env=env[:]
    return true
}
