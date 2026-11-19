package taskv2

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import eventrelay "odin_test:hub/service/eventrelay"
import jsonx "odin_test:lib/jsonx"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

// These tests exercise real SQLite transactions and the production entry hooks.
catalog_fixture :: proc(t: ^testing.T) -> (^Fixture, domain.Task_Chain, domain.Task) {
	fx, ok := fixture_open(t, "catalog")
	if !ok do return fx, {}, {}
	chain := seed_chain(t, fx, "catalog_chain", true)
	task := seed_task(t, fx, chain, "catalog_task")
	testing.expect_value(t, task_created(&fx.svc, task, hub_actor()).code, domain.Error_Code.None)
	task, _, _ = iface.taskchain_get_task(&fx.repo, task.task_id)
	return fx, chain, task
}

catalog_count :: proc(fx: ^Fixture, typ: string) -> int {
	return scalar_int(
		fx,
		fmt.tprintf("SELECT count(*) FROM event_outbox WHERE json_extract(envelope_json,'$.type')='%s';", typ),
	)
}
catalog_expect :: proc(t: ^testing.T, fx: ^Fixture, typ, class, topic: string) {
	query := fmt.tprintf(
		"SELECT envelope_json FROM event_outbox WHERE json_extract(envelope_json,'$.type')='%s' ORDER BY outbox_seq DESC LIMIT 1;",
		typ,
	)
	env := scalar_text(fx, query)
	testing.expect_value(t, jsonx.extract_string(env, "type", "", true, context.temp_allocator), typ)
	testing.expect_value(t, jsonx.extract_string(env, "class", "", true, context.temp_allocator), class)
	testing.expect_value(t, jsonx.extract_string(env, "owner_user_id", "", true, context.temp_allocator), "u1")
	testing.expect_value(t, jsonx.extract_string(env, "chain_id", "", true, context.temp_allocator), "catalog_chain")
	testing.expect(t, jsonx.extract_int(env, "entity_version", 0, true) > 0, "nonzero entity version")
	testing.expect(t, jsonx.extract_string(env, "event_id", "", true, context.temp_allocator) != "", "minted event id")
	testing.expect(t, jsonx.extract_string(env, "occurred_at", "", true, context.temp_allocator) != "", "timestamp")
	if topic != "" {
		testing.expect_value(
			t,
			jsonx.extract_string(env, "topic_key", "", true, context.temp_allocator),
			fmt.tprintf("task.catalog_task.%s", topic),
		)
		testing.expect(t, jsonx.extract_int(env, "topic_generation", 0, true) > 0, "topic generation")
	}
	suffix := typ[5:] // both task. and chain. are handled below
	entity := "task.catalog_task"
	if typ == "chain.state" || typ == "chain.work_finished" {suffix = typ[6:]; entity = "chain.catalog_chain"}
	subject := scalar_text(
		fx,
		fmt.tprintf(
			"SELECT subject FROM event_outbox WHERE json_extract(envelope_json,'$.type')='%s' ORDER BY outbox_seq DESC LIMIT 1;",
			typ,
		),
	)
	testing.expect_value(t, subject, fmt.tprintf("ev.u1.%s.%s", entity, suffix))
	if class == "state" {
		headers := scalar_text(
			fx,
			fmt.tprintf(
				"SELECT headers_json FROM event_outbox WHERE json_extract(envelope_json,'$.type')='%s' LIMIT 1;",
				typ,
			),
		)
		testing.expect_value(t, jsonx.extract_string(headers, "Nats-Rollup", "", true, context.temp_allocator), "sub")
	}
}
catalog_record :: proc(t: ^testing.T, fx: ^Fixture, task: domain.Task, kind, payload: string) -> domain.Task {
	u, began, err := begin_uow(&fx.svc); testing.expect(t, began, err.message)
	fresh, _, ok, rerr := record_event(&fx.svc, &u, task, hub_actor(), kind, payload)
	testing.expect(t, ok, rerr.message)
	committed, cerr := end_uow(&fx.svc, &u, ok); testing.expect(t, committed, cerr.message)
	return fresh
}

@(test)
test_catalog_task_state :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	testing.expect_value(t, catalog_count(fx, "task.state"), 1)
	catalog_expect(t, fx, "task.state", "state", "")
	u, _, _ := begin_uow(&fx.svc)
	_, _, ok, err := refold_task(&fx.svc, &u, task); testing.expect(t, ok, err.message)
	_, _ = end_uow(&fx.svc, &u, ok)
	testing.expect_value(t, catalog_count(fx, "task.state"), 1)
	task = catalog_record(t, fx, task, EV_LEASE_GRANTED, `{"kind":"work","instance_id":"missing","lease_id":"l"}`)
	testing.expect_value(t, catalog_count(fx, "task.state"), 2)
	testing.expect_value(t, scalar_int(fx, "SELECT version FROM event_entity_versions WHERE entity_kind='task';"), 2)
}

@(test)
test_catalog_chain_state :: proc(t: ^testing.T) {
	fx, chain, _ := catalog_fixture(t); defer fixture_close(fx)
	u, _, _ := begin_uow(&fx.svc)
	after := chain; after.status = .Completed
	testing.expect_value(t, catalog_chain_state(&fx.repo, &fx.clock, chain, after).code, domain.Error_Code.None)
	testing.expect_value(t, catalog_chain_state(&fx.repo, &fx.clock, after, after).code, domain.Error_Code.None)
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(t, catalog_count(fx, "chain.state"), 1)
	catalog_expect(t, fx, "chain.state", "state", "")
}

@(test)
test_catalog_requirements_changed :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	u, _, _ := begin_uow(&fx.svc)
	err := requirements_record(
		&fx.repo,
		&fx.clock,
		task,
		`{"goal":"new","acceptance":["a"]}`,
		Actor{kind = ACTOR_USER, id = "u1"},
		1,
		"",
		"change1",
	)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	_, _ = end_uow(&fx.svc, &u, err.code == .None)
	testing.expect_value(t, catalog_count(fx, "task.requirements_changed"), 1)
	catalog_expect(t, fx, "task.requirements_changed", "occurrence", "")
	testing.expect_value(
		t,
		scalar_text(
			fx,
			"SELECT json_extract(envelope_json,'$.actor') FROM event_outbox WHERE json_extract(envelope_json,'$.type')='task.requirements_changed';",
		),
		"user",
	)
	// Plaintext/vault requirement content must never enter the catalog envelope.
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT count(*) FROM event_outbox WHERE envelope_json LIKE '%acceptance%' OR envelope_json LIKE '%change1%';",
		),
		0,
	)
}

@(test)
test_catalog_review_verdict :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	u, _, _ := begin_uow(&fx.svc)
	_, ok, err := append_event(
		&fx.repo,
		&fx.clock,
		task,
		Actor{kind = ACTOR_AGENT, id = "inst_r"},
		EV_REVIEW_POSTED,
		`{"role":"reviewer","verdict":"approve","reviewer_agent_id":"agt_r","findings":"private"}`,
	)
	testing.expect(t, ok, err.message); _, _ = end_uow(&fx.svc, &u, ok)
	testing.expect_value(t, catalog_count(fx, "task.review_verdict"), 1)
	catalog_expect(t, fx, "task.review_verdict", "occurrence", "")
	testing.expect_value(
		t,
		scalar_text(
			fx,
			"SELECT json_extract(envelope_json,'$.actor') FROM event_outbox WHERE json_extract(envelope_json,'$.type')='task.review_verdict';",
		),
		"agt_r",
	)
	testing.expect_value(
		t,
		scalar_int(fx, "SELECT count(*) FROM event_outbox WHERE envelope_json LIKE '%private%';"),
		0,
	)
}

@(test)
test_catalog_review_request_and_user_resolution :: proc(t: ^testing.T) {
	fx, chain, task := catalog_fixture(t); defer fixture_close(fx)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	task = catalog_record(t, fx, task, EV_SUBMITTED, "{}")
	u, _, _ := begin_uow(&fx.svc)
	for _ in 0 ..< 3 {
		_, ok, err := evaluate_gate_in_uow(&fx.svc, &u, chain, task, hub_actor()); testing.expect(t, ok, err.message)
	}
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(t, catalog_count(fx, "task.review_requested_from_user"), 1)
	catalog_expect(t, fx, "task.review_requested_from_user", "resolvable", "review_request")
	u, _, _ = begin_uow(&fx.svc)
	_, ok, err := append_event(
		&fx.repo,
		&fx.clock,
		task,
		Actor{kind = ACTOR_USER, id = "u1"},
		EV_REVIEW_POSTED,
		`{"role":"user","verdict":"request_changes"}`,
	)
	testing.expect(t, ok, err.message); _, _ = end_uow(&fx.svc, &u, ok)
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT resolved_generation FROM event_topics WHERE topic_key='task.catalog_task.review_request';",
		),
		1,
	)
	// A later request reopens without deleting/resetting the earlier resolution.
	u, _, _ = begin_uow(&fx.svc)
	testing.expect_value(t, catalog_review_request(&fx.svc, task).code, domain.Error_Code.None)
	_, _ = end_uow(&fx.svc, &u, true)
	testing.expect_value(
		t,
		scalar_int(fx, "SELECT generation FROM event_topics WHERE topic_key='task.catalog_task.review_request';"),
		2,
	)
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT resolved_generation FROM event_topics WHERE topic_key='task.catalog_task.review_request';",
		),
		1,
	)
}

@(test)
test_catalog_blocked_human_and_answer :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	task = catalog_record(t, fx, task, EV_BLOCKED, `{"waiting_on":{"kind":"user","reason":"private"}}`)
	testing.expect_value(t, catalog_count(fx, "task.blocked_on_human"), 1)
	catalog_expect(t, fx, "task.blocked_on_human", "resolvable", "blocked_on_human")
	task = catalog_record(t, fx, task, EV_ANSWERED, "{}")
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT resolved_generation FROM event_topics WHERE topic_key='task.catalog_task.blocked_on_human';",
		),
		1,
	)
	task = catalog_record(t, fx, task, EV_BLOCKED, `{"waiting_on":{"kind":"user","reason":"second"}}`)
	testing.expect_value(
		t,
		scalar_int(fx, "SELECT generation FROM event_topics WHERE topic_key='task.catalog_task.blocked_on_human';"),
		2,
	)
	task = catalog_record(t, fx, task, EV_CANCELLED, "{}")
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT resolved_generation FROM event_topics WHERE topic_key='task.catalog_task.blocked_on_human';",
		),
		2,
	)
}

@(test)
test_catalog_merge_conflict_and_resolution :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	task = catalog_record(t, fx, task, EV_MERGE_CONFLICT, `{"detail":"private file names"}`)
	testing.expect_value(t, catalog_count(fx, "task.merge_conflict"), 1)
	catalog_expect(t, fx, "task.merge_conflict", "resolvable", "merge_conflict")
	task = catalog_record(t, fx, task, EV_MERGED, "{}")
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT resolved_generation FROM event_topics WHERE topic_key='task.catalog_task.merge_conflict';",
		),
		1,
	)
	task = catalog_record(t, fx, task, EV_MERGE_CONFLICT, "{}")
	testing.expect_value(
		t,
		scalar_int(fx, "SELECT generation FROM event_topics WHERE topic_key='task.catalog_task.merge_conflict';"),
		2,
	)
	task = catalog_record(t, fx, task, EV_CANCELLED, "{}")
	testing.expect_value(
		t,
		scalar_int(
			fx,
			"SELECT resolved_generation FROM event_topics WHERE topic_key='task.catalog_task.merge_conflict';",
		),
		2,
	)
}

@(test)
test_catalog_work_finished :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	task = catalog_record(t, fx, task, EV_SUBMITTED, "{}")
	testing.expect_value(t, catalog_count(fx, "chain.work_finished"), 1)
	catalog_expect(t, fx, "chain.work_finished", "occurrence", "")
	u, _, _ := begin_uow(&fx.svc)
	_, _, ok, _ := refold_task(&fx.svc, &u, task); _, _ = end_uow(&fx.svc, &u, ok)
	testing.expect_value(t, catalog_count(fx, "chain.work_finished"), 1)
}

@(test)
test_catalog_rollback_all_tables :: proc(t: ^testing.T) {
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	before := scalar_int(fx, "SELECT count(*) FROM event_outbox;")
	u, _, _ := begin_uow(&fx.svc)
	_, _, ok, err := record_event(&fx.svc, &u, task, hub_actor(), EV_BLOCKED, `{"waiting_on":{"kind":"user"}}`)
	testing.expect(t, ok, err.message)
	_, _ = end_uow(&fx.svc, &u, false)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM event_outbox;"), before)
	testing.expect_value(t, scalar_int(fx, "SELECT version FROM event_entity_versions WHERE entity_kind='task';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM event_topics;"), 0)
	fresh, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	testing.expect_value(t, fresh.state, domain.Task_State.Ready)
	// Outbox failure must abort the state/audit/version/topic mutation too.
	testing.expect(
		t,
		exec_ok(
			t,
			fx,
			"CREATE TRIGGER reject_catalog BEFORE INSERT ON event_outbox BEGIN SELECT RAISE(ABORT,'injected'); END;",
		),
	)
	u, _, _ = begin_uow(&fx.svc)
	_, _, ok, err = record_event(&fx.svc, &u, fresh, hub_actor(), EV_BLOCKED, `{"waiting_on":{"kind":"user"}}`)
	testing.expect(t, !ok && err.code != .None, "failure reaches transaction owner")
	_, _ = end_uow(&fx.svc, &u, ok)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM event_outbox;"), before)
	testing.expect_value(t, scalar_int(fx, "SELECT version FROM event_entity_versions WHERE entity_kind='task';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT count(*) FROM event_topics;"), 0)
}

// Publish real producer rows through the real relay and private JetStream
// harness. Rollup must leave only the newest state and preserve both headers.
@(test)
test_catalog_real_jetstream_rollup :: proc(t: ^testing.T) {
	defer {err := nats.shutdown(5000); testing.expect_value(t, err.status, i32(0))}
	fx, _, task := catalog_fixture(t); defer fixture_close(fx)
	// Destroy the server before fixture_close clears the legacy fixture tracker.
	server, started := natstest.start(); defer natstest.destroy(&server)
	if !testing.expect(t, started) do return
	task = catalog_record(t, fx, task, EV_LEASE_GRANTED, `{"kind":"work","instance_id":"missing","lease_id":"l"}`)
	fx.repos.event_outbox = fx.repo.catalog
	relay := eventrelay.Service {
		factory = &fx.uow,
		options = {url = server.url, timeout_ms = 1000},
	}
	defer nats.destroy(relay.connection)
	for _ in 0 ..< 2 {
		ok, published := eventrelay.step(&relay); testing.expect(t, ok && published, "relay publishes catalog row")
	}
	state, serr := nats.stream_info(relay.connection, "HEIM_EVENTS")
	testing.expect_value(t, serr.status, i32(0))
	testing.expect_value(t, state.messages, u64(1))
	err := nats.consumer_add(
		relay.connection,
		{
			stream = "HEIM_EVENTS",
			durable = "catalog",
			filter_subjects = []string{"ev.u1.task.catalog_task.state"},
			ack_wait_ns = 60_000_000_000,
			max_deliver = 10,
		},
	)
	if !testing.expect_value(t, err.status, i32(0)) do return
	pull, perr := nats.pull_bind(relay.connection, "HEIM_EVENTS", "catalog")
	if !testing.expect_value(t, perr.status, i32(0)) do return
	defer nats.pull_destroy(pull)
	batch, berr := nats.fetch(pull, 1, 2000)
	if !testing.expect_value(t, berr.status, i32(0)) do return
	defer nats.batch_destroy(batch)
	if !testing.expect_value(t, nats.batch_count(batch), 1) do return
	msg := nats.batch_message(batch, 0)
	env := string(nats.message_data(msg))
	testing.expect_value(t, jsonx.extract_int(env, "entity_version", 0, true), 2)
	data, _ := jsonx.extract_raw_object(env, "data", true, context.temp_allocator)
	testing.expect_value(t, jsonx.extract_string(data, "state", "", true, context.temp_allocator), "in_progress")
	rollup, _ := nats.message_header(msg, "Nats-Rollup")
	testing.expect_value(t, rollup, "sub")
	id, _ := nats.message_header(msg, "Nats-Msg-Id")
	testing.expect_value(t, id, jsonx.extract_string(env, "event_id", "", true, context.temp_allocator))
}
