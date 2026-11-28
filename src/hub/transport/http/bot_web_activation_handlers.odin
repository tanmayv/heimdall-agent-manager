package http

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bots "odin_test:hub/service/bots"

bot_web_activation_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Handlers)(ctx)
	auth, ok, refusal := require_auth(h.auth, req)
	if !ok do return refusal
	if !contracts.is_user_auth(auth) do return respond_error(domain.domain_error(.Forbidden, "owner authentication is required"), req.request_id)
	state: domain.Bot_Web_Activation
	err: domain.Domain_Error
	if req.method == "GET" {
		// Direct links to an existing pane still need its read-only state when
		// the owner switches the experiment off in a different tab.
		state, err = bots.get_web_activation(h.bots, auth.user_id)
	} else {
		value, parse_err := json.parse(req.body, parse_integers=true, allocator=context.temp_allocator)
		obj, object_ok := value.(json.Object)
		enabled, enabled_ok := obj["enabled"].(json.Boolean)
		expected, expected_ok := obj["expected_generation"].(json.Integer)
		if parse_err != nil || !object_ok || !enabled_ok || !expected_ok || expected < 0 do return respond_error(domain.domain_error(.Validation_Failed, "enabled and a nonnegative expected_generation are required"), req.request_id)
		state, err = bots.set_web_activation(h.bots, auth.user_id, bool(enabled), i64(expected))
	}
	defer domain.bot_web_activation_destroy(&state)
	if err.code != .None do return respond_error(err, req.request_id)
	view := struct {enabled: bool, generation: i64, bot_id, agent_instance_id, conversation_id: string}{
		state.enabled, state.generation, state.bot_id, state.agent_instance_id, state.conversation_id,
	}
	return respond_success_typed(view, req.request_id, auth_ctx_server_time(req))
}

bot_conversation_write_state :: proc(ctx: rawptr, auth: contracts.Auth_Context, cid: string) -> (Conversation_Write_State, domain.Domain_Error) {
	s := (^bots.Bots_Service)(ctx)
	state, found, err := iface.bot_web_activation_get(s.repo, auth.user_id)
	defer domain.bot_web_activation_destroy(&state)
	if err.code != .None || !found || state.conversation_id != cid do return {}, err
	if !contracts.is_user_auth(auth) do return {}, domain.domain_error(.Forbidden, "owner authentication is required")
	gate := bots.bots_gate_error(s.experiments, auth.user_id)
	if gate.code != .None && gate.code != .Forbidden do return {}, gate
	return {generation=state.generation, enabled=state.enabled && gate.code == .None, denial=gate,
	        instance_id=strings.clone(state.agent_instance_id, context.temp_allocator)}, {}
}
