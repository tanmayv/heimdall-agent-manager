package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import project_service "odin_test:hub/service/project"

// Cross-Bridge agent relay: the Hub finds the chain's (or task's) owner Bridge
// in the caller's account only, and the relay route takes Bridge tokens only.
@(test)
owner_agent_relay_routes_within_the_account_and_needs_a_bridge_token :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
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
    headers:=http_test_login(t,&auth,"relay-owner")
    other_headers:=http_test_login(t,&auth,"relay-other")
    principal,valid,_:=auth_service.resolve_auth_any(&auth,auth_service.Auth_Request{remote_addr="127.0.0.1:4444",headers=headers})
    other,other_valid,_:=auth_service.resolve_auth_any(&auth,auth_service.Auth_Request{remote_addr="127.0.0.1:4444",headers=other_headers})
    if !testing.expect(t,valid && other_valid) do return
    impl:sqlite.Taskchain_Repo_SQLite
    repo:=sqlite.new_taskchain_repository(&impl,&conn)
    runtime:project_service.Bridge_Runtime_Registry
    h:=Bridge_Handlers{auth=&auth,chains=&repo,bridge_runtime_registry=&runtime}
    fixture,_:=json.parse_string(#load("../../../contracts/fixtures/owner-local-v1.json",string),.JSON,true,context.temp_allocator)
    registry:json.Object
    for entry in fixture.(json.Object)["valid"].(json.Array) {
        e:=entry.(json.Object)
        if contracts.owner_string(e,"kind")=="registry" { registry,_=contracts.owner_parse(contracts.owner_string(e,"raw"),"registry") }
    }
    r:=domain.Owner_Registry_Record{account_id=principal.user_id,chain_id="chain_1",owner_bridge_id="brg_a",owner_key_id="bridge_key",creator_id="dev_1",genesis_digest="digest",genesis_json="genesis",metadata_revision=1}
    registry["account_id"]=json.String(principal.user_id)
    r.registry_json=owner_json(registry)
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    r.task_id="task_1"
    registry["chain_title_cipher"]=json.String("")
    registry["chain_description_cipher"]=json.String("")
    registry["task_id"]=json.String("task_1")
    registry["task_title_cipher"]=json.String("vault:v2:0123456789abcdef:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
    r.registry_json=owner_json(registry)
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)

    owner,found,code:=owner_local_route(&h,principal.user_id,"chain_1","")
    testing.expect(t,found && owner=="brg_a" && code==.Complete,"by chain id")
    owner,found,code=owner_local_route(&h,principal.user_id,"","task_1")
    testing.expect(t,found && owner=="brg_a" && code==.Complete,"by task id alone")
    _,found,_=owner_local_route(&h,principal.user_id,"missing","")
    testing.expect(t,!found)
    _,found,_=owner_local_route(&h,other.user_id,"chain_1","")
    testing.expect(t,!found,"another account never sees the chain")
    _,found,_=owner_local_route(&h,other.user_id,"","task_1")
    testing.expect(t,!found,"another account never sees the task")

    // A user session (or an agent token) cannot use the Bridge relay.
    body:=`{"chain_id":"chain_1","task_id":"","request":"x","signature":""}`
    response:=owner_local_agent_relay_handler(&h,Request{method="POST",headers=headers,body=body,remote_addr="127.0.0.1:4444"})
    testing.expectf(t,response.status==403 && strings.contains(response.body,"Bridge of the account"),"user refused: %d %s",response.status,response.body)
}
