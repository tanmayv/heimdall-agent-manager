#+feature dynamic-literals
package main

// P-CS CC-A: coordinator controls on an owner chain, without a lease.
//
// The verified chain coordinator drives tasks through the ordinary agent API
// (agent.task.hold|release|cancel|reopen|unblock|recheck|escalate|merge_retry|
// delete|review_roles, agent.lease.revoke, agent.task_chain.complete /
// agent.work.complete, agent.workflow.retry|cancel). Each verb maps to one
// owner method, signed by the owner key for the proven child; authority is
// decided only by lib/owner_local/agent_authority.odin (coordinator only;
// workers, reviewers and foreign-chain agents get invalid_scope).

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

bridge_owner_control_method :: proc(method:string) -> string {
    switch method {
    case "agent.task.hold": return "task.hold"
    case "agent.task.release": return "task.release"
    case "agent.task.cancel": return "task.cancel"
    case "agent.task.reopen": return "task.reopen"
    case "agent.task.unblock": return "task.resolve"
    case "agent.task.recheck": return "task.recheck"
    case "agent.task.escalate": return "task.escalate"
    case "agent.task.merge_retry": return "merge.retry"
    case "agent.task.delete": return "task.delete"
    case "agent.task.review_roles": return "review.roles"
    case "agent.lease.revoke": return "lease.revoke"
    case "agent.task_chain.complete","agent.work.complete": return "chain.complete"
    case "agent.workflow.retry": return "workflow.retry"
    case "agent.workflow.cancel": return "workflow.cancel"
    }
    return ""
}

// The reason an agent gives (R2-6): --reason, or --note for unblock.
bridge_owner_control_reason :: proc(p:json.Object) -> string {
    for key in ([4]string{"reason","note","body","summary"}) {
        if v:=bridge_owner_pstr(p,key);v!="" do return v
    }
    return ""
}

// Plaintext fields of the owner payload, validated before anything is
// sealed or signed. message is empty when the fields are complete.
Owner_Control_Fields :: struct {
    reason,dependents,mode,disable_fleet:string,
}
bridge_owner_control_fields :: proc(owner_method:string,p:json.Object) -> (Owner_Control_Fields,string) {
    out:=Owner_Control_Fields{reason=bridge_owner_control_reason(p)}
    switch owner_method {
    case "task.recheck":
        if out.reason=="" do out.reason="recheck"
    case "task.cancel":
        out.dependents=bridge_owner_pstr(p,"dependents")
        if target:=bridge_owner_pstr(p,"repoint");target!="" {
            if out.dependents!="" && out.dependents!=fmt.tprintf("repoint:%s",target) do return {},"use either --dependents or --repoint, not both"
            out.dependents=fmt.tprintf("repoint:%s",target)
        }
        if out.dependents!="" && !contracts.owner_field_valid(out.dependents,"cancel_dependents") do return {},"--dependents must be drop, keep or repoint:<task_id>"
    case "lease.revoke":
        out.mode=bridge_owner_pstr(p,"mode")
        if b,ok:=p["stop"].(json.Boolean);ok && bool(b) {
            if out.mode!="" && out.mode!="stop" do return {},"use either --stop or --mode checkpoint, not both"
            out.mode="stop"
        }
        if out.mode=="" do out.mode="checkpoint"
        if out.mode!="checkpoint" && out.mode!="stop" do return {},"--mode must be checkpoint or stop"
        out.disable_fleet="0"
        if b,ok:=p["disable_fleet"].(json.Boolean);ok && bool(b) do out.disable_fleet="1"
    }
    if out.reason=="" {
        switch owner_method {
        case "task.hold","task.release","task.cancel","task.reopen","task.resolve","task.escalate","merge.retry","task.delete","lease.revoke":
            return {},"a reason is required (--reason)"
        }
    }
    return out,""
}

// Typed refusals the coordinator can act on.
bridge_owner_control_refusal :: proc(owner_method,code:string) -> string {
    switch code {
    case "invalid_scope":
        switch owner_method {
        case "task.resolve","task.cancel","task.hold":
            return "refused: only the chain coordinator may do this, and a task escalated to a human is cleared only by the user from the Heimdall app"
        case "review.roles":
            return "refused: only the chain coordinator may configure review roles, for agents already in this chain, and it may add but never remove a user-approval gate"
        case "task.delete":
            return "refused: only the chain coordinator may delete a task"
        }
        return "refused: only the verified chain coordinator may use this control"
    case "operation_conflict":
        switch owner_method {
        case "task.cancel": return "the task cannot be cancelled now (already cancelled or done, a task of a workflow-language run — use workflow cancel/retry —, or a dependents repoint would create a cycle)"
        case "task.reopen": return "only a cancelled, done or merge-blocked ordinary task can be reopened"
        case "task.resolve": return "the task is not blocked"
        case "task.hold": return "the task cannot be held in its current state"
        case "task.release": return "the task is not held"
        case "task.escalate": return "only a ready (not cancelled, held or in review) task can be escalated"
        case "lease.revoke": return "the task has no live lease to revoke"
        case "task.delete": return "only an unstarted task (no lease, assignment, configuration or history) can be deleted"
        case "merge.retry": return "the task is not merge-blocked with a pending merge"
        }
    case "stale_revision": return "the task changed concurrently; read it again and retry"
    case "invalid_content": return "a reason is required (--reason)"
    }
    return fmt.tprintf("owner %s refused",owner_method)
}

bridge_owner_control :: proc(ctx:^Owner_Agent_Ctx,method:string,p:json.Object) -> string {
    s:=ctx.store
    owner_method:=bridge_owner_control_method(method)
    if owner_method=="" do return bridge_owner_fail(ctx,"bad_request","unsupported owner control")
    fields,missing:=bridge_owner_control_fields(owner_method,p)
    if missing!="" do return bridge_owner_fail(ctx,"bad_request",missing)
    sealed_reason:=""
    if fields.reason!="" {
        cipher,ok:=bridge_owner_cipher(ctx,fields.reason)
        if !ok do return bridge_owner_fail(ctx,"vault_locked","cannot seal the reason")
        sealed_reason=cipher
    }
    chain_scoped:=owner_method=="chain.complete" || owner_method=="workflow.retry" || owner_method=="workflow.cancel"
    if chain_scoped {
        chain:=bridge_owner_pstr(p,"chain_id")
        if chain=="" do chain=owner.agent_home_chain(s,ctx.child)
        body:string
        switch owner_method {
        case "chain.complete":
            revision,summary:=bridge_owner_pstr(p,"expected_work_revision"),bridge_owner_pstr(p,"summary")
            if revision=="" || summary=="" do return bridge_owner_fail(ctx,"bad_request","task-chain complete requires --expected-work-revision and --summary")
            body=bridge_owner_json(map[string]string{"expected_work_revision"=revision,"summary"=summary})
        case "workflow.retry","workflow.cancel":
            run:=bridge_owner_pstr(p,"run_id")
            if run=="" do return bridge_owner_fail(ctx,"bad_request","workflow verbs require a run id")
            execution:=bridge_owner_pstr(p,"execution")
            if execution=="" || execution=="0" do execution=bridge_owner_pstr(p,"execution_no")
            if execution=="" || execution=="0" {
                rows,read:=owner.query(s.db,"SELECT current_execution FROM local_workflow_runs WHERE chain_id=? AND run_id=?",chain,run)
                if !read do return bridge_owner_fail(ctx,"storage_error","owner store could not be read")
                if len(rows)!=1 do return bridge_owner_fail(ctx,"not_found","workflow run not found on owner")
                execution=rows[0][0]
            }
            if owner_method=="workflow.retry" {
                body=bridge_owner_json(map[string]string{"run_id"=run,"execution"=execution})
            } else {
                if fields.reason=="" do return bridge_owner_fail(ctx,"bad_request","workflow cancel requires --reason")
                body=bridge_owner_json(map[string]string{"run_id"=run,"execution"=execution,"reason"=fields.reason})
            }
        }
        cipher,ok:=bridge_owner_cipher(ctx,body)
        if !ok do return bridge_owner_fail(ctx,"vault_locked","cannot seal the command")
        r:=bridge_owner_run_command(ctx,owner_method,chain,"",bridge_owner_chain_rev(ctx,chain),bridge_owner_json(map[string]string{"body_cipher"=cipher}))
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,bridge_owner_control_refusal(owner_method,r.code))
        return bridge_local_response_data(ctx.request_id,r.body)
    }
    st,not_found:=bridge_owner_task(ctx,p)
    if not_found!="" do return not_found
    payload:string
    role_children:=make([dynamic]owner.Child,context.temp_allocator)
    switch owner_method {
    case "task.cancel":
        values:=map[string]string{"body_cipher"=sealed_reason}
        defer delete(values)
        if fields.dependents!="" do values["dependents"]=fields.dependents
        payload=bridge_owner_json(values)
    case "task.delete":
        payload=bridge_owner_json(map[string]string{"protocol_version"="1","body_cipher"=sealed_reason})
    case "lease.revoke":
        payload=bridge_owner_json(map[string]string{"body_cipher"=sealed_reason,"mode"=fields.mode,"disable_fleet"=fields.disable_fleet})
    case "merge.retry":
        if st.state!="merge_blocked" do return bridge_owner_fail(ctx,"operation_conflict","the task is not merge-blocked")
        payload=bridge_owner_json(map[string]string{"attempt"=st.attempt,"requirements_revision"=st.requirements_revision,"head"=st.head,
            "configuration_revision"=st.configuration_revision,"body_cipher"=sealed_reason})
    case "review.roles":
        roles,code,message:=bridge_owner_review_roles_body(ctx,st,p,&role_children)
        if code!="ok" do return bridge_owner_fail(ctx,code,message)
        cipher,ok:=bridge_owner_cipher(ctx,roles)
        if !ok do return bridge_owner_fail(ctx,"vault_locked","cannot seal the review roles")
        payload=bridge_owner_json(map[string]string{"body_cipher"=cipher})
    case:
        payload=bridge_owner_json(map[string]string{"body_cipher"=sealed_reason})
    }
    r:=bridge_owner_run_command(ctx,owner_method,st.chain_id,st.task_id,st.task_revision,payload,role_children=role_children[:])
    if r.code!="ok" do return bridge_owner_fail(ctx,r.code,bridge_owner_control_refusal(owner_method,r.code))
    out:=bridge_owner_result_object(r.body)
    out["authority"]=json.Object{"kind"=json.String("owner"),"bridge_id"=json.String(bridge_config.daemon_id)}
    return bridge_local_response_data(ctx.request_id,bridge_owner_json(out))
}

// review.roles for a coordinator: pairs [{role, agent_id[, instance_id]}];
// each agent must already be a running participant of this chain. The flag
// defaults to the current one (agents may add it, never remove it).
bridge_owner_review_roles_body :: proc(ctx:^Owner_Agent_Ctx,st:owner.Agent_Task_State,p:json.Object,children:^[dynamic]owner.Child) -> (string,string,string) {
    s:=ctx.store
    list,is_list:=p["pairs"].(json.Array)
    if !is_list || len(list)<1 || len(list)>16 do return "","bad_request","review roles require 1-16 pairs of {role, agent_id}"
    pairs:=make(json.Array,0,len(list),context.temp_allocator)
    for item in list {
        o,obj:=item.(json.Object)
        if !obj do return "","bad_request","each review role pair is {role, agent_id}"
        role,agent_id,instance:=bridge_owner_pstr(o,"role"),bridge_owner_pstr(o,"agent_id"),bridge_owner_pstr(o,"instance_id")
        if !contracts.owner_field_valid(role,"id") || !contracts.owner_field_valid(agent_id,"id") do return "","bad_request","each review role pair needs a role and an agent_id"
        child:owner.Child
        if instance=="" {
            resolved,code,message:=bridge_owner_resolve_agent(ctx,st.chain_id,agent_id,"--role")
            if code!="ok" do return "",code,message
            child=resolved
        } else {
            current,live:=bridge_owner_child_locked(instance,"")
            if !live || current.agent_id!=agent_id do return "","invalid_scope",fmt.tprintf("%s is not a running instance of %s on this Bridge",instance,agent_id)
            child=current
        }
        append(children,child)
        append(&pairs,json.Object{"role"=json.String(role),"agent_id"=json.String(agent_id),"instance_id"=json.String(child.instance)})
    }
    rows,read:=owner.query(s.db,"SELECT COALESCE(max(revision),0),COALESCE((SELECT requires_user_approval FROM local_role_configs WHERE chain_id=?1 AND task_id=?2 ORDER BY revision DESC LIMIT 1),0) FROM local_role_configs WHERE chain_id=?1 AND task_id=?2",st.chain_id,st.task_id)
    if !read || len(rows)!=1 do return "","storage_error","owner store could not be read"
    approval:=rows[0][1]
    if b,present:=p["requires_user_approval"];present && b!=nil {
        v,is_bool:=b.(json.Boolean)
        if !is_bool do return "","bad_request","requires_user_approval must be a boolean"
        approval="1" if bool(v) else "0"
    }
    revision:=fmt.tprintf("%d",owner.number(rows[0][0])+1)
    return bridge_owner_json(map[string]string{"configuration_revision"=revision,"requires_user_approval"=approval,"pairs"=bridge_owner_json(pairs)}),"ok",""
}
