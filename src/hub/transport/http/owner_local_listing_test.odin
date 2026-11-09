package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import project_service "odin_test:hub/service/project"

@(test)
owner_registry_http_pages_live_tombstones_bytes_and_accounts :: proc(t:^testing.T) {
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
    headers:=http_test_login(t,&auth,"registry-page-owner")
    other_headers:=http_test_login(t,&auth,"registry-page-other")
    principal,valid,_:=auth_service.resolve_auth_any(&auth,auth_service.Auth_Request{remote_addr="127.0.0.1:4444",headers=headers})
    if !testing.expect(t,valid) do return
    impl:sqlite.Taskchain_Repo_SQLite
    repo:=sqlite.new_taskchain_repository(&impl,&conn)
    runtime:project_service.Bridge_Runtime_Registry
    h:=Bridge_Handlers{auth=&auth,chains=&repo,bridge_runtime_registry=&runtime}
    fixture,_:=json.parse_string(#load("../../../contracts/fixtures/owner-local-v1.json",string),.JSON,true,context.temp_allocator)
    entries:=fixture.(json.Object)["valid"].(json.Array)
    registry:json.Object
    for entry in entries {
        e:=entry.(json.Object)
        if contracts.owner_string(e,"kind")=="registry" { registry,_=contracts.owner_parse(contracts.owner_string(e,"raw"),"registry") }
    }
    r:=domain.Owner_Registry_Record{account_id=principal.user_id,chain_id="chain_1",owner_bridge_id="brg_1",owner_key_id="bridge_key",creator_id="dev_1",genesis_digest="digest",genesis_json="genesis",metadata_revision=1}
    registry["account_id"]=json.String(principal.user_id)
    r.registry_json=owner_json(registry)
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    registry["chain_title_cipher"]=json.String("")
    registry["chain_description_cipher"]=json.String("")
    for i in 1..=105 {
        r.task_id=fmt.tprintf("task_%03d",i)
        registry["task_id"]=json.String(r.task_id)
        registry["task_title_cipher"]=json.String("vault:v2:0123456789abcdef:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
        r.registry_json=owner_json(registry)
        testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    }
    for tombstones in ([2]bool{false,true}) {
        if tombstones {
            for i in 1..=104 {
                r.task_id=fmt.tprintf("task_%03d",i);r.metadata_revision=2
                registry["task_id"]=json.String(r.task_id);registry["metadata_revision"]=json.String("2");registry["deleted"]=json.String("1");registry["task_title_cipher"]=json.String("")
                r.registry_json=owner_json(registry)
                testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
            }
        }
        query:="page=1&chain_id=chain_1"
        seen,pages:=0,0
        for {
            response:=owner_local_list_handler(&h,Request{method="GET",headers=headers,query=query,remote_addr="127.0.0.1:4444"})
            if !testing.expect_value(t,response.status,200) do break
            testing.expect(t,len(response.body)<263168)
            value,_:=json.parse_string(response.body,.JSON,true,context.temp_allocator)
            data:=value.(json.Object)["data"].(json.Object)
            items:=data["items"].(json.Array)
            seen+=len(items);pages+=1
            if data["terminal"].(json.Boolean) do break
            cursor:=data["next_cursor"].(json.Object)
            testing.expect_value(t,contracts.owner_string(cursor,"after_task"),"task_099")
            query=fmt.tprintf("page=1&chain_id=chain_1&after_chain=%s&after_task=%s",contracts.owner_string(cursor,"after_chain"),contracts.owner_string(cursor,"after_task"))
            if pages>3 { testing.expect(t,false,"bounded progress");break }
        }
        testing.expect_value(t,pages,2)
        testing.expect_value(t,seen,int(2 if tombstones else 106))
    }
    // A page containing only tombstones still advances and is nonterminal.
    empty_page:=owner_local_list_handler(&h,Request{method="GET",headers=headers,query="page=1&chain_id=chain_1&after_chain=chain_1&after_task=",remote_addr="127.0.0.1:4444"})
    empty_value,_:=json.parse_string(empty_page.body,.JSON,true,context.temp_allocator)
    empty_data:=empty_value.(json.Object)["data"].(json.Object)
    testing.expect_value(t,len(empty_data["items"].(json.Array)),0)
    testing.expect(t,!empty_data["terminal"].(json.Boolean))
    testing.expect_value(t,contracts.owner_string(empty_data["next_cursor"].(json.Object),"after_task"),"task_100")
    // Cross-account cursors remain positions, never an authorization capability.
    response:=owner_local_list_handler(&h,Request{method="GET",headers=other_headers,query="page=1&after_chain=chain_1&after_task=task_099",remote_addr="127.0.0.1:4444"})
    testing.expect_value(t,response.status,200)
    value,_:=json.parse_string(response.body,.JSON,true,context.temp_allocator)
    data:=value.(json.Object)["data"].(json.Object)
    testing.expect_value(t,len(data["items"].(json.Array)),0)
    testing.expect(t,data["terminal"].(json.Boolean))
    // Large valid protected rows split on complete encoded page framing.
    large:=fmt.tprintf("vault:v2:0123456789abcdef:e1:%s",strings.repeat("A",60000,context.temp_allocator))
    for i in 1..=5 {
        r.task_id=fmt.tprintf("task_%03d",i);r.metadata_revision=3
        registry["task_id"]=json.String(r.task_id);registry["metadata_revision"]=json.String("3");registry["deleted"]=json.String("0")
        registry["task_title_cipher"]=json.String(large)
        r.registry_json=owner_json(registry)
        testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    }
    response=owner_local_list_handler(&h,Request{method="GET",headers=headers,query="page=1&chain_id=chain_1&after_chain=chain_1&after_task=task_000",remote_addr="127.0.0.1:4444"})
    testing.expect_value(t,response.status,200)
    value,_=json.parse_string(response.body,.JSON,true,context.temp_allocator)
    data=value.(json.Object)["data"].(json.Object)
    testing.expect_value(t,len(data["items"].(json.Array)),4)
    testing.expect(t,!data["terminal"].(json.Boolean))
    testing.expect_value(t,contracts.owner_string(data["next_cursor"].(json.Object),"after_task"),"task_004")
    testing.expect(t,len(response.body)<263168)
    response=owner_local_list_handler(&h,Request{method="GET",headers=headers,query="page=1&chain_id=chain_1&after_chain=chain_1&after_task=task_004",remote_addr="127.0.0.1:4444"})
    value,_=json.parse_string(response.body,.JSON,true,context.temp_allocator)
    data=value.(json.Object)["data"].(json.Object)
    testing.expect_value(t,len(data["items"].(json.Array)),1)
    first:=data["items"].(json.Array)[0].(json.Object)
    testing.expect_value(t,contracts.owner_string(first,"task_id"),"task_005")
    testing.expect_value(t,contracts.owner_string(data["next_cursor"].(json.Object),"after_task"),"task_104")
    testing.expect(t,!data["terminal"].(json.Boolean))
}

// R4a: the unpaged array form returns every live row instead of silently
// stopping after 100 (101 for headers_only).
@(test)
owner_registry_unpaged_listing_walks_past_one_hundred_rows :: proc(t:^testing.T) {
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
    headers:=http_test_login(t,&auth,"registry-unpaged-owner")
    principal,valid,_:=auth_service.resolve_auth_any(&auth,auth_service.Auth_Request{remote_addr="127.0.0.1:4444",headers=headers})
    if !testing.expect(t,valid) do return
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
    registry["account_id"]=json.String(principal.user_id)
    // 130 chains (headers) plus 120 task rows of one chain.
    for c in 1..=130 {
        chain:=fmt.tprintf("chain_%03d",c)
        r:=domain.Owner_Registry_Record{account_id=principal.user_id,chain_id=chain,owner_bridge_id="brg_1",owner_key_id="bridge_key",creator_id="dev_1",genesis_digest="digest",genesis_json="genesis",metadata_revision=1}
        registry["chain_id"]=json.String(chain);registry["task_id"]=json.String("")
        r.registry_json=owner_json(registry)
        testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    }
    task_registry:=registry
    task_registry["chain_id"]=json.String("chain_001")
    task_registry["chain_title_cipher"]=json.String("");task_registry["chain_description_cipher"]=json.String("")
    task_registry["task_title_cipher"]=json.String("vault:v2:0123456789abcdef:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
    for i in 1..=120 {
        r:=domain.Owner_Registry_Record{account_id=principal.user_id,chain_id="chain_001",owner_bridge_id="brg_1",owner_key_id="bridge_key",creator_id="dev_1",genesis_digest="digest",genesis_json="genesis",metadata_revision=1,task_id=fmt.tprintf("task_%03d",i)}
        task_registry["task_id"]=json.String(r.task_id)
        r.registry_json=owner_json(task_registry)
        testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    }
    count :: proc(t:^testing.T,h:^Bridge_Handlers,headers:[]contracts.HTTP_Header,query:string)->int {
        response:=owner_local_list_handler(h,Request{method="GET",headers=headers,query=query,remote_addr="127.0.0.1:4444"})
        if !testing.expect_value(t,response.status,200) do return -1
        value,_:=json.parse_string(response.body,.JSON,true,context.temp_allocator)
        return len(value.(json.Object)["data"].(json.Array))
    }
    testing.expect_value(t,count(t,&h,headers,""),250)
    testing.expect_value(t,count(t,&h,headers,"headers_only=1"),130)
    testing.expect_value(t,count(t,&h,headers,"chain_id=chain_001"),121)
    testing.expect_value(t,count(t,&h,headers,"headers_only=1&chain_id=chain_002"),1)
    // The routing read used for owner authority is one row per chain.
    routes,err:=repo.owner_registry_routes(repo.ctx,principal.user_id,"")
    testing.expect(t,err.code==.None && len(routes)==130)
}
