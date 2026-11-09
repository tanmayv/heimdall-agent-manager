#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// The chain registry row names the chain's members (ids and roles only), so
// the Hub listing shows the bound coordinator without a Bridge read. Every
// membership change republishes it with a higher metadata_revision.

registry_members_payload :: proc(f:^Fixture,kind,op:string) -> json.Object {
    rows,_:=query(f.store.db,"SELECT payload_json FROM runtime_intents WHERE chain_id='chain' AND kind=? AND operation_id=? AND destination_bridge=''",kind,op)
    if len(rows)!=1 do return nil
    v,_:=contracts.owner_request_document(rows[0][0]);o,_:=v.(json.Object)
    return o
}
registry_members_prepare :: proc(t:^testing.T,f:^Fixture,op:string) -> (json.Object,string) {
    ids,_:=query(f.store.db,"SELECT intent_id FROM runtime_intents WHERE kind='registry.prepare' AND operation_id=?",op)
    claims,ok:=intent_claim_due(&f.store,1000)
    if !testing.expect(t,ok && len(ids)==1) do return nil,""
    for claim in claims {
        if claim.kind!="registry.prepare" || claim.id!=ids[0][0] do continue
        a,one:=language_registry_prepare(&f.store,claim,&f.kr,Signer{&f.owner_priv,test_sign})
        b,two:=language_registry_prepare(&f.store,claim,&f.kr,Signer{&f.owner_priv,test_sign})
        testing.expect(t,one && two && a==b,"prepared bytes are frozen")
        r,valid:=contracts.owner_parse(a,"registry")
        testing.expect(t,valid,"the prepared row is a valid registry document")
        return r,a
    }
    testing.expectf(t,false,"no registry.prepare claim for %s",op)
    return nil,""
}
registry_members_verified :: proc(f:^Fixture,r:json.Object) -> bool {
    genesis,_:=query(f.store.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id='chain'")
    return len(genesis)==1 && contracts.owner_verify_registry(r,"account","bridge",genesis[0][0],f.owner)==.None
}

@(test)
registry_members_republished_on_every_member_change :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    // chain.create publishes the chain row with an explicit empty membership.
    created:=registry_members_payload(f,"registry","create")
    testing.expect(t,created!=nil && registry_members_verified(f,created))
    testing.expect_value(t,field(created,"members_json"),"[]")
    testing.expect_value(t,field(created,"coordinator_instance_id"),"")
    // Task rows keep the plain registry shape.
    rows,_:=query(f.store.db,"SELECT payload_json FROM runtime_intents WHERE kind='registry' AND operation_id='task'")
    testing.expect(t,len(rows)==1 && !strings.contains(rows[0][0],"members_json"))

    child,second:=lease_child(),lifecycle_reviewer()
    testing.expect_value(t,member_call(f,child,"coordinator","1","bind").code,"ok")
    bound:=registry_members_payload(f,"registry.prepare","bind")
    testing.expect(t,bound!=nil)
    testing.expect_value(t,field(bound,"coordinator_instance_id"),child.instance)
    testing.expect_value(t,field(bound,"coordinator_agent_id"),child.agent_id)
    r,_:=registry_members_prepare(t,f,"bind")
    testing.expect(t,r!=nil && registry_members_verified(f,r),"the owner key signs the members row")
    seq,_:=query(f.store.db,"SELECT commit_seq FROM command_receipts WHERE operation_id='bind'")
    testing.expect_value(t,field(r,"metadata_revision"),seq[0][0])
    testing.expect_value(t,field(r,"task_id"),"")
    testing.expect_value(t,field(r,"coordinator_instance_id"),child.instance)
    testing.expect_value(t,field(r,"members_json"),`[{"agent_id":"author","instance_id":"instance","role":"coordinator","enabled":"1"}]`)
    title,opened:=vault.open(field(r,"chain_title_cipher"),&f.kr,context.temp_allocator)
    testing.expect(t,opened==.Ok && title=="chain title","titles are sealed again at delivery")
    // Changing a member field breaks the owner signature.
    forged:=doc(map[string]string{})
    for k,v in r do forged[k]=v
    forged["coordinator_instance_id"]=json.String("")
    testing.expect(t,!registry_members_verified(f,forged))

    // A second coordinator, then demoting the first: the newest binding is named.
    testing.expect_value(t,member_call(f,second,"coordinator","1","second").code,"ok")
    testing.expect_value(t,field(registry_members_payload(f,"registry.prepare","second"),"coordinator_instance_id"),second.instance)
    testing.expect_value(t,member_call(f,child,"coordinator","0","demote").code,"ok")
    demoted:=registry_members_payload(f,"registry.prepare","demote")
    testing.expect_value(t,field(demoted,"coordinator_instance_id"),second.instance)
    testing.expect_value(t,field(demoted,"members_json"),`[{"agent_id":"reviewer","instance_id":"review_instance","role":"coordinator","enabled":"1"},{"agent_id":"author","instance_id":"instance","role":"coordinator","enabled":"0"}]`)

    // chain.edit replaces the chain row, so it carries the current members too.
    edit:=encode(doc(map[string]string{"title_cipher"=cipher(f,"renamed"),"description_cipher"=cipher(f,"d")}))
    testing.expect_value(t,invoke(f,command(f,"chain.edit","rename","",edit,summary_revision(f)),edit).code,"ok")
    renamed:=registry_members_payload(f,"registry","rename")
    testing.expect(t,renamed!=nil && registry_members_verified(f,renamed))
    testing.expect_value(t,field(renamed,"coordinator_instance_id"),second.instance)
}

@(test)
registry_members_republished_after_bridge_created_coordinator_bind :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,bridge_create(f,"bchain",f.owner,&f.owner_priv).code,"ok")
    coord:=Child{"inst_creator","coord_epoch",strings.repeat("c",64,context.temp_allocator),1,"agt_creator"}
    bound:=bind_created_coordinator(&f.store,"bchain",coord,"inst_creator",1000)
    testing.expect_value(t,bound.code,"ok")
    rows,_:=query(f.store.db,"SELECT json_extract(payload_json,'$.coordinator_instance_id'),json_extract(payload_json,'$.metadata_revision'),commit_seq FROM runtime_intents WHERE chain_id='bchain' AND kind='registry.prepare' AND operation_id='bind_bchain'")
    testing.expect_value(t,len(rows),1)
    if len(rows)==1 {
        testing.expect_value(t,rows[0][0],"inst_creator")
        testing.expect_value(t,rows[0][1],rows[0][2])
    }
    claims,ok:=intent_claim_due(&f.store,1000)
    testing.expect(t,ok)
    prepared:=false
    for claim in claims {
        if claim.kind!="registry.prepare" || claim.chain!="bchain" do continue
        out,ready:=language_registry_prepare(&f.store,claim,&f.kr,Signer{&f.owner_priv,test_sign})
        r,valid:=contracts.owner_parse(out,"registry")
        genesis,_:=query(f.store.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id='bchain'")
        testing.expect(t,ready && valid && contracts.owner_verify_registry(r,"account","bridge",genesis[0][0],f.owner)==.None)
        testing.expect_value(t,field(r,"coordinator_agent_id"),"agt_creator")
        prepared=true
    }
    testing.expect(t,prepared)
}
