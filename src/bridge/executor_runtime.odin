#+feature dynamic-literals
package main

import "core:fmt"
import "core:crypto"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// The owner callback must freshly verify the signed authoritative exact fence;
// it must not trust envelope assertions or reuse a historical admission receipt.
Executor_Owner_Check :: proc(ctx:rawptr,intent:executor.Intent)->executor.Current_Owner_Fence
Executor_Now :: proc(ctx:rawptr)->i64

// Callers serialize this physical I/O path with application of executor
// invalidations. No SQLite transaction spans the owner check or daemon request.
bridge_executor_dispatch :: proc(s:^executor.Store,intent:executor.Intent,now:i64,socket:string,
    request:Pty_Host_Spawn_Request,ctx:rawptr,owner_check:Executor_Owner_Check,clock_ctx:rawptr,clock:Executor_Now,final_owner_check:Executor_Owner_Check=nil)->(bool,string) {
    if clock==nil do return false,"clock_required"
    if !executor.expire(s,now) do return false,"clock_or_storage_error"
    _,current:=executor.intent_current(s,intent,now)
    if !current do return false,"stale_intent"
    // After the durable dispatch boundary, retries have no launch authority.
    // Do not require credentials, a reconstructed Spawn, or another owner nonce
    // merely to observe the same exact daemon child.
    if executor.dispatch_started(s,intent,now) {
        return bridge_executor_observe_dispatch(s,intent,socket)
    }
    if intent.kind=="launch" {
        p,valid:=contracts.executor_parse(intent.document,"prepare")
        if !valid || request.instance!=intent.instance || !request.has_timeout_seconds || request.timeout_seconds==0 ||
           owner_check==nil {return false,"invalid_launch"}
        // Only the Bridge's catalog/configuration resolver may supply argv/env.
        // The exact spawn bytes become immutable in the daemon on first I/O.
        for pair in request.env do if pair[0]=="HEIMDALL_EXECUTOR_LAUNCH_KEY" || pair[0]=="HEIMDALL_EXECUTOR_DEADLINE_MS" ||
            pair[0]=="HEIMDALL_EXECUTOR_DEADLINE_VERSION" || pair[0]=="HEIMDALL_EXECUTOR_HARD_MS" || pair[0]=="HEIMDALL_EXECUTOR_RENEW_SECRET" || pair[0]=="HEIMDALL_EXECUTOR_LOCAL_LAUNCH" {return false,"reserved_launch_key"}
        proof:=owner_check(ctx,intent)
        if !executor.expire(s,clock(clock_ctx)) do return false,"clock_or_storage_error"
        digest,_:=contracts.executor_digest("prepare",p)
        if !proof.current || proof.prepare_digest!=digest || proof.owner_incarnation<contracts.executor_number(p,"owner_incarnation") || proof.commit_seq<=0 do return false,"owner_fence_not_current"
    }
    checked_now:=clock(clock_ctx)
    if !executor.expire(s,checked_now) do return false,"clock_or_storage_error"
    if _,valid:=executor.intent_current(s,intent,checked_now);!valid do return false,"stale_intent"
    if !bridge_pty_host_executor_capable(socket) do return false,"executor_unsupported"
    if intent.kind=="launch" && final_owner_check!=nil {
        proof:=final_owner_check(ctx,intent)
        p,_:=contracts.executor_parse(intent.document,"prepare")
        digest,_:=contracts.executor_digest("prepare",p)
        if !proof.current || proof.prepare_digest!=digest || proof.owner_incarnation<contracts.executor_number(p,"owner_incarnation") || proof.commit_seq<=0 do return false,"owner_fence_not_current"
    }
    admission_now:=clock(clock_ctx)
    if !executor.expire(s,admission_now) do return false,"clock_or_storage_error"
    fresh_remaining,still_current:=executor.intent_current(s,intent,admission_now)
    if !still_current do return false,"stale_intent"
    if intent.kind=="launch" && request.timeout_seconds>u64(fresh_remaining/1000) do return false,"expired_launch"
    secret:=""
    if intent.kind=="launch" {
        ready:bool
        secret,ready=executor.launch_control(s,intent,admission_now)
        if !ready do return false,"control_not_committed"
    }
    defer {if secret!="" do crypto.zero_explicit(raw_data(secret),len(secret))}
    first_dispatch:=executor.begin_dispatch(s,intent,admission_now)
    if first_dispatch && intent.kind=="launch" && final_owner_check!=nil {
        // A slow durable dispatch commit must not outlive the signed nonce.
        // Failure after this boundary stays query-only; never restore launch.
        proof:=final_owner_check(ctx,intent)
        if !proof.current do return false,"owner_fence_not_current"
        admission_now=clock(clock_ctx)
        if !executor.expire(s,admission_now) do return false,"clock_or_storage_error"
        remaining,current:=executor.intent_current(s,intent,admission_now)
        if !current || remaining<1000 do return false,"stale_intent"
        fresh_remaining=remaining
    }
    if first_dispatch || intent.kind=="stop" {
        if intent.kind=="stop" {
            _=bridge_pty_host_executor_close(socket,intent.instance,intent.launch_key)
        } else {
            req:=request
            if final_owner_check!=nil do req.timeout_seconds=min(req.timeout_seconds,u64(fresh_remaining/1000))
            env:=make([][2]string,len(request.env)+5,context.temp_allocator)
            copy(env,request.env);env[len(request.env)]={"HEIMDALL_EXECUTOR_LAUNCH_KEY",intent.launch_key}
            env[len(request.env)+1]={"HEIMDALL_EXECUTOR_DEADLINE_MS",fmt.tprintf("%d",admission_now+fresh_remaining)}
            p,_:=contracts.executor_parse(intent.document,"prepare")
            env[len(request.env)+2]={"HEIMDALL_EXECUTOR_DEADLINE_VERSION","1"}
            env[len(request.env)+3]={"HEIMDALL_EXECUTOR_HARD_MS",contracts.owner_string(p,"hard_ms")}
            env[len(request.env)+4]={"HEIMDALL_EXECUTOR_RENEW_SECRET",secret}
            req.env=env
            _,_=bridge_pty_host_spawn(socket,req)
        }
    }
    // Lost spawn/stop replies are resolved by exact query. Daemon cache loss or
    // an unverified child stays uncertain; it can never silently free a slot.
    return bridge_executor_observe_dispatch(s,intent,socket)
}

bridge_executor_observe_dispatch :: proc(s:^executor.Store,intent:executor.Intent,socket:string)->(bool,string) {
    pid,known:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    if !known do return false,"executor_uncertain"
    observed:=executor.Child_Observation{intent.instance,intent.launch_key,intent.incarnation,pid>0}
    if !executor.observe_child(s,intent.reservation,observed) do return false,"observation_not_committed"
    return true,("child_present" if pid>0 else "child_absent")
}
