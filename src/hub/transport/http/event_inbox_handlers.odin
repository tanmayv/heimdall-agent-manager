package http

import "core:encoding/json"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import eventinbox "odin_test:hub/service/eventinbox"

Event_Inbox_Handlers :: struct {
	agent_actions: ^Agent_Action_Handlers,
	inbox:         ^eventinbox.Service,
}
event_next_handler :: proc(ctx: rawptr, req: Request) -> Response {return event_inbox_handler(ctx, req, "next")}
event_ack_handler :: proc(ctx: rawptr, req: Request) -> Response {return event_inbox_handler(ctx, req, "ack")}
event_watch_handler :: proc(ctx: rawptr, req: Request) -> Response {return event_inbox_handler(ctx, req, "watch")}
event_unwatch_handler :: proc(ctx: rawptr, req: Request) -> Response {return event_inbox_handler(ctx, req, "unwatch")}
event_subscriptions_handler :: proc(ctx: rawptr, req: Request) -> Response {return event_inbox_handler(
		ctx,
		req,
		"subscriptions",
	)}

event_inbox_handler :: proc(ctx: rawptr, req: Request, verb: string) -> Response {
	h := (^Event_Inbox_Handlers)(ctx)
	auth, inst, ok, refusal := require_instance_action_auth(h.agent_actions, req)
	if !ok do return refusal
	defer domain.agent_instance_destroy(&inst)
	// Only authenticated, hub-resolved durable identity is authoritative.
	owner, agent := auth.user_id, string(inst.agent_id)
	if owner == "" || agent == "" || string(inst.owner_user_id) != owner do return respond_error(domain.domain_error(.Forbidden, "agent identity required"), req.request_id)
	params := json_object_raw(req.body, "params", context.temp_allocator)
	if params == "" do params = "{}"
	value, parse_err := json.parse(params, parse_integers = true, allocator = context.temp_allocator)
	obj, obj_ok := value.(json.Object)
	if parse_err != nil || !obj_ok do return respond_error(domain.domain_error(.Validation_Failed, "params must be an object"), req.request_id)
	for key in obj {
		allowed := false
		switch verb {
		case "next":
			allowed = key == "limit" || key == "wait_ms"
		case "ack":
			allowed = key == "event_ids"
		case "watch", "unwatch":
			allowed = key == "chain_id"
		}
		if !allowed do return respond_error(domain.domain_error(.Validation_Failed, "unknown events parameter"), req.request_id)
	}
	switch verb {
	case "subscriptions":
		rows, err := eventinbox.subscriptions(h.inbox, owner, agent)
		defer eventinbox.subscription_rows_destroy(rows)
		if err.code != .None do return respond_error(err, req.request_id)
		return respond_success_typed(struct {
				subscriptions: []domain.Event_Subscription,
			}{rows}, req.request_id, auth_ctx_server_time(req))
	case "next":
		input := contracts.Events_Next_Input{0, 20}
		valid := true
		for key in ([]string{"wait_ms", "limit"}) {
			if v, present := obj[key]; present {
				_, integer := v.(json.Integer)
				valid = valid && integer
			}
		}
		if !valid || json.unmarshal(transmute([]byte)params, &input, allocator = context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid next parameters"), req.request_id)
		if input.wait_ms < 0 || input.wait_ms > 30000 || input.limit < 1 || input.limit > 100 do return respond_error(domain.domain_error(.Validation_Failed, "wait_ms must be 0..30000 and limit 1..100"), req.request_id)
		rows, err := eventinbox.next(
			h.inbox,
			owner,
			agent,
			time.Duration(input.wait_ms) * time.Millisecond,
			input.limit,
		)
		defer eventinbox.values_destroy(rows)
		if err.code != .None do return respond_error(err, req.request_id)
		return respond_success_typed(struct {
				events: []json.Value,
			}{rows}, req.request_id, auth_ctx_server_time(req))
	case "ack":
		ids, array_ok := obj["event_ids"].(json.Array)
		valid := array_ok
		for id in ids {
			_, string_ok := id.(json.String)
			valid = valid && string_ok
		}
		if !valid do return respond_error(domain.domain_error(.Validation_Failed, "event_ids must be an array of strings"), req.request_id)
		input: contracts.Events_Ack_Input
		if json.unmarshal(transmute([]byte)params, &input, allocator = context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid event ids"), req.request_id)
		if err := eventinbox.acknowledge(h.inbox, owner, agent, input.event_ids); err.code != .None do return respond_error(err, req.request_id)
		return respond_success_typed(struct {
				acknowledged: bool,
			}{true}, req.request_id, auth_ctx_server_time(req))
	case "watch", "unwatch":
		if _, string_ok := obj["chain_id"].(json.String); !string_ok do return respond_error(domain.domain_error(.Validation_Failed, "chain_id must be a string"), req.request_id)
		input: contracts.Events_Watch_Input
		if json.unmarshal(transmute([]byte)params, &input, allocator = context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid chain"), req.request_id)
		if err := eventinbox.watch(h.inbox, owner, agent, input.chain_id, verb == "unwatch"); err.code != .None do return respond_error(err, req.request_id)
		return respond_success_typed(struct {
				watching: bool,
			}{verb == "watch"}, req.request_id, auth_ctx_server_time(req))
	}
	return respond_error(domain.domain_error(.Not_Found, "unknown events verb"), req.request_id)
}

event_metrics_handler :: proc(ctx: rawptr, req: Request) -> Response {
 h := (^Event_Inbox_Handlers)(ctx)
 principal, ok, refusal := require_auth(h.agent_actions.auth, req)
 if !ok do return refusal
 result, err := eventinbox.metrics(h.inbox, principal.user_id)
 defer eventinbox.metrics_destroy(&result)
 if err.code != .None do return respond_error(err, req.request_id)
 return respond_success_typed(result, req.request_id, auth_ctx_server_time(req))
}
