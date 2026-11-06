#+feature dynamic-literals
package main

// Isolated test executable. Fixed keys are disposable fixtures, never enrolled
// identities. The Python driver kills this process at SQLite commit boundaries.
import "base:runtime"
import "core:c"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

when ODIN_OS==.Windows { foreign import sqlite "system:sqlite3.lib" } else { foreign import sqlite "system:sqlite3" }
foreign sqlite {
    sqlite3_commit_hook :: proc "c"(db:owner.DB,callback:proc "c"(rawptr)->c.int,arg:rawptr)->rawptr ---
}
boundary :: proc(name:string) {
    fmt.println(name)
    // A bounded wait gives the driver a deterministic point to SIGKILL. No
    // Store.close/rollback executes, and the writer lock dies with the process.
    time.sleep(20*time.Second)
    os.exit(74)
}
before_commit :: proc "c"(_:rawptr)->c.int {
    context=runtime.default_context()
    boundary("before_commit")
    return 1
}
sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    raw,ok:=contracts.owner_canonical(kind,o)
    if !ok do return "",false
    sig,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)raw)
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator),signed
}
signed_command :: proc(priv:^ecdsa.Private_Key,method,op,task,payload,revision:string)->string {
    object:=owner.doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","immutable_owner_bridge"="bridge",
      "principal_id"="device","key_id"="device","operation_id"=op,"method"=method,"task_id"=task,"payload_digest"=contracts.owner_payload_digest(payload),
      "expected_revision"=revision,"request_expires_ms"="2000","signature"=strings.repeat("0",128,context.temp_allocator)})
    signature,_:=sign(priv,"command",object);object["signature"]=json.String(signature)
    return owner.encode(object)
}
main :: proc() {
    context.allocator=context.temp_allocator
    if len(os.args)!=3 do os.exit(2)
    mode,path:=os.args[1],os.args[2]
    s:owner.Store
    if !owner.open(&s,path,"account","bridge","bridge_key") do os.exit(3)
    if !owner.observe_directory(&s,1,"head") do os.exit(4)
    creator_priv,owner_priv:ecdsa.Private_Key
    scalar:[32]byte;scalar[31]=1
    if !ecdsa.private_key_set_bytes(&creator_priv,.SECP256R1,scalar[:]) do os.exit(5)
    scalar[31]=2
    if !ecdsa.private_key_set_bytes(&owner_priv,.SECP256R1,scalar[:]) do os.exit(5)
    pub:[65]byte
    ecdsa.private_key_public_bytes(&creator_priv,pub[:])
    creator:=contracts.Owner_Verified_Key{"account","device","device",vault.hex_encode_lower(pub[:],context.temp_allocator),"device",true,false}
    ecdsa.private_key_public_bytes(&owner_priv,pub[:])
    bridge:=contracts.Owner_Verified_Key{"account","bridge","bridge_key",vault.hex_encode_lower(pub[:],context.temp_allocator),"bridge",true,false}
    id,_:=vault.vault_id_from_root_sign_pub(creator.public_key)
    key:[32]byte;key[0]=5
    kr,_:=vault.keyring_from_single_key("account",id,1,key[:])
    signer:=owner.Signer{&owner_priv,sign}
    if mode=="seed" {
        g:=owner.doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","creation_op"="create","owner_bridge_id"="bridge",
          "owner_key_id"="bridge_key","creator_id"="device","creator_key_id"="device","schema_version"="1","creator_signature"=strings.repeat("0",128,context.temp_allocator),"owner_signature"=strings.repeat("0",128,context.temp_allocator)})
        signature,_:=sign(&creator_priv,"genesis",g);g["creator_signature"]=json.String(signature)
        signature,_=sign(&owner_priv,"genesis",g);g["owner_signature"]=json.String(signature)
        digest,_:=contracts.owner_digest("genesis",g)
        title,_:=vault.seal_string("private chain",&kr,context.temp_allocator)
        description,_:=vault.seal_string("private description",&kr,context.temp_allocator)
        payload:=owner.encode(owner.doc(map[string]string{"genesis_digest"=digest,"title_cipher"=title,"description_cipher"=description}))
        command:=signed_command(&creator_priv,"chain.create","create","",payload,"0")
        result:=owner.execute(&s,command,payload,owner.encode(g),creator,bridge,1,"head",1000,&kr,signer)
        if result.code!="ok" {fmt.println(result.code);os.exit(6)}
        body,_:=vault.seal_string("private task body",&kr,context.temp_allocator)
        payload=owner.encode(owner.doc(map[string]string{"title_cipher"=title,"body_cipher"=body}))
        command=signed_command(&creator_priv,"task.create","task_create","task",payload,"1")
        request:=owner.encode(owner.doc(map[string]string{"command"=command,"payload"=payload}))
        if os.write_entire_file(fmt.tprintf("%s.request",path),transmute([]byte)request)!=nil do os.exit(7)
    } else if strings.has_prefix(mode,"submit_") {
        child:=owner.Child{"instance","epoch",strings.repeat("a",64,context.temp_allocator),1,"author"}
        reviewer:=owner.Child{"review_instance","review_epoch",strings.repeat("b",64,context.temp_allocator),1,"reviewer"}
        if mode=="submit_seed" {
            p:=owner.encode(owner.doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""}))
            command:=signed_command(&creator_priv,"lifecycle.configure","config","task",p,"2")
            r:=owner.execute(&s,command,p,"",creator,bridge,1,"head",1000,&kr,signer,{},owner.Lifecycle_Proof{child,reviewer,true})
            if r.code!="ok" {fmt.println(r.code);os.exit(20)}
            brief,_:=vault.seal_string(`{"goal":"Private submit goal","acceptance":["Private submit acceptance"]}`,&kr,context.temp_allocator)
            p=owner.encode(owner.doc(map[string]string{"requirements_revision"="1","body_cipher"=brief}))
            command=signed_command(&creator_priv,"requirements.edit","requirements","task",p,"3")
            r=owner.execute(&s,command,p,"",creator,bridge,1,"head",1000,&kr,signer)
            if r.code!="ok" {fmt.println(r.code);os.exit(21)}
            bytes,_:=os.read_entire_file(fmt.tprintf("%s.lease",path),context.temp_allocator)
            c,_:=contracts.owner_parse(string(bytes),"lease_command")
            c["expected_revision"]=json.String("4")
            sig,_:=sign(&owner_priv,"lease_command",c);c["signature"]=json.String(sig)
            r=owner.execute_lease(&s,owner.encode(c),"",child,bridge,1000,signer)
            if r.code!="ok" {fmt.println(r.code);os.exit(22)}
            v,_:=json.parse_string(r.body,.JSON,true,context.temp_allocator);result,_:=v.(json.Object)
            cap:=owner.field(result,"capability")
            c["capability_digest"]=json.String(contracts.owner_payload_digest(cap))
            for method in ([3]string{"requirements.present","requirements.ack","lease.submit"}) {
                p=`{"requirements_revision":"1"}`
                if method=="lease.submit" do p=`{"requirements_revision":"1","head":"","summary":"Private submit evidence"}`
                c["method"]=json.String(method);c["operation_id"]=json.String(method)
                c["payload_digest"]=json.String(contracts.owner_payload_digest(p))
                sig,_=sign(&owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
                raw:=owner.encode(c)
                if method=="lease.submit" {
                    request:=owner.encode(owner.doc(map[string]string{"command"=raw,"payload"=p,"capability"=cap}))
                    if os.write_entire_file(fmt.tprintf("%s.submit",path),transmute([]byte)request)!=nil do os.exit(23)
                } else {
                    r=owner.execute_lifecycle(&s,raw,p,cap,child,bridge,1000,signer)
                    if r.code!="ok" {fmt.println(r.code);os.exit(24)}
                }
            }
        } else {
            bytes,err:=os.read_entire_file(fmt.tprintf("%s.submit",path),context.temp_allocator)
            if err!=nil do os.exit(25)
            v,_:=json.parse_string(string(bytes),.JSON,true,context.temp_allocator);request,_:=v.(json.Object)
            if mode=="submit_before" do _=sqlite3_commit_hook(s.db,before_commit,nil)
            now:=i64(1000)
            if mode=="submit_replay" do now=4000000
            r:=owner.execute_lifecycle(&s,owner.field(request,"command"),owner.field(request,"payload"),owner.field(request,"capability"),child,bridge,now,signer,owner.Source_Proof{"",true})
            if r.code!="ok" {fmt.println(r.code);os.exit(26)}
            if mode=="submit_after" do boundary("after_commit")
            fmt.println(owner.encode(r))
        }
    } else if strings.has_prefix(mode,"lease_") {
        child:=owner.Child{"instance","epoch",strings.repeat("a",64,context.temp_allocator),1,"author"}
        if mode=="lease_seed" {
            p:=owner.encode(owner.doc(map[string]string{"instance_id"="instance","configuration_revision"="1","enabled"="1"}))
            c:=signed_command(&creator_priv,"fleet.edit","fleet","task",p,"1")
            r:=owner.execute(&s,c,p,"",creator,bridge,1,"head",1000,&kr,signer,child)
            if r.code!="ok" {fmt.println(r.code);os.exit(13)}
            command:=owner.doc(map[string]string{"protocol_version"="1","account_id"="account","owner_bridge_id"="bridge","chain_id"="chain","task_id"="task",
                "lease_id"="lease","instance_id"="instance","launch_epoch"="epoch","run_count"="1","token_generation"=child.token_generation,
                "configuration_revision"="1","expected_revision"="2","operation_id"="claim","method"="lease.claim","request_expires_ms"="2000",
                "capability_digest"=contracts.owner_payload_digest(""),"key_id"="bridge_key","signature"=strings.repeat("0",128,context.temp_allocator)})
            sig,_:=sign(&owner_priv,"lease_command",command);command["signature"]=json.String(sig)
            if os.write_entire_file(fmt.tprintf("%s.lease",path),transmute([]byte)owner.encode(command))!=nil do os.exit(14)
        } else if mode=="lease_expire" {
            if !owner.expire_leases(&s,901001) do os.exit(15)
        } else {
            bytes,err:=os.read_entire_file(fmt.tprintf("%s.lease",path),context.temp_allocator)
            if err!=nil do os.exit(16)
            if mode=="lease_before" do _=sqlite3_commit_hook(s.db,before_commit,nil)
            now:=i64(1000)
            if mode=="lease_replay" do now=901002
            r:=owner.execute_lease(&s,string(bytes),"",child,bridge,now,signer)
            if r.code!="ok" {fmt.println(r.code);os.exit(17)}
            if mode=="lease_after" do boundary("after_commit")
            fmt.println(owner.encode(r))
        }
    } else if mode=="claim_kill" || mode=="settle" {
        claims,ok:=owner.intent_claim_due(&s,1000)
        if !ok || len(claims)==0 do os.exit(8)
        if mode=="claim_kill" do boundary("after_claim")
        for claim in claims do if !owner.intent_result(&s,claim,true,"published",1000) do os.exit(9)
        fmt.println("settled")
    } else {
        bytes,err:=os.read_entire_file(fmt.tprintf("%s.request",path),context.temp_allocator)
        if err!=nil do os.exit(10)
        value,parse_err:=json.parse_string(string(bytes),.JSON,true,context.temp_allocator)
        if parse_err!=nil do os.exit(11)
        request,_:=value.(json.Object)
        if mode=="before" do _=sqlite3_commit_hook(s.db,before_commit,nil)
        result:=owner.execute(&s,owner.field(request,"command"),owner.field(request,"payload"),"",creator,bridge,1,"head",1000,&kr,signer)
        if result.code!="ok" {fmt.println(result.code);os.exit(12)}
        if mode=="after" do boundary("after_commit")
        fmt.println(owner.encode(result))
    }
    owner.close(&s)
}
