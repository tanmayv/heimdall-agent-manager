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

// Pull_Fixture is a real NATS server, the HEIM_EVENTS stream, a migrated
// in-memory database and a Service over both. It is heap-allocated because the
// repositories and factory keep pointers into it.
Pull_Fixture :: struct {
	server:       natstest.Server,
	conn:         ^nats.Connection,
	db:           sqlite.Conn,
	sub_impl:     sqlite.Event_Subscription_Repo_SQLite,
	out_impl:     sqlite.Event_Outbox_Repo_SQLite,
	repos:        iface.Repositories,
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	factory:      iface.Unit_Of_Work_Factory,
	ids:          platform.ID_Generator,
	service:      Service,
	db_open:      bool,
}

// pull_fixture_start creates count coordinator subscriptions for agent, one per
// chain_<i>, with consumer and subscription id <agent>_<i>.
pull_fixture_start :: proc(t: ^testing.T, agent: string, count: int, ack_wait: time.Duration = 0) -> (f: ^Pull_Fixture, ok: bool) {
	f = new(Pull_Fixture)
	started: bool
	f.server, started = natstest.start()
	if !testing.expect(t, started) do return f, false
	nerr: nats.Error
	f.conn, nerr = nats.connect({url = f.server.url, timeout_ms = 1000})
	if !testing.expect_value(t, nerr.status, i32(0)) do return f, false
	_, nerr = nats.stream_add(f.conn, eventrelay.stream_config())
	if !testing.expect_value(t, nerr.status, i32(0)) do return f, false
	f.db, f.db_open, _ = sqlite.open(":memory:")
	if !testing.expect(t, f.db_open) do return f, false
	migrated, _ := sqlite.run_migrations(&f.db)
	if !testing.expect(t, migrated) do return f, false
	f.repos = iface.Repositories {
		event_subscriptions = sqlite.new_event_subscription_repository(&f.sub_impl, &f.db),
		event_outbox        = sqlite.new_event_outbox_repository(&f.out_impl, &f.db),
	}
	f.factory = sqlite.new_unit_of_work_factory(&f.factory_impl, &f.db, &f.repos)
	f.ids = platform.real_id_generator()
	f.service = Service {
		ids      = &f.ids,
		factory  = &f.factory,
		options  = {url = f.server.url, timeout_ms = 1000},
		ack_wait = ack_wait,
	}
	uow, began, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, began) do return f, false
	for i in 0 ..< count {
		chain := fmt.tprintf("chain_%d", i)
		subjects, _ := filters("alice", chain, "", "coordinator")
		encoded, _ := json.marshal(subjects, allocator = context.temp_allocator)
		filters_destroy(subjects)
		id := fmt.tprintf("%s_%d", agent, i)
		testing.expect_value(
			t,
			f.repos.event_subscriptions.put(f.repos.event_subscriptions.ctx, {subscription_id = id, owner_user_id = "alice", subscriber_instance_id = agent, chain_id = chain, source = "role_default", filter_subjects = string(encoded), wake_policy = "catalog", consumer_name = id, created_at = "now"}).code,
			domain.Error_Code.None,
		)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	return f, testing.expect(t, committed)
}
pull_fixture_destroy :: proc(f: ^Pull_Fixture) {
	provisioned_destroy(&f.service)
	if f.db_open do sqlite.close(&f.db)
	nats.destroy(f.conn)
	natstest.destroy(&f.server)
	free(f)
}
// pull_fixture_publish publishes one review_verdict event for chain_<chain>
// under owner, which every coordinator filter for that chain matches.
pull_fixture_publish :: proc(t: ^testing.T, conn: ^nats.Connection, owner: string, chain: int, id: string) {
	data, encode_err := json.marshal(inbox_v2(id, "task.review_verdict", owner, fmt.tprintf("chain_%d",chain), "task_1"))
	if !testing.expect(t, encode_err==nil) do return
	defer delete(data)
	_, err := nats.publish(conn, fmt.tprintf("ev.%s.chain.chain_%d.task.task_1.review_verdict", owner, chain), data, id)
	testing.expect_value(t, err.status, i32(0))
}

// REQ-EVQ-1 and REQ-EVQ-4: an identity with 55 subscriptions. The first pull
// provisions each consumer once; later pulls provision nothing, skip idle
// consumers, stop at the limit and keep to the wait budget.
@(test)
test_event_inbox_pull_many_subscriptions_within_budget :: proc(t: ^testing.T) {
	f, ok := pull_fixture_start(t, "agt_many", PULL_BUDGET_SUBSCRIPTIONS)
	defer pull_fixture_destroy(f)
	if !ok do return
	service := &f.service

	// Cold pull: every consumer is provisioned exactly once, within the budget.
	began_cold := time.tick_now()
	events, err := next(service, "alice", "agt_many", 0, 20)
	cold := time.tick_since(began_cold)
	testing.expect(t, err.code == .None && len(events) == 0, "cold pull over idle subscriptions is empty")
	values_destroy(events)
	testing.expectf(t, cold < NEXT_OVERHEAD_BUDGET + time.Second, "cold pull took %v", cold)
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS))
	testing.expect_value(t, len(service.provisioned.names), PULL_BUDGET_SUBSCRIPTIONS)

	// Warm idle pulls: no re-provisioning, and a long poll ends on time.
	for wait in ([]time.Duration{0, 300 * time.Millisecond}) {
		began_warm := time.tick_now()
		events, err = next(service, "alice", "agt_many", wait, 20)
		elapsed := time.tick_since(began_warm)
		testing.expect(t, err.code == .None && len(events) == 0, "idle pull is empty")
		values_destroy(events)
		testing.expectf(t, elapsed >= wait && elapsed < wait + NEXT_OVERHEAD_BUDGET + time.Second, "wait %v took %v", wait, elapsed)
	}
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS))

	// Three subscriptions get work; a pull stops at its limit and the next pull
	// returns the rest, without provisioning anything again.
	for chain, i in ([]int{7, 20, 40}) do pull_fixture_publish(t, f.conn, "alice", chain, fmt.tprintf("many_%d", i))
	events, err = next(service, "alice", "agt_many", 0, 2)
	testing.expect(t, err.code == .None && len(events) == 2, "pull stops at --limit")
	values_destroy(events)
	events, err = next(service, "alice", "agt_many", 0, 20)
	testing.expectf(t, err.code == .None && len(events) == 1, "remaining event delivered: %v, count %d", err, len(events))
	values_destroy(events)
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS))

	// A long poll wakes for an event on a consumer that was idle when it began.
	Late :: struct {url: string, ok: bool}
	late := Late{url = f.server.url}
	worker := thread.create_and_start_with_poly_data(&late, proc(late: ^Late) {
		time.sleep(150 * time.Millisecond)
		publisher, perr := nats.connect({url = late.url, timeout_ms = 1000})
		if perr.status != 0 do return
		defer nats.destroy(publisher)
		data := `{"event_id":"late_1","type":"task.review_verdict","owner_user_id":"alice","entity":{"kind":"task","id":"task_1"},"data":{"chain_id":"chain_33"},"topic_key":"","topic_generation":0}`
		_, pub_err := nats.publish(publisher, "ev.alice.chain.chain_33.task.task_1.review_verdict", transmute([]byte)string(data), "late_1")
		late.ok = pub_err.status == 0
	})
	began_poll := time.tick_now()
	events, err = next(service, "alice", "agt_many", 5 * time.Second, 20)
	woke := time.tick_since(began_poll)
	thread.join(worker); thread.destroy(worker)
	testing.expect(t, late.ok, "late publish")
	testing.expectf(t, err.code == .None && len(events) == 1, "long poll returns the late event: %v, count %d", err, len(events))
	testing.expectf(t, woke < 2 * time.Second, "long poll woke after %v", woke)
	values_destroy(events)

	// A consumer lost behind the cache is provisioned once more, not failed.
	testing.expect_value(t, nats.consumer_delete(f.conn, "HEIM_EVENTS", "agt_many_3").status, i32(0))
	events, err = next(service, "alice", "agt_many", 0, 20)
	testing.expect(t, err.code == .None && len(events) == 0, "lost consumer recovered")
	values_destroy(events)
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS + 1))

	// An exhausted budget binds nothing: the deadline is checked before the
	// first NATS step of a row, not only between rows.
	rows, rerr := subscriptions(service, "alice", "agt_many")
	testing.expect_value(t, rerr.code, domain.Error_Code.None)
	defer subscription_rows_destroy(rows)
	pulls := make([]Bound_Pull, len(rows))
	defer delete(pulls)
	for row, i in rows do pulls[i] = Bound_Pull{row = row}
	forget_consumer(service, "agt_many_0") // a cache miss would provision first
	testing.expect_value(t, activate(service, f.conn, pulls, time.tick_now(), 0).code, domain.Error_Code.None)
	for bound in pulls do testing.expect(t, bound.pull == nil, "no consumer bound after the deadline")
	testing.expect_value(t, sync.atomic_load(&service.provision_calls), u64(PULL_BUDGET_SUBSCRIPTIONS + 1))
}

// Review finding 1: a long poll over idle subscriptions must not rescan them
// for every event other owners publish. Heavy unrelated traffic during a 2 s
// poll costs no more JetStream API requests than the same poll on a quiet
// stream (one direct get per tick), and none of it rescans the 48 consumers.
@(test)
test_event_inbox_long_poll_ignores_other_owners_traffic :: proc(t: ^testing.T) {
	SUBS :: 48
	POLL :: 2 * time.Second
	f, ok := pull_fixture_start(t, "agt_busy", SUBS)
	defer pull_fixture_destroy(f)
	if !ok do return
	events, err := next(&f.service, "alice", "agt_busy", 0, 20) // provision once
	values_destroy(events)
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return

	quiet_before, _, _ := nats.api_stats(f.conn)
	events, err = next(&f.service, "alice", "agt_busy", POLL, 20)
	values_destroy(events)
	quiet_after, _, _ := nats.api_stats(f.conn)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	quiet := quiet_after - quiet_before

	Noise :: struct {url: string, stop: i32, published: int}
	noise := Noise{url = f.server.url}
	worker := thread.create_and_start_with_poly_data(&noise, proc(noise: ^Noise) {
		publisher, perr := nats.connect({url = noise.url, timeout_ms = 1000})
		if perr.status != 0 do return
		defer nats.destroy(publisher)
		for sync.atomic_load(&noise.stop) == 0 {
			id := fmt.tprintf("noise_%d", noise.published)
			data := fmt.tprintf(`{{"event_id":"%s","type":"task.review_verdict","owner_user_id":"bob"}}`, id)
			_, pub_err := nats.publish(publisher, "ev.bob.chain.chain_1.task.task_1.review_verdict", transmute([]byte)data, id)
			if pub_err.status == 0 do noise.published += 1
			time.sleep(10 * time.Millisecond)
		}
	})
	busy_before, _, _ := nats.api_stats(f.conn)
	events, err = next(&f.service, "alice", "agt_busy", POLL, 20)
	values_destroy(events)
	busy_after, _, _ := nats.api_stats(f.conn)
	sync.atomic_store(&noise.stop, 1)
	thread.join(worker); thread.destroy(worker)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	busy := busy_after - busy_before
	fmt.printf("long poll JetStream API: subscriptions=%d poll_ms=%d quiet=%d busy=%d other_owner_events=%d\n", SUBS, i64(POLL / time.Millisecond), quiet, busy, noise.published)
	testing.expectf(t, noise.published >= 50, "noise published %d events", noise.published)
	// A single rescan would add SUBS consumer-info requests.
	testing.expectf(t, busy <= quiet + 4, "unrelated traffic must not trigger rescans: quiet %d, busy %d", quiet, busy)
	// Ceiling for the whole poll: initial scan (one consumer-info per
	// subscription) plus stream/advisory setup plus one direct get per tick.
	ceiling := u64(SUBS + 8 + int(POLL / NEXT_POLL_TICK) + 2)
	testing.expectf(t, busy <= ceiling, "long poll used %d JetStream API requests (ceiling %d)", busy, ceiling)
}

// Review finding 2: a consumer whose only messages await acknowledgement is
// skipped until a redelivery can be due, then fetched; a delivery the hub never
// recorded is still fetched.
@(test)
test_event_inbox_ack_pending_consumer_redelivery :: proc(t: ^testing.T) {
	ACK_WAIT :: 2500 * time.Millisecond
	f, ok := pull_fixture_start(t, "agt_redeliver", 2, ACK_WAIT)
	defer pull_fixture_destroy(f)
	if !ok do return
	service := &f.service

	pull_fixture_publish(t, f.conn, "alice", 0, "recorded_1")
	events, err := next(service, "alice", "agt_redeliver", 0, 20)
	delivered_at := time.tick_now()
	testing.expect(t, err.code == .None && len(events) == 1, "first delivery")
	values_destroy(events)

	// (a) Before ack_wait the ack-pending consumer is skipped: no 1 s NoWait hold.
	began := time.tick_now()
	events, err = next(service, "alice", "agt_redeliver", 0, 20)
	elapsed := time.tick_since(began)
	testing.expect(t, err.code == .None && len(events) == 0, "nothing new before ack_wait")
	values_destroy(events)
	testing.expectf(t, elapsed < 500 * time.Millisecond, "skipped consumer pull took %v", elapsed)

	// (c) setup: a delivery made outside the hub (no event_deliveries row).
	pull_fixture_publish(t, f.conn, "alice", 1, "orphan_1")
	pull, perr := nats.pull_bind(f.conn, "HEIM_EVENTS", "agt_redeliver_1")
	if !testing.expect_value(t, perr.status, i32(0)) do return
	batch, berr := nats.fetch(pull, 1, 1000)
	testing.expect(t, berr.status == 0 && nats.batch_count(batch) == 1, "orphan delivered without a record")
	nats.batch_destroy(batch)
	nats.pull_destroy(pull)
	orphaned_at := time.tick_now()

	// (b) and (c): once ack_wait has passed, the recorded event is redelivered
	// and the unrecorded one is fetched.
	for time.tick_since(delivered_at) < ACK_WAIT + 300 * time.Millisecond || time.tick_since(orphaned_at) < ACK_WAIT + 300 * time.Millisecond {
		time.sleep(50 * time.Millisecond)
	}
	events, err = next(service, "alice", "agt_redeliver", 0, 20)
	testing.expectf(t, err.code == .None && len(events) == 2, "redelivery after ack_wait: %v, count %d", err, len(events))
	seen := map[string]bool{}
	defer delete(seen)
	for value in events {
		obj, _ := value.(json.Object)
		id, _ := obj["event_id"].(json.String)
		seen[string(id)] = true
	}
	testing.expect(t, seen["recorded_1"], "(b) recorded delivery redelivered")
	testing.expect(t, seen["orphan_1"], "(c) unrecorded ack-pending delivery fetched")
	values_destroy(events)
}
