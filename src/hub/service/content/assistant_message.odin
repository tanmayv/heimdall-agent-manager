package content

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import vault "odin_test:lib/vault"

Assistant_Message_Result :: struct {
    message: domain.Chat_Message,
    revision: i64,
    created, changed: bool,
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
    // Content retries retain their original ciphertext across key rotation.
    // The current-epoch floor applies to commands, not historical chat content.
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

// The transaction serializes revision checks and persists message, turn index
// and conversation together. Callers publish invalidations only after success.
upsert_assistant_message :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance: string, input: contracts.ACP_Assistant_Message_Input) -> (Assistant_Message_Result, bool, domain.Domain_Error) {
    if auth.kind != .Instance_Token || instance == "" || auth.agent_instance_id != instance do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
    if !assistant_message_id_valid(input.message_id) || len(input.launch_epoch) == 0 || len(input.launch_epoch) > 256 || len(input.turn_id) == 0 || len(input.turn_id) > 256 || input.revision < 1 do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant turn identity or revision")
    if input.message_status != "pending" && input.message_status != "complete" && input.message_status != "failed" do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant message status")
    // Stop reasons are protocol identifiers, never arbitrary adapter error text.
    if len(input.stop_reason) > 128 do return {}, false, domain.domain_error(.Validation_Failed, "invalid stop reason")
    for ch in input.stop_reason do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') do return {}, false, domain.domain_error(.Validation_Failed, "invalid stop reason")
    if len(input.input_ids) > contracts.ACP_SEND_NOW_MAX_MEMBERS do return {}, false, domain.domain_error(.Validation_Failed, "too many assistant input ids")
    for id in input.input_ids do if !acp_delivery_id_valid(id) do return {}, false, domain.domain_error(.Validation_Failed, "invalid assistant input id")
    if len(input.body) > domain.vault_armored_max_bytes(contracts.ACP_ASSISTANT_MAX_BYTES) do return {}, false, domain.domain_error(.Validation_Failed, "assistant_message_too_large")
    uow, begun, uerr := iface.unit_of_work_begin(s.uow_factory)
    if !begun do return {}, false, uerr
    committed := false
    defer if !committed do iface.unit_of_work_rollback(&uow)
    local := s^
    if uow.repos != nil { local.content = &uow.repos.content; local.agents = &uow.repos.agents }
    c, found, cerr := get_conversation_by_instance(&local, auth, instance)
    if !found do return {}, false, cerr
    inst, exists, ierr := iface.agent_get_instance(local.agents, instance)
    if !exists do return {}, false, ierr
    if string(inst.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Forbidden, "instance owner mismatch")
    if !assistant_envelope_valid(&local, string(c.owner_user_id), input.body) do return {}, false, domain.domain_error(.Validation_Failed, "assistant body must be sealed for the owner vault at a known epoch")
    turn, bound, terr := iface.content_get_assistant_turn(local.content, instance, input.launch_epoch, input.turn_id)
    if terr.code != .None do return {}, false, terr
    canonical, _ := json.marshal(struct{body, status, stop_reason: string}{input.body, input.message_status, input.stop_reason}, allocator=context.temp_allocator)
    digest: [32]byte
    hash.hash_string_to_buffer(.SHA256, string(canonical), digest[:])
    payload_hash := string(hex.encode(digest[:], context.temp_allocator))
    result: Assistant_Message_Result
    if bound {
        if turn.message_id != input.message_id do return {}, false, domain.domain_error(.Conflict, "assistant turn message identity mismatch")
        msg, got, merr := iface.content_get_message(local.content, turn.message_id)
        if !got do return {}, false, merr
        result = {message=msg, revision=turn.revision}
        if input.revision == turn.revision && payload_hash != turn.payload_hash do return {}, false, domain.domain_error(.Conflict, "assistant revision payload mismatch")
        if input.revision <= turn.revision do return result, true, {}
        if msg.message_status != "pending" do return {}, false, domain.domain_error(.Conflict, "assistant terminal status is immutable")
        if inst.launch_epoch != input.launch_epoch && input.message_status != "failed" do return {}, false, domain.domain_error(.Conflict, "stale assistant launch epoch")
    } else {
        if inst.launch_epoch != input.launch_epoch || inst.runtime_transport != "acp" do return {}, false, domain.domain_error(.Conflict, "stale assistant launch epoch")
        if _, collision, lookup_err := iface.content_get_message(local.content, input.message_id); collision || (lookup_err.code != .None && lookup_err.code != .Not_Found) do return {}, false, domain.domain_error(.Conflict, "assistant message identity already exists")
    }
    metadata, _ := json.marshal(struct{acp: struct{turn_id, launch_epoch: string, revision: i64, stop_reason: string}}{acp={input.turn_id,input.launch_epoch,input.revision,input.stop_reason}}, allocator=context.temp_allocator)
    // Causal association: every user input this segment answers (a batch has several).
    if len(input.input_ids) > 0 do metadata, _ = json.marshal(struct{acp: struct{turn_id, launch_epoch: string, revision: i64, stop_reason: string, input_ids: []string}}{acp={input.turn_id,input.launch_epoch,input.revision,input.stop_reason,input.input_ids}}, allocator=context.temp_allocator)
    now := platform.clock_now(s.clock)
    msg := result.message
    if !bound {
        msg = {message_id=input.message_id, conversation_id=c.conversation_id, owner_user_id=c.owner_user_id, direction="agent_to_user", sender_agent_id=c.agent_id, sender_agent_instance_id=instance, body=input.body, artifact_ids_json="[]", message_type="text", message_status=input.message_status, metadata_json=string(metadata), created_at=now}
        saved, ok, err := iface.content_save_message(local.content, msg)
        if !ok do return {}, false, err
        msg = saved
        c.last_message_at = now; c.unread_count += 1
    } else {
        saved, ok, err := iface.content_update_message(local.content,c.owner_user_id,c.conversation_id,msg.message_id,input.body,input.message_status,string(metadata))
        if !ok do return {}, false, err
        msg = saved
    }
    turn = {agent_instance_id=instance,launch_epoch=input.launch_epoch,turn_id=input.turn_id,message_id=input.message_id,revision=input.revision,payload_hash=payload_hash}
    if err := iface.content_save_assistant_turn(local.content, turn); err.code != .None do return {}, false, err
    // Updating an older turn must not replace a newer conversation preview.
    if !bound || c.last_message_at == msg.created_at { c.last_message_preview=input.body; c.updated_at=now }
    if _, ok, err := iface.content_save_conversation(local.content,c); !ok do return {}, false, err
    ok, err := iface.unit_of_work_commit(&uow)
    if !ok do return {}, false, err
    committed = true
    return {message=msg,revision=input.revision,created=!bound,changed=true}, true, {}
}
