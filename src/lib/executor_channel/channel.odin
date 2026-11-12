package executor_channel

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Transport encryption is distinct from command authorization. The expected
// scope comes from a pending exchange, never from an unchecked Hub assertion.
// Retries keep their signed operation identity; durable handlers deduplicate.
DOMAIN :: "heimdall-executor/channel/v1"
scope_live :: proc(scope:json.Object,kr:^vault.Vault_Keyring,now:i64)->bool {
    return kr!=nil && contracts.executor_valid(scope,"transport_scope") &&
        contracts.owner_string(scope,"account_id")==vault.keyring_user_id(kr) &&
        // The scope is stamped by whichever Bridge sent the request; a reply
        // reuses it on the other host, so both ends tolerate clock skew.
        contracts.executor_peer_issued(contracts.executor_number(scope,"issued_ms"),now) &&
        contracts.executor_peer_unexpired(contracts.executor_number(scope,"request_expires_ms"),now)
}
aad :: proc(scope:json.Object,id:vault.Vault_Id,epoch:u32)->(string,bool) {
    canonical,ok:=contracts.executor_canonical("transport_scope",scope)
    if !ok || epoch==0 || id==(vault.Vault_Id{}) do return "",false
    buf:[vault.VAULT_ID_HEX_CHARS]byte
    return fmt.tprintf("%s\n%s\n%d\n%s",DOMAIN,vault.vault_id_hex(id,buf[:]),epoch,canonical),true
}
// Deterministic core for shared vectors. Production callers use seal.
seal_with_nonce :: proc(plain:string,kr:^vault.Vault_Keyring,scope:json.Object,now:i64,nonce:[]byte,
    allocator:=context.allocator)->(string,bool) {
    if !scope_live(scope,kr,now) || len(plain)>contracts.EXECUTOR_DOCUMENT_MAX do return "",false
    key,found:=vault.keyring_key_for_epoch(kr,kr.current_epoch)
    associated,valid:=aad(scope,kr.vault_id,kr.current_epoch)
    if !found || !valid do return "",false
    return vault.seal_with_nonce_aad(transmute([]byte)plain,key,kr.vault_id,kr.current_epoch,nonce,transmute([]byte)associated,allocator)
}
seal :: proc(plain:string,kr:^vault.Vault_Keyring,scope:json.Object,now:i64,allocator:=context.allocator)->(string,bool) {
    nonce:[12]byte
    if !random.fill(nonce[:]) do return "",false
    return seal_with_nonce(plain,kr,scope,now,nonce[:],allocator)
}

// AEAD-only primitive: plaintext is not authority. Prefer open_signed for the
// defined Bridge request/reply records and verify current enrolled keys first.
open :: proc(token:string,kr:^vault.Vault_Keyring,expected:json.Object,now:i64,allocator:=context.allocator)->(string,bool) {
    if len(token)>65536 || !scope_live(expected,kr,now) do return "",false
    id,epoch,payload,result:=vault.envelope_parse(token,context.temp_allocator)
    if result!=.Ok do return "",false
    defer crypto.zero_explicit(raw_data(payload),len(payload))
    if id!=kr.vault_id || epoch!=kr.current_epoch || len(payload)>contracts.EXECUTOR_DOCUMENT_MAX+28 do return "",false
    key,found:=vault.keyring_key_for_epoch(kr,epoch)
    associated,valid:=aad(expected,id,epoch)
    if !found || !valid do return "",false
    plain,opened:=vault.open_payload_with_key_aad(payload,key,transmute([]byte)associated,allocator)
    return string(plain),opened
}

// Signature and exact correlation checks are mandatory even for account-key
// holders. Historical receipts remain observations, not fresh admission.
open_signed :: proc(token:string,kr:^vault.Vault_Keyring,expected:json.Object,key:contracts.Owner_Verified_Key,
    now:i64,allocator:=context.allocator,query_discovery:bool=false)->(string,bool) {
    method,direction:=contracts.owner_string(expected,"method"),contracts.owner_string(expected,"direction")
    plain,opened:=open(token,kr,expected,now,allocator)
    if !opened do return "",false
    kind:="issuance_consent" if direction=="request" && method=="enrollment" else method
    if direction=="response" {
        if method=="prepare" || method=="action" {kind="receipt"} else if method=="fence_request" {kind="fence_reply"} else if method=="notification" {kind="notification_result"} else if method=="notification_fence_request" {kind="notification_fence_reply"}
    }
    o,parsed:=contracts.executor_parse(plain,kind)
    valid:=parsed && contracts.executor_verify(kind,o,key)
    if kind=="receipt" && ((method=="prepare")!=(contracts.owner_string(o,"method")=="prepare")) do valid=false
    for name in ([4]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id"}) {
        if contracts.owner_string(o,name)!=contracts.owner_string(expected,name) do valid=false
    }
    if method!="enrollment" && contracts.owner_string(o,"reservation_id")!=contracts.owner_string(expected,"reservation_id") do valid=false
    for name in ([2]string{"owner_incarnation","executor_incarnation"}) {
        if name=="executor_incarnation" && query_discovery && direction=="response" && kind=="receipt" &&
           method=="action" && contracts.owner_string(o,"method")=="query" &&
           contracts.executor_number(o,"executor_incarnation")>=contracts.executor_number(expected,"executor_incarnation") &&
           contracts.owner_string(o,"child_incarnation")==contracts.owner_string(expected,"executor_incarnation") {continue}
        if name in o && contracts.owner_string(o,name)!=contracts.owner_string(expected,name) do valid=false
    }
    input,fence:string
    if direction=="request" {
        input,_=contracts.executor_digest(kind,o)
        fence=contracts.owner_string(o,"prepare_digest")
        if method=="prepare" {fence=input} else if (method=="fence_request" || method=="notification_fence_request") {fence=contracts.owner_string(o,"action_digest")} else if method=="enrollment" {fence=contracts.owner_string(o,"selection_digest")}
    } else if method=="enrollment" {
        input=contracts.owner_string(o,"configuration_digest");fence=input
    } else if method=="fence_request" || method=="notification_fence_request" {
        input=contracts.owner_string(o,"request_digest");fence=contracts.owner_string(o,"action_digest")
    } else {
        input=contracts.owner_string(o,"input_digest");fence=contracts.owner_string(o,"prepare_digest")
    }
    if input!=contracts.owner_string(expected,"input_digest") || fence!=contracts.owner_string(expected,"fence_digest") do valid=false
    if !valid {crypto.zero_explicit(raw_data(plain),len(plain));delete(plain,allocator);return "",false}
    return plain,true
}

// The caller supplies saved consent/selection and current enrolled keys.
// Read-only historical output never authorizes a launch.
open_issuance :: proc(token:string,kr:^vault.Vault_Keyring,expected,consent:json.Object,selection:string,
    device_key,executor_key:contracts.Owner_Verified_Key,now:i64,current_admission:=true,allocator:=context.allocator)->(string,bool) {
    if contracts.owner_string(expected,"method")!="enrollment" || contracts.owner_string(expected,"direction")!="response" do return "",false
    input,_:=contracts.executor_digest("issuance_consent",consent)
    if contracts.owner_string(expected,"input_digest")!=input ||
       contracts.owner_string(expected,"fence_digest")!=contracts.owner_string(consent,"selection_digest") {return "",false}
    for name in ([4]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id"}) {
        if contracts.owner_string(expected,name)!=contracts.owner_string(consent,name) do return "",false
    }
    plain,opened:=open(token,kr,expected,now,allocator)
    if !opened do return "",false
    bundle,valid:=contracts.executor_parse(plain,"issuance_bundle")
    receipt,r_ok:=contracts.executor_parse(contracts.owner_string(bundle,"issuance_receipt"),"issuance_receipt")
    enrollment,e_ok:=contracts.executor_parse(contracts.owner_string(bundle,"attestation"),"enrollment")
    config,c_ok:=contracts.owner_parse(contracts.owner_string(bundle,"configuration"),"remote_configuration")
    if !valid || !r_ok || !e_ok || !c_ok ||
       !contracts.executor_issuance_matches(receipt,consent,selection,contracts.owner_string(bundle,"configuration"),enrollment,device_key,executor_key,now,current_admission) ||
       (current_admission && !issuance_auto(selection) && contracts.owner_string(config,"executor_incarnation")!=contracts.owner_string(expected,"executor_incarnation")) {
        crypto.zero_explicit(raw_data(plain),len(plain));delete(plain,allocator);return "",false
    }
    return plain,true
}

// An owner-Bridge (auto) request cannot know the executor's incarnation; the
// executor's signed configuration names it and later launch fences bind it.
issuance_auto :: proc(selection:string)->bool {
    o,ok:=contracts.executor_parse(selection,"issuance_selection")
    return ok && contracts.executor_selection_auto(o)
}

// Child results use a separately signed owner receipt over the exact result
// bytes, including failures. AEAD possession alone cannot forge a result.
open_child_result :: proc(token:string,kr:^vault.Vault_Keyring,expected,request:json.Object,
    owner_key:contracts.Owner_Verified_Key,now:i64,allocator:=context.allocator)->(string,bool) {
    get:=contracts.owner_string
    digest,_:=contracts.executor_digest("child_request",request)
    if get(expected,"method")!="child_request" || get(expected,"direction")!="response" ||
       get(expected,"input_digest")!=digest || get(expected,"fence_digest")!=get(request,"prepare_digest") {return "",false}
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) {
        if get(expected,name)!=get(request,name) do return "",false
    }
    plain,opened:=open(token,kr,expected,now,allocator)
    if !opened do return "",false
    defer {crypto.zero_explicit(raw_data(plain),len(plain));delete(plain,allocator)}
    bundle,valid:=contracts.executor_parse(plain,"child_result_bundle")
    receipt,parsed:=contracts.executor_parse(get(bundle,"receipt"),"child_result")
    if !valid || !parsed || !contracts.executor_child_result_matches(receipt,request,get(bundle,"body"),owner_key,now) {return "",false}
    // Plaintext is wiped above; return a distinct caller-owned body.
    return strings.clone(get(bundle,"body"),allocator),true
}
