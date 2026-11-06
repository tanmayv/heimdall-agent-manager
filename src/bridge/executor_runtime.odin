#+feature dynamic-literals
package main

import "core:fmt"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// The owner callback must freshly verify the signed authoritative exact fence;
// it must not trust envelope assertions or reuse a historical admission receipt.
Executor_Owner_Check :: proc(ctx:rawptr,intent:executor.Intent)->executor.Current_Owner_Fence
Executor_Now :: proc(ctx:rawptr)->i64

// Callers serialize this physical I/O path with application of executor
// invalidations. No SQLite transaction spans the owner check or daemon request.
bridge_executor_dispatch :: proc(s:^executor.Store,intent:executor.Intent,now:i64,socket:string,
    request:Pty_Host_Spawn_Request,ctx:rawptr,owner_check:Executor_Owner_Check,clock_ctx:rawptr,clock:Executor_Now)->(bool,string) {
    if clock==nil do return false,"clock_required"
    if !executor.expire(s,now) do return false,"clock_or_storage_error"
    _,current:=executor.intent_current(s,intent,now)
    if !current do return false,"stale_intent"
    if intent.kind=="launch" {
        p,valid:=contracts.executor_parse(intent.document,"prepare")
        if !valid || request.instance!=intent.instance || !request.has_timeout_seconds || request.timeout_seconds==0 ||
           owner_check==nil {return false,"invalid_launch"}
        // Only the Bridge's catalog/configuration resolver may supply argv/env.
        // The exact spawn bytes become immutable in the daemon on first I/O.
        for pair in request.env do if pair[0]=="HEIMDALL_EXECUTOR_LAUNCH_KEY" || pair[0]=="HEIMDALL_EXECUTOR_DEADLINE_MS" do return false,"reserved_launch_key"
        proof:=owner_check(ctx,intent)
        if !executor.expire(s,clock(clock_ctx)) do return false,"clock_or_storage_error"
        digest,_:=contracts.executor_digest("prepare",p)
        if !proof.current || proof.prepare_digest!=digest || proof.owner_incarnation<contracts.executor_number(p,"owner_incarnation") || proof.commit_seq<=0 do return false,"owner_fence_not_current"
    }
    checked_now:=clock(clock_ctx)
    if !executor.expire(s,checked_now) do return false,"clock_or_storage_error"
    if _,valid:=executor.intent_current(s,intent,checked_now);!valid do return false,"stale_intent"
    if !bridge_pty_host_executor_capable(socket) do return false,"executor_unsupported"
    admission_now:=clock(clock_ctx)
    if !executor.expire(s,admission_now) do return false,"clock_or_storage_error"
    fresh_remaining,still_current:=executor.intent_current(s,intent,admission_now)
    if !still_current do return false,"stale_intent"
    if intent.kind=="launch" && request.timeout_seconds>u64(fresh_remaining/1000) do return false,"expired_launch"
    first_dispatch:=executor.begin_dispatch(s,intent,admission_now)
    if first_dispatch || intent.kind=="stop" {
        if intent.kind=="stop" {
            _=bridge_pty_host_executor_close(socket,intent.instance,intent.launch_key)
        } else {
            req:=request
            env:=make([][2]string,len(request.env)+2,context.temp_allocator)
            copy(env,request.env);env[len(request.env)]={"HEIMDALL_EXECUTOR_LAUNCH_KEY",intent.launch_key}
            env[len(request.env)+1]={"HEIMDALL_EXECUTOR_DEADLINE_MS",fmt.tprintf("%d",admission_now+fresh_remaining)}
            req.env=env
            _,_=bridge_pty_host_spawn(socket,req)
        }
    }
    // Lost spawn/stop replies are resolved by exact query. Daemon cache loss or
    // an unverified child stays uncertain; it can never silently free a slot.
    pid,known:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    if !known do return false,"executor_uncertain"
    observed:=executor.Child_Observation{intent.instance,intent.launch_key,intent.incarnation,pid>0}
    if !executor.observe_child(s,intent.reservation,observed) do return false,"observation_not_committed"
    return true,("child_present" if pid>0 else "child_absent")
}
