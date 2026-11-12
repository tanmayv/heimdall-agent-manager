package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import user_service "odin_test:hub/service/user"

// Another paired Bridge of the account reaches the owner-local relay and the
// registry listing (origin/main parity); every lookup stays scoped to the
// token's account, and an agent instance token only relays.
@(test)
owner_local_admits_a_same_account_bridge_token :: proc(t:^testing.T) {
    bridge:=contracts.Auth_Context{kind=.Bridge_Token,user_id="alice",bridge_id="brg_b"}
    testing.expect(t,owner_local_caller_admitted(bridge,true),"bridge token relays")
    testing.expect(t,owner_local_caller_admitted(bridge,false),"bridge token lists the registry")
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{kind=.Bridge_Token,bridge_id="brg_b"},true),"a bridge token without an account is refused")
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{kind=.Bridge_Token,user_id="alice"},false),"a bridge token without a bridge id is refused")
    instance:=contracts.Auth_Context{kind=.Instance_Token,user_id="alice",agent_instance_id="inst_1"}
    testing.expect(t,owner_local_caller_admitted(instance,true))
    testing.expect(t,!owner_local_caller_admitted(instance,false),"an agent token does not list the registry")
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{kind=.Enrollment_Token,user_id="alice"},true))
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{},true))
}

// Cross-Bridge placement: the chain's owner Bridge (a Bridge token of the
// account) relays an issuance request to another Bridge and is named to it as
// from_bridge_id; the executor admits a Bridge consent only from that Bridge.
@(test)
executor_issuance_admits_user_or_another_account_bridge :: proc(t:^testing.T) {
    from,ok:=executor_issuance_sender(contracts.Auth_Context{kind=.Bridge_Token,user_id="alice",bridge_id="brg_a"},"brg_b")
    testing.expect(t,ok && from=="brg_a","another Bridge of the account relays and is named")
    _,ok=executor_issuance_sender(contracts.Auth_Context{kind=.Bridge_Token,user_id="alice",bridge_id="brg_b"},"brg_b")
    testing.expect(t,!ok,"a Bridge never relays issuance to itself")
    _,ok=executor_issuance_sender(contracts.Auth_Context{kind=.Bridge_Token,bridge_id="brg_a"},"brg_b")
    testing.expect(t,!ok,"a bridge token without an account is refused")
    _,ok=executor_issuance_sender(contracts.Auth_Context{kind=.Bridge_Token,user_id="alice"},"brg_b")
    testing.expect(t,!ok,"a bridge token without a bridge id is refused")
    _,ok=executor_issuance_sender(contracts.Auth_Context{kind=.Instance_Token,user_id="alice",agent_instance_id="inst_1"},"brg_b")
    testing.expect(t,!ok,"an agent token never relays issuance")
    _,ok=executor_issuance_sender(contracts.Auth_Context{kind=.Enrollment_Token,user_id="alice"},"brg_b")
    testing.expect(t,!ok)
    _,ok=executor_issuance_sender(contracts.Auth_Context{},"brg_b")
    testing.expect(t,!ok)
}

// R1 FIX A (REQ-E2E-1 run9): Bridge B looks the owner of a chain up in this
// listing before it relays its reviewer's `lease next`. The route resolved
// only user credentials, so B's Bridge token was refused ("bridge token cannot
// call user APIs") and nothing was ever relayed. It takes the Bridge-token
// resolver like the other owner-local Bridge routes (here unwired, so it
// reports the bridge auth service instead of the user-API refusal).
@(test)
owner_local_listing_reaches_the_bridge_token_resolver :: proc(t:^testing.T) {
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
    h:=Bridge_Handlers{auth=&auth}
    headers:=[]contracts.HTTP_Header{{"Authorization","Bearer hba_btk_1.secret"}}
    response:=owner_local_list_handler(&h,Request{method="GET",path="/api/v1/owner-local/chains",headers=headers,remote_addr="127.0.0.1:4444"})
    testing.expectf(t,!strings.contains(response.body,"cannot call user APIs"),"a Bridge token reaches the bridge resolver: %d %s",response.status,response.body)
}
