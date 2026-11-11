#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

chain_create_test_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=contracts.owner_canonical(kind,o)
    if !ok do return "",false
    sig,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    if !signed do return "",false
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator),true
}
chain_create_test_key :: proc(t:^testing.T,priv:^ecdsa.Private_Key,principal,key_id:string) -> contracts.Owner_Verified_Key {
    testing.expect(t,vault.p256_private_key_generate(priv))
    pub:[65]byte;ecdsa.private_key_public_bytes(priv,pub[:])
    return contracts.Owner_Verified_Key{"account",principal,key_id,vault.hex_encode_lower(pub[:],context.temp_allocator),"bridge",true,false}
}

@(test)
test_owner_chain_create_route_and_input_refusals :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=bridge_agent_route("agent.task_chain.create",`{"title":"x"}`)
    testing.expect(t,r.kind==.Local && r.local_op=="task_chain.create","agent chain create is served by the owner Bridge")
    testing.expect(t,bridge_agent_method_allowed("agent.task_chain.create"))
    testing.expect(t,!bridge_owner_routable("agent.task_chain.create"),"create names no existing owner chain")
    wrapper:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_x",role=.Wrapper}
    testing.expect(t,strings.contains(bridge_owner_chain_create("r1",`{"title":"x"}`,wrapper),`"code":"invalid_scope"`),"wrapper tokens never create chains")
    agent:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_x",role=.Agent}
    testing.expect(t,strings.contains(bridge_owner_chain_create("r2",`{"title":"  "}`,agent),`"code":"bad_request"`),"title required")
    testing.expect(t,strings.contains(bridge_owner_chain_create("r3",`{"title":"x","coordinator_agent_id":"bad id/../"}`,agent),`"code":"bad_request"`),"coordinator agent id validated")
    id:=bridge_owner_chain_id("chain_")
    testing.expect(t,strings.has_prefix(id,"chain_") && len(id)==6+32 && contracts.owner_field_valid(id,"id"),"UI ownerId shape")
}

// The Bridge-built genesis/command are exactly what the owner store admits
// for a Bridge creator, and only for this store's own owner key.
@(test)
test_owner_chain_create_documents_execute_and_bind_once :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    priv,other:ecdsa.Private_Key
    defer {ecdsa.private_key_clear(&priv);ecdsa.private_key_clear(&other)}
    key:=chain_create_test_key(t,&priv,"bridge","bridge_key")
    alien:=chain_create_test_key(t,&other,"bridge","bridge_key")
    root:=fmt.tprintf("%s/.cache/heimdall-tests/owner-chain-create-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(root)==nil)
    defer _=os.remove_all(root)
    s:owner.Store
    if !testing.expect(t,owner.open(&s,fmt.tprintf("%s/runtime.sqlite",root),"account","bridge","bridge_key")) do return
    defer owner.close(&s)
    vid,_:=vault.vault_id_from_root_sign_pub(key.public_key)
    secret:[32]byte;secret[0]=7
    kr,_:=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&kr)
    tc,_:=vault.seal_string("agent chain",&kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&kr,context.temp_allocator)
    signer:=owner.Signer{&priv,chain_create_test_sign}

    // A foreign key cannot pose as this owner, even with the owner's ids.
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key","chain_alien","op_alien",tc,dc,1000,owner.Signer{&other,chain_create_test_sign})
    testing.expect(t,built)
    testing.expect_value(t,owner.execute(&s,c,p,g,alien,key,0,"",1000,&kr,signer,requested_by="inst_a").code,"invalid_scope")

    g,c,p,built=bridge_owner_chain_create_documents("account","bridge","bridge_key","chain_a","op_a",tc,dc,1000,signer)
    testing.expect(t,built)
    gj,_:=contracts.owner_parse(g,"genesis");cj,_:=contracts.owner_parse(c,"command")
    testing.expect_value(t,contracts.owner_verify_genesis(gj,"account","bridge",key,key),contracts.Owner_Auth_Error.None)
    testing.expect(t,contracts.owner_create_binding(cj,gj,p))
    created:=owner.execute(&s,c,p,g,key,key,0,"",1000,&kr,signer,requested_by="inst_a")
    testing.expect_value(t,created.code,"ok")
    rows,_:=owner.query(s.db,"SELECT (SELECT count(*) FROM local_grant_policy)+(SELECT count(*) FROM local_grants),(SELECT actor_id FROM local_events WHERE kind='chain.create'),(SELECT count(*) FROM runtime_intents WHERE kind='registry')")
    testing.expect_value(t,bridge_owner_json(rows),`[["0","inst_a","1"]]`)

    child:=owner.Child{"inst_a","epoch_a",strings.repeat("a",64,context.temp_allocator),1,"agt_a"}
    testing.expect_value(t,owner.bind_created_coordinator(&s,"chain_a",child,"inst_a",1000).code,"ok")
    testing.expect_value(t,owner.bind_created_coordinator(&s,"chain_a",child,"inst_a",1000).code,"operation_conflict")
    role,coordinator:=bridge_owner_launch_role_from(&s,"chain_a","inst_a","worker","")
    testing.expect(t,role=="coordinator" && coordinator=="inst_a","the bound instance relaunches as coordinator")

    // The bind republishes the chain registry row naming the coordinator, so
    // the Hub listing shows it without an owner read.
    probe:=Chain_Create_Registry_Probe{kr=&kr,signer=signer}
    q:owner.Intent_Completions;defer owner.intent_completions_destroy(&q)
    testing.expect(t,bridge_owner_publish_batch(&s,&q,1000,&probe,chain_create_registry_probe_send))
    testing.expect_value(t,len(probe.published),2)
    last,parsed:=contracts.owner_parse(probe.published[len(probe.published)-1] if len(probe.published)>0 else "","registry")
    testing.expect(t,parsed && contracts.owner_verify_registry(last,"account","bridge",contracts.owner_string(last,"genesis_digest"),key)==.None)
    testing.expect_value(t,contracts.owner_string(last,"coordinator_instance_id"),"inst_a")
    testing.expect_value(t,contracts.owner_string(last,"coordinator_agent_id"),"agt_a")
}

Chain_Create_Registry_Probe :: struct { kr:^vault.Vault_Keyring, signer:owner.Signer, published:[dynamic]string }
// The registry delivery of bridge_owner_publish_registry without the Hub:
// registry rows go out as stored, registry.prepare rows are sealed and signed.
chain_create_registry_probe_send :: proc(ctx:rawptr,s:^owner.Store,claim:owner.Intent_Claim) -> (bool,string,i64) {
    p:=(^Chain_Create_Registry_Probe)(ctx)
    payload:=claim.payload
    if claim.kind=="registry.prepare" {
        prepared,ok:=owner.language_registry_prepare(s,claim,p.kr,p.signer)
        if !ok do return false,"registry_prepare_failed",1000
        payload=prepared
    } else if claim.kind!="registry" { return false,"unsupported_kind",1000 }
    append(&p.published,strings.clone(payload,context.temp_allocator))
    return true,"200",1000
}
