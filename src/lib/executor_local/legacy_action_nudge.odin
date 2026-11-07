package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Private trusted Bridge observation after querying an exact native daemon key.
// A PID here is presence at an observation boundary, never absence, authority,
// a task/lease grant, or a substitute for fresh signed migration evidence.
Legacy_Action_Nudge :: struct {
    action:Legacy_Action,
    entry_index,child_pid,run_count:i64,
    entry_digest,launch_id:string,
}
legacy_action_observe_nudge :: proc(s:^Store,o:Legacy_Action_Nudge)->Result {
    if o.action.id<=0 || o.action.incarnation<=0 || o.entry_index<0 || o.child_pid<=0 || o.run_count<=0 ||
       !contracts.owner_hex(o.entry_digest,64) || !contracts.owner_field_valid(o.launch_id,"id") {return fail("invalid_scope")}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    if o.action.scope!=legacy_action_scope(s) do return fail("invalid_scope")
    id:=contracts.owner_payload_digest(encode(struct{action,index:i64,launch:string}{o.action.id,o.entry_index,o.launch_id}))
    existing,read:=query(s.db,"SELECT entry_digest,child_pid,run_count,observed_incarnation,launch_id FROM executor_legacy_action_nudges WHERE action_id=? AND entry_index=?",fmt.tprintf("%d",o.action.id),fmt.tprintf("%d",o.entry_index))
    if !read do return fail("storage_error")
    if len(existing)>0 {
        r:=existing[0]
        if r[0]!=o.entry_digest || number(r[1])!=o.child_pid || number(r[2])!=o.run_count || number(r[3])!=o.action.incarnation || r[4]!=o.launch_id do return fail("observation_conflict")
        return Result{code="ok",body=id,replay=true}
    }
    action,read_action:=query(s.db,"SELECT observed_incarnation,state FROM executor_legacy_actions WHERE action_id=?",fmt.tprintf("%d",o.action.id))
    if !read_action do return fail("storage_error")
    if len(action)!=1 || number(action[0][0])!=o.action.incarnation || o.action.incarnation!=s.incarnation || action[0][1]!="running" do return fail("invalid_scope")
    launch,read_launch:=query(s.db,"SELECT launch_key,configuration,instance_id,directory_key,state,observed_incarnation FROM executor_local_launches WHERE launch_id=?",o.launch_id)
    if !read_launch do return fail("storage_error")
    if len(launch)!=1 do return fail("launch_not_found")
    l:=launch[0]
    config,valid:=contracts.executor_parse(l[1],"local_configuration")
    if !valid || l[4]!="active" || number(l[5])!=s.incarnation || number(field(config,"run_count"))!=o.run_count ||
       field(config,"instance_id")!=l[2] || field(config,"directory_key")!=l[3] {return fail("invalid_scope")}
    counts,counted:=query(s.db,"SELECT count(*) FROM executor_legacy_action_nudges")
    if !counted || len(counts)!=1 do return fail("storage_error")
    if number(counts[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    _,written:=query(s.db,"INSERT INTO executor_legacy_action_nudges VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        id,fmt.tprintf("%d",o.action.id),fmt.tprintf("%d",o.entry_index),o.entry_digest,o.launch_id,l[0],
        contracts.owner_payload_digest(l[1]),l[2],l[3],fmt.tprintf("%d",o.child_pid),fmt.tprintf("%d",o.run_count),fmt.tprintf("%d",s.incarnation))
    if !written || !commit(s) do return fail("storage_error")
    return Result{code="ok",body=id}
}
