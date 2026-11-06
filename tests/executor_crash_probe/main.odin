#+feature dynamic-literals
package main
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

require :: proc(ok:bool,message:string) {if !ok {fmt.eprintln(message);os.exit(1)}}
doc :: proc(kind:string)->json.Object {
    v,_:=contracts.owner_content_document(#load("../../src/contracts/fixtures/executor-v1.json",string));root,_:=v.(json.Object);items,_:=root["valid"].(json.Array)
    for item in items {row,_:=item.(json.Object);if contracts.owner_string(row,"kind")==kind {o,ok:=contracts.executor_parse(contracts.owner_string(row,"raw"),kind);require(ok,"parse");return o}}
    require(false,"missing fixture");return nil
}
set :: proc(o:json.Object,key,value:string) {m:=o;m[key]=json.String(value)}
sign :: proc(o:json.Object,kind:string,key:^ecdsa.Private_Key)->string {
    c,ok:=contracts.executor_canonical(kind,o);require(ok,"canonical")
    sig,signed:=vault.sign_p256(key,transmute([]byte)c);require(signed,"signature")
    m:=o;m["signature"]=json.String(vault.hex_encode_lower(sig.sig[:],context.temp_allocator))
    return executor.encode(m)
}
key :: proc(id,key_id:string,scalar:u8)->(ecdsa.Private_Key,contracts.Owner_Verified_Key) {
    private:ecdsa.Private_Key;bytes:[32]byte;bytes[31]=scalar
    require(ecdsa.private_key_set_bytes(&private,.SECP256R1,bytes[:]),"fixed fixture key")
    pub:[65]byte;ecdsa.private_key_public_bytes(&private,pub[:])
    return private,contracts.Owner_Verified_Key{"account",id,key_id,vault.hex_encode_lower(pub[:],context.temp_allocator),"bridge",true,false}
}
main :: proc() {
    context.allocator=context.temp_allocator
    require(len(os.args)==4,"usage: executor-crash-probe seed|verify path prepare|activate|launch")
    mode,path,stage:=os.args[1],os.args[2],os.args[3]
    host_private,host:=key("executor","operator",1);owner_private,owner:=key("owner1","owner1",2)
    s:executor.Store
    require(executor.open(&s,path,"account","executor","operator"),"open")
    p:=doc("prepare");raw:=sign(p,"prepare",&owner_private)
    resolved:=executor.Resolved_Resources{contracts.owner_string(p,"directory_key"),"default","instance","1"}
    digest,_:=contracts.executor_digest("prepare",p)
    a:=doc("action");set(a,"prepare_digest",digest)
    current:=executor.Current_Owner_Fence{true,digest,1,1}
    if mode=="seed" {
        require(executor.install_policy(&s,sign(doc("policy"),"policy",&host_private),host,1000).code=="ok","policy")
        require(executor.prepare(&s,raw,owner,1000,resolved).code=="ok","prepare")
        if stage!="prepare" {
            require(executor.action(&s,sign(a,"action",&owner_private),owner,1100,current).code=="ok","activate")
        }
        if stage=="launch" {_,ok:=executor.take_intent(&s,1200);require(ok,"claim intent")}
        fmt.println("COMMITTED",stage)
        // Parent SIGKILLs here; no close, destructor or graceful shutdown runs.
        time.sleep(time.Minute)
        os.exit(2)
    }
    require(mode=="verify" && s.incarnation==2,"restart incarnation")
    replay:=executor.prepare(&s,raw,owner,4000,resolved)
    require(replay.code=="ok" && replay.replay,"historical prepare")
    rows,ok:=executor.query(s.db,"SELECT state,instance_id,launch_key,launch_state FROM executor_reservations WHERE reservation_id='reservation'")
    require(ok && len(rows)==1,"exact retained reservation")
    _,claimed:=executor.take_intent(&s,4000);require(!claimed,"no duplicate launch during recovery")
    if stage=="prepare" {
        require(rows[0][0]=="released","unactivated preparation released after restart")
    } else {
        require(rows[0][0]=="active","active resources remain charged")
        require(!executor.complete_recovery(&s,4000),"live child must reconcile")
        if stage=="launch" {require(rows[0][3]=="uncertain","ambiguous intent remains uncertain")}
        require(executor.observe_child(&s,"reservation",executor.Child_Observation{rows[0][1],rows[0][2],s.incarnation,false}),"exact fixture absence observation")
        replay=executor.action(&s,sign(a,"action",&owner_private),owner,4000)
        require(replay.code=="ok" && replay.replay,"activation replay is historical")
    }
    require(executor.complete_recovery(&s,4000),"complete recovery")
    _,claimed=executor.take_intent(&s,4000);require(!claimed,"replay cannot spawn")
    checks,clean:=executor.query(s.db,"PRAGMA foreign_key_check");require(clean && len(checks)==0,"foreign keys")
    executor.close(&s)
    fmt.println("PASS",stage,"crash boundary, exact replay and reconciliation")
}
