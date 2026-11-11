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
//   Reviewer    the configured reviewer child, or a child of an agent the
//               task brief names in reviewers.
//   Coordinator the chain's enabled coordinator member, exactly this launch:
//               chain-management verbs on behalf of the user, including fleet
//               management (fleet.policy.set, chain.member.set of workers and
//               reviewers, instance start/stop/restart, fleet.reserve of a
//               task on another Bridge of the account).
//
// Any proven agent of the account may also read any chain or task and
// comment on a task (agent_account_verb, origin/main parity). Every other
// combination, including an agent bound to another chain, is refused with
// invalid_scope.
Agent_Role :: enum { None, Worker, Reviewer, Coordinator }

// The verb classes. review.human is review.post recorded on behalf of the user.
agent_verb_role :: proc(verb:string) -> Agent_Role {
    switch verb {
    case "lease.next","lease.claim","lease.heartbeat","lease.submit","lease.handoff","lease.block","lease.switch","requirements.present","requirements.ack": return .Worker
    case "review.open","review.post","review.checkpoint": return .Reviewer
    case "task.create","task.edit","task.comment","task.read","chain.read","chain.edit","chain.summary.set","chain.propose","chain.publish","requirements.edit","review.human",
         "task.priority","dependency.edit","fleet.edit","lifecycle.configure",
         "chain.member.set","fleet.policy.set","fleet.policy.read","fleet.instance","fleet.reserve": return .Coordinator
    }
    if agent_coordinator_control(verb) do return .Coordinator
    return .None
}

// Coordinator controls on an owner chain (P-CS CC-A, REQ-CC-1..5,8,10,11 and
// R2-5): the verified chain coordinator drives tasks without holding a lease.
// Worker, reviewer and foreign-chain tokens are refused with invalid_scope by
// agent_authorize. workflow.gate stays user-only. Fleet management
// (membership, fleet policy, instance lifecycle, and fleet.reserve placing a
// task on another Bridge of the account) is agent_command_admit's; a
// reservation still needs the executor Bridge's signed enrollment attestation
// (remote_assignment_child), so the coordinator cannot invent a remote child.
agent_coordinator_control :: proc(verb:string) -> bool {
    switch verb {
    case "task.hold","task.release","task.cancel","task.reopen","task.resolve","merge.retry","task.delete",
         "chain.complete","workflow.retry","workflow.cancel","lease.revoke","task.recheck","task.escalate",
         "lifecycle.force_submit","task.complete","task.split": return true
    }
    return false
}

// Verbs any proven agent of the account may use on any owner chain, as the
// Hub allowed on origin/main (agent_action_handlers chain_show, task_show,
// task_comment): reading a chain or task and commenting on a task.
agent_account_verb :: proc(verb:string) -> bool {
    return verb=="chain.read" || verb=="task.read" || verb=="task.comment"
}

// Controls whose agent form must carry a non-empty reason (R2-6). The reason
// is stored in the control event summary and the agent-attributed event.
agent_reason_required :: proc(method:string) -> bool {
    switch method {
    case "task.hold","task.release","task.cancel","task.reopen","task.resolve","lease.revoke","task.delete","task.escalate","merge.retry",
         "lifecycle.force_submit","task.complete","task.split": return true
    }
    return false
}

agent_child_valid :: proc(child:Child) -> bool {
    return contracts.owner_field_valid(child.instance,"id") && contracts.owner_field_valid(child.epoch,"id") && child.run_count>0 &&
        contracts.owner_field_valid(child.token_generation,"hash") && contracts.owner_field_valid(child.agent_id,"id")
}

// Current coordinator membership: the latest member version for this instance
// must be enabled, carry role coordinator and name the same agent. It binds the
// instance id, not one launch: the caller's instance token already authenticates
// the live child, and a restart (new epoch, run_count, token) keeps the binding.
agent_coordinator :: proc(s:^Store,chain:string,child:Child) -> bool {
    rows,ok:=query(s.db,"SELECT enabled,role,agent_id FROM local_chain_member_versions WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,child.instance)
    return ok && len(rows)==1 && rows[0][0]=="1" && rows[0][1]=="coordinator" && rows[0][2]==child.agent_id
}

// chain_coordinator_instance: the instance currently bound as this chain's
// coordinator ("" when none). Used to launch that instance with the
// coordinator role. Read-only.
chain_coordinator_instance :: proc(s:^Store,chain:string) -> string {
    rows,ok:=query(s.db,"SELECT instance_id FROM local_chain_member_versions m WHERE chain_id=? AND enabled=1 AND role='coordinator' AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) ORDER BY accepted_seq DESC LIMIT 1",chain)
    return rows[0][0] if ok && len(rows)>0 else ""
}

// The chain's bound coordinator as last recorded at chain.member.set. Its
// authority is the instance and agent id (agent_coordinator), not one launch,
// so the owner Bridge may sign a reassignment for it when it is not running.
chain_coordinator_child :: proc(s:^Store,chain:string) -> (Child,bool) {
    rows,ok:=query(s.db,"SELECT child_json FROM local_chain_member_versions m WHERE chain_id=? AND enabled=1 AND role='coordinator' AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) ORDER BY accepted_seq DESC LIMIT 1",chain)
    if !ok || len(rows)!=1 do return {},false
    child:Child
    if json.unmarshal_string(rows[0][0],&child,allocator=context.temp_allocator)!=nil || !agent_coordinator(s,chain,child) do return {},false
    return child,true
}

// Tasks still bound to an earlier launch of this child's instance (a restart
// gives a new epoch, run count and token) whose configured author is this
// agent and whose instance is still an enabled member of the chain. origin/main
// claims by agent id and chain membership, so such a task belongs to the new
// launch; the owner Bridge rebinds it before lease next. leased is true when
// the earlier launch still holds a live lease (it can never heartbeat again).
Restarted_Binding :: struct { chain_id,task_id:string, leased:bool }
agent_restarted_bindings :: proc(s:^Store,child:Child) -> ([]Restarted_Binding,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,`SELECT chain_id,task_id,EXISTS(SELECT 1 FROM local_leases l WHERE l.chain_id=f.chain_id AND l.task_id=f.task_id AND l.instance_id=f.instance_id AND l.retired_seq IS NULL)
      FROM local_fleet f WHERE instance_id=? AND enabled=1 AND NOT (launch_epoch=? AND run_count=? AND token_generation=?)
      AND NOT EXISTS(SELECT 1 FROM lifecycle_state x WHERE x.chain_id=f.chain_id AND x.task_id=f.task_id AND x.state!='ready') ORDER BY chain_id,task_id LIMIT 100`,
      child.instance,child.epoch,fmt.tprintf("%d",child.run_count),child.token_generation)
    if !ok do return nil,false
    out:=make([dynamic]Restarted_Binding,context.temp_allocator)
    for r in rows {
        if !member_authorized(s,r[0],child) || !control_active(s,r[0],r[1]) do continue
        if config,_,configured:=lifecycle_config(s,r[0],r[1]);configured && field(config,"author_agent_id")!=child.agent_id do continue
        append(&out,Restarted_Binding{r[0],r[1],r[2]=="1"})
    }
    return out[:],true
}

// chain_summary_current: the chain's latest curated summary text and its
// accepted_seq; ("","0") when none.
// Read-only (T1: `task-chain summary get` on owner chains).
chain_summary_current :: proc(s:^Store,chain:string) -> (body:string,version:string,ok:bool) {
    rows,read:=query(s.db,"SELECT curated_body,accepted_seq FROM local_chain_summary_versions WHERE chain_id=? ORDER BY accepted_seq DESC LIMIT 1",chain)
    if !read do return "","",false
    if len(rows)==0 do return "","0",true
    return rows[0][0],rows[0][1],true
}

// agent_solo_standing: whether this exact launch is the chain's coordinator
// and whether it holds a worker fleet row in the chain (solo mode, T1
// `--assignee self`): an enabled task fleet row, or a current fleet policy
// row for its own agent with the worker role unpaused. Read-only.
agent_solo_standing :: proc(s:^Store,chain:string,child:Child) -> (coordinator:bool,worker_row:bool) {
    coordinator=agent_coordinator(s,chain,child)
    rows,ok:=query(s.db,`SELECT 1 FROM local_fleet WHERE chain_id=?1 AND instance_id=?2 AND enabled=1
      UNION ALL SELECT 1 FROM local_fleet_policy_current p JOIN local_fleet_policy_roles r ON r.chain_id=p.chain_id AND r.agent_id=p.agent_id AND r.seq=p.seq
      WHERE p.chain_id=?1 AND p.agent_id=?3 AND r.role='worker' AND r.paused=0 AND NOT EXISTS(SELECT 1 FROM local_fleet_policy_roles x
        WHERE x.chain_id=p.chain_id AND x.agent_id=p.agent_id AND x.seq=p.seq AND x.paused=1 AND x.role IN ('worker','*')) LIMIT 1`,chain,child.instance,child.agent_id)
    worker_row=ok && len(rows)>0
    return
}

// Fleet of an owner chain as `task-chain fleet list` shows it: the current
// policy row per agent and the latest version of each member. Read-only.
Agent_Fleet_Member :: struct { instance_id,agent_id,role,enabled:string }
agent_fleet_view :: proc(s:^Store,chain:string) -> (policies:[]contracts.Owner_Fleet_Policy,members:[]Agent_Fleet_Member,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,nil,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,"SELECT * FROM local_fleet_policy_current WHERE chain_id=? ORDER BY agent_id",chain)
    if !read do return nil,nil,false
    policies=make([]contracts.Owner_Fleet_Policy,len(rows),context.temp_allocator)
    for row,i in rows do policies[i]=fleet_policy_document(row)
    rows,read=query(s.db,`SELECT instance_id,agent_id,role,enabled FROM local_chain_member_versions m WHERE chain_id=?
      AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) ORDER BY accepted_seq`,chain)
    if !read do return nil,nil,false
    members=make([]Agent_Fleet_Member,len(rows),context.temp_allocator)
    for row,i in rows do members[i]={row[0],row[1],row[2],row[3]}
    return policies,members,true
}

// The current fleet policy row of one agent in this chain. Read-only.
agent_fleet_policy :: proc(s:^Store,chain,agent:string) -> (policy:contracts.Owner_Fleet_Policy,found:bool,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return {},false,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,"SELECT * FROM local_fleet_policy_current WHERE chain_id=? AND agent_id=?",chain,agent)
    if !read do return {},false,false
    if len(rows)!=1 do return {},false,true
    return fleet_policy_document(rows[0]),true,true
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
    return task_reviewer_authorized(s,chain,task,child)
}

// Caller holds the Store mutex (inside a transaction or under the lock).
agent_authorize :: proc(s:^Store,chain,task:string,child:Child,verb:string) -> (Agent_Role,string) {
    if !agent_child_valid(child) || !contracts.owner_field_valid(chain,"id") do return .None,"invalid_scope"
    chains,ok:=query(s.db,"SELECT 1 FROM task_chains WHERE chain_id=?",chain)
    if !ok do return .None,"storage_error"
    if len(chains)!=1 do return .None,"invalid_scope"
    if task!="" && verb!="task.create" {
        tasks,read:=query(s.db,"SELECT 1 FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !read do return .None,"storage_error"
        if len(tasks)!=1 do return .None,"invalid_scope"
    }
    // origin/main parity (REQ-SEC-3): any agent of the account may view any
    // chain or task of this owner and comment on a task, member or not. The
    // caller already proved the live child of this account; changes stay
    // role-gated below, and the chain's coordinator keeps its role.
    account:=agent_account_verb(verb) && (verb!="task.comment" || task!="")
    // A child bound to another chain (lifetime membership) is foreign here.
    if !member_authorized(s,chain,child) {
        if account do return .Worker,"ok"
        return .None,"invalid_scope"
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
        // Any other agent of the account only reads and comments.
        if account do return .Worker,"ok"
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
    case "task.create","task.edit","task.comment","task.read","chain.read","chain.edit","chain.summary.set","chain.propose","chain.publish","requirements.edit","review.post",
         "task.priority","dependency.edit","fleet.edit","fleet.reserve","lifecycle.configure","chain.member.set","fleet.policy.set","fleet.policy.read": return true
    }
    return agent_coordinator_control(method)
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
    p,parsed:=contracts.owner_parse(payload,contracts.owner_payload_kind(method))
    if !parsed do return "malformed"
    verb:="review.human" if method=="review.post" else method
    chain:=field(c,"chain_id")
    role,code:=agent_authorize(s,chain,field(c,"task_id"),agent,verb)
    if role==.None do return code
    // Assignment on the user's behalf is limited to agents enrolled in THIS
    // chain (an enabled member or fleet worker) and to the chain's configured
    // repository. The coordinator enrolls agents itself (chain.member.set);
    // grants stay human-only (never on the agent allowlist).
    switch method {
    case "chain.member.set":
        if code:=agent_member_admit(s,chain,p,agent);code!="ok" do return code
    case "fleet.policy.set":
        // Native-history imports carry a source revision: device only.
        if field(p,"source_revision")!="" do return "invalid_scope"
    case "review.post":
        // REQ-CC-13 (Hub solo_self_review parity): a coordinator that worked
        // the task as its worker never reviews it, not even as a relay.
        worked,ok:=agent_self_worked(s,chain,field(c,"task_id"),agent)
        if !ok do return "storage_error"
        if worked do return "invalid_scope"
    case "fleet.edit":
        participant,ok:=agent_chain_participant(s,chain,field(p,"instance_id"))
        if !ok do return "storage_error"
        if !participant do return "invalid_scope"
    case "lifecycle.configure":
        // REQ-CC-13: the coordinator never names itself the reviewer.
        if field(p,"reviewer_instance_id")==agent.instance || field(p,"reviewer_agent_id")==agent.agent_id do return "invalid_scope"
        // No reviewer is valid (origin/main parity); a named one is enrolled here.
        if field(p,"reviewer_instance_id")!="" || field(p,"reviewer_agent_id")!="" {
            participant,ok:=agent_chain_participant(s,chain,field(p,"reviewer_instance_id"))
            if !ok do return "storage_error"
            if !participant do return "invalid_scope"
        }
        if field(p,"merge_policy")=="git" {
            rows,read:=query(s.db,"SELECT enabled,body FROM local_chain_directory_versions WHERE chain_id=? AND directory_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,field(p,"directory_id"))
            if !read do return "storage_error"
            if len(rows)!=1 || rows[0][0]!="1" do return "invalid_scope"
            v,valid:=contracts.owner_content_document(rows[0][1]);d,obj:=v.(json.Object)
            if !valid || !obj || field(d,"path")!=field(p,"repository") do return "invalid_scope"
        }
    }
    return "ok"
}

agent_grant :: proc(s:^Store,c:json.Object,now:i64) -> contracts.Owner_Read_Grant {
    return contracts.Owner_Read_Grant{account_id=s.account,owner_bridge_id=s.owner,chain_id=field(c,"chain_id"),principal_id=field(c,"principal_id"),
        key_id=s.owner_key,method=field(c,"method"),revision=1,expires_ms=now+contracts.OWNER_REQUEST_TTL_MS+1,can_read=true,can_mutate=true}
}

// Coordinator (and own-task worker) commands, signed by the owner key on the
// agent's behalf. The directory pin is the owner's current one.
// fleet_child and proof are Bridge-observed facts for fleet.edit and
// lifecycle.configure, exactly as on the device path. remote_key is the
// executor Bridge key a fleet.reserve attestation is checked against, verified
// by the caller in the current directory (same account, enrolled, not revoked).
execute_agent :: proc(s:^Store,command_raw,payload:string,agent:Child,owner_key:contracts.Owner_Verified_Key,now:i64,kr:^vault.Vault_Keyring,sign:Signer,fleet_child:Child={},proof:Lifecycle_Proof={},observed_children:[]Child=nil,source:Source_Proof={},remote_key:contracts.Owner_Verified_Key={}) -> Result {
    version,hash:=directory_pin(s)
    if version<0 do return fail("storage_error")
    return execute(s,command_raw,payload,"",owner_key,owner_key,version,hash,now,kr,sign,fleet_child,proof,observed_children,remote_key=remote_key,agent=agent,source=source)
}

// Fleet membership on the coordinator's own chain: it enrolls, re-roles and
// removes workers and reviewers (any role but coordinator). It never touches
// its own membership (no removal, disable or demotion of itself) nor another
// coordinator member, and never grants the coordinator role. member_set then
// requires the Bridge-observed live child for an enabled row and keeps an
// instance in one chain for life. Caller holds the Store mutex.
agent_member_admit :: proc(s:^Store,chain:string,p:json.Object,agent:Child) -> string {
    instance:=field(p,"instance_id")
    if instance==agent.instance || field(p,"agent_id")=="" || field(p,"role")=="coordinator" do return "invalid_scope"
    prior,ok:=query(s.db,"SELECT role,enabled FROM local_chain_member_versions WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,instance)
    if !ok do return "storage_error"
    if len(prior)==1 && prior[0][0]=="coordinator" && prior[0][1]=="1" do return "invalid_scope"
    return "ok"
}

// The chain's coordinator may start, stop and restart the instances of its
// own chain (members and fleet workers); it never stops itself. Read-only.
agent_instance_control :: proc(s:^Store,chain,target,verb:string,child:Child) -> string {
    tx:Transaction
    if !transaction_begin(s,&tx) do return "storage_error"
    defer transaction_rollback(&tx)
    role,code:=agent_authorize(s,chain,"",child,"fleet.instance")
    if role!=.Coordinator do return code if code!="ok" else "invalid_scope"
    if verb=="stop" && target==child.instance do return "invalid_scope"
    rows,ok:=query(s.db,"SELECT 1 FROM local_member_chains WHERE instance_id=?1 AND chain_id=?2 UNION ALL SELECT 1 FROM local_fleet WHERE instance_id=?1 AND chain_id=?2 LIMIT 1",target,chain)
    if !ok do return "storage_error"
    return "ok" if len(rows)>0 else "invalid_scope"
}

// The owner chains an instance belongs to on this Bridge (lifetime membership
// or fleet rows); normally zero or one. ok=false only on a storage failure.
agent_instance_chains :: proc(s:^Store,instance:string) -> ([]string,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=?1 UNION SELECT chain_id FROM local_fleet WHERE instance_id=?1",instance)
    if !ok do return nil,false
    out:=make([]string,len(rows),context.temp_allocator)
    for r,i in rows do out[i]=r[0]
    return out,true
}

// An enabled current member (latest version) or an enabled fleet worker of
// this chain. ok=false only on a storage failure.
agent_chain_participant :: proc(s:^Store,chain,instance:string) -> (bool,bool) {
    if instance=="" do return false,true
    rows,ok:=query(s.db,`SELECT 1 FROM local_chain_member_versions m WHERE chain_id=?1 AND instance_id=?2 AND enabled=1
      AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)
      UNION ALL SELECT 1 FROM local_fleet WHERE chain_id=?1 AND instance_id=?2 AND enabled=1 LIMIT 1`,chain,instance)
    if !ok do return false,false
    return len(rows)>0,true
}

// Instances that may be assigned in this chain (see agent_chain_participant).
agent_chain_participants :: proc(s:^Store,chain:string) -> ([]string,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,`SELECT instance_id FROM local_chain_member_versions m WHERE chain_id=?1 AND enabled=1
      AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)
      UNION SELECT instance_id FROM local_fleet WHERE chain_id=?1 AND enabled=1`,chain)
    if !ok do return nil,false
    out:=make([dynamic]string,context.temp_allocator)
    for r in rows do append(&out,r[0])
    return out[:],true
}

// The repository a coordinator may configure: the chain's single enabled
// directory, and its target branch from the chain defaults ("target_branch")
// or the latest Git configuration on that repository. No directory means
// merge_policy none.
Agent_Assignment_Template :: struct { merge_policy,directory_id,repository,target_branch:string }
agent_assignment_template :: proc(s:^Store,chain:string) -> (Agent_Assignment_Template,string) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return {},"storage_error"
    defer transaction_rollback(&tx)
    dirs,ok:=query(s.db,`SELECT directory_id,body FROM local_chain_directory_versions d WHERE chain_id=? AND enabled=1
      AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_directory_versions x WHERE x.chain_id=d.chain_id AND x.directory_id=d.directory_id)`,chain)
    if !ok do return {},"storage_error"
    if len(dirs)==0 do return Agent_Assignment_Template{merge_policy="none",directory_id="owner_none"},"ok"
    if len(dirs)>1 do return {},"ambiguous_directory"
    v,valid:=contracts.owner_content_document(dirs[0][1]);d,obj:=v.(json.Object)
    if !valid || !obj || field(d,"path")=="" do return {},"invalid_content"
    t:=Agent_Assignment_Template{"git",dirs[0][0],field(d,"path"),""}
    defaults,read:=query(s.db,"SELECT defaults_json FROM local_chain_defaults_versions WHERE chain_id=? ORDER BY accepted_seq DESC LIMIT 1",chain)
    if !read do return {},"storage_error"
    if len(defaults)==1 {
        dv,dvalid:=contracts.owner_content_document(defaults[0][0])
        if o,is_obj:=dv.(json.Object);dvalid && is_obj do t.target_branch=field(o,"target_branch")
    }
    if t.target_branch=="" {
        configs,cread:=query(s.db,"SELECT config_json FROM lifecycle_configs WHERE chain_id=? ORDER BY rowid DESC",chain)
        if !cread do return {},"storage_error"
        for row in configs {
            c,cvalid:=contracts.owner_parse(row[0],"lifecycle_config_payload")
            if cvalid && field(c,"merge_policy")=="git" && field(c,"repository")==t.repository { t.target_branch=field(c,"target_branch");break }
        }
    }
    if t.target_branch=="" || !contracts.owner_field_valid(t.target_branch,"optional_ref") do return {},"target_branch_required"
    return t,"ok"
}

// ---- lease.next: atomic next-ready discovery + claim --------------------

Lease_Pick :: struct {
    status:string, // "granted" | "current" | "none"
    chain_id,task_id,lease_id:string,
}

// Everything the claim path would refuse, checked before choosing a task, so
// one blocked task never hides the next ready one. execute_lease re-checks.
agent_claimable :: proc(s:^Store,chain,task:string,child:Child) -> bool {
    if !task_dispatchable(s,chain,task) do return false
    if config,binding,configured:=lifecycle_config(s,chain,task);configured {
        if child.agent_id!=field(config,"author_agent_id") || encode(child)!=binding[1] do return false
    }
    return true
}

// Everything a claim needs that does not depend on the claiming child: a
// local (not reserved) assignment, a published task of an active chain, ready
// controls, dependencies and lifecycle, and no live lease. Shared by
// agent_claimable and the owner Bridge matcher (work_targets).
task_dispatchable :: proc(s:^Store,chain,task:string) -> bool {
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
    if _,_,configured:=lifecycle_config(s,chain,task);configured {
        states,state_ok:=query(s.db,"SELECT state FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !state_ok || len(states)!=1 || states[0][0]!="ready" do return false
    }
    return true
}

// M1 matcher (origin/main taskv2 matcher.odin pick_instance): every ready,
// unleased task of a chain ("" = every chain) assigned to a worker member
// instance on this Bridge, with that member's durable agent id. The owner
// Bridge wakes the instance when it is live and restarts it when it stopped;
// a restarted launch reclaims the task by agent id (agent_restarted_bindings).
// Coordinators are never candidates (solo tasks are pulled by the coordinator
// itself). Read-only.
Work_Target :: struct { chain_id,task_id,instance_id,agent_id:string }
work_targets :: proc(s:^Store,chain:string) -> ([]Work_Target,bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return nil,false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,`SELECT f.chain_id,f.task_id,f.instance_id,m.agent_id,m.role,m.enabled FROM local_fleet f
      LEFT JOIN local_chain_member_versions m ON m.chain_id=f.chain_id AND m.instance_id=f.instance_id
        AND m.accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)
      WHERE f.enabled=1 AND (?1='' OR f.chain_id=?1)
        AND NOT EXISTS(SELECT 1 FROM local_leases l WHERE l.chain_id=f.chain_id AND l.task_id=f.task_id AND l.retired_seq IS NULL)
      ORDER BY f.chain_id,f.task_id LIMIT 500`,chain)
    if !ok do return nil,false
    out:=make([dynamic]Work_Target,context.temp_allocator)
    for r in rows {
        if r[3]=="" || r[4]=="coordinator" || r[5]!="1" do continue
        if !task_dispatchable(s,r[0],r[1]) do continue
        append(&out,Work_Target{r[0],r[1],r[2],r[3]})
    }
    return out[:],true
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
    brief:string,
    fleet_instance,fleet_revision,fleet_enabled:string,
    config_max_revision:string,
    dependencies:[]string,
    config:json.Object,
    configured:bool,
}

// Resolve a task (chain optional) known to this owner store. ok=false means
// the store could not be read (busy or failed): never "not mine".
agent_task_state :: proc(s:^Store,chain,task:string) -> (st:Agent_Task_State,found:bool,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return {},false,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,"SELECT t.chain_id,t.task_id,t.revision,c.revision FROM tasks t JOIN task_chains c ON c.chain_id=t.chain_id WHERE t.task_id=? AND (?='' OR t.chain_id=?)",task,chain,chain)
    if !read do return {},false,false
    if len(rows)!=1 do return {},false,true
    st=Agent_Task_State{chain_id=rows[0][0],task_id=rows[0][1],task_revision=rows[0][2],chain_revision=rows[0][3]}
    if req,has:=lifecycle_requirements(s,st.chain_id,task);has { st.requirements_revision=req[0];st.brief=req[1] }
    st.config,_,st.configured=lifecycle_config(s,st.chain_id,task)
    if st.configured do st.configuration_revision=field(st.config,"configuration_revision")
    states,sread:=query(s.db,"SELECT l.state,l.attempt,COALESCE((SELECT head FROM local_submissions x WHERE x.chain_id=l.chain_id AND x.task_id=l.task_id AND x.attempt=l.attempt),'') FROM lifecycle_state l WHERE chain_id=? AND task_id=?",st.chain_id,task)
    if !sread do return {},false,false
    if len(states)==1 { st.state=states[0][0];st.attempt=states[0][1];st.head=states[0][2] }
    fleet,fread:=query(s.db,"SELECT instance_id,configuration_revision,enabled FROM local_fleet WHERE chain_id=? AND task_id=?",st.chain_id,task)
    if !fread do return {},false,false
    if len(fleet)==1 { st.fleet_instance=fleet[0][0];st.fleet_revision=fleet[0][1];st.fleet_enabled=fleet[0][2] }
    configs,cread:=query(s.db,"SELECT COALESCE(max(revision),0) FROM lifecycle_configs WHERE chain_id=? AND task_id=?",st.chain_id,task)
    if !cread do return {},false,false
    st.config_max_revision=configs[0][0]
    deps,dread:=query(s.db,"SELECT prerequisite FROM local_dependencies WHERE chain_id=? AND task_id=? ORDER BY prerequisite",st.chain_id,task)
    if !dread do return {},false,false
    list:=make([dynamic]string,context.temp_allocator)
    for d in deps do append(&list,d[0])
    st.dependencies=list[:]
    return st,true,true
}

// Chain revision for chain-scoped commands; found=false when this store does
// not hold the chain, ok=false when it could not be read.
agent_chain_revision :: proc(s:^Store,chain:string) -> (revision:string,found:bool,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return "",false,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !read do return "",false,false
    if len(rows)!=1 do return "",false,true
    return rows[0][0],true,true
}

// The chain this child acts on when a verb names none: its membership, its
// live lease or its enabled fleet rows (exactly one chain).
agent_home_chain :: proc(s:^Store,child:Child) -> string {
    tx:Transaction
    if !transaction_begin(s,&tx) do return ""
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=? UNION SELECT chain_id FROM local_leases WHERE instance_id=? AND retired_seq IS NULL UNION SELECT chain_id FROM local_fleet WHERE instance_id=? AND enabled=1",child.instance,child.instance,child.instance)
    if !ok || len(rows)!=1 do return ""
    return rows[0][0]
}

// Lease-verb routing: an enabled fleet row or a live lease of this instance.
// Disabled rows, membership and reviewer-only bindings do not count.
agent_lease_bound :: proc(s:^Store,instance:string) -> (bound:bool,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,`SELECT 1 FROM local_fleet WHERE instance_id=?1 AND enabled=1
      UNION ALL SELECT 1 FROM local_leases WHERE instance_id=?1 AND retired_seq IS NULL LIMIT 1`,instance)
    if !read do return false,false
    return len(rows)>0,true
}

// Chain-verb routing without ids: a current enabled member, an enabled fleet
// worker or a live lease holder of this store.
agent_bound :: proc(s:^Store,instance:string) -> (bound:bool,ok:bool) {
    tx:Transaction
    if !transaction_begin(s,&tx) do return false,false
    defer transaction_rollback(&tx)
    rows,read:=query(s.db,`SELECT 1 FROM local_fleet WHERE instance_id=?1 AND enabled=1
      UNION ALL SELECT 1 FROM local_leases WHERE instance_id=?1 AND retired_seq IS NULL
      UNION ALL SELECT 1 FROM local_chain_member_versions m WHERE instance_id=?1 AND enabled=1
        AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) LIMIT 1`,instance)
    if !read do return false,false
    return len(rows)>0,true
}
