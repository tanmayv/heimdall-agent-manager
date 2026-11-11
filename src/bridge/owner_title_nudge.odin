package main

// Owner-chain set-title nudge (the Bridge side of owner title_nudge.odin).
//
// origin/main runs this on the Hub; on this branch chains are Bridge-owned, so
// the owner Bridge tracks the activity of its chains' agents and asks the
// chain's coordinator to set a title while it still has the run's default
// '<agent-name> #<n>' one. Activity is a message delivered to an agent of the
// chain (notify_agent_message) or sent by one (agent.chat.send), in any
// direction, as on main. The nudge reuses the notify_title_nudge notice and
// delivery path; it is stamped only when a LIVE coordinator received it.
//
// Lock order: the gate runs under bridge_owner_mutex only; delivery takes the
// executor/startup locks with the owner mutex released.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// Tests substitute the delivery (no PTY host) and run synchronously.
bridge_owner_title_nudge_deliver_effect: proc(instance, notice: string) -> bool
bridge_owner_title_nudge_sync: bool

bridge_owner_title_nudge_notice :: proc() -> string {
    return fmt.tprintf("Nudge: %s",owner.TITLE_NUDGE_MESSAGE)
}

// Same path as the notify_title_nudge runtime command: a Notice to the live
// wrapper. false when the coordinator is not running yet (still launching).
bridge_owner_title_nudge_deliver :: proc(instance, notice: string) -> bool {
    if bridge_owner_title_nudge_deliver_effect!=nil do return bridge_owner_title_nudge_deliver_effect(instance,notice)
    socket,ok:=bridge_pty_host_ensure_daemon()
    if !ok do return false
    delivered,_:=bridge_legacy_agent_delivery({kind=.Notice,instance=instance,text=notice},injected_socket=socket)
    return delivered
}

// Activity by (or for) `instance`: off the caller's thread unless a test asks.
bridge_owner_title_activity :: proc(instance: string) {
    if instance=="" do return
    if bridge_owner_title_nudge_sync { bridge_owner_title_activity_run(instance);return }
    Job :: struct { instance: string }
    job:=new(Job,runtime.heap_allocator())
    job.instance=strings.clone(instance,runtime.heap_allocator())
    thread.run_with_poly_data(job,proc(j:^Job) {
        bridge_owner_title_activity_run(j.instance)
        delete(j.instance,runtime.heap_allocator())
        free(j,runtime.heap_allocator())
        free_all(context.temp_allocator)
    })
}

// Stamps the activity of the instance's chain and, when the gate fires,
// delivers the nudge to the chain's coordinator. Returns whether a nudge was
// delivered (and stamped).
bridge_owner_title_activity_run :: proc(instance: string) -> bool {
    context.allocator=context.temp_allocator
    chain,coordinator:string
    {
        sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
        if !bridge_owner_title_store_locked() do return false
        decision:owner.Title_Nudge_Decision
        chain,coordinator,decision=owner.chain_title_activity(&bridge_owner_store,instance,time.to_unix_nanoseconds(time.now())/1000000)
        if !decision.should_nudge do return false
        chain=strings.clone(chain);coordinator=strings.clone(coordinator)
    }
    if !bridge_owner_title_nudge_deliver(coordinator,bridge_owner_title_nudge_notice()) {
        // Not live yet: unstamped, so the next activity retries.
        fmt.println("bridge owner title nudge pending (coordinator not live)",chain,coordinator)
        return false
    }
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_title_store_locked() do return false
    return owner.chain_title_nudge_stamp(&bridge_owner_store,chain,time.to_unix_nanoseconds(time.now())/1000000)
}

// Opens the existing owner store; never creates one just for activity.
// Caller holds bridge_owner_mutex.
bridge_owner_title_store_locked :: proc() -> bool {
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    if account=="" do return false
    key_id,key_ok:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_config.daemon_id),context.temp_allocator)
    if !key_ok do return false
    if bridge_owner_store.db==nil {
        path:=bridge_owner_store_path(account)
        if path=="" || !os.exists(path) do return false
    }
    return bridge_owner_open(account,key_id)
}
