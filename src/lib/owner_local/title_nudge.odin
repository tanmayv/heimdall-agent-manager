package owner_local

import "core:fmt"

// Owner-chain set-title nudge: the Bridge-held port of the Hub engine on
// origin/main (src/hub/service/content/title_nudge.odin), which this branch
// no longer runs because chains are Bridge-owned.
//
// A New conversation's chain starts with the run's default '<agent-name> #<n>'
// title (title_source 'default'). Once an agent of the chain has real
// activity, the chain's COORDINATOR (never a worker or reviewer) is asked to
// set a human-meaningful title. Re-nudges are gated exactly as on main:
//   - title_source must still be 'default' (an agent or user title stops us);
//   - there must be new activity since the last nudge;
//   - at least the cooldown (1 h) must have passed since the last nudge.
// A nudge is stamped only once it was handed to a LIVE coordinator, so a
// nudge dropped while the coordinator is still launching is retried on the
// next activity instead of arming the cooldown.

TITLE_NUDGE_COOLDOWN_SECONDS :: 3600

// Same notice as origin/main's TITLE_NUDGE_MESSAGE.
TITLE_NUDGE_MESSAGE :: "Please set a short, human-meaningful title for this task chain: ham-ctl task-chain set-title \"<title>\""

Title_Nudge_Decision :: struct {
    should_nudge: bool,
    reason:       string, // "" when should_nudge, else why it was skipped
}

// Pure and clock-injected, as evaluate_title_nudge on main.
title_nudge_evaluate :: proc(title_source:string, has_activity:bool, last_activity_ms,last_nudge_ms,now_ms:i64, cooldown_seconds:int) -> Title_Nudge_Decision {
    if title_source!="default" do return {false,"non_default_title"}
    if !has_activity do return {false,"no_activity"}
    if last_nudge_ms<=0 do return {true,""}
    if last_activity_ms<=last_nudge_ms do return {false,"no_new_activity"}
    cooldown:=cooldown_seconds
    if cooldown<=0 do cooldown=TITLE_NUDGE_COOLDOWN_SECONDS
    if now_ms-last_nudge_ms<i64(cooldown)*1000 do return {false,"cooldown"}
    return {true,""}
}

// Records the source of the chain's current title: 'default' at a New
// conversation create, 'agent' for task-chain set-title, 'user' for a device
// rename. Activity and nudge stamps are kept.
chain_title_source_set :: proc(s:^Store,chain,source:string) -> bool {
    _,ok:=query(s.db,"INSERT INTO local_chain_title_state(chain_id,title_source) VALUES(?,?) ON CONFLICT(chain_id) DO UPDATE SET title_source=excluded.title_source",chain,source)
    return ok
}

// The chain's title state; found=false when the chain was titled explicitly
// at create (no row), which is never nudged.
chain_title_state :: proc(s:^Store,chain:string) -> (source:string,last_activity_ms,last_nudge_ms:i64,found,ok:bool) {
    rows,read:=query(s.db,"SELECT title_source,last_activity_ms,last_title_nudge_ms FROM local_chain_title_state WHERE chain_id=?",chain)
    if !read do return
    ok=true
    if len(rows)!=1 do return
    return rows[0][0],number(rows[0][1]),number(rows[0][2]),true,true
}

// The nudge due for `instance`'s chain after activity at now_ms: stamps the
// chain's activity, then evaluates the gate. Returns the chain and its
// coordinator instance when a nudge should be delivered (the caller delivers
// and, only on delivery, calls chain_title_nudge_stamp). A worker's or
// reviewer's activity counts for its chain; the coordinator is the target.
chain_title_activity :: proc(s:^Store,instance:string,now_ms:i64,cooldown_seconds:int=TITLE_NUDGE_COOLDOWN_SECONDS) -> (chain,coordinator:string,decision:Title_Nudge_Decision) {
    bound,read:=query(s.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=?",instance)
    if !read || len(bound)!=1 do return "","",{false,"no_chain"}
    chain=bound[0][0]
    if _,ok:=query(s.db,"UPDATE local_chain_title_state SET last_activity_ms=max(last_activity_ms,?) WHERE chain_id=?",fmt.tprintf("%d",now_ms),chain);!ok do return chain,"",{false,"storage_error"}
    source,activity,nudged,found,ok:=chain_title_state(s,chain)
    if !ok do return chain,"",{false,"storage_error"}
    if !found do return chain,"",{false,"non_default_title"}
    decision=title_nudge_evaluate(source,activity>0,activity,nudged,now_ms,cooldown_seconds)
    if !decision.should_nudge do return
    coordinator=chain_coordinator_instance(s,chain)
    if coordinator=="" do return chain,"",{false,"no_coordinator"}
    return
}

// Stamps a nudge handed to the live coordinator.
chain_title_nudge_stamp :: proc(s:^Store,chain:string,now_ms:i64) -> bool {
    _,ok:=query(s.db,"UPDATE local_chain_title_state SET last_title_nudge_ms=? WHERE chain_id=?",fmt.tprintf("%d",now_ms),chain)
    return ok
}
