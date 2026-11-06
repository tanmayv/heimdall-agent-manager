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
