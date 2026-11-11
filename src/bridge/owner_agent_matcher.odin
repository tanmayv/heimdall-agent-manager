#+feature dynamic-literals
package main

// M1 owner-chain matcher (origin/main Hub taskv2 matcher.odin pick_instance,
// ported to the owner Bridge). A coordinator only configures the fleet and the
// tasks; this Bridge brings their workers to them.
//
// For every ready, unleased task assigned to a worker member on this Bridge
// (owner.work_targets) the matcher wakes the member when it is live (the
// [taskv2] line asks it to run `lease next`), and restarts it through the Hub
// when it stopped (the coordinator's credential, as `ham-ctl agents start`).
// A restarted launch reclaims its task by agent id on `lease next`
// (bridge_owner_reclaim_restarted). A member that cannot be started blocks the
// task waiting on agent_not_running (bridge_owner_block_not_running), as the
// Hub's dispatch does. Coordinators are never candidates: a solo task is
// pulled by the coordinator itself.
//
// It runs after every owner verb that changes a chain or task (create,
// update, handoff, block, unblock, fleet changes), after lease expiry, and on
// Bridge start (the first maintenance pass). Event runs are forced; the
// periodic run acts on a task at most once per BRIDGE_OWNER_MATCH_RETRY_MS so
// a live member is not nudged every 30 seconds.
//
// The plan is made under the owner, startup and token locks; the wakes and
// starts run after every lock is released (bridge_owner_review_dispatch).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

BRIDGE_OWNER_MATCH_RETRY_MS :: 5*60*1000

BRIDGE_OWNER_MATCH_SEEN_CAP :: 4096

// task|instance|action -> last planned (ms), so periodic runs back off.
// Entries older than BRIDGE_OWNER_MATCH_RETRY_MS no longer gate anything and
// are pruned; the map never holds more than BRIDGE_OWNER_MATCH_SEEN_CAP keys.
bridge_owner_match_seen:map[string]i64
bridge_owner_match_seen_mutex:sync.Mutex
bridge_owner_match_booted:bool

// Drops expired keys, then (still over the cap) every key. Caller holds
// bridge_owner_match_seen_mutex.
bridge_owner_match_seen_prune_locked :: proc(now:i64) {
    expired:=make([dynamic]string,context.temp_allocator)
    for key,last in bridge_owner_match_seen do if now-last>=BRIDGE_OWNER_MATCH_RETRY_MS do append(&expired,key)
    for key in expired {
        stored,_:=delete_key(&bridge_owner_match_seen,key)
        delete(stored,runtime.heap_allocator())
    }
    if len(bridge_owner_match_seen)<BRIDGE_OWNER_MATCH_SEEN_CAP do return
    for key in bridge_owner_match_seen do delete(key,runtime.heap_allocator())
    clear(&bridge_owner_match_seen)
}

// Whether a periodic (unforced) run may act on key now; records the attempt.
bridge_owner_match_due :: proc(key:string,now:i64,force:bool) -> bool {
    sync.mutex_lock(&bridge_owner_match_seen_mutex);defer sync.mutex_unlock(&bridge_owner_match_seen_mutex)
    if bridge_owner_match_seen==nil do bridge_owner_match_seen=make(map[string]i64,runtime.heap_allocator())
    if last,seen:=bridge_owner_match_seen[key];seen {
        if !force && now-last<BRIDGE_OWNER_MATCH_RETRY_MS do return false
        bridge_owner_match_seen[key]=now
        return true
    }
    bridge_owner_match_seen_prune_locked(now)
    bridge_owner_match_seen[strings.clone(key,runtime.heap_allocator())]=now
    return true
}

// The dispatch of a chain in out, created with the coordinator's Hub
// credential (starts and launches use it) on first use.
bridge_owner_match_dispatch :: proc(s:^owner.Store,out:^[dynamic]Owner_Review_Dispatch,chain:string) -> ^Owner_Review_Dispatch {
    for &existing in out do if len(existing.wakes)>0 && existing.wakes[0].chain==chain do return &existing
    append(out,Owner_Review_Dispatch{wakes=make([dynamic]Owner_Review_Wake,context.temp_allocator)})
    d:=&out[len(out)-1]
    d.coordinator=owner.chain_coordinator_instance(s,chain)
    if d.coordinator!="" {
        if rec,has:=bridge_owner_review_token_locked(d.coordinator);has do d.rec=rec
    }
    return d
}

// Unassigned work (origin/main grant_work + pick_instance): each ready task
// with no worker gets a fleet agent of its chain, never the coordinator's,
// from an active row placed on this Bridge: a live, lease-free member is
// assigned at once (task update --assignee, signed for the chain's bound
// coordinator); else a stopped member is started, else (the agent has no
// member yet) a member is launched into the chain, and the matcher runs again
// once it is live. Caller holds the owner, startup and token locks; ctx
// carries the store, owner key, keyring and clock.
bridge_owner_match_assign :: proc(ctx:^Owner_Agent_Ctx,out:^[dynamic]Owner_Review_Dispatch,chain:string,force:bool) {
    tasks,ok:=owner.unassigned_tasks(ctx.store,chain)
    if !ok do return
    busy:=make(map[string]bool,context.temp_allocator) // instances assigned in this run
    pending:=make(map[string]bool,context.temp_allocator) // agents started/launched in this run
    for task in tasks {
        coordinator,bound:=owner.chain_coordinator_child(ctx.store,task.chain_id)
        if !bound do continue
        // Assigned to an agent placed on another Bridge whose placement did
        // not land (gap 4): placed there again, never given to a local agent.
        if agent,remote:=bridge_owner_match_remote_assignee(ctx.store,task.chain_id,task.task_id);agent!="" {
            if remote && agent!=coordinator.agent_id && !pending[agent] {
                bridge_owner_match_queue_place(ctx,out,task.chain_id,task.task_id,agent)
                pending[agent]=true
                continue
            }
            if remote do continue
        }
        policies,members,read:=owner.agent_fleet_view(ctx.store,task.chain_id)
        if !read do continue
        assigned:=false
        stopped,missing:owner.Agent_Fleet_Member
        launch_policy:contracts.Owner_Fleet_Policy
        run_bridge,pinned:=bridge_owner_match_run_bridge(ctx.store,task.chain_id,task.task_id)
        remote_agent:string
        for policy in policies {
            if policy.agent_id==coordinator.agent_id || len(bridge_owner_fleet_active_roles(policy))==0 do continue
            // Runs on another Bridge (the task's pin, else the row's): the
            // first such agent is placed there (origin/main pick_instance on
            // the pinned Bridge); never a local member.
            if pinned || (policy.bridge_id!="" && policy.bridge_id!=ctx.store.owner) {
                if remote_agent=="" && !pending[policy.agent_id] {
                    if _,code,_:=bridge_owner_remote_target(ctx.store,task.chain_id,policy.agent_id,run_bridge,pinned);code=="ok" do remote_agent=policy.agent_id
                }
                continue
            }
            has_member:=false
            for m in members {
                if m.agent_id!=policy.agent_id || m.enabled!="1" || m.role=="coordinator" do continue
                has_member=true
                child,live:=bridge_owner_live_child(m.instance_id)
                if !live || child.agent_id!=m.agent_id {
                    if stopped.instance_id=="" do stopped=m
                    continue
                }
                if busy[m.instance_id] do continue
                if leased,lease_ok:=owner.instance_leased(ctx.store,m.instance_id);!lease_ok || leased do continue
                cctx:=Owner_Agent_Ctx{request_id=bridge_owner_fresh_id("req"),store=ctx.store,child=coordinator,key=ctx.key,kr=ctx.kr,now=ctx.now}
                params:=bridge_owner_params(fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","assignee":"%s"}}`,task.chain_id,task.task_id,m.agent_id))
                if result:=bridge_owner_result_object(bridge_owner_agent_exec(&cctx,"agent.task.update",params));!bridge_owner_reclaim_ok(result) {
                    fmt.eprintfln("owner matcher: assigning %s to %s refused: %v",task.task_id,m.agent_id,result["error"])
                    continue
                }
                busy[m.instance_id]=true;assigned=true
                break
            }
            if assigned do break
            if !has_member && missing.agent_id=="" { missing=owner.Agent_Fleet_Member{agent_id=policy.agent_id};launch_policy=policy }
        }
        if assigned do continue
        if pinned || (remote_agent!="" && stopped.instance_id=="" && missing.agent_id=="") {
            if remote_agent=="" do continue
            bridge_owner_match_queue_place(ctx,out,task.chain_id,task.task_id,remote_agent)
            pending[remote_agent]=true
            continue
        }
        wake:Owner_Review_Wake
        switch {
        case stopped.instance_id!="":
            wake=Owner_Review_Wake{action=.Start,chain=task.chain_id,task=task.task_id,agent=stopped.agent_id,instance=stopped.instance_id,worker=true,rematch=true}
        case missing.agent_id!="":
            body:=map[string]string{"agent_id"=missing.agent_id,"chain_id"=task.chain_id,"bridge_id"=bridge_cfg().daemon_id}
            provider,model,profile:=bridge_owner_fleet_launch_model(launch_policy,bridge_cfg().daemon_id)
            if provider!="" do body["provider"]=provider
            if model!="" do body["model"]=model
            if profile!="" do body["provider_profile"]=profile
            wake=Owner_Review_Wake{action=.Launch,chain=task.chain_id,task=task.task_id,agent=missing.agent_id,body=bridge_owner_json(body),worker=true,rematch=true}
        case:
            continue // every fleet worker is busy (capacity reached)
        }
        if pending[wake.agent] do continue
        d:=bridge_owner_match_dispatch(ctx.store,out,task.chain_id)
        if d.rec.instance_token=="" do continue
        action:="start" if wake.action==.Start else "launch"
        if !bridge_owner_match_due(fmt.tprintf("%s|%s|%s",task.chain_id,wake.agent,action),ctx.now,force) do continue
        pending[wake.agent]=true
        append(&d.wakes,wake)
    }
}

// A placement on another Bridge, as the chain coordinator. Never forced: the
// verb that assigned the task just tried it (the route marks this key), so
// event runs do not place it twice within the back-off.
bridge_owner_match_queue_place :: proc(ctx:^Owner_Agent_Ctx,out:^[dynamic]Owner_Review_Dispatch,chain,task,agent:string) {
    d:=bridge_owner_match_dispatch(ctx.store,out,chain)
    if d.rec.instance_token=="" do return
    if !bridge_owner_match_due(bridge_owner_match_place_key(chain,task,agent),ctx.now,false) do return
    append(&d.wakes,Owner_Review_Wake{action=.Place,chain=chain,task=task,agent=agent,worker=true})
}

// Under the owner, startup and token locks: assign unassigned work, then one
// dispatch per chain with a worker to wake, start or launch. chain "" plans
// every chain. fresh is a worker instance that just handed off its own task:
// it is restarted for a fresh context, never nudged (a chain coordinator is
// never restarted: it keeps its conversation).
bridge_owner_match_plan :: proc(ctx:^Owner_Agent_Ctx,chain:string,force:bool,fresh:string="") -> [dynamic]Owner_Review_Dispatch {
    out:=make([dynamic]Owner_Review_Dispatch,context.temp_allocator)
    s,now:=ctx.store,ctx.now
    if ctx.kr!=nil do bridge_owner_match_assign(ctx,&out,chain,force)
    targets,ok:=owner.work_targets(s,chain)
    if !ok do return out
    restarting:=false // fresh is restarted once, whatever it is assigned
    for target in targets {
        // Pinned to another Bridge after it was assigned here (the ticket UI
        // pin is a requirements edit): its worker is placed on the run Bridge
        // (`task update --assignee`, which reserves it there) and the local
        // instance is not woken.
        if run_bridge,pinned:=bridge_owner_match_run_bridge(s,target.chain_id,target.task_id);pinned && run_bridge!="" && run_bridge!=s.owner {
            bridge_owner_match_queue_place(ctx,&out,target.chain_id,target.task_id,target.agent_id)
            continue
        }
        d:=bridge_owner_match_dispatch(s,&out,target.chain_id)
        wake:=Owner_Review_Wake{action=.Start,chain=target.chain_id,task=target.task_id,agent=target.agent_id,instance=target.instance_id,worker=true}
        if child,live:=bridge_owner_live_child(target.instance_id);live && child.agent_id==target.agent_id {
            if fresh!="" && target.instance_id==fresh && fresh!=d.coordinator {
                if restarting || d.rec.instance_token=="" do continue
                restarting=true
                wake.action=.Restart
                append(&d.wakes,wake)
                continue
            }
            // A live worker busy on another lease is not interrupted
            // (pick_instance uses lease-free instances); it pulls this task
            // with `lease next` once it is done.
            if leased,lease_ok:=owner.instance_leased(s,target.instance_id);!lease_ok || leased do continue
            wake.action=.Nudge
        }
        // Starting needs a Hub credential: the coordinator's (it may be
        // stopped too; the next run after it is back retries).
        if wake.action==.Start && d.rec.instance_token=="" do continue
        action:="nudge" if wake.action==.Nudge else "start"
        if !bridge_owner_match_due(fmt.tprintf("%s|%s|%s",target.task_id,target.instance_id,action),now,force) do continue
        append(&d.wakes,wake)
    }
    return out
}

// Takes the owner, startup and token locks; dispatches with none held.
bridge_owner_match_run :: proc(chain:string,force:bool,fresh:string="") {
    context.allocator=context.temp_allocator
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    if account=="" || !key_ok do return
    plans:[dynamic]Owner_Review_Dispatch
    {
        sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
        if !bridge_owner_open(account,key_id) do return
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
        pub:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
        ctx:=Owner_Agent_Ctx{request_id=bridge_owner_fresh_id("match"),store=&bridge_owner_store,
            key=contracts.Owner_Verified_Key{account,bridge_cfg().daemon_id,key_id,pub,"bridge",true,false},
            kr=&kr if unlocked else nil,now=time.to_unix_nanoseconds(time.now())/1000000}
        plans=bridge_owner_match_plan(&ctx,chain,force,fresh)
        if len(plans)>0 do bridge_owner_publish()
    }
    for d in plans do bridge_owner_review_dispatch(d)
}

// Owner verbs after which the matcher runs for the chain (the Hub runs
// match_chain_in_uow on every chain/task change).
bridge_owner_match_method :: proc(method:string) -> bool {
    switch method {
    case "agent.task.create","agent.task.update","agent.task.depend","agent.lease.handoff","agent.lease.block","agent.lease.submit",
         "agent.review.post","agent.task_chain.publish":
        return true
    }
    return bridge_owner_control_method(method)!="" || (bridge_owner_fleet_method(method) && method!="agent.task_chain.fleet_list")
}

// The [taskv2] line typed into a worker whose task is ready.
bridge_owner_work_line :: proc(task:string) -> string {
    return fmt.aprintf("[taskv2] Task %s is ready for you: run `ham-ctl lease next`, then read TASK.md and follow it.",task)
}

// The executor's rematch: the matcher again for a chain whose fleet agent was
// just started or launched (default Owner_Review_Effects.rematch).
bridge_owner_match_rerun :: proc(chain:string) { bridge_owner_match_run(chain,true) }

// Agents a task create/update asked to place on another Bridge, by
// chain|task, until the placement lands (a fleet row exists). In memory: after
// a Bridge restart the fleet loop below places a fleet agent for a task pinned
// to another Bridge instead.
bridge_owner_place_pending:map[string]string
bridge_owner_place_pending_mutex:sync.Mutex

bridge_owner_place_pending_set :: proc(chain,task,agent:string) {
    sync.mutex_lock(&bridge_owner_place_pending_mutex);defer sync.mutex_unlock(&bridge_owner_place_pending_mutex)
    if bridge_owner_place_pending==nil do bridge_owner_place_pending=make(map[string]string,runtime.heap_allocator())
    key:=fmt.tprintf("%s|%s",chain,task)
    if old_key,old:=delete_key(&bridge_owner_place_pending,key);old_key!="" { delete(old_key,runtime.heap_allocator());delete(old,runtime.heap_allocator()) }
    if agent=="" do return
    if len(bridge_owner_place_pending)>=BRIDGE_OWNER_MATCH_SEEN_CAP {
        for k,v in bridge_owner_place_pending { delete(k,runtime.heap_allocator());delete(v,runtime.heap_allocator()) }
        clear(&bridge_owner_place_pending)
    }
    bridge_owner_place_pending[strings.clone(key,runtime.heap_allocator())]=strings.clone(agent,runtime.heap_allocator())
}

bridge_owner_place_pending_get :: proc(chain,task:string) -> string {
    sync.mutex_lock(&bridge_owner_place_pending_mutex);defer sync.mutex_unlock(&bridge_owner_place_pending_mutex)
    return strings.clone(bridge_owner_place_pending[fmt.tprintf("%s|%s",chain,task)],context.temp_allocator)
}

// The agent an unplaced task waits for on another Bridge ("" = none asked):
// remote=false when it no longer places remotely (pin cleared, row moved).
bridge_owner_match_remote_assignee :: proc(s:^owner.Store,chain,task:string) -> (agent:string,remote:bool) {
    agent=bridge_owner_place_pending_get(chain,task)
    if agent=="" do return "",false
    run_bridge,pinned:=bridge_owner_match_run_bridge(s,chain,task)
    _,code,_:=bridge_owner_remote_target(s,chain,agent,run_bridge,pinned)
    return agent,code=="ok"
}

// A task's pinned run Bridge other than this one (pinned=false otherwise).
bridge_owner_match_run_bridge :: proc(s:^owner.Store,chain,task:string) -> (string,bool) {
    st,found,ok:=owner.agent_task_state(s,chain,task)
    if !ok || !found do return "",false
    bridge,_:=bridge_owner_brief_run_bridge(st.brief)
    return bridge,bridge!=""
}

bridge_owner_match_place_key :: proc(chain,task,agent:string) -> string {
    return fmt.tprintf("%s|%s|%s|place",chain,task,agent)
}

// Places a task's assignee on its remote run Bridge again, as the
// coordinator's own `task update --assignee` (owner_agent_routing.odin), with
// no lock held. "" when the route accepted it.
bridge_owner_match_place :: proc(chain,task,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    context.allocator=context.temp_allocator
    params:=bridge_owner_json(map[string]string{"chain_id"=chain,"task_id"=task,"assignee"=agent})
    response,_:=bridge_owner_agent_route(bridge_owner_fresh_id("req"),"agent.task.update",params,rec)
    if bridge_owner_response_ok(response) do return ""
    if e,has:=bridge_owner_result_object(response)["error"].(json.Object);has {
        if message,m:=e["message"].(json.String);m do return string(message)
    }
    return "placement refused"
}
