package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

@(test)
test_catalog_reconnect_pages_tenants_expiry_and_metrics :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	catalog_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}
catalog_scenario :: proc(t: ^testing.T) {
	server, started := natstest.start(); defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	conn, ne := nats.connect({url=server.url, timeout_ms=1000})
	if !testing.expect_value(t, ne.status, i32(0)) do return
	defer nats.destroy(conn)
	_, ne = nats.stream_add(conn, eventrelay.stream_config())
	if !testing.expect_value(t, ne.status, i32(0)) do return
	service := Service{options={url=server.url,timeout_ms=1000}}
	baseline, err := catalog_replay(&service,"alice","chain_1","")
	if !testing.expect(t, err.code==.None) do return
	defer catalog_page_destroy(&baseline)
	testing.expect_value(t, baseline.catalog_cursor, "0")
	// Disconnect: publish mixed tenants/chains and a non-catalog DLQ envelope.
	for row, i in ([][3]string{
		{"alice","chain_1","task.state"}, {"bob","chain_1","task.state"},
		{"alice","chain_2","task.state"}, {"alice","chain_1","task.review_verdict"},
	}) {
		encoded,_ := json.marshal(struct{event_id,owner_user_id,chain_id,type:string}{fmt.tprintf("event_%d",i),row[0],row[1],row[2]})
		_, pe := nats.publish(conn,fmt.tprintf("ev.%s.chain.%s.task.task_1.%s",row[0],row[1],row[2]),encoded)
		delete(encoded)
		testing.expect_value(t,pe.status,i32(0))
	}
	page, page_err := catalog_replay(&service,"alice","chain_1",baseline.catalog_cursor,1)
	if !testing.expect(t,page_err.code==.None) do return
	defer catalog_page_destroy(&page)
	testing.expect_value(t,len(page.events),1)
	testing.expect(t,page.has_more)
	resumed, resumed_err := catalog_replay(&service,"alice","chain_1",page.catalog_cursor,50)
	defer catalog_page_destroy(&resumed)
	testing.expect(t,resumed_err.code==.None && len(resumed.events)==1 && !resumed.has_more)
	testing.expect_value(t,resumed.catalog_cursor,"4")
	expired, expired_err := catalog_replay(&service,"alice","chain_1","999")
	defer catalog_page_destroy(&expired)
	testing.expect(t,expired_err.code==.None && expired.cursor_expired && len(expired.events)==0)
	testing.expect_value(t,expired.catalog_cursor,"4")
	for invalid in ([]string{"-1"," 1","+1","1.0","18446744073709551616"}) {
		rejected, re := catalog_replay(&service,"alice","chain_1",invalid)
		catalog_page_destroy(&rejected)
		testing.expect(t,re.code==.Validation_Failed)
	}
	db, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t,opened) do return
	defer sqlite.close(&db)
	migrated,_ := sqlite.run_migrations(&db)
	if !testing.expect(t,migrated) do return
	si: sqlite.Event_Subscription_Repo_SQLite
	oi: sqlite.Event_Outbox_Repo_SQLite
	repos := iface.Repositories{event_subscriptions=sqlite.new_event_subscription_repository(&si,&db),event_outbox=sqlite.new_event_outbox_repository(&oi,&db)}
	fi: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&fi,&db,&repos)
	service.factory = &factory
	uow,began,_ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t,began) do return
	for owner in ([]string{"alice","bob"}) {
		testing.expect_value(t,repos.event_subscriptions.put(repos.event_subscriptions.ctx,{subscription_id=fmt.tprintf("sub_%s",owner),owner_user_id=owner,subscriber_agent_id="agt_1",chain_id="chain_1",source="explicit",consumer_name=fmt.tprintf("sub_%s",owner),filter_subjects="[]",wake_policy="catalog",created_at="now"}).code,domain.Error_Code.None)
		testing.expect_value(t,repos.event_outbox.append(repos.event_outbox.ctx,{event_id=fmt.tprintf("pending_%s",owner),owner_user_id=owner,subject="ev.test",envelope_json="{}",headers_json="{}",created_at="now"}).code,domain.Error_Code.None)
	}
	committed,_ := iface.unit_of_work_commit(&uow)
	testing.expect(t,committed)
	testing.expect_value(t,nats.consumer_add(conn,{stream="HEIM_EVENTS",durable="sub_alice",filter_subjects=[]string{"ev.alice.chain.>"},ack_wait_ns=i64(10*time.Millisecond),max_deliver=10}).status,i32(0))
	pull, pe := nats.pull_bind(conn,"HEIM_EVENTS","sub_alice")
	testing.expect_value(t,pe.status,i32(0))
	defer nats.pull_destroy(pull)
	batch, fe := nats.fetch(pull,1,1000)
	testing.expect_value(t,fe.status,i32(0))
	nats.batch_destroy(batch)
	time.sleep(30*time.Millisecond)
	batch, fe = nats.fetch(pull,1,1000)
	testing.expect_value(t,fe.status,i32(0))
	nats.batch_destroy(batch)
	for owner in ([]string{"alice","bob"}) {
		_,de := nats.publish(conn,fmt.tprintf("ev.dlq.%s.chain.chain_1.task.task_1.state",owner),transmute([]byte)string("{}"))
		testing.expect_value(t,de.status,i32(0))
	}
	record_notice(&service,"alice",false); record_notice(&service,"alice",true)
	record_notice(&service,"bob",false); record_notice(&service,"bob",false)
	defer counters_destroy(&service)
	result, me := metrics(&service,"alice")
	defer metrics_destroy(&result)
	testing.expect(t,me.code==.None)
	testing.expect_value(t,len(result.subscriptions),1)
	if len(result.subscriptions)==1 {
		testing.expect_value(t,result.subscriptions[0].subscription_id,"sub_alice")
		testing.expect(t,result.subscriptions[0].available && result.subscriptions[0].consumer_lag>0)
	}
	testing.expect(t,result.redeliveries>0)
	testing.expect_value(t,result.outbox_backlog,i64(1))
	testing.expect_value(t,result.dlq_count,u64(1))
	testing.expect_value(t,result.nudges_sent,u64(1))
	testing.expect_value(t,result.wakes_sent,u64(1))
	// A stream-wide rollup advances first_seq deterministically, exercising the
	// same cursor-expiry condition as age retention without a timing race.
	_,roll_err:=nats.publish(conn,"ev.alice.chain.chain_1.state",transmute([]byte)string("{}"),"",[]nats.Header{{"Nats-Rollup","all"}})
	testing.expect_value(t,roll_err.status,i32(0))
	old,old_err:=catalog_replay(&service,"alice","chain_1","0")
	defer catalog_page_destroy(&old)
	testing.expect(t,old_err.code==.None && old.cursor_expired && len(old.events)==0,"expired retention requires a full refresh even for cursor zero")

	state,ie:=nats.stream_info(conn,"HEIM_EVENTS")
	testing.expect_value(t,ie.status,i32(0))
	edge:=fmt.aprintf("%d",state.first-1)
	boundary,boundary_err:=catalog_read(conn,"alice","chain_1",edge)
	delete(edge)
	testing.expect(t,boundary_err.code==.None && !boundary.cursor_expired,"first-1 is fully resumable")
	catalog_page_destroy(&boundary)
	// More than the old global scan cap of another tenant's traffic must require
	// only a subject-filtered read, not one API call per shared stream position.
	checkpoint:=fmt.aprintf("%d",state.last)
	defer delete(checkpoint)
	for _ in 0..<1200 {
		_,other_err:=nats.publish(conn,"ev.bob.chain.chain_1.state",transmute([]byte)string("{}"))
		testing.expect_value(t,other_err.status,i32(0))
	}
	_,bad_err:=nats.publish(conn,"ev.alice.chain.chain_1.state",transmute([]byte)string(`{"partial":[`))
	testing.expect_value(t,bad_err.status,i32(0))
	_,good_err:=nats.publish(conn,"ev.alice.chain.chain_1.state",transmute([]byte)string(`{"owner_user_id":"alice","chain_id":"chain_1","type":"chain.state"}`))
	testing.expect_value(t,good_err.status,i32(0))
	api_before,_,_:=nats.api_stats(conn)
	sparse,sparse_err:=catalog_read(conn,"alice","chain_1",checkpoint)
	defer catalog_page_destroy(&sparse)
	absent,absent_err:=catalog_read(conn,"carol","chain_1",checkpoint)
	testing.expect(t,absent_err.code==.None && len(absent.events)==0 && !absent.has_more,"no matching subject returns an empty page")
	catalog_page_destroy(&absent)
	api_after,_,_:=nats.api_stats(conn)
	testing.expect(t,sparse_err.code==.None && len(sparse.events)==1 && !sparse.has_more)
	testing.expect(t,api_after-api_before<=8,"replay cost does not scale with foreign tenant traffic")

}
