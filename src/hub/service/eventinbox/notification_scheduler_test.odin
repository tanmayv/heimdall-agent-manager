package eventinbox

import "core:fmt"
import "core:encoding/json"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"


@(test)
test_notification_scheduler_publish_external_deadline_reconnect :: proc(t: ^testing.T) {
	notification_scheduler_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
}
notification_scheduler_scenario :: proc(t: ^testing.T) {
	server, started := natstest.start()
	defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	conn, ne := nats.connect({url=server.url, timeout_ms=1000})
	if !testing.expect_value(t, ne.status, i32(0)) do return
	defer nats.destroy(conn)
	_, ne = nats.stream_add(conn, eventrelay.stream_config())
	if !testing.expect_value(t, ne.status, i32(0)) do return
	db, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&db)
	migrated, _ := sqlite.run_migrations(&db)
	if !testing.expect(t, migrated) do return
	out_impl: sqlite.Event_Outbox_Repo_SQLite
	impl: sqlite.Event_Subscription_Repo_SQLite
	repos := iface.Repositories{event_subscriptions=sqlite.new_event_subscription_repository(&impl, &db),event_outbox=sqlite.new_event_outbox_repository(&out_impl,&db)}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &db, &repos)
	service := Service{factory=&factory, ack_wait=2*time.Second, options={url=server.url, timeout_ms=1000}, notice=notification_record_dispatch}
	r := Runtime{service=&service}
	defer runtime_disconnect(&r)
	defer clear_notifications(&r)
	defer clear_notice_dirty(&service)
	defer counters_destroy(&service)
	defer provisioned_destroy(&service)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	for i in 0..<2 {
		id := fmt.tprintf("inbox_audit_%d", i)
		testing.expect(t, sqlite.exec(&db, fmt.tprintf("INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('%s','alice','audit','bridge','running','idle','now','now');", id)))
		err := repos.event_subscriptions.put(repos.event_subscriptions.ctx, {subscription_id=id,owner_user_id="alice",subscriber_instance_id=id,chain_id="audit",source="explicit",filter_subjects=`["ev.alice.chain.audit.>"]`,consumer_name=id,created_at="now"})
		testing.expect_value(t, err.code, domain.Error_Code.None)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	if !testing.expect(t, committed) do return
	if !testing.expect(t, reconcile(&r)) do return
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	rows, re := uow.repos.event_subscriptions.all(uow.repos.event_subscriptions.ctx)
	iface.unit_of_work_rollback(&uow)
	testing.expect_value(t, re.code, domain.Error_Code.None)
	defer subscription_rows_destroy(rows)

	recorder := Isolation_Recorder{t=t}
	defer delete(recorder.notices)
	service.notice_process = notice_test_process
	service.notice = isolation_record
	service.notice_ctx = &recorder
	now := time.tick_now()
	// The initial empty scan is cached; unrelated tenant/chain signals do not
	// turn all subscriptions dirty.
	published(&service, "ev.bob.chain.audit.state")
	published(&service, "ev.alice.chain.other.state")
	before, _, _ := nats.api_stats(conn)
	testing.expect(t, notify_pending(&r, rows, now))
	after, _, _ := nats.api_stats(conn)
	testing.expect(t, after-before <= 1, "unrelated publications do not poll consumers")

	subject :: "ev.alice.chain.audit.task.task_1.review_verdict"
	// Enqueueing is not publication. The relay must signal only after NATS
	// accepts the event, and outside the SQL transaction.
	uow, began, _ = iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect_value(t, repos.event_outbox.append(repos.event_outbox.ctx, {
		event_id="relay_event",owner_user_id="alice",subject=subject,
		envelope_json=`{"event_id":"relay_event","owner_user_id":"alice","entity":{"kind":"task","id":"task_1"},"data":{"chain_id":"audit"},"type":"task.review_verdict"}`,
		headers_json="{}",created_at="now",
	}).code, domain.Error_Code.None)
	iface.unit_of_work_commit(&uow)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 0)
	relay := eventrelay.Service{factory=&factory,options=service.options,
		published_ctx=&service,published=proc(ctx: rawptr, subject: string) {
			service := (^Service)(ctx)
			uow, began, _ := iface.unit_of_work_begin(service.factory)
			assert(began, "post-publish callback must run outside SQL")
			iface.unit_of_work_rollback(&uow)
			published(service, subject)
		}}
	defer nats.destroy(relay.connection)
	ok, progress := eventrelay.step(&relay)
	testing.expect(t, ok && progress)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 2)

	for row in rows {
		events, err := next(&service,"alice",row.subscriber_instance_id,0,10)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, len(events), 1)
		values_destroy(events)
		testing.expect_value(t, acknowledge(&service,"alice",row.subscriber_instance_id,[]string{"relay_event"}).code, domain.Error_Code.None)
	}
	now._nsec += i64(31*time.Second)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 2)

	// A direct external publisher has no relay callback. A quiet consumer is
	// discovered by the bounded fallback, including retained rollup traffic.
	scheduler_publish(t, conn, subject, "external")
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 2)
	now._nsec += i64(NOTICE_RECONCILE_INTERVAL)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 4)

	// Observe a new delivery receipt, then schedule its actual AckWait
	// deadline instead of waiting for the five-minute external scan.
	for row in rows {
		events, err := next(&service,"alice",row.subscriber_instance_id,0,10)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, len(events), 1)
		values_destroy(events)
	}
	now._nsec += i64(31*time.Second)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 4)
	for row in rows {
		state := r.notifications[fmt.tprintf("schedule:%s",row.consumer_name)]
		testing.expect(t, state.next_check._nsec-now._nsec <= i64(3*time.Second), "receipt schedules the redelivery deadline")
	}
	time.sleep(3100*time.Millisecond)
	now._nsec += i64(4*time.Second)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 6)
	for row in rows {
		testing.expect_value(t, acknowledge(&service,"alice",row.subscriber_instance_id,[]string{"external"}).code, domain.Error_Code.None)
	}
	now._nsec += i64(31*time.Second)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 6)

	// Connection loss invalidates the scan schedule; an external event
	// published during the gap is found immediately after reconnection.
	runtime_disconnect(&r)
	scheduler_publish(t, conn, subject, "during_disconnect")
	testing.expect(t, runtime_connect(&r))
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 8)

	// Dirty events arriving during cooldown survive until it expires.
	scheduler_publish(t, conn, subject, "cooldown")
	published(&service, subject)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 8)
	now._nsec += i64(30*time.Second)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 10)
	for row in rows {
		events, err := next(&service,"alice",row.subscriber_instance_id,0,10)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		values_destroy(events)
		testing.expect_value(t, acknowledge(&service,"alice",row.subscriber_instance_id,[]string{"during_disconnect","cooldown"}).code, domain.Error_Code.None)
	}
	now._nsec += i64(31*time.Second)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect(t, sqlite.exec(&db,"UPDATE agent_instances SET activity_status='busy';"))
	scheduler_publish(t, conn, subject, "while_busy")
	published(&service, subject)
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 10)
	testing.expect(t, sqlite.exec(&db,"UPDATE agent_instances SET activity_status='idle';"))
	testing.expect(t, notify_pending(&r, rows, now))
	testing.expect_value(t, len(recorder.notices), 12)

	// Cursors for bounded scans survive skipped/deferred passes.
	key := fmt.tprintf("scan:%s/%s",rows[0].consumer_name,"ev.alice.chain.audit.>")
	save_notification_state(&r,key,{cursor=999})
	testing.expect(t, notify_pending(&r,rows,now))
	testing.expect_value(t,r.notifications[key].cursor,u64(999))
	save_notification_state(&r,key,{cursor=0})
	// Rejected dispatch uses five seconds, independently of the 30-second
	// pending deadline. Dirty state must survive the backoff.
	now._nsec += i64(31*time.Second)
	recorder.reject = true
	published(&service, subject)
	testing.expect(t, notify_pending(&r,rows,now))
	testing.expect_value(t,len(recorder.notices),12)
	recorder.reject = false
	now._nsec += i64(5*time.Second)
	testing.expect(t, notify_pending(&r,rows,now))
	testing.expect_value(t,len(recorder.notices),14)
	testing.expect(t, sqlite.exec(&db,"DELETE FROM event_subscriptions;"))
	testing.expect(t, notify_pending(&r,nil,now))
	testing.expect_value(t,len(r.notifications),0)
}
scheduler_publish :: proc(t: ^testing.T, conn: ^nats.Connection, subject, id: string) {
	data, encode_err := json.marshal(inbox_v2(id,"task.review_verdict","alice","audit","task_1"))
	if !testing.expect(t, encode_err == nil) do return
	defer delete(data)
	_, err := nats.publish(conn, subject, data, id)
	testing.expect_value(t, err.status, i32(0))
}

@(test)
test_notification_dirty_overflow_is_bounded :: proc(t: ^testing.T) {
	service: Service
	defer clear_notice_dirty(&service)
	for i in 0..<5000 do published(&service, fmt.tprintf("ev.alice.chain.chain_%d.state",i))
	testing.expect_value(t, len(service.notice_dirty.chains),4096)
	testing.expect(t, service.notice_dirty.all)
	dirty, all := take_notice_dirty(&service)
	defer destroy_notice_dirty(dirty)
	testing.expect(t, all)
	testing.expect_value(t, len(dirty),4096)
	testing.expect_value(t, len(service.notice_dirty.chains),0)
}
