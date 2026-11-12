#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// Called with owner serialization immediately after execution_child resolves
// the exact native identity. The remote child never supplies a signed command,
// task grant, work attempt, or an authoritative Child record.
bridge_owner_executor_child_apply :: proc(s:^owner.Store,input_raw:string,child:owner.Child,key:contracts.Owner_Verified_Key,
    kr:^vault.Vault_Keyring=nil,followup:^Owner_Executor_Child_Followup=nil)->string {
    if verb,is_verb:=contracts.executor_parse(input_raw,"agent_verb");is_verb {
        return bridge_owner_executor_child_verb(s,verb,child,key,kr,followup)
    }
    input,valid:=contracts.owner_parse(input_raw,"lease_input")
    lifecycle:=false
    if !valid {input,valid=contracts.owner_parse(input_raw,"lifecycle_input");lifecycle=valid}
    if !valid do return bridge_owner_json(owner.Result{code="malformed"})
    command:=make(json.Object,context.temp_allocator)
    cap:=contracts.owner_string(input,"capability")
    for name in ([10]string{"chain_id","task_id","lease_id","configuration_revision","expected_revision","operation_id","method","request_expires_ms","protocol_version","capability_digest"}) {
        command[name]=json.String(contracts.owner_payload_digest(cap)) if name=="capability_digest" else input[name]
    }
    command["account_id"]=json.String(s.account);command["owner_bridge_id"]=json.String(s.owner)
    command["instance_id"]=json.String(child.instance);command["launch_epoch"]=json.String(child.epoch)
    command["run_count"]=json.String(fmt.tprintf("%d",child.run_count));command["token_generation"]=json.String(child.token_generation)
    command["key_id"]=json.String(s.owner_key);command["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    kind:="lifecycle_command" if lifecycle else "lease_command"
    payload:=""
    if lifecycle {
        payload=contracts.owner_string(input,"payload")
        command["payload_digest"]=json.String(contracts.owner_payload_digest(payload))
    }
    signature,signed:=bridge_owner_sign(nil,kind,command)
    if !signed do return bridge_owner_json(owner.Result{code="signer_unavailable"})
    command["signature"]=json.String(signature)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    result:owner.Result
    if lifecycle {
        proof:=bridge_owner_source_proof(s,contracts.owner_string(command,"chain_id"),contracts.owner_string(command,"task_id"))
        result=owner.execute_lifecycle(s,bridge_owner_json(command),payload,cap,child,key,now,{nil,bridge_owner_sign},proof)
        // A remote lifecycle submit plans no review itself: the matcher's
        // review pass for the chain does (bridge_owner_match_reviews).
        if result.code=="ok" && followup!=nil && contracts.owner_string(input,"method")=="lease.submit" {
            followup.match_chain=strings.clone(contracts.owner_string(input,"chain_id"),context.temp_allocator)
        }
    } else {result=owner.execute_lease(s,bridge_owner_json(command),cap,child,key,now,{nil,bridge_owner_sign})}
    return bridge_owner_json(result)
}

// What an agent verb owes once every owner lock is released (as
// bridge_owner_agent_route does for a local child): review leases to wake
// and the chain's matcher run.
Owner_Executor_Child_Followup :: struct {
    reviews:Owner_Review_Dispatch,
    match_chain:string,
}
bridge_owner_executor_child_followup :: proc(f:^Owner_Executor_Child_Followup) {
    bridge_owner_review_dispatch(f.reviews)
    if f.match_chain!="" do bridge_owner_match_run(f.match_chain,true)
    f^={}
}

// A remote (executor-launched) child's ordinary agent verb. execution_child
// already proved the exact child and that the input names its own chain,
// task, lease and revision; this keeps every task-addressed verb on that
// task, then runs the same owner handler a local child reaches. The result
// is the full local response (code and reason), carried back as the body.
bridge_owner_executor_child_verb :: proc(s:^owner.Store,verb:json.Object,child:owner.Child,key:contracts.Owner_Verified_Key,
    kr:^vault.Vault_Keyring,followup:^Owner_Executor_Child_Followup)->string {
    get:=contracts.owner_string
    method,chain,task:=get(verb,"method"),get(verb,"chain_id"),get(verb,"task_id")
    reply:=proc(response:string)->string {return bridge_owner_json(owner.Result{code="ok",body=response})}
    p:=bridge_owner_params(get(verb,"params"))
    for name in ([2]string{"chain_id","task_id"}) {
        own:=chain if name=="chain_id" else task
        if named:=bridge_owner_pstr(p,name);named!="" && named!=own {
            return reply(bridge_local_response_error("","invalid_scope",fmt.tprintf("remote agents may act only on their own task (%s %s); %s %s refused",name,own,method,named)))
        }
        p[name]=json.String(own)
    }
    if lease:=bridge_owner_pstr(p,"lease_id");lease!="" && lease!=get(verb,"lease_id") {
        return reply(bridge_local_response_error("","invalid_scope",fmt.tprintf("remote agents may act only on their own lease %s",get(verb,"lease_id"))))
    }
    if kr==nil do return reply(bridge_local_response_error("","vault_locked","owner Bridge vault is locked"))
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id=child.instance,role=.Agent}
    // No run_dir: a remote child's TASK.md is written by its executor Bridge.
    ctx:=Owner_Agent_Ctx{store=s,child=child,key=key,kr=kr,now=time.to_unix_nanoseconds(time.now())/1000000,rec=rec}
    response:=bridge_owner_agent_exec(&ctx,method,p)
    if response=="" && ctx.pending.active do response=bridge_local_response_data("",bridge_owner_json(ctx.pending.next))
    bridge_owner_publish()
    if followup!=nil && bridge_owner_response_ok(response) {
        followup.reviews=ctx.reviews
        if bridge_owner_match_method(method) do followup.match_chain=strings.clone(chain,context.temp_allocator)
    }
    return reply(response)
}
