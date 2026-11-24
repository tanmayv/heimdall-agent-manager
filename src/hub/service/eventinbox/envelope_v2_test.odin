package eventinbox

import "core:encoding/json"
import "core:strings"
import "core:testing"

Inbox_Test_Envelope :: struct {
	event_id, type, owner_user_id: string,
	entity: struct {kind, id: string},
	data: struct {chain_id, state: string},
	topic_key: string,
	topic_generation: i64,
}
inbox_v2 :: proc(id, typ, owner, chain, task: string, topic := "", generation: i64 = 0, state := "") -> Inbox_Test_Envelope {
	is_task := strings.has_prefix(typ, "task.")
	return {event_id=id, type=typ, owner_user_id=owner,
		entity={"task" if is_task else "chain", task if is_task else chain},
		data={chain if is_task else "", state}, topic_key=topic, topic_generation=generation}
}
@(test)
test_v2_catalog_parent_decoder :: proc(t: ^testing.T) {
	for input, i in ([]string{
		`{"entity":{"kind":"chain","id":"c"}}`,
		`{"entity":{"kind":"task","id":"t"},"data":{"chain_id":"c"}}`,
		`{"chain_id":"c","task_id":"t"}`,
	}) {
		value: json.Value
		testing.expect_value(t, json.unmarshal(transmute([]u8)input, &value), nil)
		obj, _ := value.(json.Object)
		testing.expect_value(t, catalog_chain(obj), "c" if i<2 else "")
		json.destroy_value(value)
	}
}
