package http

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import project_service "odin_test:hub/service/project"
import vault "odin_test:lib/vault"

// The owner Bridge republishes the chain registry row with its member ids and
// roles after every membership change. The Hub verifies the owner signature
// over them like any registry row and lists the signed bytes unchanged, so
// the app reads the bound coordinator from the listing.

registry_members_sign :: proc(t:^testing.T,priv:^ecdsa.Private_Key,kind:string,o:^json.Object,field:string) {
    canonical,ok:=contracts.owner_canonical(kind,o^)
    testing.expect(t,ok)
    sig,signed:=vault.sign_p256(priv,transmute([]byte)canonical)
    testing.expect(t,signed)
    o^[field]=json.String(strings.clone(vault.hex_encode_lower(sig.sig[:],context.temp_allocator)))
}
registry_members_documents :: proc(t:^testing.T,owner:^ecdsa.Private_Key,account,revision,members,agent,instance:string)->(json.Object,json.Object,string) {
    zeros:=strings.repeat("0",128)
    g:=make(json.Object)
    for pair in ([11][2]string{{"protocol_version","1"},{"account_id",account},{"chain_id","chain_1"},{"creation_op","op_1"},{"owner_bridge_id","brg_1"},{"owner_key_id","brg_key_1"},
        {"creator_id","brg_1"},{"creator_key_id","brg_key_1"},{"schema_version","1"},{"creator_signature",zeros},{"owner_signature",zeros}}) { g[pair[0]]=json.String(pair[1]) }
    registry_members_sign(t,owner,"genesis",&g,"creator_signature");registry_members_sign(t,owner,"genesis",&g,"owner_signature")
    digest,_:=contracts.owner_digest("genesis",g)
    cipher:="vault:v2:0123456789abcdef:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
    r:=make(json.Object)
    for pair in ([13][2]string{{"protocol_version","1"},{"account_id",account},{"chain_id","chain_1"},{"owner_bridge_id","brg_1"},{"key_id","brg_key_1"},{"genesis_digest",digest},
        {"metadata_revision",revision},{"task_id",""},{"chain_title_cipher",cipher},{"chain_description_cipher",cipher},{"task_title_cipher",""},{"deleted","0"},{"signature",zeros}}) { r[pair[0]]=json.String(pair[1]) }
    if members!="" {
        r["coordinator_agent_id"]=json.String(agent);r["coordinator_instance_id"]=json.String(instance);r["members_json"]=json.String(members)
    }
    registry_members_sign(t,owner,"registry",&r,"signature")
    raw,_:=json.marshal(g)
    return g,r,string(raw)
}

@(test)
owner_registry_members_publish_verify_and_list :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    own:ecdsa.Private_Key
    testing.expect(t,vault.p256_private_key_generate(&own))
    defer ecdsa.private_key_clear(&own)
    pub:[65]byte;ecdsa.private_key_public_bytes(&own,pub[:])
    owner:=contracts.Owner_Verified_Key{"acct_1","brg_1","brg_key_1",strings.clone(vault.hex_encode_lower(pub[:],context.temp_allocator)),"bridge",true,false}
    members:=`[{"agent_id":"agt_coord","instance_id":"inst_coord","role":"coordinator","enabled":"1"}]`

    // Publication: the owner signature covers the members; old rows still verify.
    g,r,raw:=registry_members_documents(t,&own,"acct_1","2",members,"agt_coord","inst_coord")
    testing.expect(t,owner_publication_verified(g,r,raw,"acct_1","brg_1",owner,owner,nil),"a members row verifies")
    r["coordinator_instance_id"]=json.String("")
    r["coordinator_agent_id"]=json.String("")
    testing.expect(t,!owner_publication_verified(g,r,raw,"acct_1","brg_1",owner,owner,nil),"forged members are refused")
    g,r,raw=registry_members_documents(t,&own,"acct_1","1","","","")
    testing.expect(t,owner_publication_verified(g,r,raw,"acct_1","brg_1",owner,owner,nil),"a row without members keeps verifying")

    // Listing: the newest chain row's signed bytes, members included.
    conn,opened,_:=sqlite.open(":memory:")
    if !testing.expect(t,opened) do return
    defer sqlite.close(&conn)
    migrated,_:=sqlite.run_migrations(&conn)
    if !testing.expect(t,migrated) do return
    users:sqlite.User_Repo_SQLite
    user_repo:=sqlite.new_user_repository(&users,&conn)
    clock:=platform.real_clock()
    ids:=http_test_id_generator()
    user_svc:=user_service.new_user_service_basic(&user_repo,&clock,&ids)
    auth:=auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users=true},&user_svc)
    auth.clock=&clock;auth.ids=&ids
    headers:=http_test_login(t,&auth,"registry-members-owner")
    principal,valid,_:=auth_service.resolve_auth_any(&auth,auth_service.Auth_Request{remote_addr="127.0.0.1:4444",headers=headers})
    if !testing.expect(t,valid) do return
    impl:sqlite.Taskchain_Repo_SQLite
    repo:=sqlite.new_taskchain_repository(&impl,&conn)
    runtime:project_service.Bridge_Runtime_Registry
    h:=Bridge_Handlers{auth=&auth,chains=&repo,bridge_runtime_registry=&runtime}
    list :: proc(t:^testing.T,h:^Bridge_Handlers,headers:[]contracts.HTTP_Header)->json.Object {
        response:=owner_local_list_handler(h,Request{method="GET",headers=headers,query="page=1&chain_id=chain_1",remote_addr="127.0.0.1:4444"})
        testing.expect_value(t,response.status,200)
        value,_:=json.parse_string(response.body,.JSON,true,context.temp_allocator)
        items:=value.(json.Object)["data"].(json.Object)["items"].(json.Array)
        if !testing.expect_value(t,len(items),1) do return nil
        registry,parsed:=contracts.owner_parse(contracts.owner_string(items[0].(json.Object),"registry_json"),"registry")
        testing.expect(t,parsed,"the listed row is a valid registry document")
        return registry
    }
    publish :: proc(t:^testing.T,repo:^iface.Taskchain_Repository,account,raw_genesis:string,r:json.Object,revision:i64)->domain.Error_Code {
        row:=domain.Owner_Registry_Record{account_id=account,chain_id="chain_1",owner_bridge_id="brg_1",owner_key_id="brg_key_1",creator_id="brg_1",genesis_digest=contracts.owner_string(r,"genesis_digest"),genesis_json=raw_genesis,task_id="",registry_json=owner_json(r),metadata_revision=revision}
        return repo.owner_registry_publish(repo.ctx,row).code
    }
    account:=principal.user_id
    _,old,raw1:=registry_members_documents(t,&own,account,"1","","","")
    testing.expect_value(t,publish(t,&repo,account,raw1,old,1),domain.Error_Code.None)
    listed:=list(t,&h,headers)
    testing.expect(t,listed!=nil && !("members_json" in listed),"an old row lists without members (the app falls back to the owner read)")
    _,bound,_:=registry_members_documents(t,&own,account,"2",members,"agt_coord","inst_coord")
    bound["genesis_digest"]=old["genesis_digest"]
    registry_members_sign(t,&own,"registry",&bound,"signature")
    testing.expect_value(t,publish(t,&repo,account,raw1,bound,2),domain.Error_Code.None)
    listed=list(t,&h,headers)
    testing.expect_value(t,contracts.owner_string(listed,"coordinator_instance_id"),"inst_coord")
    testing.expect_value(t,contracts.owner_string(listed,"coordinator_agent_id"),"agt_coord")
    testing.expect_value(t,contracts.owner_string(listed,"members_json"),members)
    // A stale replay of the older row never replaces the members row.
    testing.expect_value(t,publish(t,&repo,account,raw1,old,1),domain.Error_Code.None)
    testing.expect_value(t,contracts.owner_string(list(t,&h,headers),"coordinator_instance_id"),"inst_coord")
}
