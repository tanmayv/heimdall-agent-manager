package actions

import "core:encoding/json"
import "core:testing"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"

@(test)
test_v2_snapshot_settle_and_templates :: proc(t: ^testing.T) {
	envelope := test_config(`{"entity":{"kind":"chain","id":"chain_v2"},"actor":"hub","data":{"state":"completed"}}`)
	msg := Event_View{event_id="evt_v2", event_type="chain.state", envelope=envelope}
	testing.expect_value(t, entity_settle_key(msg), "chain:chain_v2")
	params := event_params(msg,1,"")
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

v2_missing_trigger :: proc(ctx: rawptr, id: string) -> (domain.Action_Trigger, bool, domain.Domain_Error) { return {}, false, {} }
@(test)
test_v2_prompt_metadata_has_flat_entity_fields :: proc(t: ^testing.T) {
 repo := iface.Action_Repository{trigger_get=v2_missing_trigger}
 metadata, err := prompt_metadata(&repo, {}, {event_params_json=`{"entity":{"kind":"chain","id":"c"},"id":"evt"}`}, 0)
 testing.expect_value(t, err.code, domain.Error_Code.None)
 value: json.Value
 testing.expect_value(t, json.unmarshal(transmute([]u8)metadata, &value), nil)
 defer json.destroy_value(value)
 obj, _ := value.(json.Object)
 kind, _ := obj["entity_kind"].(string)
 id, _ := obj["entity_id"].(string)
 testing.expect_value(t, kind, "chain")
 testing.expect_value(t, id, "c")
 _, nested := obj["entity"]; _, legacy := obj["chain_id"]
 testing.expect(t, !nested && !legacy)
}
