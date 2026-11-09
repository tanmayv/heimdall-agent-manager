#+feature dynamic-literals
package http

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import user_service "odin_test:hub/service/user"
import vault "odin_test:lib/vault"

// Fake owner Bridge for handler tests: signs the receipt for the relayed
// manifest and, like the real Bridge, replays its first reply exactly.
Migration_Post_Fake :: struct {
    mutex:sync.Mutex,
    account:string,
    device_priv,owner_priv:ecdsa.Private_Key,
    reply:string,
    relays:int,
}
migration_post_fake:Migration_Post_Fake

migration_post_keys :: proc(h:^Bridge_Handlers,account:string,selection:json.Object)->(contracts.Owner_Verified_Key,contracts.Owner_Verified_Key,vault.Directory_Verification_Input,bool) {
    device:=migration_http_key(&migration_post_fake.device_priv,"device","device","device");device.account_id=account
    owner:=migration_http_key(&migration_post_fake.owner_priv,"bridge","bridge_key","bridge");owner.account_id=account
    return device,owner,{},true
}
migration_post_relay :: proc(h:^Bridge_Handlers,bridge_id,command_id,body:string)->(string,bool,domain.Domain_Error) {
    sync.mutex_lock(&migration_post_fake.mutex);defer sync.mutex_unlock(&migration_post_fake.mutex)
    migration_post_fake.relays+=1
    time.sleep(20*time.Millisecond)
    if migration_post_fake.reply!="" do return strings.clone(migration_post_fake.reply,context.temp_allocator),true,{}
    command:Owner_Migration_Import_Command
    if json.unmarshal_string(body,&command,.JSON,context.temp_allocator)!=nil do return "",false,domain.domain_error(.Internal_Error,"bad command")
    selection,_:=contracts.owner_parse(command.selection,"migration_selection")
    genesis,_:=contracts.owner_parse(command.genesis,"genesis")
    migration_http_sign(&migration_post_fake.owner_priv,"genesis",&genesis,"owner_signature")
    selection_digest,_:=contracts.owner_digest("migration_selection",selection)
    genesis_digest,_:=contracts.owner_digest("genesis",genesis)
    receipt:=migration_http_doc(map[string]string{"protocol_version"="1","account_id"=command.account_id,"chain_id"=command.chain_id,"migration_id"=command.migration_id,"owner_bridge_id"="bridge","key_id"="bridge_key",
        "selection_digest"=selection_digest,"manifest_digest"=command.manifest_digest,"genesis_digest"=genesis_digest,"database_id"="db","import_seq"="9","schema_version"="1","signature"=strings.repeat("0",128)})
    migration_http_sign(&migration_post_fake.owner_priv,"migration_import_receipt",&receipt,"signature")
    reply:=owner_json(Owner_Migration_Import_Reply{"command_result",command_id,"ok",owner_json(receipt),owner_json(genesis)})
    migration_post_fake.reply=strings.clone(reply)
    return reply,true,{}
}
migration_post_env :: proc(live:bool)->Owner_Migration_Env {
    return {
        keys=migration_post_keys,
        bridge_owned=proc(h:^Bridge_Handlers,auth:contracts.Auth_Context,bridge_id:string)->(bool,domain.Domain_Error){return bridge_id=="bridge",{}},
        bridge_live=proc(h:^Bridge_Handlers,bridge_id:string)->bool{return true} if live else proc(h:^Bridge_Handlers,bridge_id:string)->bool{return false},
        relay=migration_post_relay,
        nudge=proc(h:^Bridge_Handlers,account,bridge_id,migration,chain_id,manifest_digest:string)->bool{return true},
    }
}
migration_post_request :: proc(account,chain,migration:string,revision:i64)->string {
    zeros:=strings.repeat("0",128,context.temp_allocator)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    selection:=migration_http_doc(map[string]string{"protocol_version"="1","account_id"=account,"chain_id"=chain,"migration_id"=migration,"owner_bridge_id"="bridge","owner_key_id"="bridge_key",
        "principal_id"="device","key_id"="device","expected_work_revision"=fmt.tprintf("%d",revision),"request_expires_ms"=fmt.tprintf("%d",now+60000),"signature"=zeros})
    migration_http_sign(&migration_post_fake.device_priv,"migration_selection",&selection,"signature")
    genesis:=migration_http_doc(map[string]string{"protocol_version"="1","account_id"=account,"chain_id"=chain,"creation_op"=migration,"owner_bridge_id"="bridge","owner_key_id"="bridge_key",
        "creator_id"="device","creator_key_id"="device","schema_version"="1","creator_signature"=zeros,"owner_signature"=zeros})
    migration_http_sign(&migration_post_fake.device_priv,"genesis",&genesis,"creator_signature")
    return owner_json(Owner_Migration_Request{owner_json(selection),owner_json(genesis)})
}
Migration_Post_Call :: struct { h:^Bridge_Handlers, headers:[]contracts.HTTP_Header, body:string, status:int, response:string }

// Handler-level coverage of the migrate POST: busy-chain neutralization, offline owner,
// concurrent identical POSTs, exact replay, and the abort endpoint.
@(test)
owner_migration_post_blockers_offline_concurrency_replay_and_abort :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened,_:=sqlite.open(":memory:")
    if !testing.expect(t,opened) do return
    defer sqlite.close(&conn)
    migrated,_:=sqlite.run_migrations(&conn)
    _ = sqlite.legacy_fixture_allow_seeding(&conn)
    if !testing.expect(t,migrated) do return
    users:sqlite.User_Repo_SQLite
    user_repo:=sqlite.new_user_repository(&users,&conn)
    clock:=platform.real_clock()
    ids:=http_test_id_generator()
    user_svc:=user_service.new_user_service_basic(&user_repo,&clock,&ids)
    auth:=auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users=true},&user_svc)
    auth.clock=&clock;auth.ids=&ids
    headers:=http_test_login(t,&auth,"migration-post-owner")
    principal,valid,_:=auth_service.resolve_auth_any(&auth,auth_service.Auth_Request{remote_addr="127.0.0.1:4444",headers=headers})
    if !testing.expect(t,valid) do return
    account:=principal.user_id
    impl:sqlite.Taskchain_Repo_SQLite
    repo:=sqlite.new_taskchain_repository(&impl,&conn)
    h:=Bridge_Handlers{auth=&auth,chains=&repo}
    testing.expect(t,vault.p256_private_key_generate(&migration_post_fake.device_priv) && vault.p256_private_key_generate(&migration_post_fake.owner_priv))
    defer {ecdsa.private_key_clear(&migration_post_fake.device_priv);ecdsa.private_key_clear(&migration_post_fake.owner_priv)}
    testing.expect(t,sqlite.exec(&conn,fmt.tprintf(`INSERT INTO task_chains(chain_id,owner_user_id,title,kind,created_at,updated_at) VALUES('chain_a','%s','a','mixed_work','c','u'),('chain_b','%s','b','mixed_work','c','u');
      INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at) VALUES('task_a','chain_a','%s','t','c','u'),('task_b','chain_b','%s','t','c','u');`,account,account,account,account)))
    revision :: proc(conn:^sqlite.Conn,chain:string)->i64 {
        rows,_:=sqlite.legacy_metadata(conn,"SELECT work_revision FROM task_chains WHERE chain_id=?",1,chain)
        n:i64;for b in rows[0][0] do n=n*10+i64(b-'0');return n
    }
    post :: proc(h:^Bridge_Handlers,headers:[]contracts.HTTP_Header,body:string,env:Owner_Migration_Env)->Response {
        return owner_migration_post(h,Request{method="POST",headers=headers,body=body,remote_addr="127.0.0.1:4444"},env)
    }
    // 1. Busy chain, owner offline: no longer refused. The import neutralizes
    // the live work (lease ended, in-progress task force-held) in the freeze
    // transaction, and the chain stays frozen until the import is retried.
    testing.expect(t,sqlite.exec(&conn,fmt.tprintf(`INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery)
      VALUES('lease_a','task_a','chain_a','%s',1,'inst','work','g','e','h','wake'); UPDATE tasks SET state='in_progress' WHERE task_id='task_a';`,account)))
    request_a:=migration_post_request(account,"chain_a","mig_a",revision(&conn,"chain_a"))
    offline:=post(&h,headers,request_a,migration_post_env(false))
    testing.expect(t,offline.status>=400 && strings.contains(offline.body,"owner_unavailable"),offline.body)
    f,_,_:=repo.legacy_source_get(repo.ctx,account,"chain_a")
    testing.expect_value(t,f.state,"frozen")
    testing.expect_value(t,f.forced_held_json,`["task_a"]`)
    testing.expect(t,strings.contains(f.neutralized_json,`"code":"live_leases_ended","count":1,"items":["lease_a"]`),f.neutralized_json)
    leases,_:=sqlite.legacy_metadata(&conn,"SELECT count(*) FROM task_leases",1)
    testing.expect_value(t,leases[0][0],"0")
    testing.expect_value(t,migration_post_fake.relays,0)
    // 3. Concurrent identical POSTs both succeed; one route, one import state.
    calls:[2]Migration_Post_Call
    threads:[2]^thread.Thread
    for &call,i in calls {
        call={h=&h,headers=headers,body=request_a}
        threads[i]=thread.create_and_start_with_poly_data(&call,proc(c:^Migration_Post_Call) {
            context.allocator=context.temp_allocator
            r:=owner_migration_post(c.h,Request{method="POST",headers=c.headers,body=c.body,remote_addr="127.0.0.1:4444"},migration_post_env(true))
            c.status=r.status;c.response=strings.clone(r.body)
        })
    }
    for th in threads { thread.join(th);thread.destroy(th) }
    for call in calls do testing.expectf(t,call.status==200 && strings.contains(call.response,`"state":"imported"`) && strings.contains(call.response,`"forced_held":["task_a"]`),"concurrent POST: %d %s",call.status,call.response)
    routes,_:=sqlite.legacy_metadata(&conn,"SELECT count(*) FROM owner_local_chains WHERE chain_id='chain_a'",1)
    testing.expect_value(t,routes[0][0],"1")
    // 4. Exact replay after cutover: read-only, no new relay.
    relays:=migration_post_fake.relays
    replay:=post(&h,headers,request_a,migration_post_env(true))
    testing.expect(t,replay.status==200 && strings.contains(replay.body,`"replayed":true`),replay.body)
    testing.expect_value(t,migration_post_fake.relays,relays)
    abort :: proc(h:^Bridge_Handlers,headers:[]contracts.HTTP_Header,chain,migration:string)->Response {
        return owner_migration_abort_handler(h,Request{method="POST",headers=headers,body=owner_json(Owner_Migration_Abort_Request{chain,migration}),remote_addr="127.0.0.1:4444"})
    }
    // Abort is a human decision: agent instance tokens are refused.
    testing.expect(t,!owner_migration_abort_authorized(contracts.Auth_Context{kind=.Instance_Token,user_id=account}))
    testing.expect(t,owner_migration_abort_authorized(contracts.Auth_Context{kind=.Session,user_id=account}))
    // 5. An imported migration cannot be aborted.
    testing.expect_value(t,abort(&h,headers,"chain_a","mig_a").status,409)
    // 6. Abort a frozen migration: the chain is a plain legacy record again
    // (no fence), the same selection cannot freeze again and a late cutover is
    // refused; a new signed selection may import it.
    request_b:=migration_post_request(account,"chain_b","mig_b",revision(&conn,"chain_b"))
    testing.expect(t,post(&h,headers,request_b,migration_post_env(false)).status>=400)
    testing.expect(t,!sqlite.exec(&conn,"UPDATE tasks SET title='frozen' WHERE task_id='task_b'"))
    aborted:=abort(&h,headers,"chain_b","mig_b")
    testing.expect(t,aborted.status==200 && strings.contains(aborted.body,`"state":"aborted"`),aborted.body)
    testing.expect(t,sqlite.exec(&conn,"UPDATE tasks SET title='writable' WHERE task_id='task_b'"),"legacy writer released")
    again:=post(&h,headers,request_b,migration_post_env(true))
    testing.expect_value(t,again.status,409)
    _,refrozen,_:=repo.legacy_source_get(repo.ctx,account,"chain_b")
    testing.expect(t,!refrozen,"an aborted selection never freezes the chain again")
    testing.expect_value(t,abort(&h,headers,"chain_b","mig_b").status,200)
    testing.expect_value(t,abort(&h,headers,"chain_b","mig_unknown").status,404)
    sync.mutex_lock(&migration_post_fake.mutex)
    delete(migration_post_fake.reply);migration_post_fake.reply=""
    sync.mutex_unlock(&migration_post_fake.mutex)
}
