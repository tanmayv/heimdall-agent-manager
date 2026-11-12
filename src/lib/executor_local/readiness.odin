package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Local readiness is authenticated again before replay. A retained successful
// receipt never authenticates a rotated, expired, stopped or replaced child.
child_ready :: proc(s:^Store,instance,secret:string,observation:Child_Observation,
    owner_key,executor_key:contracts.Owner_Verified_Key,now:i64)->Result {
    context.allocator=context.temp_allocator
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    now:=effective_now(s,now) // C1: decide with max(caller clock, store clock), under the store mutex
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    raw,authenticated:=child_bootstrap_locked(s,instance,secret,now)
    if !authenticated do return fail("invalid_scope")
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed || !contracts.executor_verify("bootstrap",b,owner_key) || !executor_key.enrolled || executor_key.revoked ||
       executor_key.kind!="bridge" || executor_key.account_id!=s.account || executor_key.principal_id!=s.executor ||
       executor_key.key_id!=s.operator_key {return fail("invalid_scope")}
    if !observation.present || observation.executor_incarnation!=s.incarnation || observation.instance!=instance ||
       observation.launch_key!=field(b,"launch_key") {return fail("child_not_current")}
    rows,read:=query(s.db,"SELECT instance_id,launch_key,token_generation,executor_incarnation,ready_ms FROM executor_readiness WHERE reservation_id=?",field(b,"reservation_id"))
    if !read do return fail("storage_error")
    if len(rows)>0 {
        row:=rows[0]
        if row[0]!=instance || row[1]!=observation.launch_key || row[2]!=field(b,"token_generation") ||
           number(row[3])!=s.incarnation {return fail("invalid_scope")}
        return Result{"ok",encode(contracts.Executor_Readiness_Ack{true,row[4]}),true}
    }
    if code:=clock(s,now);code!="" do return fail(code)
    if _,written:=query(s.db,"INSERT INTO executor_readiness VALUES(?,?,?,?,?,?)",field(b,"reservation_id"),instance,
        observation.launch_key,field(b,"token_generation"),fmt.tprintf("%d",s.incarnation),fmt.tprintf("%d",now));!written do return fail("storage_error")
    if !commit(s) do return fail("storage_error")
    return Result{code="ok",body=encode(contracts.Executor_Readiness_Ack{true,fmt.tprintf("%d",now)})}
}
