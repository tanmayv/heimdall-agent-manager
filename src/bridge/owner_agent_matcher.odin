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
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

BRIDGE_OWNER_MATCH_RETRY_MS :: 5*60*1000

// task|instance|action -> last planned (ms), so periodic runs back off.
bridge_owner_match_seen:map[string]i64
bridge_owner_match_seen_mutex:sync.Mutex
bridge_owner_match_booted:bool

// Whether a periodic (unforced) run may act on key now; records the attempt.
bridge_owner_match_due :: proc(key:string,now:i64,force:bool) -> bool {
    sync.mutex_lock(&bridge_owner_match_seen_mutex);defer sync.mutex_unlock(&bridge_owner_match_seen_mutex)
    context.allocator=runtime.heap_allocator()
    if bridge_owner_match_seen==nil do bridge_owner_match_seen=make(map[string]i64)
    if last,seen:=bridge_owner_match_seen[key];seen {
        if !force && now-last<BRIDGE_OWNER_MATCH_RETRY_MS do return false
        bridge_owner_match_seen[key]=now
        return true
    }
    bridge_owner_match_seen[strings.clone(key)]=now
    return true
}

// Under the owner, startup and token locks: one dispatch per chain with a
// worker to wake or start. chain "" plans every chain.
bridge_owner_match_plan :: proc(s:^owner.Store,chain:string,force:bool,now:i64) -> [dynamic]Owner_Review_Dispatch {
    out:=make([dynamic]Owner_Review_Dispatch,context.temp_allocator)
    targets,ok:=owner.work_targets(s,chain)
    if !ok do return out
    for target in targets {
        d:^Owner_Review_Dispatch
        for &existing in out do if len(existing.wakes)>0 && existing.wakes[0].chain==target.chain_id do d=&existing
        if d==nil {
            append(&out,Owner_Review_Dispatch{wakes=make([dynamic]Owner_Review_Wake,context.temp_allocator)})
            d=&out[len(out)-1]
            d.coordinator=owner.chain_coordinator_instance(s,target.chain_id)
            if d.coordinator!="" {
                if rec,has:=bridge_owner_review_token_locked(d.coordinator);has do d.rec=rec
            }
        }
        wake:=Owner_Review_Wake{action=.Start,chain=target.chain_id,task=target.task_id,agent=target.agent_id,instance=target.instance_id,worker=true}
        if child,live:=bridge_owner_live_child(target.instance_id);live && child.agent_id==target.agent_id do wake.action=.Nudge
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
bridge_owner_match_run :: proc(chain:string,force:bool) {
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
        plans=bridge_owner_match_plan(&bridge_owner_store,chain,force,time.to_unix_nanoseconds(time.now())/1000000)
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
