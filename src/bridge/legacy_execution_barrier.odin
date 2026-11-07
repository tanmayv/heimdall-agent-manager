package main

import "core:strings"
import "core:sync"
import jsonx "odin_test:lib/jsonx"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

// Order: executor application mutex (when using the global journal), startup
// I/O (for child mutation), physical gate, then Store.mutex. No SQL transaction
// spans physical I/O. Installation waits for all guarded invocations to return.
// This gate does not prove absence: legacy origin and surviving children still
// need exhaustive authenticated evidence before any migration freeze.
bridge_legacy_physical_mutex:sync.Mutex

// Caller serializes Store lifecycle. Only the eventual authenticated migration
// receiver may call this with the verified full target inventory. No Hub/agent
// route currently exposes it; unverified caller chain fields confer no authority.
bridge_legacy_install_barrier :: proc(s:^executor.Store,b:executor.Legacy_Barrier,targets:[]executor.Legacy_Resource,snapshot:^executor.Legacy_Journal_Snapshot=nil)->executor.Result {
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    return executor.legacy_barrier_install(s,b,targets,snapshot)
}

// Caller holds the physical gate. Compare actual execution targets, independent
// of any chain asserted by the incoming command. Never cache a negative result.
bridge_legacy_targets_allowed :: proc(s:^executor.Store,targets:[]executor.Legacy_Resource)->bool {
    if s==nil do return false
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || !executor.legacy_resources_valid(targets) do return false
    for target in targets {
        rows,read:=executor.query(s.db,"SELECT 1 FROM executor_legacy_resources WHERE kind=? AND resource_id=? LIMIT 1",target.kind,target.id)
        if !read || len(rows)>0 do return false
    }
    return true
}

// Caller holds bridge_executor_mutex. Reopen the durable journal after restart;
// an unopened in-memory Store is never evidence that no barrier exists.
bridge_legacy_global_store :: proc()->^executor.Store {
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key,identified:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if account=="" || !identified || !bridge_executor_open(account,key) do return nil
    return &bridge_executor_store
}

bridge_legacy_stop_target :: proc(s:^executor.Store,instance:string,force:bool)->bool {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    if !bridge_legacy_targets_allowed(s,[]executor.Legacy_Resource{{"instance",instance}}) do return false
    // Only a retained native admission supplies an exact close key. An
    // instance ID or generic process listing cannot authorize a retargeted stop.
    sync.mutex_lock(&s.mutex)
    rows,read:=executor.query(s.db,"SELECT launch_key FROM executor_local_launches WHERE instance_id=? AND state IN ('dispatching','active','stopping')",instance)
    sync.mutex_unlock(&s.mutex)
    if !read || len(rows)>1 do return false
    key:=""
    if len(rows)==1 do key=rows[0][0]
    return bridge_runtime_stop_agent_unfenced(instance,force,key)
}

bridge_legacy_merge_target :: proc(s:^executor.Store,repo,workdir,branch,task:string)->Bridge_Taskv2_Merge_Result {
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    if strings.trim_space(workdir)=="" || !contracts.owner_field_valid(task,"id") do return Bridge_Taskv2_Merge_Result{detail="legacy merge target unresolved"}
    canonical:=bridge_fs_canonicalize_existing(workdir);defer delete(canonical)
    canonical_repo:=bridge_fs_canonicalize_existing(repo);defer delete(canonical_repo)
    // Bind the actual registered worktree/branch convention established by
    // ensure_task_worktree. A command cannot substitute another workdir while
    // still merging the original protected branch.
    expected:=strings.concatenate({canonical_repo,"/.heimdall/worktrees/",task},context.temp_allocator)
    actual_branch,branch_read:=vcs_run([]string{"git","-C",canonical,"symbolic-ref","--short","HEAD"})
    defer delete(actual_branch)
    if canonical!=expected || branch!=strings.concatenate({"heimdall/",task},context.temp_allocator) ||
       !branch_read || strings.trim_space(actual_branch)!=branch || !bridge_taskv2_is_checkout_root(canonical) ||
       !bridge_legacy_targets_allowed(s,[]executor.Legacy_Resource{{"task",task},{"workdir_hash",contracts.owner_payload_digest(canonical)}}) {
        return Bridge_Taskv2_Merge_Result{detail="legacy merge target fenced or unresolved"}
    }
    return bridge_taskv2_merge_task_worktree_unfenced(canonical_repo,canonical,branch,task)
}

// Caller holds startup I/O and the physical gate. Derive all protected targets
// from the pack that will actually be applied. A claimed chain is never used.
// This is protective refusal, not authenticated source provenance or drain.
bridge_legacy_apply_pack_locked :: proc(s:^executor.Store,instance,run_dir,pack:string)->bool {
    targets:=make([dynamic]executor.Legacy_Resource,context.temp_allocator)
    append(&targets,executor.Legacy_Resource{"instance",instance})
    task_obj,_:=jsonx.extract_raw_object(pack,"task",true,context.temp_allocator)
    task:=jsonx.extract_string(pack,"task_id",jsonx.extract_string(task_obj,"task_id","",true,context.temp_allocator),true,context.temp_allocator)
    if task!="" do append(&targets,executor.Legacy_Resource{"task",task})
    place,has:=jsonx.extract_raw_object(pack,"placement",true,context.temp_allocator)
    if !has {
        lease,found:=jsonx.extract_raw_object(pack,"lease",true,context.temp_allocator)
        if found do place,has=jsonx.extract_raw_object(lease,"placement",true,context.temp_allocator)
    }
    workdir_hash:=""
    if has {
        workdir:=jsonx.extract_string(place,"workdir","",true,context.temp_allocator)
        if workdir!="" {
            canonical:=bridge_fs_canonicalize_existing(workdir);defer delete(canonical)
            workdir_hash=contracts.owner_payload_digest(canonical)
            append(&targets,executor.Legacy_Resource{"workdir_hash",workdir_hash})
        }
    }
    if run_dir!="" {
        canonical:=bridge_fs_canonicalize_existing(run_dir);defer delete(canonical)
        digest:=contracts.owner_payload_digest(canonical)
        if digest!=workdir_hash do append(&targets,executor.Legacy_Resource{"workdir_hash",digest})
    }
    if !bridge_legacy_targets_allowed(s,targets[:]) do return false
    bridge_taskv2_ensure_pack_worktree(pack)
    return run_dir=="" || bridge_taskv2_materialize_task_md(run_dir,pack)
}

bridge_legacy_apply_pack :: proc(s:^executor.Store,instance,run_dir,pack:string)->bool {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    return bridge_legacy_apply_pack_locked(s,instance,run_dir,pack)
}
