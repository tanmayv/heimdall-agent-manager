package content

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import events "odin_test:hub/service/events"

// Read the previous status under the same transaction as the write: concurrent
// status changes must not produce stale previous_status values.
save_memory :: proc(s: ^Content_Service, m: domain.Memory, auth: contracts.Auth_Context) -> (domain.Memory, bool, domain.Domain_Error) {
	uow, begun, err := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {}, false, err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	before: domain.Memory
	found: bool
	read_err: domain.Domain_Error
	{
		context.allocator = context.temp_allocator
		before, found, read_err = iface.content_get_memory(&uow.repos.content, m.memory_id)
	}
	if read_err.code != .None && read_err.code != .Not_Found do return {}, false, read_err
	saved, ok, save_err := iface.content_save_memory(&uow.repos.content, m)
	if !ok do return {}, false, save_err
	if saved.owner_user_id != "system" && (!found || before.status != saved.status) {
		data := struct {
			status, previous_status, memory_type, proposed_by_instance_id, proposed_in_chain_id: string,
		}{
			status=saved.status, previous_status=before.status if found else "",
			memory_type=domain.memory_type_string(saved.type),
			proposed_by_instance_id=saved.proposed_by_instance_id,
			proposed_in_chain_id=saved.proposed_in_chain_id,
		}
		encoded, encode_err := json.marshal(data, allocator=context.temp_allocator)
		if encode_err != nil do return {}, false, domain.domain_error(.Internal_Error, "memory event encoding failed")
		defer delete(encoded, context.temp_allocator)
		actor := "hub"
		if contracts.is_user_auth(auth) {
			actor = "user"
		} else if auth.kind == .Instance_Token && auth.agent_instance_id != "" {
			instance: domain.Agent_Instance
			known: bool
			lookup_err: domain.Domain_Error
			{
				context.allocator = context.temp_allocator
				instance, known, lookup_err = iface.agent_get_instance(&uow.repos.agents, auth.agent_instance_id)
			}
			if lookup_err.code != .None && lookup_err.code != .Not_Found do return {}, false, lookup_err
			if known && instance.owner_user_id == saved.owner_user_id && instance.agent_id != "" do actor = instance.agent_id
		}
		_, emit_err := events.emit(&uow.repos.event_outbox, s.clock, {
			owner=string(saved.owner_user_id), type="memory.state", class="state",
			entity_kind="memory", entity_id=saved.memory_id,
			subject=fmt.tprintf("ev.%s.memory.%s.state", saved.owner_user_id, saved.memory_id),
			data=string(encoded), actor=actor,
		})
		if emit_err.code != .None do return {}, false, emit_err
	}
	// A card operation may already own an outer transaction. The attention
	// projector must see only committed writes, after the transaction lock drops.
	effect: ^Memory_Attention_Effect
	if s.attention != nil {
		heap := runtime.default_allocator()
		effect = new(Memory_Attention_Effect, heap)
		effect^ = {notifier=s.attention, owner=strings.clone(string(saved.owner_user_id), heap), id=strings.clone(saved.memory_id, heap)}
		if iface.unit_of_work_after_commit(&uow, {ctx=effect, run=memory_attention_run, discard=memory_attention_discard}) {
			effect = nil
		} else if uow.nested {
			memory_attention_discard(effect)
			return {}, false, domain.domain_error(.Internal_Error, "cannot defer memory attention")
		}
	}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed {
		if effect != nil do memory_attention_discard(effect)
		return {}, false, commit_err
	}
	if effect != nil do memory_attention_run(effect)
	return saved, true, {}
}

Memory_Attention_Effect :: struct {
	notifier: ^contracts.Attention_Notifier,
	owner, id: string,
}
memory_attention_discard :: proc(ctx: rawptr) {
	e := (^Memory_Attention_Effect)(ctx)
	heap := runtime.default_allocator()
	delete(e.owner, heap)
	delete(e.id, heap)
	free(e, heap)
}
memory_attention_run :: proc(ctx: rawptr) {
	e := (^Memory_Attention_Effect)(ctx)
	defer memory_attention_discard(ctx)
	contracts.attention_notify(e.notifier, e.owner, contracts.ATTENTION_SOURCE_MEMORY, e.id)
}
