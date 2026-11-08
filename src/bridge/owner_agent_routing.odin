#+feature dynamic-literals
package main

// R4a: transparent agent verbs on owner chains.
//
// The ordinary agent API (`ham-ctl lease|task|review|task-chain ...`) reaches
// the Bridge as agent.<domain>.<verb>. Before the Hub route table runs, this
// file asks: does THIS Bridge own the target chain? If so the verb is served
// by the owner store, authorized by the one policy in
// lib/owner_local/agent_authority.odin, and signed with the owner key on the
// proven child's behalf — exactly like bridge_owner_agent does for the
// hand-built owner-local lease path. Otherwise the request falls through to
// the Hub unchanged; for a chain held by another owner the Hub answers a typed
// owner_authority error naming that Bridge.
//
// No agent ever supplies a capability, lease JSON or child identity.

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// The agent methods that are served by the owner store when the owner holds
// the target chain. Everything else always goes to the Hub.
bridge_owner_routable :: proc(method:string) -> bool {
    switch method {
    case "agent.lease.next","agent.lease.heartbeat","agent.lease.submit","agent.lease.handoff","agent.lease.switch","agent.lease.block",
         "agent.review.post","agent.task.show","agent.task.comments","agent.task.comment","agent.task.create","agent.task.update","agent.task.depend",
         "agent.task_chain.show","agent.task_chain.set_summary","agent.chain.summary","agent.task_chain.propose","agent.chain.propose","agent.task_chain.publish":
        return true
    }
    return false
}

// Lease verbs act on the caller's own lease and name no chain.
bridge_owner_lease_method :: proc(method:string) -> bool {
    return strings.has_prefix(method,"agent.lease.")
}

bridge_owner_fresh_id :: proc(prefix:string) -> string {
    raw:[12]byte
    crypto.rand_bytes(raw[:])
    return fmt.tprintf("%s_%s",prefix,vault.hex_encode_lower(raw[:],context.temp_allocator))
}

bridge_owner_store_path :: proc(account:string) -> string {
    dir,ok:=bridge_vault_bridge_dir(bridge_config.daemon_id,context.temp_allocator)
    if !ok do return ""
    return fmt.tprintf("%sowner-local-%s/runtime.sqlite",dir,contracts.owner_payload_digest(account))
}

bridge_owner_params :: proc(raw:string) -> json.Object {
    trimmed:=strings.trim_space(raw)
    if trimmed=="" do return make(json.Object,context.temp_allocator)
    value,err:=json.parse_string(trimmed,.JSON,true,context.temp_allocator)
    o,is_object:=value.(json.Object)
    if err!=.None || !is_object do return make(json.Object,context.temp_allocator)
    return o
}
bridge_owner_pstr :: proc(o:json.Object,key:string) -> string {
    #partial switch v in o[key] {
    case json.String: return strings.trim_space(string(v))
    case json.Integer: return fmt.tprintf("%d",v)
    case json.Float: return fmt.tprintf("%d",i64(v))
    }
    return ""
}
bridge_owner_pobj :: proc(o:json.Object,key:string) -> json.Object {
    v,_:=o[key].(json.Object)
    return v
}

// The context every owner verb runs in; built under the owner, startup and
// token locks after the exact child is proven.
Owner_Agent_Ctx :: struct {
    request_id:string,
    store:^owner.Store,
    child:owner.Child,
    key:contracts.Owner_Verified_Key,
    kr:^vault.Vault_Keyring,
    run_dir:string,
    now:i64,
    // Checkout + TASK.md delivery, finished after the child locks are released.
    pending:Owner_Pending_Delivery,
}

// A claim/switch commits and presents requirements under the child locks;
// the Git worktree and TASK.md are materialized afterwards (no git I/O under
// the startup/token mutexes). A failure is reported to the caller and on
// TASK.md; the next `lease next` (status current) retries it.
Owner_Pending_Delivery :: struct {
    active:bool,
    config:json.Object,
    configured:bool,
    task:string,
    command:json.Object,
    present_body:string,
    next:Owner_Agent_Next,
}

// Returns handled=false when this Bridge does not own the target, so the
// caller continues with the Hub route.
bridge_owner_agent_route :: proc(request_id,method,params:string,rec:Bridge_Local_Agent_Token_Record) -> (string,bool) {
    if rec.role!=.Agent || !bridge_owner_routable(method) do return "",false
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    if account=="" do return "",false
    pub:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(pub,context.temp_allocator)
    if !key_ok do return "",false
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    // Never create an owner store just to answer "not mine".
    if bridge_owner_store.db==nil {
        path:=bridge_owner_store_path(account)
        if path=="" || !os.exists(path) do return "",false
    }
    // The store exists: an unreadable or busy store is an owner failure,
    // never a reason to send the verb to the Hub.
    if !bridge_owner_open(account,key_id) do return bridge_local_response_error(request_id,"storage_error","owner store unavailable"),true
    p:=bridge_owner_params(params)
    owned,read:=bridge_owner_targets(&bridge_owner_store,method,p,rec.agent_instance_id)
    if !read do return bridge_local_response_error(request_id,"storage_error","owner store could not be read; retry"),true
    if !owned do return "",false
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return bridge_local_response_error(request_id,"vault_locked","owner Bridge vault is locked"),true
    key:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,key_id,pub,"bridge",true,false}
    response,pending,run_dir:=bridge_owner_agent_route_child(request_id,method,p,rec,key,&kr)
    if pending.active {
        block:string
        response,block=bridge_owner_materialize_checked(request_id,pending,run_dir)
        if block!="" do response=bridge_owner_block_unavailable_worktree(request_id,pending,rec,key,&kr,block)
    }
    // Registry publication and merge intents run after the child locks are
    // released, under the owner mutex only (as bridge_owner_handle does).
    bridge_owner_publish()
    return response,true
}

// Lock order owner -> startup I/O -> token, as bridge_owner_agent: stop,
// rotation and relaunch cannot race admission after exact-child validation.
bridge_owner_agent_route_child :: proc(request_id,method:string,p:json.Object,rec:Bridge_Local_Agent_Token_Record,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring) -> (string,Owner_Pending_Delivery,string) {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    if !current do return bridge_local_response_error(request_id,"invalid_scope","owner chain: current launched child required"),{},""
    run_dir:=""
    if launch,launched:=bridge_runtime_get_launch(child.instance);launched do run_dir=strings.clone(launch.run_dir,context.temp_allocator)
    ctx:=Owner_Agent_Ctx{request_id=request_id,store=&bridge_owner_store,child=child,key=key,kr=kr,run_dir=run_dir,now=time.to_unix_nanoseconds(time.now())/1000000}
    response:=bridge_owner_agent_exec(&ctx,method,p)
    return response,ctx.pending,run_dir
}

// Whether the verb's target lives in this owner store. read=false means the
// store could not be read; the caller must fail rather than fall through.
bridge_owner_targets :: proc(s:^owner.Store,method:string,p:json.Object,instance:string) -> (owned:bool,read:bool) {
    chain,task:=bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id")
    // Lease verbs follow the caller's own enabled fleet rows and live lease.
    if bridge_owner_lease_method(method) && method!="agent.lease.switch" do return owner.agent_lease_bound(s,instance)
    if task!="" {
        _,found,ok:=owner.agent_task_state(s,chain,task)
        return found,ok
    }
    if chain!="" {
        _,found,ok:=owner.agent_chain_revision(s,chain)
        return found,ok
    }
    // No ids: the agent's own chain context (member, worker or lease holder).
    return owner.agent_bound(s,instance)
}

bridge_owner_fail :: proc(ctx:^Owner_Agent_Ctx,code,message:string) -> string {
    return bridge_local_response_error(ctx.request_id,code,message)
}
bridge_owner_signer :: proc() -> owner.Signer { return owner.Signer{nil,bridge_owner_sign} }

// Lease and lifecycle inputs are signed exactly like bridge_owner_agent does.
bridge_owner_run_input :: proc(ctx:^Owner_Agent_Ctx,method,chain,task,lease,configuration,expected,capability,payload:string) -> owner.Result {
    lifecycle:=method!="lease.claim" && method!="lease.heartbeat"
    command:=make(json.Object,context.temp_allocator)
    s:=ctx.store
    values:=map[string]string{"protocol_version"="1","chain_id"=chain,"task_id"=task,"lease_id"=lease,"configuration_revision"=configuration,
        "expected_revision"=expected,"operation_id"=bridge_owner_fresh_id("op"),"method"=method,"request_expires_ms"=fmt.tprintf("%d",ctx.now+60000),
        "capability_digest"=contracts.owner_payload_digest(capability),"account_id"=s.account,"owner_bridge_id"=s.owner,
        "instance_id"=ctx.child.instance,"launch_epoch"=ctx.child.epoch,"run_count"=fmt.tprintf("%d",ctx.child.run_count),
        "token_generation"=ctx.child.token_generation,"key_id"=s.owner_key,"signature"=strings.repeat("0",128,context.temp_allocator)}
    defer delete(values)
    for k,v in values do command[k]=json.String(v)
    kind:="lease_command"
    if lifecycle {
        kind="lifecycle_command"
        command["payload_digest"]=json.String(contracts.owner_payload_digest(payload))
    }
    signature,signed:=bridge_owner_sign(nil,kind,command)
    if !signed do return owner.Result{code="storage_error"}
    command["signature"]=json.String(signature)
    if lifecycle {
        proof:=bridge_owner_source_proof(s,chain,task)
        return owner.execute_lifecycle(s,bridge_owner_json(command),payload,capability,ctx.child,ctx.key,ctx.now,bridge_owner_signer(),proof)
    }
    return owner.execute_lease(s,bridge_owner_json(command),capability,ctx.child,ctx.key,ctx.now,bridge_owner_signer())
}

// Coordinator (or own-task worker) commands, signed by the owner key for the
// proven child; owner.execute applies agent_command_admit.
bridge_owner_run_command :: proc(ctx:^Owner_Agent_Ctx,method,chain,task,expected,payload:string,fleet_child:owner.Child={},proof:owner.Lifecycle_Proof={}) -> owner.Result {
    s:=ctx.store
    c:=make(json.Object,context.temp_allocator)
    values:=map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=chain,"immutable_owner_bridge"=s.owner,
        "principal_id"=ctx.child.instance,"operation_id"=bridge_owner_fresh_id("op"),"method"=method,"task_id"=task,"expected_revision"=expected,
        "request_expires_ms"=fmt.tprintf("%d",ctx.now+60000),"payload_digest"=contracts.owner_payload_digest(payload),"key_id"=s.owner_key,
        "signature"=strings.repeat("0",128,context.temp_allocator)}
    defer delete(values)
    for k,v in values do c[k]=json.String(v)
    signature,signed:=bridge_owner_sign(nil,"command",c)
    if !signed do return owner.Result{code="storage_error"}
    c["signature"]=json.String(signature)
    return owner.execute_agent(s,bridge_owner_json(c),payload,ctx.child,ctx.key,ctx.now,ctx.kr,bridge_owner_signer(),fleet_child,proof)
}

// A vault-armored value from ham-ctl is already a cipher under this account's
// keyring; plaintext is sealed here.
bridge_owner_cipher :: proc(ctx:^Owner_Agent_Ctx,value:string) -> (string,bool) {
    if _,_,_,parsed:=vault.envelope_parse(value,context.temp_allocator);parsed==.Ok {
        if _,opened:=vault.open(value,ctx.kr,context.temp_allocator);opened==.Ok do return value,true
        return "",false
    }
    sealed,ok:=vault.seal_string(value,ctx.kr,context.temp_allocator)
    return sealed,ok
}
bridge_owner_plain :: proc(ctx:^Owner_Agent_Ctx,value:string) -> string {
    if _,_,_,parsed:=vault.envelope_parse(value,context.temp_allocator);parsed==.Ok {
        if plain,opened:=vault.open(value,ctx.kr,context.temp_allocator);opened==.Ok do return plain
    }
    return value
}
bridge_owner_result_object :: proc(body:string) -> json.Object {
    value,_:=json.parse_string(body,.JSON,true,context.temp_allocator)
    o,_:=value.(json.Object)
    if o==nil do o=make(json.Object,context.temp_allocator)
    return o
}

Owner_Agent_Placement :: struct { workdir,directory_path,branch:string }
Owner_Agent_Lease :: struct {
    lease_id,task_id,chain_id,requirements_revision,acknowledged:string,
    placement:Owner_Agent_Placement,
}
Owner_Agent_Task_Ref :: struct { task_id,chain_id:string }
Owner_Agent_Authority :: struct { kind,bridge_id:string }
Owner_Agent_Next :: struct {
    status:string,
    lease:Maybe(Owner_Agent_Lease) `json:"lease,omitempty"`,
    task:Maybe(Owner_Agent_Task_Ref) `json:"task,omitempty"`,
    authority:Owner_Agent_Authority,
}
bridge_owner_authority :: proc() -> Owner_Agent_Authority { return {"owner",bridge_config.daemon_id} }

bridge_owner_placement :: proc(config:json.Object,configured:bool) -> Owner_Agent_Placement {
    if !configured || contracts.owner_string(config,"merge_policy")!="git" do return {}
    return {contracts.owner_string(config,"worktree"),contracts.owner_string(config,"repository"),contracts.owner_string(config,"source_branch")}
}

// Every component of <repo>/.heimdall/worktrees/<task> must be absent or a
// real directory (lstat, never a symlink) before anything is created there.
bridge_owner_worktree_path_safe :: proc(repo,task:string) -> bool {
    if repo=="" || !contracts.owner_field_valid(task,"id") do return false
    parts:=[3]string{fmt.tprintf("%s/.heimdall",repo),fmt.tprintf("%s/.heimdall/worktrees",repo),fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task)}
    for path in parts {
        info,err:=os.lstat(path,context.temp_allocator)
        if err!=nil {
            if os.exists(path) do return false // present but unreadable
            return true // this and every deeper component are absent
        }
        if info.type!=.Directory do return false
    }
    return true
}

// Why a task worktree could not be materialized. Deterministic failures (the
// path is squatted by a non-checkout, a symlink, a checkout on another branch,
// an inconsistent configuration) never fix themselves on retry; the rest may.
Owner_Worktree_Status :: enum { Ok, Retry, Deterministic }

// Creates repo/.heimdall/worktrees/<task> on branch heimdall/<task> from the
// configured base when it is missing (claim parity with the Hub path). An
// existing checkout must be exactly that worktree on exactly that branch.
// Called only after the owner admitted the claim, without the child locks.
bridge_owner_ensure_worktree :: proc(config:json.Object,task:string) -> bool {
    status,_:=bridge_owner_prepare_worktree(config,task)
    return status==.Ok
}
bridge_owner_prepare_worktree :: proc(config:json.Object,task:string) -> (Owner_Worktree_Status,string) {
    get:=contracts.owner_string
    if get(config,"merge_policy")!="git" do return .Ok,""
    repo,work,branch,base:=get(config,"repository"),get(config,"worktree"),get(config,"source_branch"),get(config,"base_head")
    if repo=="" || work!=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task) || branch!=fmt.tprintf("heimdall/%s",task) || !contracts.owner_field_valid(base,"optional_commit") || base=="" {
        return .Deterministic,"the lifecycle configuration does not name repo/.heimdall/worktrees/<task> on heimdall/<task> with a base commit"
    }
    if !bridge_owner_worktree_path_safe(repo,task) do return .Deterministic,fmt.tprintf("a component of %s is a symlink or not a directory",work)
    if os.exists(work) {
        if !bridge_taskv2_is_checkout_root(work) do return .Deterministic,fmt.tprintf("%s exists but is not a git worktree checkout",work)
        current,stderr,ok,timed_out:=bridge_owner_git_capture(work,[]string{"symbolic-ref","--short","HEAD"})
        if !ok {
            // Only a git that ran and reported a non-symbolic HEAD which still
            // resolves to a commit is a detached HEAD. A spawn failure, a
            // timeout, or an unreadable repository may fix itself: retry.
            if timed_out || stderr=="" do return .Retry,fmt.tprintf("git could not read HEAD of %s (not started or timed out)",work)
            if _,resolved:=bridge_owner_git(work,[]string{"rev-parse","--verify","--quiet","HEAD^{commit}"});resolved {
                return .Deterministic,fmt.tprintf("%s is on a detached HEAD, not branch %s",work,branch)
            }
            return .Retry,fmt.tprintf("git could not read HEAD of %s: %s",work,stderr)
        }
        if current!=branch do return .Deterministic,fmt.tprintf("%s is checked out on branch %s, not %s",work,current,branch)
        return .Ok,""
    }
    if top,ok:=bridge_owner_git(repo,[]string{"rev-parse","--show-toplevel"});!ok || top!=repo do return .Retry,fmt.tprintf("%s is not readable as the top of a git repository",repo)
    bridge_taskv2_exclude_worktrees(repo)
    _,_=bridge_owner_git(repo,[]string{"worktree","prune"})
    for dir in ([2]string{fmt.tprintf("%s/.heimdall",repo),fmt.tprintf("%s/.heimdall/worktrees",repo)}) {
        if !os.exists(dir) && os.make_directory(dir)!=nil do return .Retry,fmt.tprintf("could not create %s",dir)
    }
    // Re-check after creation: nothing may have been swapped for a symlink.
    if !bridge_owner_worktree_path_safe(repo,task) || os.exists(work) do return .Deterministic,fmt.tprintf("%s changed while it was being created (symlink or squatting path)",work)
    added:bool
    if bridge_taskv2_branch_exists(repo,branch) {
        _,added=bridge_owner_git(repo,[]string{"worktree","add",work,branch})
    } else {
        _,added=bridge_owner_git(repo,[]string{"worktree","add","-b",branch,work,base})
    }
    if !added || !bridge_taskv2_is_checkout_root(work) do return .Retry,fmt.tprintf("git worktree add %s (%s) failed",work,branch)
    return .Ok,""
}

// Under the child locks: present requirements after a claim (or for the
// current lease) and record what remains to materialize.
bridge_owner_deliver :: proc(ctx:^Owner_Agent_Ctx,st:owner.Agent_Lease_State,status:string) -> (string,string) {
    out:=Owner_Agent_Lease{lease_id=st.lease_id,task_id=st.task_id,chain_id=st.chain_id,requirements_revision=st.requirements_revision,acknowledged="0"}
    out.placement=bridge_owner_placement(st.config,st.configured)
    next:=Owner_Agent_Next{status,out,Owner_Agent_Task_Ref{st.task_id,st.chain_id},bridge_owner_authority()}
    if !st.configured {
        ctx.pending=Owner_Pending_Delivery{active=false,next=next}
        return "ok",""
    }
    payload:=fmt.tprintf(`{{"requirements_revision":"%s"}}`,st.requirements_revision)
    r:=bridge_owner_run_input(ctx,"requirements.present",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,payload)
    if r.code!="ok" do return r.code,"requirements could not be presented"
    out.acknowledged=contracts.owner_string(bridge_owner_result_object(r.body),"acknowledged")
    next.lease=out
    command:=owner.doc(map[string]string{"chain_id"=st.chain_id,"task_id"=st.task_id,"lease_id"=st.lease_id,"instance_id"=ctx.child.instance,
        "workdir"=out.placement.workdir,"branch"=out.placement.branch})
    ctx.pending=Owner_Pending_Delivery{true,st.config,st.configured,st.task_id,command,r.body,next}
    return "ok",""
}

// Consecutive worktree failures per lease (guarded by bridge_owner_mutex,
// which the agent route holds while materializing).
OWNER_WORKTREE_MAX_FAILURES :: 3
bridge_owner_worktree_failures:map[string]int

// After the child locks: the Git worktree, then TASK.md (which names the
// Workdir, or says why it is unavailable). The lease is committed either way;
// a failure is reported now and retried by the next `lease next`.
bridge_owner_materialize :: proc(request_id:string,pending:Owner_Pending_Delivery,run_dir:string) -> string {
    response,_:=bridge_owner_materialize_checked(request_id,pending,run_dir)
    return response
}
// block is non-empty when the lease must be blocked instead of retried: the
// failure is deterministic, or this is the OWNER_WORKTREE_MAX_FAILURES-th
// consecutive failure for the lease.
bridge_owner_materialize_checked :: proc(request_id:string,pending:Owner_Pending_Delivery,run_dir:string) -> (response,block:string) {
    command:=pending.command
    lease:=contracts.owner_string(command,"lease_id")
    status,reason:=bridge_owner_prepare_worktree(pending.config,pending.task)
    failures:=0
    if status==.Ok {
        bridge_owner_worktree_failure_reset(lease)
    } else {
        failures=bridge_owner_worktree_failure_record(lease)
        work:=contracts.owner_string(pending.config,"worktree")
        if status==.Deterministic || failures>=OWNER_WORKTREE_MAX_FAILURES {
            why:="this will not fix itself on retry" if status==.Deterministic else fmt.tprintf("%d consecutive attempts failed",failures)
            block=fmt.tprintf("task Workdir %s unavailable: %s (%s); fix the repository or worktree, then release the task",work,reason,why)
            bridge_owner_worktree_failure_reset(lease)
        }
        command["workdir"]=json.String("")
        command["workdir_error"]=json.String(fmt.tprintf("could not create or verify %s: %s",work,reason))
    }
    written:=run_dir!="" && bridge_owner_materialize_context(run_dir,command,pending.present_body)
    if status!=.Ok {
        if block!="" do return bridge_local_response_error(request_id,"worktree_unavailable",fmt.tprintf("%s; the lease is being blocked (waiting on human) so the coordinator is told",block)),block
        return bridge_local_response_error(request_id,"worktree_unavailable",fmt.tprintf("lease held; the task Workdir could not be created or verified (%s; attempt %d of %d, see TASK.md); run lease next again to retry",reason,failures,OWNER_WORKTREE_MAX_FAILURES)),""
    }
    if !written do return bridge_local_response_error(request_id,"context_delivery_failed","lease held and requirements presented; TASK.md write failed; run lease next again"),""
    return bridge_local_response_data(request_id,bridge_owner_json(pending.next)),""
}
bridge_owner_worktree_failure_record :: proc(lease:string) -> int {
    context.allocator=runtime.heap_allocator() // process-lifetime map, whatever the caller allocates with
    if bridge_owner_worktree_failures==nil do bridge_owner_worktree_failures=make(map[string]int)
    if count,found:=bridge_owner_worktree_failures[lease];found {
        bridge_owner_worktree_failures[lease]=count+1
        return count+1
    }
    // Bounded: a lease that vanished between failures never pins memory.
    if len(bridge_owner_worktree_failures)>=256 do bridge_owner_worktree_failure_clear()
    bridge_owner_worktree_failures[strings.clone(lease)]=1
    return 1
}
bridge_owner_worktree_failure_reset :: proc(lease:string) {
    context.allocator=runtime.heap_allocator() // process-lifetime map, whatever the caller allocates with
    if lease in bridge_owner_worktree_failures {
        key,_:=delete_key(&bridge_owner_worktree_failures,lease)
        delete(key)
    }
}
bridge_owner_worktree_failure_clear :: proc() {
    context.allocator=runtime.heap_allocator() // process-lifetime map, whatever the caller allocates with
    for key in bridge_owner_worktree_failures do delete(key)
    clear(&bridge_owner_worktree_failures)
}

// Blocks the caller's current lease after an unrecoverable worktree failure
// (lease.block waiting on human with the reason), so the task leaves the
// claim loop and shows as blocked to the coordinator. Takes the startup and
// token locks again (lock order owner -> startup I/O -> token; the caller
// holds the owner mutex) and re-proves the exact child and lease.
bridge_owner_block_unavailable_worktree :: proc(request_id:string,pending:Owner_Pending_Delivery,rec:Bridge_Local_Agent_Token_Record,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,reason:string) -> string {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    if !current do return bridge_local_response_error(request_id,"worktree_unavailable",fmt.tprintf("%s; the lease could not be blocked (the caller is no longer the current child)",reason))
    ctx:=Owner_Agent_Ctx{request_id=request_id,store=&bridge_owner_store,child=child,key=key,kr=kr,now=time.to_unix_nanoseconds(time.now())/1000000}
    st,has:=owner.agent_lease_state(ctx.store,child)
    if !has || st.lease_id!=contracts.owner_string(pending.command,"lease_id") do return bridge_local_response_error(request_id,"worktree_unavailable",fmt.tprintf("%s; the lease is no longer held, nothing to block",reason))
    payload:=bridge_owner_json(map[string]string{"requirements_revision"=st.requirements_revision,"summary"=reason,
        "next_steps"="fix the task repository/worktree on the owner Bridge, then release the task so it can be claimed again","waiting_on"="human"})
    r:=bridge_owner_run_input(&ctx,"lease.block",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,payload)
    if r.code!="ok" do return bridge_local_response_error(request_id,"worktree_unavailable",fmt.tprintf("%s; blocking the lease was refused (%s), it stays held",reason,r.code))
    return bridge_local_response_error(request_id,"worktree_unavailable",fmt.tprintf("%s; the lease was blocked (waiting on human) and the coordinator must resolve it",reason))
}

bridge_owner_agent_exec :: proc(ctx:^Owner_Agent_Ctx,method:string,p:json.Object) -> string {
    s:=ctx.store
    switch method {
    case "agent.lease.next":
        peek:=false
        if b,ok:=p["peek"].(json.Boolean);ok do peek=bool(b)
        if peek {
            st,has:=owner.agent_lease_state(s,ctx.child)
            if !has do return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{status="none",authority=bridge_owner_authority()}))
            lease:=Owner_Agent_Lease{lease_id=st.lease_id,task_id=st.task_id,chain_id=st.chain_id,requirements_revision=st.requirements_revision,placement=bridge_owner_placement(st.config,st.configured)}
            return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{"current",lease,Owner_Agent_Task_Ref{st.task_id,st.chain_id},bridge_owner_authority()}))
        }
        _=owner.expire_leases(s,ctx.now)
        r,pick:=owner.lease_next(s,ctx.child,ctx.key,ctx.now,bridge_owner_signer(),bridge_owner_fresh_id("lease"),bridge_owner_fresh_id("op"))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner lease next refused")
        if pick.status=="none" do return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{status="none",authority=bridge_owner_authority()}))
        st,has:=owner.agent_lease_state(s,ctx.child)
        if !has do return bridge_owner_fail(ctx,"lease_lost","lease vanished after claim")
        code,message:=bridge_owner_deliver(ctx,st,pick.status)
        if code!="ok" do return bridge_owner_fail(ctx,code,message)
        if !ctx.pending.active do return bridge_local_response_data(ctx.request_id,bridge_owner_json(ctx.pending.next))
        return ""
    case "agent.lease.heartbeat","agent.lease.submit","agent.lease.handoff","agent.lease.block","agent.lease.switch":
        return bridge_owner_lease_verb(ctx,method,p)
    case "agent.review.post":
        return bridge_owner_review(ctx,p)
    case "agent.task.show","agent.task.comments":
        st,missing:=bridge_owner_task(ctx,p)
        if missing!="" do return missing
        limit:="100"
        if last:=bridge_owner_pstr(p,"last");last!="" {
            n,parsed:=strconv.parse_int(last)
            if !parsed || n<1 do return bridge_owner_fail(ctx,"bad_request","--last must be a positive number")
            limit=fmt.tprintf("%d",min(n,100))
        }
        r:=bridge_owner_run_command(ctx,"task.read",st.chain_id,st.task_id,"0",fmt.tprintf(`{{"cursor":"","limit":"%s"}}`,limit))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner task read refused")
        read:=bridge_owner_result_object(r.body)
        Task_Show :: struct {
            task:struct{task_id,chain_id,title,body,priority,state,attempt,requirements_revision,revision:string},
            comments:json.Value,
            authority:Owner_Agent_Authority,
        }
        out:Task_Show
        out.task={st.task_id,st.chain_id,contracts.owner_string(read,"title"),contracts.owner_string(read,"body"),contracts.owner_string(read,"priority"),st.state,st.attempt,st.requirements_revision,st.task_revision}
        out.comments=read["items"]
        out.authority=bridge_owner_authority()
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
    case "agent.task.comment":
        if unsupported:=bridge_owner_unsupported(ctx,p,"notify","--notify");unsupported!="" do return unsupported
        st,missing:=bridge_owner_task(ctx,p)
        if missing!="" do return missing
        body,sealed:=bridge_owner_cipher(ctx,bridge_owner_pstr(p,"body"))
        if !sealed || bridge_owner_pstr(p,"body")=="" do return bridge_owner_fail(ctx,"bad_request","comment requires a body")
        r:=bridge_owner_run_command(ctx,"task.comment",st.chain_id,st.task_id,st.task_revision,bridge_owner_json(map[string]string{"body_cipher"=body}))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner comment refused")
        return bridge_local_response_data(ctx.request_id,r.body)
    case "agent.task.create":
        return bridge_owner_task_create(ctx,p)
    case "agent.task.update":
        return bridge_owner_task_update(ctx,p)
    case "agent.task.depend":
        st,missing:=bridge_owner_task(ctx,p)
        if missing!="" do return missing
        prerequisite:=bridge_owner_pstr(p,"depends_on_task_id")
        if prerequisite=="" do return bridge_owner_fail(ctx,"bad_request","task depend requires --on <task_id>")
        if code,message:=bridge_owner_dependency(ctx,st,prerequisite,true);code!="ok" do return bridge_owner_fail(ctx,code,message)
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(map[string]string{"task_id"=st.task_id,"chain_id"=st.chain_id,"depends_on_task_id"=prerequisite}))
    case "agent.task_chain.show":
        chain:=bridge_owner_pstr(p,"chain_id")
        if chain=="" do chain=owner.agent_home_chain(s,ctx.child)
        r:=bridge_owner_run_command(ctx,"chain.read",chain,"","0",`{"cursor":"","limit":"100"}`)
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner chain read refused")
        read:=bridge_owner_result_object(r.body)
        read["authority"]=json.Object{"kind"=json.String("owner"),"bridge_id"=json.String(bridge_config.daemon_id)}
        read["tasks"]=read["items"]
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(read))
    case "agent.task_chain.set_summary","agent.chain.summary":
        chain:=bridge_owner_pstr(p,"chain_id")
        if chain=="" do chain=owner.agent_home_chain(s,ctx.child)
        summary,sealed:=bridge_owner_cipher(ctx,bridge_owner_pstr(p,"summary"))
        if !sealed || bridge_owner_pstr(p,"summary")=="" do return bridge_owner_fail(ctx,"bad_request","summary set requires text")
        r:=bridge_owner_run_command(ctx,"chain.summary.set",chain,"",bridge_owner_chain_rev(ctx,chain),bridge_owner_json(map[string]string{"body_cipher"=summary}))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner summary refused")
        return bridge_local_response_data(ctx.request_id,r.body)
    case "agent.task_chain.propose","agent.chain.propose","agent.task_chain.publish":
        chain:=bridge_owner_pstr(p,"chain_id")
        if chain=="" do chain=owner.agent_home_chain(s,ctx.child)
        method_name:="chain.publish"
        body:="{}"
        if method!="agent.task_chain.publish" {
            method_name="chain.propose"
            plan:=make(json.Object,context.temp_allocator)
            for k,v in p do if k!="chain_id" do plan[k]=v
            body=bridge_owner_json(plan)
        }
        cipher,sealed:=bridge_owner_cipher(ctx,body)
        if !sealed do return bridge_owner_fail(ctx,"vault_locked","cannot seal the proposal")
        r:=bridge_owner_run_command(ctx,method_name,chain,"",bridge_owner_chain_rev(ctx,chain),bridge_owner_json(map[string]string{"body_cipher"=cipher}))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner chain command refused")
        return bridge_local_response_data(ctx.request_id,r.body)
    }
    return bridge_owner_fail(ctx,"bad_request","unsupported owner verb")
}

bridge_owner_lease_verb :: proc(ctx:^Owner_Agent_Ctx,method:string,p:json.Object) -> string {
    s:=ctx.store
    st,has:=owner.agent_lease_state(s,ctx.child)
    if !has do return bridge_owner_fail(ctx,"lease_lost","no live owner lease for this agent; run lease next")
    if lease:=bridge_owner_pstr(p,"lease_id");lease!="" && lease!=st.lease_id do return bridge_owner_fail(ctx,"lease_lost","that lease is no longer yours; run lease next")
    requirements:=bridge_owner_pstr(p,"requirements_revision")
    if requirements=="" do requirements=st.requirements_revision
    summary:=bridge_owner_pstr(p,"summary")
    handoff:=bridge_owner_pobj(p,"handoff")
    next_steps:=bridge_owner_pstr(handoff,"next_steps")
    switch method {
    case "agent.lease.heartbeat":
        acknowledged:=""
        if ack:=bridge_owner_pstr(p,"acknowledge_requirements_revision");ack!="" {
            r:=bridge_owner_run_input(ctx,"requirements.ack",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,fmt.tprintf(`{{"requirements_revision":"%s"}}`,ack))
            if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"requirements acknowledgement refused; read TASK.md for the current revision")
            acknowledged=ack
        }
        r:=bridge_owner_run_input(ctx,"lease.heartbeat",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,"")
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner heartbeat refused")
        out:=bridge_owner_result_object(r.body)
        delete_key(&out,"capability")
        out["task_id"]=json.String(st.task_id);out["chain_id"]=json.String(st.chain_id)
        if acknowledged!="" do out["acknowledged_requirements_revision"]=json.String(acknowledged)
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
    case "agent.lease.submit":
        if summary=="" do return bridge_owner_fail(ctx,"bad_request","lease submit requires --summary")
        head:=""
        if st.configured && contracts.owner_string(st.config,"merge_policy")=="git" {
            proof:=bridge_owner_source_proof(s,st.chain_id,st.task_id)
            if !proof.valid do return bridge_owner_fail(ctx,"worktree_not_clean",fmt.tprintf("commit your work in %s first (the worktree must be clean and descend from the base)",contracts.owner_string(st.config,"worktree")))
            head=proof.head
        }
        payload:=map[string]string{"requirements_revision"=requirements,"head"=head,"summary"=summary}
        defer delete(payload)
        if output,has_output:=p["output"];has_output && output!=nil do payload["output"]=bridge_owner_json(output)
        r:=bridge_owner_run_input(ctx,"lease.submit",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,bridge_owner_json(payload))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner submit refused (acknowledge the current requirements revision first)")
        out:=bridge_owner_result_object(r.body)
        out["task_id"]=json.String(st.task_id);out["chain_id"]=json.String(st.chain_id)
        if head!="" {
            work:=contracts.owner_string(st.config,"worktree")
            dirty,_:=bridge_taskv2_git_dirty(work)
            files:=bridge_taskv2_git_files_json(work,contracts.owner_string(st.config,"base_head"));defer delete(files)
            vcs:=bridge_taskv2_vcs_object_json(head,dirty,files);defer delete(vcs)
            value,_:=json.parse_string(vcs,.JSON,true,context.temp_allocator)
            out["vcs"]=value
        }
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
    case "agent.lease.handoff":
        if summary=="" do return bridge_owner_fail(ctx,"bad_request","lease handoff requires --summary")
        payload:=bridge_owner_json(map[string]string{"requirements_revision"=requirements,"summary"=summary,"next_steps"=next_steps})
        r:=bridge_owner_run_input(ctx,"lease.handoff",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,payload)
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner handoff refused")
        return bridge_local_response_data(ctx.request_id,r.body)
    case "agent.lease.block":
        waiting:=bridge_owner_pobj(p,"waiting_on")
        kind:=bridge_owner_pstr(waiting,"kind")
        if summary=="" do summary=bridge_owner_pstr(waiting,"reason")
        if !contracts.owner_field_valid(kind,"id") || summary=="" do return bridge_owner_fail(ctx,"bad_request","lease block requires --waiting-on <kind> and --reason")
        payload:=bridge_owner_json(map[string]string{"requirements_revision"=requirements,"summary"=summary,"next_steps"=next_steps,"waiting_on"=kind})
        r:=bridge_owner_run_input(ctx,"lease.block",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,payload)
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner block refused")
        return bridge_local_response_data(ctx.request_id,r.body)
    case "agent.lease.switch":
        if summary=="" do return bridge_owner_fail(ctx,"bad_request","lease switch requires --summary")
        dst,found,read_ok:=owner.agent_task_state(s,"",bridge_owner_pstr(p,"task_id"))
        if !read_ok do return bridge_owner_fail(ctx,"storage_error","owner store could not be read")
        if !found do return bridge_owner_fail(ctx,"not_found","destination task not found on owner")
        fleet,read:=owner.query(s.db,"SELECT configuration_revision FROM local_fleet WHERE chain_id=? AND task_id=?",dst.chain_id,dst.task_id)
        if !read || len(fleet)!=1 do return bridge_owner_fail(ctx,"invalid_scope","destination is not assigned to you")
        dst_req:=dst.requirements_revision
        if dst_req=="" do dst_req="1"
        payload:=bridge_owner_json(map[string]string{"requirements_revision"=requirements,"summary"=summary,"next_steps"=next_steps,
            "destination_chain_id"=dst.chain_id,"destination_task_id"=dst.task_id,"destination_revision"=dst.task_revision,
            "destination_configuration_revision"=fleet[0][0],"destination_requirements_revision"=dst_req,"destination_lease_id"=bridge_owner_fresh_id("lease")})
        r:=bridge_owner_run_input(ctx,"lease.switch",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,payload)
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner switch refused")
        next,has_next:=owner.agent_lease_state(s,ctx.child)
        if !has_next do return bridge_local_response_data(ctx.request_id,r.body)
        code,message:=bridge_owner_deliver(ctx,next,"granted")
        if code!="ok" do return bridge_owner_fail(ctx,code,message)
        if !ctx.pending.active do return bridge_local_response_data(ctx.request_id,bridge_owner_json(ctx.pending.next))
        return ""
    }
    return bridge_owner_fail(ctx,"bad_request","unsupported lease verb")
}

// review post: the configured reviewer child opens its review capability and
// posts the bound verdict; --on-behalf-of user is the coordinator relaying the
// user's decision (never a substitute for the independent reviewer, and never
// the user's own approval: that is device-signed only).
bridge_owner_review :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    s:=ctx.store
    st,missing:=bridge_owner_task(ctx,p)
    if missing!="" do return missing
    verdict:=bridge_owner_pstr(p,"verdict")
    summary:=bridge_owner_pstr(p,"summary")
    if summary=="" do summary=fmt.tprintf("%s by %s",verdict,ctx.child.agent_id)
    if st.state!="in_review" do return bridge_owner_fail(ctx,"operation_conflict","task is not awaiting review")
    if attempt:=bridge_owner_pstr(p,"expected_attempt_no");attempt!="" && attempt!=st.attempt do return bridge_owner_fail(ctx,"stale_revision","a newer attempt is under review")
    if head:=bridge_owner_pstr(p,"expected_head");head!="" && head!=st.head do return bridge_owner_fail(ctx,"stale_revision","the submitted head changed")
    payload:=bridge_owner_json(map[string]string{"requirements_revision"=st.requirements_revision,"attempt"=st.attempt,"head"=st.head,"verdict"=verdict,"summary"=summary})
    if bridge_owner_pstr(p,"on_behalf_of")=="user" {
        r:=bridge_owner_run_command(ctx,"review.post",st.chain_id,st.task_id,st.task_revision,payload)
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner review on behalf of the user refused")
        // R2-1: an agent's relay is recorded as an agent review. It can send the
        // task back (request_changes) but never satisfies a user-approval gate;
        // only the user's own device-signed review does.
        out:=bridge_owner_result_object(r.body)
        if after,reloaded:=bridge_owner_reload(ctx,st.chain_id,st.task_id);reloaded && after.state=="in_review" {
            out["note"]=json.String("recorded as an agent relay; a user-approval gate still needs the user's own review from the Heimdall app")
        }
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
    }
    submitted,read:=owner.query(s.db,"SELECT lease_id FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",st.chain_id,st.task_id,st.attempt)
    if !read || len(submitted)!=1 do return bridge_owner_fail(ctx,"stale_revision","submission not found")
    opened:=bridge_owner_run_input(ctx,"review.open",st.chain_id,st.task_id,submitted[0][0],st.configuration_revision,st.task_revision,"",payload)
    if opened.code!="ok" do return bridge_owner_fail(ctx,opened.code,"owner review open refused")
    capability:=contracts.owner_string(bridge_owner_result_object(opened.body),"capability")
    posted:=bridge_owner_run_input(ctx,"review.post",st.chain_id,st.task_id,submitted[0][0],st.configuration_revision,st.task_revision,capability,payload)
    if posted.code!="ok" do return bridge_owner_fail(ctx,posted.code,"owner review post refused")
    return bridge_local_response_data(ctx.request_id,posted.body)
}

// ham-ctl seals the goal and each acceptance item individually; the owner
// stores the brief as exact plaintext JSON under one sealed body.
bridge_owner_brief_text :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    brief,has:=p["brief"]
    if !has || brief==nil do return ""
    if text,is_text:=brief.(json.String);is_text do return bridge_owner_plain(ctx,string(text))
    o,is_object:=brief.(json.Object)
    if !is_object do return ""
    if len(o)==0 do return ""
    if goal,typed:=o["goal"].(json.String);typed do o["goal"]=json.String(bridge_owner_plain(ctx,string(goal)))
    if acceptance,typed:=o["acceptance"].(json.Array);typed {
        for item,i in acceptance {
            if text,is_text:=item.(json.String);is_text do acceptance[i]=json.String(bridge_owner_plain(ctx,string(text)))
        }
    }
    return bridge_owner_json(o)
}

// A flag the owner path cannot honour is a typed error naming it, never a
// silent success.
bridge_owner_unsupported :: proc(ctx:^Owner_Agent_Ctx,p:json.Object,key,flag:string) -> string {
    if _,present:=p[key];present do return bridge_owner_fail(ctx,"unsupported_on_owner_chain",fmt.tprintf("%s is not supported on an owner-held chain",flag))
    return ""
}

bridge_owner_task :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> (owner.Agent_Task_State,string) {
    st,found,ok:=owner.agent_task_state(ctx.store,bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id"))
    if !ok do return {},bridge_owner_fail(ctx,"storage_error","owner store could not be read")
    if !found do return {},bridge_owner_fail(ctx,"not_found","task not found on owner")
    return st,""
}
bridge_owner_reload :: proc(ctx:^Owner_Agent_Ctx,chain,task:string) -> (owner.Agent_Task_State,bool) {
    st,found,ok:=owner.agent_task_state(ctx.store,chain,task)
    return st,found && ok
}
bridge_owner_chain_rev :: proc(ctx:^Owner_Agent_Ctx,chain:string) -> string {
    revision,_,_:=owner.agent_chain_revision(ctx.store,chain)
    return revision
}

// Coordinator task options parsed and validated before any mutation, so an
// unsupported or unresolvable flag never leaves a half-applied change.
Owner_Task_Plan :: struct {
    priority:string,
    has_deps:bool,
    deps:[dynamic]string,
    assignee,reviewer:string,
    has_assignee,has_reviewer:bool,
    // --require-user-approval: agents may add the flag (it lives in the brief)
    // but never remove it; only the user's device can (R2-1 ratchet).
    has_approval,approval:bool,
}
bridge_owner_task_plan :: proc(ctx:^Owner_Agent_Ctx,p:json.Object,updating:bool) -> (Owner_Task_Plan,string) {
    plan:Owner_Task_Plan
    plan.deps=make([dynamic]string,context.temp_allocator)
    for pair in ([3][2]string{{"requirements_reason","--reason"},{"request_id","--request-id"},{"notify","--notify"}}) {
        if u:=bridge_owner_unsupported(ctx,p,pair[0],pair[1]);u!="" do return {},u
    }
    if b,present:=p["requires_user_approval"];present && b!=nil {
        v,is_bool:=b.(json.Boolean)
        if !is_bool do return {},bridge_owner_fail(ctx,"bad_request","requires_user_approval must be a boolean")
        plan.has_approval=true
        plan.approval=bool(v)
    }
    if bridge:=bridge_owner_pstr(p,"bridge_id");bridge!="" && bridge!=bridge_config.daemon_id {
        return {},bridge_owner_fail(ctx,"unsupported_on_owner_chain","--bridge other than the owner Bridge is not supported on an owner-held chain")
    }
    if _,present:=p["bridge_id"];present && bridge_owner_pstr(p,"bridge_id")=="" && updating {
        return {},bridge_owner_fail(ctx,"unsupported_on_owner_chain","clearing --bridge is not supported on an owner-held chain")
    }
    if priority:=bridge_owner_pstr(p,"priority");priority!="" {
        if !contracts.owner_field_valid(priority,"priority") do return {},bridge_owner_fail(ctx,"bad_request","--priority must be p0, p1 or p2")
        plan.priority=priority
    }
    if value,present:=p["depends_on"];present {
        list,is_list:=value.(json.Array)
        if !is_list do return {},bridge_owner_fail(ctx,"bad_request","depends_on must be a list of task ids")
        plan.has_deps=true
        for item in list {
            id,is_text:=item.(json.String)
            if !is_text do return {},bridge_owner_fail(ctx,"bad_request","depends_on must be a list of task ids")
            if trimmed:=strings.trim_space(string(id));trimmed!="" {
                if strings.contains(trimmed,":") do return {},bridge_owner_fail(ctx,"unsupported_on_owner_chain","--depends-on workflow runs are not supported on an owner-held chain")
                append(&plan.deps,trimmed)
            }
        }
    }
    if _,present:=p["assignee"];present {
        plan.has_assignee=true
        plan.assignee=bridge_owner_pstr(p,"assignee")
        if plan.assignee=="" do return {},bridge_owner_fail(ctx,"unsupported_on_owner_chain","clearing --assignee is not supported on an owner-held chain")
    }
    if value,present:=p["reviewers"];present {
        list,is_list:=value.(json.Array)
        if !is_list || len(list)!=1 do return {},bridge_owner_fail(ctx,"unsupported_on_owner_chain","--reviewer must name exactly one reviewer agent on an owner-held chain (clearing or several reviewers is unsupported)")
        id,is_text:=list[0].(json.String)
        if !is_text || strings.trim_space(string(id))=="" do return {},bridge_owner_fail(ctx,"bad_request","--reviewer must be an agent id")
        plan.has_reviewer=true
        plan.reviewer=strings.trim_space(string(id))
    }
    return plan,""
}

// The exact live child of a durable agent id among this chain's current
// enabled members and fleet workers on this Bridge. Caller holds the child
// locks (bridge_owner_child_locked).
bridge_owner_resolve_agent :: proc(ctx:^Owner_Agent_Ctx,chain,agent_id,flag:string) -> (owner.Child,string,string) {
    participants,ok:=owner.agent_chain_participants(ctx.store,chain)
    if !ok do return {},"storage_error","owner store could not be read"
    found:owner.Child
    matches:=0
    for instance in participants {
        if child,live:=bridge_owner_child_locked(instance,"");live && child.agent_id==agent_id { found=child;matches+=1 }
    }
    if matches==0 do return {},"invalid_scope",fmt.tprintf("%s %s is not a running, enabled member or fleet worker of this chain on this Bridge (adding members is human-only)",flag,agent_id)
    if matches>1 do return {},"ambiguous_agent",fmt.tprintf("%s %s matches several running instances in this chain",flag,agent_id)
    return found,"ok",""
}

// An assignment derived and validated before any mutation: the task's
// dependencies exist, a reviewer has a worker, the chain has one repository
// and target branch, the target branch resolves, the worktree path is safe
// and the worker was launched in the chain repository. Only then does create
// or update write anything, so a refused assignment is never half-applied
// (H1: these checks used to run after task.create and fleet.edit committed).
Owner_Assignment :: struct {
    configure:bool,
    // lifecycle.configure payload; configuration_revision is set when applied.
    config:map[string]string,
}
bridge_owner_assignment_preflight :: proc(ctx:^Owner_Agent_Ctx,chain,task:string,st:owner.Agent_Task_State,existing:bool,plan:Owner_Task_Plan,assignee,reviewer:owner.Child) -> (Owner_Assignment,string,string) {
    for d in plan.deps {
        if d==task do return {},"invalid_scope","a task cannot depend on itself"
        _,found,ok:=owner.agent_task_state(ctx.store,chain,d)
        if !ok do return {},"storage_error","owner store could not be read"
        if !found do return {},"not_found",fmt.tprintf("--depends-on %s is not a task of this chain",d)
    }
    if reviewer.instance=="" do return {},"ok",""
    author:=assignee
    if !plan.has_assignee {
        if !existing || st.fleet_instance=="" || st.fleet_enabled!="1" do return {},"worker_required","assign a worker (--assignee) before a reviewer"
        live:bool
        author,live=bridge_owner_child_locked(st.fleet_instance,"")
        if !live do return {},"invalid_scope","the assigned worker is not running"
    }
    template,code:=owner.agent_assignment_template(ctx.store,chain)
    if code!="ok" do return {},code,"the chain has no single configured repository and target branch (set the chain directory and a target_branch chain default)"
    config:=make(map[string]string,context.temp_allocator)
    config["configuration_revision"]="1" // validation placeholder
    config["author_agent_id"]=author.agent_id;config["reviewer_agent_id"]=reviewer.agent_id;config["reviewer_instance_id"]=reviewer.instance
    config["directory_id"]=template.directory_id;config["merge_policy"]=template.merge_policy
    config["repository"]="";config["worktree"]="";config["source_branch"]="";config["target_branch"]="";config["base_head"]=""
    if template.merge_policy=="git" {
        base,read:=bridge_owner_git(template.repository,[]string{"rev-parse","--verify",strings.concatenate({"refs/heads/",template.target_branch,"^{commit}"},context.temp_allocator)})
        if !read do return {},"invalid_scope",fmt.tprintf("target branch %s not found in %s",template.target_branch,template.repository)
        config["repository"]=template.repository;config["worktree"]=fmt.tprintf("%s/.heimdall/worktrees/%s",template.repository,task)
        config["source_branch"]=fmt.tprintf("heimdall/%s",task);config["target_branch"]=template.target_branch;config["base_head"]=base
        launch,found:=bridge_runtime_get_launch(author.instance)
        if !found do return {},"invalid_scope",fmt.tprintf("worker %s has no launch record on this Bridge",author.agent_id)
        project:=bridge_fs_canonicalize_existing(launch.project_path);defer delete(project)
        if project!=config["repository"] && project!=config["worktree"] {
            return {},"invalid_scope",fmt.tprintf("worker %s was launched in %s, not in the chain repository %s; assign a worker launched in the chain directory",author.agent_id,launch.project_path,template.repository)
        }
    }
    c,valid:=contracts.owner_parse(bridge_owner_json(config),"lifecycle_config_payload")
    if !valid do return {},"invalid_content","derived lifecycle configuration is invalid"
    if !bridge_owner_paths(c,task,allow_missing_worktree=true) do return {},"invalid_scope",fmt.tprintf("the chain repository %s cannot host task worktrees for target branch %s",template.repository,template.target_branch)
    return Owner_Assignment{true,config},"ok",""
}

// fleet.edit, then (when a reviewer is known) lifecycle.configure, on the
// user's behalf, from a preflighted assignment. The owner re-checks
// membership, the chain repository and every lifecycle invariant
// (agent_command_admit, lifecycle_human).
bridge_owner_assign :: proc(ctx:^Owner_Agent_Ctx,chain,task:string,plan:Owner_Task_Plan,assignee:owner.Child,pre:Owner_Assignment) -> (string,string) {
    st,ok:=bridge_owner_reload(ctx,chain,task)
    if !ok do return "storage_error","owner store could not be read"
    if plan.has_assignee {
        revision,_:=strconv.parse_i64(st.fleet_revision)
        payload:=bridge_owner_json(map[string]string{"instance_id"=assignee.instance,"configuration_revision"=fmt.tprintf("%d",revision+1),"enabled"="1"})
        r:=bridge_owner_run_command(ctx,"fleet.edit",chain,task,st.task_revision,payload,fleet_child=assignee)
        if r.code!="ok" do return r.code,"assigning the worker was refused"
        st,ok=bridge_owner_reload(ctx,chain,task)
        if !ok do return "storage_error","owner store could not be read"
    }
    if !pre.configure do return "ok",""
    if st.fleet_instance=="" || st.fleet_enabled!="1" do return "worker_required","assign a worker (--assignee) before a reviewer"
    config_revision,_:=strconv.parse_i64(st.config_max_revision)
    config:=pre.config
    config["configuration_revision"]=fmt.tprintf("%d",config_revision+1)
    raw:=bridge_owner_json(config)
    c,valid:=contracts.owner_parse(raw,"lifecycle_config_payload")
    if !valid do return "invalid_content","derived lifecycle configuration is invalid"
    proof:=bridge_owner_config_proof(ctx.store,c,chain,task)
    r:=bridge_owner_run_command(ctx,"lifecycle.configure",chain,task,st.task_revision,raw,proof=proof)
    if r.code!="ok" do return r.code,"configuring the worker/reviewer pair was refused (the worker must run in the chain repository)"
    return "ok",""
}

bridge_owner_dependency :: proc(ctx:^Owner_Agent_Ctx,st:owner.Agent_Task_State,prerequisite:string,enabled:bool) -> (string,string) {
    current,ok:=bridge_owner_reload(ctx,st.chain_id,st.task_id)
    if !ok do return "storage_error","owner store could not be read"
    payload:=bridge_owner_json(map[string]string{"prerequisite"=prerequisite,"enabled"=("1" if enabled else "0")})
    r:=bridge_owner_run_command(ctx,"dependency.edit",st.chain_id,st.task_id,current.task_revision,payload)
    if r.code!="ok" do return r.code,fmt.tprintf("dependency on %s refused",prerequisite)
    return "ok",""
}

// Priority, dependencies, brief and assignment shared by create and update.
bridge_owner_apply_plan :: proc(ctx:^Owner_Agent_Ctx,chain,task:string,plan:Owner_Task_Plan,assignee:owner.Child,pre:Owner_Assignment) -> (string,string) {
    st,ok:=bridge_owner_reload(ctx,chain,task)
    if !ok do return "storage_error","owner store could not be read"
    if plan.priority!="" {
        r:=bridge_owner_run_command(ctx,"task.priority",chain,task,st.task_revision,bridge_owner_json(map[string]string{"priority"=plan.priority}))
        if r.code!="ok" do return r.code,"priority refused"
    }
    if plan.has_deps {
        wanted:=make(map[string]bool,context.temp_allocator)
        for d in plan.deps do wanted[d]=true
        for d in st.dependencies do if !wanted[d] {
            if code,message:=bridge_owner_dependency(ctx,st,d,false);code!="ok" do return code,message
        }
        for d in plan.deps {
            present:=false
            for existing in st.dependencies do if existing==d do present=true
            if present do continue
            if code,message:=bridge_owner_dependency(ctx,st,d,true);code!="ok" do return code,message
        }
    }
    if plan.has_assignee || plan.has_reviewer do return bridge_owner_assign(ctx,chain,task,plan,assignee,pre)
    return "ok",""
}

// Resolve assignee/reviewer children up front (and the reviewer of an
// existing configuration when only the worker changes).
bridge_owner_plan_children :: proc(ctx:^Owner_Agent_Ctx,chain:string,st:owner.Agent_Task_State,plan:^Owner_Task_Plan) -> (owner.Child,owner.Child,string) {
    assignee,reviewer:owner.Child
    code,message:string
    if plan.has_assignee {
        assignee,code,message=bridge_owner_resolve_agent(ctx,chain,plan.assignee,"--assignee")
        if code!="ok" do return {},{},bridge_owner_fail(ctx,code,message)
    }
    reviewer_agent:=plan.reviewer
    if !plan.has_reviewer && plan.has_assignee && st.configured do reviewer_agent=contracts.owner_string(st.config,"reviewer_agent_id")
    if reviewer_agent!="" {
        reviewer,code,message=bridge_owner_resolve_agent(ctx,chain,reviewer_agent,"--reviewer")
        if code!="ok" do return {},{},bridge_owner_fail(ctx,code,message)
        if plan.has_assignee && reviewer.agent_id==assignee.agent_id do return {},{},bridge_owner_fail(ctx,"invalid_scope","the reviewer must be a different agent than the assignee")
    }
    if plan.has_assignee && reviewer_agent=="" do return {},{},bridge_owner_fail(ctx,"reviewer_required","an owner task needs an independent --reviewer with its --assignee")
    return assignee,reviewer,""
}

bridge_owner_task_create :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    s:=ctx.store
    chain:=bridge_owner_pstr(p,"chain_id")
    if chain=="" do chain=owner.agent_home_chain(s,ctx.child)
    // Only the coordinator may create; refuse before resolving anything.
    if role,code:=owner.agent_authorize_locked(s,chain,"",ctx.child,"task.create");role!=.Coordinator do return bridge_owner_fail(ctx,code,"only the chain coordinator creates tasks")
    title:=bridge_owner_pstr(p,"title")
    if title=="" do return bridge_owner_fail(ctx,"bad_request","task create requires --title")
    plan,unsupported:=bridge_owner_task_plan(ctx,p,false)
    if unsupported!="" do return unsupported
    assignee,reviewer,failed:=bridge_owner_plan_children(ctx,chain,{},&plan)
    if failed!="" do return failed
    task:=bridge_owner_fresh_id("task")
    // Validate the whole assignment before the task exists.
    pre,pre_code,pre_message:=bridge_owner_assignment_preflight(ctx,chain,task,{},false,plan,assignee,reviewer)
    if pre_code!="ok" do return bridge_owner_fail(ctx,pre_code,fmt.tprintf("no task created: %s",pre_message))
    // The owner gate reads the flag from the brief, so a gated task needs one.
    if plan.approval && bridge_owner_brief_text(ctx,p)=="" do return bridge_owner_fail(ctx,"bad_request","--require-user-approval on an owner-held chain needs a brief (--goal and --acceptance); no task created")
    title_cipher,ok:=bridge_owner_cipher(ctx,title)
    body_cipher,body_ok:=bridge_owner_cipher(ctx,bridge_owner_pstr(p,"description"))
    if !ok || !body_ok do return bridge_owner_fail(ctx,"vault_locked","cannot seal task content")
    r:=bridge_owner_run_command(ctx,"task.create",chain,task,bridge_owner_chain_rev(ctx,chain),bridge_owner_json(map[string]string{"title_cipher"=title_cipher,"body_cipher"=body_cipher}))
    if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner task create refused")
    if brief:=bridge_owner_brief_text(ctx,p);brief!="" {
        if plan.approval do brief=bridge_owner_brief_with_approval(brief)
        if code,message:=bridge_owner_requirements(ctx,chain,task,brief,"",true);code!="ok" do return bridge_owner_fail(ctx,code,fmt.tprintf("task %s created; requirements refused%s",task,message))
    }
    if code,message:=bridge_owner_apply_plan(ctx,chain,task,plan,assignee,pre);code!="ok" do return bridge_owner_fail(ctx,code,fmt.tprintf("task %s created; %s",task,message))
    out:=bridge_owner_result_object(r.body)
    out["authority"]=json.Object{"kind"=json.String("owner"),"bridge_id"=json.String(bridge_config.daemon_id)}
    if plan.has_assignee do out["assignee_instance_id"]=json.String(assignee.instance)
    if reviewer.instance!="" do out["reviewer_instance_id"]=json.String(reviewer.instance)
    return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
}

// The brief with requires_user_approval set (the owner gate's source).
bridge_owner_brief_with_approval :: proc(brief:string) -> string {
    v,ok:=contracts.owner_content_document(brief)
    o,obj:=v.(json.Object)
    if !ok || !obj do return brief
    o["requires_user_approval"]=json.Boolean(true)
    return bridge_owner_json(o)
}
bridge_owner_brief_approval :: proc(brief:string) -> (value:bool,present:bool) {
    v,ok:=contracts.owner_content_document(brief)
    o,obj:=v.(json.Object)
    if !ok || !obj do return false,false
    flag,has:=o["requires_user_approval"]
    if !has do return false,false
    b,is_bool:=flag.(json.Boolean)
    return is_bool && bool(b),true
}
BRIDGE_OWNER_RATCHET_MESSAGE :: ": requires_user_approval can be added by an agent but only removed by the user (device-signed requirements edit)"

// requirements.edit with the next revision. Without --replace-brief the new
// keys merge over the current brief, as on the Hub. The user-approval ratchet
// (owner lifecycle_human) refuses an agent removal; a replacement brief that
// merely omits the flag keeps it.
bridge_owner_requirements :: proc(ctx:^Owner_Agent_Ctx,chain,task,brief,expected:string,replace:bool) -> (string,string) {
    st,ok:=bridge_owner_reload(ctx,chain,task)
    if !ok do return "not_found",""
    if expected!="" && expected!=st.requirements_revision do return "stale_revision",""
    body:=brief
    current,_:=bridge_owner_brief_approval(st.brief)
    next,explicit:=bridge_owner_brief_approval(brief)
    if current && explicit && !next do return "invalid_scope",BRIDGE_OWNER_RATCHET_MESSAGE
    if current && !explicit do body=bridge_owner_brief_with_approval(body)
    if !replace && st.brief!="" {
        old,old_ok:=contracts.owner_content_document(st.brief)
        new,new_ok:=contracts.owner_content_document(brief)
        o,o_obj:=old.(json.Object);n,n_obj:=new.(json.Object)
        if old_ok && new_ok && o_obj && n_obj {
            for k,v in n do o[k]=v
            body=bridge_owner_json(o)
        }
    }
    revision,_:=strconv.parse_i64(st.requirements_revision)
    sealed,sealed_ok:=bridge_owner_cipher(ctx,body)
    if !sealed_ok do return "vault_locked",""
    payload:=bridge_owner_json(map[string]string{"requirements_revision"=fmt.tprintf("%d",revision+1),"body_cipher"=sealed})
    return bridge_owner_run_command(ctx,"requirements.edit",st.chain_id,st.task_id,st.task_revision,payload).code,""
}

bridge_owner_task_update :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    st,missing:=bridge_owner_task(ctx,p)
    if missing!="" do return missing
    if role,code:=owner.agent_authorize_locked(ctx.store,st.chain_id,st.task_id,ctx.child,"task.edit");role!=.Coordinator do return bridge_owner_fail(ctx,code,"only the chain coordinator updates tasks")
    plan,unsupported:=bridge_owner_task_plan(ctx,p,true)
    if unsupported!="" do return unsupported
    if reason:=bridge_owner_pstr(p,"expected_requirements_revision");reason!="" && bridge_owner_brief_text(ctx,p)=="" do return bridge_owner_fail(ctx,"bad_request","--expected-requirements-revision needs brief flags")
    assignee,reviewer,failed:=bridge_owner_plan_children(ctx,st.chain_id,st,&plan)
    if failed!="" do return failed
    pre,pre_code,pre_message:=bridge_owner_assignment_preflight(ctx,st.chain_id,st.task_id,st,true,plan,assignee,reviewer)
    if pre_code!="ok" do return bridge_owner_fail(ctx,pre_code,fmt.tprintf("task unchanged: %s",pre_message))
    title,description:=bridge_owner_pstr(p,"title"),bridge_owner_pstr(p,"description")
    brief:=bridge_owner_brief_text(ctx,p)
    if plan.has_approval {
        current,_:=bridge_owner_brief_approval(st.brief)
        if current && !plan.approval do return bridge_owner_fail(ctx,"invalid_scope",fmt.tprintf("task unchanged%s",BRIDGE_OWNER_RATCHET_MESSAGE))
        if plan.approval && !current {
            if brief=="" && st.brief=="" do return bridge_owner_fail(ctx,"bad_request","--require-user-approval on an owner-held chain needs a brief (--goal and --acceptance); task unchanged")
            brief=bridge_owner_brief_with_approval(brief if brief!="" else "{}")
        }
    }
    if title=="" && description=="" && brief=="" && plan.priority=="" && !plan.has_deps && !plan.has_assignee && !plan.has_reviewer && !plan.has_approval {
        return bridge_owner_fail(ctx,"bad_request","task update needs at least one field to change")
    }
    result:="{}"
    if title!="" || description!="" {
        read:=bridge_owner_run_command(ctx,"task.read",st.chain_id,st.task_id,"0",`{"cursor":"","limit":"1"}`)
        if read.code!="ok" do return bridge_owner_fail(ctx,read.code,"owner task read refused")
        current:=bridge_owner_result_object(read.body)
        if title=="" do title=contracts.owner_string(current,"title")
        if description=="" do description=contracts.owner_string(current,"body")
        title_cipher,ok:=bridge_owner_cipher(ctx,title)
        body_cipher,body_ok:=bridge_owner_cipher(ctx,description)
        if !ok || !body_ok do return bridge_owner_fail(ctx,"vault_locked","cannot seal task content")
        r:=bridge_owner_run_command(ctx,"task.edit",st.chain_id,st.task_id,st.task_revision,bridge_owner_json(map[string]string{"title_cipher"=title_cipher,"body_cipher"=body_cipher}))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner task edit refused")
        result=r.body
    }
    if brief!="" {
        replace:=false
        if b,typed:=p["replace_brief"].(json.Boolean);typed do replace=bool(b)
        if code,message:=bridge_owner_requirements(ctx,st.chain_id,st.task_id,brief,bridge_owner_pstr(p,"expected_requirements_revision"),replace);code!="ok" do return bridge_owner_fail(ctx,code,fmt.tprintf("owner requirements edit refused%s",message))
    }
    if code,message:=bridge_owner_apply_plan(ctx,st.chain_id,st.task_id,plan,assignee,pre);code!="ok" do return bridge_owner_fail(ctx,code,message)
    final,ok:=bridge_owner_reload(ctx,st.chain_id,st.task_id)
    if ok do result=bridge_owner_json(map[string]string{"task_id"=final.task_id,"chain_id"=final.chain_id,"revision"=final.task_revision})
    return bridge_local_response_data(ctx.request_id,result)
}
