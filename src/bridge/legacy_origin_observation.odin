package main

import "core:encoding/json"
import contracts "odin_test:contracts"

// Native observation, NOT historical authority or a task grant. This records
// what this Bridge actually received and transformed. Only later explicit
// migration adoption plus independent signed current completeness can use it.
// Original commands/tokens never enter inventories; retain their raw hashes.
Executor_Legacy_Origin :: struct {
    version,account,parent_command_id,parent_digest,entry_digest:string,
    parent_chain,entry_chain,instance,task,lease,native_command_digest:string,
    entry_index:i64,
}

bridge_legacy_wake_observations :: proc(parent:string)->([]Executor_Legacy_Origin,bool) {
    p,valid:=contracts.owner_content_document(parent)
    if !valid do return nil,false
    root,object:=p.(json.Object)
    if !object || contracts.owner_string(root,"type")!="wake_agent" do return nil,false
    id,chain:=contracts.owner_string(root,"command_id"),contracts.owner_string(root,"chain_id")
    payload,present:=contracts.owner_content_member_bytes(parent,"payload")
    if !present do return nil,false
    raw_runs,has_runs:=contracts.owner_content_member_bytes(payload,"run")
    if !has_runs do return nil,false
    entries,parsed:=contracts.owner_content_array_bytes(raw_runs)
    if !parsed do return nil,false
    if id!="" && !contracts.owner_field_valid(id,"id") || chain!="" && !contracts.owner_field_valid(chain,"id") do return nil,false
    parent_digest:=contracts.owner_payload_digest(parent)
    observations:=make([]Executor_Legacy_Origin,len(entries),context.temp_allocator)
    for raw_entry,index in entries {
        entry_value,entry_valid:=contracts.owner_content_document(raw_entry)
        entry,is_object:=entry_value.(json.Object)
        if !entry_valid || !is_object do return nil,false
        get:=contracts.owner_string
        instance,task,lease,entry_chain:=get(entry,"agent_instance_id"),get(entry,"task_id"),get(entry,"lease_id"),get(entry,"chain_id")
        if !contracts.owner_field_valid(instance,"id") || !contracts.owner_field_valid(task,"optional") || !contracts.owner_field_valid(lease,"optional") || !contracts.owner_field_valid(entry_chain,"optional") || chain!="" && entry_chain!="" && entry_chain!=chain do return nil,false
        // Legacy id-less/unscoped wakes retain normal launch behavior but have no
        // adoptable origin. Never manufacture an ID or backfill a chain claim.
        if id=="" || chain=="" do continue
        observations[index]=Executor_Legacy_Origin{version="1",parent_command_id=id,parent_digest=parent_digest,entry_digest=contracts.owner_payload_digest(raw_entry),parent_chain=chain,entry_chain=entry_chain,instance=instance,task=task,lease=lease,entry_index=i64(index)}
    }
    return observations,true
}

bridge_legacy_wake_entry_observation :: proc(parent:string,index:int)->(Executor_Legacy_Origin,bool) {
    observations,ok:=bridge_legacy_wake_observations(parent)
    if !ok || index<0 || index>=len(observations) do return {},false
    return observations[index],true
}

bridge_legacy_origin_matches_native :: proc(origin:Executor_Legacy_Origin,command:string)->bool {
    if origin.version!="1" || origin.entry_index<0 || !contracts.owner_field_valid(origin.parent_command_id,"id") || !contracts.owner_field_valid(origin.parent_chain,"id") || !contracts.owner_hex(origin.parent_digest,64) || !contracts.owner_hex(origin.entry_digest,64) || origin.native_command_digest!=contracts.owner_payload_digest(command) do return false
    if !contracts.owner_field_valid(origin.instance,"id") || !contracts.owner_field_valid(origin.task,"optional") || !contracts.owner_field_valid(origin.lease,"optional") || !contracts.owner_field_valid(origin.entry_chain,"optional") || origin.entry_chain!="" && origin.entry_chain!=origin.parent_chain do return false
    payload,present:=contracts.owner_content_member_bytes(command,"payload")
    if !present do return false
    value,valid:=contracts.owner_content_document(payload)
    object,is_object:=value.(json.Object)
    if !valid || !is_object do return false
    get:=contracts.owner_string
    return get(object,"agent_instance_id")==origin.instance && get(object,"task_id")==origin.task && get(object,"lease_id")==origin.lease && get(object,"chain_id")==origin.entry_chain
}
