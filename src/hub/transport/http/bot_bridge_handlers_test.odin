package http
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_bot_switch_http_auth_and_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t, false); defer bot_http_destroy(f)
	h := Bridge_Handlers{bridges = &f.wire.br_svc, bots = &f.service, experiments = &f.experiments}
	req := Request{method = "POST", path = "/api/v1/bridge/bot-attempts/bda_switch/switch", body = "{}"}
	testing.expect_value(t, bot_bridge_switch_handler(&h, req).status, 401)
	req.headers = {{name = "Authorization", value = "Bearer invalid"}}
	testing.expect_value(t, bot_bridge_switch_handler(&h, req).status, 401)
	req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.wire.bridge_token)}}
	disabled := bot_bridge_switch_handler(&h, req)
	testing.expect_value(t, disabled.status, 403)
	testing.expect(t, strings.contains(disabled.body, "experimental_feature_disabled"))
	_, _ = iface.experiment_set(&f.experiments, {owner_user_id = string(f.wire.owner), key = "bots", enabled = true, updated_at = "now"})
	missing := bot_bridge_switch_handler(&h, req)
	testing.expect_value(t, missing.status, 404)
	testing.expect(t, strings.contains(missing.body, "bot_attempt_not_found"))
	bot := bot_http_create(t, f)
	_ = iface.bot_set_instance(&f.bot_repo, bot.bot_id, f.wire.instance_id, "now")
	inst, found, _ := iface.agent_get_instance(&f.wire.ag_repo, f.wire.instance_id)
	testing.expect(t, found)
	_ = iface.delivery_insert(&f.bot_repo, {delivery_id = "bdl_switch", bot_id = bot.bot_id, owner_user_id = string(f.wire.owner), state = .Dispatched, round = 1, created_at = "now", updated_at = "now"})
	candidates, _ := json.marshal([]contracts.Bot_Candidate_Wire{{provider = inst.provider, provider_profile = inst.provider_profile, model = inst.model}})
	_ = iface.attempt_insert(&f.bot_repo, {attempt_id = "bda_switch", delivery_id = "bdl_switch", bridge_id = f.wire.bridge_pin, round = 1, state = .Sent, candidates_json = string(candidates), created_at = "now"})
	req.body = `{"provider":"unauthorized","model":"model"}`
	denied := bot_bridge_switch_handler(&h, req)
	testing.expect_value(t, denied.status, 409)
	testing.expect(t, strings.contains(denied.body, "bot_candidate_not_allowed"))
	request_data, _ := json.marshal(struct {provider, provider_profile, model: string}{inst.provider, inst.provider_profile, inst.model})
	req.body = string(request_data)
	response := bot_bridge_switch_handler(&h, req)
	testing.expectf(t, response.status == 200, "%s", response.body)
	testing.expect(t, strings.contains(response.body, `"relaunched":false`))
	testing.expect(t, strings.contains(response.body, inst.agent_instance_id))
	a, _, _ := iface.attempt_get(&f.bot_repo, "bda_switch")
	a.state = .Cancelled; _, _ = iface.attempt_update(&f.bot_repo, a, .Sent)
	terminal := bot_bridge_switch_handler(&h, req)
	testing.expect_value(t, terminal.status, 404)
}
