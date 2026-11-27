# Per-provider runtime transport and Claude ACP MVP

This specification adds ACP (Agent Client Protocol) beside PTY execution. The Hub selects a transport per provider per bridge; `ham-pty-host` owns either the existing PTY child or a new child with pipes. The Bridge drives ACP v1, translates events into existing Heimdall surfaces, and streams natural assistant text into durable chat. Coordination remains `./bin/ham-ctl`. Claude keeps `pty` as its catalog default until the real-device acceptance passes.

Status: implementation specification, 2026-11-18. Approved inputs: [plan](artifact://art_18e9124cfc75a9c2), [comparison](artifact://art_18e8badae3e44864), and subsequent chain decisions. Those decisions supersede the plan's deferrals of piped hosting, streaming, adapter status, and login fallback. This document specifies proposed changes; it does not assert they already exist. Existing-source references were read at `7ccd2d909c34e2c6c0d985adeba40d2a4e06442f`; paths and line numbers below are relative to that repository revision.

## Provider registry (R1, 2026-11-27)

Three sources describe a provider, each owning different facts, linked by the provider id:

| Source | Owns | Where |
| --- | --- | --- |
| Provider registry (`Provider_Descriptor`) | Identity and traits: display name, aliases, telemetry symbol, default CLI binary, `--version` format, config-dir convention (profile field, env var, home default, config file, history dir), profile fields, extension kind, model probe, install and auth guidance | `src/contracts/provider_descriptor.odin` (compiled) |
| Hub catalog row | Launch recipe, models, state (active/inactive), extension descriptor | SQLite `provider_catalog` (migrations) |
| ACP recipe (`ACP_Provider_Descriptor`) | ACP/app-server runtime: launch kind, package pins, argv, permission binding; for detect-only (System) runtimes `pkg.version` is the minimum CLI version | `src/contracts/acp_provider.odin` (compiled) |

Shared code reads provider facts through one resolver each and never compares provider names (G7, G9):

- Binary: `bridge_provider_resolve_binary` (profile `binary_path`, else the registry binary; a catalog-only slug uses the catalog row's binary).
- Version: `bridge_provider_cli_version` / `bridge_provider_cli_version_check`, parsing with `contracts.provider_parse_cli_version`; the minimum is `contracts.provider_min_version` (derived from the System ACP recipe) and `contracts.provider_version_status` is the only comparison.
- Config directory: `contracts.provider_config_dir_resolve` (bridge: `bridge_provider_config_dir`): profile field, else the CLI's env var, else the home default.
- Context window: `bridge_context_window_resolve` over `src/bridge/context_windows.json`, whose provider ids must be registered.

The catalog `binary` column and the registry `binary` must agree, and every active catalog row must have a registry descriptor (and vice versa): `test_provider_catalog_matches_provider_registry` (`src/hub/repository/sqlite/provider_catalog_migration_test.odin`) enforces it. An ACP recipe must belong to a registered provider whose binary it launches (`acp_descriptor_shape_valid`).

## Provider descriptor contract (C1, 2026-11-19)

The compiled closed registry in `src/contracts/acp_provider.odin` owns executable behavior. Catalog recipes select an exact trusted descriptor; they cannot supply extra commands, arguments, environment values, fields, protocol versions or package pins. A valid Claude recipe copied onto another provider is rejected by both Hub and Bridge.

| Provider | Enabled ACP descriptor | Launch | Package / protocol | Bootstrap fallback | Permission binding |
| --- | --- | --- | --- | --- | --- |
| Claude | `claude-acp`, revision 1 | Adapter | `@agentclientprotocol/claude-agent-acp@0.108.0`, pinned SHA-512; ACP v1 | `CLAUDE.md` | `model` category; `mode` category with ask=`default`, yolo=`bypassPermissions` |
| Copilot | `copilot-acp`, revision 1; opt-in ACP, PTY default | Native `<resolved-copilot> --acp --stdio` | `@github/copilot@1.0.114` + linux-x64 native package, pinned SHA-512; ACP v1 | `AGENTS.md` | `model` config category; bridge-owned ask/yolo, unique once-only decisions |
| Kiro | `kiro-acp`, revision 1; ACP only (no PTY transport) | System `<detected kiro-cli> acp --agent-engine v3` | User-installed `kiro-cli` ≥ `3.5.0` on linux/darwin, detected and never installed; ACP v1 | `AGENTS.md`, embedded or as a baseline `resource_link` | `model` category (catalog `default` keeps Kiro's own model); bridge-owned ask/yolo, unique once-only decisions |
| Codex | `codex-app-server`, revision 1; opt-in ACP, PTY default | System `<detected codex> app-server` | User-installed `codex-cli` ≥ `0.162.0`; Codex app-server NDJSON driver | `AGENTS.md` as `developerInstructions` | Catalog model; bridge-owned ask/yolo and method-specific once-only decisions |
| Pi | None | PTY | No native ACP mode or adapter enabled | Existing PTY catalog behavior | Existing PTY behavior |

Descriptors distinguish native and adapter launch shapes and carry exact package/platform SRIs, CLI/version requirements, protected executable/environment bindings, trusted authentication guidance and config categories. Native shapes require the native CLI pin and explicit platform package pins. Shape validity alone does not register or enable a provider.

Bootstrap reads the safe catalog filename, falling back to the descriptor filename. The filename is frozen in each launch binding and supplies both the embedded resource URI and exact file bytes. Authentication guidance comes from the trusted descriptor and names the selected profile; agent-supplied terminal commands are never executed.

The package tree and stable advisory lock are shared per provider + descriptor ID/revision + package version tuple. Probe receipts live at `heimdall-probes/<profile>.json` within that tree and bind the selected profile/version; the old integrity-only receipt cannot validate them. A selected profile without a matching receipt receives its own isolated initialize probe before launch. Probes strip `HEIMDALL_*`, and actual authentication remains the selected profile's `session/new`/`session/load` result. npm installation disables lifecycle scripts. No per-profile package trees or profile-install endpoint/UI are added.

The runtime journal now binds provider, descriptor ID/revision, package name/version/SRI, resolved CLI version, profile ID/revision, platform and bootstrap filename. Restore rejects mismatches and compares saved provider/profile against the Hub launch intent. Dead-child recovery resolves the same profile and CLI version before spawning. New runtime journals use inner schema `3` (encrypted envelope stays `2`) and binding version `1`; their identity is strict. Pre-C1 Claude `0.108.0` journals with schema `1` receive a one-time compatibility migration only when the saved profile is nonempty and matches the authoritative Hub launch intent, the profile still exists, the managed bootstrap manifest matches the instance, and the entire checkpoint validates. Because old journals never stored CLI version or profile revision, this coordinator-approved boundary freezes the current matching profile revision and resolved CLI version. The bridge logs `ACP_LEGACY_BIND` once and atomically rewrites the journal before reattaching. Migration sends no initialize/new prompt and preserves session, RPC/delivery IDs, receipts, input queues and outbox. Ambiguous or corrupt legacy state reports typed cause `acp_restart_required` and requires an explicit restart.

This format upgrade is one-way: do not downgrade to pre-C1 bridges after rewriting a journal. Old bridges reject inner schema `3`. The valid legacy Claude package tree/lock at `bridge/acp-adapters/claude/0.108.0` stays in place beneath live children; its pinned files are reverified and its marker is upgraded automatically with a fresh isolated probe. No manual reinstall is needed for a valid tree. Other providers/descriptors cannot use this compatibility path.

The existing `acp_adapter` status field and `install_acp_adapter` command name remain wire-compatible. Status adds `provider`, `profile` and `runtime_kind` (`adapter`, `native` or `system`); Hub readiness validates descriptor/provider identity, and UI wording follows the runtime kind. Installation readiness remains independent from selected-profile authentication.

C1 does not change SQLite schema or the enabled catalog recipe, so it needs no migration or catalog ETag update. Numbered migrations on the required `origin/main` base run through `223`; any later catalog/schema change must append after the current maximum. Released migrations remain unchanged.

### Copilot C2 installation and validation boundary

The Copilot descriptor currently supports only Linux amd64. Its installer embeds reviewed `acp_pins/copilot/package{,-lock}.json`, runs `npm ci --ignore-scripts`, and verifies the complete frozen lock plus the launcher/native package identities before promotion. The native executable is the selected profile's resolved CLI and must report exactly `1.0.114`; an installed older CLI never supplies readiness. `COPILOT_AUTO_UPDATE=false` is protected against profile overrides. Credentials and `COPILOT_HOME`/`COPILOT_PROVIDER_*` remain selected-profile environment values and are excluded from bindings and diagnostics. Shared package readiness does not certify authentication.

On NixOS x86_64, build the pinned host package with:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#copilot-acp --out-link .nix-build-links/copilot-acp
python3 tests/copilot_acp_smoke.py --binary .nix-build-links/copilot-acp/bin/copilot
```

Set the selected profile's binary path to the resulting `bin/copilot`. This derivation checks the same native npm tarball SRI, patches its ELF interpreter and library paths, preserves the Node SEA payload, and wraps auto-update/certificate settings. It does not invoke the raw glibc loader, replace the system Copilot, override HOME, or modify live services. Its clean-profile install check uses `COPILOT_HOME` and `XDG_CACHE_HOME` in the build scratch directory. Version and unauthenticated initialize/new have been exercised on NixOS; authenticated login/self-resume remain unverified in this environment.

For once-only policy, ask uses the existing permission relay. Yolo responds only to a unique `allow_once` option; missing/duplicate options, cancellation and replay fail closed. Policy stays separate from Copilot's session or reasoning mode and is frozen in the journal as `ask`/`yolo`. Models still use the actual advertised config ID and exact response-selected value. No-steering sessions retain the serialized inbox owner. Migration `224_copilot_acp_transport.sql` advertises ACP as an explicit choice and preserves PTY defaults, profile settings and existing launches; its catalog hash is checked against the Hub and release serializer. Unsupported platforms return `acp_adapter_unsupported_platform` before installation.

Validation boundary (user answer, 2026-11-19): no logged-in Copilot setup is available, so authenticated end-to-end checks are unrun. Real NixOS version/initialize and clean-profile auth-required checks passed. Automated fixtures cover exact config selection, profile env precedence, once-only relay decisions, serialized inbox, token/journal/shim recovery, surviving-pipe reattachment and dead-child `session/load`; the daemon boundary and successful model/backend responses are simulated. Actual authenticated bootstrap/tool/model behavior, saved permissions/enterprise policy, account isolation and session-store compatibility remain unverified. A local-only BYOK config probe timed out in `session/new`; it establishes no BYOK success. No authenticated success or release qualification is claimed.

### Codex app-server runtime (detect-only, 2026-11-22)

Migration `234_codex_acp_transport.sql` adds Codex's `acp` option and keeps `pty` as the catalog default. Existing PTY argv, hooks, profiles, bridge overrides and instance snapshots are preserved. The Bridge detects the selected profile's `binary_path` or `codex` on PATH, parses `codex-cli X.Y.Z`, and requires at least `0.162.0`. **Re-check** runs the protocol driver's `initialize` probe in a scratch directory and certifies the detected version/profile revision; it never installs Codex or requires Node. Hub readiness requires a ready `system` report with an acceptable version and bridge `acp_runtime_v1` support. Authentication remains a launch-time check via `account/read`, with trusted guidance to run `codex login` under the selected profile's `CODEX_HOME`.

The shared ACP runtime selects the Codex app-server driver rather than sending ACP methods to Codex. Its stdio frames use NDJSON, integer IDs and no `jsonrpc` field; initialization enables `experimentalApi`. App-server launches inherit profile/shadow `CODEX_HOME` and disable hooks, notify and the Heimdall PTY plugin for that child to avoid duplicate telemetry. The UI labels the selection **ACP (Codex app-server)** and displays the **Codex app-server runtime** status. The version floor is based on the generated `0.162.0` protocol schema and a real initialize probe; authenticated end-to-end launch/recovery verification belongs to the follow-on smoke task. Ship Hub and Bridge together: older Bridges reject catalogs with an unrecognized Codex ACP recipe and retain their cached catalog.

### Kiro System runtime (detect-only, 2026-11-21)

`ACP_Launch_Kind.System` describes a CLI the user installs on the bridge host. Its descriptor carries no package integrity, Node minimum or platform pins: `pkg.name` is the CLI and `pkg.version` is the **minimum** accepted version (the catalog recipe's `adapter_version`), plus `system_os` and a `cli_version_prefix` for parsing `kiro-cli 3.5.0`. Status is computed live from the selected profile: `missing` (not on PATH or the profile `binary_path`), `outdated` (below the minimum, reporting the detected version), `error` (not runnable, e.g. the glibc build on NixOS, where only the musl build runs; or no probe receipt yet) and `ready` (a receipt binding the detected version and profile revision). The `install_acp_adapter` command is a probe-only **Re-check**: no npm or Node, an initialize probe in a scratch cwd, then the receipt. Hub readiness requires `runtime_kind: "system"` and a version at or above the minimum.

Kiro keeps settings under `KIRO_HOME` and its credential store (`kiro-cli/data.sqlite3`) under `XDG_DATA_HOME`, so a Kiro profile's `config_dir` sets both (`XDG_DATA_HOME=<dir>/data`); without one the user's own login is inherited. Passing any v2-only flag (`--model`, `--agent`, `--trust-all-tools`) silently switches `kiro-cli acp` to its v2 engine, so the fixed argv pins `--agent-engine v3` and nothing else. Signed-out kiro-cli 3.5.0 reports `embeddedContext:false`; its descriptor opts in to `bootstrap_resource_link`, so the first prompt links `AGENTS.md` (baseline ACP) instead of failing with `acp_bootstrap_unsupported`. Claude and Copilot do not opt in. Kiro's model ids are visible only when signed in, so migration `232_kiro_acp_provider.sql` lists only the `default` model, which sends no `session/set_config_option`; an unlisted model still fails with `acp_model_unavailable`.

Validation boundary (user answer, 2026-11-21): no Kiro account or API key is available. Real kiro-cli 3.5.0 (musl, sha256-checked) `--version`, signed-out initialize and the `-32000` auth error on `session/new` were exercised on dawnstar; signed-in behaviour (embeddedContext, model options, permission option kinds, reading the linked bootstrap) is unverified. Bridges without this descriptor reject a catalog containing the Kiro ACP row and keep their cached catalog until updated.

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

The driver owns the tool map in memory and serializes dirty state at checkpoint. Keep open tools separately from compact completion receipts: retain at most 128 recent completed IDs/diff hashes, evicting older receipts first under the 2 MiB journal budget. Telemetry pressure must never terminate the agent: discard cached content/rawOutput from the largest open tools first, then rawInput, preserving IDs, names and start/end state. Terminal events mark discarded detail with `telemetry_truncated`. The 512-tool resource cap applies to concurrently open tools, never the lifetime count; excessive count or metadata settles the largest open telemetry records with failure/`telemetry_capacity`, leaving the RPC turn running. Prompt completion, cancellation or failure closes any remaining open records once with failure and the stop reason, then retains compact receipts so late terminal updates cannot duplicate ends. Pipe sequence fencing covers already acknowledged history. Corrupt restored tool state is an explicit `acp_protocol_error`.

Example normalized event, matching the [existing parser](../../src/contracts/extension.odin):

```json
{"schema":"ham.ext.v1","event":"tool.start","provider":"claude","ext_version":"acp-0.108.0","ts":"2026-11-18T00:00:00Z","session_id":"session-example","tool":{"name":"Bash","use_id":"call-1","input":{"command":"pwd"}},"payload":{}}
```

Do not fabricate usage/token counts from text; map only values actually reported with supported semantics. Disable provider-native hook installation for ACP to avoid duplicate telemetry. File edit locations/content follow [ACP tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls); all filesystem paths remain data, never shell fragments.

### Permission request routing

**Implementation amendment (T9):** interactive permissions are implemented through the existing extension permission relay. Each request has a journaled stable blocker ID and a separate worker; the dispatcher owns the single reply. Ask mode uses the interactive flow below; yolo remains `bypassPermissions`. Both modes only select the adapter’s once options if a permission request arrives.

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

**Push-only fetching (T13):** the Bridge drains the durable inbox on launch/restore,
on `notify_agent_message` (`acp_chat_notify`), and once for every live ACP chat after
each successful Hub WebSocket ready handshake. Reconnect recovers notifications
missed while disconnected. There is no periodic inbox fetch. A failed drain retries
after 1, 2, 4, 8, 16, then 30 seconds (capped); success clears retry state. A fresh
push or ready edge triggers a drain immediately, bypassing an old retry deadline. Pushes
coalesce in an atomic latch, including pushes received during a drain; retries retain
the checkpoint-before-ack and message-ID deduplication rules below.

Bridge list requests set `params.input_source="bridge_acp"` and `mark_read=false`.
The Hub validates the normal Bridge/instance authority, ACP transport and own-inbox
target before accepting that source. These infrastructure fetches publish no
`chat_fetch`/`chat_read` activity bubble. Empty reads also publish none; a model's
ordinary nonempty `ham-ctl chat read` still publishes its activity. Ack-only requests
continue to contain only `ack_message_ids` and emit the existing read receipt event.

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

Append assistant text to a geometrically growing byte buffer; wipe old allocations on resize and wipe the retained capacity on reset/destroy. Publication treats an immutable-terminal 409 as already satisfied, including when a newer revision coalesced during the request. Network failures, 408, 429 and 5xx retain the same retry payload; other 4xx persist `acp_chat_publish_rejected` and stop publication retries, preserving the rejected outbox for diagnosis.

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

**MVP authentication:** auth-required errors create a stable startup blocker per launch epoch with reason `acp_auth_required` and an empty actions array. UI instructs the user to run `claude /login` on the bridge host with the profile's environment/config directory, then use the existing Restart agent control. Startup and unknown blocker kinds never receive Allow/Deny actions.

**Deferred post-MVP login workflow (not implemented):** auth-required initialize/new/load/prompt errors (`-32000` or the pinned adapter's documented auth-required error) would extend the startup blocker with actions `open_login_shell`, `retry_acp`, `cancel_launch`. Use a stable ID per launch epoch and reason `acp_auth_required`; do not classify arbitrary provider/network errors as auth. A future authenticated Hub action `POST /api/v1/agent-instances/:id/acp-login` would accept `{action:"open_login_shell"|"retry_acp"|"cancel_launch"}` and send a launch-fenced Bridge command `acp_login_action`. Owner scope, bridge binding, current ACP launch and blocker existence would be required. It would return 202 plus shell_session_id for an opened shell. Repeating open for the same blocker would return the existing live shell. The remainder of this login-shell workflow is deferred with that endpoint.

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

The provider-status response includes `acp_runtime_supported`, derived using the Hub's `contracts.bridge_supports_acp_runtime` check. Absent capability disables ACP with an upgrade reason. Its existing `extension_commands` array includes the latest command per provider/profile/kind for `install` and `install_acp_adapter`. UI polls only while an ACP install command is active, stops waiting after 150 seconds, and offers an explicit Check status action without starting another install. Instance change summaries carry `runtime_transport` and `launch_epoch` so relaunches update mounted panes from the frozen snapshot.

Instance API/state adds `runtime_transport` from the frozen launch snapshot. Add that prop to AgentPaneComposerPanel and gate terminal-hook/xterm mounting in a child component: ACP renders “Structured runtime — conversation and tools appear in chat” with adapter status and startup blocker actions. Never subscribe to the PTY stream for ACP or infer its transport from a provider setting changed after launch. The chat composer stays functional; interrupt/stop use the driver. Shell/dev-server panes keep xterm.

The ACP placeholder offers Interrupt (`agent-acp-interrupt-<instance>`); Esc/Ctrl+C while the pane is focused uses the existing pane-input request with Ctrl+C, dispatched by the Bridge to the ACP driver. Stop/restart remain in the existing instance controls. Authentication blockers disable interrupt and show only the bridge-host login instruction.

Required MVP debug IDs: `providers-runtime-select-<provider>`, `providers-runtime-reset-<provider>`, `providers-acp-install-<provider>`, `providers-acp-status-<provider>`, `agent-acp-runtime-placeholder-<instance>`. Check status uses `providers-acp-check-<provider>`. The login-workflow IDs `agent-acp-login-open-<instance>`, `agent-acp-login-retry-<instance>`, `agent-acp-login-cancel-<instance>` are deferred. Preserve keyboard labels, disabled reasons and mobile layout.

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

## 15. ACP priority inbox (T16)

The bridge owns input scheduling; the adapter's prompt queue is not a notice
debouncer. The pinned `@agentclientprotocol/claude-agent-acp@0.108.0` v1 source
(`dist/v1/acp-agent.js`, `dist/v1/steering.js`) advertises two distinct capabilities:

```json
{
  "agentCapabilities": { "_meta": { "claudeCode": { "promptQueueing": true } } },
  "_meta": { "steering": { "supported": true } }
}
```

Concurrent ordinary `session/prompt` requests enqueue separate adapter turns;
each request stays pending until its turn finishes. For a user message during a
running turn the bridge instead sends this extension **request**, without
starting another prompt/chat/tool lifecycle:

```json
{
  "jsonrpc": "2.0",
  "id": "ham:example:2",
  "method": "_session/steering",
  "params": {
    "sessionId": "existing-session",
    "prompt": [{ "type": "text", "text": "Change direction" }],
    "_meta": { "steering": { "idleBehavior": "promptRequired" } }
  }
}
```

`{"outcome":"injected"}` means the content joined the running turn and output
continues under the original `session/prompt`. If the turn finished during the
race, `{"outcome":"promptRequired","reason":"noRunningTurn"}` means the
adapter consumed nothing; the bridge submits the saved input through an ordinary
prompt once the original response settles. Omitting `idleBehavior` permits the
adapter's legacy `startedNewTurn` detached fallback, which Heimdall deliberately
does not use. Missing capability or a method-not-found response falls back to
append-to-next-turn. An ambiguous transport failure retains the pending request;
it does not silently resend the content as a new turn. The adapter uses SDK
priority `later` while a permission/elicitation is open, otherwise `now`.
Steering reduces ACP turn requests; it does not promise that the SDK makes only
one underlying model generation, since preemption can start another generation.
The [upstream steering example](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/examples/steering.ts)
describes the same extension; the installed pin is authoritative for this implementation.

| Lane | Inputs | Scheduling |
| --- | --- | --- |
| Steer | Direct chat/raw user input; interrupt task notices (`pausing`, `finishing`, or explicit interrupt) | Prompt immediately when idle; inject into the running turn when supported; otherwise append to the next turn |
| Batch | Task ready/assigned/changes requested, shell completion, other actionable origins | One notice digest after 2 seconds quiet, with a 10 second maximum debounce |
| Digest | `review_requested_from_user`, `hold_stale`, `work_batch_finished`, `agent_not_running`, title nudge | Never starts a turn; added inside `<heimdall_notice_digest>` to the next real prompt |

Classification uses existing Hub `origin`, falling back to `target_role`, and
explicit shell/title command types; human prose is never inspected for priority.
The existing PTY delivery/debounce/interrupt branches retain their behavior.
ACP bypasses the older task-only nudge debounce, which would discard different
kinds for one task. Notices with the same `(task_id, kind)` replace queued content
with the latest, retaining the superseded delivery's dedupe receipt. Coordinator
alerts which omit `task_id` keep their distinct command identities, so two tasks
in one chain cannot overwrite one another. Shell notices use `session_id`.

All accumulated notices, including a restored backlog or notices received during
a long turn, are consumed in one digest rather than one prompt per notice.
User inputs retain priority and their individual identities. A per-agent budget
allows one autonomous notice turn per 60 seconds by default. Set bridge process
environment `HEIMDALL_ACP_NOTICE_INTERVAL_MS` to configure it (clamped to
1,000–3,600,000 ms; invalid/unset values use 60,000). This applies to Batch turns;
user/control Steer input remains immediate. Overflow is demoted to Digest and
stays context even after the budget refills; a fresh actionable/user input is
needed to consume it. The budget timestamp is journaled across bridge restart.

The RPC dispatcher owns timers and all queue mutations, including when no chat
worker is active. Durable admission precedes the Hub acknowledgement. The runtime
journal contains lane/key/kind, debounce and budget timestamps, pending steering
content and its semantic RPC role. A live reattach restores that completion and
the original prompt instead of reinjecting; stdin receipts keep the existing
daemon delivery dedupe. Legacy untyped `notice_` FIFO entries migrate to Batch on
restore. Existing `msg_` admission acknowledgements and the bounded 256-input
dedupe window remain. The inbox preserves the previous journal limit of 128
entries, each at most 256 KiB (including a pending steer); new notices are limited
to 112 slots, reserving 16 for real input. Excess admission returns false for
retry, with no silent eviction. A prompt consumes at most 512 KiB of inbox text;
larger legacy backlogs retain the remainder as Digest for later real turns rather
than failing restore or generating repeated autonomous turns. Child/daemon loss
still follows the existing explicit interrupted
turn policy rather than claiming exactly-once provider execution across process death.

### Live pin spike, 2026-11-19

`tests/acp_steering_live.mjs` ran the actual adapter and installed Claude executable
using the isolated provider home of named bridge `t16-acp`
(`brg_18e96f5dd4210a46`, bridge port 49947, local endpoint 49948) enrolled against
the existing isolated `t12-acp` Hub. This is a direct adapter API spike under that
bridge's isolated home; it does not claim a browser/managed-agent routing test.
No production bridge, provider configuration, or managed agent was restarted.

```bash
ACP_ADAPTER_ENTRY=/home/tanmay/.local/share/heimdall/bridges/heimdall-bridge-hub-mundus-in/bridge/acp-adapters/claude/0.108.0/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js \
ACP_ISOLATED_HOME=/home/tanmay/.local/state/heimdall-local/bridges/t16-acp/home \
node tests/acp_steering_live.mjs
```

Captured in shell session `sh_fcfe5775503640609b67784e6eebd849` (exit 0):

```json
{"steering":{"supported":true},"claudeCode":{"promptQueueing":true}}
{"sessionId":"43dab704-6110-4a1b-8d8a-60a0bff300a2"}
{"idle":{"outcome":"promptRequired","reason":"noRunningTurn"}}
{"active":{"outcome":"injected"}}
{"result":{"stopReason":"end_turn"},"promptRequests":1,"sawSteeredAnswer":true}
```

The active probe asked for a harmless `sleep 12`, injected a new final-answer
instruction at its tool call, and observed `STEERED_T16` through the original
prompt. The isolated bridge was stopped after the check. Deterministic fake-agent
tests in `src/bridge/acp_inbox_test.odin` cover lanes, latest-wins/delivery dedupe,
debounce/cap, budget overflow, dispatcher timer, long-turn/restore merging,
admission bounds/write failure, idle race, unsupported fallback, and restoring
pending steering without a second prompt.

Final verification on this worktree:

- Focused inbox set: 10/10 passed (`sh_da2e8888f8d79369bc1470721bc1abf2`).
- Full bridge package: 1,164/1,164 passed (`sh_595974886ed6e998e7a9c6fd8c5f0fe1`).
- Unchanged Rust PTY suite: 193 passed, 2 expected child-helper ignores,
  0 failed (`sh_3b44911625f3f20c3ba44960320d0770`).
- Nix bridge package build passed (`sh_aeff6db4b92e4810440f0e9edf1e32c9`).
- Live pin spike, JavaScript syntax check, and `git diff --check` passed.

```bash
nix develop --command unshare --user --map-root-user --mount bash -c \
  'mount -t tmpfs tmpfs /tmp && mount -t tmpfs tmpfs "$HOME/.cache/heimdall-tests" && mkdir -p "${TMPDIR:-/tmp}" && exec setpriv --bounding-set=-dac_override,-dac_read_search bash scripts/dev-odin.sh test src/bridge -define:ODIN_TEST_THREADS=1'
nix develop --command cargo test --manifest-path tools/pty_host/Cargo.toml -- --test-threads=1
nix build .#ham-bridge --out-link .heimdall/t16-package-final
node --check tests/acp_steering_live.mjs
git diff --check
```

The private tmpfs namespace accelerates existing migration-heavy fixtures while
retaining their fsync calls and DAC checks; these are functional recovery checks,
not a physical-disk durability certification. No UI or Hub packages changed;
their separate suites were not run for this bridge-only task.

### Conversation response and tool status

The pending ACP assistant message drives **Responding…** in the shared conversation
tail status line. Completion and failure snapshots remove that status immediately;
the partial assistant body remains inside its transcript message.

ACP tools use the same viewer-scoped stream as PTY tools:
`acp_events_tool` → `bridge_ext_ingest` → `bridge_tool_live_event` →
`tool_stream_state` → `tool_live_apply_bridge` → `toolActivitySlice` →
`LiveToolActivity`.
The Hub extension history endpoint is retired. `agentActivitySlice` supplies CLI
action labels separately.

Thought chunks update runtime liveness directly. Emitting `activity(active)` for
each chunk incorrectly told the shared reducer that another turn had begun,
settling in-flight tools as interrupted before the next stream batch. ACP emits
that lifecycle event only when a prompt starts. Event timestamps retain
nanoseconds, and the live reducer parses the complete fraction (the pinned Odin
parser reads only hundredths), so fresh calls survive reset fences. Failures carry the shared
`status=error` field. Existing toolCallId receipts deduplicate start/end updates
and diff digests deduplicate file edits.
