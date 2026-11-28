package http

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import vault "odin_test:lib/vault"

Conversation_Write_State :: struct {
	generation: i64,
	enabled: bool,
	instance_id: string,
	denial: domain.Domain_Error,
}
Conversation_Write_Policy :: struct {
	ctx: rawptr,
	read: proc(ctx: rawptr, auth: contracts.Auth_Context, cid: string) -> (Conversation_Write_State, domain.Domain_Error),
}
conversation_write_state :: proc(h: ^Content_Handlers, auth: contracts.Auth_Context, cid: string) -> (Conversation_Write_State, domain.Domain_Error) {
	if h.write_policy.read == nil do return {}, {}
	return h.write_policy.read(h.write_policy.ctx, auth, cid)
}

conversation_control_allowed :: proc(h: ^Content_Handlers, auth: contracts.Auth_Context, cid: string, require_live := false) -> domain.Domain_Error {
	state, err := conversation_write_state(h, auth, cid)
	if err.code != .None do return err
	if state.denial.code != .None do return state.denial
	if state.generation == 0 do return {}
	if !state.enabled do return domain.domain_error(.Conflict, "this conversation is paused")
	if require_live do return conversation_require_live(h.content.agents, state.instance_id)
	return {}
}

// Only a committed winner invokes the ordinary delivery and WebSocket effects.
// Admission, receipt, sealed message, and preview share the same database transaction.
send_generation_message :: proc(h: ^Content_Handlers, auth: contracts.Auth_Context, cid: string, input: content.Message_Input, body: string) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	value, parse_err := json.parse(body, parse_integers=true, allocator=context.temp_allocator)
	obj, object_ok := value.(json.Object)
	key, key_ok := obj["idempotency_key"].(json.String)
	expected, generation_ok := obj["activation_generation"].(json.Integer)
	if parse_err != nil || !object_ok || !key_ok || len(strings.trim_space(string(key))) == 0 || len(key) > 128 || !generation_ok || expected < 1 do return {}, false, domain.domain_error(.Validation_Failed, "a request key and activation generation are required")
	_, _, payload, seal_result := vault.envelope_parse(input.body, context.temp_allocator)
	defer delete(payload, context.temp_allocator)
	if seal_result != .Ok do return {}, false, domain.domain_error(.Validation_Failed, "this conversation requires a vault-sealed message")
	id := content.scoped_message_id("msg_web_", cid, string(key))
	defer delete(id)
	uow, begun, err := iface.unit_of_work_begin(h.content.uow_factory)
	if !begun do return {}, false, err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	state, policy_err := conversation_write_state(h, auth, cid)
	if policy_err.code != .None do return {}, false, policy_err
	if state.denial.code != .None do return {}, false, state.denial
	if state.generation == 0 do return {}, false, domain.domain_error(.Conflict, "conversation identity changed")
	repo := &uow.repos.content
	if repo.claim_message_request == nil do return {}, false, domain.domain_error(.Internal_Error, "chat receipt repository is unavailable")
	inserted, claim_err := repo.claim_message_request(repo.ctx, id)
	if claim_err.code != .None do return {}, false, claim_err
	if !inserted {
		saved, found, get_err := iface.content_get_message(repo, id)
		if !found do return {}, false, get_err
		if saved.conversation_id != cid || string(saved.owner_user_id) != auth.user_id || saved.body != input.body || saved.artifact_ids_json != artifact_json_or_empty(input.artifact_ids_json) do return {}, false, domain.domain_error(.Conflict, "this request key already belongs to another message")
		return saved, false, {}
	}
	if !state.enabled || i64(expected) != state.generation do return {}, false, domain.domain_error(.Conflict, "conversation activation changed; refresh before sending")
	// R7 owns implicit starts and the disposition of stopped input. Until it
	// lands, ordinary controls can explicitly start this instance.
	if live_err := conversation_require_live(&uow.repos.agents, state.instance_id); live_err.code != .None do return {}, false, live_err
	local := h.content^
	local.content = repo
	local.agents = &uow.repos.agents
	m, saved, write_err := content.persist_user_message(&local, auth, cid, input, id)
	if !saved do return {}, false, write_err
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed do return {}, false, commit_err
	m.message_id = strings.clone(id, context.temp_allocator)
	_, _ = content.deliver_user_message(h.content, auth, cid, m)
	return m, true, {}
}

conversation_require_live :: proc(repo: ^iface.Agent_Repository, instance_id: string) -> domain.Domain_Error {
	inst, found, instance_err := iface.agent_get_instance(repo, instance_id)
	defer domain.agent_instance_destroy(&inst)
	if !found do return instance_err
	switch inst.runtime_status {
	case "running", "idle", "busy": return {}
	case: return domain.domain_error(.Conflict, "start the agent and wait until it is running before sending")
	}
}
