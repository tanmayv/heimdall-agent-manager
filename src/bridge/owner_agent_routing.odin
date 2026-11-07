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
         "agent.review.post","agent.task.show","agent.task.comments","agent.task.comment","agent.task.create","agent.task.update",
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
    if !bridge_owner_open(account,key_id) do return "",false
    p:=bridge_owner_params(params)
    if !bridge_owner_targets(&bridge_owner_store,method,p,rec.agent_instance_id) do return "",false
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return bridge_local_response_error(request_id,"vault_locked","owner Bridge vault is locked"),true
    key:=contracts.Owner_Verified_Key{account,bridge_config.daemon_id,key_id,pub,"bridge",true,false}
    response:=bridge_owner_agent_route_child(request_id,method,p,rec,key,&kr)
    // Registry publication and merge intents run after the child locks are
    // released, under the owner mutex only (as bridge_owner_handle does).
    bridge_owner_publish()
    return response,true
}

// Lock order owner -> startup I/O -> token, as bridge_owner_agent: stop,
// rotation and relaunch cannot race admission after exact-child validation.
bridge_owner_agent_route_child :: proc(request_id,method:string,p:json.Object,rec:Bridge_Local_Agent_Token_Record,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring) -> string {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    if !current do return bridge_local_response_error(request_id,"invalid_scope","owner chain: current launched child required")
    run_dir:=""
    if launch,launched:=bridge_runtime_get_launch(child.instance);launched do run_dir=strings.clone(launch.run_dir,context.temp_allocator)
    ctx:=Owner_Agent_Ctx{request_id,&bridge_owner_store,child,key,kr,run_dir,time.to_unix_nanoseconds(time.now())/1000000}
    return bridge_owner_agent_exec(&ctx,method,p)
}

// Whether the verb's target lives in this owner store.
bridge_owner_targets :: proc(s:^owner.Store,method:string,p:json.Object,instance:string) -> bool {
    chain,task:=bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id")
    if bridge_owner_lease_method(method) && method!="agent.lease.switch" do return owner.agent_bound(s,instance)
    if task!="" {
        _,found:=owner.agent_task_state(s,chain,task)
        return found
    }
    if chain!="" do return owner.agent_chain_revision(s,chain)!=""
    // No ids: the agent's own chain context (coordinator or worker).
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
bridge_owner_run_command :: proc(ctx:^Owner_Agent_Ctx,method,chain,task,expected,payload:string) -> owner.Result {
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
    return owner.execute_agent(s,bridge_owner_json(c),payload,ctx.child,ctx.key,ctx.now,ctx.kr,bridge_owner_signer())
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

// Creates repo/.heimdall/worktrees/<task> on branch heimdall/<task> from the
// configured base when it is missing (claim parity with the Hub path). The
// paths are the immutable configured ones; bridge_owner_paths revalidates.
bridge_owner_ensure_worktree :: proc(config:json.Object,task:string) -> bool {
    get:=contracts.owner_string
    if get(config,"merge_policy")!="git" do return true
    repo,work,branch,base:=get(config,"repository"),get(config,"worktree"),get(config,"source_branch"),get(config,"base_head")
    if repo=="" || work!=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task) || branch!=fmt.tprintf("heimdall/%s",task) || !contracts.owner_field_valid(base,"optional_commit") || base=="" do return false
    if bridge_taskv2_is_checkout_root(work) do return true
    if top,ok:=bridge_owner_git(repo,[]string{"rev-parse","--show-toplevel"});!ok || top!=repo do return false
    bridge_taskv2_exclude_worktrees(repo)
    _,_=bridge_owner_git(repo,[]string{"worktree","prune"})
    _=bridge_make_directory_all(fmt.tprintf("%s/.heimdall/worktrees",repo))
    if bridge_taskv2_branch_exists(repo,branch) {
        _,added:=bridge_owner_git(repo,[]string{"worktree","add",work,branch})
        return added && bridge_taskv2_is_checkout_root(work)
    }
    _,added:=bridge_owner_git(repo,[]string{"worktree","add","-b",branch,work,base})
    return added && bridge_taskv2_is_checkout_root(work)
}

// After a claim (or a re-read of the current lease): checkout, requirements
// presentation and TASK.md, like the Hub path's pack application.
bridge_owner_deliver :: proc(ctx:^Owner_Agent_Ctx,st:owner.Agent_Lease_State) -> (Owner_Agent_Lease,string,string) {
    out:=Owner_Agent_Lease{lease_id=st.lease_id,task_id=st.task_id,chain_id=st.chain_id,requirements_revision=st.requirements_revision,acknowledged="0"}
    out.placement=bridge_owner_placement(st.config,st.configured)
    if !st.configured do return out,"ok",""
    if !bridge_owner_ensure_worktree(st.config,st.task_id) do return out,"worktree_unavailable","could not create the task worktree"
    payload:=fmt.tprintf(`{{"requirements_revision":"%s"}}`,st.requirements_revision)
    r:=bridge_owner_run_input(ctx,"requirements.present",st.chain_id,st.task_id,st.lease_id,st.configuration_revision,st.task_revision,st.capability,payload)
    if r.code!="ok" do return out,r.code,"requirements could not be presented"
    out.acknowledged=contracts.owner_string(bridge_owner_result_object(r.body),"acknowledged")
    command:=owner.doc(map[string]string{"chain_id"=st.chain_id,"task_id"=st.task_id,"lease_id"=st.lease_id,"instance_id"=ctx.child.instance,
        "workdir"=out.placement.workdir,"branch"=out.placement.branch})
    if ctx.run_dir=="" || !bridge_owner_materialize_context(ctx.run_dir,command,r.body) {
        return out,"context_delivery_failed","requirements presented; TASK.md write failed; run lease next again"
    }
    return out,"ok",""
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
        lease,code,message:=bridge_owner_deliver(ctx,st)
        if code!="ok" do return bridge_owner_fail(ctx,code,message)
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{pick.status,lease,Owner_Agent_Task_Ref{st.task_id,st.chain_id},bridge_owner_authority()}))
    case "agent.lease.heartbeat","agent.lease.submit","agent.lease.handoff","agent.lease.block","agent.lease.switch":
        return bridge_owner_lease_verb(ctx,method,p)
    case "agent.review.post":
        return bridge_owner_review(ctx,p)
    case "agent.task.show","agent.task.comments":
        st,found:=owner.agent_task_state(s,bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id"))
        if !found do return bridge_owner_fail(ctx,"not_found","task not found on owner")
        r:=bridge_owner_run_command(ctx,"task.read",st.chain_id,st.task_id,"0",`{"cursor":"","limit":"100"}`)
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
        st,found:=owner.agent_task_state(s,bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id"))
        if !found do return bridge_owner_fail(ctx,"not_found","task not found on owner")
        body,sealed:=bridge_owner_cipher(ctx,bridge_owner_pstr(p,"body"))
        if !sealed || bridge_owner_pstr(p,"body")=="" do return bridge_owner_fail(ctx,"bad_request","comment requires a body")
        r:=bridge_owner_run_command(ctx,"task.comment",st.chain_id,st.task_id,st.task_revision,bridge_owner_json(map[string]string{"body_cipher"=body}))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner comment refused")
        return bridge_local_response_data(ctx.request_id,r.body)
    case "agent.task.create":
        return bridge_owner_task_create(ctx,p)
    case "agent.task.update":
        return bridge_owner_task_update(ctx,p)
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
        r:=bridge_owner_run_command(ctx,"chain.summary.set",chain,"",owner.agent_chain_revision(s,chain),bridge_owner_json(map[string]string{"body_cipher"=summary}))
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
        r:=bridge_owner_run_command(ctx,method_name,chain,"",owner.agent_chain_revision(s,chain),bridge_owner_json(map[string]string{"body_cipher"=cipher}))
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
        dst,found:=owner.agent_task_state(s,"",bridge_owner_pstr(p,"task_id"))
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
        lease,code,message:=bridge_owner_deliver(ctx,next)
        if code!="ok" do return bridge_owner_fail(ctx,code,message)
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{"granted",lease,Owner_Agent_Task_Ref{next.task_id,next.chain_id},bridge_owner_authority()}))
    }
    return bridge_owner_fail(ctx,"bad_request","unsupported lease verb")
}

// review post: the configured reviewer child opens its review capability and
// posts the bound verdict; --on-behalf-of user is the coordinator recording
// the user's decision (never a substitute for the independent reviewer).
bridge_owner_review :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    s:=ctx.store
    st,found:=owner.agent_task_state(s,bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id"))
    if !found do return bridge_owner_fail(ctx,"not_found","task not found on owner")
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
        return bridge_local_response_data(ctx.request_id,r.body)
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

bridge_owner_task_create :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    s:=ctx.store
    chain:=bridge_owner_pstr(p,"chain_id")
    if chain=="" do chain=owner.agent_home_chain(s,ctx.child)
    title:=bridge_owner_pstr(p,"title")
    if title=="" do return bridge_owner_fail(ctx,"bad_request","task create requires --title")
    title_cipher,ok:=bridge_owner_cipher(ctx,title)
    body_cipher,body_ok:=bridge_owner_cipher(ctx,bridge_owner_pstr(p,"description"))
    if !ok || !body_ok do return bridge_owner_fail(ctx,"vault_locked","cannot seal task content")
    task:=bridge_owner_fresh_id("task")
    r:=bridge_owner_run_command(ctx,"task.create",chain,task,owner.agent_chain_revision(s,chain),bridge_owner_json(map[string]string{"title_cipher"=title_cipher,"body_cipher"=body_cipher}))
    if r.code!="ok" do return bridge_owner_fail(ctx,r.code,"owner task create refused")
    if brief:=bridge_owner_brief_text(ctx,p);brief!="" {
        if code:=bridge_owner_requirements(ctx,chain,task,brief);code!="ok" do return bridge_owner_fail(ctx,code,"task created; requirements refused")
    }
    out:=bridge_owner_result_object(r.body)
    out["authority"]=json.Object{"kind"=json.String("owner"),"bridge_id"=json.String(bridge_config.daemon_id)}
    return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
}

bridge_owner_requirements :: proc(ctx:^Owner_Agent_Ctx,chain,task,brief:string) -> string {
    st,found:=owner.agent_task_state(ctx.store,chain,task)
    if !found do return "not_found"
    current,_:=strconv.parse_i64(st.requirements_revision)
    sealed,ok:=bridge_owner_cipher(ctx,brief)
    if !ok do return "vault_locked"
    payload:=bridge_owner_json(map[string]string{"requirements_revision"=fmt.tprintf("%d",current+1),"body_cipher"=sealed})
    return bridge_owner_run_command(ctx,"requirements.edit",st.chain_id,st.task_id,st.task_revision,payload).code
}

bridge_owner_task_update :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    s:=ctx.store
    st,found:=owner.agent_task_state(s,bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id"))
    if !found do return bridge_owner_fail(ctx,"not_found","task not found on owner")
    title,description:=bridge_owner_pstr(p,"title"),bridge_owner_pstr(p,"description")
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
    if brief:=bridge_owner_brief_text(ctx,p);brief!="" {
        if code:=bridge_owner_requirements(ctx,st.chain_id,st.task_id,brief);code!="ok" do return bridge_owner_fail(ctx,code,"owner requirements edit refused")
    }
    return bridge_local_response_data(ctx.request_id,result)
}
