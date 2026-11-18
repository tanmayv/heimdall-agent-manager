package http
import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bots "odin_test:hub/service/bots"
import bridge_service "odin_test:hub/service/bridge"

bot_bridge_switch_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	token, token_ok := bearer_token(req)
	if !token_ok do return respond_error(domain.domain_error(.Unauthenticated, "bridge bearer token is required"), req.request_id)
	auth, ok, err := bridge_service.verify_bridge_token(h.bridges, token)
	if !ok do return respond_error(err, req.request_id)
	if enabled, refusal := require_experiment_enabled(h.experiments, auth.user_id, "bots", req.request_id); !enabled do return refusal
	if h.bots == nil do return respond_error(domain.domain_error(.Internal_Error, "bots service is not configured"), req.request_id)
	candidate: contracts.Bot_Candidate_Wire
	if json.unmarshal(transmute([]u8)(req.body), &candidate, allocator = context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid bot switch"), req.request_id)
	view, switch_err := bots.bots_switch(h.bots, auth.bridge_id, path_part(req.path, 5), candidate)
	if switch_err.code != .None do return respond_error(switch_err, req.request_id)
	return respond_success_typed(view, req.request_id, auth_ctx_server_time(req))
}
