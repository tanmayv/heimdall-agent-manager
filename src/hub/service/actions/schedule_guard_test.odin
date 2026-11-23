package actions

import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_schedule_guard_and_event_key :: proc(t:^testing.T) {actions_track(t,schedule_guard_cases)}
schedule_guard_cases :: proc(t:^testing.T) {
	keys:=[?]struct{next,expected:string}{{"","2:once"},{"purge","2:once"},{"2027-01-01T00:00:00Z","2:2027-01-01T00:00:00Z"}}
	for c in keys {
		key:=schedule_event_key({trigger_rev="2",schedule_next=c.next},context.allocator)
		testing.expect_value(t,key,c.expected)
		delete(key)
	}
	ms,_:=schedule_time("2026-01-01T01:00:00Z")
	cases:=[?]struct{config,rev,reason:string,run,retire:bool}{
		{"{\"mode\":\"once\"}","1","stale_rev",false,false},
		{"{\"mode\":\"once\"}","2","",true,true},
		{"{\"mode\":\"interval\",\"active_from\":\"2026-01-02T00:00:00Z\"}","2","outside_window",false,false},
		{"{\"mode\":\"interval\",\"active_until\":\"2025-12-31T00:00:00Z\"}","2","outside_window",false,true},
		{"{\"mode\":\"interval\",\"timezone\":\"America/New_York\",\"blackout_dates\":[\"2025-12-31\"]}","2","blackout",false,false},
		{"{\"mode\":\"once\",\"blackout_dates\":[\"2026-01-01\"]}","2","blackout",false,true},
		{"{\"mode\":\"interval\"}","2","",true,false},
	}
	for c in cases {
		run,reason,retire:=schedule_guard(domain.Action_Trigger{rev=2,config_json=c.config},Event_View{trigger_rev=c.rev,stream_time_ms=ms})
		testing.expect_value(t,run,c.run)
		testing.expect_value(t,reason,c.reason)
		testing.expect_value(t,retire,c.retire)
	}
}
