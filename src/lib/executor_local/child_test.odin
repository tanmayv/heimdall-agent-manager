#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

executor_child_input :: proc(x:Bootstrap_Fixture)->string {
    return encode(contracts.Owner_Lease_Input{"1",field(x.b,"chain_id"),field(x.b,"task_id"),field(x.b,"lease_id"),
        field(x.b,"configuration_revision"),"1","child_heartbeat","lease.heartbeat","1900","capability"})
}

@(test)
executor_child_auth_requires_exact_issued_secret_confirmed_live_generation_and_deadline :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    intent,taken:=take_intent(&f.store,1300);testing.expect(t,taken)
    material,ready:=launch_material(&f.store,intent,1300);testing.expect(t,ready)
    _,authenticated:=child_bootstrap(&f.store,intent.instance,material.token_secret,1300)
    testing.expect(t,!authenticated,"accepted content is not a confirmed live child")
    testing.expect(t,begin_dispatch(&f.store,intent,1300))
    testing.expect(t,observe_child(&f.store,intent.reservation,{intent.instance,intent.launch_key,f.store.incarnation,true}))
    raw:string
    raw,authenticated=child_bootstrap(&f.store,intent.instance,material.token_secret,1300)
    testing.expect(t,authenticated && raw==x.raw)
    for bad in ([3]string{"",strings.concatenate({material.token_secret," "},context.temp_allocator),"other_secret"}) {
        _,authenticated=child_bootstrap(&f.store,intent.instance,bad,1300)
        testing.expect(t,!authenticated)
    }
    _,authenticated=child_bootstrap(&f.store,"other_instance",material.token_secret,1300);testing.expect(t,!authenticated)
    _,authenticated=child_bootstrap(&f.store,intent.instance,material.token_secret,5000);testing.expect(t,!authenticated,"deadline is enforced without maintenance")
    _,authenticated=child_bootstrap(&f.store,intent.instance,material.token_secret,1299);testing.expect(t,!authenticated,"clock regression fails closed")
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    _,authenticated=child_bootstrap(&f.store,intent.instance,material.token_secret,1400);testing.expect(t,!authenticated,"restart never silently authenticates an old child generation")
}

@(test)
executor_child_attestation_binds_input_observation_keys_and_cannot_grant_task_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    x:=bootstrap_fixture(t,f)
    testing.expect_value(t,accept_bootstrap(&f.store,x.raw,x.body,x.action,f.owner1.public,1300,proof(x.a)).code,"ok")
    intent,_:=take_intent(&f.store,1300)
    material,ready:=launch_material(&f.store,intent,1300);testing.expect(t,ready)
    testing.expect(t,begin_dispatch(&f.store,intent,1300))
    live:=Child_Observation{intent.instance,intent.launch_key,f.store.incarnation,true}
    testing.expect(t,observe_child(&f.store,intent.reservation,live))
    input:=executor_child_input(x)
    sign:=Signer{&f.operator,sign_receipt}
    result:=attest_child_request(&f.store,intent.instance,material.token_secret,input,live,f.owner1.public,f.operator.public,1400,sign)
    if !testing.expect_value(t,result.code,"ok") do return
    r,valid:=contracts.executor_parse(result.body,"child_request");testing.expect(t,valid)
    b,_:=contracts.executor_parse(x.raw,"bootstrap")
    testing.expect(t,contracts.executor_child_request_matches(r,b,input,f.operator.public,f.owner1.public,1400))
    testing.expect(t,!strings.contains(result.body,material.token_secret) && !strings.contains(result.body,"capability"),"attestation carries digests, not credentials or input")
    for i in 0..<4 {
        bad:=live
        switch i {case 0:bad.instance="other";case 1:bad.launch_key=strings.repeat("0",64,context.temp_allocator);case 2:bad.executor_incarnation+=1;case 3:bad.present=false}
        testing.expect_value(t,attest_child_request(&f.store,intent.instance,material.token_secret,input,bad,f.owner1.public,f.operator.public,1400,sign).code,"invalid_scope")
    }
    wrong,_:=contracts.owner_parse(input,"lease_input");wrong["task_id"]=json.String("other_task")
    testing.expect_value(t,attest_child_request(&f.store,intent.instance,material.token_secret,encode(wrong),live,f.owner1.public,f.operator.public,1400,sign).code,"invalid_scope")
    revoked:=f.owner1.public;revoked.revoked=true
    testing.expect_value(t,attest_child_request(&f.store,intent.instance,material.token_secret,input,live,revoked,f.operator.public,1400,sign).code,"invalid_scope")
    revoked=f.operator.public;revoked.revoked=true
    testing.expect_value(t,attest_child_request(&f.store,intent.instance,material.token_secret,input,live,f.owner1.public,revoked,1400,sign).code,"invalid_scope")
    testing.expect_value(t,attest_child_request(&f.store,intent.instance,material.token_secret,input,live,f.owner1.public,f.operator.public,1900,sign).code,"ok")
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM executor_reservations),(SELECT count(*) FROM executor_intents),(SELECT count(*) FROM executor_receipts)")
    testing.expect(t,ok && rows[0][0]=="1" && rows[0][1]=="1" && rows[0][2]=="2","attesting never allocates another reservation, intent or action receipt")
    testing.expect(t,expire(&f.store,5000))
    testing.expect_value(t,attest_child_request(&f.store,intent.instance,material.token_secret,input,live,f.owner1.public,f.operator.public,5000,sign).code,"invalid_scope")
}
