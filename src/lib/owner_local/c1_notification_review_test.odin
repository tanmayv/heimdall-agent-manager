package owner_local
import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"
@(test)
review_c1_notification_signs_at_effective_time :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x,activation:=execution_bootstrap_fixture(t);defer execution_test_destroy(x);f:=x.owner
    sign:=Signer{&f.owner_priv,execution_test_sign}
    if !testing.expect_value(t,execution_bootstrap(&f.store,activation,"Worker","","[]",f.owner,1200,sign).code,"ok") do return
    if !testing.expect_value(t,r5_hold(f,"review_hold",1300).code,"ok") do return
    claims:=r5_notification_claims(t,f,1300)
    if !testing.expect_value(t,len(claims),1) do return
    testing.expect(t,exec(f.store.db,"UPDATE runtime_database SET clock_high_ms=20000"))
    result:=execution_notification(&f.store,claims[0],f.owner,5000,sign)
    if !testing.expect_value(t,result.code,"ok") do return
    v,_:=contracts.owner_content_document(result.body);body,_:=v.(json.Object)
    n,ok:=contracts.executor_parse(field(body,"notification"),"notification")
    if !testing.expect(t,ok) do return
    testing.expect_value(t,contracts.executor_number(n,"issued_ms"),i64(20000))
    testing.expect(t,contracts.executor_number(n,"request_expires_ms")>20000,"new notification is live at effective time")
}
