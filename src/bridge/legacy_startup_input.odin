package main

import "core:sync"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// Caller holds application -> startup I/O -> physical gates. The native
// journal, retained token issuance, current project directory and both daemon
// identities must agree before a startup reminder can write to the PTY.
// Unknown historical children are never replaced or treated as absent.
bridge_legacy_startup_input_allowed_locked :: proc(s:^executor.Store,inst:Bridge_Runtime_Instance,socket:string)->bool {
    if s==nil do return bridge_config.daemon_id=="" // Pre-enrollment remains unknown.
    if !bridge_startup_rec_current(inst.startup.rec) || inst.startup.pty_pid<=0 || inst.startup.rec.run_count<=0 do return false
    sync.mutex_lock(&s.mutex)
    if s.db==nil || s.unusable {sync.mutex_unlock(&s.mutex);return false}
    rows,read:=executor.query(s.db,`SELECT l.launch_key,l.configuration,d.material
      FROM executor_local_launches l JOIN executor_local_drafts d ON d.launch_id=l.launch_id
      WHERE l.instance_id=? AND l.state='active' AND l.observed_incarnation=? AND d.state='authorized'`,
      inst.agent_instance_id,executor.encode(s.incarnation))
    sync.mutex_unlock(&s.mutex)
    if !read || len(rows)!=1 do return false
    material,valid:=bridge_executor_local_material(executor.Local_Draft{configuration=rows[0][1],material=rows[0][2]})
    if !valid || material.run_count!=inst.startup.rec.run_count ||
       bridge_local_hash_token(material.token)!=inst.startup.rec.token_hash ||
       inst.startup.launch_key!=inst.startup.rec.token_hash {return false}
    resources:=bridge_executor_resolve_local(s,rows[0][1],material)
    if !resources.resolved do return false
    targets:=make([dynamic]executor.Legacy_Resource,context.temp_allocator)
    append(&targets,executor.Legacy_Resource{"instance",inst.agent_instance_id})
    for path,i in ([3]string{resources.directory_path,material.run_dir,material.request.cwd}) {
        if path=="" && i==0 do continue // A launch without a project.
        if path=="" do return false
        canonical,exists:=bridge_executor_canonical_directory(path)
        if !exists do return false
        target:=executor.Legacy_Resource{"workdir_hash",contracts.owner_payload_digest(canonical)}
        duplicate:=false
        for other in targets do if other==target {duplicate=true;break}
        if !duplicate do append(&targets,target)
    }
    if !bridge_legacy_targets_allowed(s,targets[:]) do return false
    native_pid,native_known:=bridge_pty_host_executor_query(socket,inst.agent_instance_id,rows[0][0])
    startup_pid,startup_known:=bridge_pty_host_startup_launch(socket,inst.agent_instance_id,inst.startup.launch_key)
    return native_known && startup_known && native_pid==inst.startup.pty_pid && startup_pid==native_pid &&
        bridge_startup_job_current(inst.agent_instance_id,inst.startup.generation)
}
