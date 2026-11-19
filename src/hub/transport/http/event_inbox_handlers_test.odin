package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import eventinbox "odin_test:hub/service/eventinbox"

@(test)
test_events_api_uses_authenticated_durable_identity :: proc(t: ^testing.T) {
	// Legacy auth fixture uses request-arena ownership. Inbox and NATS integration
	// suites separately track and assert every owned allocation.
	context.allocator = context.temp_allocator
	f := wire_setup(t, "events_auth")
	defer wire_teardown(f)
	sub_impl: sqlite.Event_Subscription_Repo_SQLite
	repos := iface.Repositories {
		event_subscriptions = sqlite.new_event_subscription_repository(&sub_impl, &f.conn),
		taskchains          = f.tc_repo,
	}
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &f.conn, &repos)
	service := eventinbox.Service {
		factory = &factory,
		ids     = &f.ids,
	}
	handlers := Event_Inbox_Handlers {
		agent_actions = &f.ah,
		inbox         = &service,
	}
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	for identity, i in ([][2]string {
			{string(f.owner), "agt_wire_tb2"},
			{string(f.owner), "agt_other"},
			{"other_owner", "agt_wire_tb2"},
		}) {
		id := "sub_own"
		if i == 1 do id = "sub_other_agent"
		if i == 2 do id = "sub_other_tenant"
		testing.expect_value(
			t,
			repos.event_subscriptions.put(repos.event_subscriptions.ctx, {subscription_id = id, owner_user_id = identity[0], subscriber_agent_id = identity[1], chain_id = string(f.chain_id), source = "explicit", filter_subjects = "[]", consumer_name = id, wake_policy = "catalog", created_at = "now"}).code,
			domain.Error_Code.None,
		)
	}
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	req := wire_agent_request(
		f,
		"events",
		`{"params":{"subscriber_agent_id":"agt_other","owner_user_id":"other_owner"}}`,
	)
	injected := event_subscriptions_handler(&handlers, req)
	testing.expect(t, injected.status == 400, "caller cannot supply identity")
	req = wire_agent_request(f, "events", `{"params":{}}`)
	resp := event_subscriptions_handler(&handlers, req)
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	testing.expect(t, strings.contains(resp.body, "sub_own"))
	testing.expect(
		t,
		!strings.contains(resp.body, "sub_other_agent") && !strings.contains(resp.body, "sub_other_tenant"),
		"body cannot select another identity",
	)
	unauth := event_subscriptions_handler(&handlers, {method = "POST", body = "{}"})
	testing.expect_value(t, unauth.status, 401)
	human := event_subscriptions_handler(
		&handlers,
		wire_cookie_request(f, "POST", "/api/v1/agent-actions/events/subscriptions", "{}"),
	)
	testing.expect(t, human.status == 401 || human.status == 403, "user cookie is not an instance token")
	// Unwatch is scoped to the token's durable identity even with injected ids.
	unwatch_body := wire_body(
		[]string{`{"params":{"chain_id":"`, string(f.chain_id), `","subscriber_agent_id":"agt_other"}}`},
	)
	defer delete(unwatch_body)
	resp = event_unwatch_handler(&handlers, wire_agent_request(f, "events", unwatch_body))
	testing.expect_value(t, resp.status, 400)
	clean_unwatch_body := wire_body([]string{`{"params":{"chain_id":"`, string(f.chain_id), `"}}`})
	resp = event_unwatch_handler(&handlers, wire_agent_request(f, "events", clean_unwatch_body))
	defer delete(clean_unwatch_body)
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	others, err := eventinbox.subscriptions(&service, string(f.owner), "agt_other")
	testing.expect(t, err.code == .None && len(others) == 1)
	eventinbox.subscription_rows_destroy(others)
	own, own_err := eventinbox.subscriptions(&service, string(f.owner), "agt_wire_tb2")
	testing.expect(t, own_err.code == .None && len(own) == 1)
	if len(own) > 0 do testing.expect_value(t, own[0].source, "role_default")
	eventinbox.subscription_rows_destroy(own)
	for params in ([]string {
			`{"params":{"limit":0}}`,
			`{"params":{"limit":101}}`,
			`{"params":{"limit":"20"}}`,
			`{"params":{"wait_ms":30001}}`,
			`{"params":{"wait_ms":-1}}`,
			`{"params":{"wait_ms":1.5}}`,
		}) {
		resp = event_next_handler(&handlers, wire_agent_request(f, "events", params))
		testing.expectf(t, resp.status == 400, "invalid parameters rejected: %s", resp.body)
	}
	resp = event_watch_handler(&handlers, wire_agent_request(f, "events", `{"params":{"chain_id":"missing"}}`))
	testing.expect_value(t, resp.status, 404)
}
