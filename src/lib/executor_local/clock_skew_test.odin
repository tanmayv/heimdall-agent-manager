package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"

// G3: the owner's request expiry is set by the owner's clock. An executor
// whose clock runs behind accepts it up to EXECUTOR_CLOCK_SKEW_MS beyond the
// request TTL; further out, or already expired, is refused.
@(test)
executor_request_live_tolerates_clock_skew :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    now:=i64(1_000_000)
    request :: proc(expires:i64) -> json.Object {
        o:=make(json.Object,context.temp_allocator)
        o["request_expires_ms"]=json.String(fmt.tprintf("%d",expires))
        return o
    }
    testing.expect(t,request_live(request(now+contracts.OWNER_REQUEST_TTL_MS),now),"exactly the TTL")
    testing.expect(t,request_live(request(now+contracts.OWNER_REQUEST_TTL_MS+contracts.EXECUTOR_CLOCK_SKEW_MS),now),"owner clock ahead within the tolerance")
    testing.expect(t,!request_live(request(now+contracts.OWNER_REQUEST_TTL_MS+contracts.EXECUTOR_CLOCK_SKEW_MS+1),now),"beyond the tolerance")
    testing.expect(t,!request_live(request(now),now),"expired")
}
