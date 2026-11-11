package main

// Owner-chain coordinator notices (origin/main taskv2 effect_notify_coordinator).
//
// origin/main's Hub task engine wakes a chain's coordinator with one-line
// [taskv2] notices so it can relay to the user and act. On this branch chains
// are Bridge-owned, so the owner Bridge does it: every
// BRIDGE_OWNER_NOTICE_POLL it reads the current conditions
// (owner.coordinator_notice_candidates), decides which are due and delivers
// each line to the chain's coordinator as a Notice to its live wrapper (the
// title-nudge path), which wakes an idle coordinator.
//
// Dedupe and rate limits, as on main:
//   - blocked_on human: once when the task blocks, then a "still waiting"
//     re-alert every BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS (main 24 h);
//   - agent_not_running, review_requested_from_user: once per block reason /
//     review attempt;
//   - hold_stale: only once the hold is BRIDGE_OWNER_NOTICE_HOLD_STALE_MS old
//     (from its task.hold receipt) and no live holder is checkpointing, then at
//     most once per that interval (main HOLD_STALE_SECONDS, 30 min).
// A notice counts as sent only once a LIVE coordinator received it; an
// undelivered one (first send or repeat) is retried after
// BRIDGE_OWNER_NOTICE_RETRY_MS. A condition that clears is forgotten, so
// blocking again notifies again. The state is in memory: after a Bridge
// restart each outstanding condition is notified once more.
//
// Lock order: candidates are read under bridge_owner_mutex only; title
// decryption and delivery run with it released.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import owner "odin_test:lib/owner_local"

BRIDGE_OWNER_NOTICE_POLL :: 5 * time.Second
BRIDGE_OWNER_NOTICE_RETRY_MS :: i64(30 * 1000)
BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS :: i64(24 * 60 * 60 * 1000)
BRIDGE_OWNER_NOTICE_HOLD_STALE_MS :: i64(30 * 60 * 1000)

Owner_Notice_Seen :: struct {
    first_seen_ms,last_sent_ms,last_try_ms: i64,
}

// Keys and the map live on the heap (runtime.heap_allocator()).
Owner_Notice_State :: struct {
    mutex: sync.Mutex,
    seen: map[string]Owner_Notice_Seen,
}

// A due notice: the candidate (title still as stored) and how to word it.
Owner_Notice :: struct {
    key: string,
    candidate: owner.Coordinator_Notice_Candidate,
    realert: bool,
    held_ms: i64,
}

bridge_owner_notice_state: Owner_Notice_State

// Tests substitute the delivery (no PTY host).
@(thread_local)
bridge_owner_notice_deliver_effect: proc(instance, line: string) -> bool

bridge_owner_notice_key :: proc(c: owner.Coordinator_Notice_Candidate, allocator := context.allocator) -> string {
    return strings.join({c.coordinator,c.chain_id,c.task_id,c.trigger,c.attempt,c.reason},"\x1f",allocator)
}

// bridge_owner_notice_line renders main's wording for a candidate.
bridge_owner_notice_line :: proc(c: owner.Coordinator_Notice_Candidate, realert: bool, held_ms: i64, allocator := context.allocator) -> string {
    switch c.trigger {
    case "blocked_on human":
        if realert do return fmt.aprintf("[taskv2] blocked_on human: task %s (%s) still waiting on human input",c.task_id,c.title,allocator=allocator)
        return fmt.aprintf("[taskv2] blocked_on human: task %s (%s) is waiting on human input",c.task_id,c.title,allocator=allocator)
    case "agent_not_running":
        return fmt.aprintf("[taskv2] agent_not_running: task %s (%s): %s",c.task_id,c.title,c.reason,allocator=allocator)
    case "review_requested_from_user":
        return fmt.aprintf("[taskv2] review_requested_from_user: task %s (%s) is in_review and awaits user approval",c.task_id,c.title,allocator=allocator)
    case "hold_stale":
        return fmt.aprintf("[taskv2] hold_stale: task %s (%s) held for %d min (reason: %s); release it with `task release %s` once the reason is resolved",c.task_id,c.title,held_ms/60000,c.reason,c.task_id,allocator=allocator)
    }
    return ""
}

// bridge_owner_notices_due returns the notices to deliver now (allocated in
// context.allocator; candidates are referenced, not copied) and forgets conditions that are no longer present. Each
// returned notice is marked tried; call bridge_owner_notice_sent once it was
// delivered.
bridge_owner_notices_due :: proc(st: ^Owner_Notice_State, candidates: []owner.Coordinator_Notice_Candidate, now_ms: i64) -> []Owner_Notice {
    sync.mutex_lock(&st.mutex);defer sync.mutex_unlock(&st.mutex)
    heap:=runtime.heap_allocator()
    if st.seen==nil do st.seen=make(map[string]Owner_Notice_Seen,allocator=heap)
    out:=make([dynamic]Owner_Notice)
    present:=make(map[string]bool,allocator=context.temp_allocator)
    for c in candidates {
        // No bound coordinator: nobody to tell (main returns as well).
        if c.coordinator=="" do continue
        key:=bridge_owner_notice_key(c,context.temp_allocator)
        present[key]=true
        seen,known:=st.seen[key]
        if !known {
            seen={first_seen_ms=now_ms}
            st.seen[strings.clone(key,heap)]=seen
        }
        // The last attempt was not delivered (first send, re-alert or repeat
        // reminder alike): retry only after BRIDGE_OWNER_NOTICE_RETRY_MS.
        if seen.last_try_ms>seen.last_sent_ms && now_ms-seen.last_try_ms<BRIDGE_OWNER_NOTICE_RETRY_MS do continue
        due,realert:=false,false
        held_ms:=i64(0)
        switch c.trigger {
        case "blocked_on human":
            due=seen.last_sent_ms==0 || now_ms-seen.last_sent_ms>=BRIDGE_OWNER_NOTICE_BLOCKED_REALERT_MS
            realert=seen.last_sent_ms!=0
        case "agent_not_running","review_requested_from_user":
            due=seen.last_sent_ms==0
        case "hold_stale":
            since:=c.since_ms if c.since_ms>0 else seen.first_seen_ms
            held_ms=now_ms-since
            due=held_ms>=BRIDGE_OWNER_NOTICE_HOLD_STALE_MS &&
                (seen.last_sent_ms==0 || now_ms-seen.last_sent_ms>=BRIDGE_OWNER_NOTICE_HOLD_STALE_MS)
        }
        if !due do continue
        seen.last_try_ms=now_ms
        st.seen[key]=seen
        append(&out,Owner_Notice{key=strings.clone(key),candidate=c,realert=realert,held_ms=held_ms})
    }
    gone:=make([dynamic]string,context.temp_allocator)
    for key in st.seen do if !present[key] do append(&gone,key)
    for key in gone {
        delete_key(&st.seen,key)
        delete(key,heap)
    }
    return out[:]
}

bridge_owner_notice_sent :: proc(st: ^Owner_Notice_State, key: string, now_ms: i64) {
    sync.mutex_lock(&st.mutex);defer sync.mutex_unlock(&st.mutex)
    if seen,ok:=&st.seen[key];ok do seen.last_sent_ms=now_ms
}

// Same path as the title nudge: a Notice to the coordinator's live wrapper.
bridge_owner_notice_deliver :: proc(instance, line: string) -> bool {
    if bridge_owner_notice_deliver_effect!=nil do return bridge_owner_notice_deliver_effect(instance,line)
    return bridge_owner_title_nudge_deliver(instance,line)
}

// bridge_owner_notice_deliver_due delivers the notices and stamps each one a
// live coordinator received. Returns how many were delivered.
bridge_owner_notice_deliver_due :: proc(st: ^Owner_Notice_State, notices: []Owner_Notice, now_ms: i64) -> int {
    delivered:=0
    for n in notices {
        c:=n.candidate
        // Owner task titles are stored as vault tokens; locked reads as a marker.
        c.title=bridge_taskv2_decrypt_field(c.title,context.temp_allocator)
        line:=bridge_owner_notice_line(c,n.realert,n.held_ms,context.temp_allocator)
        if line=="" do continue
        if !bridge_owner_notice_deliver(c.coordinator,line) {
            fmt.println("bridge owner coordinator notice pending (coordinator not live)",c.chain_id,c.coordinator,c.trigger,c.task_id)
            continue
        }
        bridge_owner_notice_sent(st,n.key,now_ms)
        delivered+=1
    }
    return delivered
}

// One pass over the owner store. Never creates a store.
bridge_owner_notice_once :: proc(st: ^Owner_Notice_State) -> int {
    context.allocator=context.temp_allocator
    now:=time.to_unix_nanoseconds(time.now())/1000000
    notices:[]Owner_Notice
    {
        sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
        if !bridge_owner_title_store_locked() do return 0
        candidates,ok:=owner.coordinator_notice_candidates(&bridge_owner_store)
        if !ok do return 0
        notices=bridge_owner_notices_due(st,candidates,now)
    }
    return bridge_owner_notice_deliver_due(st,notices,now)
}

bridge_owner_notice_worker :: proc() {
    for {
        if sync.atomic_load(&bridge_hub_traffic_stopped) do return
        _=bridge_owner_notice_once(&bridge_owner_notice_state)
        free_all(context.temp_allocator)
        time.sleep(BRIDGE_OWNER_NOTICE_POLL)
    }
}

bridge_owner_notice_start :: proc() { bridge_thread_run(bridge_owner_notice_worker) }
