package contracts

import "core:encoding/json"
import "core:crypto/sha2"
import "core:fmt"
import "core:strconv"
import "core:strings"
import vault "odin_test:lib/vault"

// task.hold is a dispatch overlay: live capabilities retain authority and TTL.
// Current holders may heartbeat, submit/vote or checkpoint. No fresh work/review
// capability is issued while held; gates settle only after task.release.
// Retained event content records this marker so older revoke-on-hold evidence
// remains explicitly incomplete rather than acquiring fabricated semantics.
OWNER_HOLD_SEMANTICS :: "live_lease_v1"

// Minimal owner-local v1. Decimal strings preserve SQLite i64 across JS.
// Raw envelope input is bounded before allocation. Bodies travel separately,
// sealed end-to-end; payload_digest binds their exact UTF-8 transport bytes.
OWNER_DOCUMENT_MAX :: 256 * 1024
OWNER_REQUEST_TTL_MS :: 300000
Owner_Field :: struct { name, kind: string }

owner_string :: proc(o: json.Object, field: string) -> string {
    s, _ := o[field].(json.String)
    return string(s)
}

owner_ascii :: proc(s: string) -> bool {
    for b in s do if b < 0x20 || b > 0x7e do return false
    return true
}

owner_hex :: proc(s: string, n: int) -> bool {
    if len(s) != n do return false
    for b in s do if !(b >= '0' && b <= '9' || b >= 'a' && b <= 'f') do return false
    return true
}

owner_method_valid :: proc(s: string) -> bool {
    switch s {
    case "native.history.import", "native.history.read", "native.history.fetch", "attempt.read", "history.read", "history.fetch", "context.read", "grant.set", "grant.revoke", "grant.read", "grant.policy", "grant.recover", "workflow.coordinator", "workflow.cancel", "workflow.gate", "workflow.define", "workflow.run", "workflow.retry", "workflow.read", "source.observe", "source.consume", "source.ack", "source.retire", "source.resolve", "source.escalate", "source.read", "dependency.edit", "review.roles", "task.hold", "task.release", "task.cancel", "task.reopen", "task.resolve", "merge.retry", "submission.read", "chain.edit", "task.edit", "task.delete", "chain.search", "chain.create", "task.create", "task.comment", "chain.read", "task.read", "receipt.read", "fleet.edit", "runtime.read", "lifecycle.configure", "requirements.edit", "review.post": return true
    }
    return false
}

owner_field_valid :: proc(s, kind: string) -> bool {
    if kind=="document" || kind=="optional_document" do return len(s)<=OWNER_DOCUMENT_MAX && (s!="" || kind=="optional_document")
    if !owner_ascii(s) do return false
    switch kind {
    case "id", "optional":
        if s == "" do return kind == "optional"
        if len(s) > 160 do return false
        for b in s do if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '-' || b == '.' || b == ':') do return false
        return true
    case "version": return s == "1"
    case "counter", "positive": return owner_decimal_valid(s) && (kind == "counter" || s != "0")
    case "native_history_kind": return s=="attempt" || s=="event" || s=="facet"
    case "native_cursor": return len(s)<=512
    case "native_actor": return s=="agent" || s=="user" || s=="hub" || s=="bridge"
    case "native_event_actor": return s=="agent" || s=="user" || s=="hub" || s=="bridge" || s=="coordinator"
    case "facet_kind": return s=="handoff" || s=="vcs" || s=="verify" || s=="output" || s=="runtime" || s=="artifacts" || s=="placement"
    case "optional_counter": return s=="" || owner_decimal_valid(s)
    case "attempt_outcome": return s=="" || s=="handoff" || s=="submitted" || s=="blocked" || s=="expired" || s=="expired:ttl" || s=="expired:hard_cap" || s=="expired:cancelled" || s=="expired:replaced" || s=="expired:chain_closed"
    case "hash": return owner_hex(s, 64)
    case "signature": return owner_hex(s, 128)
    case "method": return owner_method_valid(s)
    case "lease_method": return s=="lease.claim" || s=="lease.heartbeat"
    case "coordinator_methods": return s=="workflow.gate.post"
    case "lease_methods": return s=="lease.claim,lease.heartbeat,requirements.present,requirements.ack,lease.submit,lease.handoff,lease.block,lease.switch" || s=="review.role.post,review.checkpoint" || s=="review.post,review.checkpoint" || s=="lease.claim,lease.heartbeat" || s=="lease.claim,lease.heartbeat,requirements.present,requirements.ack,lease.submit" || s=="review.post"
    case "lifecycle_method": return s=="workflow.gate.post" || s=="review.role.open" || s=="review.role.post" || s=="lease.handoff" || s=="lease.block" || s=="lease.switch" || s=="review.checkpoint" || s=="requirements.present" || s=="requirements.ack" || s=="lease.submit" || s=="review.open" || s=="review.post"
    case "merge_policy": return s=="none" || s=="git"
    case "verdict": return s=="approve" || s=="request_changes"
    case "history_completeness": return s=="full" || s=="incomplete"
    case "attempt_release": return s=="" || s=="handoff" || s=="submitted" || s=="blocked" || s=="expired" || s=="changes_requested" || s=="replaced" || s=="dep_added" || s=="reopened" || s=="user_stopped" || s=="released_noncounting"
    case "path": return len(s)<=4096 && (s=="" || (s[0]=='/' && !strings.contains(s,"..") && !strings.contains(s,"\\")))
    case "optional_commit": return s=="" || owner_hex(s,40) || owner_hex(s,64)
    case "optional_ref":
        if s=="" do return true
        if len(s)>160 || s[0]=='-' || strings.contains(s,"..") || strings.contains(s,"//") do return false
        for b in s do if !(b>='a' && b<='z' || b>='A' && b<='Z' || b>='0' && b<='9' || b=='_' || b=='-' || b=='.' || b=='/') do return false
        return true
    case "flag": return s == "0" || s == "1"
    case "relay_cipher":
        if len(s)>196608 do return false
        _,_,_,result:=vault.envelope_parse(s,context.temp_allocator)
        return result==.Ok
    case "cipher", "required_cipher":
        if s == "" do return kind == "cipher"
        if len(s) > 65536 do return false
        _, _, _, result := vault.envelope_parse(s, context.temp_allocator)
        return result == .Ok
    case "result_code": return s == "ok" || s == "retired"
    case "error_code":
        switch s {
        case "malformed", "bad_signature", "invalid_scope", "owner_mismatch",
             "digest_mismatch", "operation_conflict", "expired", "retired",
             "stale_revision", "owner_unavailable", "retention_capacity",
             "storage_error", "invalid_content", "clock_uncertain", "stale_cursor": return true
        }
    }
    return false
}

owner_document_valid :: proc(kind: string, o: json.Object) -> bool {
    if kind=="submit_payload" && "output" in o do return owner_document_valid("submit_output_payload",o)
    schema := owner_schema(kind)
    if len(schema) == 0 || len(o) != len(schema) do return false
    for f in schema {
        value, exists := o[f.name]
        s, is_string := value.(json.String)
        if !exists || !is_string || !owner_field_valid(string(s), f.kind) do return false
    }
    if kind == "command" {
        method, task := owner_string(o, "method"), owner_string(o, "task_id")
        if (method == "native.history.import" || method == "native.history.read" || method == "native.history.fetch" || method == "attempt.read" || method == "dependency.edit" || method == "review.roles" || method == "task.hold" || method == "task.release" || method == "task.cancel" || method == "task.reopen" || method == "task.resolve" || method == "merge.retry" || method == "submission.read" || method == "task.edit" || method == "task.delete" || method == "task.create" || method == "task.comment" || method == "task.read" || method == "fleet.edit" || method == "runtime.read" || method == "lifecycle.configure" || method == "requirements.edit" || method == "review.post") != (task != "") do return false
    }
    if kind=="native_attempt" {
        ended,outcome:=owner_string(o,"ended_ms"),owner_string(o,"outcome")
        if (ended=="") != (outcome=="") do return false
        if ended!="" {
            start,_:=strconv.parse_i64(owner_string(o,"started_ms"));end,_:=strconv.parse_i64(ended)
            if end<start do return false
        }
    }
    // Placement diagnostics can precede the first work grant. This is an
    // archival facet identity, never a zero-numbered logical work attempt.
    if kind=="native_history_facet" && owner_string(o,"attempt_no")=="0" && owner_string(o,"kind")!="placement" do return false
    if kind == "registry" && owner_string(o, "deleted") == "0" {
        if owner_string(o, "task_id") == "" {
            if owner_string(o, "chain_title_cipher") == "" || owner_string(o, "chain_description_cipher") == "" || owner_string(o, "task_title_cipher") != "" do return false
        } else {
            if owner_string(o, "task_title_cipher") == "" || owner_string(o, "chain_title_cipher") != "" || owner_string(o, "chain_description_cipher") != "" do return false
        }
    }
    if kind == "registry" && owner_string(o, "deleted") == "1" {
        if owner_string(o, "chain_title_cipher") != "" || owner_string(o, "chain_description_cipher") != "" || owner_string(o, "task_title_cipher") != "" do return false
    }
    if kind == "receipt" && owner_string(o, "result_code") == "retired" && owner_string(o, "result_cipher") != "" do return false
    if kind=="capability" {
        expires,_:=strconv.parse_i64(owner_string(o,"expires_ms"))
        hard,_:=strconv.parse_i64(owner_string(o,"hard_ms"))
        if expires>hard do return false
    }
    if kind=="lease_input" && ((owner_string(o,"method")=="lease.claim") != (owner_string(o,"capability")=="")) do return false
    if kind == "read_payload" || kind=="native_history_read" {
        limit, _ := strconv.parse_i64(owner_string(o, "limit"))
        if limit > 100 do return false
    }
    return true
}

owner_payload_kind :: proc(method: string) -> string {
    switch method {
    case "workflow.coordinator": return "coordinator_payload"
    case "workflow.gate.post": return "workflow_gate"
    case "workflow.cancel", "workflow.gate", "workflow.define", "workflow.run", "workflow.retry", "source.observe", "source.consume", "source.ack", "source.retire", "source.resolve", "source.escalate", "review.roles": return "control_payload"
    case "workflow.read", "source.read": return "read_payload"
    case "dependency.edit": return "dependency_payload"
    case "review.role.open", "review.role.post": return "review_role_payload"
    case "grant.set", "grant.recover": return "grant_payload"
    case "grant.revoke": return "grant_revoke_payload"
    case "grant.policy": return "grant_policy_payload"
    case "grant.read": return "read_payload"
    case "chain.create": return "chain_create_payload"
    case "task.create", "task.edit": return "task_create_payload"
    case "submission.read": return "submission_read_payload"
    case "chain.edit": return "chain_edit_payload"
    case "task.delete": return "delete_payload"
    case "chain.search": return "search_payload"
    case "task.comment": return "comment_payload"
    case "fleet.edit": return "fleet_payload"
    case "task.hold", "task.release", "task.cancel", "task.reopen", "task.resolve": return "control_payload"
    case "lease.handoff": return "handoff_payload"
    case "lease.block": return "block_payload"
    case "lease.switch": return "switch_payload"
    case "review.checkpoint": return "checkpoint_payload"
    case "merge.retry": return "merge_retry_payload"
    case "lifecycle.configure": return "lifecycle_config_payload"
    case "requirements.edit": return "requirements_payload"
    case "requirements.present", "requirements.ack": return "ack_payload"
    case "lease.submit": return "submit_payload"
    case "review.open", "review.post": return "review_payload"
    case "native.history.import": return "native_import_payload"
    case "native.history.read": return "native_history_read"
    case "native.history.fetch": return "native_history_fetch"
    case "attempt.read": return "attempt_read_payload"
    case "history.fetch": return "history_fetch_payload"
    case "history.read", "context.read", "chain.read", "task.read", "runtime.read": return "read_payload"
    case "receipt.read": return "receipt_payload"
    }
    return ""
}

// Returned tree and decoded strings use context.temp_allocator. Callers retaining
// them across request boundaries must clone; always parse ORIGINAL untrusted bytes.
owner_parse :: proc(raw, kind: string) -> (json.Object, bool) {
    if len(raw) > OWNER_DOCUMENT_MAX do return nil, false
    v, ok := owner_request_document(raw)
    o, is_object := v.(json.Object)
    if !ok || !is_object || !owner_document_valid(kind, o) do return nil, false
    return o, true
}

// Length-prefixed ASCII netstrings, in schema order, with kind-specific domain.
// Signatures are detached and omitted; all other fields (including key IDs) bind.
// No JSON serialization, escaping, map iteration or float formatting affects bytes.
owner_canonical :: proc(kind: string, o: json.Object) -> (string, bool) {
    if kind=="submit_payload" && "output" in o do return owner_canonical("submit_output_payload",o)
    if !owner_document_valid(kind, o) do return "", false
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, fmt.tprintf("heimdall-owner-local/%s/v1\n", kind))
    for f in owner_schema(kind) {
        if f.kind == "signature" do continue
        s := owner_string(o, f.name)
        strings.write_string(&b, fmt.tprintf("%d:%s,", len(s), s))
    }
    return strings.to_string(b), true
}

owner_digest :: proc(kind: string, o: json.Object) -> (string, bool) {
    s, ok := owner_canonical(kind, o)
    if !ok do return "", false
    return owner_payload_digest(s), true
}

// These records are TRUSTED INPUT from current enrolled directory verification and
// local grant storage, never deserialized from an envelope or granted by a vault key.
// This verifier remains device-only. Local agent commands use the separate
// lease_command/capability domains and require Bridge-authenticated child facts.
Owner_Verified_Key :: struct {
    account_id, principal_id, key_id, public_key: string,
    kind: string, // "device" or "bridge"; never "content"
    enrolled, revoked: bool,
}
Owner_Read_Grant :: struct {
    account_id, owner_bridge_id, chain_id, principal_id, key_id: string,
    task_id, method: string, // empty task = entire chain; method always exact
    revision, expires_ms: i64,
    can_read, can_mutate, revoked: bool,
}
Owner_Auth_Error :: enum {
    None, Malformed, Bad_Signature, Invalid_Scope, Owner_Mismatch,
    Digest_Mismatch, Expired, Stale_Revision,
}

owner_verify_signature :: proc(kind: string, o: json.Object, signature_field: string, key: Owner_Verified_Key) -> bool {
    if !key.enrolled || key.revoked || (key.kind != "device" && key.kind != "bridge") do return false
    canonical, ok := owner_canonical(kind, o)
    if !ok do return false
    sig, sig_ok := vault.signature_text_from_parts("ecdsa-p256-sha256", owner_string(o, signature_field), context.temp_allocator)
    return sig_ok && vault.verify("ecdsa-p256-sha256", key.public_key, transmute([]byte)canonical, sig)
}

// Authenticate immutable genesis against the recipient's enrolled identity AND an
// approved creating device. Persistence must insert once and reject conflicting
// genesis digests; validation alone does not make a mutable DB record immutable.
owner_verify_genesis :: proc(o: json.Object, account, recipient_bridge: string, creator, owner: Owner_Verified_Key) -> Owner_Auth_Error {
    if !owner_document_valid("genesis", o) do return .Malformed
    if owner_string(o, "account_id") != account || creator.account_id != account || owner.account_id != account do return .Invalid_Scope
    if owner_string(o, "owner_bridge_id") != recipient_bridge || owner.principal_id != recipient_bridge do return .Owner_Mismatch
    if creator.kind != "device" || owner.kind != "bridge" ||
       creator.principal_id != owner_string(o, "creator_id") || creator.key_id != owner_string(o, "creator_key_id") ||
       owner.key_id != owner_string(o, "owner_key_id") { return .Invalid_Scope }
    if !owner_verify_signature("genesis", o, "creator_signature", creator) ||
       !owner_verify_signature("genesis", o, "owner_signature", owner) { return .Bad_Signature }
    return .None
}

// Run before receipt lookup and RECHECK grant inside the owner transaction.
// Deliberately does NOT check request expiry, mutation right or expected revision:
// historical read-authorized replay survives release/expiry without new effects.
owner_authenticate_command :: proc(o: json.Object, payload: string, key: Owner_Verified_Key, grant: Owner_Read_Grant, now_ms: i64) -> Owner_Auth_Error {
    if !owner_document_valid("command", o) || len(payload) > OWNER_DOCUMENT_MAX do return .Malformed
    if now_ms < 0 || grant.revision < 1 || grant.expires_ms <= now_ms || grant.revoked || !grant.can_read do return .Invalid_Scope
    if owner_string(o, "account_id") != grant.account_id || key.account_id != grant.account_id ||
       owner_string(o, "chain_id") != grant.chain_id || owner_string(o, "principal_id") != grant.principal_id ||
       key.principal_id != grant.principal_id || owner_string(o, "key_id") != grant.key_id || key.key_id != grant.key_id ||
       owner_string(o, "method") != grant.method || (grant.task_id != "" && owner_string(o, "task_id") != grant.task_id) ||
       key.kind != "device" { return .Invalid_Scope }
    if owner_string(o, "immutable_owner_bridge") != grant.owner_bridge_id do return .Owner_Mismatch
    if !owner_verify_signature("command", o, "signature", key) do return .Bad_Signature
    if owner_payload_digest(payload) != owner_string(o, "payload_digest") do return .Digest_Mismatch
    if _, ok := owner_parse(payload, owner_payload_kind(owner_string(o, "method"))); !ok do return .Malformed
    return .None
}

// Only AFTER a receipt miss, inside the transaction, using the same current grant.
// Canonical digest comparison/tombstones must precede this check in the caller.
owner_live_admit :: proc(o: json.Object, grant: Owner_Read_Grant, now_ms, current_revision: i64) -> Owner_Auth_Error {
    if !owner_document_valid("command", o) do return .Malformed
    if now_ms < 0 || !grant.can_read || grant.revoked || grant.revision < 1 || grant.expires_ms <= now_ms do return .Invalid_Scope
    if owner_string(o, "account_id") != grant.account_id || owner_string(o, "chain_id") != grant.chain_id ||
       owner_string(o, "principal_id") != grant.principal_id || owner_string(o, "key_id") != grant.key_id ||
       owner_string(o, "method") != grant.method || (grant.task_id != "" && owner_string(o, "task_id") != grant.task_id) { return .Invalid_Scope }
    if owner_string(o, "immutable_owner_bridge") != grant.owner_bridge_id do return .Owner_Mismatch
    expires, _ := strconv.parse_i64(owner_string(o, "request_expires_ms"))
    if expires <= now_ms || expires - now_ms > OWNER_REQUEST_TTL_MS do return .Expired
    method := owner_string(o, "method")
    read := method == "native.history.read" || method == "native.history.fetch" || method == "attempt.read" || method == "history.read" || method == "history.fetch" || method == "context.read" || method == "grant.read" || method == "workflow.read" || method == "source.read" || method == "submission.read" || method == "chain.search" || method == "chain.read" || method == "task.read" || method == "receipt.read" || method == "runtime.read"
    if !read && !grant.can_mutate do return .Invalid_Scope
    expected, _ := strconv.parse_i64(owner_string(o, "expected_revision"))
    if current_revision < 0 do return .Stale_Revision
    if read && expected == 0 do return .None // initial read; response supplies its revision
    if expected != current_revision do return .Stale_Revision
    return .None
}

owner_payload_digest :: proc(payload: string) -> string {
    digest: [32]byte
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, transmute([]byte)payload)
    sha2.final(&ctx, digest[:])
    return vault.hex_encode_lower(digest[:], context.temp_allocator)
}

// Registry receiver supplies the pinned immutable genesis digest. Ordered metadata
// CAS/tombstones belong to storage; this helper authenticates only its allowlist.
owner_verify_registry :: proc(o: json.Object, account, bridge, genesis_digest: string, key: Owner_Verified_Key) -> Owner_Auth_Error {
    if !owner_document_valid("registry", o) do return .Malformed
    if key.kind != "bridge" || key.account_id != account || owner_string(o, "account_id") != account ||
       key.key_id != owner_string(o, "key_id") { return .Invalid_Scope }
    if key.principal_id != bridge || owner_string(o, "owner_bridge_id") != bridge { return .Owner_Mismatch }
    if owner_string(o, "genesis_digest") != genesis_digest do return .Digest_Mismatch
    if !owner_verify_signature("registry", o, "signature", key) do return .Bad_Signature
    return .None
}

// Creation must bind the separately authenticated genesis to this exact command
// and payload; storage still atomically inserts genesis, state, receipt and outbox.
owner_create_binding :: proc(command, genesis: json.Object, payload: string) -> bool {
    if !owner_document_valid("command", command) || !owner_document_valid("genesis", genesis) do return false
    if owner_string(command, "method") != "chain.create" do return false
    for pair in ([6][2]string{
        {"account_id", "account_id"}, {"chain_id", "chain_id"},
        {"immutable_owner_bridge", "owner_bridge_id"}, {"principal_id", "creator_id"},
        {"key_id", "creator_key_id"}, {"operation_id", "creation_op"},
    }) {
        if owner_string(command, pair[0]) != owner_string(genesis, pair[1]) do return false
    }
    p, ok := owner_parse(payload, "chain_create_payload")
    digest, valid := owner_digest("genesis", genesis)
    return ok && valid && owner_string(p, "genesis_digest") == digest && owner_payload_digest(payload) == owner_string(command, "payload_digest")
}

owner_auth_error_code :: proc(err: Owner_Auth_Error) -> string {
    switch err {
    case .None: return ""
    case .Malformed: return "malformed"
    case .Bad_Signature: return "bad_signature"
    case .Invalid_Scope: return "invalid_scope"
    case .Owner_Mismatch: return "owner_mismatch"
    case .Digest_Mismatch: return "digest_mismatch"
    case .Expired: return "expired"
    case .Stale_Revision: return "stale_revision"
    }
    return "malformed"
}
