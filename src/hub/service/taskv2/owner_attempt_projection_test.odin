package taskv2

import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import local "odin_test:lib/owner_local"

// Compare every prefix against the original authoritative fold, including the
// distinction between a spent attempt and a non-counting NEXT grant. This is
// intentionally differential rather than a second list of expected counters.
@(test)
test_owner_attempt_projection_matches_native_fold_prefixes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    Step :: struct { native_kind,native_payload,local_kind,local_payload:string }
    steps:=[?]Step{
        {EV_LEASE_GRANTED,`{"lease_id":"a"}`,"lease.claim",`{}`},
        {EV_HANDOFF,`{}`,"lease.handoff",`{}`},
        {EV_LEASE_GRANTED,`{"lease_id":"b"}`,"lease.claim",`{}`},
        {EV_LEASE_EXPIRED,`{}`,"lease.expired",`{}`},
        {EV_LEASE_GRANTED,`{"lease_id":"c"}`,"lease.claim",`{}`},
        {EV_SUBMITTED,`{}`,"lease.submit",`{}`},
        {EV_CHANGES_REQUESTED,`{}`,"review.post",`{"verdict":"request_changes"}`},
        {EV_LEASE_GRANTED,`{"lease_id":"d"}`,"lease.claim",`{}`},
        {EV_LEASE_EXPIRED,`{"reason":"replaced"}`,"fleet.edit",`{}`},
        {EV_LEASE_GRANTED,`{"lease_id":"e"}`,"lease.claim",`{}`},
        {EV_CANCELLED,`{}`,"task.cancel",`{}`},
        {EV_REOPENED,`{}`,"task.reopen",`{}`},
        {EV_LEASE_GRANTED,`{"lease_id":"f"}`,"lease.claim",`{}`},
        {EV_LEASE_EXPIRED,`{}`,"lease.expired",`{}`},
        {EV_LEASE_GRANTED,`{"lease_id":"g"}`,"lease.claim",`{}`},
        {EV_SUBMITTED,`{}`,"lease.submit",`{}`},
        {EV_REQUIREMENTS_REWORK,`{}`,"requirements.edit",`{}`},
        {EV_LEASE_GRANTED,`{"lease_id":"h"}`,"lease.claim",`{}`},
    }
    events:=make([dynamic]domain.Task_Event,context.temp_allocator)
    view:local.Attempt_View
    input:=Fold_Input{deps_done=true,kind=.Task,review_roles_count=1,max_attempts=100}
    for step,i in steps {
        append(&events,domain.Task_Event{event_id=i64(i+1),ts_ms=i64(i+1),kind=step.native_kind,payload_json=step.native_payload})
        c_value,c_ok:=contracts.owner_request_document(step.native_payload);c,_:=c_value.(json.Object)
        p_value,p_ok:=contracts.owner_request_document(step.local_payload);p,_:=p_value.(json.Object)
        testing.expect(t,c_ok && p_ok)
        local.attempt_event(&view,step.local_kind,c,p)
        native:=fold_task(events[:],input)
        testing.expect_value(t,view.attempt_no,i64(native.attempt_no))
        testing.expect_value(t,view.counting_attempts,i64(native.counting_attempts))
        testing.expect_value(t,view.live,native.has_work_lease)
        testing.expect(t,!view.incomplete)
    }
}
