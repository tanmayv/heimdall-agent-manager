#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// R2-1/R3-1: only a device-signed review is the user. The user or the
// verified chain coordinator may add or remove requires_user_approval (audited;
// clearing re-evaluates the review gate); workers and reviewers may not.

USER_GATE_BRIEF :: `{"goal":"Complete scoped work","acceptance":["Tests pass"],"requires_user_approval":true}`

// lifecycle_seed with a brief that requires the user's approval.
user_gate_seed :: proc(t:^testing.T,f:^Fixture,brief:=USER_GATE_BRIEF) {
    child:=lease_child();fleet_seed(t,f,child)
    raw:=encode(doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
    c:=command(f,"lifecycle.configure","config","task",raw,"2")
    testing.expect_value(t,execute(&f.store,c,raw,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
    p:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","req1","task",p,"3"),p).code,"ok")
}
user_gate_state :: proc(f:^Fixture) -> string {
    rows,_:=query(f.store.db,"SELECT state FROM lifecycle_state WHERE chain_id='chain' AND task_id='task'")
    return rows[0][0] if len(rows)==1 else ""
}
// Submit attempt 1 and record the independent reviewer's approval.
user_gate_reviewed :: proc(t:^testing.T,f:^Fixture) -> bool {
    cap:=lifecycle_ready(t,f)
    if cap=="" do return false
    if !testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Checks pass"}`,cap).code,"ok") do return false
    p:=lifecycle_verdict()
    opened:=lifecycle_call(f,lifecycle_reviewer(),"review.open","open",p,"",agent_task_revision(f,"task"))
    if !testing.expect_value(t,opened.code,"ok") do return false
    return testing.expect_value(t,lifecycle_call(f,lifecycle_reviewer(),"review.post","post",p,result_cap(opened),agent_task_revision(f,"task")).code,"ok")
}
user_gate_requirements :: proc(f:^Fixture,agent:Child,op,revision,brief:string) -> Result {
    p:=encode(doc(map[string]string{"requirements_revision"=revision,"body_cipher"=cipher(f,brief)}))
    if agent.instance=="" do return invoke(f,command(f,"requirements.edit",op,"task",p,agent_task_revision(f,"task")),p)
    return agent_run(f,agent,"requirements.edit",op,"task",p,agent_task_revision(f,"task"))
}

@(test)
user_gate_coordinator_relay_never_counts_as_user :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    testing.expect_value(t,user_gate_state(f),"in_review")
    // The coordinator's review post --on-behalf-of user (review.human) is
    // recorded, as an agent row, and the gate keeps waiting for the user.
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    rows,_:=query(f.store.db,"SELECT principal_id,principal_kind FROM local_reviews WHERE principal_id='coord_instance'")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"coord_instance","agent"}}))
    // The user's own device-signed review satisfies the gate.
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
    rows,_=query(f.store.db,"SELECT principal_kind FROM local_reviews WHERE principal_id='device'")
    testing.expect_value(t,encode(rows),encode([1][1]string{{"device"}}))
}

@(test)
user_gate_agent_request_changes_still_returns_the_task :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    p,_:=contracts.owner_parse(lifecycle_verdict(),"review_payload");p["verdict"]=json.String("request_changes")
    testing.expect_value(t,agent_run(f,coord,"review.post","relay_changes","task",encode(p),agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"ready")
}

USER_GATE_CLEARED :: `{"goal":"Complete scoped work","acceptance":["Tests pass"],"requires_user_approval":false,"requirements_reason":"user asked to skip their review"}`

// The audit recorded with the latest event of kind:
// event actor|change actor|old>new|reason|operation (empty without a change).
user_gate_audit :: proc(f:^Fixture,kind:string) -> string {
    rows,_:=query(f.store.db,`SELECT e.actor_kind||':'||e.actor_id||'|'||COALESCE(json_extract(c.v,'$.actor_kind')||':'||json_extract(c.v,'$.actor_id')||'|'||
        json_extract(c.v,'$.old')||'>'||json_extract(c.v,'$.new')||'|'||json_extract(c.v,'$.reason')||'|'||json_extract(c.v,'$.operation_id'),'')
      FROM local_events e,(SELECT json_extract(json_extract(evidence_json,'$.result'),'$.user_approval_change') AS v,seq FROM local_events) c
      WHERE c.seq=e.seq AND e.kind=? ORDER BY e.seq DESC LIMIT 1`,kind)
    return rows[0][0] if len(rows)==1 else ""
}

@(test)
user_gate_coordinator_adds_and_removes_the_brief_gate :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    // Omitting the flag is an ordinary edit that clears it too (the Bridge
    // keeps it on omission); an agent removal must carry a reason.
    testing.expect_value(t,user_gate_requirements(f,coord,"no_reason","2",`{"goal":"g","acceptance":["a"],"requires_user_approval":false}`).code,"invalid_content")
    required,ok:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"a refused edit leaves the gate in place")
    testing.expect_value(t,user_gate_requirements(f,coord,"clear","2",`{"goal":"g","acceptance":["a"],"requires_user_approval":false,"requirements_reason":"user said no review"}`).code,"ok")
    required,ok=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && !required,"the coordinator removed the gate")
    testing.expect_value(t,user_gate_audit(f,"requirements.edit"),"agent:coord_instance|agent:coord_instance|1>0|user said no review|clear")
    // The coordinator may add it back (audited, no reason needed).
    testing.expect_value(t,user_gate_requirements(f,coord,"add","3",USER_GATE_BRIEF).code,"ok")
    required,ok=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"the coordinator added the gate")
    testing.expect_value(t,user_gate_audit(f,"requirements.edit"),"agent:coord_instance|agent:coord_instance|0>1||add")
    // An edit that keeps it records no change.
    testing.expect_value(t,user_gate_requirements(f,coord,"keep","4",`{"goal":"g2","acceptance":["a"],"requires_user_approval":true}`).code,"ok")
    testing.expect_value(t,user_gate_audit(f,"requirements.edit"),"agent:coord_instance|")
    // The user's device may remove it without a reason.
    testing.expect_value(t,user_gate_requirements(f,{},"device_unset","5",`{"goal":"g3","acceptance":["a"]}`).code,"ok")
    required,ok=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && !required,"a device edit removes the gate")
    testing.expect_value(t,user_gate_audit(f,"requirements.edit"),"device:device|device:device|1>0||device_unset")
}

@(test)
user_gate_workers_and_reviewers_cannot_change_the_gate :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    worker,reviewer:=lease_child(),lifecycle_reviewer()
    agent_seat(t,f,reviewer,"reviewer")
    for agent in ([2]Child{worker,reviewer}) {
        testing.expect_value(t,user_gate_requirements(f,agent,fmt.tprintf("clear_%s",agent.instance),"2",USER_GATE_CLEARED).code,"invalid_scope")
    }
    required,ok:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"the gate stays on")
}

@(test)
user_gate_clearing_reevaluates_the_review_gate :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    // The independent approval is held; an agent relay never satisfies the
    // active user gate.
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    // Clearing only the gate settles the submitted attempt.
    r:=user_gate_requirements(f,coord,"clear","2",USER_GATE_CLEARED)
    testing.expect_value(t,r.code,"ok")
    testing.expect(t,strings.contains(r.body,`"state":"done"`),r.body)
    testing.expect_value(t,user_gate_state(f),"done")
    testing.expect_value(t,cc_scalar(f,"SELECT count(*) FROM local_review_sessions"),"0")
    testing.expect_value(t,user_gate_audit(f,"requirements.edit"),"agent:coord_instance|agent:coord_instance|1>0|user asked to skip their review|clear")
}

@(test)
user_gate_clearing_with_owed_reviews_or_other_changes_returns_to_ready :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    coord:=agent_coordinator_child()
    // The independent reviewer has not approved yet: the attempt cannot settle.
    {
        f:=fixture(t);defer destroy(f);user_gate_seed(t,f);agent_seat_coordinator(t,f,coord)
        cap:=lifecycle_ready(t,f)
        if cap=="" do return
        testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.submit","submit",`{"requirements_revision":"1","head":"","summary":"Checks pass"}`,cap).code,"ok")
        testing.expect_value(t,user_gate_state(f),"in_review")
        testing.expect_value(t,user_gate_requirements(f,coord,"clear","2",USER_GATE_CLEARED).code,"ok")
        testing.expect_value(t,user_gate_state(f),"ready")
    }
    // Clearing together with a content change is an ordinary requirements edit.
    {
        f:=fixture(t);defer destroy(f);user_gate_seed(t,f);agent_seat_coordinator(t,f,coord)
        if !user_gate_reviewed(t,f) do return
        testing.expect_value(t,user_gate_requirements(f,coord,"clear","2",`{"goal":"Different work","acceptance":["Tests pass"],"requires_user_approval":false,"requirements_reason":"rescoped"}`).code,"ok")
        testing.expect_value(t,user_gate_state(f),"ready")
    }
}

@(test)
user_gate_lifecycle_configure_cannot_remove_the_gate :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord,worker,reviewer:=agent_coordinator_child(),lease_child(),lifecycle_reviewer()
    agent_seat_coordinator(t,f,coord);agent_seat(t,f,reviewer,"reviewer")
    config:=doc(map[string]string{"configuration_revision"="2","author_agent_id"=worker.agent_id,"reviewer_agent_id"=reviewer.agent_id,"reviewer_instance_id"=reviewer.instance,"directory_id"="owner_none","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""})
    // The payload has no flag to clear: one carrying requires_user_approval is malformed.
    withflag:=doc(map[string]string{"requires_user_approval"="0"})
    for k,v in config do withflag[k]=v
    raw:=encode(withflag)
    testing.expect_value(t,execute_agent(&f.store,agent_command(f,coord,"lifecycle.configure","config_flag","task",raw,agent_task_revision(f,"task")),raw,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{worker,reviewer,true}).code,"malformed")
    raw=encode(config)
    testing.expect_value(t,execute_agent(&f.store,agent_command(f,coord,"lifecycle.configure","config2","task",raw,agent_task_revision(f,"task")),raw,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{worker,reviewer,true}).code,"ok")
    required,ok:=task_user_approval_required(&f.store,"chain","task")
    testing.expect(t,ok && required,"a coordinator reconfiguration keeps the user gate")
}

@(test)
user_gate_migration_backfills_principal_kind_without_regating :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
    // Simulate V34 rows: every review carries the column default ('agent').
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,"DROP TRIGGER local_reviews_immutable; UPDATE local_reviews SET principal_kind='agent'; CREATE TRIGGER local_reviews_immutable BEFORE UPDATE ON local_reviews BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END; UPDATE schema_migrations SET version=34"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    rows,_:=query(f.store.db,"SELECT reviewer_agent_id,principal_kind FROM local_reviews ORDER BY reviewer_agent_id")
    testing.expect_value(t,encode(rows),encode([3][2]string{{"coord_instance","agent"},{"device","device"},{"reviewer","agent"}}))
    version,_:=query(f.store.db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect_value(t,encode(version),encode([1][2]string{{"38","38"}}))
    // An attempt already past the gate is not re-gated.
    testing.expect_value(t,user_gate_state(f),"done")
    // Review evidence stays immutable after the backfill.
    testing.expect(t,!exec(f.store.db,"UPDATE local_reviews SET principal_kind='device'"))
}

@(test)
user_gate_migration_keeps_waiting_attempts_on_the_device :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);user_gate_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    if !user_gate_reviewed(t,f) do return
    p:=lifecycle_verdict()
    testing.expect_value(t,agent_run(f,coord,"review.post","relay","task",p,agent_task_revision(f,"task")).code,"ok")
    testing.expect_value(t,user_gate_state(f),"in_review")
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=34"))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    testing.expect_value(t,user_gate_state(f),"in_review")
    rows,_:=query(f.store.db,"SELECT principal_kind FROM local_reviews WHERE principal_id='coord_instance'")
    testing.expect_value(t,encode(rows),encode([1][1]string{{"agent"}}))
    testing.expect_value(t,invoke(f,command(f,"review.post","human","task",p,agent_task_revision(f,"task")),p).code,"ok")
    testing.expect_value(t,user_gate_state(f),"done")
}
