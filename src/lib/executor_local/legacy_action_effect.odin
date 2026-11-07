package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Actual native targets observed before a stop or Git merge. These records
// associate a running packet occurrence with its effects; they confer no
// historical origin, task grant, completeness, or physical absence.
Legacy_Stop_Evidence :: struct {
    instance_id,launch_id,launch_key,configuration_digest,directory_key:string,
    run_count,child_pid:i64,
}
Legacy_Merge_Evidence :: struct {
    task_id,repository_hash,workdir_hash,branch,repository_head,worktree_head:string,
}

// Caller holds Store.mutex and a transaction. Replays are read-only even after
// restart. New writes require the current exact running occurrence.
legacy_action_effect_tx :: proc(s:^Store,a:Legacy_Action,kind:string,index:i64,entry_digest,evidence:string)->Result {
    if a.scope!=legacy_action_scope(s) do return fail("invalid_scope")
    digest:=contracts.owner_payload_digest(evidence)
    id:=contracts.owner_payload_digest(encode(struct{action:i64,kind:string,index:i64}{a.id,kind,index}))
    rows,read:=query(s.db,"SELECT entry_digest,evidence,evidence_digest,observed_incarnation FROM executor_legacy_action_effects WHERE action_id=? AND effect_kind=? AND entry_index=?",fmt.tprintf("%d",a.id),kind,fmt.tprintf("%d",index))
    if !read do return fail("storage_error")
    if len(rows)>0 {
        r:=rows[0]
        if r[0]!=entry_digest || r[1]!=evidence || r[2]!=digest || number(r[3])!=a.incarnation do return fail("observation_conflict")
        return Result{code="ok",body=id,replay=true}
    }
    action,read_action:=query(s.db,"SELECT observed_incarnation,state,command_kind,packet_digest FROM executor_legacy_actions WHERE action_id=?",fmt.tprintf("%d",a.id))
    if !read_action do return fail("storage_error")
    if len(action)!=1 || number(action[0][0])!=a.incarnation || a.incarnation!=s.incarnation || action[0][1]!="running" do return fail("invalid_scope")
    command:=action[0][2]
    if index== -1 {
        if entry_digest!=action[0][3] || kind=="stop" && command!="stop_agent" || kind=="merge" && command!="taskv2_merge_worktree" do return fail("invalid_scope")
    } else if kind!="stop" || command!="wake_agent" {return fail("invalid_scope")}
    counts,counted:=query(s.db,"SELECT count(*) FROM executor_legacy_action_effects")
    if !counted || len(counts)!=1 do return fail("storage_error")
    if number(counts[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    _,written:=query(s.db,"INSERT INTO executor_legacy_action_effects VALUES(?,?,?,?,?,?,?,?)",id,fmt.tprintf("%d",a.id),kind,fmt.tprintf("%d",index),entry_digest,evidence,digest,fmt.tprintf("%d",s.incarnation))
    if !written do return fail("storage_error")
    return Result{code="ok",body=id}
}

legacy_action_observe_stop :: proc(s:^Store,a:Legacy_Action,index:i64,entry_digest:string,o:Legacy_Stop_Evidence)->Result {
    if a.id<=0 || a.incarnation<=0 || index< -1 || o.run_count<=0 || o.child_pid<0 ||
       !contracts.owner_hex(entry_digest,64) || !contracts.owner_field_valid(o.instance_id,"id") ||
       !contracts.owner_field_valid(o.launch_id,"id") || !contracts.owner_hex(o.launch_key,64) ||
       !contracts.owner_hex(o.configuration_digest,64) || !contracts.owner_hex(o.directory_key,64) {return fail("invalid_scope")}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    // Resolve exact native identity independently of caller command claims.
    launch,read:=query(s.db,"SELECT configuration,instance_id,launch_key,directory_key,state,observed_incarnation FROM executor_local_launches WHERE launch_id=?",o.launch_id)
    if !read do return fail("storage_error")
    if len(launch)!=1 do return fail("launch_not_found")
    l:=launch[0]
    config,valid:=contracts.executor_parse(l[0],"local_configuration")
    if !valid || l[1]!=o.instance_id || l[2]!=o.launch_key || l[3]!=o.directory_key ||
       contracts.owner_payload_digest(l[0])!=o.configuration_digest || number(field(config,"run_count"))!=o.run_count {
        return fail("invalid_scope")
    }
    result:=legacy_action_effect_tx(s,a,"stop",index,entry_digest,encode(o))
    if result.code!="ok" || result.replay do return result
    if (l[4]!="active" && l[4]!="dispatching" && l[4]!="stopping") || number(l[5])!=s.incarnation do return fail("invalid_scope")
    if !commit(s) do return fail("storage_error")
    return result
}

legacy_action_observe_merge :: proc(s:^Store,a:Legacy_Action,entry_digest:string,o:Legacy_Merge_Evidence)->Result {
    if a.id<=0 || a.incarnation<=0 || !contracts.owner_hex(entry_digest,64) ||
       !contracts.owner_field_valid(o.task_id,"id") || !contracts.owner_hex(o.repository_hash,64) ||
       !contracts.owner_hex(o.workdir_hash,64) || o.branch!=fmt.tprintf("heimdall/%s",o.task_id) ||
       !(contracts.owner_hex(o.repository_head,40) || contracts.owner_hex(o.repository_head,64)) ||
       !(contracts.owner_hex(o.worktree_head,40) || contracts.owner_hex(o.worktree_head,64)) {return fail("invalid_scope")}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    result:=legacy_action_effect_tx(s,a,"merge",-1,entry_digest,encode(o))
    if result.code!="ok" || result.replay do return result
    if !commit(s) do return fail("storage_error")
    return result
}
