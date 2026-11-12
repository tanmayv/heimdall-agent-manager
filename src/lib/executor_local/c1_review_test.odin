package executor_local
import "core:testing"
@(test)
review_c1_prepare_uses_high_water_deadline :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    testing.expect(t,exec(f.store.db,"UPDATE executor_runtime SET clock_high_ms=20000"))
    p:=document("prepare")
    testing.expect_value(t,reserve(f,p,&f.owner1,1000).code,"expired")
}
@(test)
review_c1_expire_uses_high_water_deadline :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    p:=document("prepare")
    testing.expect_value(t,reserve(f,p,&f.owner1,1000).code,"ok")
    testing.expect(t,exec(f.store.db,"UPDATE executor_runtime SET clock_high_ms=20000"))
    testing.expect(t,expire(&f.store,1000))
    rows,ok:=query(f.store.db,"SELECT state FROM executor_reservations WHERE reservation_id='reservation'")
    testing.expect(t,ok && len(rows)==1)
    testing.expect_value(t,rows[0][0],"released")
}
