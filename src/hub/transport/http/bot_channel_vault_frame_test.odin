package http

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
	text := strings.clone(`{"type":"bot_channel_vault_result","request_id":"12345678901234567890123456789012","command_id":"must-not-cache","operation":"open","scope_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"ok","body":"Zml4dHVyZQ=="}`)
	handled := bridge_ws_process_frame(&h, "brg_vault_frame", hello.generation, 0, nil, text, c)
	testing.expect(t, handled)
	testing.expect_value(t, slot.result.body, "fixture")
	testing.expect_value(t, registry.command_slots_used, 0)
}
