package http

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventinbox "odin_test:hub/service/eventinbox"
import eventrelay "odin_test:hub/service/eventrelay"
import taskchain "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

// Script a bot's authenticated create/message/pull/ack actions against the real
// service and HTTP handlers, SQLite outbox relay and an isolated JetStream.
@(test)
test_bot_auto_watches_and_pulls_review_request :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	bot_events_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

bot_events_scenario :: proc(t: ^testing.T) {
	// Existing wire fixture follows request-arena ownership for nested records.
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	c := coordinator_wake_fixture(t)
	defer coordinator_wake_fixture_destroy(c)
	f := c.f
	sub_impl: sqlite.Event_Subscription_Repo_SQLite
	out_impl: sqlite.Event_Outbox_Repo_SQLite
	repos := iface.Repositories {
		event_subscriptions = sqlite.new_event_subscription_repository(&sub_impl, &f.conn),
		event_outbox        = sqlite.new_event_outbox_repository(&out_impl, &f.conn),
		taskchains          = f.tc_repo,
	}
	f.tc_repo.catalog = repos.event_outbox
	repos.taskchains = f.tc_repo
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &f.conn, &repos)
	f.tc_svc.uow_factory = &factory
	c.content.uow_factory = &factory
	auth := contracts.Auth_Context {
		kind              = .Instance_Token,
		user_id           = string(f.owner),
		agent_instance_id = f.instance_id,
	}
	inbox := eventinbox.Service {
		factory = &factory,
		ids     = &f.ids,
	}
	// A normal worker (even one messaging a coordinator) gets no explicit watch.
	coordinator_wake_expect(t, c, "started", 1)
	rows, err := eventinbox.subscriptions(&inbox, string(f.owner), string(f.instance_id))
	testing.expect_value(t, err.code, domain.Error_Code.None)
	for row in rows do testing.expect(t, row.source != "explicit")
	eventinbox.subscription_rows_destroy(rows)
	testing.expect(
		t,
		sqlite.exec(
			&f.conn,
			fmt.tprintf(
				"INSERT INTO bots(bot_id,owner_user_id,agent_id,agent_instance_id,created_at,updated_at) VALUES('bot_events','%s','agt_wire_tb2','%s','now','now');",
				f.owner,
				f.instance_id,
			),
		),
	)
	// Creation installs the watch before any subsequent task can request review.
	created, ok, cerr := taskchain.create_chain(&f.tc_svc, auth, {title = "Bot created"})
	if !testing.expect(t, ok, cerr.message) do return
	rows, err = eventinbox.subscriptions(&inbox, string(f.owner), string(f.instance_id))
	found := false
	for row in rows {
		if row.chain_id == string(created.chain_id) && row.source == "explicit" do found = true
	}
	testing.expect(t, found, "bot creation adds explicit watch")
	eventinbox.subscription_rows_destroy(rows)
	// A failed watch write must roll back creation, never leave an unwatched
	// chain after reporting failure.
	before, _ := iface.taskchain_list_chains_by_owner(&f.tc_repo, f.owner)
	testing.expect(
		t,
		sqlite.exec(
			&f.conn,
			"CREATE TEMP TRIGGER reject_bot_watch BEFORE INSERT ON event_subscriptions WHEN NEW.source='explicit' BEGIN SELECT RAISE(ABORT,'injected watch failure'); END;",
		),
	)
	_, rejected, rerr := taskchain.create_chain(&f.tc_svc, auth, {title = "Must roll back"})
	testing.expect(t, !rejected && rerr.code != .None)
	testing.expect(t, sqlite.exec(&f.conn, "DROP TRIGGER reject_bot_watch;"))
	after, _ := iface.taskchain_list_chains_by_owner(&f.tc_repo, f.owner)
	testing.expect_value(t, len(after), len(before))
	// A message to an existing coordinator installs its chain watch. Repeating
	// messages is idempotent and never changes the existing consumer identity.
	coordinator_wake_expect(t, c, "not_needed", 1)
	coordinator_wake_expect(t, c, "not_needed", 1)
	rows, err = eventinbox.subscriptions(&inbox, string(f.owner), string(f.instance_id))
	watched := 0
	for row in rows {
		if row.source != "explicit" do continue
		watched += 1
		testing.expect(t, row.chain_id == string(created.chain_id) || row.chain_id == string(f.chain_id))
	}
	testing.expect_value(t, watched, 2)
	eventinbox.subscription_rows_destroy(rows)
	// A retired instance and another tenant cannot reuse the canonical binding.
	testing.expect_value(
		t,
		eventinbox.auto_watch_bot(&inbox, "other_owner", f.instance_id, string(f.chain_id), "").code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		eventinbox.auto_watch_bot(&inbox, string(f.owner), "retired_instance", string(f.chain_id), "").code,
		domain.Error_Code.None,
	)
	// Emit through the production catalog producer in a real transaction.
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	engine := taskv2.Service {
		repo  = &f.tc_repo,
		clock = &f.clock,
		ids   = &f.ids,
	}
	testing.expect_value(
		t,
		taskv2.catalog_review_request(&engine, {task_id = "task_bot_review", chain_id = f.chain_id, owner_user_id = f.owner}).code,
		domain.Error_Code.None,
	)
	committed, _ := iface.unit_of_work_commit(&uow)
	if !testing.expect(t, committed) do return
	server, started := natstest.start()
	defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	relay := eventrelay.Service {
		factory = &factory,
		options = {url = server.url, timeout_ms = 1000},
	}
	defer nats.destroy(relay.connection)
	relay_ok, progress := eventrelay.step(&relay)
	if !testing.expect(t, relay_ok && progress, "publish review request outbox") do return
	inbox.options = {
		url        = server.url,
		timeout_ms = 1000,
	}
	handlers := Event_Inbox_Handlers {
		agent_actions = &f.ah,
		inbox         = &inbox,
	}
	// Same authenticated action contract as ham-ctl events next and ack.
	resp := event_next_handler(&handlers, wire_agent_request(f, "events", `{"params":{}}`))
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	wire: struct {
		data: struct {
			events: []struct {
				event_id, type, chain_id, task_id: string,
			},
		},
	}
	if !testing.expect_value(t, json.unmarshal_string(resp.body, &wire), nil) do return
	testing.expect_value(t, len(wire.data.events), 1)
	if len(wire.data.events) != 1 do return
	ev := wire.data.events[0]
	testing.expect_value(t, ev.type, "task.review_requested_from_user")
	testing.expect_value(t, ev.chain_id, string(f.chain_id))
	testing.expect_value(t, ev.task_id, "task_bot_review")
	body := strings.concatenate({`{"params":{"event_ids":["`, ev.event_id, `"]}}`})
	resp = event_ack_handler(&handlers, wire_agent_request(f, "events", body))
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	resp = event_next_handler(&handlers, wire_agent_request(f, "events", `{"params":{}}`))
	testing.expect(t, resp.status == 200 && strings.contains(resp.body, `"events":[]`), resp.body)
}
