package main

import "core:encoding/json"
import "core:fmt"
import owner "odin_test:lib/owner_local"

// M1 item 2 (origin/main parity: claims by durable agent id and chain
// membership). A restarted agent (Bridge, pty-host or process restart) keeps
// its instance id but gets a new launch epoch, run count and token, while its
// fleet row and lifecycle configuration still name the earlier launch, and
// the owner store fences leases on the exact launch. On lease next the owner
// Bridge rebinds such a task to the caller with the commands a coordinator
// would run itself: lease.revoke when the earlier launch still holds a lease
// (it can never heartbeat again), then task update --assignee <agent> (fleet
// edit + lifecycle configure to the live launch, existing reviewer kept).
// They are signed for the chain's bound coordinator, whose authority is its
// instance and agent id, so it need not be running. Caller holds the owner
// and child locks (bridge_owner_agent_exec). A refusal leaves the task as it
// was; the next lease next tries again. Returns the rebound task ids.
bridge_owner_reclaim_restarted :: proc(ctx:^Owner_Agent_Ctx) -> []string {
    bindings,ok:=owner.agent_restarted_bindings(ctx.store,ctx.child)
    reclaimed:=make([dynamic]string,context.temp_allocator)
    if !ok do return reclaimed[:]
    for b in bindings {
        coordinator,found:=owner.chain_coordinator_child(ctx.store,b.chain_id)
        if !found do continue
        cctx:=Owner_Agent_Ctx{request_id=bridge_owner_fresh_id("req"),store=ctx.store,child=coordinator,key=ctx.key,kr=ctx.kr,now=ctx.now}
        if b.leased {
            revoke:=bridge_owner_params(fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","reason":"the holder restarted; its new launch reclaims the task"}}`,b.chain_id,b.task_id))
            if out:=bridge_owner_result_object(bridge_owner_agent_exec(&cctx,"agent.lease.revoke",revoke));!bridge_owner_reclaim_ok(out) {
                fmt.eprintfln("owner reclaim: revoking %s's earlier lease on %s refused: %v",ctx.child.instance,b.task_id,out["error"])
                continue
            }
        }
        update:=bridge_owner_params(fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","assignee":"%s"}}`,b.chain_id,b.task_id,ctx.child.agent_id))
        if out:=bridge_owner_result_object(bridge_owner_agent_exec(&cctx,"agent.task.update",update));!bridge_owner_reclaim_ok(out) {
            fmt.eprintfln("owner reclaim: rebinding %s to %s's new launch refused: %v",b.task_id,ctx.child.instance,out["error"])
            continue
        }
        append(&reclaimed,b.task_id)
    }
    return reclaimed[:]
}

bridge_owner_reclaim_ok :: proc(out:json.Object) -> bool {
    ok,is_bool:=out["ok"].(json.Boolean)
    return is_bool && bool(ok)
}
