package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"

actions_track :: proc(t:^testing.T,scenario:proc(^testing.T)) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	scenario(t)
	testing.expect_value(t,len(track.allocation_map),0)
}
compile_case :: proc(t:^testing.T,kind,config_text,code,subject:string) {
	value:json.Value
	if !testing.expect(t,json.unmarshal(transmute([]u8)config_text,&value)==nil) do return
	defer json.destroy_value(value)
	config,_:=value.(json.Object)
	entry,found:=trigger_kind_find(kind)
	if !testing.expect(t,found) do return
	spec,err:=entry.compile("owner","act_a","trg_a",config,context.allocator)
	defer match_spec_destroy(&spec)
	if code=="" {
		testing.expect_value(t,err.code,domain.Error_Code.None)
		if subject!="" do testing.expect_value(t,spec.subject_filter,subject)
	} else {
		testing.expect(t,err.code!=.None)
		testing.expect(t,strings.contains(err.details_json,code),err.details_json)
	}
}
@(test)
test_schedule_compile_table :: proc(t:^testing.T) {actions_track(t,schedule_compile_cases)}
schedule_compile_cases :: proc(t:^testing.T) {
	cases:=[?]struct{config,code:string}{
		{"{\"mode\":\"cron\",\"cron_expr\":\"0 9 * * 1-5\",\"timezone\":\"America/New_York\"}",""},
		{"{\"mode\":\"interval\",\"interval_s\":60}",""},
		{"{\"mode\":\"interval\",\"interval_s\":31536000}",""},
		{"{\"mode\":\"once\",\"run_at\":\"2020-01-01T12:00:00+05:30\"}",""},
		{"{\"mode\":\"once\",\"run_at\":\"2020-01-01T12:00:00Z\",\"blackout_dates\":[\"2026-02-28\"],\"active_from\":\"2025-01-01T00:00:00Z\",\"active_until\":\"2027-01-01T00:00:00Z\"}",""},
		{"{}","invalid_schedule_mode"},
		{"{\"mode\":\"bad\"}","invalid_schedule_mode"},
		{"{\"mode\":1}","invalid_schedule_mode"},
		{"{\"mode\":\"cron\",\"cron_expr\":\"bad\"}","invalid_cron"},
		{"{\"mode\":\"cron\",\"cron_expr\":\"0 0 * * *\",\"timezone\":\"Bad/Zone\"}","invalid_timezone"},
		{"{\"mode\":\"interval\",\"interval_s\":59}","invalid_interval"},
		{"{\"mode\":\"interval\",\"interval_s\":31536001}","invalid_interval"},
		{"{\"mode\":\"interval\",\"interval_s\":60.5}","invalid_interval"},
		{"{\"mode\":\"interval\",\"interval_s\":\"60\"}","invalid_interval"},
		{"{\"mode\":\"once\",\"run_at\":\"bad\"}","invalid_run_at"},
		{"{\"mode\":\"once\",\"run_at\":\"2020-01-01T00:00:00Z\",\"blackout_dates\":[\"2026-02-30\"]}","invalid_blackout_dates"},
		{"{\"mode\":\"interval\",\"interval_s\":60,\"active_from\":\"2027-01-01T00:00:00Z\",\"active_until\":\"2025-01-01T00:00:00Z\"}","invalid_active_window"},
		{"{\"mode\":\"interval\",\"interval_s\":60,\"extra\":true}","invalid_config"},
	}
	for tc in cases do compile_case(t,"schedule",tc.config,tc.code,"ev.owner.sched.trg_a")
}
@(test)
test_event_compile_table :: proc(t:^testing.T) {actions_track(t,event_compile_cases)}
event_compile_cases :: proc(t:^testing.T) {
	service_case(t,service_foreign_chain)
	compile_case(t,"event","{\"event_type\":\"chain.state\",\"filter\":{\"all\":[{\"field\":\"data.state\",\"op\":\"eq\",\"value\":\"completed\"}]}}","","ev.owner.chain.*.state")
	compile_case(t,"event","{\"event_type\":\"chain.work_finished\",\"entity_id\":\"chain_a\",\"filter\":{\"all\":[{\"field\":\"data.outcome\",\"op\":\"eq\",\"value\":\"done\"}]}}","","ev.owner.chain.chain_a.work_finished")
	compile_case(t,"event","{\"event_type\":\"unknown\"}","unknown_event_type","")
	compile_case(t,"event","{\"event_type\":\"chain.state\",\"filter\":{\"all\":[{\"field\":\"data.wrong\",\"op\":\"eq\",\"value\":\"x\"}]}}","unknown_field","")
	compile_case(t,"event","{\"event_type\":\"chain.state\",\"entity_id\":\"a.b\"}","unknown_entity","")
	compile_case(t,"event","{\"event_type\":\"chain.state\",\"extra\":true}","invalid_config","")
}
@(test)
test_schedule_definition_row :: proc(t:^testing.T) {actions_track(t,schedule_row_cases)}
schedule_row_cases :: proc(t:^testing.T) {
	cases:=[?]struct{config,expression,zone:string}{
		{"{\"mode\":\"cron\",\"cron_expr\":\"0 9 * * *\",\"timezone\":\"America/New_York\"}","0 0 9 * * *","America/New_York"},
		{"{\"mode\":\"cron\",\"cron_expr\":\"0 9 * * *\",\"timezone\":\"UTC\"}","0 0 9 * * *",""},
		{"{\"mode\":\"interval\",\"interval_s\":60}","@every 60s",""},
		{"{\"mode\":\"once\",\"run_at\":\"2020-01-01T12:00:00+05:30\"}","@at 2020-01-01T06:30:00Z",""},
	}
	for tc in cases do schedule_row_case(t,tc.config,tc.expression,tc.zone)
}
schedule_row_case :: proc(t:^testing.T,config,expression,zone:string) {
	ids:=platform.real_id_generator()
	clock:=platform.real_clock()
	sc:=Sync_Context{clock=&clock,ids=&ids}
	trg:=domain.Action_Trigger{trigger_id="trg_a",action_id="act_a",owner_user_id="owner",config_json=config,rev=2,enabled=true}
	row,err:=schedule_definition_row(&sc,trg)
	defer domain.event_outbox_row_destroy(&row)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	testing.expect_value(t,row.subject,"sched.def.trg_a")
	headers_value,body_value:json.Value
	testing.expect(t,json.unmarshal(transmute([]u8)row.headers_json,&headers_value)==nil)
	defer json.destroy_value(headers_value)
	testing.expect(t,json.unmarshal(transmute([]u8)row.envelope_json,&body_value)==nil)
	defer json.destroy_value(body_value)
	headers,_:=headers_value.(json.Object)
	body,_:=body_value.(json.Object)
	expected:=[?]struct{key,value:string}{
		{"Nats-Schedule",expression},{"Nats-Schedule-Target","ev.owner.sched.trg_a"},
		{"Nats-TTL","never"},{"Nats-Schedule-TTL","24h"},{"Heim-Trigger-Rev","2"},
	}
	for item in expected {
		got,_:=headers[item.key].(string)
		testing.expect_value(t,got,item.value)
	}
	zone_value,has_zone:=headers["Nats-Schedule-Time-Zone"]
	testing.expect_value(t,has_zone,zone!="")
	if has_zone {got,_:=zone_value.(string);testing.expect_value(t,got,zone)}
	event_id,_:=body["event_id"].(string)
	testing.expect_value(t,event_id,row.event_id)
	data,_:=body["data"].(json.Object)
	rev,_:=data["rev"].(json.Integer)
	testing.expect_value(t,rev,json.Integer(2))
}
@(test)
test_schedule_rows_carry_fire_ttl :: proc(t:^testing.T) {actions_track(t,fire_ttl_case)}
fire_ttl_case :: proc(t:^testing.T) {
	schedule_row_case(t,"{\"mode\":\"interval\",\"interval_s\":60}","@every 60s","")
	ids:=platform.real_id_generator(); clock:=platform.real_clock()
	sc:=Sync_Context{clock=&clock,ids=&ids}
	row,err:=deferral_row(&sc,"owner","act_a","run_a","2026-01-01T00:00:00Z")
	defer domain.event_outbox_row_destroy(&row)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	value:json.Value
	testing.expect(t,json.unmarshal(transmute([]u8)row.headers_json,&value)==nil)
	defer json.destroy_value(value)
	headers,_:=value.(json.Object)
	ttl,_:=headers["Nats-Schedule-TTL"].(string)
	testing.expect_value(t,ttl,"24h")
	_,has_ttl:=headers["Nats-TTL"]
	testing.expect(t,!has_ttl)
}
@(test)
test_reconcile_plan_table :: proc(t:^testing.T) {actions_track(t,reconcile_cases)}
reconcile_cases :: proc(t:^testing.T) {
	reconcile_scale_cases(t)
	triggers:=[?]domain.Action_Trigger{{trigger_id="missing",rev=1},{trigger_id="stale",rev=2},{trigger_id="same",rev=1}}
	stored:=[?]Stored_Definition{{"sched.def.stale","stale",1},{"sched.def.same","same",1},{"sched.def.orphan","orphan",1}}
	ops:=reconcile_plan(stored[:],triggers[:],context.allocator)
	defer reconcile_ops_destroy(ops)
	testing.expect_value(t,len(ops),3)
	if len(ops)!=3 do return
	testing.expect(t,ops[0].publish && ops[0].trigger==&triggers[0])
	testing.expect(t,ops[1].publish && ops[1].trigger==&triggers[1])
	testing.expect(t,!ops[2].publish && ops[2].purge_subject=="sched.def.orphan")
}
@(test)
test_match_key_derivation :: proc(t:^testing.T) {actions_track(t,match_key_cases)}
match_key_cases :: proc(t:^testing.T) {
	service_case(t,service_match_keys)
	testing.expect_value(t,match_key("ev.owner.sched.trg_a"),"ev.owner.sched.trg_a")
	testing.expect_value(t,match_key("ev.owner.chain.chain_a.state"),"ev.owner.chain.chain_a.state")
	testing.expect_value(t,match_key("ev.owner.chain.*.state"),"")
}


reconcile_scale_cases :: proc(t: ^testing.T) {
	count :: 2000
	triggers := make([]domain.Action_Trigger, count)
	defer domain.action_triggers_destroy(triggers)
	stored := make([]Stored_Definition, count)
	defer {
		for definition in stored { delete(definition.subject); delete(definition.trigger_id) }
		delete(stored)
	}
	for &trigger, i in triggers {
		id := fmt.tprintf("trigger_%d", i)
		trigger.trigger_id = strings.clone(id)
		trigger.rev = 2
	}
	for &definition, i in stored {
		id := triggers[i].trigger_id if i < 1500 else fmt.tprintf("orphan_%d", i)
		definition = {subject=strings.clone(fmt.tprintf("sched.def.%s", id)), trigger_id=strings.clone(id), rev=2}
		if i == 10 do definition.rev = 1
	}
	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_track, context.allocator)
	defer mem.tracking_allocator_destroy(&temp_track)
	context.temp_allocator = mem.tracking_allocator(&temp_track)
	ops := reconcile_plan(stored, triggers, context.allocator)
	defer reconcile_ops_destroy(ops)
	// One stale definition, 500 missing definitions and 500 orphans.
	if !testing.expect_value(t, len(ops), 1001) do return
	testing.expect(t, ops[0].publish && ops[0].trigger == &triggers[10])
	for i in 0..<500 {
		testing.expect(t, ops[i+1].publish && ops[i+1].trigger == &triggers[i+1500])
		testing.expect(t, !ops[i+501].publish && ops[i+501].purge_subject == stored[i+1500].subject)
	}
	testing.expect_value(t, len(temp_track.allocation_map), 0)
	testing.expect_value(t, temp_track.total_allocation_count, i64(0))
}
