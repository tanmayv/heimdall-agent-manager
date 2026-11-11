package owner_local

// Owner-chain tasks that need the user (origin/main taskv2 user_attention):
// blocked on the user/human or on agent_not_running ("blocked"), or in review
// with the user's approval required and not yet given ("review"). The Bridge
// sends these as an in-memory snapshot to the Hub, which merges them into the
// Needs-attention deck at read time. Ids and flags only: never titles, briefs,
// reasons or other task content.
User_Attention :: struct {
    chain_id,task_id,attention,badge,state,attempt:string,
}

USER_ATTENTION_MAX :: 200

user_attention_list :: proc(s:^Store) -> ([]User_Attention,bool) {
    out:=make([dynamic]User_Attention,context.temp_allocator)
    if s==nil || s.db==nil do return out[:],true
    blocked,ok:=query(s.db,`SELECT c.chain_id,c.task_id,c.waiting_on,COALESCE(l.state,'ready'),COALESCE(l.attempt,'0')
      FROM local_controls c JOIN tasks t ON t.chain_id=c.chain_id AND t.task_id=c.task_id
      LEFT JOIN lifecycle_state l ON l.chain_id=c.chain_id AND l.task_id=c.task_id
      WHERE c.mode='blocked' AND c.waiting_on IN ('user','human','agent_not_running')
      ORDER BY c.chain_id,c.task_id LIMIT ?`,"200")
    if !ok do return nil,false
    for r in blocked {
        badge:="agent_not_running" if r[2]=="agent_not_running" else "question"
        append(&out,User_Attention{r[0],r[1],"blocked",badge,r[3],r[4]})
    }
    reviews,read:=query(s.db,`SELECT l.chain_id,l.task_id,l.attempt FROM lifecycle_state l
      LEFT JOIN local_controls c ON c.chain_id=l.chain_id AND c.task_id=l.task_id
      WHERE l.state='in_review' AND COALESCE(c.mode,'ready')='ready' ORDER BY l.chain_id,l.task_id LIMIT ?`,"200")
    if !read do return nil,false
    for r in reviews {
        if len(out)>=USER_ATTENTION_MAX do break
        required,approved,gate_ok:=complete_user_gate(s,r[0],r[1],r[2])
        if !gate_ok do return nil,false
        if required && !approved do append(&out,User_Attention{r[0],r[1],"review","review","in_review",r[2]})
    }
    return out[:],true
}
