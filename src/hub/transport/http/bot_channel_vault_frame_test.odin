package http

import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import br "odin_test:hub/service/bridge_runtime"
import project "odin_test:hub/service/project"

@(test)
bot_channel_vault_reply_frame_uses_only_the_volatile_waiter :: proc(t: ^testing.T) {
	registry := new(project.Bridge_Runtime_Registry)
	defer {
		br.runtime_command_cache_destroy(registry)
		project.bridge_runtime_registry_destroy(registry)
		free(registry)
	}
	hello, admitted, _ := br.runtime_accept_hello(registry, "brg_vault_frame", br.PROTOCOL_VERSION, "", "usr_vault_frame")
	if !testing.expect(t, admitted) do return
	c := project.bridge_runtime_connection_acquire(registry, "brg_vault_frame", hello.generation)
	if !testing.expect(t, c != nil) do return
	defer project.bridge_runtime_connection_release(registry, c)
	slot := project.Channel_Vault_Pending{
		connection = c, operation = "open", request_id = "12345678901234567890123456789012",
		scope_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		started = time.tick_now(), timeout = time.Second,
	}
	registry.channel_vault_pending[0] = &slot
	defer {
		registry.channel_vault_pending[0] = nil
		contracts.bot_channel_vault_result_destroy(&slot.result)
	}
	h := Bridge_Handlers{bridge_runtime_registry = registry}
	// A command_id field must not make the secret body observable from generic
	// command-result paths, even if a peer sends it gratuitously.
	{
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
		text := strings.clone(`{"type":"bot_channel_vault_result","request_id":"12345678901234567890123456789012","command_id":"must-not-cache","operation":"open","scope_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"ok","body":"Zml4dHVyZQ=="}`)
		allocations_before := track.total_allocation_count
		handled := bridge_ws_process_frame(&h, "brg_vault_frame", hello.generation, 0, nil, text, c)
		allocations_after := track.total_allocation_count
		testing.expect(t, handled)
		testing.expect(t, allocations_after == allocations_before, "vault replies bypass heap-backed generic JSON parsing")
	}
	testing.expect_value(t, slot.result.body, "fixture")
	testing.expect_value(t, registry.command_slots_used, 0)
}
