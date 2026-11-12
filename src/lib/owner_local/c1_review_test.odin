package owner_local
import "core:testing"
@(test)
review_c1_activation_clamps_stale_time :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    x:=execution_test_fixture(t);defer execution_test_destroy(x);f:=x.owner
    testing.expect_value(t,execution_prepare_start(&f.store,x.prepare,x.lease,f.owner,1000).code,"ok")
    x.receipt=execution_test_prepare(t,x)
    testing.expect_value(t,execution_test_commit(x).code,"ok")
    claim:=execution_test_claim(t,f)
    current,_,_,_:=execution_activation_fence(&f.store,claim,1100)
    testing.expect(t,current)
    current,_,_,_=execution_activation_fence(&f.store,claim,1099)
    testing.expect(t,current,"stale caller time must clamp, not refuse")
}
@(test)
review_c1_compaction_clamps_stale_time :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f)
    testing.expect(t,exec(f.store.db,"UPDATE runtime_database SET clock_high_ms=3000000000"))
    _,ok:=compact_receipts(&f.store,2999999999)
    testing.expect(t,ok,"stale caller time must clamp, not refuse")
}
