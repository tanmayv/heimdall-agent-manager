# Heimdall UI Onboarding Implementation Plan

Status: Draft for review
Scope: The UI surfaces (and the backend they require) needed to take a brand-new
machine from "nothing installed" to "multiple running instances of an agent":
enroll a Bridge, configure/test Providers on it, create an Agent (template +
name) with a default provider (§2.5 override model), deploy it on the bridge
machine, and start multiple instances — plus the New-Conversation composer.
Audience: UI + bridge + hub implementers.

This document is the source of truth for the onboarding critical path. It also
defines the **data/configuration ownership boundary** between Hub, Bridge, and
Wrapper, because several onboarding pages only make sense once that boundary is
fixed.

Related docs:
- `docs/plans/hub-bridge-user-owned-architecture-and-api.md` (durable model, REST conventions)
- `docs/plans/hub-bridge-runtime-protocol.md` (Hub ↔ Bridge WS commands)

---

## 1. Goals and requirements

### 1.1 Onboarding critical path (the one flow this doc unblocks)

From a fresh system, a user must be able to:

1. **Enroll and connect a Bridge** from the UI (one-time enrollment token →
   `ham-bridge enroll`), and see it come **online**.
2. **Configure and test a provider on that Bridge, from the UI.** This includes:
   - the **command** to run for the provider (argv),
   - the **model per tier** (`cheap`/`normal`/`smart`) and the **flag** used to
     pass the model,
   - the **flags** appended when launching (prompt flags, yolo/skip-permission
     flags, starter prompt, prompt-delivery mode),
   - **startup detection** (blocking-prompt patterns, auto-enter keys, probe
     window) and **activity/block detection** settings,
   - a **Test** action that validates the provider on that machine and reports
     a pass/fail result.
3. **Create a durable Agent identity** by picking a **persona/template** and a
   **name (agent id)**, choosing its **default provider**, and enabling it to
   run on the Bridge machine. Provider selection follows the resolution model in
   §2.5: the Bridge already has a default provider, so at agent level the user
   may (a) accept the bridge default, (b) set a provider **override for one
   bridge**, or (c) set a provider **override for all bridges** of that agent.
   In normal use the user only needs to select a **preferred tier**.
4. **Deploy and run the agent on the Bridge machine**, and **start multiple
   instances** of the same agent id — each instance is its own running
   session/conversation on the bridge.
5. **Start a conversation** from the composer: pick agent/project (and, only if
   they want, override provider/tier), launch an instance, and chat.

### 1.1a End-to-end goal (the flow this whole doc serves)

```text
Enroll bridge -> bridge online
  -> configure/test providers on that bridge (bridge has a default provider)
  -> create agent: pick template/persona + name (agent id) + default provider
     (accept bridge default, or override for one bridge / all bridges)
  -> enable agent on the bridge; user just picks preferred tier
  -> start one or more instances of that agent on the bridge machine
  -> chat with each instance
```

### 1.2 Hard requirements

- **R1 — Provider config is editable from the UI and persisted by the Bridge.**
  The Bridge stores the working provider configuration in a **bridge-local
  editable store** (not in `config.toml`). `config.toml` is treated as a
  **read-only defaults/seed** file.
- **R2 — Provider config/credentials never live on the Hub.** The Hub relays UI
  edits/tests to the Bridge and only stores a **capabilities snapshot** for
  display and scheduling. No provider command, flags, model map, or credential
  is persisted on the Hub.
- **R3 — Provider/tier choices in the UI come from reported Bridge
  capabilities**, computed as the union across the relevant enabled Bridges.
  No page may hardcode `claude`/`smart` or any provider/tier literal.
- **R4 — An Agent cannot run with zero enabled bridge-support rows** (arch
  invariant 19). Agent create leads directly into enabling a Bridge.
- **R5 — Cookie/trusted-proxy auth only** for these pages (`cookieJsonFetch` /
  `cookieMutation` against `/api/v1/*`). The legacy `daemonUrl`/`clientToken`
  session path must not be used by onboarding surfaces.
- **R6 — Offline Bridges fail fast** (`bridge_offline`). No durable command
  queue in v1; the UI shows the offline state and disables provider edit/test.

---

## 2. Ownership boundary: Hub vs Bridge vs Wrapper

This is the central model the onboarding UI is built on. Three tiers own three
different kinds of state.

### 2.1 One-paragraph summary

The **Hub** owns durable, machine-agnostic product state (identities, projects,
chains, chat, memory, the bridge registry, and a read-only capability snapshot).
The **Bridge** owns everything machine-dependent: the editable **provider
profiles** (command, tiers, flags, detection config), filesystem paths,
tmux/run dirs, capability detection, and wrapper supervision. It does **not**
store provider credentials — providers run in the operator's existing shell
environment (D2).
The **Wrapper** (bridge wrapper-supervisor) owns a single running process: it
takes a **fully-resolved** launch spec from the Bridge and executes it, runs
startup/activity detection against that process, and reports runtime signals
back to the Bridge. The Wrapper stores no durable configuration of its own.

### 2.2 Ownership matrix

| Concern | Hub | Bridge | Wrapper |
|---|---|---|---|
| User identity, agents, projects, chains, tasks, memory, chat, artifacts | **Owns (durable)** | — | — |
| Agent *default* provider/tier (a preference on the identity) | **Owns** | — | — |
| Agent↔Bridge support policy (which bridges may run an agent) | **Owns** | — | — |
| Bridge registry record (id, label, status, last_seen) | **Owns** | reports metadata | — |
| **Capabilities snapshot** (providers + tiers available on a bridge) | **Stores snapshot** (display/scheduling) | **Owns / computes** | — |
| **Provider profile**: command argv, model-per-tier + model flag, prompt/yolo flags, starter prompt, prompt-delivery | — | **Owns (editable, persisted)** | consumes resolved value |
| **Provider credentials / env** (API keys, tokens) | **Never** | **Not managed** (D2): user configures the shell/CLI login themselves | inherits operator shell env at launch |
| **Startup detection** config (probe window, blocked/auto-enter patterns, pre-keys, reason mapping) | — | **Owns (editable, persisted)** | **executes** detection using the config |
| **Activity/block detection** config (sample lines, intervals, gap thresholds) | — | **Owns (editable, persisted)** | **executes** detection using the config |
| Provider **Test** execution | relays request/result | **executes** on the machine | — |
| Filesystem/project paths, run dirs, tmux sessions | — | **Owns** | runs inside the given cwd |
| Bootstrap file materialization (AGENTS.md, skills, manifest) | provides bootstrap payload | **materializes to disk** | reads files |
| Resolved launch spec (final argv, cwd, env, detection config) | issues `launch_agent` command (provider/tier/project) | **resolves profile → spec** | **executes spec**, reports signals |
| Durable config file | — | `config.toml` = **read-only seed** | — |

### 2.3 Provider profile: the editable unit (UI-managed, bridge-persisted)

The provider profile is the exact thing the Providers page edits. Its shape is
taken 1:1 from the current `config.toml` `[wrapper.agent-cmd.<name>]` sections
(`src/lib/config/config.odin: Agent_Command_Config`), so an operator can move
today's config into the bridge store without loss.

```ts
BridgeProviderProfile {
  name: string                 // profile id, e.g. "pi", "claude", "codex"
  enabled: boolean             // included in reported capabilities when true
  command: string[]            // argv, e.g. ["pi"] or ["/path/to/cli"]

  // Model-per-tier + the flag used to pass the model to the command.
  models: {
    flag: string               // e.g. "--model" | "-m"
    cheap: string
    normal: string
    smart: string
  }

  // Launch flags/prompt behavior.
  prompt_flags: string[]       // e.g. ["--prompt-interactive"] | ["-i"]
  yolo_flags: string[]         // e.g. ["--dangerously-skip-permissions"]
  starter_prompt: string
  prompt_delivery?: string     // e.g. "flag-injection"
  prompt_tmux_delay_ms?: number
  prompt_tmux_enter?: boolean

  // Machine-local run dir behavior (optional overrides).
  agent_run_dir?: string
  use_random_dir?: boolean

  // Startup detection (executed by the Wrapper, configured here).
  startup_detection: {
    enabled: boolean
    startup_probe_seconds: number
    capture_interval_ms: number
    blocked_patterns: string[]
    auto_enter_patterns: string[]
    auto_enter_pre_keys: string[]      // parallel to auto_enter_patterns
    startup_unknown_is_blocked: boolean
    sanitized_reason_mapping: string[] // "key=human reason"
  }

  // Activity/block detection (executed by the Wrapper, configured here).
  activity_detection: {
    enabled: boolean
    sample_line_count: number
    ignore_bottom_lines: number
    check_interval_seconds: number
    min_gap_ms: number
    max_gap_ms: number
  }

  // NO credential management (D2). The Bridge stores no API keys/env. Providers
  // are launched in the operator's existing shell environment; the user is
  // assumed to have logged the CLI in and set up the environment already.

  // Bridge-maintained test result (not user-editable). See D1 for semantics.
  last_test?: {
    status: "ok" | "failed" | "unknown"
    tested_at: string
    message?: string
    diagnostics?: string             // sanitized (captured start-success output)
  }
}
```

**Capabilities derivation (Bridge → Hub):** for each `enabled` profile the
Bridge advertises `{ provider: name, tiers: [tiers with a non-empty model],
default_tier }`. This is what `bridge_hello` / heartbeat / `capability_report`
send today (currently hardcoded to `claude/normal` in
`src/bridge/hub_runtime_client.odin` and must be replaced with store-derived
values).

### 2.4 Config defaults + bridge-store overrides (D4)

`config.toml` `[wrapper.agent-cmd.*]` is the **read-only defaults source**. The
bridge-local provider store holds **overrides only**.

Effective provider profile resolution:

```text
effective_profile(name):
  base    = config.toml [wrapper.agent-cmd.name]   (read-only defaults, may be absent)
  override = bridge_provider_store[name]           (persisted UI edits, may be absent)
  result  = deep_merge(base, override)             (override wins field-by-field)
```

Rules:
- Every provider defined in `config.toml` is **visible in the UI** even with no
  override saved (it renders from defaults).
- Saving an edit in the UI writes an **override** into the bridge store; it never
  writes back to `config.toml`.
- A provider can exist purely as a store override (added from the UI) with no
  `config.toml` entry.
- Capabilities are derived from the **effective** (merged) profiles.
- An explicit "reset to config defaults" (delete the override) is **deferred**
  to post-v1; deleting a store-only provider is allowed in v1.

### 2.5 Provider/tier resolution model (agent → bridge → instance)

This is the model the Agent-create and instance-launch UI implement. It answers
"which provider and tier does a running instance use?" and defines exactly what a
user can override and where.

**Three levels of provider config, most-specific wins:**

```text
resolve_provider(agent, bridge, request):
  provider =
      request.provider_override                 // per-instance, optional (advanced)
   ?? agent_bridge_support[bridge].provider      // agent override for THIS bridge
   ?? agent.default_provider                     // agent override for ALL bridges
   ?? bridge.default_provider                    // bridge default

  tier =
      request.tier                               // per-instance preferred tier (normal path)
   ?? agent_bridge_support[bridge].tier          // agent tier for this bridge
   ?? agent.default_tier                          // agent default tier
   ?? bridge.capability(provider).default_tier    // provider's default tier
```

**What each level means in the UI:**

| Level | Field(s) | Where set | Typical use |
|---|---|---|---|
| Bridge default | `bridge.default_provider` (+ each provider's `default_tier`) | Providers page | The machine's out-of-the-box choice |
| Agent default (all bridges) | `agent.default_provider`, `agent.default_tier` | Agent create/edit | "This agent always uses provider X" |
| Agent per-bridge override | `AgentBridgeSupport.provider`, `.tier` | Agent → bridge support row | "On this machine, use provider Y" |
| Instance (advanced) | request `provider`/`tier` | Composer advanced / instance launch | One-off run on a different tier |

**Design intent / UI simplification:**
- **Bridge already has a default provider.** So the common agent-create path is:
  pick template + name, accept the bridge default provider, and just choose a
  **preferred tier**. Provider override is an *optional* advanced control.
- **Provider override scope is explicit** in the UI: a segmented control offers
  "Use bridge default", "Override for this bridge", or "Override for all bridges".
  Choosing an override reveals a provider select sourced from that bridge's (or
  the union of the agent's bridges') reported capabilities (R3).
- **Tier is always just a select** (`cheap`/`normal`/`smart`), constrained to the
  tiers the resolved provider actually advertises.
- The selectable provider/tier range at any level is the **intersection** of the
  bridge's reported capabilities and the agent-bridge-support policy (arch doc
  invariant on reconfigure).

**Bridge default provider:** `bridge.default_provider` is the provider marked as
the bridge's default. **v1 decision: the bridge default provider is simply the
first `enabled` provider** in the effective profile list — no explicit "set as
default" selector is required for v1. An explicit chooser is deferred post-v1.
The Bridge remains authoritative; the Hub uses the first-enabled provider from
the capabilities snapshot as the resolution default.

---

## 3. Backend work required (blocking for Providers page)

The Providers page cannot be "done" as UI-only. Minimum backend:

### 3.1 Bridge
- **`bridge_provider_store`** — persisted JSON in the bridge data dir (mirrors
  `src/bridge/agent_token_store.odin`). Stores **overrides only** over the
  `config.toml` defaults (see §2.4); no credentials/env (D2).
- **Effective-profile resolution** — merge `config.toml` defaults with store
  overrides so both the UI list and capabilities reflect the merged result.
- **Capabilities from effective profiles** — replace hardcoded capabilities in
  `bridge_hub_hello_json` and heartbeat digest with values derived from the
  merged profiles.
- **Launch resolution** — `bridge_runtime_agent_command` / wrapper-supervisor
  argv build the final command + model flag + prompt/yolo flags + detection
  config from the selected effective profile and tier (replacing the current
  `sleep 3600` placeholder).
- **New WS commands handled by the Bridge** (runtime protocol §9):
  `list_providers` (returns effective profiles + override flags),
  `upsert_provider` (writes an override), `delete_provider` (removes a
  store-only provider or override), `test_provider`, `refresh_capabilities`.
- **`test_provider` (D1)** — launch the provider command in a throwaway sandbox
  cwd/tmux and assert the agent can reach the Hub by having it run
  `ham-ctl ... start-success`. The Bridge waits (bounded, e.g. 30–60s) for the
  resulting start-success for that probe instance. Pass = start-success
  received; fail/timeout = provider could not start or could not call ctl. No
  per-tier round-trip, no token spend beyond starting the CLI.

### 3.2 Hub REST API (relay only; no provider persistence)

New cookie-auth REST routes (register in `src/hub/app/wiring.odin`), each scoped
to a bridge the caller owns, each returning `bridge_offline` if the bridge WS is
not connected. All responses use the standard success/error envelope from the
architecture doc (§8): success bodies are wrapped in `{ "data": ... }`.

| Method | Path | Relays WS command |
|---|---|---|
| GET | `/api/v1/bridges/{id}/providers` | `list_providers` |
| PUT | `/api/v1/bridges/{id}/providers/{name}` | `upsert_provider` |
| DELETE | `/api/v1/bridges/{id}/providers/{name}` | `delete_provider` |
| POST | `/api/v1/bridges/{id}/providers/{name}/test` | `test_provider` |
| POST | `/api/v1/bridges/{id}/providers/refresh` | `refresh_capabilities` |

#### 3.2.1 GET `/api/v1/bridges/{id}/providers`
List effective (merged) provider profiles for the bridge.

Response `200`:
```json
{
  "data": {
    "bridge_id": "brg_123",
    "providers": [
      {
        "name": "pi",
        "enabled": true,
        "source": "config",
        "has_override": false,
        "command": ["pi"],
        "models": { "flag": "--model", "cheap": "openai-codex/gpt-5.4", "normal": "openai-codex/gpt-5.4", "smart": "openai-codex/gpt-5.5" },
        "prompt_flags": [],
        "yolo_flags": [],
        "starter_prompt": "First, run: {ctl_bin} --token {token} start-success. ...",
        "prompt_delivery": "",
        "startup_detection": { "enabled": false, "startup_probe_seconds": 0, "capture_interval_ms": 0, "blocked_patterns": [], "auto_enter_patterns": [], "auto_enter_pre_keys": [], "startup_unknown_is_blocked": false, "sanitized_reason_mapping": [] },
        "activity_detection": { "enabled": true, "sample_line_count": 20, "ignore_bottom_lines": 0, "check_interval_seconds": 15, "min_gap_ms": 100, "max_gap_ms": 500 },
        "last_test": { "status": "ok", "tested_at": "2026-07-27T10:00:00Z", "message": "start-success received" }
      }
    ]
  }
}
```
- `source`: `"config"` (from `config.toml`), `"store"` (UI-added, no config
  entry), or `"merged"` (config default with a store override applied).
- `has_override`: whether a bridge-store override exists for this provider.
- `last_test` is present only if the provider has been tested since boot.

#### 3.2.2 PUT `/api/v1/bridges/{id}/providers/{name}`
Create or replace the **override** for a provider (writes the bridge store).
Request body is a full `BridgeProviderProfile` (minus `source`/`has_override`/
`last_test`, which are bridge-maintained):
```json
{
  "enabled": true,
  "command": ["pi"],
  "models": { "flag": "--model", "cheap": "anthropic/claude-sonnet-4-6", "normal": "anthropic/claude-sonnet-4-6", "smart": "anthropic/claude-opus-4-8" },
  "prompt_flags": [],
  "yolo_flags": ["--dangerously-skip-permissions"],
  "starter_prompt": "First, run: {ctl_bin} --token {token} start-success. ...",
  "prompt_delivery": "",
  "startup_detection": { "enabled": true, "startup_probe_seconds": 20, "capture_interval_ms": 500, "blocked_patterns": ["Enter auto mode"], "auto_enter_patterns": ["Yes, I trust this folder"], "auto_enter_pre_keys": [""], "startup_unknown_is_blocked": false, "sanitized_reason_mapping": ["trust=Claude directory trust prompt"] },
  "activity_detection": { "enabled": true, "sample_line_count": 20, "ignore_bottom_lines": 0, "check_interval_seconds": 15, "min_gap_ms": 100, "max_gap_ms": 500 }
}
```
Response `200`: `{ "data": { "provider": { ...effective profile after merge... } } }`.

#### 3.2.3 DELETE `/api/v1/bridges/{id}/providers/{name}`
Remove a store-only provider, or (post-v1) reset an override back to config
defaults. Deleting a provider that only exists in `config.toml` is rejected.
Response `200`: `{ "data": { "deleted": true } }`.

#### 3.2.4 POST `/api/v1/bridges/{id}/providers/{name}/test`
Run the start-success probe (D1). Request body optional:
```json
{ "tier": "normal" }
```
Response `200`:
```json
{
  "data": {
    "name": "pi",
    "status": "ok",
    "tested_at": "2026-07-27T10:00:00Z",
    "message": "start-success received in 4.2s",
    "diagnostics": "<sanitized captured output>"
  }
}
```
`status` is one of `ok` | `failed` | `unknown`; a timeout returns `failed` with a
`message` explaining the timeout.

#### 3.2.5 POST `/api/v1/bridges/{id}/providers/refresh`
Ask the bridge to re-derive and re-advertise capabilities.
Response `200`:
```json
{ "data": { "capabilities": [ { "provider": "pi", "tiers": ["cheap","normal","smart"], "default_tier": "normal" } ] } }
```

#### 3.2.6 Error envelope (all provider routes)
Standard error envelope; notable codes:
```json
{ "error": { "code": "bridge_offline", "message": "Bridge brg_123 is not connected" } }
```
- `bridge_offline` → HTTP 409 (bridge WS not connected; no durable queue in v1).
- `not_found` → HTTP 404 (bridge not owned by caller, or provider name unknown).
- `validation_failed` → HTTP 422 (bad profile body, e.g. empty `command`).

#### 3.2.7 Bridge list/detail capability fix
Fix `write_bridge_json` in `src/hub/transport/http/bridge_handlers.odin` to emit
real `active_instance_count` and the effective-profile-derived `capabilities`
array. Current wire shape (already an array) stays:
```json
"capabilities": [ { "provider": "pi", "default_tier": "normal", "tiers": ["cheap","normal","smart"] } ]
```

### 3.3 Runtime protocol WS command/report shapes (Hub ↔ Bridge)

The REST routes in §3.2 relay these WS messages. They are now specified in
`docs/plans/hub-bridge-runtime-protocol.md` — implement against those sections:

| REST route | Relays WS command | Bridge reply | Protocol § |
|---|---|---|---|
| `GET .../providers` | `list_providers` | `providers_report` | 9.6.1 / 10.5 |
| `PUT .../providers/{name}` | `upsert_provider` | command result `{provider}` | 9.6.2 |
| `DELETE .../providers/{name}` | `delete_provider` | command result `{deleted}` | 9.6.3 |
| `POST .../providers/{name}/test` | `test_provider` | command result `{status,…}` | 9.6.4 |
| `POST .../providers/refresh` | `refresh_capabilities` | `capability_report` | 9.4 / 10.1 |

The provider profile shape (fields, `source`/`has_override`/`last_test`) is
defined once in runtime-protocol §9.6 and mirrored by §2.3 here; keep them in
sync. Offline handling for all four new commands is `fail_if_offline`
(runtime-protocol §15.1) — the REST layer returns `bridge_offline` (HTTP 409).

### 3.4 Resolved backend decisions
1. **Test semantics (D1):** start-success probe — launch the provider and
   confirm the agent runs `ham-ctl ... start-success`. No per-tier round-trip,
   no `tier_results`.
2. **Credentials (D2):** none. The Bridge stores no API keys/env; providers run
   in the operator's existing shell environment (user is assumed logged in and
   configured).
3. **Provider identity:** keyed by `name`, unique per bridge.
4. **Defaults vs overrides (D4):** `config.toml` = read-only defaults; bridge
   store = overrides only; effective = merge (see §2.4).

### 3.5 Existing-route gaps to close (agent deploy/run + §2.5)

These hub routes exist (`src/hub/app/wiring.odin`) but need work for Pages 3/3b/4:

- **`GET /api/v1/agent-instances` needs an `agent_id` (and optional `bridge_id`,
  `runtime_status`) filter.** `list_agent_instances_handler` currently ignores
  query params; Page 3b lists instances per agent. Add query filtering in
  `agent_service.list_instances`.
- **`POST /api/v1/agent-instances` must apply the §2.5 resolution** when
  `provider`/`tier` are omitted (resolve from agent-bridge-support → agent
  default → bridge default), and must accept an omitted `chain_id` to create a
  private chain + 1:1 conversation (arch doc 22a/22b).
- **`PATCH /api/v1/agents/{id}`** must accept `default_provider`/`default_tier`
  edits (Page 3b default editor).
- **`PATCH /api/v1/agents/{id}/bridge-support/{bridge_id}`** already supports
  `provider`/`tier`/`enabled`; the UI uses empty `provider` to mean "use bridge
  default" (clear override).
- **`POST /api/v1/agent-instances/{id}/restart` and `.../stop`** exist; wire the
  UI stop/restart to them.
- **Bridge default provider (v1):** the bridge default is the **first `enabled`
  provider** in the effective profile list. No explicit selector in v1 (§2.5).

### 3.5a Agent runtime path audit (ham-ctl → Bridge → Hub)

Audited the path agents use so `ham-ctl` can call start-success and read/write
conversations through the Bridge (agent has no Hub URL/token; the Bridge relays).

**Working today** (`src/ctl/main.odin` agent mode, `src/bridge/wrapper_endpoint.odin`,
`src/hub/transport/http/agent_action_handlers.odin`):
- `ham-ctl agent ...` mode discovers `HEIMDALL_BRIDGE_ENDPOINT` +
  `HEIMDALL_AGENT_TOKEN`, which the Bridge injects into the agent's child env
  (`bridge_wrapper_child_env`).
- Local endpoint allowlists `agent.*` and relays to `/api/v1/agent-actions/*`
  with the Bridge-held instance token (`hit_<instance_id>`); Hub verifies via
  `verify_instance_token`. WRITE to conversation (`agent.chat.send_to_user`) and
  `agent.start_success` both relay correctly.

**Blockers (make these requirements of this effort):**

- **B1 — No conversation READ path for agents.** The requirement is read AND
  write. There is no `agent.chat.read` / `agent.context` message-fetch method:
  the local endpoint allowlist has no read, and Hub message reads
  (`GET /api/v1/chats/*/messages`, `.../read`) use `require_auth` (user/cookie),
  which **rejects instance tokens**. Add:
  - Hub: accept instance-token auth on conversation read for the instance's OWN
    conversation (a `require_instance_or_user_auth` on
    `GET /chats/{id}/messages` + `POST /chats/{id}/read`, scoped so an instance
    can only read its bound `conversation_id`), OR add
    `POST /api/v1/agent-actions/chat/fetch` + `.../chat/read` instance-scoped
    endpoints.
  - Bridge: allowlist `agent.chat.fetch` / `agent.chat.read` and relay them.
  - ctl: add `ham-ctl agent chat read|fetch` (agent mode) to call them.
- **B2 — `agent.context.get` is a stub.** It returns only
  `{agent_instance_id}` locally without relaying to the Hub, so an agent cannot
  discover its conversation_id/chain/current task to then read messages. Wire it
  to a Hub instance-scoped context endpoint returning conversation_id, chain_id,
  current task, and unread summary.
- **B3 — Bare `ham-ctl start-success` targets the legacy daemon, not the
  Bridge.** `main.odin` dispatches top-level `start-success` to
  `ctl_start_success` → `POST {daemon_url}/agent-rpc` with an `agent_token` body.
  The Hub has no `/agent-rpc` route (only `/api/v1/...`), and tokens must be in
  the `Authorization` header, not the body. The starter prompt uses
  `{ctl_bin} --token {token} start-success`. Fix by either:
  - (preferred) changing the rendered starter prompt to `ham-ctl agent
    start-success` (agent mode, already works via the Bridge), and/or
  - making top-level `start-success` detect `HEIMDALL_BRIDGE_ENDPOINT` and route
    through agent mode. `bridge_provider_render_starter_prompt` is the single
    place to update the rendered command.
- **B4 — Instance-token trust model: Bridge-managed identity, Hub trusts the
  Bridge.** DECISION: instance tokens are **managed at the Bridge level**, not
  issued as Hub secrets. The Bridge is the authenticated principal (bridge token
  over the bridge WS); it owns the local agent tokens it hands to wrappers/agents
  and maps them to `agent_instance_id`. When the Bridge relays an agent action,
  **the Hub trusts the instance identity (`agent_instance_id`) asserted by the
  authenticated Bridge** — it does not require a separately-issued per-instance
  Hub secret. Requirements:
  - The Bridge asserts instance identity on relay in a way the Hub authenticates
    as coming from that Bridge (e.g. the bridge token / bridge-authenticated
    channel), and the Hub verifies the asserted `agent_instance_id` **belongs to
    that Bridge** (`instance.bridge_id == authenticated bridge`) and resolves
    `owner_user_id` from the instance record. Reject if the instance is not on
    that Bridge.
  - The `hit_<instance_id>` bearer stays an internal Bridge→Hub relay detail, but
    the Hub MUST bind it to the calling Bridge (not accept any `hit_<id>` from
    anywhere). The trust anchor is the Bridge, not the token string.
  - Local agent tokens (`hlat_...`) remain Bridge-issued and Bridge-scoped; they
    never reach the Hub. This matches runtime protocol §12 (Bridge asserts
    instance identity; agent/wrapper hold no Hub credential).
  Net: no Hub-issued per-instance secret is required; the Bridge is the identity
  authority for its instances and the Hub trusts Bridge-asserted `instance_id`
  scoped to that Bridge.
- **B5 — Env allowlist must keep the three HEIMDALL_* runtime vars.** Confirmed
  present (`HEIMDALL_BRIDGE_ENDPOINT/AGENT_TOKEN/AGENT_INSTANCE_ID`); ensure any
  provider-store launch-resolution rework (§3.1) preserves them, or `ham-ctl
  agent` breaks. Add a regression test.

These unblock the end-to-end coordination use case (agents using `ham-ctl` to
signal start-success and to read/write their conversation via the Bridge).

### 3.6 Audit findings on the current UI (must fix as part of this effort)

Audit of the three existing surfaces (`BridgesPanel`, `ProvidersPanel`,
`AgentsPanel`) plus the composer against the real Hub responses. Each finding is
a **requirement** for the corresponding page rewrite.

**Bridges page (`src/ui/components/settings/BridgesPanel.tsx`)**
- A1 — **Capabilities never render.** `capabilitiesLabel` reads
  `caps.providers` / `caps.provider_profiles` (object), but `write_bridge_json`
  emits `capabilities` as an **array** `[{provider, default_tier}]`. Result is
  always “—”. Must parse the array via the shared
  `normalizeBridgeCapabilities()` (§5).
- A2 — **Wrong status/last-seen/instance fields.** Reads `last_seen_unix_ms`
  and `instance_count`; API emits `last_seen_at` (ISO string) and
  `active_instance_count`. Also `active_instance_count` is currently hardcoded
  to `0` server-side (see A9) — fix server-side and read the correct field.
- A3 — **Dead `session` prop.** `AppShell` passes
  `session={{ clientToken: 'cookie-auth-bypass' }}`; these endpoints are
  cookie-auth and ignore it. Remove the prop and the `session` threading.
- A4 — **No live refresh.** Does not poll while an enrollment is pending, so a
  newly-connected bridge never appears without manual refresh. Add polling (§Page 1).

**Providers page (`src/ui/components/settings/ProvidersPanel.tsx`)**
- A5 — **Capabilities rendered as an object.** Uses
  `Object.entries(bridge.capabilities)` but capabilities is an **array**; this
  prints array indices as labels. Must iterate the array of `{provider, tiers,
  default_tier}`.
- A6 — **Read-only only.** The page cannot configure or test providers — the
  core requirement (R1). Full rewrite per Page 2.
- A7 — **Online check ignores capabilities.** Treats `status === 'online'` as
  ready; onboarding readiness also requires ≥1 reported provider (§Page 1 ready
  indicator).

**Agents page (`src/ui/components/agents/AgentsPanel.tsx`)**
- A8 — **Hardcoded provider/tier.** Create form defaults
  `defaultProvider:'claude'`, `defaultTier:'smart'` and posts them literally —
  violates R3. Must source from capabilities and follow §2.5 (bridge default +
  tier-only normal path).
- A9 — **`supported_bridge_count` / `active_instance_count` are hardcoded `0`**
  in `write_agent_json` (and `write_bridge_json` for instances). The “Enable all
  bridges” button keys off `supported_bridge_count === 0`, so it shows even after
  support is enabled. Compute real counts server-side.
- A10 — **`enableBridgeSupport` PUT body shape.** UI sends
  `{ bridges: [{bridge_id, enabled}] }`; the handler parses repeated `bridge_id`
  keys via `support_inputs_from_body`. Verify/align the PUT body contract with
  `replace_supports` so enable actually persists (fix whichever side is wrong,
  document the contract).
- A11 — **No template/persona picker and no name-vs-slug clarity.** Spec
  requires create = template/persona + name (agent id). Add the template select
  and §2.5 provider control; drop the free-text provider defaults.

**Composer (`src/ui/components/chat/ConversationLaunchComposer.tsx`)**
- A12 — **Depends on the same capability shape.** Its `capabilityTiers` already
  tolerates the compact `default_tier` array; keep it, but route through the
  shared `normalizeBridgeCapabilities()`/`resolveProviderTier()` helpers so all
  pages agree.
- A13 — **Synthetic default project omitted on send.** Known gap: it drops
  `project_id` for the fallback Conversations project until the backend exposes
  the default-project marker/id. Close this when the default project is exposed
  (arch doc §7.8) rather than leaving a silent omission.
- A14 — **Uses raw `fetch`, not the RTK Query endpoints.** The composer
  hand-rolls `apiList`/`apiJson` instead of the shared cookie-auth endpoints, so
  its data is not cache-invalidated by WS events. Migrate to the RTKQ hooks used
  elsewhere (or justify the exception).

### 3.7 ham-ctl audit + refactor (agent-facing CLI)

`ham-ctl` is the interface agents use through the Bridge. Audited
`src/ctl/main.odin` (2125 lines, one file). It must be clean, non-redundant,
agent-optimized, and self-documenting. Findings are requirements.

**Structure**
- C1 — **Monolith.** `src/ctl/main.odin` is a single ~2100-line file mixing
  three transports (legacy daemon, hub user mode, agent-via-bridge mode). Refactor
  into a package: e.g. `src/ctl/main.odin` (dispatch only) + `agent_mode.odin`,
  `hub_mode.odin`, `daemon_legacy.odin`, `help.odin`, `httpx.odin`, `jsonx.odin`.
  One command family per file; shared helpers factored out.

**Redundant / unsupported surface**
- C2 — **Three overlapping worlds.** Top-level commands (`tasks`, `artifacts`,
  `memory`, `send`, `inbox`, `chat`, `projects`, `task-chains`, `workspace`,
  `attention`, `users`, `agents create/update/defaults`) POST to the **legacy
  daemon** (`http.post(daemon_url, ...)`, `ROUTE_AGENT_RPC` `/agent-rpc`,
  `/agents/create`) which **does not exist on the Hub** (Hub is `/api/v1/*`
  only). These are dead against the target Hub.
  **Decision:** for each legacy command with no Hub equivalent yet, **remove the
  access point** (unwire it from the top-level dispatch and drop it from help so
  it cannot be invoked) but **keep the implementation code**, moved into a
  `src/ctl/legacy/` (or `daemon_legacy.odin`) module and clearly marked
  `DEPRECATED / not wired`. This lets us re-enable them later with little
  refactoring once a Hub equivalent lands. Commands that DO have a Hub path
  (chat, tasks/task-chains, agents, launch, artifacts, memory, projects) are
  ported to `hub`/`agent` mode as the live surface. Net effect: users/agents see
  only working Hub-backed commands; dead code is parked, not deleted.
- C3 — **`start-success` duplicated and wrong.** Top-level `start-success`
  (`ctl_start_success`) posts to legacy `/agent-rpc` with a token in the body
  (also B3). The correct agent path is `ham-ctl agent start-success` via the
  Bridge. Remove/redirect the legacy one; keep a single canonical spelling.
- C4 — **Redundant aliases.** `list`/`agents list`, `run`/`start`/`agents
  run`/`agents start`, `messages send`/`send`, `chains`/`task-chains`,
  `chat`/`chats`, `messages`/`fetch`. Collapse to one canonical verb per action;
  drop undocumented aliases from help.
- C5 — **Token in query/body.** Several legacy paths pass `?token=` (artifacts)
  or token in JSON body (start-success, send). Agent/hub modes must use
  `Authorization: Bearer` only (arch doc §2.5). Remove query/body token usage.

**Agent-optimized output (easy on context)**
- C6 — **Return only NEW information.** Agent-mode reads must support delta
  fetches so an agent does not reprocess the whole conversation each poll:
  `ham-ctl agent chat read --since <cursor|timestamp>` returns only messages
  after the cursor, plus a `next_cursor`. Same for tasks/context. Default to
  compact output; avoid echoing request params back.
- C7 — **Compact, stable JSON by default** for agent mode (one object or a small
  array + `next_cursor`), with a `--json` already implied; a `--verbose` may add
  detail. No decorative/log lines mixed into stdout (machine-parseable).

**Self-documenting help (skill replacement)**
- C8 — **Per-subcommand help.** Every command and subcommand must support
  `ham-ctl <cmd> [<sub>] --help`/`help`, printing purpose, args, and **example
  usages**, so an agent can learn the command without an external skill file.
- C9 — **Examples in help.** Each subcommand help includes at least one runnable
  example line (real flags), e.g.
  `ham-ctl agent chat read --since 2026-07-27T10:00:00Z`.
- C10 — **Top-level help is high-level only.** `ham-ctl` / `ham-ctl --help`
  prints one line per command family (name + one-sentence purpose), not the full
  flag dump it prints today. Detail lives in per-subcommand help.
- C11 — **Agent surface is the priority.** The `agent` mode command set (context,
  start-success, chat read/send, tasks, artifacts, memory) is the agent-facing
  contract; ensure it is complete (incl. B1 read) and its help is the most
  polished, since it replaces a skill doc.

**Deliverable:** a refactored `src/ctl` package with a lean dispatch, one file
per command family, bearer-only auth, delta-capable agent reads, and
per-subcommand help with examples. Legacy daemon-only commands have their access
points removed (unwired from dispatch + help) but their code kept, parked under
`src/ctl/legacy/` and marked deprecated for easy future re-enable.

---

## 4. Page-by-page UI plan (onboarding order)

All pages render inside `AppShell` `RouteOutlet`
(`src/ui/components/shell/AppShell.tsx`), cookie-auth, hash-routed.

### Page 1 — Settings → Bridges (`/settings/bridges`, `BridgesPanel`)

**Purpose:** enroll + connect a machine; confirm it is online. Onboarding is not
complete until a bridge shows **online** AND reports ≥1 provider capability.

**Sections/states**
- Header + "Add bridge".
- Enrollment ceremony: create enrollment → show one-time
  `ham-bridge enroll --hub <hub_url> --enrollment-token <token>` built from the
  backend response (`setup_command`/`hub_url`/`enrollment_token` — do **not**
  derive from a client session; there is none under cookie auth).
- Pending enrollments: list, expiry, revoke; "waiting for bridge to connect…"
  affordance.
- Bridge list: status dot, label, hostname/os/arch, **reported capabilities
  (provider + tiers)**, active instance count, last-seen; rename / revoke.
- **Ready indicator** per bridge (`online` + ≥1 capability) — the signal the
  rest of onboarding keys off.

**RTK Query (existing, cookie-auth, `bridgeSupport.ts`)**
`useListBridgesQuery`, `useListBridgeEnrollmentsQuery`,
`useCreateBridgeEnrollmentMutation`, `useRevokeBridgeEnrollmentMutation`,
`useRenameBridgeMutation`, `useRevokeBridgeMutation`. Poll `useListBridgesQuery`
(~5s) while any pending enrollment exists so a newly-connected bridge appears.

**Actions:** create/copy/revoke enrollment; rename bridge; revoke bridge;
observe online + capabilities.

**Fixes (audit §3.6):** A1 render capabilities array; A2 read `last_seen_at` /
`active_instance_count`; A3 drop the `session={{clientToken:...}}` prop; A4 poll
while enrollments pending. Remove/curate the stale "token rotation gap" note.

**Debug IDs:** reuse registered `settings-bridges-*` / `settings-bridge-row-*`;
add `settings-bridge-caps-${id}`, `settings-bridge-ready-${id}`.

**Out of scope:** token rotation (unserved), project bridge-paths (Projects
page), per-agent bridge support (Agent page).

---

### Page 2 — Settings → Providers (`/settings/providers`, `ProvidersPanel` rewrite)

**Purpose:** the core new capability — configure and **test** a Bridge's
providers from the UI, persisted by the Bridge (R1–R3, R6). Depends on the §3
backend.

**Sections/states**
- **Bridge selector** (when >1). Offline bridge → disabled edit/test with an
  explicit "bridge offline" banner (R6).
- **Provider list** for the selected bridge: name, `source` badge
  (config / override / store-only), enabled toggle, command preview, tier→model
  summary (with model flag), last test result (ok/failed + time). Providers
  defined only in `config.toml` render from defaults with no override (§2.4).
- **Add/Edit provider modal** — full `BridgeProviderProfile` editor (saving an
  edit to a config provider writes an **override**, never `config.toml`):
  - command (argv), enabled;
  - models: `flag`, `cheap`, `normal`, `smart`;
  - `prompt_flags`, `yolo_flags`, `starter_prompt`, `prompt_delivery`;
  - startup detection: enabled, probe seconds, capture interval, blocked
    patterns, auto-enter patterns + parallel pre-keys, `startup_unknown_is_blocked`,
    reason mapping;
  - activity detection: enabled, sample lines, ignore-bottom, check interval,
    min/max gap.
  - **No credentials/env fields (D2)** — the modal never collects secrets.
- **Test** action per provider → spinner → ok/fail + sanitized diagnostics from
  the start-success probe (D1). Advisory only; never blocks.
- **Refresh capabilities** action (re-derive).
- Keep a note: "providers run in your machine's shell environment; Heimdall
  never stores or sends credentials."

**RTK Query (new, cookie-auth, add to `bridgeSupport.ts`)**
`useListBridgeProvidersQuery({bridgeId})`,
`useUpsertBridgeProviderMutation`, `useDeleteBridgeProviderMutation`,
`useTestBridgeProviderMutation`, `useRefreshBridgeCapabilitiesMutation`. Mutations
invalidate `Bridges/{id}` and a new `BridgeProviders/{id}` tag so the Bridges
page capability list and the Agent-create picker refresh.

**Actions:** add provider (store-only); edit provider (saves an override);
delete store-only provider; toggle enabled; edit models/flags/detection; test
(start-success probe); refresh capabilities. No credential entry.

**Fixes (audit §3.6):** A5 render capabilities as an array (not `Object.entries`);
A6 replace the read-only page with the full configure/test rewrite; A7 factor
capability presence into readiness.

**Debug IDs:** `providers-bridge-select`, `providers-add-btn`,
`providers-provider-row-${name}`, `providers-enabled-toggle-${name}`,
`providers-edit-btn-${name}`, `providers-delete-btn-${name}`,
`providers-test-btn-${name}`, `providers-test-result-${name}`,
`providers-refresh-caps-btn`, plus modal ids
(`providers-editor-*`: `name-input`, `command-input`, `models-flag-input`,
`models-cheap-input`/`normal`/`smart`, `prompt-flags-input`, `yolo-flags-input`,
`starter-prompt-input`, `startup-enabled-checkbox`, `startup-probe-input`,
`startup-blocked-patterns-input`, `startup-auto-enter-patterns-input`,
`startup-auto-enter-pre-keys-input`, `activity-enabled-checkbox`,
`activity-sample-lines-input`, `activity-check-interval-input`,
`provider-source-badge-${name}`, `save-btn`, `cancel-btn`).

---

### Page 3 — Agents → Create Agent (`/agents`, `AgentsPanel` rewrite)

**Purpose:** create a durable agent identity (template/persona + name), give it a
default provider following the §2.5 resolution model, and enable it on the
bridge machine (R3, R4). The create flow is intentionally short; provider
override is optional.

**Agent list**
- Durable identities (`GET /api/v1/agents`): name (agent id), template, default
  provider/tier, `supported_bridge_count`, running instance count, state.
- Row actions: open detail (Page 3b), launch instance (quick), archive.

**Create Agent modal (intuitive, minimal)**
Step-style single form:
1. **Name (agent id)** — required; `agents-create-name-input`.
2. **Template / persona** — required select from `GET /api/v1/templates`;
   `agents-create-template-select`. Persona/instructions come from the template;
   an optional "customize instructions" textarea is collapsed by default.
3. **Where it runs** — bridge(s) to enable. Defaults to "all my bridges";
   `agents-create-bridge-scope`.
4. **Provider** — a **segmented control** implementing §2.5:
   - `Use bridge default` (default choice; no provider stored on the agent),
   - `Same provider on all bridges` → reveals `agents-create-provider-select`
     (union of capabilities across selected bridges),
   - `Per-bridge` → defer to Page 3b after create (keep create simple).
   Control id `agents-create-provider-scope`.
5. **Preferred tier** — always a simple select (`cheap`/`normal`/`smart`),
   constrained to tiers the resolved provider advertises;
   `agents-create-tier-select`. This is the one knob users normally touch.

On submit: `POST /api/v1/agents` (name/slug, template_id, optional
default_provider/default_tier), then `PUT /api/v1/agents/{id}/bridge-support`
enabling the selected bridges (each row provider/tier defaulting from §2.5). If
no online bridge reports capabilities, block submit with a link to
Bridges/Providers (`agents-no-capabilities-warning`).

**RTK Query**
`useListAgentIdentitiesQuery` (`GET /agents`), `useCreateAgentMutation`
(`POST /agents`), `useEnableBridgeSupportMutation`
(`PUT /agents/{id}/bridge-support`), templates via settings/templates query.
Provider/tier options derived from `useListBridgesQuery` capabilities +
`unionCapabilities()` (§5).

**Fixes (audit §3.6):** A8 remove hardcoded `claude`/`smart` (R3); A9 compute real
`supported_bridge_count`/`active_instance_count` server-side (drives the enable
button); A10 align the `bridge-support` PUT body contract with `replace_supports`;
A11 add template/persona picker and §2.5 provider control.

**Debug IDs:** `agents-add-agent-btn`, `agents-create-name-input`,
`agents-create-template-select`, `agents-create-instructions-input`,
`agents-create-bridge-scope`, `agents-create-provider-scope`,
`agents-create-provider-select`, `agents-create-tier-select`,
`agents-create-submit-btn`, `agents-create-cancel-btn`,
`agents-no-capabilities-warning`, `agents-agent-row-${agentId}`,
`agents-agent-open-btn-${agentId}`, `agents-agent-launch-btn-${agentId}`.

---

### Page 3b — Agent detail: bridge support + instances (`/agents/{agentId}`)

**Purpose:** manage where an agent runs, its per-bridge provider overrides, and
its **multiple running instances** (the deploy/run surface).

**Sections/states**
- **Header:** name (agent id), template, default provider/tier, edit/archive.
- **Default provider/tier editor** (§2.5 "all bridges" level):
  segmented `Use bridge default` / `Same provider on all bridges`; tier select.
  Saves via `PATCH /api/v1/agents/{id}`.
- **Bridge support list** — one row per user bridge:
  - enabled toggle (`agent-detail-bridge-toggle-${bridgeId}`),
  - **provider override for this bridge**: segmented `Bridge default` /
    `Override` → provider select from that bridge's capabilities
    (`agent-detail-bridge-provider-select-${bridgeId}`),
  - **tier** select for this bridge (`agent-detail-bridge-tier-select-${bridgeId}`),
  - **effective resolution preview**: shows the resolved provider+tier from §2.5
    (`agent-detail-bridge-effective-${bridgeId}`),
  - saves via `PATCH /api/v1/agents/{id}/bridge-support/{bridgeId}`.
- **Instances section (start multiple instances):**
  - "Launch instance" button (`agent-detail-launch-instance-btn`) → optional
    bridge/project/tier picker (defaults from §2.5), then
    `POST /api/v1/agent-instances` (no `chain_id` → Hub creates a private chain
    + 1:1 conversation). Repeat to start as many instances as wanted.
  - Instance list: each row shows `agent_instance_id`, bridge, resolved
    provider/tier, `runtime_status`, conversation link, stop/restart.
    Rows `agent-detail-instance-row-${instanceId}` with
    `-open-btn`, `-stop-btn`, `-restart-btn`, `-status`.
  - Uses `GET /api/v1/agent-instances?agent_id=...`,
    `POST /api/v1/agent-instances/{id}/stop`, `.../restart`.

**RTK Query**
`useFetchAgentQuery` (detail), `useListAgentBridgeSupportQuery`,
`usePatchAgentBridgeSupportMutation`, `useUpdateAgentMutation` (PATCH agent),
`useListAgentInstancesQuery({agentId})` (new, `GET /agent-instances`),
`useCreateAgentInstanceMutation` (`POST /agent-instances`),
`useStopAgentInstanceMutation`, `useRestartAgentInstanceMutation`. Capabilities
from `useListBridgesQuery`.

**Actions:** edit default provider/tier; enable/disable per bridge; set/clear
per-bridge provider override; set per-bridge tier; launch/stop/restart
instances; open an instance conversation.

---

### Page 4 — New Conversation composer (`/conversations/new`, `ConversationLaunchComposer`)

**Purpose:** the quick path to start an instance → conversation → chat. Same
launch as Page 3b's "launch instance", but agent-first and chat-first.

**Sections/states**
- Agent select (durable identities with ≥1 enabled bridge support;
  `new-convo-no-runnable-agent-warning` otherwise).
- Project select (default **Conversations** project when unset).
- **Advanced (collapsed by default):** bridge / provider / tier overrides,
  constrained to the intersection of the agent's enabled bridge support and each
  bridge's reported capabilities (§2.5 instance level). Normal users skip this
  and get the resolved defaults.
- First send → `POST /api/v1/agent-instances` (creates private chain + instance
  + 1:1 conversation), then navigate to `/conversations/{id}`.

**RTK Query**
Agents from `useListAgentIdentitiesQuery`; bridges/capabilities from
`useListBridgesQuery`; projects from sidebar/projects endpoints; create via
`useCreateAgentInstanceMutation` (`POST /api/v1/agent-instances`).

**Actions:** choose agent/project; optionally override bridge/provider/tier;
send first message; open conversation.

**Debug IDs:** `new-convo-agent-select`, `new-convo-project-select`,
`new-convo-advanced-toggle`, `new-convo-bridge-select`,
`new-convo-provider-select`, `new-convo-tier-select`,
`new-convo-input`, `new-convo-send-btn`, `new-convo-error`,
`new-convo-no-runnable-agent-warning`.

**Fixes (audit §3.6):** A12 route capabilities through the shared normalize/
resolve helpers; A13 stop silently dropping `project_id` once the default project
is exposed; A14 migrate the hand-rolled `fetch` to the shared cookie-auth RTKQ
endpoints so WS invalidation applies.

---

## 5. Cross-cutting UI rules

- **Capabilities are the single source for provider/tier options** everywhere
  (Agent create, composer, bridge-support overrides). Add one shared helper,
  e.g. `selectBridgeCapabilities()` / `unionCapabilities(bridges)`, and a
  `normalizeBridgeCapabilities(raw)` used by Bridges, Providers, Agents, and the
  composer so the wire shape is parsed in exactly one place.
- **Provider/tier resolution (§2.5) is implemented once**, in a shared
  `resolveProviderTier(agent, bridge, request)` helper used by Agent create,
  Agent detail (per-bridge rows + effective preview), and the composer. No page
  reimplements the precedence chain.
- **Provider override is opt-in; tier is the everyday control.** Default UI shows
  "Use bridge default" + a tier select; provider selects appear only when the
  user explicitly chooses an override scope.
- **No onboarding surface uses the legacy session/clientToken path** (R5).
- **Offline/empty states are first-class**: no bridges, bridge offline, no
  capabilities, no runnable agent each have an explicit message + the next
  action link.
- **Every new interactive element gets a `data-debug-id`** and is added to the
  `AGENTS.md` registry when built.

---

## 6. Build order and dependencies

1. **DONE — Backend: bridge provider store + capabilities-from-store** (unblocks real
   capabilities everywhere; removes hardcoded `claude/normal`); bridge default
   provider. Phase commit: `3e8d869`.
2. **DONE — Backend: hub provider relay routes + `write_bridge_json` fix** (incl. A2/A9
   real `active_instance_count` / `supported_bridge_count`). Phase commits: `ff075b5`, `f627808`.
3. **DONE — Backend: agent deploy/run gaps (§3.5)** — `agent-instances` `agent_id`
   filter, §2.5 resolution on create, `PATCH /agents/{id}` defaults, stop/restart
   wiring, and the A10 `bridge-support` PUT-body contract. Phase commits: `1162d8f`, `a339bec`.
3a. **DONE — Backend/ctl: agent runtime path (§3.5a)** — conversation READ for instance
   tokens (B1), real `agent.context` relay (B2), fix start-success command
   rendering/routing (B3), Bridge-scoped instance assertion trust (B4), keep
   HEIMDALL_* env + regression test (B5). Required for agents to use `ham-ctl`
   to start-success and read/write conversations. Phase commits: `45cbb3a`, `9188b1a`.
3b. **DONE — ctl refactor (§3.7)** — split the `src/ctl` monolith into a package (one
   command family per file); remove access points for legacy daemon-only commands
   but keep the code parked+deprecated under `src/ctl/legacy/` (C2/C3); drop
   redundant aliases (C4); enforce bearer-only auth (C5); add delta-capable agent
   reads (C6/C7); per-subcommand help with examples + high-level top-level help
   (C8–C11). Phase commit: `f273a09`.
4. **Page 1 Bridges** polish (capability rendering, cookie-auth cleanup, poll).
5. **Page 2 Providers** rewrite (configure + test, bridge-persisted, set default).
6. **Page 3 Agents** create (template + name + §2.5 provider, tier-only normal
   path).
7. **Page 3b Agent detail** — per-bridge overrides + multi-instance deploy/run.
8. **Page 4 Composer** — quick launch with optional overrides.

Pages 1 and 3–4 can proceed against real capabilities only after steps 1–2; a
temporary path is to ship Page 1 first (it needs no new backend) while the
provider store lands.

---

## 7. Decisions (resolved)

- D1 — **Test semantics:** start-success probe. The Bridge launches the provider
  and confirms the agent can run `ham-ctl ... start-success` within a bounded
  wait. No per-tier round-trip, no token spend beyond CLI startup. (§3.1, §3.2.4)
- D2 — **Credentials:** none. The Bridge stores no API keys/env; providers run
  in the operator's existing shell environment (assumed pre-configured/logged
  in). The Providers UI never collects secrets. (§2.2, Page 2)
- D3 — **Build sequencing:** backend-first. Ship the bridge provider store +
  hub relay routes before the Providers UI (UI alone cannot satisfy R1). (§6)
- D4 — **Config defaults + overrides:** `config.toml` providers are read-only
  defaults surfaced in the UI; edits save as overrides in the bridge store;
  effective profile = merge. Explicit "reset to config defaults" is deferred
  post-v1. (§2.4)

Superseded open questions (kept for history):

- ~~Test semantics~~ → D1 above.
- ~~Credentials in the profile~~ → D2 above.
- ~~Build sequencing~~ → D3 above.
- ~~Reset-to-config action~~ → D4 above (deferred post-v1).
