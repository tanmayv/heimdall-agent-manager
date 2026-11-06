package taskv2

import "core:testing"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import local "odin_test:lib/owner_local"

// Compare each prefix with the original fold and its actual admission helper.
// Includes a declared pre-v2 baseline without inventing old attempt records.
@(test)
test_owner_budget_native_fold_and_admission_prefixes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    Step :: struct { kind,payload:string }
    sequences:=[?][]Step{
        {
            {EV_CREATED,`{}`},{EV_PUBLISHED,`{}`},
            {EV_LEASE_GRANTED,`{"lease_id":"a","instance_id":"worker"}`},
            {EV_HELD,`{}`},{EV_HANDOFF,`{}`},{EV_HOLD_RELEASED,`{}`},
            {EV_LEASE_GRANTED,`{"lease_id":"b"}`},
            {EV_LEASE_EXPIRED,`{"kind":"review","reason":"ttl"}`},
            {EV_LEASE_EXPIRED,`{"reason":"ttl"}`},
            {EV_LEASE_GRANTED,`{"lease_id":"c"}`},{EV_SUBMITTED,`{}`},
            {EV_CHANGES_REQUESTED,`{}`},{EV_ANSWERED,`{}`},
            {EV_CANCELLED,`{}`},{EV_REOPENED,`{}`},
            {EV_LEASE_GRANTED,`{"lease_id":"d"}`},{EV_LEASE_EXPIRED,`{"reason":"dep_added"}`},
            {EV_LEASE_GRANTED,`{"lease_id":"e"}`},{EV_LEASE_EXPIRED,`{"reason":"replaced"}`},
            {EV_LEASE_GRANTED,`{"lease_id":"f"}`},{EV_SUBMITTED,`{}`},
            {EV_REQUIREMENTS_REWORK,`{}`},{EV_LEASE_GRANTED,`{"lease_id":"g"}`},
            {EV_LEASE_EXPIRED,`{"reason":"user_stopped"}`},{EV_LEASE_GRANTED,`{"lease_id":"h"}`},
            {EV_LEASE_EXPIRED,`{"reason":"ttl","counting":false}`},
            {EV_LEASE_GRANTED,`{"lease_id":"i"}`},{EV_LEASE_EXPIRED,`{"reason":"ttl"}`},
        },
        {
            {EV_MIGRATED,`{"state":"ready","attempt_no":4,"published":true}`},
            {EV_LEASE_GRANTED,`{"lease_id":"after_migration"}`},{EV_HANDOFF,`{}`},
            {EV_LEASE_GRANTED,`{"lease_id":"continuation"}`},{EV_BLOCKED,`{}`},
            {EV_ANSWERED,`{}`},{EV_CANCELLED,`{}`},{EV_REOPENED,`{}`},
            {EV_LEASE_GRANTED,`{"lease_id":"recovered"}`},{EV_BLOCKED,`{}`},
        },
        {
            {EV_LEASE_GRANTED,`{"lease_id":"failed_dispatch"}`},
            {EV_BLOCKED,`{"dispatch_failed":true}`},
            {EV_LEASE_GRANTED,`{"lease_id":"real"}`},{EV_HANDOFF,`{}`},
            {EV_LEASE_GRANTED,`{"lease_id":"handoff_dispatch"}`},
            {EV_BLOCKED,`{"dispatch_failed":true,"continuation":true}`},
            {EV_BLOCKED,`{"infrastructure":true,"waiting_on":{"reason":"agent_not_running"}}`},
            {EV_ANSWERED,`{}`},{EV_LEASE_GRANTED,`{"lease_id":"resumed"}`},
            {EV_SUBMITTED,`{}`},{EV_LEASE_GRANTED,`{"kind":"review"}`},
            {EV_BLOCKED,`{"kind":"review","dispatch_failed":true}`},
            {EV_CHANGES_REQUESTED,`{}`},
        },
    }
    for maximum in ([3]int{1,2,5}) {
        for steps in sequences {
            events:=make([dynamic]domain.Task_Event,context.temp_allocator)
            view:local.Budget_State
            input:=Fold_Input{kind=.Task,deps_done=true,review_roles_count=1,max_attempts=maximum}
            for step,i in steps {
                append(&events,domain.Task_Event{event_id=i64(i+1),ts_ms=i64(i+1),kind=step.kind,payload_json=step.payload})
                local.budget_event(&view,step.kind,step.payload,local.Budget_Input{max_attempts=i64(maximum)})
                native:=fold_task(events[:],input)
                testing.expect_value(t,view.attempt_no,i64(native.attempt_no))
                testing.expect_value(t,view.counting_attempts,i64(native.counting_attempts))
                testing.expect_value(t,view.exhausted,native.budget_exhausted)
                testing.expect_value(t,view.live,native.has_work_lease)
                testing.expect_value(t,view.in_review,native.in_review)
                testing.expect_value(t,view.review_rounds,i64(native.review_rounds))
                testing.expect_value(t,view.review_leases,i64(native.review_lease_count))
                testing.expect_value(t,view.done,native.done)
                testing.expect_value(t,view.cancelled,native.cancelled)
                testing.expect_value(t,view.held,native.held)
                testing.expect_value(t,local.budget_allows(view,i64(maximum)),budget_allows_grant(native,maximum))
            }
        }
    }
}

// Native oracle for the signed owner-local command regressions in
// budget_review_test.odin and dependency_budget_test.odin. These state checks
// cover actual admission dispositions in addition to counter-only prefixes.
@(test)
test_owner_review_recovery_dependency_and_oscillation_native_oracles :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    expired:=[3]domain.Task_Event{{kind=EV_PUBLISHED,payload_json=`{}`},{kind=EV_LEASE_GRANTED,payload_json=`{"lease_id":"only"}`},{kind=EV_LEASE_EXPIRED,payload_json=`{"reason":"ttl"}`}}
    recovered:=fold_task(expired[:],Fold_Input{kind=.Task,deps_done=true,review_roles_count=1,max_attempts=2})
    testing.expect(t,recovered.state==.Ready && recovered.counting_attempts==1 && budget_allows_grant(recovered,2))
    dependency:=[3]domain.Task_Event{{kind=EV_PUBLISHED,payload_json=`{}`},{kind=EV_LEASE_GRANTED,payload_json=`{"lease_id":"source_lease"}`},{kind=EV_LEASE_EXPIRED,payload_json=`{"lease_id":"source_lease","reason":"dep_added"}`}}
    released:=fold_task(dependency[:],Fold_Input{kind=.Task,deps_done=false,review_roles_count=1,max_attempts=1})
    testing.expect(t,released.counting_attempts==1 && !released.has_work_lease && !released.budget_exhausted && budget_allows_grant(released,1))
    events:=make([dynamic]domain.Task_Event,context.temp_allocator)
    append(&events,..dependency[:]);append(&events,domain.Task_Event{kind=EV_DEP_ADDED,payload_json=`{"depends_on":"dest"}`})
    append(&events,domain.Task_Event{kind=EV_LEASE_GRANTED,payload_json=`{"lease_id":"source_next"}`})
    continued:=fold_task(events[:],Fold_Input{kind=.Task,deps_done=true,review_roles_count=1,max_attempts=1})
    testing.expect(t,continued.attempt_no==2 && continued.counting_attempts==1 && continued.has_work_lease)
    clear(&events);append(&events,domain.Task_Event{kind=EV_PUBLISHED,payload_json=`{}`})
    for _ in 0..<3 {
        append(&events,domain.Task_Event{kind=EV_LEASE_GRANTED,payload_json=`{"lease_id":"reviewed"}`},domain.Task_Event{kind=EV_SUBMITTED,payload_json=`{}`},domain.Task_Event{kind=EV_CHANGES_REQUESTED,payload_json=`{}`})
    }
    oscillating:=fold_task(events[:],Fold_Input{kind=.Task,deps_done=true,review_roles_count=1,max_attempts=5})
    testing.expect(t,oscillating.oscillating && oscillating.state==.Backlog && strings.contains(oscillating.blocked_on_json,"oscillation"))
    append(&events,domain.Task_Event{kind=EV_ANSWERED,payload_json=`{}`})
    answered:=fold_task(events[:],Fold_Input{kind=.Task,deps_done=true,review_roles_count=1,max_attempts=5})
    testing.expect(t,!answered.oscillating && answered.counting_attempts==3 && answered.state==.Ready && budget_allows_grant(answered,5))
}

@(test)
test_owner_budget_shared_migrated_fixture_matches_native_admission :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    raw:=string(#load("../../../contracts/fixtures/owner-native-budget.json"))
    bundle,ok:=contracts.owner_parse(raw,"native_history_bundle");if !testing.expect(t,ok) do return
    value,_:=contracts.owner_request_document(contracts.owner_string(bundle,"events"));items,_:=value.(json.Array)
    events:=make([dynamic]domain.Task_Event,context.temp_allocator)
    local_view:local.Budget_State
    input:=Fold_Input{kind=.Task,deps_done=true,review_roles_count=1,max_attempts=5}
    for item in items {
        raw,_:=item.(json.String);record,valid:=contracts.owner_parse(string(raw),"native_history_event")
        testing.expect(t,valid)
        id,_:=strconv.parse_i64(contracts.owner_string(record,"event_id"))
        kind,payload:=contracts.owner_string(record,"kind"),contracts.owner_string(record,"payload_json")
        append(&events,domain.Task_Event{event_id=id,kind=kind,payload_json=payload})
        local.budget_event(&local_view,kind,payload,local.Budget_Input{max_attempts=5})
        native:=fold_task(events[:],input)
        testing.expect_value(t,local_view.attempt_no,i64(native.attempt_no))
        testing.expect_value(t,local_view.counting_attempts,i64(native.counting_attempts))
        testing.expect_value(t,local.budget_allows(local_view,5),budget_allows_grant(native,5))
    }
    native:=fold_task(events[:],input)
    testing.expect(t,native.attempt_no==5 && native.counting_attempts==5 && budget_allows_grant(native,5),"handoff can continue the seeded final attempt")
    append(&events,domain.Task_Event{kind=EV_LEASE_GRANTED,payload_json=`{"lease_id":"continued"}`})
    append(&events,domain.Task_Event{kind=EV_BLOCKED,payload_json=`{}`})
    native=fold_task(events[:],input)
    testing.expect(t,native.budget_exhausted && !budget_allows_grant(native,5))
    // Source task kind/review facts are explicit activation manifest pins.
    for gate in ([2]bool{false,true}) {
        for no_review in ([2]bool{false,true}) {
            local_view={}
            simple:=[3]domain.Task_Event{{kind=EV_LEASE_GRANTED,payload_json=`{"lease_id":"work"}`},{kind=EV_SUBMITTED,payload_json=`{}`},{kind=EV_CHANGES_REQUESTED,payload_json=`{}`}}
            for e in simple do local.budget_event(&local_view,e.kind,e.payload_json,local.Budget_Input{max_attempts=1,gate=gate,no_review=no_review})
            folded:=fold_task(simple[:],Fold_Input{kind=(.Gate if gate else .Task),max_attempts=1,review_roles_count=(0 if no_review else 1),deps_done=true})
            testing.expect_value(t,local_view.done,folded.done)
            testing.expect_value(t,local_view.cancelled,folded.cancelled)
            testing.expect_value(t,local_view.exhausted,folded.budget_exhausted)
        }
    }
}
