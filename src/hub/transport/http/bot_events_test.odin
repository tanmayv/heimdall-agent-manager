package http

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import eventinbox "odin_test:hub/service/eventinbox"
import eventrelay "odin_test:hub/service/eventrelay"
import taskchain "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

// nats.shutdown closes the NATS library process-wide, so a test that calls it
// tears down the connections of NATS tests on other runner threads. Every test
// in this package that touches NATS holds this lock for its whole run.
@(private = "file")
http_nats_test_mutex: sync.Mutex
http_nats_test_lock :: proc() { sync.mutex_lock(&http_nats_test_mutex) }
http_nats_test_unlock :: proc() { sync.mutex_unlock(&http_nats_test_mutex) }

Bot_Event_Pull_Probe :: struct {
	factory: ^iface.Unit_Of_Work_Factory,
	calls: int,
	wait, longest_wait: time.Duration,
}
bot_event_probe_begin :: proc(ctx: rawptr) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
	p := (^Bot_Event_Pull_Probe)(ctx)
	started := time.tick_now()
	u, ok, err := iface.unit_of_work_begin(p.factory)
	wait := time.tick_since(started)
	p.calls += 1; p.wait += wait; p.longest_wait = max(p.longest_wait, wait)
	return u, ok, err
}

// Inspect the specific review event, not just whether some outbox row moved.
// Returned text belongs to the fixture arena. Never change delivery state here.
bot_event_outbox_snapshot :: proc(t: ^testing.T, conn: ^sqlite.Conn) -> string {
	query := "SELECT json_object('event_id',event_id,'subject',subject,'envelope',json(envelope_json),'published_at',COALESCE(published_at,''),'deliveries',(SELECT count(*) FROM event_deliveries d WHERE d.event_id=o.event_id)) FROM event_outbox o WHERE json_extract(envelope_json,'$.type')='task.review_requested_from_user' AND json_extract(envelope_json,'$.entity.id')='task_bot_review';"
	stmt: sqlite.sqlite3_stmt
	if !testing.expect_value(t, sqlite.sqlite3_prepare_v2(conn.db,cstring(raw_data(query)),-1,&stmt,nil),sqlite.SQLITE_OK) do return ""
	defer sqlite.sqlite3_finalize(stmt)
	if !testing.expect_value(t,sqlite.sqlite3_step(stmt),sqlite.SQLITE_ROW) do return ""
	return strings.clone(string(sqlite.sqlite3_column_text(stmt,0)))
}

// Read target metadata through a separate consumer after the original pull.
// Its independent cursor cannot acknowledge, advance or repair the tested watches.
bot_event_timestamp_probe :: proc(conn: ^nats.Connection, subject: string, bindings: []domain.Event_Subscription) {
	probe_name := "bot_event_timestamp_probe"
	add_err := nats.consumer_add(conn, {stream = "HEIM_EVENTS", durable = probe_name, filter_subjects = {subject}, ack_wait_ns = i64(time.Minute), max_deliver = 1})
	if add_err.status != 0 {fmt.eprintf("BOT_EVENT_TIME probe_add_status=%d\n", add_err.status); return}
	pull, bind_err := nats.pull_bind(conn, "HEIM_EVENTS", probe_name)
	if bind_err.status != 0 {fmt.eprintf("BOT_EVENT_TIME probe_bind_status=%d\n", bind_err.status); return}
	defer nats.pull_destroy(pull)
	batch, fetch_err := nats.fetch_available(pull, 1)
	defer nats.batch_destroy(batch)
	if fetch_err.status != 0 || batch == nil || nats.batch_count(batch) != 1 {
		fmt.eprintf("BOT_EVENT_TIME probe_fetch_status=%d\n", fetch_err.status)
		return
	}
	msg := nats.batch_message(batch, 0)
	meta, meta_err := nats.message_metadata(msg)
	fmt.eprintf("BOT_EVENT_TIME timestamp_ns=%d stream_sequence=%d metadata_status=%d body=%s\n", meta.timestamp_ns, meta.stream_sequence, meta_err.status, string(nats.message_data(msg)))
	for binding in bindings {
		start, parsed := platform.parse_rfc3339_utc(binding.created_at)
		start_ns := time.to_unix_nanoseconds(start)
		fmt.eprintf("BOT_EVENT_START subscription=%s created_at=%s parsed=%t start_ns=%d event_minus_start_ns=%d\n", binding.subscription_id, binding.created_at, parsed, start_ns, meta.timestamp_ns - start_ns)
	}
}

// Script a bot's authenticated create/message/pull/ack actions against the real
// service and HTTP handlers, SQLite outbox relay and an isolated JetStream.
@(test)
test_bot_auto_watches_and_pulls_review_request :: proc(t: ^testing.T) {
	http_nats_test_lock(); defer http_nats_test_unlock()
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
	published := bot_event_outbox_snapshot(t, &f.conn)
	published_value, published_err := json.parse_string(published,parse_integers=true)
	if !testing.expect_value(t,published_err,nil) do return
	defer json.destroy_value(published_value)
	published_object := published_value.(json.Object)
	event_id := published_object["event_id"].(json.String)
	subject := published_object["subject"].(json.String)
	testing.expect(t,published_object["published_at"].(json.String)!="","the specific review event was published")
	probe_conn, probe_err := nats.connect(inbox.options)
	if !testing.expect_value(t,probe_err.status,i32(0)) do return
	defer nats.destroy(probe_conn)
	stored, sequence, stored_err := nats.stream_next(probe_conn,"HEIM_EVENTS",string(subject),1)
	if !testing.expect(t,stored_err.status==0 && stored!=nil,"published review event exists in JetStream") do return
	stored_value, stored_parse_err := json.parse(nats.message_data(stored),parse_integers=true)
	nats.message_destroy(stored)
	if !testing.expect_value(t,stored_parse_err,nil) do return
	defer json.destroy_value(stored_value)
	testing.expect_value(t,stored_value.(json.Object)["event_id"].(json.String),event_id)
	bindings, bindings_err := eventinbox.subscriptions(&inbox,string(f.owner),f.instance_id)
	if !testing.expect_value(t,bindings_err.code,domain.Error_Code.None) do return
	defer eventinbox.subscription_rows_destroy(bindings)
	pull_probe := Bot_Event_Pull_Probe{factory=&factory}
	probe_factory := iface.Unit_Of_Work_Factory{ctx=&pull_probe,begin=bot_event_probe_begin}
	inbox.factory=&probe_factory
	handlers := Event_Inbox_Handlers {
		agent_actions = &f.ah,
		inbox         = &inbox,
	}
	// Same authenticated action contract as ham-ctl events next and ack.
	pull_started:=time.tick_now()
	resp := event_next_handler(&handlers, wire_agent_request(f, "events", `{"params":{}}`))
	pull_elapsed:=time.tick_since(pull_started)
	inbox.factory=&factory
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	wire: struct {
		data: struct {
			events: []struct {
				event_id, type: string,
				entity: struct {kind, id: string},
				data: struct {chain_id: string},
			},
		},
	}
	if !testing.expect_value(t, json.unmarshal_string(resp.body, &wire), nil) do return
	fmt.eprintf("BOT_EVENT_PULL event=%s stream_seq=%d elapsed_ms=%d uow_calls=%d uow_wait_ms=%d longest_wait_ms=%d provision_calls=%d received=%d outbox=%s\n",event_id,sequence,pull_elapsed/time.Millisecond,pull_probe.calls,pull_probe.wait/time.Millisecond,pull_probe.longest_wait/time.Millisecond,inbox.provision_calls,len(wire.data.events),bot_event_outbox_snapshot(t,&f.conn))
	for binding in bindings {
		state,state_err:=nats.consumer_state(probe_conn,"HEIM_EVENTS",binding.consumer_name)
		fmt.eprintf("BOT_EVENT_BINDING subscription=%s instance=%s chain=%s consumer=%s filters=%s created_at=%s state=%v status=%d jetstream=%d\n",binding.subscription_id,binding.subscriber_instance_id,binding.chain_id,binding.consumer_name,binding.filter_subjects,binding.created_at,state,state_err.status,state_err.jetstream)
	}
	if len(wire.data.events) != 1 do bot_event_timestamp_probe(probe_conn, string(subject), bindings)
	testing.expect_value(t, len(wire.data.events), 1)
	if len(wire.data.events) != 1 do return
	ev := wire.data.events[0]
	testing.expect_value(t, ev.type, "task.review_requested_from_user")
	testing.expect_value(t, ev.data.chain_id, string(f.chain_id))
	testing.expect_value(t, ev.entity.kind, "task")
	testing.expect_value(t, ev.entity.id, "task_bot_review")
	body := strings.concatenate({`{"params":{"event_ids":["`, ev.event_id, `"]}}`})
	resp = event_ack_handler(&handlers, wire_agent_request(f, "events", body))
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	resp = event_next_handler(&handlers, wire_agent_request(f, "events", `{"params":{}}`))
	testing.expect(t, resp.status == 200 && strings.contains(resp.body, `"events":[]`), resp.body)
}
