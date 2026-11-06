package taskv2

import "core:encoding/json"
import "core:strconv"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// The exact source fixture imported by owner-local tests must agree with the
// authoritative native fold. In particular two leases after a handoff are one
// logical attempt, and a replaced attempt makes the next grant non-counting.
@(test)
test_owner_native_import_fixture_matches_original_attempt_accounting :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    raw:=string(#load("../../../contracts/fixtures/owner-native-history.json"))
    bundle,ok:=contracts.owner_parse(raw,"native_history_bundle")
    if !testing.expect(t,ok) do return
    source,_:=contracts.owner_request_document(contracts.owner_string(bundle,"events"));items,_:=source.(json.Array)
    events:=make([dynamic]domain.Task_Event,context.temp_allocator)
    coordinator:=false
    for item in items {
        text,_:=item.(json.String)
        record,valid:=contracts.owner_parse(string(text),"native_history_event")
        if !testing.expect(t,valid) do return
        id,_:=strconv.parse_i64(contracts.owner_string(record,"event_id"))
        ts,_:=strconv.parse_i64(contracts.owner_string(record,"ts_ms"))
        actor:=contracts.owner_string(record,"actor_kind")
        if actor==ACTOR_COORDINATOR do coordinator=true
        append(&events,domain.Task_Event{event_id=id,ts_ms=ts,actor_kind=actor,actor_id=contracts.owner_string(record,"actor_id"),kind=contracts.owner_string(record,"kind"),payload_json=contracts.owner_string(record,"payload_json")})
    }
    native:=fold_task(events[:],Fold_Input{deps_done=true,kind=.Task,review_roles_count=1,max_attempts=100})
    source,_=contracts.owner_request_document(contracts.owner_string(bundle,"attempts"));attempts,_:=source.(json.Array)
    counted:=0
    for item in attempts {
        text,_:=item.(json.String);record,valid:=contracts.owner_parse(string(text),"native_history_attempt")
        testing.expect(t,valid)
        if contracts.owner_string(record,"counts_toward_budget")=="1" do counted+=1
    }
    testing.expect_value(t,native.attempt_no,len(attempts))
    testing.expect_value(t,native.counting_attempts,counted)
    testing.expect_value(t,native.attempt_no,3)
    testing.expect_value(t,counted,2)
    testing.expect(t,coordinator && !native.has_work_lease && native.in_review)
}
