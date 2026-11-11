package owner_local

// Owner-chain coordinator notices (origin/main taskv2 effect_notify_coordinator):
// the task states the chain's coordinator is told about so it can relay to the
// user and act. This lists the CURRENT conditions only; the owner Bridge
// (bridge/owner_coordinator_notice.odin) dedupes them, rate-limits the
// repeating ones and delivers the [taskv2] line to the coordinator.
//
//   blocked_on human     blocked on the user/human (lease.block, task.escalate)
//   agent_not_running    blocked because the task's agent could not run
//   review_requested_from_user  in review, user approval required and not given
//   hold_stale           held (task.hold); the Bridge alerts only once it is old
//
// Owner chains keep no attempt budget or review-round limit, so main's
// budget_exhausted and oscillation have no owner-chain state to report.
Coordinator_Notice_Candidate :: struct {
    chain_id,task_id,coordinator,trigger,title,reason,attempt:string,
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
    controls,ok:=query(s.db,`SELECT c.chain_id,c.task_id,c.mode,c.waiting_on,c.reason,t.title,COALESCE(l.attempt,'0')
      FROM local_controls c JOIN tasks t ON t.chain_id=c.chain_id AND t.task_id=c.task_id
      LEFT JOIN lifecycle_state l ON l.chain_id=c.chain_id AND l.task_id=c.task_id
      WHERE (c.mode='blocked' AND c.waiting_on IN ('user','human','agent_not_running')) OR c.mode='held'
      ORDER BY c.chain_id,c.task_id LIMIT ?`,"200")
    if !ok do return nil,false
    for r in controls {
        trigger:="hold_stale" if r[2]=="held" else ("agent_not_running" if r[3]=="agent_not_running" else "blocked_on human")
        append(&out,Coordinator_Notice_Candidate{r[0],r[1],coordinator_of(s,&coordinators,r[0]),trigger,r[5],r[4],r[6]})
    }
    reviews,read:=query(s.db,`SELECT l.chain_id,l.task_id,l.attempt,t.title FROM lifecycle_state l
      JOIN tasks t ON t.chain_id=l.chain_id AND t.task_id=l.task_id
      LEFT JOIN local_controls c ON c.chain_id=l.chain_id AND c.task_id=l.task_id
      WHERE l.state='in_review' AND COALESCE(c.mode,'ready')='ready' ORDER BY l.chain_id,l.task_id LIMIT ?`,"200")
    if !read do return nil,false
    for r in reviews {
        required,approved,gate_ok:=complete_user_gate(s,r[0],r[1],r[2])
        if !gate_ok do return nil,false
        if required && !approved do append(&out,Coordinator_Notice_Candidate{r[0],r[1],coordinator_of(s,&coordinators,r[0]),"review_requested_from_user",r[3],"",r[2]})
    }
    return out[:],true
}
