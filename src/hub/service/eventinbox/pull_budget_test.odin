package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventrelay "odin_test:hub/service/eventrelay"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

PULL_BUDGET_SUBSCRIPTIONS :: 55

// REQ-EVQ-1 and REQ-EVQ-4: an identity with 55 subscriptions. The first pull
// provisions each consumer once; later pulls provision nothing, skip idle
// consumers, stop at the limit and keep to the wait budget.
@(test)
test_event_inbox_pull_many_subscriptions_within_budget :: proc(t: ^testing.T) {
	server, started := natstest.start()
	defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	conn, nerr := nats.connect({url = server.url, timeout_ms = 1000})
	if !testing.expect_value(t, nerr.status, i32(0)) do return
	defer nats.destroy(conn)
	_, nerr = nats.stream_add(conn, eventrelay.stream_config())
	if !testing.expect_value(t, nerr.status, i32(0)) do return
	db, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&db)
	migrated, _ := sqlite.run_migrations(&db)
	if !testing.expect(t, migrated) do return
	sub_impl: sqlite.Event_Subscription_Repo_SQLite
	out_impl: sqlite.Event_Outbox_Repo_SQLite
	repos := iface.Repositories {
		event_subscriptions = sqlite.new_event_subscription_repository(&sub_impl, &db),
		event_outbox        = sqlite.new_event_outbox_repository(&out_impl, &db),
	}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &db, &repos)
	ids := platform.real_id_generator()
	service := Service {
		ids     = &ids,
		factory = &factory,
		options = {url = server.url, timeout_ms = 1000},
	}
	defer provisioned_destroy(&service)

	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	for i in 0 ..< PULL_BUDGET_SUBSCRIPTIONS {
		subjects, _ := filters("alice", fmt.tprintf("chain_%d", i), "", "coordinator")
		encoded, _ := json.marshal(subjects, allocator = context.temp_allocator)
		filters_destroy(subjects)
		id := fmt.tprintf("sub_many_%d", i)
		testing.expect_value(
			t,
			repos.event_subscriptions.put(repos.event_subscriptions.ctx, {subscription_id = id, owner_user_id = "alice", subscriber_agent_id = "agt_many", chain_id = fmt.tprintf("chain_%d", i), source = "role_default", filter_subjects = string(encoded), wake_policy = "catalog", consumer_name = id, created_at = "now"}).code,
			domain.Error_Code.None,
		)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	if !testing.expect(t, committed) do return

	// Cold pull: every consumer is provisioned exactly once, within the budget.
	began_cold := time.tick_now()
	events, err := next(&service, "alice", "agt_many", 0, 20)
	cold := time.tick_since(began_cold)
	testing.expect(t, err.code == .None && len(events) == 0, "cold pull over idle subscriptions is empty")
	values_destroy(events)
	testing.expectf(t, cold < NEXT_OVERHEAD_BUDGET + time.Second, "cold pull took %v", cold)
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS))
	testing.expect_value(t, len(service.provisioned.names), PULL_BUDGET_SUBSCRIPTIONS)

	// Warm idle pulls: no re-provisioning, and a long poll ends on time.
	for wait in ([]time.Duration{0, 300 * time.Millisecond}) {
		began_warm := time.tick_now()
		events, err = next(&service, "alice", "agt_many", wait, 20)
		elapsed := time.tick_since(began_warm)
		testing.expect(t, err.code == .None && len(events) == 0, "idle pull is empty")
		values_destroy(events)
		testing.expectf(t, elapsed >= wait && elapsed < wait + NEXT_OVERHEAD_BUDGET + time.Second, "wait %v took %v", wait, elapsed)
	}
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS))

	// Three subscriptions get work; a pull stops at its limit and the next pull
	// returns the rest, without provisioning anything again.
	for chain, i in ([]int{7, 20, 40}) {
		subject := fmt.tprintf("ev.alice.chain.chain_%d.task.task_1.review_verdict", chain)
		inbox_test_publish(t, conn, subject, fmt.tprintf("many_%d", i), "task.review_verdict", "", 0, "", false)
	}
	events, err = next(&service, "alice", "agt_many", 0, 2)
	testing.expect(t, err.code == .None && len(events) == 2, "pull stops at --limit")
	values_destroy(events)
	events, err = next(&service, "alice", "agt_many", 0, 20)
	testing.expectf(t, err.code == .None && len(events) == 1, "remaining event delivered: %v, count %d", err, len(events))
	values_destroy(events)
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS))

	// A long poll wakes for an event on a consumer that was idle when it began.
	Late :: struct {url: string, ok: bool}
	late := Late{url = server.url}
	worker := thread.create_and_start_with_poly_data(&late, proc(late: ^Late) {
		time.sleep(150 * time.Millisecond)
		publisher, perr := nats.connect({url = late.url, timeout_ms = 1000})
		if perr.status != 0 do return
		defer nats.destroy(publisher)
		data := `{"event_id":"late_1","type":"task.review_verdict","owner_user_id":"alice","chain_id":"chain_33","task_id":"task_1","topic_key":"","topic_generation":0}`
		_, pub_err := nats.publish(publisher, "ev.alice.chain.chain_33.task.task_1.review_verdict", transmute([]byte)string(data), "late_1")
		late.ok = pub_err.status == 0
	})
	began_poll := time.tick_now()
	events, err = next(&service, "alice", "agt_many", 5 * time.Second, 20)
	woke := time.tick_since(began_poll)
	thread.join(worker); thread.destroy(worker)
	testing.expect(t, late.ok, "late publish")
	testing.expectf(t, err.code == .None && len(events) == 1, "long poll returns the late event: %v, count %d", err, len(events))
	testing.expectf(t, woke < 2 * time.Second, "long poll woke after %v", woke)
	values_destroy(events)

	// A consumer lost behind the cache is provisioned once more, not failed.
	testing.expect_value(t, nats.consumer_delete(conn, "HEIM_EVENTS", "sub_many_3").status, i32(0))
	events, err = next(&service, "alice", "agt_many", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 0, "lost consumer recovered")
	values_destroy(events)
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS + 1))

	// An exhausted scan budget binds nothing and returns promptly.
	rows, rerr := subscriptions(&service, "alice", "agt_many")
	testing.expect_value(t, rerr.code, domain.Error_Code.None)
	defer subscription_rows_destroy(rows)
	pulls := make([]Bound_Pull, len(rows))
	defer delete(pulls)
	for row, i in rows do pulls[i] = Bound_Pull{row = row}
	testing.expect_value(t, activate(&service, conn, pulls, time.tick_now(), 0).code, domain.Error_Code.None)
	for bound in pulls do testing.expect(t, bound.pull == nil, "no consumer bound after the deadline")
}
