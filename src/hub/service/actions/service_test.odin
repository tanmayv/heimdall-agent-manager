package actions

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import "core:mem"

service_case :: proc(t: ^testing.T, scenario: proc(^testing.T, ^Service, ^sqlite.Conn)) {
	db, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&db)
	migrated, _ := sqlite.run_migrations(&db)
	if !testing.expect(t, migrated) do return
	testing.expect(t, sqlite.exec(&db, "PRAGMA foreign_keys=OFF;"))
	actions_impl: sqlite.Action_Repo_SQLite
	agents_impl: sqlite.Agent_Repo_SQLite
	outbox_impl: sqlite.Event_Outbox_Repo_SQLite
	chains_impl: sqlite.Taskchain_Repo_SQLite
	repos := iface.Repositories{
		actions=sqlite.new_action_repository(&actions_impl,&db),
		agents=sqlite.new_agent_repository(&agents_impl,&db),
		event_outbox=sqlite.new_event_outbox_repository(&outbox_impl,&db),
		taskchains=sqlite.new_taskchain_repository(&chains_impl,&db),
	}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl,&db,&repos)
	_, saved, save_err := repos.agents.save_instance(repos.agents.ctx, domain.Agent_Instance{agent_instance_id="inst_target",agent_id="agt_target",owner_user_id="owner",bridge_id="bridge",runtime_transport="pty"})
	if !testing.expect(t,saved && save_err.code==.None) do return
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := Service{factory=&factory,repos=&repos,clock=&clock,ids=&ids,target_kinds={"agent","instance"}}
	scenario(t,&service,&db)
}
test_config :: proc(text: string) -> json.Object {
	value: json.Value
	_ = json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)
	object,_ := value.(json.Object)
	return object
}
test_input :: proc() -> Action_Input {
	triggers := make([]Trigger_Input, 1, context.temp_allocator)
	triggers[0] = {kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":60}")}
	return {prompt_text=string("hello"),target=Target_Input{kind="instance",instance_id="inst_target"},triggers=triggers}
}
pending_count :: proc(t:^testing.T,s:^Service) -> i64 {
	uow,ok,_:=iface.unit_of_work_begin(s.factory)
	if !testing.expect(t,ok) do return -1
	defer iface.unit_of_work_rollback(&uow)
	count,err:=uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	return count
}
expect_pending :: proc(t:^testing.T,s:^Service,count:i64) {
	testing.expect_value(t,pending_count(t,s),count)
}
@(test)
test_one_outbox_row_per_schedule_save :: proc(t:^testing.T) {actions_track(t,service_outbox_tracked)}
service_outbox_tracked :: proc(t:^testing.T) {service_case(t,service_outbox_scenario)}
service_outbox_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	v,err:=create(s,"owner",test_input())
	defer action_view_destroy(&v)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	expect_pending(t,s,1)
	renamed,rename_err:=update(s,"owner",string(v.action.id),{name=string("renamed")})
	defer action_view_destroy(&renamed)
	testing.expect_value(t,rename_err.code,domain.Error_Code.None)
	expect_pending(t,s,1)
	changed,change_err:=update(s,"owner",string(v.action.id),{triggers=[]Trigger_Input{{id=v.triggers[0].trigger_id,kind="schedule",config=test_config("{\"interval_s\":120,\"mode\":\"interval\"}")}}})
	defer action_view_destroy(&changed)
	if !testing.expect_value(t,change_err.code,domain.Error_Code.None) do return
	testing.expect_value(t,changed.triggers[0].rev,2)
	expect_pending(t,s,2)
	// The same semantic object in another key order must not advance rev.
	same,same_err:=update(s,"owner",string(v.action.id),{triggers=[]Trigger_Input{{id=v.triggers[0].trigger_id,kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":120}")}}})
	defer action_view_destroy(&same)
	testing.expect_value(t,same_err.code,domain.Error_Code.None)
	testing.expect_value(t,same.triggers[0].rev,2)
	expect_pending(t,s,2)
	disabled,disable_err:=set_enabled(s,"owner",string(v.action.id),false)
	defer action_view_destroy(&disabled)
	testing.expect_value(t,disable_err.code,domain.Error_Code.None)
	expect_pending(t,s,3)
	enabled,enable_err:=set_enabled(s,"owner",string(v.action.id),true)
	defer action_view_destroy(&enabled)
	testing.expect_value(t,enable_err.code,domain.Error_Code.None)
	expect_pending(t,s,4)
	testing.expect_value(t,delete_action(s,"owner",string(v.action.id)).code,domain.Error_Code.None)
	expect_pending(t,s,5)
	missing,missing_err:=get(s,"owner",string(v.action.id))
	defer action_view_destroy(&missing)
	testing.expect_value(t,missing_err.code,domain.Error_Code.Not_Found)
}
@(test)
test_action_disable_purges_all_schedules :: proc(t:^testing.T) {actions_track(t,service_disable_tracked)}
service_disable_tracked :: proc(t:^testing.T) {service_case(t,service_disable_scenario)}
service_disable_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	input:=test_input()
	input.triggers=[]Trigger_Input{
		{kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":60}")},
		{kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":120}")},
		{kind="event",config=test_config("{\"event_type\":\"chain.state\"}")},
	}
	v,err:=create(s,"owner",input)
	defer action_view_destroy(&v)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	expect_pending(t,s,2)
	disabled,disable_err:=set_enabled(s,"owner",string(v.action.id),false)
	defer action_view_destroy(&disabled)
	testing.expect_value(t,disable_err.code,domain.Error_Code.None)
	if !testing.expect_value(t,len(disabled.triggers),3) do return
	for trigger in disabled.triggers do testing.expect_value(t,trigger.rev,2)
	expect_pending(t,s,4)
	// Deleting an already disabled action emits no redundant purge.
	testing.expect_value(t,delete_action(s,"owner",string(v.action.id)).code,domain.Error_Code.None)
	expect_pending(t,s,4)
}
@(test)
test_reconcile_waits_for_backlog :: proc(t:^testing.T) {actions_track(t,reconcile_backlog_tracked)}
reconcile_backlog_tracked :: proc(t:^testing.T) {service_case(t,reconcile_backlog_scenario)}
reconcile_backlog_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	v,err:=create(s,"owner",test_input())
	defer action_view_destroy(&v)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	// nil connection proves the backlog path never talks to NATS.
	done,reconcile_err:=reconcile(s,nil)
	testing.expect(t,!done)
	testing.expect_value(t,reconcile_err.code,domain.Error_Code.None)
	expect_pending(t,s,1)
}
fake_compile_calls, fake_change_calls: int
fake_compile :: proc(owner, action_id, trigger_id:string, config:json.Object, allocator: mem.Allocator) -> (Match_Spec,domain.Domain_Error) {
	fake_compile_calls+=1
	return {event_type=strings.clone("test.fired",allocator),subject_filter=strings.clone("ev.owner.test",allocator),data_filter_json=strings.clone("{}",allocator)},{}
}
fake_change :: proc(sc:^Sync_Context,before,after:^domain.Action_Trigger) -> domain.Domain_Error {
	fake_change_calls+=1
	return {}
}
@(test)
test_fake_trigger_kind :: proc(t:^testing.T) {actions_track(t,fake_kind_tracked)}
fake_kind_tracked :: proc(t:^testing.T) {service_case(t,fake_kind_scenario)}
fake_kind_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	fake_compile_calls=0
	fake_change_calls=0
	append(&extra_trigger_kinds,Trigger_Kind{kind="test_only",compile=fake_compile,on_change=fake_change})
	defer {delete(extra_trigger_kinds);extra_trigger_kinds=nil}
	input:=test_input()
	input.triggers=[]Trigger_Input{{kind="test_only",config=test_config("{}")}}
	v,err:=create(s,"owner",input)
	defer action_view_destroy(&v)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	testing.expect_value(t,fake_compile_calls,1)
	testing.expect_value(t,fake_change_calls,1)
	expect_pending(t,s,0)
}
@(test)
test_actions_service_kind_change_rolls_back :: proc(t:^testing.T) {actions_track(t,kind_change_tracked)}
kind_change_tracked :: proc(t:^testing.T) {service_case(t,kind_change_scenario)}
kind_change_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	v,err:=create(s,"owner",test_input())
	defer action_view_destroy(&v)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	bad,bad_err:=update(s,"owner",string(v.action.id),{name=string("must rollback"),triggers=[]Trigger_Input{{id=v.triggers[0].trigger_id,kind="event",config=test_config("{\"event_type\":\"chain.state\"}")}}})
	defer action_view_destroy(&bad)
	testing.expect(t,strings.contains(bad_err.details_json,"trigger_kind_immutable"))
	persisted,read_err:=get(s,"owner",string(v.action.id))
	defer action_view_destroy(&persisted)
	testing.expect_value(t,read_err.code,domain.Error_Code.None)
	testing.expect_value(t,persisted.action.name,v.action.name)
	testing.expect_value(t,persisted.triggers[0].rev,1)
	expect_pending(t,s,1)
	other,other_err:=get(s,"someone_else",string(v.action.id))
	defer action_view_destroy(&other)
	testing.expect_value(t,other_err.code,domain.Error_Code.Not_Found)
}

service_match_keys :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	for id in ([]string{"chain_first","chain_second"}) {
		_,saved,err:=iface.taskchain_save_chain(&s.repos.taskchains,domain.Task_Chain{chain_id=domain.Task_Chain_ID(id),owner_user_id="owner",title=id,kind=domain.CHAIN_KIND_MIXED_WORK,status=.Active})
		testing.expect(t,saved && err.code==.None)
	}
	input:=test_input()
	input.triggers=[]Trigger_Input{
		{kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":60}")},
		{kind="event",config=test_config("{\"event_type\":\"chain.state\",\"chain_id\":\"chain_first\"}")},
		{kind="event",config=test_config("{\"event_type\":\"chain.work_finished\"}")},
	}
	v,err:=create(s,"owner",input)
	defer action_view_destroy(&v)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	if !testing.expect_value(t,len(v.triggers),3) do return
	for trigger in v.triggers {
		if trigger.kind=="schedule" do testing.expect_value(t,trigger.match_key,trigger.subject_filter)
		if trigger.event_type=="chain.work_finished" do testing.expect_value(t,trigger.match_key,"")
		if trigger.event_type=="chain.state" {
			testing.expect_value(t,trigger.match_key,"ev.owner.chain.chain_first.state")
			updated,update_err:=update(s,"owner",string(v.action.id),{triggers=[]Trigger_Input{{id=trigger.trigger_id,kind="event",config=test_config("{\"event_type\":\"chain.state\",\"chain_id\":\"chain_second\"}")}}})
			defer action_view_destroy(&updated)
			if !testing.expect_value(t,update_err.code,domain.Error_Code.None) do return
			if !testing.expect_value(t,len(updated.triggers),1) do return
			testing.expect_value(t,updated.triggers[0].match_key,"ev.owner.chain.chain_second.state")
			stored,found,read_err:=s.repos.actions.trigger_get(s.repos.actions.ctx,trigger.trigger_id)
			defer domain.action_trigger_destroy(&stored)
			testing.expect(t,found && read_err.code==.None)
			testing.expect_value(t,stored.match_key,"ev.owner.chain.chain_second.state")
		}
	}
}
service_foreign_chain :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	_,saved,save_err:=iface.taskchain_save_chain(&s.repos.taskchains,domain.Task_Chain{chain_id="chain_foreign",owner_user_id="other",title="Other",kind=domain.CHAIN_KIND_MIXED_WORK,status=.Active})
	testing.expect(t,saved && save_err.code==.None)
	input:=test_input()
	input.triggers=[]Trigger_Input{{kind="event",config=test_config("{\"event_type\":\"chain.state\",\"chain_id\":\"chain_foreign\"}")}}
	v,err:=create(s,"owner",input)
	defer action_view_destroy(&v)
	testing.expect(t,strings.contains(err.details_json,"unknown_chain"),err.details_json)
	expect_pending(t,s,0)
}
