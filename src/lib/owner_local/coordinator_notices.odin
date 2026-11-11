package owner_local

// Owner-chain coordinator notices (origin/main taskv2 effect_notify_coordinator):
// the task states the chain's coordinator is told about so it can relay to the
// user and act. This lists the CURRENT conditions only; the owner Bridge
// (bridge/owner_coordinator_notice.odin) dedupes them, rate-limits the
// repeating ones and delivers the [taskv2] line to the coordinator.
//
//   blocked_on human     blocked on the user/human (lease.block, task.escalate)
//   agent_not_running    blocked because the task's agent could not run
//   review_requested_from_user  in review, user approval required and not given,
//                        and no agent review still owed (the user is the last gate)
//   hold_stale           held (task.hold); the Bridge alerts only once it is old
//
// Owner chains keep no attempt budget or review-round limit, so main's
// budget_exhausted and oscillation have no owner-chain state to report.
Coordinator_Notice_Candidate :: struct {
    chain_id,task_id,coordinator,trigger,title,reason,attempt:string,
    // hold_stale: when the hold was accepted (its task.hold receipt), 0 when
    // unknown (an imported hold); the Bridge then counts from first seen.
    since_ms:i64,
}

coordinator_notice_candidates :: proc(s:^Store) -> ([]Coordinator_Notice_Candidate,bool) {
    out:=make([dynamic]Coordinator_Notice_Candidate,context.temp_allocator)
    if s==nil || s.db==nil do return out[:],true
    coordinators:=make(map[string]string,context.temp_allocator)
    coordinator_of :: proc(s:^Store,m:^map[string]string,chain:string) -> string {
        if c,seen:=m[chain];seen do return c
        c:=chain_coordinator_instance(s,chain)
        m[chain]=c
        return c
    }
    // A held task whose live holder was asked to checkpoint is not stale yet
    // (main fire_hold_stale: no live lease); its handoff or expiry ends that.
    controls,ok:=query(s.db,`SELECT c.chain_id,c.task_id,c.mode,c.waiting_on,c.reason,t.title,COALESCE(l.attempt,'0'),
      (SELECT COALESCE(max(r.created_ms),0) FROM command_receipts r WHERE r.chain_id=c.chain_id AND r.task_id=c.task_id AND r.method='task.hold'),
      EXISTS(SELECT 1 FROM local_leases x WHERE x.chain_id=c.chain_id AND x.task_id=c.task_id AND x.retired_seq IS NULL)
      FROM local_controls c JOIN tasks t ON t.chain_id=c.chain_id AND t.task_id=c.task_id
      LEFT JOIN lifecycle_state l ON l.chain_id=c.chain_id AND l.task_id=c.task_id
      WHERE (c.mode='blocked' AND c.waiting_on IN ('user','human','agent_not_running')) OR c.mode='held'
      ORDER BY c.chain_id,c.task_id LIMIT ?`,"200")
    if !ok do return nil,false
    for r in controls {
        if r[2]=="held" && r[8]=="1" do continue
        trigger:="hold_stale" if r[2]=="held" else ("agent_not_running" if r[3]=="agent_not_running" else "blocked_on human")
        append(&out,Coordinator_Notice_Candidate{r[0],r[1],coordinator_of(s,&coordinators,r[0]),trigger,r[5],r[4],r[6],i64(number(r[7])) if r[2]=="held" else 0})
    }
    reviews,read:=query(s.db,`SELECT l.chain_id,l.task_id,l.attempt,t.title FROM lifecycle_state l
      JOIN tasks t ON t.chain_id=l.chain_id AND t.task_id=l.task_id
      LEFT JOIN local_controls c ON c.chain_id=l.chain_id AND c.task_id=l.task_id
      WHERE l.state='in_review' AND COALESCE(c.mode,'ready')='ready' ORDER BY l.chain_id,l.task_id LIMIT ?`,"200")
    if !read do return nil,false
    for r in reviews {
        required,approved,gate_ok:=complete_user_gate(s,r[0],r[1],r[2])
        if !gate_ok do return nil,false
        if !required || approved do continue
        // As on main (gate.odin: notified when the agent review gate PASSES),
        // the user must be the remaining gate: no agent review still owed.
        if config,_,configured:=lifecycle_config(s,r[0],r[1]);configured {
            owed,owed_ok:=review_owed(s,r[0],r[1],r[2],config)
            if !owed_ok do return nil,false
            if len(owed)>0 do continue
        }
        append(&out,Coordinator_Notice_Candidate{r[0],r[1],coordinator_of(s,&coordinators,r[0]),"review_requested_from_user",r[3],"",r[2],0})
    }
    return out[:],true
}
