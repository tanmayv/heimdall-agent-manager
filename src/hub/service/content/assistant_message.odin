package content

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import vault "odin_test:lib/vault"

// G12: agent output is streamed, not stored. An ACP assistant segment (the
// agent's live text for one turn) is relayed to the owner's UI as a transient
// `agent_output` event and is never written to chat_messages, unread counts,
// conversation previews or acp_assistant_turns. An agent's reply is what it
// sends with `chat send`. A reloaded UI does not see earlier segments.
AGENT_OUTPUT_EVENT_TYPE :: "agent_output"
AGENT_OUTPUT_ASSISTANT_SEGMENT :: "assistant_segment"

Assistant_Segment_Event :: struct {
    type, event, conversation_id, agent_instance_id, message_id, turn_id, launch_epoch: string,
    // text (assistant text) | thought | plan.
    kind: string,
    revision: i64,
    message_status, stop_reason: string,
    input_ids: []string,
    // Sealed for the owner vault; the hub never sees the plaintext.
    body: string,
}

Assistant_Segment_Relay :: struct {
    owner_user_id: string,
    // "" when the segment is accepted but not relayed (a stale launch epoch).
    event_json: string,
}

// The bridge outbox kind of a streamed segment: "" is assistant text.
assistant_segment_kind :: proc(kind: string) -> string {
    switch kind {
    case "", "text": return "text"
    case "thought", "plan": return kind
    }
    return ""
}

assistant_message_id_valid :: proc(id: string) -> bool {
    if len(id) != 20 || !strings.has_prefix(id, "msg_") do return false
    for ch in id[4:] do if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') do return false
    return true
}

assistant_envelope_valid :: proc(s: ^Content_Service, owner, body: string) -> bool {
    vid, epoch, _, parsed := vault.envelope_parse(body, context.temp_allocator)
    if parsed != .Ok do return false
    dir, found, err := iface.vault_get_directory(s.vault_directory, owner)
    // Bridge retries retain their original ciphertext across key rotation.
    // The current-epoch floor applies to commands, not content.
    if !found || err.code != .None || epoch==0 || i64(epoch)>dir.current_epoch do return false
    devices, derr := iface.vault_list_devices(s.vault_directory, owner)
    if derr.code != .None do return false
    for d in devices {
        if d.device_id != dir.root_device_id do continue
        expected, ok := vault.vault_id_from_root_sign_pub(d.sign_public_key)
        return ok && expected == vid
    }
    return false
}

// Validates one segment and renders its transient UI event. Reads only: no
// unit of work, no write. A segment from an older launch epoch is accepted
// (the bridge drops it from its outbox) but not relayed, since its turn is gone.
relay_assistant_segment :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance: string, input: contracts.ACP_Assistant_Message_Input) -> (Assistant_Segment_Relay, bool, domain.Domain_Error) {
    if auth.kind != .Instance_Token || instance == "" || auth.agent_instance_id != instance do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
    if !assistant_message_id_valid(input.message_id) || len(input.launch_epoch) == 0 || len(input.launch_epoch) > 256 || len(input.turn_id) == 0 || len(input.turn_id) > 256 || input.revision < 1 do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant turn identity or revision")
    kind := assistant_segment_kind(input.kind)
    if kind == "" do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant segment kind")
    if input.message_status != "pending" && input.message_status != "complete" && input.message_status != "failed" do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant message status")
    // Stop reasons are protocol identifiers, never arbitrary adapter error text.
    if len(input.stop_reason) > 128 do return {}, false, domain.domain_error(.Validation_Failed, "invalid stop reason")
    for ch in input.stop_reason do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') do return {}, false, domain.domain_error(.Validation_Failed, "invalid stop reason")
    if len(input.input_ids) > contracts.ACP_SEND_NOW_MAX_MEMBERS do return {}, false, domain.domain_error(.Validation_Failed, "too many assistant input ids")
    for id in input.input_ids do if !acp_delivery_id_valid(id) do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant input id")
    if len(input.body) > domain.vault_armored_max_bytes(contracts.ACP_ASSISTANT_MAX_BYTES) do return {}, false, domain.domain_error(.Validation_Failed, "assistant_message_too_large")
    c, found, cerr := get_conversation_by_instance(s, auth, instance)
    if !found do return {}, false, cerr
    inst, exists, ierr := iface.agent_get_instance(s.agents, instance)
    if !exists do return {}, false, ierr
    if string(inst.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Forbidden, "instance owner mismatch")
    if inst.runtime_transport != "acp" do return {}, false, domain.domain_error(.Conflict, "assistant segments require an ACP instance")
    if !assistant_envelope_valid(s, string(c.owner_user_id), input.body) do return {}, false, domain.domain_error(.Validation_Failed, "assistant body must be sealed for the owner vault at a known epoch")
    relay := Assistant_Segment_Relay{owner_user_id=string(c.owner_user_id)}
    if inst.launch_epoch != input.launch_epoch do return relay, true, {}
    event := Assistant_Segment_Event{type=AGENT_OUTPUT_EVENT_TYPE, event=AGENT_OUTPUT_ASSISTANT_SEGMENT, kind=kind, conversation_id=c.conversation_id, agent_instance_id=instance, message_id=input.message_id, turn_id=input.turn_id, launch_epoch=input.launch_epoch, revision=input.revision, message_status=input.message_status, stop_reason=input.stop_reason, input_ids=input.input_ids, body=input.body}
    raw, merr := json.marshal(event, allocator=context.temp_allocator)
    if merr != nil do return {}, false, domain.domain_error(.Internal_Error, "assistant segment could not be encoded")
    relay.event_json = string(raw)
    return relay, true, {}
}
