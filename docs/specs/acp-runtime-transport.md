# Per-provider runtime transport and Claude ACP MVP

This specification adds ACP (Agent Client Protocol) beside PTY execution. The Hub selects a transport per provider per bridge; `ham-pty-host` owns either the existing PTY child or a new child with pipes. The Bridge drives ACP v1, translates events into existing Heimdall surfaces, and streams natural assistant text into durable chat. Coordination remains `./bin/ham-ctl`. Claude keeps `pty` as its catalog default until the real-device acceptance passes.

Status: implementation specification, 2026-11-18. Approved inputs: [plan](artifact://art_18e9124cfc75a9c2), [comparison](artifact://art_18e8badae3e44864), and subsequent chain decisions. Those decisions supersede the plan's deferrals of piped hosting, streaming, adapter status, and login fallback. This document specifies proposed changes; it does not assert they already exist. Existing-source references were read at `7ccd2d909c34e2c6c0d985adeba40d2a4e06442f`; paths and line numbers below are relative to that repository revision.

## 1. Scope and requirements

| ID | Scope | Required behavior | Contract |
| --- | --- | --- | --- |
| REQ-ACP-1 | MVP | Catalog declares supported transports, default and pinned ACP recipe | §3 |
| REQ-ACP-2 | MVP | One override per bridge/provider; profiles inherit it | §3–4 |
| REQ-ACP-3 | MVP | Hub resolves and freezes effective transport in each launch | §4 |
| REQ-ACP-4 | MVP | Settings Runtime control and structured-runtime pane | §11 |
| REQ-ACP-5 | MVP | Bidirectional JSON-RPC client with newline framing and deadlines | §6 |
| REQ-ACP-6 | MVP | ACP launch lifecycle through daemon-owned pipes | §5, §7 |
| REQ-ACP-7 | MVP | Deliver, interrupt, stop, readiness, activity and exit parity | §7 |
| REQ-ACP-8 | MVP | Tool/diff/activity translation and existing permission relay | §8 |
| REQ-ACP-9 | MVP | Direct input prompts and assistant chunk streaming | §9 |
| REQ-ACP-10 | MVP | Piped children survive Bridge restart; reattach and recover sessions | §5, §7 |
| REQ-ACP-11 | Deferred | ACP model discovery for the catalog/picker via configOptions | Existing discovery remains; §7 only uses options for the selected launch model |
| REQ-ACP-12 | MVP | Apply explicit launch model through session/set_config_option | §7 |
| REQ-ACP-13 | MVP | Adapter installation, version, Node and error status | §10–11 |
| REQ-ACP-14 | MVP | Auth blocker offers a PTY login shell and explicit retry | §10 |
| REQ-ACP-15 | MVP | Exact adapter package/version in Bridge-managed installation | §3, §10 |
| REQ-ACP-16 | MVP | Same bootstrap run dir and ham-ctl; CLAUDE.md parity test/fallback | §7, §12 |

No MCP implementation, ACP `terminal/*` proxy, second provider adapter, or replacement for shell sessions is included. Do not advertise client terminal or filesystem capabilities. The Claude adapter uses its own tools. Existing PTY providers and the PTY path retain their behavior. Deferred REQ-ACP-11 does not defer model selection at launch.

## 2. Verified integration points

| Existing contract | Verified source |
| --- | --- |
| Catalog domain object stores JSON strings; Bridge has a typed catalog mirror | `src/hub/domain/provider.odin:12`; `src/bridge/provider_catalog_cache.odin:20` |
| Settings are now keyed by bridge/profile, not bridge/provider | `src/hub/repository/sqlite/migrations/169_provider_profiles.sql:27`; `src/hub/repository/sqlite/provider_repo_sqlite.odin:59` |
| PUT requires enabled today and supports profile_id | `src/hub/transport/http/provider_handlers.odin:385` |
| Provider view derives enablement from profile/presence, then explicit settings | `src/hub/service/provider/provider_service.odin:399` |
| Catalog body is canonical input to its ETag | `src/hub/service/provider/provider_service.odin:243`; `src/hub/service/provider/provider_service.odin:330` |
| Launch payload carries provider, profile, model, permission mode and launch epoch | `src/hub/service/agent/agent_service.odin:1750` |
| Bridge launch record is currently in-memory; instance state includes readiness and process liveness | `src/bridge/hub_runtime_client.odin:117`; `src/bridge/hub_runtime_client.odin:146` |
| Current host calls openpty; kind is explicitly a passthrough label | `tools/pty_host/src/host.rs:102`; `tools/pty_host/src/dproto.rs:79` |
| Host protocol has List, Attach, Input and lifecycle/heartbeat events | `tools/pty_host/src/dproto.rs:301`; `tools/pty_host/src/dproto.rs:338` |
| Current reconcile preserves live daemon children and reaps stopped ones | `src/bridge/agent_reconcile.odin:155` |
| Bootstrap materialization cleans run_dir; Claude defaults to CLAUDE.md; shim is generated | `src/bridge/bootstrap_prespawn.odin:36`; `src/bridge/bootstrap_service.odin:143`; `src/bridge/bootstrap_service.odin:227` |
| Extension event kinds and ingest already exist | `src/contracts/extension.odin:44`; `src/bridge/extension_ingest.odin:90` |
| Permission core waits on allow/deny/none; none means no decision | `src/bridge/extension_permission.odin:118` |
| Assistant send action authenticates instance and emits fetchable chat_updated | `src/hub/transport/http/agent_action_handlers.odin:232`; `src/hub/transport/http/agent_action_handlers.odin:285` |
| Message repository can update body/status/metadata in place | `src/hub/repository/iface/content_repo.odin:13` |
| CLI seals chat before forwarding; Hub stores supplied body; Bridge already has vault open/seal helpers | `src/ctl/agent_mode.odin:1534`; `src/hub/service/content/content_service.odin:252`; `src/bridge/vault_decrypt.odin:40`; `src/bridge/vault_decrypt.odin:59` |
| UI handles fetch-required chat events through message invalidation | `src/ui/api/wsInvalidation.ts:637` |
| Provider API mirrors and terminal pane require new fields/branch | `src/ui/components/providers/providerSetupApi.ts:10`; `src/ui/components/chat/AgentPaneComposerPanel.tsx:49` |
| Last embedded migration is 210 | `src/hub/repository/sqlite/migrations.odin:666` |

## 3. Storage, catalog and Odin contracts

### 3.1 Migration 211_provider_transport.sql

Use this SQL, registered in the embedded constant, ordered filename list and load dispatch in `migrations.odin`. The canonical settings row has `profile_id=provider`. Only that row may hold transport. Adding a custom profile must not create another transport choice. Preserve per-profile `enabled` and all existing keys.

```sql
ALTER TABLE provider_catalog ADD COLUMN transports TEXT NOT NULL DEFAULT '["pty"]'
  CHECK (json_valid(transports) AND json_type(transports) = 'array'
         AND json_array_length(transports) BETWEEN 1 AND 2);
ALTER TABLE provider_catalog ADD COLUMN default_transport TEXT NOT NULL DEFAULT 'pty'
  CHECK (default_transport IN ('pty','acp'));
ALTER TABLE provider_catalog ADD COLUMN acp_recipe TEXT DEFAULT NULL
  CHECK (acp_recipe IS NULL OR
         (json_valid(acp_recipe) AND json_type(acp_recipe) = 'object'));
ALTER TABLE bridge_provider_settings ADD COLUMN transport TEXT DEFAULT NULL
  CHECK (transport IS NULL OR
         (transport IN ('pty','acp') AND profile_id = provider));
ALTER TABLE bridge_provider_status ADD COLUMN acp_adapter TEXT DEFAULT NULL
  CHECK (acp_adapter IS NULL OR
         (json_valid(acp_adapter) AND json_type(acp_adapter) = 'object'));
ALTER TABLE agent_instances ADD COLUMN runtime_transport TEXT NOT NULL DEFAULT 'pty'
  CHECK (runtime_transport IN ('pty','acp'));

CREATE TRIGGER provider_transport_insert BEFORE INSERT ON provider_catalog
BEGIN
  SELECT CASE WHEN
    EXISTS (SELECT 1 FROM json_each(NEW.transports)
            WHERE type <> 'text' OR value NOT IN ('pty','acp'))
    OR (SELECT count(*) FROM json_each(NEW.transports)) <>
       (SELECT count(DISTINCT value) FROM json_each(NEW.transports))
    OR NOT EXISTS (SELECT 1 FROM json_each(NEW.transports)
                   WHERE value = NEW.default_transport)
    OR (EXISTS (SELECT 1 FROM json_each(NEW.transports) WHERE value='acp')
        AND NEW.acp_recipe IS NULL)
  THEN RAISE(ABORT, 'invalid provider transport contract') END;
END;
CREATE TRIGGER provider_transport_update
BEFORE UPDATE OF transports, default_transport, acp_recipe ON provider_catalog
BEGIN
  SELECT CASE WHEN
    EXISTS (SELECT 1 FROM json_each(NEW.transports)
            WHERE type <> 'text' OR value NOT IN ('pty','acp'))
    OR (SELECT count(*) FROM json_each(NEW.transports)) <>
       (SELECT count(DISTINCT value) FROM json_each(NEW.transports))
    OR NOT EXISTS (SELECT 1 FROM json_each(NEW.transports)
                   WHERE value = NEW.default_transport)
    OR (EXISTS (SELECT 1 FROM json_each(NEW.transports) WHERE value='acp')
        AND NEW.acp_recipe IS NULL)
  THEN RAISE(ABORT, 'invalid provider transport contract') END;
END;

UPDATE provider_catalog SET
  transports='["pty","acp"]', default_transport='pty',
  acp_recipe='{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}'
WHERE provider='claude';
```

The SQL enforces storage shape/membership; service and Bridge validators enforce the complete recipe: command exactly the installed package bin, args string array, env string map, protocol_version exactly integer 1, known package, exact semver (no ranges/tags), nonempty version. Never execute an arbitrary command received from a provider status report. The catalog owns recipes. Invalid JSON, unsupported default, duplicate transports and an ACP provider without a recipe must fail migration/repository tests. No default flip is part of 211; a follow-up migration after §12 passes sets Claude's default to `acp`.

`runtime_transport` is a launch snapshot, not a user override. Add it to Agent_Instance repository read/write/cloning/destruction, instance JSON, launch preparation, reconfiguration and wake serialization. Existing rows become `pty`. Live settings changes do not relabel a running instance. Recompute the snapshot only for a new launch epoch, including explicit restart/move. Preserve it for command retries in that epoch.

### 3.2 Domain and wire fields

Add owned strings and destruction paths to the existing domain types:

```odin
// Provider_Catalog_Entry additions (SQL JSON kept raw like existing args):
transports_json: string,    // '["pty"]' for old/absent catalog fields
default_transport: string, // "pty" | "acp"
acp_recipe_json: string,    // "" means SQL NULL, wire null
// Bridge_Provider_Setting addition:
transport: string,         // "" means SQL NULL; meaningful on canonical row only
// Bridge_Provider_Status addition:
acp_adapter_json: string,  // "" means unknown/null
// Agent_Instance addition:
runtime_transport: string, // persisted launch snapshot
```

Extend `PROVIDER_SELECT` after its current 18 columns and parse indices 18–20 as transports/default/recipe; extend settings SELECT/UPSERT with nullable binding for transport. Enable-only updates MUST preserve the stored transport, rather than writing an empty value from a zero-initialized struct. Add repository operations `get_provider_transport(bridge_id,provider)` and `set_provider_transport(bridge_id,provider,transport,now)` in iface/sqlite. The latter updates the canonical row only. If no row exists, first materialize its current effective `enabled` from the view within the same unit of work; do not accidentally disable an implicitly enabled provider by inserting `enabled=0`.

Catalog JSON adds `transports`, `default_transport`, `acp_recipe` with arrays/objects/null, not encoded JSON strings. Include all three in `write_catalog_entry_json`/`catalog_body_json` so the body hash changes. Bridge cache owns deep copies including recipe env; validate before replacing the last good snapshot. Typed Bridge additions:

```odin
Bridge_ACP_Recipe :: struct {
    command: string `json:"command"`,
    args: []string `json:"args"`,
    env: map[string]string `json:"env"`,
    protocol_version: int `json:"protocol_version"`,
    adapter_package: string `json:"adapter_package"`,
    adapter_version: string `json:"adapter_version"`,
}
// Bridge_Catalog_Provider:
transports: []string `json:"transports"`,
default_transport: string `json:"default_transport"`,
acp_recipe: Bridge_ACP_Recipe `json:"acp_recipe"`,
```

Use `json.Value` for nullable serialized fields and a presence/type parse for mutation fields; ordinary pointer fields are not the nullable wire contract. Missing catalog additions normalize to PTY-only. Recipe is unused on PTY launches.

## 4. Hub selection and HTTP API

### 4.1 PUT /api/v1/bridges/:id/providers/:provider

Continue owner checks from `provider_owned_bridge`. Extend the existing action into a partial settings update; at least one of `enabled` or `transport` is required. Unknown provider/deprecated provider remains rejected. Request examples:

```json
{"transport":"acp"}
```

```json
{"enabled":true,"profile_id":"claude","transport":null}
```

Presence matters: absent `transport` preserves it; null clears the override; string accepts only `pty` or `acp` present in the catalog transports. `enabled` must be boolean when present and keeps existing presence/profile validation. `profile_id` absent or equal to provider is canonical. Any request containing `transport` with a different profile_id returns 422 `transport_is_provider_wide`, including a null transport. Do not silently discard it. Invalid type/value returns 422 `invalid_transport`; a supported but unready ACP runtime returns 409 `acp_unavailable` with safe status details. Reverting to PTY or clearing an override is always allowed for an owned, active provider; offline transport-only changes are allowed, with readiness checked again before launch. A fresh adapter status indicating missing/outdated/installable is not a permanent prohibition: explicit ACP selection requests the install in §10, returns 409 `acp_installing` while it runs, and UI retries only on the user's next save after status changes. No implicit launch on a failed settings save.

Response data (200) and provider-status rows add:

```json
{"bridge_id":"brg_example","provider":"claude","profile_id":"claude","enabled":true,"transport":"acp","effective_transport":"acp","transports":["pty","acp"],"default_transport":"pty","acp_adapter":{"installed":true,"version":"0.108.0","node_version":"v22.0.0","state":"ready","error":null,"checked_at":"2026-11-18T00:00:00Z"}}
```

`transport` is nullable override, `effective_transport` is always resolved. All profile status rows repeat the provider-wide fields, read only. Publish provider-status-changed only after commit. Persist settings via a unit of work; combined enabled/transport changes are atomic. Do not trust a client-supplied effective_transport, recipe or adapter status.

### 4.2 Launch selection and skew

Add `resolve_runtime_transport(bridge_id,provider)` in the provider service. It reads the canonical setting, else catalog default, validates membership and recipe, and requires bridge capability `acp_runtime_v1` and host piped capability for ACP. Freeze the result into `Agent_Instance.runtime_transport` in launch preparation. Extend `launch_command_json_full`, task wake run entries/serializers, restart, test-agent and instance-reconfiguration paths using one helper, including launches that bypass ordinary manual creation. Never resolve against the chosen profile's transport.

```json
{"type":"launch_agent","protocol_version":1,"command_id":"cmd_example","payload":{"agent_instance_id":"inst_example","provider":"claude","provider_profile":"claude-work","effective_transport":"acp","catalog_etag":"catalog_hash","launch_epoch":"epoch_example","model":"selected-model-id","permission_mode":"ask"}}
```

Other existing fields remain required as before. Bridge validates effective_transport against its matching catalog snapshot before bootstrap/spawn; refresh a mismatched ETag once, then fail clearly. Missing effective_transport means `pty` for an old Hub. Unknown values fail `unsupported_runtime_transport`; explicit ACP never silently falls back to PTY. An old Bridge cannot safely ignore an ACP field: Hub must reject ACP launch if its capability is missing. Bridge hello adds `acp_runtime_v1`; only advertise it after compatible daemon capability detection. A disconnected Bridge does not prove process death.

## 5. Daemon-owned piped execution

### 5.1 Protocol and process changes

Keep `kind` independent of transport. Add `SpawnMode { Pty, Pipe }` (`Default=Pty`) to `SpawnRequest.mode`. Implement a `PipeHost` with `std::process::Command`, piped stdin/stdout/stderr, same filtered env plus per-instance overrides, cwd, timeout, POSIX process group / Windows job, and exit watcher. Never call openpty, construct a VT engine, run startup detection, merge stderr into stdout, or treat ACP bytes as terminal input. Reuse the daemon registry/lifecycle interface through a host enum, not duplicated agent registries.

Do not append fields to legacy AgentList rows: their positional encoding would misparse old clients. Keep legacy Spawn/List/Attach behavior byte-compatible and fail legacy Attach/Input/Key/Resize/Capture on a pipe child with `pipe_requires_protocol`. Pipe mode is sent only using the new SpawnPipe tag; decoding it creates SpawnRequest with mode=Pipe. This avoids an old host silently spawning a PTY after ignoring a trailing mode field.

Add these Rust variants, mirrored by Odin codecs in `src/bridge/pty_host_client.odin`:

```rust
// CtlMsg additions, tags 0x40..0x46 in this order:
Capabilities,
SpawnPipe(SpawnRequest),
ListPipes,
AttachPipe { instance: String, generation: String, after_seq: u64 },
PipeInput { instance: String, generation: String, delivery_id: String, data: Vec<u8> },
PipeAck { instance: String, generation: String, through_seq: u64 },
PipeDetach { instance: String, generation: String },

// CtlReply additions, tags 0xC0..0xC5 in this order:
Capabilities { piped_spawn_v1: bool },
PipeList(Vec<PipeInfo>),
PipeReady { instance: String, generation: String, first_seq: u64, last_seq: u64 },
PipeOutput { instance: String, generation: String, seq: u64,
             stream: u8, data: Vec<u8> }, // stream 1=stdout, 2=stderr
PipeInputDone { instance: String, generation: String, delivery_id: String },
PipeGap { instance: String, generation: String, first_seq: u64 },

struct PipeInfo {
    instance: String, generation: String, pid: i32, alive: bool,
    exit_code: Option<i32>, meta: Option<serde_json::Value>,
}
```

Use existing outer u32 big-endian frame length, string/vector primitives and enum tag conventions. In new variants encode fields in declaration order; booleans/stream discriminants u8; sequence/counts u64/u32 big-endian; optional exit is u8 presence then i32; meta is optional JSON string. SpawnPipe uses the existing Spawn body encoding (without its tag); mode is implied. Capabilities body is empty. PipeList starts u32 count, then rows as declared. Reject unknown stream/mode, oversized lengths and trailing garbage. Limit input/output data to 64 KiB per frame; reject >4 MiB total outer frames before allocation. Large stdin JSON lines are split into chunks with distinct delivery_ids and serialized in order.

`generation` is a new random daemon child identity, stable for its life and changed on Restart. `meta` contains nonsecret launch identity: runtime_transport, provider/profile, launch_epoch, run_dir and catalog_etag. Never put the token into List metadata. SpawnPipe returns existing Spawned; query ListPipes for generation before attachment. List still includes pipe children in liveness roster (rows/cols=0), while ListPipes supplies mode-specific data. `Close`, `Restart`, `Signal`, `ChildExited`, `HostHeartbeat` retain process-group semantics for both modes. A pipe child is not exposed to UI terminal subscribers.

Capabilities must succeed before SpawnPipe; an unknown tag/disconnected old host means unsupported, not permission to downgrade. Update/restart the host only with the existing safe upgrade mechanism; never kill unrelated live PTYs to enable ACP.

### 5.2 Reattachment, delivery and backpressure

Each ACP instance uses a dedicated daemon socket for AttachPipe, stdin and replies. The shared control/watch socket continues to carry heartbeats/exits, so a chat flood cannot starve liveness. One writable AttachPipe owner per generation; a new attachment atomically fences the previous connection. Detach/Bridge socket loss leaves child and stdin open.

Daemon assigns a monotonic sequence to stdout frames and retains unacknowledged bytes in a 16 MiB per-child replay queue; bounded subscriber queue is 1 MiB. When full, pause the stdout reader so the OS pipe applies backpressure. Do not drop ACP bytes, disconnect a client as a substitute for flow control, or grow memory without a limit. Reader pauses must hold no daemon registry or heartbeat lock. Separate stderr drain retains the last 64 KiB, with explicit truncation diagnostics; stderr is diagnostic and may be dropped. Stderr frames use seq=0 and are never part of the lossless stdout cursor. Maximum combined queued stdin is 4 MiB, with a dedicated writer; queue overflow returns a retryable error without writing any bytes.

AttachPipe replies PipeReady, then ordered stdout frames with seq > after_seq, then live bytes. The daemon retains data until PipeAck, not until socket write. A requested cursor older than retained bytes returns PipeGap, never a partial JSON stream. after_seq ahead of last_seq or wrong generation is rejected. Exit/tombstone and remaining stdout stay queryable for 10 minutes or until explicitly closed, allowing final RPC output to drain before finalizing death.

For PipeInput, retain a per-generation map from delivery_id to bytes hash and write receipt. A duplicate with identical bytes returns the previous receipt without writing; a mismatched duplicate is an error. WriteDone is sent only after all bytes reached child stdin. Keep receipts until generation ends (bounded: 65,536 receipts; refuse further writes with explicit error when exhausted, do not evict an unacknowledged id). On a writer failure after partial write, mark that generation unusable and terminate it; never retry the remainder into an uncertain JSON stream. Bridge recovery then uses session/load. Every sender persists its delivery_id before sending; only one writer feeds stdin. The raw protocol adapter never appends Enter, terminal escapes or extra delimiters beyond the JSON client's one newline.

## 6. ACP JSON-RPC client API

New `src/bridge/acp_jsonrpc.odin` is a transport-independent client; it does not spawn processes. Its I/O implementation uses §5, including replay sequence/checkpoint callbacks. ACP uses UTF-8 JSON objects separated by newline; stdout is protocol-only and stderr is logging. This is the [ACP stdio contract](https://agentclientprotocol.com/protocol/v1/transports).

```odin
ACP_RPC_ID :: distinct string // outgoing IDs use "ham:<launch_epoch>:<counter>"
ACP_RPC_Error :: struct { code: int, message: string, data_json: string }
ACP_RPC_Result :: struct { id: ACP_RPC_ID, result_json: string, error: ACP_RPC_Error, ok: bool }
// Exact exported operations; callbacks receive owned copies and must release them.
acp_rpc_open :: proc(io: ACP_RPC_IO, callbacks: ACP_RPC_Callbacks) -> (^ACP_RPC_Client, bool)
acp_rpc_request :: proc(c: ^ACP_RPC_Client, method, params_json: string,
                       timeout_ms: i64, completion: ACP_RPC_Completion) -> (ACP_RPC_ID, bool)
acp_rpc_notify :: proc(c: ^ACP_RPC_Client, method, params_json: string) -> bool
acp_rpc_reply :: proc(c: ^ACP_RPC_Client, inbound_id_json, result_json: string) -> bool
acp_rpc_reply_error :: proc(c: ^ACP_RPC_Client, inbound_id_json: string, err: ACP_RPC_Error) -> bool
acp_rpc_restore :: proc(c: ^ACP_RPC_Client, checkpoint_json: string) -> bool
acp_rpc_close :: proc(c: ^ACP_RPC_Client)
```

`ACP_RPC_IO` supplies serialized write(bytes,delivery_id), close and feed(bytes,seq); `ACP_RPC_Callbacks` supplies notification(method,params), inbound_request(id_json,method,params), fault(reason), checkpoint(state). Request completion callbacks execute on the per-instance dispatcher, never while holding pending-map or global runtime locks. `acp_rpc_close` detaches I/O, rejects remaining waiters exactly once, joins reader/writer/dispatcher workers and frees owned state; it does not kill the child. Allocate persistent workers/state with heap allocator, with independent per-iteration scratch arenas.

Maintain separate maps for outbound requests and inbound requests. Preserve inbound numeric/string IDs as JSON values when replying; server ID 1 and client ID 1 are unrelated. Persist outbound counter, method, params, deadline, delivery_id and semantic completion role (initialize/new/load/config/prompt), rather than callback addresses. Restore roles into fresh callbacks on recovery. Incoming responses must have exactly one result/error; reject invalid JSON-RPC version, batch arrays, missing method/id shape and invalid UTF-8. Unknown response IDs are logged once and ignored. Duplicate inbound requests reuse the stored response; never create two permission blockers for one ID.

Incremental framing handles split UTF-8, escaped newlines and multiple lines per frame. Bound a single line at 4 MiB. Empty lines may be ignored; malformed/oversized lines fail the connection and launch with `acp_protocol_error`, with a sanitized diagnostic. Unknown notifications are ignored; unknown inbound methods return -32601. Invalid params use -32602; ordinary JSON-RPC parse/invalid request errors use -32700/-32600 only when a safe reply is possible. Do not interpret arbitrary non-JSON output as assistant text.

Deadlines: initialize 15s; session/new or load 60s; set_config_option 15s; inbound permission 300s by existing relay clamp; explicit stop grace 10s; cancel acknowledgement is the original prompt result, due within 10s. Prompt requests have no absolute timeout while the daemon child is alive; heartbeat liveness and user cancellation govern them. Expired setup calls terminate launch; a late response cannot mark it ready. Timeouts do not automatically replay non-idempotent session/new or prompt into a fresh process.

## 7. ACP runtime lifecycle and restart contract

New modules: `acp_runtime.odin`, `acp_state.odin`, `acp_adapter.odin`, `acp_events.odin`; dispatch from runtime launch/deliver/interrupt/stop/notify paths by the immutable launch snapshot. Keep the common bootstrap and token issuance before the transport branch in `bridge_runtime_launch_agent`. Store additions in `Bridge_Runtime_Launch`: effective_transport, launch_epoch, acp_session_id, acp_load_session, pipe_generation, adapter_version; runtime driver owns RPC client and queues, not a copied pointer in returned launch snapshots.

### 7.1 New launch

1. Verify recipe, readiness, model/profile inputs and capabilities. Materialize the same bootstrap files and shim. Both process cwd and ACP session cwd are the absolute bootstrap run_dir; project Workdir remains in TASK.md/instructions. Inherit the bootstrap token/instance/endpoint env and profile auth/config isolation. ACP profile launch_args/binary_path are not adapter argv: existing Claude binary override is mapped only through adapter-supported `CLAUDE_CODE_EXECUTABLE` after validation; config_dir/home_path retain profile semantics. Do not append PTY yolo/model/prompt flags or load hook extensions into ACP mode.
2. Persist launch state outside run_dir at `<bridge-data>/bridge/acp/<instance-id>/<launch-epoch>/state.json`, mode 0600, atomic temp+fsync+rename and parent fsync. Its directory is 0700. SpawnPipe with launch identity, attach, record child generation. Use the daemon's existing immutable startup launch key concept to avoid duplicate process launches after a command retry.
3. Negotiate once for a new child:

```json
{"jsonrpc":"2.0","id":"ham:epoch:1","method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"heimdall","version":"build-version"},"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}}
```

Require response protocolVersion=1, save agentInfo, agentCapabilities.loadSession and promptCapabilities. Authentication metadata by itself is not an auth failure; react to auth-required errors. Capability negotiation follows [initialization](https://agentclientprotocol.com/protocol/v1/initialization).

```json
{"jsonrpc":"2.0","id":"ham:epoch:2","method":"session/new","params":{"cwd":"/absolute/bootstrap/run-dir","mcpServers":[]}}
```

4. Persist returned sessionId and configOptions before output acknowledgment. For explicit nonempty selected model find exactly one select option with category=model; accept a grouped or flat option list, match the validated resolved model ID exactly, then set using that option's id. Missing option/value fails `acp_model_unavailable`; never silently select another model. An empty model leaves the adapter default. Consume full updated configOptions response and validate the returned selection. Existing bespoke discovery/static seeds continue to feed the picker; no scratch-session discovery is added.

```json
{"jsonrpc":"2.0","id":"ham:epoch:3","method":"session/set_config_option","params":{"sessionId":"session-example","configId":"model-option-id","value":"selected-model-id"}}
```

Use the actual configId from the session, following [config options](https://agentclientprotocol.com/protocol/v1/session-config-options). Likewise apply permission_mode to the pinned Claude adapter's category=mode option: ask maps to `default`, yolo to `bypassPermissions`. Validate those values in that adapter's returned options; failure is `acp_permission_mode_unsupported`, never a broader mode. The [pinned mode implementation](https://raw.githubusercontent.com/agentclientprotocol/claude-agent-acp/v0.108.0/src/session-mode.ts) can omit bypass mode under policy and otherwise may initially choose auto: explicitly set the requested mode before the first prompt. Record this mapping in adapter-specific recipe code and test it rather than assuming other adapters use these names.

5. After session/new and required configuration succeed, mark running/idle and invoke common `bridge_runtime_mark_start_success`. `ham-ctl agent start-success` remains accepted and idempotent. Send the catalog starter prompt verbatim as the first session/prompt text block; optional bootstrap fallback resources are additional blocks, not a rewritten starter text. No PTY startup keystroke detection.

```json
{"jsonrpc":"2.0","id":"ham:epoch:4","method":"session/prompt","params":{"sessionId":"session-example","prompt":[{"type":"text","text":"verbatim starter prompt"}]}}
```

### 7.2 Operations and state mapping

| Trigger | ACP action | Bridge_Runtime_Instance effect |
| --- | --- | --- |
| Spawn/setup pending | initialize/new/config | runtime_status=starting, startup starting; pty_process_alive=true means daemon process alive for either mode |
| Session/config ready | common start-success | running, idle, start_success_seen=true; enqueue normal status push |
| Deliver user/answer/nudge | queued session/prompt text/resources | running, active with activity_source=acp; one prompt in flight per session |
| Permission waiter | §8 relay | running, waiting_user |
| Prompt response end_turn/max_tokens/max_turn_requests/refusal | finalize assistant row | running, idle; record stopReason; drain next input |
| Interrupt | session/cancel notification | keep running; after prompt result cancelled, idle and drain queue |
| Stop | cancel, resolve pending permissions cancelled, daemon Close after ≤10s | stopping then stopped only after daemon exit/close confirmation |
| Unexpected child exit | drain final stdout; fail pending RPC/outbox turn | failed with acp_adapter_exited, process_alive=false; common child-exited/status path |
| Auth required | §10 login blocker | starting with blocked startup; waiting_user |
| Protocol/setup error | close owned child | failed with classified safe error; never ready from a late callback |

The common runtime currently calls its process flag `pty_process_alive`; reuse it consistently for both modes in MVP rather than retaining a PTY-only liveness check. `last_seen_unix_ms` comes from daemon heartbeat, not stdout activity; quiet assistants stay alive. Use source `acp` for activity and give it the same authoritative precedence as extension events. Do not feed ACP instances to pane-diff/startup detectors. Preserve stop-intent and launch-epoch fencing so late completion cannot resurrect a stopped/replaced child.

Interrupt shape follows [cancellation](https://agentclientprotocol.com/protocol/v1/cancellation):

```json
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"session-example"}}
```

There is no response ID for cancel. The outstanding prompt resolves with stopReason=cancelled. On no result in 10s, stop the unresponsive child and report failure, rather than sending a second concurrent prompt.

### 7.3 Journal and reconcile

`state.json` contains schema_version=1, instance/bridge/launch_epoch, effective_transport, provider/profile, run_dir, catalog_etag/adapter_version, pipe_generation, initialized, loadSession, sessionId, selected model/mode, next_rpc_id, pending outbound calls, pending inbound requests/replies, queued input message IDs, completed delivery IDs, last_stdout_seq, partial_line_base64, tool map and current chat outbox. It excludes raw tokens; recover the token from the existing scoped token store. Every state and outbox mutation is atomic and serial on the instance dispatcher. Persist before sending stdin and before PipeAck. The partial line is persisted with its acknowledged raw frame cursor; otherwise a restart in the middle of a JSON line would corrupt framing.

Reconcile after Hub connectivity is restored:

1. Fetch full/paginated Hub instance intent and daemon List + ListPipes; on transport error or incomplete listing, do not reap anything. Join by instance plus launch_epoch/generation. Stopped/cancelled Hub intent wins; close the matching child and cancel waiters. Never adopt a child under a newer launch epoch.
2. For surviving pipe child with valid matching journal: restore pending request IDs/dispatcher roles and partial framing; AttachPipe at last_stdout_seq; replay unacked output. Do not initialize again, session/new again, or session/load against that already-initialized live process. Its generation, PID and sessionId remain the same. Restore in-flight activity and permission blockers from the journal before accepting new input. Persisted outbound writes without a receipt retry with the same delivery_id. Hub outbox retries use §9 idempotency.
3. For lost child or unusable stream (PipeGap, mismatched/corrupt journal): never guess pending execution. If saved sessionId and loadSession=true, close any old matching child, spawn a fresh pinned adapter, initialize, and load:

```json
{"jsonrpc":"2.0","id":"ham:recovery:2","method":"session/load","params":{"sessionId":"session-example","cwd":"/absolute/bootstrap/run-dir","mcpServers":[]}}
```

Session loading and history replay are defined by [session setup](https://agentclientprotocol.com/protocol/v1/session-setup). Set replay_only=true until the load response; replay notifications rebuild tool/config state but never create new chat rows, unread counts, tool bubbles or effects. Retain existing chat. Mark the interrupted turn failed with `acp_turn_interrupted`; never automatically resubmit a prompt that might already have executed tools. Reapply model/mode after load and accept fresh queued, previously unsent inputs. Bootstrap files/token are reused; do not clean-slate a surviving session's cwd during reconcile.
4. Without a recoverable session or load capability, report stopped with `acp_pipe_lost`, preserving chat and explicit error. No silent new conversation. Retry requires an explicit new launch. Daemon survival is the normal Bridge-restart path and does not depend on loadSession; load is the child-loss path, tested separately.

## 8. Telemetry and permissions

Map `session/update.params.update.sessionUpdate` only for the driver's sessionId. Deduplicate using pipe sequence and a per-session tool map keyed by toolCallId. Partial tool_call_update merges into stored state; it is not a replacement with empty fields. All normalized events include schema=ham.ext.v1, provider=claude, ext_version=acp-0.108.0, ts, session_id and bound instance identity. Call `bridge_ext_ingest(rec, params, now)` with the locally verified token record, the normalized event JSON, and the dispatcher's monotonic `now`, so ingest timing matches the PTY path; never use an identity or timestamp claimed by the adapter.

| ACP update/action | Ext_Event_Kind and payload | Handling |
| --- | --- | --- |
| initialize/session ready | Hello / Session | capabilities limited to supported telemetry; session phase start/source startup or resume |
| prompt submitted/result | Activity | payload.state active/idle; cancelled result also idle |
| tool_call first pending/in_progress | Tool_Start | event tool.start; tool.name=name if present else kind/title, tool.use_id=toolCallId, input=rawInput object or {} |
| tool_call_update pending/in_progress | no additional start | update cached fields/progress, keep tool live |
| tool_call or update completed/failed | Tool_End, once | event tool.end; same use_id; payload includes outcome success/failure and rawOutput/content; synthesize start first if initial event was terminal |
| content entry type=diff on either tool event | File_Edit | event file.edit; payload.path, unified diff from oldText/newText; obey existing 64 KiB diff and 256 KiB event caps |
| agent_thought_chunk | Activity active | do not store private reasoning text as chat; no new reasoning UI contract |
| agent_message_chunk text | no extension event | chat path §9; not a tool or activity bubble per token |
| user_message_chunk | none | session/load replay input; do not echo/reinsert user chat |
| plan | none | retain latest plan in driver diagnostics; do not invent a Tool_Start |
| config_option_update/current_mode_update | none | merge configuration snapshot, validate required launch settings |
| unknown updates | none | bounded diagnostic; compatible future notifications are ignored |

Example normalized event, matching the [existing parser](../../src/contracts/extension.odin):

```json
{"schema":"ham.ext.v1","event":"tool.start","provider":"claude","ext_version":"acp-0.108.0","ts":"2026-11-18T00:00:00Z","session_id":"session-example","tool":{"name":"Bash","use_id":"call-1","input":{"command":"pwd"}},"payload":{}}
```

Do not fabricate usage/token counts from text; map only values actually reported with supported semantics. Disable provider-native hook installation for ACP to avoid duplicate telemetry. File edit locations/content follow [ACP tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls); all filesystem paths remain data, never shell fragments.

### Permission request routing

**MVP implementation amendment (T5, requirements revision 2):** interactive permissions are deferred. Reply with `RequestPermissionOutcome` cancelled immediately on the instance dispatcher and emit one Activity naming the tool. Do not start a permission worker, call `bridge_ext_permission_run`, map option kinds, or show a permission prompt. The interactive design below is retained for a later task.

The request contains `toolCall` (a ToolCallUpdate object), not merely a top-level toolCallId:

```json
{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"session-example","toolCall":{"toolCallId":"call-1","title":"Run command","kind":"execute","rawInput":{"command":"pwd"}},"options":[{"optionId":"allow-this","name":"Allow once","kind":"allow_once"},{"optionId":"deny-this","name":"Reject once","kind":"reject_once"}]}}
```

Dispatch on a separate permission worker; neither RPC reader nor Hub reader may block waiting for the user. Generate valid ≤64-char blocker ID from a hash of launch epoch, session and canonical inbound request ID. Save request/options and blocker ID before acknowledgment. Build `Bridge_Ext_Permission_Request` with that ID, tool_name/title, tool_use_id, rawInput and safe suggestions; call `bridge_ext_permission_run` directly. It uses existing permission_decision frames and attention UI. Re-register the same blocker on Bridge restart; refresh uses the existing generation supersession rules. One map entry owns the reply.

| Existing outcome | ACP result |
| --- | --- |
| allow | select option whose kind=allow_once, using its actual optionId |
| deny | select kind=reject_once, using its actual optionId |
| none, timeout, stopped, cancelled, superseded | outcome cancelled; never grant |
| required once option absent | disable that choice in blocker UI; if no supported choice remains, cancelled |

```json
{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"selected","optionId":"allow-this"}}}
```

```json
{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"cancelled"}}}
```

Do not send bare allow_once as outcome, confuse kind with optionId, or translate allow_always into once approval. The MVP offers only the existing once allow/deny decisions; this preserves existing relay authority. On cancel, resolve every pending permission request before waiting for prompt completion. Reject wrong-session requests and unsupported client methods with an RPC error, not an approval.

## 9. Direct input and streamed assistant chat

### 9.1 Input delivery

**MVP implementation amendment (T5 coordinator decision):** ordinary messages and notices remain FIFO. The explicit pane interrupt uses the existing `session/cancel` path; after cancellation, drain the FIFO in order. A combined send-and-interrupt control and message priority flag are deferred post-MVP.

User messages remain durable chat rows. On notify_agent_message, ACP driver fetches unseen input via `POST /api/v1/agent-actions/chat/read`, using the same instance authority as ham-ctl (`src/bridge/agent_api.odin:251`). The response remains sealed: open body and the encrypted structured labels/custom text locally with `bridge_vault_decrypt_field` and the scoped keyring; the Hub does not decrypt. Fetch with mark_read=false until the local input FIFO is durably checkpointed. Extend that action with an optional ack-only `params:{ack_message_ids:["msg_..."]}` branch (maximum 100 IDs): validate every ID belongs to this instance's incoming conversation before calling `mark_messages_read_by_ids_at`, return `{marked_count,read_at}`, and publish the existing read receipt event. No cross-instance target or list filters are accepted in ack-only mode. The existing handler currently marks the rows it fetches (`src/hub/transport/http/agent_action_handlers.odin:627`); refetching with mark_read=true could acknowledge a newly arrived, unqueued row and is not sufficient. Paginate until all unseen rows have been checkpointed and acknowledged. Convert actual message body into a prompt text block; do not send the old notice that tells the model to run chat read. Include sender, message_id and structured answer metadata in a labeled context text block so quick replies and grouped answers retain question/option IDs. Task nudges, lease wakes and background shell completion notices remain notices with fetch instructions for their technical context; deliver them as text prompts instead of terminal keystrokes. No output payload is inferred from a wake notice.

Persist the input row ID in a FIFO before marking it consumed; completion bookkeeping distinguishes fetched/queued/sent/finished. A repeated notification cannot enqueue the same row twice. One in-flight prompt at a time. User interrupt cancels the current turn then prioritizes the new message; other notices queue until idle. Do not hold the Hub command socket waiting for a model result. Images/resources are supplied only when the adapter advertises matching prompt capability; otherwise include their existing fetchable artifact reference and explain the unsupported inline type. No arbitrary resource fetch by ACP client.

### 9.2 New agent action

Add `POST /api/v1/agent-actions/chat/assistant-message` through the existing instance-action auth envelope and Bridge `httpc` request path. New content service operation `upsert_assistant_message(auth,instance_id,input)` uses a unit of work. Caller is the ACP driver; the model need not invoke ham-ctl chat send. Existing explicit chat send remains available for action cards/questions and other structured control messages.

```json
{"method":"agent.chat.assistant_message","agent_instance_id":"inst-example","params":{"launch_epoch":"epoch-example","turn_id":"ham:epoch:4","message_id":"msg_bridge_generated_id","revision":1,"body":"vault:v2:<sealed-snapshot>","message_status":"pending","stop_reason":null}}
```

The armor above is illustrative. Before HTTP, the Bridge seals each full text snapshot using `bridge_read_vault_keyring` and `bridge_encrypt_vault_text`; the Hub stores opaque ciphertext. Reuse the saved ciphertext on a retry so payload hashes are stable despite randomized vault nonces. Header auth is the existing Bridge bearer plus `X-Heimdall-Instance-Token` (`src/bridge/agent_api.odin:18`); do not send the local agent token to the Hub. The bridge generates one stable standard-format `msg_...` ID per turn before first flush. Server validates its format but derives conversation/owner/sender from authenticated instance; never accepts those from params. The durable idempotency key is `(instance_id,launch_epoch,turn_id)` and binds that message_id. Persist it in new `acp_assistant_turns` (part of migration 211):

```sql
CREATE TABLE acp_assistant_turns (
  agent_instance_id TEXT NOT NULL REFERENCES agent_instances(agent_instance_id) ON DELETE CASCADE,
  launch_epoch TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  message_id TEXT NOT NULL UNIQUE REFERENCES chat_messages(message_id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  payload_hash TEXT NOT NULL,
  PRIMARY KEY (agent_instance_id, launch_epoch, turn_id)
);
```

Insert chat row then turn index atomically; update both atomically. Valid statuses are pending, complete, failed. Body is a sealed full snapshot, not a delta: Bridge enforces 1 MiB plaintext; Hub enforces the corresponding `domain.vault_armored_max_bytes(1 MiB)` storage bound, validates vault armor with existing owner vault policy, and never truncates ciphertext. Use the stream-specific bound rather than a smaller ordinary chat limit. Hash canonical received body/status/stop_reason on the Hub. `revision` is strictly increasing per turn; same revision and payload hash replays 200 without effects, different payload for same revision returns 409, lower revision returns current saved snapshot without regressing it. Higher revisions may coalesce skipped sequence numbers. Terminal status is immutable except identical replay. Reject stale launch epoch for a new turn or nonterminal update after instance replacement; allow the old driver to finish an already-bound turn as failed only. Enforce existing owner/instance auth on every request; Bridge credentials alone cannot impersonate arbitrary agents.

Return 201 for first insertion, 200 thereafter, data containing the ordinary message plus revision. First nonempty chunk creates direction=agent_to_user, message_type=text, pending; empty turns produce no blank row. `end_turn` or other normal stopReason completes the row with metadata `{acp:{turn_id,launch_epoch,revision,stop_reason}}`; cancellation preserves partial text and completes with stop_reason=cancelled. Protocol/child/transport errors fail it with a safe reason. A turn that exceeds the 1 MiB cap is cancelled and its partial row marked failed with `assistant_message_too_large`, never silently truncated into a successful reply.

### 9.3 Chunk updates and events

Accumulate agent_message_chunk text without altering Markdown. Flush full snapshots at most every 100ms or on 8 KiB new text, whichever first; final status flushes immediately. This is MVP streaming. Persist current full body/revision/outbox before PipeAck. Coalesce unsent pending snapshots, retry latest with the same ID/revision/hash on uncertain HTTP completion. Per-instance outbox is bounded at 4 MiB; pause PipeAck/reader when Hub is unavailable instead of dropping text. Hub outage therefore backs up into the bounded daemon queue. No network operation occurs while runtime global locks are held.

Publish `chat_updated` only after each saved mutation, with message_id, conversation_id, agent_instance_id, direction=agent_to_user, message_type=text, message_status, revision, fetch_required=true, fetch_kind=chat_message, fetch_id=message_id. Metadata contains only nonsecret turn/revision/status fields; seal any human text field on the Bridge. Do not put token deltas or plaintext body in WS events; UI fetches the sealed durable message and decrypts through its current path. UI throttles fetches per message to 100ms, then guarantees a final fetch, upserts by message_id and discards older revisions. Event reordering must not change complete back to pending. Message-specific fetch must bypass list-page caches. Reconnect REST fetch restores latest text without replaying all chunks.

On vault lock/missing epoch, pause prompts and chat publication, report the existing vault-locked blocker, and backpressure pipes. Never persist/send plaintext as fallback. Seal queued chat bodies/input text and partial RPC content in the local journal too; retain only launch IDs/cursors needed to report the lock outside the sealed journal payload. Wipe keyring/plaintext buffers after use. Unlock resumes the same revision/outbox. Local-only stdout replay resides in the daemon process; it never enters Hub logs or PTY frames.

Unread count and last-message timestamp increment only on initial creation. Conversation preview may track latest body without changing chronological position. No push/toast per chunk: at most one ordinary completion notification per turn and no duplicate notification on retry. `pending` rows render live with existing reveal behavior and `complete` removes the indicator. The same durable text survives page reload and Bridge restart. Replayed session/load history never enters this endpoint.

## 10. Adapter install, status and login fallback

The initial exact pin is `@agentclientprotocol/claude-agent-acp@0.108.0`, with `CLAUDE_AGENT_ACP_PROTOCOL=v1`. Published npm metadata was checked for version, `claude-agent-acp` bin, Node >=22, and integrity `sha512-Y0HI3CB0DfhpWItCn2RE3xgpen001V2U/bHm3G6ZVKXsElF5N4uYyjYlmgNzZBKcBtZK0JqiE96NMaeVXtgJjw==`. See [versioned npm metadata](https://registry.npmjs.org/@agentclientprotocol/claude-agent-acp/0.108.0) and [upstream package manifest](https://raw.githubusercontent.com/agentclientprotocol/claude-agent-acp/main/package.json). This is a release candidate pin for this implementation; real auth/bootstrap/recovery behavior must pass §12 before the default changes. No assumption of successful live verification is made here.

Install below `<bridge-data>/bridge/acp-adapters/claude/0.108.0/` using an exclusive version lock and staging directory. Execute argv equivalent to the following, without shell interpolation:

```bash
npm install --prefix <staging-dir> --save-exact --no-audit --no-fund @agentclientprotocol/claude-agent-acp@0.108.0
```

Preserve package-lock and npm integrity verification, verify package/version/bin and a v1 initialize probe in scratch cwd, atomically rename to the final directory and then expose ready. Never use npx/latest, install globally, auto-upgrade on launch, or install into bootstrap/project directories. Later restarts use the same version/lock. Node absence/version mismatch or unavailable npm/network produces explicit status, not a PTY downgrade. Install/probe runs outside runtime locks, with 120s install deadline and cleanup of owned staging paths. Avoid concurrent network installs for multiple launches of the same version. Apply profile auth env to launch/probe only, not to the npm command or logs.

Explicit install API: `POST /api/v1/bridges/:id/providers/:provider/acp-adapter` with `{action:"install"}`; use owner cookie auth, active catalog entry and online bridge checks. No client package/version/command fields. Return 202 `{command_id,provider,state:"installing"}` and send tracked Hub command `install_acp_adapter` with payload `{provider,catalog_etag,adapter_version}`. Bridge validates against its catalog and reports ordinary command result plus provider status updates. Requests for the same active version coalesce to one command. Unsupported provider returns 422, offline returns 409, foreign bridge is hidden by existing ownership rules. Settings ACP-selection preflight may call this same operation before returning acp_installing. Installation status is read through existing provider status GET/events; no polling endpoint with a second status vocabulary.

Status is per bridge/provider and repeats on profile views:

```json
{"installed":false,"version":null,"node_version":"v22.0.0","state":"installing","error":null,"checked_at":"2026-11-18T00:00:00Z"}
```

Allowed states: not_checked, missing_node, missing, installing, ready, outdated, error. `installed` means exact requested files exist and verify; ready additionally requires compatible Node and successful initialize probe. Report on normal discovery, install transitions and launch failure. Store on canonical status row, preserving it during profile-only status upserts; checked_at prevents an older report overwriting a newer result. Error is sanitized, bounded to 1 KiB, excludes credentials and raw environment. Existing provider binary presence remains a separate fact. UI displays the installed version and error; a provider with no ACP recipe returns acp_adapter=null.

Auth-required initialize/new/load/prompt errors (`-32000` or the pinned adapter's documented auth-required error) create an existing startup blocker extended with actions `open_login_shell`, `retry_acp`, `cancel_launch`. Use a stable ID per launch epoch and reason `acp_auth_required`; do not classify arbitrary provider/network errors as auth. New authenticated Hub action `POST /api/v1/agent-instances/:id/acp-login` accepts `{action:"open_login_shell"|"retry_acp"|"cancel_launch"}` and sends a launch-fenced Bridge command `acp_login_action`. Owner scope, bridge binding, current ACP launch and blocker existence are required. Return 202 plus shell_session_id for an opened shell. Repeating open for the same blocker returns the existing live shell.

Open login shell via the existing shell-session service and ham-pty-host PTY spawn, with the selected profile's CLI binary/auth home/config and `claude /login` argv, never the ACP adapter. Shell is user-visible, owner-bound, with no agent token in its env. Do not launch a login command through the ACP protocol or declare terminal capability. User completes login, returns to blocker and explicitly clicks Retry. Shell exit alone is not proof of authentication. Retry cancels old pending permissions/RPC, closes the old adapter generation, initializes a fresh one and uses session/load when a valid saved session is available; otherwise session/new. Keep starter-prompt delivery bookkeeping so a successful prior turn is not repeated. A failed login retains a clear blocker; Cancel closes the ACP child and marks stopped. Login shell can be closed independently and never changes the provider's selected transport.

The upstream [adapter README](https://github.com/agentclientprotocol/claude-agent-acp#readme) documents protocol-version limiting. The [pinned v1 implementation](https://raw.githubusercontent.com/agentclientprotocol/claude-agent-acp/v0.108.0/src/v1/acp-agent.ts) advertises loadSession and configures user/project/local setting sources; those source facts motivate, but do not replace, live auth, bootstrap and recovery verification.

## 11. UI and bootstrap presentation

Extend `BridgeProviderStatus`, catalog API types and normalizers with:

```typescript
type RuntimeTransport = 'pty' | 'acp';
transports: RuntimeTransport[];
default_transport: RuntimeTransport;
transport: RuntimeTransport | null;
effective_transport: RuntimeTransport;
acp_adapter: {
  installed: boolean; version: string | null; node_version: string | null;
  state: 'not_checked' | 'missing_node' | 'missing' | 'installing' | 'ready' | 'outdated' | 'error';
  error: string | null; checked_at: string | null;
} | null;
```

Add `providerSetupApi.setTransport(current,provider,transport)` which sends only transport on the canonical provider endpoint and refreshes status. `setEnabled` retains its profile contract and omits transport. Put one Runtime selector per provider in Settings → Providers and the provider-level header of ProviderProfilesSurface, shared across profiles; no editable per-profile copy. Show PTY/ACP and a Reset to catalog default action. With one supported transport, disable the selector with an explanatory tooltip. Missing/old fields normalize to PTY-only. Unsupported bridge/host capability disables ACP with an explicit reason; installable missing/outdated shows an Install adapter action using §10's endpoint and the tracked `install_acp_adapter` command. Show progress and error alongside version/Node; no spinner without a bounded operation result.

Instance API/state adds `runtime_transport` from the frozen launch snapshot. Add that prop to AgentPaneComposerPanel and gate terminal-hook/xterm mounting in a child component: ACP renders “Structured runtime — conversation and tools appear in chat” with adapter status and startup blocker actions. Never subscribe to the PTY stream for ACP or infer its transport from a provider setting changed after launch. The chat composer stays functional; interrupt/stop use the driver. Shell/dev-server panes keep xterm.

Required debug IDs: `providers-runtime-select-<provider>`, `providers-runtime-reset-<provider>`, `providers-acp-install-<provider>`, `providers-acp-status-<provider>`, `agent-acp-runtime-placeholder-<instance>`, `agent-acp-login-open-<instance>`, `agent-acp-login-retry-<instance>`, `agent-acp-login-cancel-<instance>`. Preserve keyboard labels, disabled reasons and mobile layout.

Bootstrap rendering gets an effective_transport argument. For ACP, replace the user-chat instruction with: messages and answers arrive in session prompts; natural assistant text reaches user chat; use ham-ctl for task/lease/artifact/shell/memory and structured questions/actions. Do not require an ACP assistant to echo every answer with chat send. Keep `./bin/ham-ctl`, token env, TASK.md, MEMORY.md, skills and the canonical Claude bootstrap file. The first prompt remains the starter text. Test auto-load using a unique harmless marker in CLAUDE.md. If the exact adapter does not load it, set a Bridge adapter-version capability `bootstrap_resource_required=true` and add an embedded resource to the first prompt (only when initialize advertises embeddedContext):

```json
{"type":"resource","resource":{"uri":"file:///absolute/bootstrap/run-dir/CLAUDE.md","mimeType":"text/markdown","text":"exact generated bootstrap content"}}
```

This shape follows [ACP content](https://agentclientprotocol.com/protocol/v1/content). Use already-generated local content; do not expose token values. If embedded context is unsupported too, fail `acp_bootstrap_unsupported`; never run without instructions. Resource content includes the generated main bootstrap (which references the other files); it does not inline arbitrary project files. On fresh launch use one mechanism determined by the pinned-version check; on reattach/load do not inject a second system-equivalent bootstrap into history.

## 12. Verification and rollout

Tests live beside changed Odin packages and existing UI/Rust test conventions. Use Nix Odin with `-collection:odin_test=src` and unique binaries under `$HOME/.cache/heimdall-tests`; assert a nonzero test count. This docs-only specification does not claim these implementation tests have run.

| Component | Required tests |
| --- | --- |
| SQL/domain/repository | Apply 211 to full pre-211 DB; preserve profiles/enablement; defaults; canonical-only transport CHECK; recipe/cross-field validation; nullable round trips; ETag changes; runtime snapshot persistence; assistant-turn index uniqueness/transaction rollback |
| Hub API/services | Owned/foreign bridge and instance; omitted/null/invalid fields; combined atomic update; custom-profile transport 422; absent canonical row preserves implicit enabled; capability skew; every launch/wake/reconfigure path; old launch epoch rejection; no running-instance relabel |
| Rust protocol/daemon | Old PTY golden vectors unchanged; every new variant round trip/malformed lengths; pipe child has isatty=false; stdout/stderr separated; stdin receipts; partial writer failure; generation fence; AttachPipe replay split mid-JSON; queue saturation no drop; heartbeat responsive; process-group cleanup; Bridge disconnect child survives |
| RPC client | Fake daemon/agent splits UTF-8/lines; interleaved replies; numeric/string ID isolation; unknown methods/errors; duplicate inbound requests; setup deadlines; no absolute prompt timeout; cancel still accepts final updates; close joins threads; allocator lifetime after request scratch arena destroyed |
| Runtime/recovery | Setup order/model/mode error classification; starter exactly once; prompt FIFO/dedup; stop-intent fence; quiet liveness; Bridge restart at every journal/send/ack boundary; same live PID/session preserved; lost-child load suppresses history; unsupported load/gap errors explicit; no replay of ambiguous tool-bearing prompts |
| Events/permissions | Partial merges; start/end once; late/duplicate terminal update; bounded diff; cancelled/timeouts never allow; opaque option IDs; once-option absent; request worker does not block reader; restored blocker resolves once; ACP hooks disabled |
| Chat | Pending snapshots → complete/failed; unicode/Markdown; stale/out-of-order revision; same revision hash replay; cross-owner denial; one row/one unread/one notification; reload midstream; outage/outbox backpressure; no duplicate history or echo on session/load |
| UI | Runtime shared by profiles; disabled/installation/error/reset states; frozen per-instance transport; no xterm subscription for ACP; pending updates upsert; final fetch and stale event protection; login buttons owner/action state; all interactive debug IDs |
| Bootstrap/adapter | Exact package/version/integrity; Node missing/old; install failure cleanup/concurrency; profile auth isolation; CLAUDE.md marker auto-load or resource fallback; ham-ctl token/endpoint works; zero coordination MCP servers |

Recommended component commands once implementation exists:

```bash
nix develop --command odin test src/hub/repository/sqlite -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/acp-sqlite-$$
nix develop --command odin test src/hub/service/provider -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/acp-provider-$$
nix develop --command odin test src/hub/service/agent -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/acp-agent-$$
nix develop --command odin test src/hub/service/content -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/acp-chat-$$
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/acp-http-$$
nix develop --command odin test src/bridge -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/acp-bridge-$$
cargo test --manifest-path tools/pty_host/Cargo.toml -- --test-threads=1
npm run typecheck
npm test
```

Run through ham-ctl shell in the implementation task Workdir. Start isolated local Hub/Bridge pairs for destructive restart/failure injection; never restart the live production Hub/Bridge as a unit test.

### Real-device acceptance on brg_18e0e5e547267b4e

The final implementation ticket records versions, sanitized request/event captures, instance/session IDs, PIDs and outcomes in `docs/acp-runtime-verification.md`. On this bridge, use an isolated named local runtime attached to a test Hub for restart injection; record its association to the physical bridge. Any final enrolled-bridge smoke is scoped to test instances and must not disrupt other live agents.

1. With default still PTY, install the pinned adapter; verify status ready and set Claude Runtime ACP through Settings. Custom Claude profile inherits it, while another provider remains PTY.
2. Launch Claude ask-mode on ACP with a deliberately selected valid model. Observe pipes/no TTY, v1 negotiation, run_dir cwd, empty mcpServers, successful set_config_option, readiness, and one starter prompt. Verify bootstrap marker and ham-ctl task/context access from that cwd.
3. Send a user message including Markdown/backticks/unicode and get a progressively updating natural assistant response without ham-ctl chat read/send. Verify one durable row changes pending→complete, reload restores it, quick-reply/grouped answer retains metadata, and task/shell notices still work.
4. Execute a harmless read, edit and command in a disposable test project. Observe tool bubbles/diff and an ask-mode permission request; allow once and deny once in separate requests. Cancel a permission/turn and confirm no tool runs due to timeout/cancel.
5. Disconnect/restart only the isolated Bridge midstream. Daemon child PID/generation and ACP sessionId must remain unchanged; pending RPC, chat cursor and blocker restore without duplicate text, tools or starter. Host heartbeat remains responsive under saturated output. This is the primary REQ-ACP-10 pass condition.
6. Separately kill the test adapter to exercise child-loss recovery: new PID, initialize/session/load for saved session, no duplicate replay chat, interrupted turn explicitly failed, fresh prompt succeeds. If the pin lacks loadSession, this step is a failed MVP acceptance requiring adapter investigation; do not mark session/load verified merely because live reattach worked.
7. Use an isolated unauthenticated auth home: get login blocker, open profile-scoped PTY login shell, finish interactive auth, explicitly retry and get ACP response. No agent token in shell; no silent transport fallback. Verify failed login remains actionable.
8. Stop the test instance, verify child/process group gone and final status stopped, clean test shell/project/runtime. Existing PTY agent and shell tests pass. Only after all checks are recorded and reviewed may a separate follow-up migration flip Claude default to ACP.

## 13. Implementation tasks

Seven cohesive tasks; no implementation is delegated by this specification itself.

| Task | Files to touch | Depends on | Acceptance |
| --- | --- | --- | --- |
| T1 Hub contracts/storage/selection | `src/hub/repository/sqlite/migrations/211_provider_transport.sql`, `migrations.odin`, `provider_repo_sqlite.odin`, `agent_repo_sqlite.odin`; `src/hub/repository/iface/provider_repo.odin`; `src/hub/domain/provider.odin`, `agent.odin`; `src/hub/service/provider/provider_service.odin`; `src/hub/service/agent/agent_service.odin`, reconfiguration serializers; `src/hub/transport/http/provider_handlers.odin`, `bridge_handlers.odin`, instance serializers; contract mirrors/tests | — | Exact migration, canonical override semantics, launch snapshot/capability gate on all launch paths, owner validation and ETag tests pass; include assistant-turn index for T5 |
| T2 Daemon pipe mode and Odin codecs | `tools/pty_host/src/dproto.rs`, `daemon.rs`, `host.rs`, new `pipe_host.rs`, module registration; `src/bridge/pty_host_client.odin`, tests | — | New tags/capabilities/pipe lifecycle, generation fencing, receipt and lossless bounded replay tests; heartbeat independent; legacy vectors/tests unchanged |
| T3 RPC client and durable state | new `src/bridge/acp_jsonrpc.odin`, `acp_state.odin` and adjacent tests; pipe I/O adapter | T2 | Incremental framing, id maps/restore, inbound dispatch, bounded queues, atomic checkpoint/partial-line persistence, timeout/teardown tests |
| T4 ACP lifecycle, adapter and bootstrap | new `src/bridge/acp_runtime.odin`, `acp_adapter.odin`; `hub_runtime_client.odin`, `agent_reconcile.odin`, `startup_readiness.odin`, `provider_catalog_cache.odin`, provider profile/discovery modules, `bootstrap_service.odin`, bootstrap prompt templates | T1,T2,T3 | Pinned install/status, launch/model/mode, all operation dispatch, live reattach and child-loss load, bootstrap parity, tests; hooks omitted for ACP |
| T5 Events, permissions and durable chat streaming | new `src/bridge/acp_events.odin`; `extension_ingest.odin`, `extension_permission.odin`, `agent_api.odin`, `vault_decrypt.odin`; `src/hub/transport/http/agent_action_handlers.odin`, route registration; `src/hub/service/content/` assistant operation; iface/sqlite turn repository; `src/ui/api/wsInvalidation.ts`, `src/ui/api/endpoints/chats.ts`, chat reducer | T1,T4 | Exact permission options/replies, no duplicate telemetry; authenticated revisioned sealed chat endpoint/outbox; direct input and streamed pending→complete UI; outage/idempotency/vault-lock tests |
| T6 Settings and login workflow | `src/ui/components/settings/ProvidersPanel.tsx`, `components/providers/ProviderProfilesSurface.tsx`, `providerSetupApi.ts`, `components/chat/AgentPaneComposerPanel.tsx`; UI instance API mirror; Hub owner-scoped acp-login route/command, shell-session service integration; Bridge blocker/action dispatch | T1,T4,T5 | One provider-wide Runtime control, install/status UI, frozen instance placeholder, no ACP xterm, actionable PTY login/retry/cancel, debug IDs and UI/API tests |
| T7 Claude real-device acceptance and rollout evidence | `docs/acp-runtime-verification.md`, integration fixture/tests and targeted fixes to T1–T6 components | T1–T6 | All §12 device steps including restart/load/login pass, PTY regression checks pass; reviewed evidence and separate default-flip follow-up proposed |

T1 and T2 can proceed independently; T3 follows T2; T4 integrates them; T5 then T6; T7 is the release gate. Keep tasks at this scale rather than one ticket per enum/field. Every implementation handoff reports exact checks and commits; never push.

## 14. Risks and mitigations

| Risk | Mitigation / release condition |
| --- | --- |
| Bridge restart loses RPC framing or pending tool permission | Persist partial line, pending IDs/roles and blockers before stdout ack; replay/fence tests at every boundary |
| Child loss cannot safely resume an in-flight tool-bearing turn | session/load restores history only; fail ambiguous turn, never resubmit automatically; explicit fresh input |
| Slow/offline Hub stalls model | Bounded durable outbox and lossless daemon backpressure; heartbeat/stop use independent control path |
| Piped daemon protocol skew silently makes a PTY | New SpawnPipe tag and capability gate; never encode pipe mode as an ignorable legacy field |
| Profile transport split | Canonical settings row, SQL constraint, 422 on custom-profile transport; all profiles resolve through provider |
| Adapter auth/config/bootstrap differs from CLI | Pin, isolated profile tests, marker/resource fallback and login blocker; default remains PTY until evidence |
| Adapter config IDs/mode values drift | Discover session option IDs, validate exact model/value, pin version and fixture its responses; fail clearly |
| Duplicate chat/unread/push on retries/replay | Transactional unique turn key, full snapshots/revisions/hashes, terminal immutability, replay_only recovery |
| Secrets leak through stderr, List or WS | Safe bounded diagnostics; no token metadata; existing scoped token/vault auth, sealed durable chat, metadata-only updates |
| Installing a package mutates shared host unexpectedly | Versioned Bridge-owned staging/lock/atomic promotion; no global install/project mutation; preserve lock/integrity |
| Daemon restart loses pipe queues/receipts | Distinct child generation; initialize+load, explicit interrupted turn; no exactly-once claim across daemon death |

Confidence for implementation readiness depends on the specified fixtures and live gate. Package publication and protocol documentation establish contracts, not a successful Claude login/bootstrap/recovery run on this device.
