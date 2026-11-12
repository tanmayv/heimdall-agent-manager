#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"

// The Bridge resolves both keys from the current paired directory and holds
// its owner serialization until the ordinary lease/lifecycle handler finishes.
// A remote process cannot supply a Child or create a task grant through this
// boundary: identity comes from the owner's original journal and assignment.
execution_child :: proc(s:^Store,request_raw,input_raw:string,executor_key,owner_key:contracts.Owner_Verified_Key,
    now:i64)->(Child,bool) {
    now:=store_now(s,now) // C1: monotonic clamp, never refuse on the clock
    r,parsed:=contracts.executor_parse(request_raw,"child_request")
    if !parsed || !execution_owner_key(s,owner_key) || !contracts.executor_verify("child_request",r,executor_key) ||
       field(r,"account_id")!=s.account || field(r,"owner_bridge_id")!=s.owner ||
       contracts.executor_number(r,"owner_incarnation")!=s.incarnation {return {},false}
    input,valid:=contracts.owner_parse(input_raw,"lease_input")
    if !valid {input,valid=contracts.owner_parse(input_raw,"lifecycle_input")}
    if !valid {input,valid=contracts.executor_parse(input_raw,"agent_verb")}
    // Initial remote grants exist only through preparation/commit. A live
    // child may use its existing grant, never initiate a replacement claim.
    if !valid || field(input,"method")=="lease.claim" do return {},false
    tx:Transaction
    if !transaction_begin(s,&tx) do return {},false
    defer transaction_rollback(&tx)
    if execution_clock(&tx,now)!="ok" do return {},false
    rows,ok:=query(s.db,`SELECT b.document,j.prepare_json,j.lease_command,j.child_json
      FROM owner_execution_bootstraps b JOIN owner_execution_journal j USING(reservation_id)
      WHERE j.reservation_id=? AND j.state='committed'`,field(r,"reservation_id"))
    if !ok || len(rows)!=1 do return {},false
    row:=rows[0]
    b,b_ok:=contracts.executor_parse(row[0],"bootstrap")
    p,p_ok:=contracts.executor_parse(row[1],"prepare")
    c,c_ok:=contracts.owner_parse(row[2],"lease_command")
    renewal:json.Object
    if b_ok && field(r,"deadline_version")!=field(b,"deadline_version") {
        saved,read:=query(s.db,"SELECT payload_json FROM runtime_intents WHERE kind='executor.heartbeat' AND chain_id=? AND principal_id=? AND json_extract(payload_json,'$.reservation_id')=? AND json_extract(payload_json,'$.deadline_version')=?",
            field(b,"chain_id"),field(b,"instance_id"),field(b,"reservation_id"),field(r,"deadline_version"))
        if !read || len(saved)!=1 do return {},false
        parsed:bool
        renewal,parsed=contracts.executor_parse(saved[0][0],"action")
        if !parsed do return {},false
    }
    if !b_ok || !p_ok || !c_ok || !remote_assignment_key_matches(s,p,executor_key) ||
       !contracts.executor_child_request_matches(r,b,input_raw,executor_key,owner_key,now,renewal) ||
       now>=contracts.executor_number(r,"expires_ms") || now>=contracts.executor_number(r,"hard_ms") {return {},false}
    child,current:=execution_assignment(s,p,c,false)
    original:Child
    if !current || json.unmarshal_string(row[3],&original,.JSON,context.temp_allocator)!=nil ||
       encode(original)!=encode(child) {return {},false}
    if !transaction_commit(&tx) do return {},false
    return child,true
}

execution_child_result :: proc(request:json.Object,body:string,scope:json.Object,owner_key:contracts.Owner_Verified_Key,
    now:i64,kr:^vault.Vault_Keyring,sign:Signer)->(string,bool) {
    if sign.sign==nil || !contracts.executor_peer_unexpired(contracts.executor_number(request,"request_expires_ms"),now) do return "",false
    r:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("child_result") do r[entry.name]=request[entry.name]
    digest,_:=contracts.executor_digest("child_request",request)
    r["request_digest"]=json.String(digest);r["result_digest"]=json.String(contracts.owner_payload_digest(body))
    r["issued_ms"]=json.String(fmt.tprintf("%d",now))
    r["key_id"]=json.String(owner_key.key_id);r["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    signature,signed:=sign.sign(sign.ctx,"executor.child_result",r)
    if !signed do return "",false
    r["signature"]=json.String(signature)
    if !contracts.executor_child_result_matches(r,request,body,owner_key,now,owner_side=true) do return "",false
    bundle:=encode(struct{receipt,body:string}{encode(r),body})
    if _,valid:=contracts.executor_parse(bundle,"child_result_bundle");!valid do return "",false
    response:=make(json.Object,context.temp_allocator)
    for name,value in scope do response[name]=value
    response["direction"]=json.String("response")
    return channel.seal(bundle,kr,response,now,context.temp_allocator)
}
