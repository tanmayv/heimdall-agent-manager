# Hub-Owned Provider Catalog, Explicit Models & Ephemeral Run Validation

**Design & Implementation Plan**
**Document Location**: `docs/plans/provider-catalog-and-model-verification-plan.md`
**Requirement IDs**: `REQ-PROVIDER-CATALOG-1` … `REQ-PROVIDER-CATALOG-7`
**Status**: Architecture locked against approved provider-setup mock — not yet implemented
**Target Subsystems**: `src/hub/`, `src/bridge/`, `src/lib/config/`, `src/lib/agent_runtime/`, `src/ctl/`, `src/ui/`
**Backward compatibility**: None required. Deprecation replaces compatibility; `hub.db` may be wiped in dev.

**Supersedes**:
- `docs/plans/bridge_provider_seeding_onboarding_audit.md` (`REQ-PROVIDER-SEED-AUDIT-1`)
- `docs/plans/onboarding-wizard-and-provider-discovery-plan.md` (`REQ-WIZARD-*`)

Both prior plans try to repair the bridge-authored seed model. This plan deletes that model
outright, so their proposals no longer apply.

**Supported providers (fixed set)**: `claude`, `codex`, `copilot`, `antigravity`.
Users cannot add providers. `jetski` and `pi` are removed — see §3.3.

---

## 1. Problem Statement

### 1.1 The recipe exists in three drifting copies

A provider "recipe" (binary, flags, model list, prompt delivery, bootstrap file, skill dir,
startup detection) is independently hardcoded in:

| Location | Providers defined |
|---|---|
| `src/bridge/provider_seeds.odin:19` (`BRIDGE_PROVIDER_SEEDS`) | claude, codex, copilot, antigravity |
| `src/ui/components/settings/providerCatalog.ts:22` (`SUPPORTED_PROVIDER_PRESETS`) | claude, **jetski**, antigravity |
| `config.toml:13` (`default_agent_provider_profile`) | **pi** |

The three sets disagree. `jetski` and `pi` appear in no other list; `config.toml` defaults every
generated agent to a provider that does not exist in the bridge seed table.

### 1.2 Capabilities are asserted, not measured

`bridge_provider_profile_from_seed` (`src/bridge/provider_store.odin:449`) sets
`enabled = true` unconditionally. `bridge_provider_capabilities_json`
(`src/bridge/provider_store.odin:586`) then advertises every enabled profile to the hub in
`bridge_hello`. A bridge therefore claims it can run all four CLIs whether or not any binary is
present, and fleet dispatch routes work to bridges that cannot execute it.

PATH detection does exist — `bridge_provider_detect_supported_json`
(`src/bridge/provider_store.odin:987`) — but it is a separate on-demand relay that no install or
enrollment path invokes. Its only consumer, `bridge_provider_enable_selected_json`
(`src/bridge/provider_store.odin:1017`), re-seeds from the same hardcoded table it was meant to
validate.

### 1.3 A full PATH scan on every agent launch

`src/bridge/pty_host_runtime.odin:149` → `bridge_runtime_agent_argv_for_profile` →
`bridge_runtime_resolve_provider_executable` (`src/bridge/provider_store.odin:1102`) →
`bridge_runtime_find_on_path` (`src/bridge/hub_runtime_client.odin:2014`), which reads `$PATH`
and `stat`s every directory entry. This happens per launch, and the result is discarded.

### 1.4 `tier` is an indirection that buys nothing

`tier` has exactly one use: `resolve_model_value(profile.models, tier)` at
`src/lib/agent_runtime/runtime.odin:30` maps `cheap|normal|smart` to a model string. There is no
cost-based routing, no scheduling input, no policy attached. It is a three-valued enum standing in
front of a string, costing ~1200 references across the tree (`src/hub/service/agent/agent_service.odin`
66, `src/ui/components/tasks/fleetSelection.ts` 124, and 68 other files).

### 1.5 An empty model silently runs the wrong model

`src/lib/agent_runtime/runtime.odin:30`:

```odin
if profile.models.flag != "" {
    model := cfg_lib.resolve_model_value(profile.models, tier)
    if model != "" {
        append(&argv, profile.models.flag)
        append(&argv, model)
    }
}
```

An unresolvable tier appends no `--model` flag at all, so the CLI runs on its vendor default and
the launch reports success. A wrong-model run is indistinguishable from a correct one.

### 1.6 Four-level default resolution can launch what nobody chose

`src/hub/service/agent/agent_service.odin:1248`:

```odin
provider := first_non_empty(req.provider, support.provider, default_provider_from_bridge(bridge), "")
tier     := first_non_empty(req.tier, support.tier, agent.default_tier, default_tier_for_provider_from_bridge(bridge, provider))
```

Repeated at `:1264` and `:1359`. Any of four sources may supply the answer, so an instance can run
on a provider the user never selected with a model that does not exist for it.

### 1.7 The Providers panel wakes every bridge to render

`src/ui/api/endpoints/bridgeSupport.ts:246-247` fans out `/bridges/:id/providers` **and**
`/bridges/:id/detected-providers` per bridge. Both are WebSocket relays into the live bridge
(`bridge_provider_relay`, `src/hub/transport/http/bridge_handlers.odin:1220`). The panel cannot
render for an offline bridge at all, and re-interrogates every online bridge on each open.

---

## 2. Design

### 2.1 Six concerns, one owner each

The defects above share a root cause: three unrelated concerns are stored in the same places.

| Concern | Nature | Owner | Home |
|---|---|---|---|
| **Catalog** — which CLIs exist, their models, flags, icon, launch recipe | editorial data | service provider | hub DB, edited by migration |
| **Availability** — which catalog entries *this machine* can run | measured fact | derived | `bridge_provider_status`, from discovery reports |
| **Location** — where the binary actually lives on this machine | local fact | the bridge | `provider_paths.json` on the bridge |
| **Enablement** — which detected providers the user permits on a bridge | durable choice | hub | `bridge_provider_settings` |
| **Choice** — which provider+model *this instance* runs | a decision | recorded at launch | `agent_instances`, immutable |
| **Test run** — whether one temporary launch reached `start-success` and awaits human validation | ephemeral runtime state | hub memory | `Provider_Test_Run` registry; never a DB result |

Catalog is never authored by a user or a bridge. Availability and location are never authored by
the hub. Choice is never inferred.

### 2.2 Hub schema (`REQ-PROVIDER-CATALOG-1`)

```sql
-- migrations/0NN_provider_catalog.sql
CREATE TABLE provider_catalog (
  provider           TEXT PRIMARY KEY,   -- 'claude' | 'codex' | 'copilot' | 'antigravity'
  display_name       TEXT NOT NULL,
  icon_url           TEXT NOT NULL,      -- hub-relative, see 2.3
  binary             TEXT NOT NULL,      -- SEARCH KEY only; never executed directly
  base_args          TEXT NOT NULL,      -- JSON array
  yolo_args          TEXT NOT NULL,      -- JSON array
  model_flag         TEXT NOT NULL,      -- '--model' | '-m'
  prompt_args        TEXT NOT NULL,      -- JSON array
  prompt_delivery    TEXT NOT NULL,      -- flag-injection | tmux | none
  starter_prompt     TEXT NOT NULL,
  bootstrap_file     TEXT NOT NULL,      -- CLAUDE.md | AGENTS.md
  skill_dir          TEXT NOT NULL,
  startup_detection  TEXT NOT NULL,      -- JSON
  activity_detection TEXT NOT NULL,      -- JSON
  state              TEXT NOT NULL,      -- active | deprecated
  rank               INTEGER NOT NULL
);

CREATE TABLE provider_models (
  provider TEXT NOT NULL REFERENCES provider_catalog(provider) ON DELETE CASCADE,
  model_id TEXT NOT NULL,                -- 'claude-opus-5' — the literal argv value
  label    TEXT NOT NULL,                -- 'Opus 5'
  state    TEXT NOT NULL,                -- active | deprecated
  rank     INTEGER NOT NULL,
  PRIMARY KEY (provider, model_id)
);

CREATE TABLE provider_catalog_meta (
  catalog_etag TEXT NOT NULL             -- sha256 of canonical catalog JSON
);

CREATE TABLE bridge_provider_status (
  bridge_id    TEXT NOT NULL,
  provider     TEXT NOT NULL,
  binary_path  TEXT NOT NULL DEFAULT '',  -- '' = not located
  version_text TEXT NOT NULL DEFAULT '',
  state        TEXT NOT NULL,             -- absent | present
  checked_at   TEXT NOT NULL,
  PRIMARY KEY (bridge_id, provider)
);

CREATE TABLE bridge_provider_settings (
  bridge_id  TEXT NOT NULL,
  provider   TEXT NOT NULL REFERENCES provider_catalog(provider),
  enabled    INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (bridge_id, provider)
);

-- Operational scaffolding only. Provider-test rows are deleted when the run stops.
ALTER TABLE agent_instances ADD COLUMN kind TEXT NOT NULL DEFAULT 'agent';
-- kind: agent | provider_test
```

`provider_catalog` and `provider_models` are seeded by the migration. **Editing these rows is the
service-provider configuration mechanism.** There is no scope column, no per-owner override table,
and no precedence resolution — those were only needed when users could author recipes. The Hub is
already the trusted control plane, but this boundary prevents a browser/client request from
injecting commands: only code-reviewed catalog rows may contribute argv fragments.

**Deprecation replaces backward compatibility.** `state = 'deprecated'` hides a provider or model
from new launches while leaving historical `agent_instances` rows readable and interpretable.

There is deliberately no verification column and no provider-test table. A validation result is
useful only to the person watching that run; it does not become a durable claim about credentials
or future launches. The temporary `agent_instances(kind = 'provider_test')` row exists only because
instance authentication, `start-success`, and terminal streaming already key off that record. It is
excluded from every product projection and deleted after stop or reap.

**Launchable** is one predicate in one place: catalog provider/model active, provider enabled for
the bridge, and `bridge_provider_status.state = 'present'`. A later authentication failure remains
a normal launch failure; a successful test is not treated as a credential guarantee.

### 2.3 Icons

`icon_url` holds a **hub-relative** path (`/api/v1/providers/claude/icon`) served by the hub from
bytes shipped in the migration. Rejected alternatives:

- absolute remote URL — requires network egress, breaks self-hosted and offline installs, adds CSP surface
- UI-bundled asset keyed by name — this is today's `logo` field (`provider_store.odin:35`), a bare
  string that no UI code renders, and it makes adding a provider require a UI release

The bridge never receives or needs the icon.

### 2.4 Bridge local state (`REQ-PROVIDER-CATALOG-2`)

Two files with **different ownership semantics**. Conflating them is the mistake this section exists
to prevent.

| | `<data_dir>/bridge/provider_catalog.json` | `<data_dir>/bridge/provider_paths.json` |
|---|---|---|
| Authored by | the hub | the bridge, by probing |
| Contents | display name, icon_url, model list, model_flag, base/yolo/prompt args, prompt delivery, bootstrap file, skill dir, startup/activity detection | resolved absolute path, version text, probed_at, last probe outcome |
| On conflict | hub wins, replaced wholesale | **bridge wins** — the hub is never authoritative on where a binary lives |
| Sent to hub | never (it is a replica) | reported for display only, never as authority |
| Refreshed | etag miss on connect, or catalog edit | explicit Hub-requested discovery, or stale-path miss at launch |

The catalog's `binary` field is a **search key** — what to look for. It is never executed.
`argv[0]` always comes from the local path store.

### 2.5 The launch invariant

> **The launch path never contacts the hub, never reads disk, and never scans `$PATH`.**

argv assembly is a pure in-memory join:

```
argv = [ paths[provider].resolved_path ]              -- local, bridge-owned
     + catalog[provider].base_args                    -- cached hub replica
     + catalog[provider].yolo_args
     + [ catalog[provider].model_flag, model ]         -- model from the launch frame
     + catalog[provider].prompt_args + [ rendered_prompt ]
```

Three cache layers, each read by exactly one caller:

| Layer | Lifetime | Read by |
|---|---|---|
| in-memory snapshot | process | every launch, under a read lock |
| the two JSON files | reboots | boot only |
| the hub | — | connect and catalog change only |

Boot reuses the existing load-once latch (`bridge_provider_store_init`,
`src/bridge/provider_store.odin:273`) and the existing atomic tmp-write + `rename` in
`bridge_provider_save_overrides`.

Provider-related bridge↔hub traffic after this change: one etag comparison per connect, one body
transfer per catalog edit, an on-demand discovery report when the Hub requests one, plus
user-initiated test runs. A normal reconnect does not scan `$PATH`, and a normal agent run sends
**zero provider-discovery traffic**.

### 2.6 Protocol frames

| Direction | Frame | When |
|---|---|---|
| hub → bridge | `ready` gains `catalog_etag` | every connect |
| bridge → hub | `provider_catalog_request` | cached etag differs |
| hub → bridge | `provider_catalog` (full body) | answering a request |
| hub → bridge | `provider_catalog_version` | a catalog edit bumps the etag |
| hub → bridge | `provider_discover` (`request_id`, optional provider filter) | enrollment/settings explicitly asks for fresh detection |
| bridge → hub | `provider_discovery_report` (`request_id`, complete requested results) | answering `provider_discover` |
| hub → bridge | `launch_provider_test` (`run_id`, `agent_instance_id`, provider, model, agent token) | user starts a test |
| hub → bridge | existing `stop_agent` | user validates/cancels, test expires, or cleanup runs |

Etag-first negotiation follows `src/bridge/bootstrap_cache.odin`, which already implements
manifest-before-body with sha256 verification for bootstrap fragments. A matching etag transfers
zero bytes and parses nothing.

On a miss: fetch body → verify sha256 → write `.tmp` → `rename` → swap the in-memory snapshot.

Discovery is Hub-initiated and on demand. The Hub correlates the report with `request_id`, updates
`bridge_provider_status`, and returns the fresh rows to the HTTP caller. The browser never supplies
an executable, argv, flags, working directory, or bootstrap content. The Bridge resolves only the
fixed catalog search keys against its own environment.

**Offline**: the cached catalog serves launches indefinitely; only newly added providers or models
are unavailable. **Never-synced bridge**: no cache means launches fail with
`provider_catalog_unsynced`. There is no fallback to hardcoded seeds, because none will exist.

### 2.7 Stale binary paths

A stored absolute path goes stale when the CLI is upgraded, removed, or — this repo is Nix-based —
rebuilt into a new `/nix/store/...` path.

At launch, one `access(path, X_OK)` on the stored path: a single syscall, not a directory walk.
On failure, re-probe that one provider inline, persist the new path, and continue if found; fail
with `provider_binary_missing` naming the stale path if not. The expensive PATH scan runs only when
something actually moved. Any path change pushes a fresh `provider_discovery_report` so
`bridge_provider_status.binary_path` does not drift from reality in the UI.

### 2.8 Snapshot lifetime — a known hazard class in this repo

`AGENTS.md` documents a concurrency defect this codebase has shipped five times: two owners, one
resource. The catalog snapshot is the same shape. `bridge_provider_upsert_override_unlocked`
(`src/bridge/provider_store.odin:364`) frees strings in place before overwriting; if a launch holds
a profile whose strings point into the snapshot while a catalog push replaces it, those strings are
freed underneath the launch.

Rules:

- **Never hand a profile out of the lock.** Build the complete argv under the read lock and return
  owned strings.
- A snapshot is **immutable once published**. A push builds a new snapshot and atomically swaps the
  pointer.
- The old snapshot is freed only when no reader can hold it. With four providers and rare pushes,
  deliberately never freeing it is the correct trade — a few KB per catalog edit over a process
  lifetime. Comment it as intentional so it is not "fixed" into a use-after-free later.

### 2.9 Ephemeral provider tests (`REQ-PROVIDER-CATALOG-5`)

A test answers only whether one concrete provider/model launch reaches the application's existing
readiness signal while the user is watching it. It creates no durable verification, credential, or
launch-gating result.

The Hub holds an in-memory `Provider_Test_Run` registry with this state machine:

```
starting → detecting → awaiting_validation → stopping → stopped
              │                 │
              ├── failed        ├── cancelled
              └── expired       └── expired
```

1. The Hub verifies that the user owns the bridge, the bridge is online, the provider is enabled
   and present, and the requested provider/model pair is active in the catalog.
2. The Hub creates an unguessable `run_id`, an in-memory run record, and a minimal temporary
   `agent_instances(kind = 'provider_test')` row with a normal short-lived agent token. That row is
   operational scaffolding for the existing instance authentication, stream, and `start-success`
   paths; it is not a product agent.
3. The Hub sends `launch_provider_test`. The Bridge derives argv from its cached catalog and local
   path, uses the existing `bridge_bootstrap_materialize_local_provider_test` helper, and launches
   the normal agent runtime. It does not use `shell_sessions` and does not accept executable details
   from the browser.
4. The UI opens the existing
   `GET /api/v1/agent-instances/:agent_instance_id/stream` transport and renders its output/input in
   the test popup. Login prompts, if any, remain interactive in that terminal; there is no separate
   sign-in API or `needs_auth` state.
5. The UI displays **Detecting** until that exact instance calls `agent.start_success`. Only that
   signal moves the run to `awaiting_validation`. It does not mark anything verified and it does not
   stop the process.
6. The user clicks **Mark as validated** only after inspecting the live instance. The Hub moves the
   run to `stopping`, sends the existing `stop_agent`, waits for the terminal state, removes the
   temporary instance/run directory, and reports `stopped`.
7. Cancel, timeout, bridge disconnect, and Hub restart take the same stop/reap path. Limits apply per
   user and bridge so tests cannot be used to create unbounded processes.

Provider-test instances are excluded from every fleet, agent, conversation, capacity, and sidebar
projection. Their `start-success` handler updates only the transient test registry: it must not
create system chat, a conversation, or ordinary lifecycle notifications. No result survives cleanup.

### 2.10 HTTP API contract

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/v1/providers` | Global active/deprecated catalog and models. Hub DB only. |
| `GET` | `/api/v1/providers/:provider/icon` | Hub-shipped provider icon. |
| `GET` | `/api/v1/bridges/:bridge_id/provider-status` | Last-known detection joined with durable enabled settings; never wakes the Bridge. |
| `POST` | `/api/v1/bridges/:bridge_id/providers/discover` | Ask the online Bridge for a fresh scan and return the correlated results. |
| `PUT` | `/api/v1/bridges/:bridge_id/providers/:provider` | Set `{ "enabled": true|false }`; provider-level only. |
| `POST` | `/api/v1/bridges/:bridge_id/provider-tests` | Start a test with `{ "provider": "...", "model": "..." }`. |
| `GET` | `/api/v1/provider-tests/:run_id` | Read transient state and its `agent_instance_id`; owner only. |
| `POST` | `/api/v1/provider-tests/:run_id/validate` | Human validation; initiates stop and cleanup. |
| `DELETE` | `/api/v1/provider-tests/:run_id` | Cancel and clean up an unfinished run. |

All bridge-scoped routes require an authenticated owner and reject archived bridges. Test routes
also require ownership of the run. `run_id` and the temporary instance/token are cryptographically
unguessable. The Hub applies a short TTL, bounded concurrency, idempotent cancel/validate behavior,
and cleanup on disconnect/restart. The test status response contains runtime state and identifiers,
not captured terminal output; output stays on the existing authenticated instance stream.

The response shapes are deliberately small and shared by enrollment and settings:

```json
{
  "bridge_id": "br_123",
  "providers": [
    {
      "provider": "codex",
      "display_name": "Codex",
      "icon_url": "/api/v1/providers/codex/icon",
      "state": "present",
      "binary_path": "/usr/bin/codex",
      "version_text": "codex 1.2.3",
      "checked_at": "2026-10-09T12:00:00Z",
      "enabled": true,
      "models": [{ "model_id": "gpt-5", "label": "GPT-5", "state": "active" }]
    }
  ]
}
```

`POST .../provider-tests` returns `201` with the same shape as subsequent status reads:

```json
{
  "run_id": "ptr_...",
  "bridge_id": "br_123",
  "provider": "codex",
  "model": "gpt-5",
  "agent_instance_id": "provider-test-...",
  "state": "detecting",
  "expires_at": "2026-10-09T12:05:00Z",
  "error": null
}
```

Discovery times out with `504` if the correlated Bridge report does not arrive. Enabling an absent
provider returns `409`; disabling is always allowed. Starting a test returns `409` when the Bridge
is offline, the provider is disabled/absent, or a concurrency limit is reached, and `422` for an
unknown/deprecated provider-model pair. Validate is accepted only from `awaiting_validation`;
calling it earlier returns `409` and never treats a merely-started process as successful.

### 2.11 Choice recorded on the instance (`REQ-PROVIDER-CATALOG-4`)

Launch requests must carry both `provider` and `model`. The hub validates the pair against
`provider_catalog(state='active')` ∩ `provider_models(state='active')` ∩
`bridge_provider_settings(enabled=true)` ∩ `bridge_provider_status(state='present')` and returns
422 otherwise. No inheritance, no fallback, no defaults, and no durable test result participate.

The pair is written to `agent_instances`; restart and replay read it back from there. That row is the
only place a provider/model preference exists in the system.

A running instance whose model has since been deprecated keeps running. Relaunch is blocked, and the
UI shows "model retired, pick another".

---

## 3. Removal Inventory

### 3.1 Deleted outright

| File | Lines |
|---|---|
| `src/bridge/provider_seeds.odin` | 110 (whole file) |
| `src/ui/components/settings/providerCatalog.ts` | 239 (whole file) |
| `src/ui/components/settings/providerManagement.ts` | 294 (whole file) |

### 3.2 Gutted

**`src/bridge/provider_store.odin`: 1177 → ~200 lines.** Everything `Bridge_Provider_Override*`
goes: the wire struct and its ~20 `*_set` booleans, the field-level merge
(`bridge_provider_apply_override:487`), the two-pass seed/override resolution
(`bridge_effective_provider_profiles:414`), `bridge_provider_profile_from_seed:449`,
`bridge_provider_capabilities_json:586`, `bridge_provider_profiles_report_json:627`,
`bridge_provider_enable_selected_json:1017`, `bridge_provider_set_defaults:561`,
`bridge_provider_default_tier:553`, `bridge_provider_by_name_or_default:543`, and
`bridge_runtime_resolve_provider_executable:1102` (its job moves to probe time).
What remains: the catalog snapshot, the path store, the probe, and argv assembly.

**`src/ui/components/settings/ProvidersPanel.tsx`: 1754 → ~400 lines**, rewritten as a read-only
catalog list plus per-bridge status and a Test button.

`src/bridge/provider_store_test.odin` is rewritten against the new surface.

### 3.3 Dead provider names

`jetski` (`providerCatalog.ts`) and `pi` (`config.toml:13`) are removed. Neither appears in the
bridge seed table; `pi` is the configured default for every generated agent.

### 3.4 Endpoints, handlers and frames

Legacy routes removed: bridge provider listing/mutation/default routes, detected-provider routes,
`/providers/refresh`, and `/providers/enable-detected`. They are replaced, not aliased; no backward
compatibility shim remains.

Handlers removed from `src/hub/transport/http/bridge_handlers.odin`:
`list_bridge_providers_handler:120`, `get_detected_bridge_providers_handler:127`,
`enable_bridge_providers_handler:134`, `put_bridge_provider_handler:1183`,
`delete_bridge_provider_handler:1192`, `set_bridge_provider_defaults_handler:1199`,
`refresh_bridge_providers_handler:1207`, `bridge_provider_relay:1220`,
`bridge_provider_command_json:1258`.

Bridge WS commands removed (`src/bridge/hub_runtime_client.odin:1729`
`bridge_hub_handle_provider_command`): `list_providers`, `upsert_provider`, `delete_provider`,
`set_provider_defaults`, `enable_providers`, `detect_supported_providers`. The
`providers_report` reply type is removed from the result dispatch at `bridge_handlers.odin:1686`.

Replacement reads are `GET /api/v1/providers`, `GET /api/v1/providers/:provider/icon`, and
`GET /api/v1/bridges/:bridge_id/provider-status`. Mutations are the provider-level enable route,
on-demand discovery route, and ephemeral test lifecycle in §2.10. The Providers panel opens without
waking any bridge and renders correctly for offline bridges — showing last-known status and
`checked_at`; only an explicit discovery or test contacts the Bridge.

### 3.5 Schema changes

Removed:
- `bridges.capabilities_json` (`002_owner_scoped_core.sql:9`)
- `agents.default_provider`, `agents.default_tier` (`002_owner_scoped_core.sql:38-39`)
- `agent_bridge_support.provider`, `agent_bridge_support.tier` (`002_owner_scoped_core.sql:52-53`) —
  `enabled`, `priority` and `max_instances` are retained
- the inline `task_chain_fleets` ALTERs at `src/hub/repository/sqlite/migrations.odin:975-976`

Renamed:
- `agent_instances.tier` → `model` (`002_owner_scoped_core.sql:67`)
- `task_chain_fleets.tier` → `model`, and both `provider` and `model` become required
- `actions.target_tier` → `target_model` (`036_action_targets.sql:4`)

Added: `provider_catalog`, `provider_models`, `provider_catalog_meta`, `bridge_provider_status`,
`bridge_provider_settings`; `agent_instances.kind` for provider-test exclusion. There is no
provider-validation column or provider-test table.

### 3.6 Resolution logic and config

Removed from `src/hub/service/agent/agent_service.odin`: the `first_non_empty` chains at `:1248`,
`:1264`, `:1359`; `default_provider_from_bridge:1589`; `default_tier_from_bridge:1595`;
`default_tier_for_provider_from_bridge:1601`.

Removed from `src/lib/config/config.odin`: `Model_Tiers_Config:163`, `resolve_model_value:744`,
`default_agent_model_tier:109` (and its parse at `:457`, its default at `:809`).

Removed from `src/lib/agent_runtime/runtime.odin`: the `models` field on `Agent_Profile`, the `tier`
parameter of `build_agent_command:25`, `log_model_tier_unavailable:143`. The empty-model branch at
`:30` becomes a hard error rather than a skipped flag (§1.5).

Removed from `config.toml`: `default_agent_provider_profile` (`:13`), `provider_profile` (`:38`),
and the model-tier block. The hub DB becomes the only catalog; `config.toml` keeps no provider role,
so no second source of truth is reintroduced.

### 3.7 CLI

Every `--tier` becomes `--model` in `src/ctl/hub_mode.odin` (`agents create:51`, `launch:62`,
`task-chains add-agent:203`, `actions create:645`) and `src/ctl/agent_mode.odin`, including help text.

---

## 4. Phase Plan

Each phase compiles and is independently testable.

| Phase | Req ID | Scope |
|---|---|---|
| 1 | `-CATALOG-1` | Hub catalog: migration + seeds, `domain/provider.odin`, `provider_repo_sqlite`, `provider_service`, `GET /api/v1/providers`, `GET /api/v1/providers/:name/icon`. Nothing consumes it yet. |
| 2a | `-CATALOG-2` | Bridge catalog replica: etag negotiation, body-on-miss, sha256 verify, atomic write, immutable snapshot. |
| 2b | `-CATALOG-2` | Bridge path store and on-demand discovery frames: explicit Hub request → probe → persist/report resolved paths → `access` check at launch → inline re-probe on miss. Delete `bridge_runtime_resolve_provider_executable`. |
| 2c | `-CATALOG-2` | Durable per-bridge provider enablement and the status/settings read model. Provider is the only enablement granularity. |
| 3 | `-CATALOG-3` | `tier` → `model`, mechanical, ~1200 call sites. Own commit, kept bisectable. Empty model becomes a hard error. |
| 4 | `-CATALOG-4` | Defaults die: drop columns, delete fallback chains, require provider+model at every entry point, 422 on an invalid pair. |
| 5 | `-CATALOG-5` | Ephemeral tests: in-memory registry, temporary `provider_test` instance, existing agent stream/input and `start-success`, explicit human validation/stop, cancel, TTL and reaper. |
| 6 | `-CATALOG-6` | UI: delete both helper modules, implement the approved shared provider-setup surface, and replace every tier dropdown with a model dropdown fed by `GET /api/v1/providers`. |
| 7 | `-CATALOG-7` | Enrollment hand-off: after enrollment, show **Continue to provider selection**; Apply persists provider enablement and then navigates home. No automatic redirect or Skip/Finish action. |

**Sequencing risk.** Phase 3 is ~1200 mechanical edits across ~70 files, and phases 3–4 together
break every provider-related test at once (`src/hub/service/agent/agent_service_test.odin` has 49
tier references, `src/hub/service/taskchain/fleet_dispatcher_test.odin` 33,
`src/ui/components/tasks/fleetSelection.ts` 124). The suite will be red mid-flight for structural
reasons rather than real failures. Recommendation: land and verify phases 1–2 as their own PR before
starting 3.

---

## 5. Resulting Flows

### 5.1 Service provider adds a provider or a model

A migration. One `INSERT` into `provider_catalog` / `provider_models`, code-reviewed and shipped like
any schema change. The hub recomputes `catalog_etag`, pushes `provider_catalog_version` to connected
bridges, and each fetches the body once and caches it. Every user has it on their next launch.

No UI, no user action, no per-bridge fan-out. This is the whole "change the configuration for
everyone" mechanism.

Retiring a model is `state = 'deprecated'`: it disappears from new-launch dropdowns, running
instances continue, relaunch is blocked with a "model retired" affordance.

### 5.2 User enables a provider on a machine

```
Settings → Providers                            bridge: workstation-01

  Provider         Detected path                  Enabled       Action
  Claude Code      /home/t/.local/bin/claude      [on]          [Test]
  Codex            /usr/bin/codex                 [on]          [Test]
  Copilot          — not detected                 [off]         [Install guide]
  Antigravity      /usr/bin/agy                   [off]         [Test]
```

The list is `provider_catalog` joined to `bridge_provider_status` — a hub-DB read that wakes no
bridge. Enablement is provider-level. The user may pick an active model for a test, click **Test**,
and watch the real CLI boot in a live terminal (§2.9). The popup remains **Detecting** until
`start-success`; it then waits with the instance still running until **Mark as validated** stops it.
That interaction does not persist a validation result.

The user never types a command, a flag, a model id, or a startup pattern.

### 5.3 Launch

The dialog offers enabled, present providers for the chosen bridge, each with its icon and active
models. Both provider and model are required. The pair is written to `agent_instances`; restart and
replay read it back. A provider test is diagnostic and never becomes a durable launch gate.

---

## 6. Decisions Taken

1. **Supported set is fixed**: claude, codex, copilot, antigravity. Users cannot add providers.
2. **No per-user or per-bridge catalog overrides.** One catalog, edited by migration.
3. **`config.toml` keeps no provider role.** Deleted rather than retained as a dev seed override.
4. **Provider-test instances are excluded from all projections** via `kind = 'provider_test'`.
5. **A deprecated model does not stop a running instance**; it blocks relaunch.
6. **Enablement is per provider, never per model.** Models are explicit launch/test choices.
7. **Testing is ephemeral.** `start-success` permits human validation; it does not persist a result
   or stop the instance. Human validation triggers stop and cleanup.
8. **Authentication stays inside the live provider terminal.** There is no separate login API or
   durable `needs_auth` state.
9. **Tests reuse the normal agent stream/input and stop protocol.** They do not create a second PTY
   transport or expose terminal output through test status responses.
10. **Discovery is on demand and Hub-initiated.** Merely rendering settings or reconnecting does not
    scan the Bridge.
11. **Enrollment pauses before provider setup.** The user explicitly continues, applies provider
    choices, and then returns home.
12. **Icons are hub-served at a hub-relative URL.**

## 7. Open Question

**Supported provider installed off `$PATH`.** A user may have `claude` in `~/bin` where the bridge's
service environment does not look (systemd and launchd units deliberately constrain PATH — see
`bridge_provider_seeding_onboarding_audit.md` §1). This is not a custom CLI; it is locating one of
the four. Two options:

- **(a)** `provider_paths.json` carries an optional user-supplied path alongside the probed one, and
  the panel offers "Locate manually" when a probe returns `absent`. Costs one field and one dialog.
- **(b)** Not on PATH means not available; the user fixes their environment.

(a) is recommended — it does not reopen recipe authoring, since the catalog still owns every flag and
model, and it addresses a failure mode the prior audit documented as common. Pending decision.
