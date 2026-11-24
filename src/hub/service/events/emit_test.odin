package events

import "core:encoding/json"
import "core:mem"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

emit_test_clock :: proc(ctx: rawptr) -> string { return "2026-11-24T00:00:00Z" }
Emit_Test :: struct {t: ^testing.T, appended, headed: bool}
emit_test_version :: proc(ctx: rawptr, owner, kind, id: string) -> (i64, domain.Domain_Error) {
	f := (^Emit_Test)(ctx)
	testing.expect_value(f.t, kind, "memory")
	testing.expect_value(f.t, id, "m1")
	return 7, {}
}
emit_test_append :: proc(ctx: rawptr, row: domain.Event_Outbox_Row) -> domain.Domain_Error {
	f := (^Emit_Test)(ctx)
	value: json.Value
	testing.expect_value(f.t, json.unmarshal(transmute([]u8)row.envelope_json, &value), nil)
	defer json.destroy_value(value)
	obj, _ := value.(json.Object)
	entity, _ := obj["entity"].(json.Object)
	id, _ := entity["id"].(string)
	testing.expect_value(f.t, id, "m1")
	version, _ := obj["entity_version"].(json.Integer)
	testing.expect_value(f.t, i64(version), i64(7))
	_, old := obj["chain_id"]
	testing.expect(f.t, !old)
	testing.expect_value(f.t, row.headers_json, `{"Nats-Rollup":"sub"}`)
	f.appended = true
	return {}
}
@(test)
test_v2_neutral_emit_owns_temporary_allocations :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = context.allocator
	f := Emit_Test{t=t}
	repo := iface.Event_Outbox_Repository{ctx=&f, next_version=emit_test_version, set_state_head=emit_test_head, append=emit_test_append}
	clock := platform.Clock{now=emit_test_clock}
	id, err := emit(&repo, &clock, {owner="owner", type="memory.state", class="state",
		entity_kind="memory", entity_id="m1", subject="ev.owner.memory.m1.state",
		data=`{"status":"approved"}`, actor="hub", event_id="evt"})
	testing.expect_value(t, id, "evt")
	testing.expect(t, err.code==.None && f.appended)
	testing.expect_value(t, len(track.allocation_map), 0)
}

emit_test_head :: proc(ctx: rawptr, owner, kind, id, event_type, event_id: string, version: i64) -> domain.Domain_Error {
	f := (^Emit_Test)(ctx)
	testing.expect_value(f.t, owner, "owner")
	testing.expect_value(f.t, kind, "memory")
	testing.expect_value(f.t, id, "m1")
	testing.expect_value(f.t, event_type, "memory.state")
	testing.expect_value(f.t, event_id, "evt")
	testing.expect_value(f.t, version, i64(7))
	f.headed=true
	return {}
}
