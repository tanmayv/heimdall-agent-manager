package main

import "core:encoding/json"
import "core:sync"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// Initial required observation families, NOT an exhaustive classification of
// resource effects. Other/nested/MCP/provider work remains unknown until its
// actual effects can be positively excluded or independently inventoried.
bridge_legacy_dispatch_requires_observation :: proc(spec:Bridge_Command_Spec)->bool {
    return spec.key_kind==.Agent || spec.key_kind==.Filesystem ||
        spec.key_kind==.VCS || spec.key_kind==.Shell || spec.key_kind==.LSP
}

// Caller holds executor application mutex. Only an unconfigured Bridge identity
// permits pre-enrollment compatibility, never proof of no relevant work. Otherwise
// inability to open the journal refuses the action before its handler executes.
bridge_legacy_dispatch_store_locked :: proc(injected:^executor.Store)->(^executor.Store,bool) {
    if injected!=nil do return injected,true
    if bridge_config.daemon_id=="" do return nil,true
    store:=bridge_legacy_global_store()
    return store,store!=nil
}

// Caller holds executor application mutex. Preserve original empty claims;
// dispatcher-synthesized wake IDs are never substituted into native evidence.
bridge_legacy_dispatch_prepare_locked :: proc(text,kind:string,spec:Bridge_Command_Spec,store:^executor.Store)->(executor.Legacy_Action,bool) {
    if !bridge_legacy_dispatch_requires_observation(spec) || store==nil do return {},true
    command_id,chain:="",""
    value,valid:=contracts.owner_content_document(text)
    if object,is_object:=value.(json.Object);valid && is_object {
        command_id=contracts.owner_string(object,"command_id")
        chain=contracts.owner_string(object,"chain_id")
        if !contracts.owner_field_valid(command_id,"optional") do command_id=""
        if !contracts.owner_field_valid(chain,"optional") do chain=""
    }
    action,result:=executor.legacy_action_receive(store,executor.Legacy_Action_Input{
        command_id=command_id,kind=kind,chain_claim=chain,
        packet_digest=contracts.owner_payload_digest(text)})
    if result.code!="ok" do return {},false
    queued:=executor.legacy_action_transition(store,action,"received","prepared")
    return action,queued.code=="ok"
}

bridge_legacy_dispatch_prepare :: proc(text,kind:string,spec:Bridge_Command_Spec,injected:^executor.Store=nil)->(executor.Legacy_Action,bool) {
    if !bridge_legacy_dispatch_requires_observation(spec) do return {},true
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    store,available:=bridge_legacy_dispatch_store_locked(injected)
    if !available do return {},false
    return bridge_legacy_dispatch_prepare_locked(text,kind,spec,store)
}

bridge_legacy_dispatch_start :: proc(job:^Bridge_Dispatch_Job,injected:^executor.Store=nil)->bool {
    spec,known:=bridge_command_spec(job.command_type)
    if !known do return false
    if !bridge_legacy_dispatch_requires_observation(spec) do return true
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    store,available:=bridge_legacy_dispatch_store_locked(injected)
    if !available do return false
    if store==nil do return job.legacy_action.id==0 && !job.paired_observation_required
    // A pre-enrollment queued job may run only after new paired observation.
    // Its earlier unobserved queue interval remains unknown.
    if job.legacy_action.id==0 {
        action,prepared:=bridge_legacy_dispatch_prepare_locked(job.text,job.command_type,spec,store)
        if !prepared do return false
        job.legacy_action=action
    }
    started:=executor.legacy_action_transition(store,job.legacy_action,"prepared","running")
    return started.code=="ok" && !started.replay
}

// A storage/enrollment/restart failure leaves retained unresolved evidence.
// Returned is solely a handler boundary, never a child/resource disposition.
bridge_legacy_dispatch_end :: proc(action:executor.Legacy_Action,ran:bool,injected:^executor.Store=nil)->bool {
    if action.id==0 do return true
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    store,available:=bridge_legacy_dispatch_store_locked(injected)
    if !available || store==nil do return false
    from,to:="prepared","discarded"
    if ran {from="running";to="returned"}
    return executor.legacy_action_transition(store,action,from,to).code=="ok"
}

// Caller holds executor application mutex. The action is carried alongside the
// invocation, never added to serialized local launch material or consent scope.
bridge_legacy_action_observe_selected_draft :: proc(store:^executor.Store,action:executor.Legacy_Action,command,draft:string,index:i64,entry_digest:string)->bool {
    if action.id==0 do return true // Unobserved producer remains unknown.
    digest:=entry_digest
    if index== -1 do digest=contracts.owner_payload_digest(command)
    result:=executor.legacy_action_observe_draft(store,executor.Legacy_Action_Draft{
        action=action,entry_index=index,entry_digest=digest,
        native_request_digest=contracts.owner_payload_digest(command),draft_id=draft})
    return result.code=="ok"
}

// Caller holds application/startup/physical gates. Query the exact retained
// native key, then persist presence before applying any task pack or keystroke.
// An unresolved child is never replaced and a historical row is not fresh proof.
bridge_legacy_observe_nudge_locked :: proc(store:^executor.Store,action:executor.Legacy_Action,instance:string,run:int,index:i64,entry_digest,socket:string)->bool {
    if action.id==0 do return true // Producer remains outside verified coverage.
    if store==nil || index<0 || !contracts.owner_hex(entry_digest,64) do return false
    sync.mutex_lock(&store.mutex)
    rows,read:=executor.query(store.db,"SELECT launch_id,launch_key FROM executor_local_launches WHERE instance_id=? AND state='active' AND observed_incarnation=?",instance,executor.encode(store.incarnation))
    sync.mutex_unlock(&store.mutex)
    if !read || len(rows)!=1 do return false
    pid,known:=bridge_pty_host_executor_query(socket,instance,rows[0][1])
    if !known || pid<=0 do return false
    result:=executor.legacy_action_observe_nudge(store,executor.Legacy_Action_Nudge{
        action=action,entry_index=index,entry_digest=entry_digest,launch_id=rows[0][0],child_pid=i64(pid),run_count=i64(run)})
    return result.code=="ok" && !result.replay
}
