#+feature dynamic-literals
package owner_local

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Agent `task-chain create`: the owner Bridge key is the genesis creator. The
// store enables root recovery, and the one narrow coordinator bind follows.

bridge_genesis :: proc(f:^Fixture,chain,creator_id,creator_key:string,creator:^ecdsa.Private_Key) -> string {
    g:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"=chain,"creation_op"=fmt.tprintf("create_%s",chain),"owner_bridge_id"="bridge","owner_key_id"="bridge_key","creator_id"=creator_id,"creator_key_id"=creator_key,"schema_version"="1","creator_signature"=strings.repeat("0",128,context.temp_allocator),"owner_signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(creator,"genesis",g);g["creator_signature"]=json.String(sig)
    sig,_=test_sign(&f.owner_priv,"genesis",g);g["owner_signature"]=json.String(sig)
    return encode(g)
}
bridge_create :: proc(f:^Fixture,chain:string,key:contracts.Owner_Verified_Key,priv:^ecdsa.Private_Key,requested_by:string="inst_creator") -> Result {
    genesis:=bridge_genesis(f,chain,key.principal_id,key.key_id,priv)
    g,_:=contracts.owner_parse(genesis,"genesis");digest,_:=contracts.owner_digest("genesis",g)
    p:=encode(doc(map[string]string{"genesis_digest"=digest,"title_cipher"=cipher(f,"agent chain"),"description_cipher"=cipher(f,"made by an agent")}))
    c:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"=chain,"immutable_owner_bridge"="bridge","principal_id"=key.principal_id,"operation_id"=fmt.tprintf("create_%s",chain),"method"="chain.create","task_id"="","expected_revision"="0","request_expires_ms"="2000","payload_digest"=contracts.owner_payload_digest(p),"key_id"=key.key_id,"signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(priv,"command",c);c["signature"]=json.String(sig)
    if !observe_directory(&f.store,1,"head") do return fail("invalid_scope")
    return execute(&f.store,encode(c),p,genesis,key,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},requested_by=requested_by)
}
bridge_agent_command :: proc(f:^Fixture,chain:string,agent:Child,method,op,payload,revision:string) -> Result {
    c:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"=chain,"immutable_owner_bridge"="bridge","principal_id"=agent.instance,"operation_id"=op,"method"=method,"task_id"="","expected_revision"=revision,"request_expires_ms"="2000","payload_digest"=contracts.owner_payload_digest(payload),"key_id"="bridge_key","signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(&f.owner_priv,"command",c);c["signature"]=json.String(sig)
    return execute_agent(&f.store,encode(c),payload,agent,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign})
}
bridge_chain_rev :: proc(f:^Fixture,chain:string) -> string {
    rows,_:=query(f.store.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    return rows[0][0] if len(rows)==1 else "0"
}

@(test)
bridge_created_chain_enables_recovery_and_only_own_owner_key_creates :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    // A foreign enrolled Bridge key, under its own id or claiming the owner's.
    other:ecdsa.Private_Key;testing.expect(t,vault.p256_private_key_generate(&other));defer ecdsa.private_key_clear(&other)
    pub:[65]byte;ecdsa.private_key_public_bytes(&other,pub[:])
    alien:=contracts.Owner_Verified_Key{"account","bridge2","bridge2_key",vault.hex_encode_lower(pub[:],context.temp_allocator),"bridge",true,false}
    testing.expect_value(t,bridge_create(f,"foreign_chain",alien,&other).code,"invalid_scope")
    claim:=alien;claim.principal_id="bridge";claim.key_id="bridge_key"
    testing.expect_value(t,bridge_create(f,"claim_chain",claim,&other).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM task_chains")
    testing.expect_value(t,rows[0][0],"1")

    // The owner key creates; recovery is on, no grant exists, event attributed.
    testing.expect_value(t,bridge_create(f,"bchain",f.owner,&f.owner_priv).code,"ok")
    rows,_=query(f.store.db,"SELECT creator,creator_key,(SELECT revision||':'||recovery_enabled FROM local_grant_policy WHERE chain_id='bchain'),(SELECT count(*) FROM local_grants WHERE chain_id='bchain') FROM task_chains WHERE chain_id='bchain'")
    testing.expect_value(t,encode(rows),encode([1][4]string{{"bridge","bridge_key","1:1","0"}}))
    rows,_=query(f.store.db,"SELECT actor_kind,actor_id FROM local_events WHERE chain_id='bchain' AND kind='chain.create'")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"agent","inst_creator"}}))
    outbox,_:=query(f.store.db,"SELECT count(*) FROM runtime_intents WHERE chain_id='bchain' AND kind='registry'")
    testing.expect_value(t,outbox[0][0],"1")
    // A device-created chain keeps its creator grant and no recovery policy.
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_grant_policy WHERE chain_id='chain'),(SELECT count(*) FROM local_grants WHERE chain_id='chain')")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"0","1"}}))

    // The Bridge key signs nothing else, even on its own chain.
    edit:=encode(doc(map[string]string{"title_cipher"=cipher(f,"t"),"description_cipher"=cipher(f,"d")}))
    c:=doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="bchain","immutable_owner_bridge"="bridge","principal_id"="bridge","operation_id"="bridge_edit","method"="chain.edit","task_id"="","expected_revision"="1","request_expires_ms"="2000","payload_digest"=contracts.owner_payload_digest(edit),"key_id"="bridge_key","signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=test_sign(&f.owner_priv,"command",c);c["signature"]=json.String(sig)
    testing.expect_value(t,execute(&f.store,encode(c),edit,"",f.owner,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")

    // The paired root recovers a grant, then reads; no other device can.
    root:=grant_device(t);defer ecdsa.private_key_clear(&root.priv)
    read:=`{"cursor":"","limit":"20"}`
    before:=grant_command(f,root.key,&root.priv,"chain.read","root_before","",read,"0",chain="bchain")
    testing.expect_value(t,grant_call(f,before,read,root.key).code,"invalid_scope")
    stranger:=grant_device(t);defer ecdsa.private_key_clear(&stranger.priv)
    gp:=grant_payload(root.key)
    wrong:=grant_command(f,stranger.key,&stranger.priv,"grant.recover","stranger_recover","",gp,bridge_chain_rev(f,"bchain"),chain="bchain")
    testing.expect_value(t,grant_call(f,wrong,gp,stranger.key,Grant_Proof{root=root.root,target=root.key}).code,"invalid_scope")
    recover:=grant_command(f,root.key,&root.priv,"grant.recover","root_recover","",gp,bridge_chain_rev(f,"bchain"),chain="bchain")
    testing.expect_value(t,grant_call(f,recover,gp,root.key,Grant_Proof{root=root.root,target=root.key}).code,"ok")
    after:=grant_command(f,root.key,&root.priv,"chain.read","root_after","",read,"0",chain="bchain")
    got:=grant_call(f,after,read,root.key)
    testing.expect(t,got.code=="ok" && strings.contains(got.body,"agent chain"))
}

@(test)
bridge_created_chain_binds_one_coordinator_and_agents_stay_out_of_grants :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,bridge_create(f,"bchain",f.owner,&f.owner_priv).code,"ok")
    testing.expect_value(t,bridge_create(f,"bchain2",f.owner,&f.owner_priv).code,"ok")
    coord:=Child{"inst_creator","coord_epoch",strings.repeat("c",64,context.temp_allocator),1,"agt_creator"}
    // Device-created chains never take the agent bind.
    testing.expect_value(t,bind_created_coordinator(&f.store,"chain",coord,"inst_creator",1000).code,"invalid_scope")
    testing.expect_value(t,bind_created_coordinator(&f.store,"missing",coord,"inst_creator",1000).code,"invalid_scope")
    bad:=coord;bad.token_generation="nope"
    testing.expect_value(t,bind_created_coordinator(&f.store,"bchain",bad,"inst_creator",1000).code,"invalid_scope")
    first:=bind_created_coordinator(&f.store,"bchain",coord,"inst_creator",1000)
    testing.expect_value(t,first.code,"ok")
    testing.expect_value(t,chain_coordinator_instance(&f.store,"bchain"),"inst_creator")
    testing.expect(t,agent_coordinator(&f.store,"bchain",coord))
    rows,_:=query(f.store.db,"SELECT actor_kind,actor_id,kind FROM local_events WHERE chain_id='bchain' ORDER BY seq")
    testing.expect_value(t,encode(rows),encode([2][3]string{{"agent","inst_creator","chain.create"},{"agent","inst_creator","chain.member.set"}}))
    // First and only binding: no second coordinator, no re-bind.
    other:=Child{"inst_other","other_epoch",strings.repeat("e",64,context.temp_allocator),1,"agt_other"}
    testing.expect_value(t,bind_created_coordinator(&f.store,"bchain",other,"inst_creator",1000).code,"operation_conflict")
    testing.expect_value(t,bind_created_coordinator(&f.store,"bchain",coord,"inst_creator",1000).code,"operation_conflict")
    // An instance is locked to one chain for life.
    testing.expect_value(t,bind_created_coordinator(&f.store,"bchain2",coord,"inst_creator",1000).code,"invalid_scope")
    rows,_=query(f.store.db,"SELECT count(*) FROM local_chain_member_versions")
    testing.expect_value(t,rows[0][0],"1")

    // The bound coordinator works the chain, but it never grants the
    // coordinator role (fleet members are workers/reviewers), grants stay
    // human-only, and it can never create a chain itself.
    summary:=encode(doc(map[string]string{"body_cipher"=cipher(f,"plan")}))
    testing.expect_value(t,bridge_agent_command(f,"bchain",coord,"chain.summary.set","coord_summary",summary,bridge_chain_rev(f,"bchain")).code,"ok")
    member:=encode(doc(map[string]string{"instance_id"=other.instance,"agent_id"=other.agent_id,"role"="coordinator","enabled"="1"}))
    testing.expect_value(t,bridge_agent_command(f,"bchain",coord,"chain.member.set","coord_member",member,bridge_chain_rev(f,"bchain")).code,"invalid_scope")
    root:=grant_device(t);defer ecdsa.private_key_clear(&root.priv)
    gp:=grant_payload(root.key)
    for method in ([4]string{"grant.set","grant.recover","grant.policy","grant.revoke"}) {
        payload:=gp
        if method=="grant.policy" do payload=`{"policy_revision":"2","recovery_enabled":"0"}`
        if method=="grant.revoke" do payload=encode(doc(map[string]string{"principal_id"=root.key.principal_id,"key_id"=root.key.key_id}))
        testing.expect_value(t,bridge_agent_command(f,"bchain",coord,method,fmt.tprintf("coord_%s",method),payload,bridge_chain_rev(f,"bchain")).code,"invalid_scope")
    }
    testing.expect_value(t,bridge_agent_command(f,"bchain3",coord,"chain.create","coord_create",gp,"0").code,"invalid_scope")
    rows,_=query(f.store.db,"SELECT (SELECT count(*) FROM local_chain_member_versions),(SELECT count(*) FROM local_grants WHERE chain_id='bchain'),(SELECT recovery_enabled FROM local_grant_policy WHERE chain_id='bchain')")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"1","0","1"}}))
}
