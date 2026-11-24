package events

import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Emit borrows its input and appends inside the caller's unit of work.
// Network publication belongs to the relay after commit.
Emit_Input :: struct {
	owner, type, class, entity_kind, entity_id, subject, data, actor: string,
	topic_key: string,
	replace_open: bool,
	event_id: string,
}
emit :: proc(repo: ^iface.Event_Outbox_Repository, clock: ^platform.Clock, input: Emit_Input) -> (string, domain.Domain_Error) {
	if repo == nil || repo.append == nil do return "", {}
	id := input.event_id
	if id == "" do id = platform.time_id_generate(nil, "evt_")
	generation: i64
	if input.topic_key != "" {
		g, opened, err := repo.open_topic(repo.ctx, input.owner, input.topic_key, id, input.replace_open)
		if err.code != .None do return "", err
		if !opened do return "", {}
		generation = g
	}
	version, err := repo.next_version(repo.ctx, input.owner, input.entity_kind, input.entity_id)
	if err.code != .None do return "", err
	data: json.Value
	defer json.destroy_value(data, allocator=context.temp_allocator)
	if json.unmarshal(transmute([]u8)input.data, &data, allocator=context.temp_allocator) != nil do return "", domain.domain_error(.Validation_Failed, "invalid event data")
	object, valid := data.(json.Object)
	if !valid do return "", domain.domain_error(.Validation_Failed, "event data must be an object")
	at := platform.clock_now(clock)
	envelope := contracts.Event_Envelope{
		event_id=id, type=input.type, class=input.class, owner_user_id=input.owner,
		entity={kind=input.entity_kind, id=input.entity_id}, entity_version=version,
		actor=input.actor, occurred_at=at, data=object,
		topic_key=input.topic_key, topic_generation=generation,
	}
	encoded, encode_err := json.marshal(envelope, allocator=context.temp_allocator)
	if encode_err != nil do return "", domain.domain_error(.Internal_Error, "event encoding failed")
	defer delete(encoded, context.temp_allocator)
	if input.class == "state" {
		if err := repo.set_state_head(repo.ctx, input.owner, input.entity_kind, input.entity_id, input.type, id, version); err.code != .None do return "", err
	}
	return id, repo.append(repo.ctx, {
		event_id=id, owner_user_id=input.owner, subject=input.subject, envelope_json=string(encoded),
		headers_json=`{"Nats-Rollup":"sub"}` if input.class=="state" else "{}", created_at=at,
	})
}
