#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

Signer :: struct {ctx:rawptr,sign:proc(rawptr,string,json.Object)->(string,bool)}
// The caller passes the ORIGINAL parsed request and the corresponding result.
// Historical receipts always say historical=1. They cannot grant activation.
seal_receipt :: proc(s:^Store,request:json.Object,kind:string,result:Result,sign:Signer)->(string,bool) {
    context.allocator=context.temp_allocator
    if result.code!="ok" || (kind!="prepare" && kind!="action") || sign.sign==nil || !contracts.executor_valid(request,kind) || !scope(s,request) do return "",false
    digest,_:=contracts.executor_digest(kind,request)
    // Only immutable identity is read here; result.body is the persisted
    // historical snapshot returned by receipt deduplication.
    value,ok:=contracts.owner_content_document(result.body);body,obj:=value.(json.Object)
    if !ok || !obj || field(body,"reservation_id")!=field(request,"reservation_id") do return "",false
    fields:=contracts.executor_schema("receipt")
    receipt:=make(json.Object,context.temp_allocator)
    for f in fields do receipt[f.name]=json.String("")
    for name in ([6]string{"protocol_version","account_id","executor_bridge_id","owner_bridge_id","chain_id","reservation_id"}) do receipt[name]=request[name]
    for name in ([8]string{"prepare_digest","deadline_version","expires_ms","hard_ms","launch_key","state","executor_incarnation","child_incarnation"}) do receipt[name]=body[name]
    receipt["grant_generation"]=request["grant_generation"]
    receipt["operation_id"]=request["operation_id"]
    receipt["method"]=json.String("prepare" if kind=="prepare" else field(request,"method"))
    receipt["input_digest"]=json.String(digest)
    receipt["historical"]=json.String("1" if result.replay else "0")
    receipt["key_id"]=json.String(s.operator_key)
    receipt["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    if !contracts.executor_valid(receipt,"receipt") do return "",false
    signature,signed:=sign.sign(sign.ctx,"receipt",receipt)
    if !signed do return "",false
    receipt["signature"]=json.String(signature)
    return encode(receipt),true
}
