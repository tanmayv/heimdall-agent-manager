package http

import "core:strings"
import "core:sync"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_owner_chain_prepare_result_and_title :: proc(t: ^testing.T) {
	chain, err := owner_chain_prepare_result(`{"type":"command_result","command_id":"c","code":"ok","message":"","chain_id":"chain_abc"}`)
	testing.expect_value(t, chain, "chain_abc")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	_, err = owner_chain_prepare_result(`{"code":"vault_locked","message":"the owner Bridge vault is locked","chain_id":""}`)
	testing.expect_value(t, err.code, domain.Error_Code.Vault_Locked)
	testing.expect(t, strings.contains(err.message, "vault is locked"), "the Bridge's reason reaches the user")
	_, err = owner_chain_prepare_result(`{"code":"bad_request","message":"x","chain_id":""}`)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	_, err = owner_chain_prepare_result(`{"code":"ok","chain_id":"bad id/.."}`)
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)

	testing.expect_value(t, owner_chain_title("Explicit", "Plan it"), "Explicit")
	testing.expect_value(t, owner_chain_title("", "  Plan the release\nwith tickets"), "Plan the release")
	testing.expect_value(t, owner_chain_title("", ""), "Coordinator")
	testing.expect_value(t, owner_chain_title("", "vault:v2:abc:e1:sealed"), "Coordinator") // a sealed message is never read
	sealed := strings.concatenate({"vault:v2:abc:e1:", strings.repeat("x", 200, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, owner_chain_title(sealed, ""), sealed) // a sealed title is relayed untouched
	testing.expect_value(t, len(owner_chain_title(strings.repeat("é", 100, context.temp_allocator), "")), 160)
}

Owner_Prepare_Probe :: struct { calls, discards: int, bridge, agent, title, description, chain, discarded: string, fail: domain.Domain_Error }

@(private = "file")
owner_prepare_probe_discard :: proc(ctx: rawptr, bridge_id, chain_id: string) -> bool {
	p := (^Owner_Prepare_Probe)(ctx)
	sync.atomic_add(&p.discards, 1)
	p.discarded = strings.clone(strings.concatenate({bridge_id, "/", chain_id}, context.temp_allocator), context.temp_allocator)
	return true
}

@(test)
test_create_chat_owner_chain_refusal_saves_nothing :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "owner_prepare")
	defer mq_http_base_close(f.base)
	@(static) probe: Owner_Prepare_Probe
	probe = {fail = domain.domain_error(.Vault_Locked, "the Bridge could not create the task chain: the owner Bridge vault is locked")}
	f.handlers.prepare_ctx = &probe
	f.handlers.prepare_owner_chain = proc(ctx: rawptr, bridge_id, agent_id, chain_id, title, description: string) -> (string, domain.Domain_Error) {
		p := (^Owner_Prepare_Probe)(ctx)
		sync.atomic_add(&p.calls, 1)
		p.bridge, p.agent, p.title, p.description = strings.clone(bridge_id, context.temp_allocator), strings.clone(agent_id, context.temp_allocator), strings.clone(title, context.temp_allocator), strings.clone(description, context.temp_allocator)
		return p.chain, p.fail
	}
	f.handlers.discard_owner_chain = owner_prepare_probe_discard
	before := list_chat_conversations_count(t, &f)

	// No bridge: refused before the Bridge is asked.
	missing := create_chat_handler(&f.handlers, mq_http_req(f.base, "/api/v1/chats", `{"agent_id":"agt_coord","create_owner_chain":true,"initial_message":{"body":"Plan"}}`))
	testing.expect_value(t, missing.status, 400)
	testing.expect_value(t, probe.calls, 0)

	body := strings.concatenate({`{"agent_id":"agt_coord","bridge_id":"`, f.base.bridge_id, `","create_owner_chain":true,"chain_description":"d","initial_message":{"body":"Plan the release\nwith tickets"}}`}, context.temp_allocator)
	refused := create_chat_handler(&f.handlers, mq_http_req(f.base, "/api/v1/chats", body))
	testing.expect_value(t, refused.status, 423)
	testing.expect(t, strings.contains(refused.body, "vault is locked"), "a clear error")
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.bridge, f.base.bridge_id)
	testing.expect_value(t, probe.agent, "agt_coord")
	testing.expect_value(t, probe.title, "Plan the release")
	testing.expect_value(t, probe.description, "d")
	testing.expect_value(t, probe.discards, 0) // nothing was created, nothing to roll back
	testing.expect_value(t, list_chat_conversations_count(t, &f), before)
}

// The Bridge created the chain but the launch fails (here: the chain is not
// in this Hub's registry, so create_instance refuses it). The chain is
// discarded on its Bridge and no conversation is saved.
@(test)
test_create_chat_owner_chain_launch_failure_discards_the_chain :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "owner_prepare_rollback")
	defer mq_http_base_close(f.base)
	@(static) probe: Owner_Prepare_Probe
	probe = {chain = "chain_rollback"}
	f.handlers.prepare_ctx = &probe
	f.handlers.prepare_owner_chain = proc(ctx: rawptr, bridge_id, agent_id, chain_id, title, description: string) -> (string, domain.Domain_Error) {
		p := (^Owner_Prepare_Probe)(ctx)
		sync.atomic_add(&p.calls, 1)
		return p.chain, p.fail
	}
	f.handlers.discard_owner_chain = owner_prepare_probe_discard
	before := list_chat_conversations_count(t, &f)
	body := strings.concatenate({`{"agent_id":"agt_coord","bridge_id":"`, f.base.bridge_id, `","create_owner_chain":true,"initial_message":{"body":"Plan"}}`}, context.temp_allocator)
	failed := create_chat_handler(&f.handlers, mq_http_req(f.base, "/api/v1/chats", body))
	testing.expect(t, failed.status >= 400, "the launch error is returned")
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.discards, 1)
	testing.expect_value(t, probe.discarded, strings.concatenate({f.base.bridge_id, "/chain_rollback"}, context.temp_allocator))
	testing.expect_value(t, list_chat_conversations_count(t, &f), before)
}

@(private = "file")
list_chat_conversations_count :: proc(t: ^testing.T, f: ^MQ_HTTP_Fixture) -> int {
	req := mq_http_req(f.base, "/api/v1/chats", "")
	req.method = "GET"
	listed := list_chats_handler(&f.handlers, req)
	testing.expect_value(t, listed.status, 200)
	return strings.count(listed.body, `"conversation_id"`)
}
