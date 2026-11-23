package actions

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_reconcile_real_server :: proc(t:^testing.T) {
	actions_track(t,reconcile_real_tracked)
	testing.expect_value(t,nats.shutdown(5000).status,i32(0))
}
reconcile_real_tracked :: proc(t:^testing.T) {service_case(t,reconcile_real_scenario)}
publish_test_row :: proc(t:^testing.T,conn:^nats.Connection,row:domain.Event_Outbox_Row) -> u64 {
	value:json.Value
	if !testing.expect(t,json.unmarshal(transmute([]u8)row.headers_json,&value)==nil) do return 0
	defer json.destroy_value(value)
	obj,_:=value.(json.Object)
	headers:=make([]nats.Header,len(obj))
	defer delete(headers)
	i:=0
	for key,entry in obj {
		text,_:=entry.(string)
		headers[i]={key=key,value=text}
		i+=1
	}
	_,purge_err:=nats.stream_purge_subject(conn,"HEIM_EVENTS",row.subject)
	testing.expect_value(t,purge_err.status,i32(0))
	ack,err:=nats.publish(conn,row.subject,transmute([]u8)row.envelope_json,headers=headers)
	testing.expect_value(t,err.status,i32(0))
	return ack.sequence
}
reconcile_real_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
	server,started:=natstest.start()
	defer natstest.destroy(&server)
	if !testing.expect(t,started) do return
	conn,nerr:=nats.connect({url=server.url,timeout_ms=1000})
	if !testing.expect_value(t,nerr.status,i32(0)) do return
	defer nats.destroy(conn)
	_,stream_err:=nats.stream_add(conn,{name="HEIM_EVENTS",subjects={"ev.>","sched.def.>"},replicas=1,allow_direct=true,allow_msg_schedules=true,allow_msg_ttl=true})
	if !testing.expect_value(t,stream_err.status,i32(0)) do return
	input:=test_input()
	input.triggers=[]Trigger_Input{
		{kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":600}")},
		{kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":700}")},
		{kind="schedule",config=test_config("{\"mode\":\"interval\",\"interval_s\":800}")},
	}
	v,err:=create(s,"owner",input)
	defer action_view_destroy(&v)
	if !testing.expect_value(t,err.code,domain.Error_Code.None) do return
	// Simulate delivery of two definitions; one has an obsolete revision.
	sc:=Sync_Context{clock=s.clock,ids=s.ids}
	matching,row_err:=schedule_definition_row(&sc,v.triggers[0])
	defer domain.event_outbox_row_destroy(&matching)
	testing.expect_value(t,row_err.code,domain.Error_Code.None)
	matching_sequence:=publish_test_row(t,conn,matching)
	stale:=v.triggers[1]
	stale.rev=99
	stale_row,stale_err:=schedule_definition_row(&sc,stale)
	defer domain.event_outbox_row_destroy(&stale_row)
	testing.expect_value(t,stale_err.code,domain.Error_Code.None)
	stale_sequence:=publish_test_row(t,conn,stale_row)
	orphan:=v.triggers[2]
	orphan.trigger_id="orphan"
	orphan_row,orphan_err:=schedule_definition_row(&sc,orphan)
	defer domain.event_outbox_row_destroy(&orphan_row)
	testing.expect_value(t,orphan_err.code,domain.Error_Code.None)
	_ = publish_test_row(t,conn,orphan_row)
	// This emulates the relay having consumed the original create rows.
	testing.expect(t,sqlite.exec(db,"DELETE FROM event_outbox;"))
	done,reconcile_err:=reconcile(s,conn)
	testing.expect(t,done)
	testing.expect_value(t,reconcile_err.code,domain.Error_Code.None)
	expect_pending(t,s,3)
	// Inspect and apply the actual rows produced by reconcile outside the UoW.
	definitions,purges:=0,0
	for {
		uow,ok,_:=iface.unit_of_work_begin(s.factory)
		if !testing.expect(t,ok) do return
		row,found,next_err:=uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
		iface.unit_of_work_rollback(&uow)
		if !testing.expect_value(t,next_err.code,domain.Error_Code.None) do return
		if !found {domain.event_outbox_row_destroy(&row);break}
		if row.subject=="sched.def.orphan" {
			purges+=1
			_,purge_err:=nats.stream_purge_subject(conn,"HEIM_EVENTS",row.subject)
			testing.expect_value(t,purge_err.status,i32(0))
		} else {
			definitions+=1
			_ = publish_test_row(t,conn,row)
		}
		mark,mark_ok,_:=iface.unit_of_work_begin(s.factory)
		if !testing.expect(t,mark_ok) {domain.event_outbox_row_destroy(&row);return}
		mark_err:=mark.repos.event_outbox.mark_published(mark.repos.event_outbox.ctx,row.outbox_seq,"2026-11-23T00:00:00Z")
		testing.expect_value(t,mark_err.code,domain.Error_Code.None)
		_,commit_err:=iface.unit_of_work_commit(&mark)
		testing.expect_value(t,commit_err.code,domain.Error_Code.None)
		domain.event_outbox_row_destroy(&row)
	}
	testing.expect_value(t,definitions,2)
	testing.expect_value(t,purges,1)
	for trigger,i in v.triggers {
		subject:=fmt.tprintf("sched.def.%s",trigger.trigger_id)
		msg,seq,read_err:=nats.stream_next(conn,"HEIM_EVENTS",subject,1)
		testing.expect_value(t,read_err.status,i32(0))
		if msg!=nil do nats.message_destroy(msg)
		if i==0 do testing.expect_value(t,seq,matching_sequence)
		if i==1 do testing.expect(t,seq>stale_sequence)
	}
	orphan_msg,_,orphan_read_err:=nats.stream_next(conn,"HEIM_EVENTS","sched.def.orphan",1)
	if orphan_msg!=nil do nats.message_destroy(orphan_msg)
	testing.expect_value(t,orphan_read_err.status,i32(13))
	done_again,again_err:=reconcile(s,conn)
	testing.expect(t,done_again)
	testing.expect_value(t,again_err.code,domain.Error_Code.None)
	expect_pending(t,s,0)
}
