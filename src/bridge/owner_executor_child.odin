#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

// Called with owner serialization immediately after execution_child resolves
// the exact native identity. The remote child never supplies a signed command,
// task grant, work attempt, or an authoritative Child record.
bridge_owner_executor_child_apply :: proc(s:^owner.Store,input_raw:string,child:owner.Child,key:contracts.Owner_Verified_Key)->string {
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
    } else {result=owner.execute_lease(s,bridge_owner_json(command),cap,child,key,now,{nil,bridge_owner_sign})}
    return bridge_owner_json(result)
}
