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
issuance_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,valid:=contracts.executor_canonical(kind,o)
    if !valid do return "",false
    signature,ok:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    return vault.hex_encode_lower(signature.sig[:],context.temp_allocator),ok
}
main :: proc() {
    context.allocator=context.temp_allocator
    require(len(os.args)==4,"usage: executor-crash-probe seed|verify path issuance|prepare|activate|launch")
    mode,path,stage:=os.args[1],os.args[2],os.args[3]
    host_private,host:=key("executor","operator",1);owner_private,owner:=key("owner1","owner1",2)
    s:executor.Store
    require(executor.open(&s,path,"account","executor","operator"),"open")
    if stage=="issuance" {
        device_private,device:=key("owner2","owner2",3);device.kind="device"
        if mode=="seed" {
            require(executor.install_policy(&s,sign(doc("policy"),"policy",&host_private),host,1000).code=="ok","issuance policy")
            require(executor.install_directory(&s,sign(doc("directory"),"directory",&host_private),host,1000,"/repo").code=="ok","issuance mapping")
            selection:=executor.encode(doc("issuance_selection"));consent:=doc("issuance_consent")
            set(consent,"selection_digest",contracts.owner_payload_digest(selection))
            resources:=executor.Issuance_Resources{contracts.owner_payload_digest(selection),executor.directory_key("executor","/repo"),"/repo",true}
            result:=executor.issue(&s,sign(consent,"issuance_consent",&device_private),selection,device,host,1100,resources,executor.Signer{&host_private,issuance_sign})
            require(result.code=="ok","issue commit")
            fmt.println("COMMITTED",stage)
            time.sleep(time.Minute);os.exit(2)
        }
        rows,ok:=executor.query(s.db,"SELECT consent,selection,result_json,configuration,token_secret FROM executor_issuances")
        require(ok && len(rows)==1,"one committed issuance survives crash")
        replay:=executor.issue(&s,rows[0][0],rows[0][1],device,host,5000,{},{})
        require(replay.code=="ok" && replay.replay && replay.body==rows[0][2],"original issuance exact replay after expiry/restart")
        config,valid:=contracts.owner_parse(rows[0][3],"remote_configuration")
        require(valid && contracts.owner_string(config,"executor_incarnation")=="1" && contracts.owner_string(config,"token_generation")==contracts.owner_payload_digest(rows[0][4]),"physical identity and credential unchanged")
        count,_:=executor.query(s.db,"SELECT (SELECT count(*) FROM executor_reservations),(SELECT count(*) FROM executor_intents)")
        require(count[0][0]=="0" && count[0][1]=="0","issuance never creates reservation or launch")
        executor.close(&s);fmt.println("PASS",stage);return
    }
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
        if stage=="launch" {intent,ok:=executor.take_intent(&s,1200);require(ok,"claim intent");require(executor.begin_dispatch(&s,intent,1200),"dispatch fence") }
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
