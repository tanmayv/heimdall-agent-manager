package http

// POST /chats {create_owner_chain:true, chain_title?, chain_description?}: a
// one-step coordinator conversation. Before the launch the Hub asks the launch
// Bridge (owner_chain_prepare runtime command) for a new Bridge-created chain;
// the Bridge publishes its registry entry before it replies, so
// create_instance resolves the chain, and the instance boots as its
// coordinator (src/bridge/owner_chain_prepare.odin). Nothing is saved when the
// Bridge refuses.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

OWNER_CHAIN_PREPARE_WAIT_MS :: 20_000
OWNER_CHAIN_TITLE_MAX :: 80

// (chain_id, error). ctx is Content_Handlers.prepare_ctx.
Owner_Chain_Prepare_Proc :: proc(ctx: rawptr, bridge_id, agent_id, title, description: string) -> (string, domain.Domain_Error)

// The default: the owner_chain_prepare runtime command on the launch Bridge.
owner_chain_prepare_via_runtime :: proc(ctx: rawptr, bridge_id, agent_id, title, description: string) -> (string, domain.Domain_Error) {
	registry := cast(^project_service.Bridge_Runtime_Registry)ctx
	if registry == nil do return "", domain.domain_error(.Internal_Error, "bridge runtime is not configured")
	id := fmt.tprintf("cmd_owner_prepare_%d", time.to_unix_nanoseconds(time.now()))
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":"owner_chain_prepare","command_id":"`); write_handler_json_string(&b, id)
	strings.write_string(&b, `","agent_id":"`); write_handler_json_string(&b, agent_id)
	strings.write_string(&b, `","title":"`); write_handler_json_string(&b, title)
	strings.write_string(&b, `","description":"`); write_handler_json_string(&b, description)
	strings.write_string(&b, `"}`)
	reply, received, err := bridge_runtime.send_runtime_command_wait(registry, project_service.Runtime_Command{bridge_id = bridge_id, command_id = id, body_json = strings.to_string(b)}, OWNER_CHAIN_PREPARE_WAIT_MS)
	if !received do return "", err
	defer delete(reply, runtime.default_allocator())
	return owner_chain_prepare_result(reply)
}

// The Bridge's command_result {code, message, chain_id} as (chain_id, error).
owner_chain_prepare_result :: proc(reply: string) -> (string, domain.Domain_Error) {
	code := json_string(reply, "code", context.temp_allocator)
	chain := json_string(reply, "chain_id", context.temp_allocator)
	if code == "ok" && contracts.owner_field_valid(chain, "id") do return chain, {}
	message := json_string(reply, "message", context.temp_allocator)
	if message == "" do message = code
	detail := fmt.tprintf("the Bridge could not create the task chain: %s", message)
	switch code {
	case "vault_locked": return "", domain.domain_error(.Vault_Locked, detail)
	case "bad_request":  return "", domain.domain_error(.Validation_Failed, detail)
	case "invalid_scope": return "", domain.domain_error(.Forbidden, detail)
	}
	return "", domain.domain_error(.Conflict, detail)
}

// The chain's title: the explicit one, else the first line of the message
// (like the UI), else a fallback; at most OWNER_CHAIN_TITLE_MAX runes.
owner_chain_title :: proc(chain_title, initial_body: string) -> string {
	title := strings.trim_space(chain_title)
	if title == "" {
		first := strings.trim_space(initial_body)
		if nl := strings.index_byte(first, '\n'); nl >= 0 do first = strings.trim_space(first[:nl])
		title = first
	}
	if title == "" do title = "Coordinator"
	runes := 0
	for _, i in title {
		if runes == OWNER_CHAIN_TITLE_MAX do return title[:i]
		runes += 1
	}
	return title
}
