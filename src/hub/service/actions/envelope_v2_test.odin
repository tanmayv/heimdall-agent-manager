package actions

import "core:encoding/json"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_v2_snapshot_settle_and_templates :: proc(t: ^testing.T) {
	envelope := test_config(`{"entity":{"kind":"chain","id":"chain_v2"},"actor":"hub","data":{"state":"completed"}}`)
	msg := Event_View{event_id="evt_v2", event_type="chain.state", envelope=envelope}
	testing.expect_value(t, chain_settle_key(msg), "chain_v2")
	params := event_params(msg)
	value: json.Value
	testing.expect_value(t, json.unmarshal(transmute([]u8)params, &value), nil)
	defer json.destroy_value(value)
	object, _ := value.(json.Object)
	entity, _ := object["entity"].(json.Object)
	id, _ := entity["id"].(string)
	testing.expect_value(t, id, "chain_v2")
	_, old := object["chain_id"]
	testing.expect(t, !old)
	body := render("{{event.entity.id}}/{{event.entity.kind}}/{{event.chain_id}}", {}, domain.Action_Run{event_params_json=params}, 0, context.allocator)
	defer delete(body)
	testing.expect_value(t, body, "chain_v2/chain/{{event.chain_id}}")
}
@(test)
test_v2_matcher_skips_old_catalog :: proc(t: ^testing.T) {
	// Must ack before opening a UoW, even with no service configured.
	runtime: Runtime
	testing.expect(t, handle_message(&runtime, {subject="ev.owner.chain.c.state", event_type="chain.state", envelope=test_config(`{"chain_id":"c"}`)}))
}
