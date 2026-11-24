package eventinbox

import "core:fmt"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

// Audit reproducer: excludes provisioning, counts management calls on an empty
// stream with eligible idle targets. No events or agent commands are produced.
@(test)
test_notification_idle_management_cost :: proc(t: ^testing.T) {
    notification_idle_management_cost(t)
    testing.expect_value(t, nats.shutdown(5000).status, i32(0))
}
notification_idle_management_cost :: proc(t: ^testing.T) {
    count :: #config(AUDIT_NOTIFICATION_CONSUMERS, 8)
    passes :: #config(AUDIT_NOTIFICATION_PASSES, 3)
    pause_ms :: #config(AUDIT_NOTIFICATION_PAUSE_MS, 0)
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
    impl: sqlite.Event_Subscription_Repo_SQLite
    repos := iface.Repositories{event_subscriptions=sqlite.new_event_subscription_repository(&impl, &db)}
    factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
    factory := sqlite.new_unit_of_work_factory(&factory_impl, &db, &repos)
    service := Service{factory=&factory, options={url=server.url, timeout_ms=1000}, notice=notification_record_dispatch}
    r := Runtime{service=&service}
    defer runtime_disconnect(&r)
    defer clear_notifications(&r)
    defer provisioned_destroy(&service)
    uow, began, _ := iface.unit_of_work_begin(&factory)
    if !testing.expect(t, began) do return
    for i in 0..<count {
        id := fmt.tprintf("inbox_audit_%d", i)
        testing.expect(t, sqlite.exec(&db, fmt.tprintf("INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,activity_status,created_at,updated_at) VALUES('%s','alice','audit','bridge','running','idle','now','now');", id)))
        err := repos.event_subscriptions.put(repos.event_subscriptions.ctx, {subscription_id=id,owner_user_id="alice",subscriber_instance_id=id,chain_id="audit",source="explicit",filter_subjects=`["ev.alice.chain.audit.state"]`,consumer_name=id,created_at="now"})
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
    before, _, be := nats.api_stats(conn)
    testing.expect_value(t, be.status, i32(0))
    started_at := time.tick_now()
    for _ in 0..<passes {
        testing.expect(t, notify_pending(&r, rows, time.tick_now()))
        if pause_ms > 0 do time.sleep(time.Duration(pause_ms)*time.Millisecond)
    }
    after, _, ae := nats.api_stats(conn)
    testing.expect_value(t, ae.status, i32(0))
    fmt.printf("notification idle cost: consumers=%d passes=%d elapsed_ms=%d management_requests=%d baseline_consumer_info=%d\n", count, passes, i64(time.tick_since(started_at)/time.Millisecond), after-before, count*passes)
    // Permit the planned reduction while guarding against extra repeated scans.
    testing.expect(t, after-before <= u64(1), "idle cost must be independent of pass count between full reconciliations")
}
