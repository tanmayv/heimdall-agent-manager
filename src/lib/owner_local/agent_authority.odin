#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Agent authority on an owner chain (R4a). This is the ONE policy that decides
// what a launched agent may do on a chain this Bridge owns. The caller (the
// owner Bridge) has already proved the exact live child from the agent's
// instance token; nothing here trusts request JSON for identity. The owner
// then signs the resulting command with its own key, so the existing lease,
// lifecycle and command paths re-check every fence.
//
//   Worker      a child bound by local_fleet to the task: lease and
//               requirements verbs on that task only; it may read and
//               comment on the task while it holds a live lease there.
//   Reviewer    the configured reviewer child (or a review-role child).
//   Coordinator the chain's enabled coordinator member, exactly this launch:
//               chain-management verbs on behalf of the user.
//
// Every other combination, including an agent bound to another chain, is
// refused with invalid_scope.
Agent_Role :: enum { None, Worker, Reviewer, Coordinator }

// The verb classes. review.human is review.post recorded on behalf of the user.
agent_verb_role :: proc(verb:string) -> Agent_Role {
    switch verb {
    case "lease.next","lease.claim","lease.heartbeat","lease.submit","lease.handoff","lease.block","lease.switch","requirements.present","requirements.ack": return .Worker
    case "review.open","review.post","review.role.open","review.role.post","review.checkpoint": return .Reviewer
    case "task.create","task.edit","task.comment","task.read","chain.read","chain.summary.set","chain.propose","chain.publish","requirements.edit","review.human": return .Coordinator
    }
    return .None
}

agent_child_valid :: proc(child:Child) -> bool {
    return contracts.owner_field_valid(child.instance,"id") && contracts.owner_field_valid(child.epoch,"id") && child.run_count>0 &&
        contracts.owner_field_valid(child.token_generation,"hash") && contracts.owner_field_valid(child.agent_id,"id")
}

// Exact current coordinator membership: the latest member version for this
// instance must be enabled, carry role coordinator and name this very launch.
agent_coordinator :: proc(s:^Store,chain:string,child:Child) -> bool {
    rows,ok:=query(s.db,"SELECT enabled,role,child_json,agent_id FROM local_chain_member_versions WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,child.instance)
    return ok && len(rows)==1 && rows[0][0]=="1" && rows[0][1]=="coordinator" && rows[0][2]==encode(child) && rows[0][3]==child.agent_id
}

// The fleet row binds the task to this exact launch.
agent_worker :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    rows,ok:=query(s.db,"SELECT instance_id,enabled,launch_epoch,run_count,token_generation FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    return ok && len(rows)==1 && rows[0][0]==child.instance && rows[0][1]=="1" && rows[0][2]==child.epoch &&
        number(rows[0][3])==child.run_count && rows[0][4]==child.token_generation
}

// A live (unretired) lease of this exact launch on this task.
agent_holder :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    rows,ok:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? AND task_id=? AND instance_id=? AND launch_epoch=? AND run_count=? AND token_generation=? AND retired_seq IS NULL",
        chain,task,child.instance,child.epoch,fmt.tprintf("%d",child.run_count),child.token_generation)
    return ok && len(rows)==1 && agent_worker(s,chain,task,child)
}

agent_reviewer :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    config,binding,configured:=lifecycle_config(s,chain,task)
    if !configured || child.agent_id==field(config,"author_agent_id") do return false
    if encode(child)==binding[2] && child.agent_id==field(config,"reviewer_agent_id") do return true
    return role_child_authorized(s,chain,task,child,"")
}

// Caller holds the Store mutex (inside a transaction or under the lock).
agent_authorize :: proc(s:^Store,chain,task:string,child:Child,verb:string) -> (Agent_Role,string) {
    if !agent_child_valid(child) || !contracts.owner_field_valid(chain,"id") do return .None,"invalid_scope"
    chains,ok:=query(s.db,"SELECT 1 FROM task_chains WHERE chain_id=?",chain)
    if !ok do return .None,"storage_error"
    if len(chains)!=1 do return .None,"invalid_scope"
    // A child bound to another chain (lifetime membership) is foreign here.
    if !member_authorized(s,chain,child) do return .None,"invalid_scope"
    if task!="" && verb!="task.create" {
        tasks,read:=query(s.db,"SELECT 1 FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !read do return .None,"storage_error"
        if len(tasks)!=1 do return .None,"invalid_scope"
    }
    switch agent_verb_role(verb) {
    case .Worker:
        if task!="" && agent_worker(s,chain,task,child) do return .Worker,"ok"
        return .None,"invalid_scope"
    case .Reviewer:
        if task!="" && agent_reviewer(s,chain,task,child) do return .Reviewer,"ok"
        return .None,"invalid_scope"
    case .Coordinator:
        if agent_coordinator(s,chain,child) do return .Coordinator,"ok"
        // A worker may read and comment on its own leased task, nothing else.
        if (verb=="task.read" || verb=="task.comment") && task!="" && agent_holder(s,chain,task,child) do return .Worker,"ok"
        return .None,"invalid_scope"
    case .None:
    }
    return .None,"invalid_scope"
}

// Locked wrapper for callers outside a transaction.
agent_authorize_locked :: proc(s:^Store,chain,task:string,child:Child,verb:string) -> (Agent_Role,string) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return .None,"storage_error"
    defer transaction_rollback(&tx)
    return agent_authorize(s,chain,task,child,verb)
}

// Methods an agent may submit through the ordinary signed command path.
agent_command_method :: proc(method:string) -> bool {
    switch method {
    case "task.create","task.edit","task.comment","task.read","chain.read","chain.summary.set","chain.propose","chain.publish","requirements.edit","review.post": return true
    }
    return false
}

// Admission of an owner-signed agent command inside execute(): the owner key
// signed it for exactly this child, and the policy grants the verb.
agent_command_admit :: proc(s:^Store,c:json.Object,payload:string,key:contracts.Owner_Verified_Key,agent:Child) -> string {
    method:=field(c,"method")
    if !agent_command_method(method) do return "invalid_scope"
    if key.kind!="bridge" || !key.enrolled || key.revoked || key.account_id!=s.account || key.principal_id!=s.owner || key.key_id!=s.owner_key do return "invalid_scope"
    if field(c,"principal_id")!=agent.instance || field(c,"key_id")!=s.owner_key || field(c,"account_id")!=s.account || field(c,"immutable_owner_bridge")!=s.owner do return "invalid_scope"
    if !contracts.owner_verify_signature("command",c,"signature",key) do return "bad_signature"
    if contracts.owner_payload_digest(payload)!=field(c,"payload_digest") do return "digest_mismatch"
    if _,parsed:=contracts.owner_parse(payload,contracts.owner_payload_kind(method));!parsed do return "malformed"
    verb:="review.human" if method=="review.post" else method
    role,code:=agent_authorize(s,field(c,"chain_id"),field(c,"task_id"),agent,verb)
    if role==.None do return code
    return "ok"
}

agent_grant :: proc(s:^Store,c:json.Object,now:i64) -> contracts.Owner_Read_Grant {
    return contracts.Owner_Read_Grant{account_id=s.account,owner_bridge_id=s.owner,chain_id=field(c,"chain_id"),principal_id=field(c,"principal_id"),
        key_id=s.owner_key,method=field(c,"method"),revision=1,expires_ms=now+contracts.OWNER_REQUEST_TTL_MS+1,can_read=true,can_mutate=true}
}

// Coordinator (and own-task worker) commands, signed by the owner key on the
// agent's behalf. The directory pin is the owner's current one.
execute_agent :: proc(s:^Store,command_raw,payload:string,agent:Child,owner_key:contracts.Owner_Verified_Key,now:i64,kr:^vault.Vault_Keyring,sign:Signer) -> Result {
    version,hash:=directory_pin(s)
    if version<0 do return fail("storage_error")
    return execute(s,command_raw,payload,"",owner_key,owner_key,version,hash,now,kr,sign,agent=agent)
}

// ---- lease.next: atomic next-ready discovery + claim --------------------

Lease_Pick :: struct {
    status:string, // "granted" | "current" | "none"
    chain_id,task_id,lease_id:string,
}

// Everything the claim path would refuse, checked before choosing a task, so
// one blocked task never hides the next ready one. execute_lease re-checks.
agent_claimable :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    assignment,read:=query(s.db,"SELECT configuration_command FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    if !read || len(assignment)!=1 do return false
    assigned,valid:=contracts.owner_parse(assignment[0][0],"command")
    // Remote reservations are claimed only by their executor preparation.
    if !valid || field(assigned,"method")=="fleet.reserve" do return false
    if migration_quarantined(s,chain) || migration_archived_task(s,chain,task) do return false
    if !work_chain_active(s,chain) || !work_task_published(s,chain,task) do return false
    if !control_active(s,chain,task) || !control_ready(s,chain,task) do return false
    if !workflow_task_current(s,chain,task) || !dependency_ready(s,chain,task) || !language_claim_ready(s,chain,task) do return false
    if !lifecycle_path_current(s,chain,task) do return false
    live,ok:=query(s.db,"SELECT 1 FROM local_leases WHERE task_id=? AND retired_seq IS NULL",task)
    if !ok || len(live)>0 do return false
    if config,binding,configured:=lifecycle_config(s,chain,task);configured {
        if child.agent_id!=field(config,"author_agent_id") || encode(child)!=binding[1] do return false
        states,state_ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !state_ok || len(states)!=1 || states[0][0]!="ready" do return false
    }
    return true
}

// Returns the caller's live lease (status current), or claims the first
// eligible task bound to this exact child (priority p0 first, then chain and
// task id), or status none. Selection and claim commit in one transaction.
lease_next :: proc(s:^Store,child:Child,key:contracts.Owner_Verified_Key,now:i64,sign:Signer,lease_id,operation_id:string) -> (Result,Lease_Pick) {
    context.allocator=context.temp_allocator
    if !agent_child_valid(child) || !contracts.owner_field_valid(lease_id,"id") || !contracts.owner_field_valid(operation_id,"id") do return fail("invalid_scope"),{}
    if sign.sign==nil || now<0 do return fail("storage_error"),{}
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error"),{}
    defer transaction_rollback(&tx)
    current,ok:=query(s.db,"SELECT lease_id,chain_id,task_id FROM local_leases WHERE instance_id=? AND retired_seq IS NULL AND expires_ms>? AND hard_ms>?",child.instance,fmt.tprintf("%d",now),fmt.tprintf("%d",now))
    if !ok do return fail("storage_error"),{}
    if len(current)==1 {
        row:=current[0]
        if role,code:=agent_authorize(s,row[1],row[2],child,"lease.heartbeat");role!=.Worker do return fail(code),{}
        pick:=Lease_Pick{"current",row[1],row[2],row[0]}
        return Result{code="ok",body=encode(pick)},pick
    }
    candidates,read:=query(s.db,`SELECT f.chain_id,f.task_id,f.configuration_revision,t.revision,
      COALESCE((SELECT priority FROM local_task_priority_versions p WHERE p.chain_id=f.chain_id AND p.task_id=f.task_id ORDER BY accepted_seq DESC LIMIT 1),'p2') AS pr
      FROM local_fleet f JOIN tasks t ON t.chain_id=f.chain_id AND t.task_id=f.task_id
      WHERE f.instance_id=? AND f.enabled=1 ORDER BY pr,f.chain_id,f.task_id LIMIT 200`,child.instance)
    if !read do return fail("storage_error"),{}
    for row in candidates {
        chain,task:=row[0],row[1]
        if role,_:=agent_authorize(s,chain,task,child,"lease.next");role!=.Worker do continue
        if !agent_claimable(s,chain,task,child) do continue
        c:=doc(map[string]string{
            "protocol_version"="1","account_id"=s.account,"owner_bridge_id"=s.owner,"chain_id"=chain,"task_id"=task,
            "lease_id"=lease_id,"instance_id"=child.instance,"launch_epoch"=child.epoch,"run_count"=fmt.tprintf("%d",child.run_count),
            "token_generation"=child.token_generation,"configuration_revision"=row[2],"expected_revision"=row[3],
            "operation_id"=operation_id,"method"="lease.claim","request_expires_ms"=fmt.tprintf("%d",now+60000),
            "capability_digest"=contracts.owner_payload_digest(""),"key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)})
        signature,signed:=sign.sign(sign.ctx,"lease_command",c)
        if !signed do return fail("storage_error"),{}
        c["signature"]=json.String(signature)
        // A refused candidate rolls back its savepoint; try the next one.
        r:=execute_lease(s,encode(c),"",child,key,now,sign,&tx)
        if r.code!="ok" do continue
        if !transaction_commit(&tx) do return fail("storage_error"),{}
        return r,Lease_Pick{"granted",chain,task,lease_id}
    }
    pick:=Lease_Pick{status="none"}
    return Result{code="ok",body=encode(pick)},pick
}

// ---- read-side helpers for the owner Bridge (locked) ---------------------

Agent_Lease_State :: struct {
    lease_id,chain_id,task_id,capability,configuration_revision,task_revision,requirements_revision:string,
    config:json.Object,
    configured:bool,
}

// The caller's live lease and the revisions needed to sign its next command.
agent_lease_state :: proc(s:^Store,child:Child) -> (Agent_Lease_State,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return {},false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT l.lease_id,l.chain_id,l.task_id,l.capability_json,l.configuration_revision,t.revision FROM local_leases l JOIN tasks t ON t.chain_id=l.chain_id AND t.task_id=l.task_id WHERE l.instance_id=? AND l.retired_seq IS NULL",child.instance)
    if !ok || len(rows)!=1 do return {},false
    r:=rows[0]
    st:=Agent_Lease_State{lease_id=r[0],chain_id=r[1],task_id=r[2],capability=r[3],configuration_revision=r[4],task_revision=r[5],requirements_revision="1"}
    if req,has:=lifecycle_requirements(s,r[1],r[2]);has do st.requirements_revision=req[0]
    st.config,_,st.configured=lifecycle_config(s,r[1],r[2])
    return st,true
}

Agent_Task_State :: struct {
    chain_id,task_id,task_revision,chain_revision,requirements_revision,state,attempt,head,configuration_revision:string,
    config:json.Object,
    configured:bool,
}

// Resolve a task (chain optional) known to this owner store.
agent_task_state :: proc(s:^Store,chain,task:string) -> (Agent_Task_State,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return {},false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT t.chain_id,t.task_id,t.revision,c.revision FROM tasks t JOIN task_chains c ON c.chain_id=t.chain_id WHERE t.task_id=? AND (?='' OR t.chain_id=?)",task,chain,chain)
    if !ok || len(rows)!=1 do return {},false
    st:=Agent_Task_State{chain_id=rows[0][0],task_id=rows[0][1],task_revision=rows[0][2],chain_revision=rows[0][3]}
    if req,has:=lifecycle_requirements(s,st.chain_id,task);has do st.requirements_revision=req[0]
    st.config,_,st.configured=lifecycle_config(s,st.chain_id,task)
    if st.configured do st.configuration_revision=field(st.config,"configuration_revision")
    states,read:=query(s.db,"SELECT l.state,l.attempt,COALESCE((SELECT head FROM local_submissions x WHERE x.chain_id=l.chain_id AND x.task_id=l.task_id AND x.attempt=l.attempt),'') FROM lifecycle_state l WHERE chain_id=? AND task_id=?",st.chain_id,task)
    if read && len(states)==1 { st.state=states[0][0];st.attempt=states[0][1];st.head=states[0][2] }
    return st,true
}

// Chain revision for chain-scoped commands; "" when this store does not own it.
agent_chain_revision :: proc(s:^Store,chain:string) -> string {
    tx:Transaction
    if !transaction_begin(s,&tx) do return ""
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !ok || len(rows)!=1 do return ""
    return rows[0][0]
}

// The chains this child acts on as a member or fleet worker (its context when
// a verb names no chain).
agent_home_chain :: proc(s:^Store,child:Child) -> string {
    tx:Transaction
    if !transaction_begin(s,&tx) do return ""
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=? UNION SELECT chain_id FROM local_leases WHERE instance_id=? AND retired_seq IS NULL UNION SELECT chain_id FROM local_fleet WHERE instance_id=? AND enabled=1",child.instance,child.instance,child.instance)
    if !ok || len(rows)!=1 do return ""
    return rows[0][0]
}

// Whether this instance has any owner-local binding at all (fleet row, lease,
// membership or review configuration) on this store.
agent_bound :: proc(s:^Store,instance:string) -> bool {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,`SELECT 1 FROM local_fleet WHERE instance_id=?1 UNION ALL SELECT 1 FROM local_leases WHERE instance_id=?1 AND retired_seq IS NULL
      UNION ALL SELECT 1 FROM local_member_chains WHERE instance_id=?1 UNION ALL SELECT 1 FROM lifecycle_configs WHERE json_extract(reviewer_child,'$.instance')=?1 LIMIT 1`,instance)
    return ok && len(rows)>0
}
