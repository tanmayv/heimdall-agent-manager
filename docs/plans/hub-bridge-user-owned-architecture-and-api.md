# Heimdall Hub + User-Owned Bridge Architecture and API Plan

Status: Draft target architecture  
Scope: Hub/user/bridge data model, browser/API authentication, SPA-friendly REST API, green-field build milestones  
Out of scope for this document: the full Hub ↔ Bridge runtime command protocol. A short preview is included, but the detailed bridge protocol should be specified in the next document.

---

## 1. Executive summary

Heimdall should move away from daemon federation, remote proxy agents, and local proxy instance mapping. The simpler target architecture is:

> Heimdall Hub owns durable product state. User-owned Bridges run wrappers on user machines. Authentik/Authelia handles browser login. Heimdall scopes every durable resource to the authenticated user.

This means:

- There is one central durable Hub, often running on a VPS.
- Users authenticate through Authentik/Authelia in front of the Hub/UI.
- Users enroll Bridges from the UI/CLI.
- A Bridge runs on a user's machine and connects outbound to the Hub.
- Bridges report host metadata, provider capabilities, and runtime state.
- Agent identities, task chains, memories, projects, chats, artifacts, templates, and agent instances are Hub records owned by a user.
- Providers and filesystem paths are machine-local details reported/configured per Bridge.
- Agent instances are Hub-owned runtime records located on a Bridge.
- No Team model for now.
- No Visibility/shared-resource model for now.
- No Federation API.
- No local proxy agent for a remote agent.
- No token in query params or request bodies.

---

## 2. Design goals

### 2.1 Simpler ownership

Every durable user-facing resource has exactly one owner:

```ts
owner_user_id: string
```

There are no teams and no resource visibility levels in the target v1 model.

Authorization rule for user-authenticated requests:

```text
auth.user_id == resource.owner_user_id
```

Machine-token requests resolve ownership through the authenticated machine principal, not through caller-supplied fields:

```text
bridge_token:
  owner_user_id = bridge.owner_user_id
  scope = resources/commands assigned to that bridge only

instance_token:
  owner_user_id = agent_instance.owner_user_id
  scope = that instance's own runtime/chat/task/artifact context only
```

For writes performed by Bridges, Wrappers, or agents, `owner_user_id` is assigned by auth middleware from the authenticated Bridge/Instance record. Request bodies must not carry authoritative `owner_user_id` or `user_id`.

Every independently-queryable durable table carries its own `owner_user_id`, including child records whose owner is logically derivable from a parent. This is a deliberate denormalization for uniform authorization, cheap tenant-scoped listing/pagination, and future PostgreSQL Row-Level Security (an RLS policy over a local column is far simpler and faster than one over a join/subquery). It is safe here because **ownership is immutable**.

Rules that make the denormalization safe:

- `owner_user_id` is **set once at insert and is immutable**. No update path ever changes it. Because a resource never changes owner, a stored copy can never become stale.
- Equality with the parent owner is **enforced at creation** as the single choke point (invariant 17). Writers reject a create whose child owner would not equal the parent owner.
- Required equalities:
  - `AgentBridgeSupport.owner_user_id` must equal both `Agent.owner_user_id` and `Bridge.owner_user_id`.
  - `AgentInstance.owner_user_id` must equal both `Agent.owner_user_id` and `Bridge.owner_user_id`.
  - `ProjectBridgePath.owner_user_id` must equal both `Project.owner_user_id` and `Bridge.owner_user_id`.
  - `Task.owner_user_id` must equal `TaskChain.owner_user_id`.
  - `ChatMessage.owner_user_id` must equal `ChatConversation.owner_user_id`.
  - `Artifact.owner_user_id` must equal the owner of its associated chain/task/agent/project context.

Rationale note: the `agent.owner == bridge.owner` check for an instance must be performed at launch regardless of storage choice, so storing the resolved `owner_user_id` on the child adds no meaningful validation cost while making every downstream read a flat `WHERE owner_user_id = ?`.

Chat in v1 is single-owner user↔agent chat. Since there are no teams and no cross-user sharing, `agent_to_user` chat is always between a user and that user's own agent/instance. Cross-user agent messaging is not part of v1.

### 2.2 Centralized durable state

The Hub owns:

- users
- agent identities
- agent instances
- agent bridge support policy
- task chains
- tasks
- task comments/status
- memory
- projects
- project bridge path overrides
- chats/messages
- artifacts metadata/content policy
- templates/personas
- bridge registry
- bridge enrollment
- user API tokens if supported for CLI

All of the above is stored in a relational database behind a repository layer (see Section 7A). There is no JSONL or flat-file durable store, and no SQLite-specific coupling above the repository layer.

### 2.3 Bridge as a user-owned runner

The Bridge owns machine-local runtime execution only:

- provider credentials/config
- available provider capabilities
- wrapper command/profile config
- local filesystem paths
- tmux sessions
- local run dirs
- wrapper launch/supervision
- local project path validation
- startup/activity detection execution

The Bridge should not own durable product resources.

### 2.4 Browser login delegated to Authentik/Authelia

Heimdall UI should not implement its own login screen.

Browser flow:

```text
Browser
  -> Authentik/Authelia/reverse proxy
  -> Heimdall Hub UI/API/WS
```

The Hub receives trusted identity headers from Authentik/Authelia and maps them to a Heimdall user.

### 2.5 Machine auth uses bearer tokens only

For CLI, Bridge, Wrapper, and runtime instance APIs:

```http
Authorization: Bearer <token>
```

Never accept tokens in:

```text
?token=...
```

or:

```json
{ "token": "..." }
```

### 2.6 SPA-friendly API

The UI should avoid unnecessary API calls and large payloads.

API defaults:

- compact list responses
- cursor pagination
- filter/search/sort parameters
- explicit expansions for detail pages
- sparse field selection where useful
- lightweight WebSocket invalidation events
- version/updated_at on mutable resources
- optional ETag/If-None-Match support

### 2.7 Stable resource IDs with user-local display names

Internal IDs should be globally unique and opaque:

```text
agt_...
brg_...
inst_...
proj_...
chain_...
task_...
```

User-facing names/slugs are scoped to a user. Two users may both have an agent slug `backend-agent`; internally those are different `agent_id` values.

---

## 3. Non-goals for v1

The following should not be part of the initial target model:

- Teams
- Team-owned resources
- Visibility/shared-resource policies
- Cross-user sharing
- Federation daemon-to-daemon APIs
- Local proxy agent records for remote agents
- Local proxy instance mappings
- Browser login form in Heimdall UI
- Passing tokens in URL params
- Agent-to-agent inbox/federated message-provider APIs
- Cross-user agent messaging
- Full durable state replication to Bridges

These can be revisited later after the Hub/Bridge/user-owned model is stable.

---

## 3.1 V1 minimal subset decisions

The prior review follow-ups are resolved as concrete scope decisions. V1 should optimize for a working Hub/Bridge/user-owned system before adding guardrails and quality-of-life features.

V1 minimal subset:

- REST/user-facing architecture and Bridge runtime protocol are split into separate documents.
- API v1 includes versioned base path, success/list/error envelopes, cursor pagination, basic filter/sort/search, and only the listed expansions.
- Defer sparse fields, ETag/`If-None-Match`, optimistic concurrency/`If-Match`, and universal `version` fields. Keep `updated_at` in v1.
- Defer batch lookup until measured UI request fan-out requires it.
- Treat user API tokens as full-user tokens and Bridge tokens as full-bridge-runtime tokens for their own Bridge in v1; fine-grained scopes are post-v1.
- Defer Bridge token rotation; revoke + re-enroll is sufficient for v1.
- Use Bridge WebSocket only in v1; HTTP runtime fallback is post-v1.
- Hardcode Bridge protocol `protocol_version = 1` and reject mismatches; negotiation is post-v1.
- Do not build durable offline command queues in v1. If a Bridge is offline, return `bridge_offline`.
- Keep expansions limited to `instances`, `bridge_support`, `bridge_paths`, and `tasks`.
- Task/chain lifecycle is manual and simple: `publish_state` (draft/published) plus an explicit execution `status`. No auto-assignment, no auto-promotion of the next task, no scheduled nudges. Nudges are manual (agent- or user-triggered from the UI). Scheduling and auto-assignment are post-v1.
- First working cut prioritizes the single-user local case: one default user and one default local Bridge, exercised end to end. Multi-user hardening follows after the single-user path works.
- Initial tests focus on trusted-proxy auth, cross-user denial, one-time Bridge enrollment, explicit-Bridge launch, and offline-Bridge error. Broader matrices follow after cutover.

This is a green-field rewrite. Data migration from the current daemon is out of scope; there are no legacy records to import, and no federation/proxy compatibility shims are built.

---

## 4. Terminology

| Term | Meaning |
|---|---|
| Hub | Central durable control plane and API server. |
| Bridge | User-owned machine-local runner that connects outbound to Hub and launches wrappers. |
| Wrapper | Per-agent runtime shim launched by a Bridge; manages tmux/bootstrap/startup/activity. |
| User | Authenticated Heimdall user derived from Authentik/Authelia trusted headers or a bearer user token. |
| Agent | Durable Hub-owned identity/persona/instructions, owned by one user. |
| Agent instance | Runtime instance of an Agent located on one Bridge. Hub owns record; Bridge runs process. |
| Bridge enrollment | One-time user-created credential used to add a Bridge to the user's account. |
| Bridge token | Long-lived/revocable bearer credential used by a Bridge after enrollment. |
| Agent bridge support | Per-agent policy declaring which Bridges the agent is allowed to run on and with what defaults. |
| Project bridge path | Bridge-local path override for a Hub-owned Project. |

---

## 5. Core invariants

1. Hub is the source of truth for durable product state.
2. Bridge is a runner, not a data owner.
3. User-facing durable resources have `owner_user_id`.
4. No resource authorization depends on a caller-supplied `user_id` body/query parameter.
5. Auth middleware creates the authoritative request user context.
6. Browser user auth is handled by Authentik/Authelia or another trusted reverse proxy.
7. Heimdall UI has no login page; unauthenticated state links to external login.
8. Machine clients authenticate with `Authorization: Bearer ...`.
9. Bridges are owned by exactly one user.
10. Agent IDs are owned by users, not Bridges.
11. Agent instances are owned by users and located on Bridges.
12. Agent bridge support controls which Bridges may run an Agent.
13. Project identity is Hub-owned/user-owned; project filesystem paths are Bridge-local.
14. A Project has a mandatory `default_path` and optional Bridge-specific overrides.
15. List endpoints are compact and paginated by default.
16. WebSocket user events are lightweight invalidation/summary events, not durable data streams.
17. Every independently-queryable durable table carries its own `owner_user_id`. It is set once at insert, is immutable, and must equal the parent resource owner; equality is enforced at creation. Immutability is what makes the stored copy always correct (ownership never changes) and enables flat tenant filtering and PostgreSQL RLS.
18. Machine-token auth resolves `owner_user_id` from the authenticated Bridge/Instance record and scopes access to that Bridge/Instance.
19. Agents with no enabled Bridge support cannot run. At least one enabled `AgentBridgeSupport` row is required before scheduling or explicit launch.
20. Task assignment targets concrete same-chain actor refs, not arbitrary agent identities. The coordinator instance is the default assignee. Chain-level default reviewers are inherited by tasks unless overridden.
20a. Task and TaskChain each use two orthogonal state fields: `publish_state` (draft/published) and a single execution `status` enum that only applies once published. There is no single flat status enum.
20b. Dependency unblocking is derived from task status (only `completed` and `cancelled` unblock dependents; `paused` does not) through one centralized helper, not stored per edge.
20d. Task ordering within a chain is backend-owned and single-source: the Hub computes the transitively reduced dependency graph and a canonical topological order (tie-broken by priority, then created_at) from `depends_on`. The chain-graph API, the UI graph, and next-task selection all use this same order. The UI never computes its own ordering. Dependency cycles are rejected at create/update.
20c. v1 has no auto-assignment, no auto-promotion of the next task, and no scheduled/automatic nudges. Nudges are manual, triggered by an agent or a user from the UI. Scheduling and auto-assignment are post-v1.
21. Memory may be proposed by a user or authorized instance, but only the owning user may approve/reject pending memory.
22. Agent-to-agent inbox/federated message-provider APIs are not part of v1; v1 chat is user↔own-agent only.
22a. Every `AgentInstance` is bound 1:1 to exactly one `ChatConversation` (no standalone instances). Instances created from the composer, from an explicit Agent-page launch, or by the system for task-chain work all get a conversation. This makes chatting with the coordinator and with individual chain agents uniform.
22b. Every `AgentInstance` belongs to exactly one immutable `TaskChain` (`chain_id` required). Creating an instance with an existing `chain_id` hydrates that agent into that chain. Creating an instance without a `chain_id` creates a private/default chain for that instance in the same transaction. A live instance cannot be moved into another chain; cross-chain context transfer happens through memory/artifacts, not live-context reuse.
23. All durable state lives in a relational database. There are no JSONL, append-only flat-file, or ad hoc on-disk stores for durable product state. Only truly ephemeral in-memory projections (live sockets, connection registries) may live outside the database.
24. The database engine is an implementation detail behind a repository layer. SQLite is the v1 engine, but no business logic, service, or handler may depend on SQLite-specific APIs, types, SQL dialect quirks, or file semantics. Swapping SQLite for PostgreSQL must be a data-access-layer change only.
25. No singletons for state or dependencies. Stores, repositories, services, and connection handles are constructed once at startup and passed explicitly via dependency injection. No global mutable state, no package-level mutable singletons.
26. Separation of concerns is enforced by layer: HTTP/WS transport → service (business logic) → repository (persistence). Transport handlers never write SQL; repositories never contain business rules.
27. State mutation for a given resource is centralized in that resource's service/repository. Write paths are not scattered across handlers; every durable mutation for a resource funnels through one owning module.

---

## 6. User and authentication model

### 6.1 User model

The user model is intentionally simple.

```ts
User {
  user_id: string        // normalized authenticated username
  name: string           // raw username from Authentik/Authelia
  display_name?: string
  email?: string
  status: "active" | "disabled"
  created_at: string
  updated_at: string
}
```

For the initial version:

```text
user_id = normalized authenticated username
```

Example trusted headers:

```http
X-authentik-username: tanmay
X-authentik-name: Tanmay Vijay
X-authentik-email: tanmay@example.com
```

Mapped Hub user:

```json
{
  "user_id": "tanmay",
  "name": "tanmay",
  "display_name": "Tanmay Vijay",
  "email": "tanmay@example.com"
}
```

Important assumption:

- Authentik/Authelia usernames must be unique and stable enough to use as Heimdall user IDs.
- If usernames can be renamed later, we should introduce an immutable `subject` internally before production multi-user deployment.

### 6.2 Trusted proxy auth

Hub config example:

```toml
[auth]
mode = "trusted_proxy"

[auth.trusted_proxy]
username_header = "X-authentik-username"
display_name_header = "X-authentik-name"
email_header = "X-authentik-email"
trusted_proxy_cidrs = ["127.0.0.1/32"]
auto_provision_users = true

[auth.logout]
url = "https://auth.example.com/application/o/heimdall/end-session/"
```

Middleware requirements:

1. Verify request came from a trusted proxy IP/CIDR.
2. Read configured username/display/email headers.
3. Reject missing username.
4. Normalize username into `user_id`.
5. Lookup or auto-provision `User`.
6. Reject disabled users.
7. Attach `AuthContext` to request.

```ts
AuthContext {
  kind: "trusted_proxy" | "user_token" | "bridge_token" | "enrollment_token" | "instance_token"
  user_id?: string
  name?: string
  display_name?: string
  email?: string
  bridge_id?: string
  agent_instance_id?: string
  token_scopes?: string[]
}
```

### 6.3 User API token auth


For CLI access, the Hub may support user API tokens.

Rules:

- Tokens are generated by Hub for the authenticated user.
- Tokens are stored hashed.
- Tokens are presented only in the Authorization header.
- Token grants act as that user and are scoped by `owner_user_id`.

Example:

```http
Authorization: Bearer hut_...
```

Potential scopes:

```text
user:read
agents:read
agents:write
bridges:write
tasks:write
memory:write
artifacts:write
```

Fine-grained user token scopes are post-v1. V1 treats user API tokens as full-user tokens for the owning user.

### 6.4 Bridge auth

After enrollment, the Bridge receives a bridge token:

```http
Authorization: Bearer hbr_...
```

Bridge tokens are not user tokens. They resolve `owner_user_id` from the authenticated Bridge record and can only perform Bridge runtime actions for that Bridge.

Bridge token allowed actions:

- connect to `/api/v1/bridge-ws`
- heartbeat
- report capabilities
- report runtime status
- receive launch/stop/validation commands
- fetch bootstrap for instances assigned to that bridge
- fetch project path validation command details

Bridge token forbidden actions:

- list all user agents
- list all user tasks
- mutate arbitrary task chains
- access resources not assigned to the bridge
- use another bridge ID

### 6.5 Instance auth

Wrappers/agents may receive a short-lived or revocable `instance_token`.

Instance token scope:

- identify one `agent_instance_id`
- resolve `owner_user_id = agent_instance.owner_user_id`
- send runtime heartbeat/activity/startup status for that instance
- fetch own chat/task context if allowed
- call agent-facing APIs as that instance

Instance-token scoping must be enforced by auth middleware and shared authorization helpers, not ad hoc in each handler. An instance token cannot become a general user token and cannot access arbitrary agents, Bridges, or user resources.

Agent-to-agent inbox/message-provider APIs are a v1 non-goal, so instance tokens do not grant an agent-to-agent inbox scope in this target API.

### 6.6 Local development auth proxy (Authentik/Authelia stand-in)

For local testing and single-machine deployment, we do not want to run a full Authentik/Authelia install, and we do not want a "dev bypass" branch inside the Hub. A dev bypass would fork the auth code path and let real auth bugs hide behind a shortcut.

Instead, we keep the Hub in exactly one auth mode (`trusted_proxy`) and put a tiny stand-in proxy in front of it. The Hub cannot tell the difference between the dev proxy and a real IdP; only the front component changes.

```text
Browser / curl
  -> ham-dev-proxy      (stand-in for Authentik/Authelia)
  -> Hub (/api/v1, trusted_proxy mode, CIDR-restricted to the proxy)
```

#### 6.6.1 Design rules

1. The dev proxy is a **separate binary** (`ham-dev-proxy`), never code compiled into the Hub. It cannot ship coupled to the Hub.
2. The Hub keeps `mode = "trusted_proxy"` and binds only to a trusted CIDR (loopback), so it never accepts trusted headers from arbitrary clients.
3. The dev proxy performs the two jobs a real IdP proxy performs:
   - **Strip** any client-supplied trusted headers (`X-authentik-*`) from the incoming request so a browser/curl cannot spoof identity.
   - **Inject** authoritative trusted headers for the selected dev user, then forward to the Hub.
4. The dev proxy forwards everything else unchanged, including `Authorization: Bearer ...`, so CLI/Bridge/agent bearer-token flows pass straight through and are unaffected.
5. Because the Hub still enforces the trusted-proxy CIDR, the same spoofing-protection tests that guard production also guard dev.

#### 6.6.2 Dev proxy config

```toml
[dev_proxy]
listen = "127.0.0.1:8080"
hub_url = "http://127.0.0.1:8081"

# Header names must match the Hub's [auth.trusted_proxy] config.
username_header = "X-authentik-username"
display_name_header = "X-authentik-name"
email_header = "X-authentik-email"

# Default identity injected when no user is explicitly selected.
default_user = "tanmay"

[[dev_proxy.users]]
username = "tanmay"
display_name = "Tanmay Vijay"
email = "tanmay@example.com"

[[dev_proxy.users]]
username = "reviewer"
display_name = "Reviewer User"
email = "reviewer@example.com"
```

#### 6.6.3 Selecting the active user

To test cross-user isolation from a browser, the dev proxy supports a simple user switch. Any of the following may select the active dev user; the proxy resolves one authoritative user per request and injects only that user's headers:

- a `ham_dev_user` cookie (set via a small `/_dev/login?user=<username>` endpoint on the proxy),
- an `X-Dev-User: <username>` request header (convenient for `curl`/tests),
- otherwise `default_user`.

The proxy validates the selected username against its configured `users` list and rejects unknown users, mirroring how a real IdP only issues identities it knows.

#### 6.6.4 Logout

`GET /api/v1/me/logout-url` in dev returns the proxy's `/_dev/logout` URL, which clears the `ham_dev_user` cookie and returns to `default_user`. This keeps the UI logout flow identical to production, where the URL points at the real IdP end-session endpoint.

#### 6.6.5 Explicit non-goals for the dev proxy

- It is not a security boundary and must never be exposed publicly.
- It does no password auth, sessions, or token issuance beyond the dev-user cookie.
- It is not used in production; production uses Authentik/Authelia or another trusted reverse proxy with the same header contract.

---

## 7. Durable data model

### 7.1 User

```ts
User {
  user_id: string
  name: string
  display_name?: string
  email?: string
  status: "active" | "disabled"
  created_at: string
  updated_at: string
}
```

Indexes:

- primary: `user_id`
- optional: `name`
- optional: `email`

### 7.2 Bridge

```ts
Bridge {
  bridge_id: string
  owner_user_id: string
  label: string
  label_is_user_customized: boolean
  machine_hostname: string
  machine_os?: string
  machine_arch?: string
  status: "online" | "offline" | "revoked"
  capabilities: BridgeCapability[]
  active_instance_count: number
  created_at: string
  updated_at: string
  last_seen_at?: string
  revoked_at?: string
}
```

Default label rule:

```text
if enrollment had explicit label:
  label = enrollment label
  label_is_user_customized = true
else:
  label = reported hostname
  label_is_user_customized = false
```

On later heartbeat/connect:

- Hub may update hostname/os/arch.
- Hub must not overwrite a user-customized label.
- If label is not customized and hostname changes, Hub may update label to the new hostname.

### 7.3 Bridge capability

```ts
BridgeCapability {
  provider: string
  tiers: string[]
  default_tier?: string
  max_concurrent_agents?: number
  metadata?: Record<string, unknown>
}
```

Examples:

```json
{
  "provider": "claude",
  "tiers": ["normal", "smart"],
  "default_tier": "normal",
  "max_concurrent_agents": 3
}
```

Provider credentials remain on the Bridge.

### 7.4 Bridge enrollment

```ts
BridgeEnrollment {
  enrollment_id: string
  owner_user_id: string
  label?: string
  token_hash: string
  expires_at: string
  consumed_at?: string
  consumed_by_bridge_id?: string
  created_at: string
}
```

Rules:

- Enrollment token is shown once.
- Enrollment token is one-time.
- Enrollment token expires.
- Consumed enrollment cannot be reused.
- Enrollment token maps to the owner user.

### 7.5 Agent

```ts
Agent {
  agent_id: string
  owner_user_id: string
  name: string
  slug: string
  template_id?: string
  default_provider?: string
  default_tier?: string
  instructions?: string
  state: "active" | "archived"
  created_at: string
  updated_at: string
}
```

Rules:

- `agent_id` is globally unique.
- `owner_user_id + slug` is unique.
- Agent belongs to user, not Bridge.
- Agent can run on Bridges only through AgentBridgeSupport.

### 7.6 Agent bridge support

```ts
AgentBridgeSupport {
  agent_id: string
  bridge_id: string
  owner_user_id: string
  enabled: boolean
  provider?: string
  tier?: string
  priority?: number
  max_instances?: number
  created_at: string
  updated_at: string
}
```

Rules:

- User must own Agent.
- User must own Bridge.
- If `enabled = false`, scheduler must not select that Bridge for the Agent.
- If no enabled support records exist, the agent cannot run. Explicit launch requests must fail with `validation_failed` or `provider_unavailable` until at least one `AgentBridgeSupport` row is enabled; UI may offer to create/enable support before retrying, but launch itself must not implicitly create support.

Provider/tier resolution:

```text
request override
  > agent bridge-support override
  > agent default provider/tier
  > bridge provider default
```

### 7.7 Agent instance

An `AgentInstance` is a **durable, restartable session**, not a single process run. The record persists across process restarts and keeps the same `agent_instance_id`. `runtime_status` describes the *current* process; the record outlives any one process. This is what lets a conversation own exactly one instance for its whole life (see 7.13) while the underlying process can stop and start.

```ts
AgentInstance {
  agent_instance_id: string
  owner_user_id: string
  agent_id: string
  bridge_id: string            // pinned; the session always relaunches on this bridge
  chain_id: string             // required, immutable; every instance belongs to exactly one chain
  conversation_id: string      // required 1:1 conversation owner
  provider: string
  tier: string
  project_id?: string
  project_path?: string       // effective path snapshot captured at first launch
  runtime_status: "launching" | "starting" | "running" | "idle" | "busy" | "stopping" | "stopped" | "failed" | "unreachable"
  startup_status?: "starting" | "ready" | "startup_blocked" | "startup_failed" | "startup_unknown"
  activity_status?: "unknown" | "idle" | "active" | "blocked"
  status_message?: string
  last_applied_seq?: number   // highest Bridge state_seq applied; monotonic ACROSS restarts
  run_count?: number          // number of times this session has been (re)started
  created_at: string
  updated_at: string
  started_at?: string         // start of the CURRENT run
  stopped_at?: string         // end of the last run (when stopped)
  last_seen_at?: string
}
```

Rules:

- Hub owns record.
- Bridge runs actual process.
- Instance belongs to same owner as Agent and Bridge.
- The instance is a restartable session: stopping ends the process but keeps the record; restarting reuses the same `agent_instance_id` and produces a new process on the same pinned `bridge_id`.
- Every instance has exactly one immutable `chain_id` and exactly one 1:1 `conversation_id`. If a start request supplies `chain_id`, the instance is hydrated into that existing chain. If no `chain_id` is supplied, the Hub creates a private/default task chain for the instance in the same transaction. The instance can never move chains.
- The `agent_instance_id` is stable across restarts AND across provider/tier changes. Task chains reference instances by `agent_instance_id` (assignee/reviewer/coordinator); this id must never be forked by a runtime change, or those references would break.
- Launch parameters split into two mutability tiers:
  - Immutable session identity: `agent_id`, `bridge_id`, `chain_id`, `conversation_id`, `project_id`, `project_path`. Changing any of these means a different instance, not a reconfigure.
  - Mutable runtime tuning: `provider`, `tier`. These can be changed mid-session (e.g. mid-conversation). A change triggers a process restart on the same `agent_instance_id`; the record and all task-chain references are preserved.
- `bridge_id` is pinned for the life of the session. Because `project_path` is bridge-local, the session cannot relaunch on a different bridge; if the pinned bridge is offline the session cannot resume until it is back online.
- A provider/tier change is only valid to a combination supported by BOTH the pinned bridge's capabilities and the agent-bridge-support policy for (agent, bridge). The selectable range is the intersection of those two.
- `project_path` is a faithful launch snapshot and must not auto-update if `Project.default_path` or `ProjectBridgePath` changes later.
- Restart does NOT preserve in-process agent context. A restarted process is a fresh session with empty scrollback; continuity comes from replaying conversation history + bootstrap/memory into the new process, not from the stable id. The stable id preserves identity/attribution, not runtime memory.
- APIs and filters must use `runtime_status` for AgentInstance state, not overloaded `status`.
- Runtime status updates from the Bridge are applied only when the incoming `state_seq > last_applied_seq` (idempotent, ordered), and `state_seq`/`last_applied_seq` continue monotonically across restarts. Both coalesced edge events and the periodic heartbeat digest update this field, so a lost edge event self-corrects on the next heartbeat. See runtime protocol §7.4.

Lifecycle:

```text
create -> launching -> starting -> running -> stopping -> stopped
                                       ^                      |
                                       |     restart (same id, same bridge)
                                       +----------------------+

reconfigure(provider|tier): running -> stopping -> launching -> ... -> running
   (same agent_instance_id; new process uses new provider/tier; history replayed)
```

### 7.8 Project

```ts
Project {
  project_id: string
  owner_user_id: string
  name: string
  slug: string
  description?: string
  repo_url?: string
  vcs_kind?: "git" | "jj" | "none"
  default_path: string
  created_at: string
  updated_at: string
}
```

Rules:

- Project metadata is Hub/user-owned.
- `default_path` is mandatory.
- `default_path` is a fallback path; it may or may not be valid on every Bridge.
- If different machines use different paths, configure ProjectBridgePath overrides.

### 7.9 Project bridge path

```ts
ProjectBridgePath {
  project_id: string
  bridge_id: string
  owner_user_id: string
  path: string
  is_validated: boolean
  last_validated_at?: string
  validation_error?: string
  validation_details?: Record<string, unknown>
  created_at: string
  updated_at: string
}
```

Effective path resolution:

```text
effective_path(project_id, bridge_id):
  if ProjectBridgePath exists for project+bridge:
    use override path
  else:
    use Project.default_path
```

Validation checks performed by Bridge may include:

- path exists
- path is directory
- wrapper can access it
- expected VCS kind is present
- repo remote matches `project.repo_url` where possible

### 7.10 Task chain

Status uses **two orthogonal fields** rather than one flat enum (see 7.11 for the rationale). `publish_state` gates whether the chain definition is finalized; `status` is only meaningful once published.

```ts
TaskChain {
  chain_id: string
  owner_user_id: string
  kind: "private_conversation" | "team_work"
  title: string
  description?: string
  project_id?: string
  coordinator_agent_instance_id: string
  default_reviewer_refs: ReviewerRef[]
  publish_state: "draft" | "published"
  status: "active" | "completed" | "cancelled"   // only meaningful when published
  task_counts: TaskCounts
  final_summary?: string
  quality_rating?: "good" | "bad"
  created_at: string
  updated_at: string
  published_at?: string
  completed_at?: string
}

ReviewerRef =
  | { type: "user", user_id: string }
  | { type: "agent_instance", agent_instance_id: string }
```

Rules:

- Tasks inherit ownership from parent TaskChain.
- A chain is created as `draft`. Publishing (`publish_state = published`) means the chain and its tasks are defined and ready to be worked. `status` starts `active` on publish.
- Chain `status` is intentionally minimal in v1: `active` while work proceeds, `completed` or `cancelled` when finished. There is no auto-progression; transitions are explicit operator/coordinator actions.
- The coordinator is a concrete `agent_instance_id`, not an `agent_id`. The coordinator instance is the default assignee for tasks that do not set an assignee override.
- Default reviewers are chain-level actor refs. Private conversation chains normally use the user as the default reviewer. Team chains may use the user and/or same-chain agent instances.
- Any `ReviewerRef` with `type = agent_instance` must refer to an instance whose immutable `chain_id` equals this chain. This prevents assigning a live unrelated conversation instance into the chain.
- The chain roster is derived from instances whose immutable `chain_id` equals the chain plus refs on the chain/tasks; no separate v1 roster/slot table is required.

```ts
TaskCounts {
  total: number
  draft: number
  assigned: number
  in_progress: number
  in_validation: number
  validated_good: number
  validated_not_good: number
  paused: number
  completed: number
  cancelled: number
}
```

All mutable durable resources in v1 must carry `updated_at`. A monotonically increasing `version: number` is post-v1 and should be added when optimistic concurrency is implemented for a concrete stale-write conflict case.

### 7.11 Task

A task's state has **two independent axes**, so it uses **two fields**, not one enum:

- `publish_state` (`draft` | `published`) — whether the task definition/content is finalized. Orthogonal to any work. A `draft` task has no meaningful execution status.
- `status` — the execution state, a single enum of mutually-exclusive values that only applies once `publish_state = published`.

Folding these into one flat enum would create impossible combinations (e.g. `draft` + `in_progress`) or force enumerating invalid cross-products. Keeping publication separate means `status` simply does not apply until the task is published.

```ts
Task {
  task_id: string
  chain_id: string
  owner_user_id: string          // = TaskChain.owner_user_id, immutable, set at insert
  title: string
  description?: string
  acceptance_criteria?: string[]
  assignee_ref?: AssigneeRef     // default = TaskChain.coordinator_agent_instance_id
  reviewer_refs?: ReviewerRef[]  // default = TaskChain.default_reviewer_refs
  depends_on_task_ids?: string[]
  publish_state: "draft" | "published"
  status:
    | "assigned"              // published, has an assignee, not yet started
    | "in_progress"           // assignee actively working
    | "in_validation"         // handed to reviewer
    | "validated_good"        // reviewer approved
    | "validated_not_good"    // reviewer rejected; goes back to in_progress on rework
    | "paused"                // halted, does NOT unblock dependents
    | "completed"             // terminal, unblocks dependents
    | "cancelled"             // terminal, unblocks dependents
  created_at: string
  updated_at: string
  published_at?: string
  started_at?: string
  completed_at?: string
}

AssigneeRef =
  | { type: "agent_instance", agent_instance_id: string }
  | { type: "user", user_id: string }
```

Effective assignment:

```text
effective_assignee(task) = task.assignee_ref
  ?? { type: "agent_instance", agent_instance_id: task.chain.coordinator_agent_instance_id }

effective_reviewers(task) = task.reviewer_refs
  ?? task.chain.default_reviewer_refs
```

Execution transitions (all explicit; no auto-promotion in v1):

```text
(draft) --publish--> assigned
assigned      -> in_progress
in_progress   -> in_validation
in_validation -> validated_good | validated_not_good
validated_not_good -> in_progress            (rework)
validated_good     -> completed              (coordinator gate)
any active state   -> paused | cancelled
paused             -> in_progress | cancelled
```

Dependency unblocking is **derived, not stored**, via one centralized helper (invariant 27):

```text
unblocks_dependents(status) = status in { completed, cancelled }
# paused and all active states do NOT unblock dependents
```

Rules:

- Authorization is checked through `TaskChain.owner_user_id` (and the task's own immutable `owner_user_id` copy for flat listing/RLS).
- Any task `assignee_ref` or `reviewer_refs` override must be a user ref for the chain owner or an `agent_instance` ref whose immutable `chain_id` equals the task's `chain_id`. Tasks cannot assign an unrelated live instance from another conversation/chain.
- If no assignee override is set, the chain coordinator instance is the default assignee.
- If no reviewer override is set, the chain's `default_reviewer_refs` apply.
- There is no auto-assignment, no auto-promotion of the next task, and no scheduled/automatic nudges in v1. All assignment and status changes are explicit operator/agent actions.
- A task is only workable when `publish_state = published`; a `draft` task is not scheduled, assigned, or nudged.

### 7.12 Memory

```ts
Memory {
  memory_id: string
  owner_user_id: string
  agent_id?: string
  type: "fact" | "habit" | "episode" | "expertise" | "skill" | "template"
  status: "pending" | "active" | "archived" | "rejected"
  title: string
  body: string
  evidence?: string
  created_at: string
  updated_at: string
}
```

Rules:

- Memory belongs to user.
- Agent-targeted memory references a user-owned agent.
- No team-scoped memory in v1.
- No visibility in v1.
- User-created memory may be created directly as `active` or `pending` depending on UI policy.
- Instance/agent-proposed memory must be created as `pending`.
- Only the owning authenticated user may approve or reject pending memory.

### 7.13 Chat/conversation

**Invariant: every `AgentInstance` has exactly one `ChatConversation`, and vice versa (1:1).** There are no standalone instances. Whenever an instance is created — from the composer, from an explicit "Launch instance" on the Agent page, or by the system for task-chain work — a conversation is created to own it. The conversation is the user's chat window into that instance regardless of what work it does. This makes "chat with the coordinator" and "chat with an individual chain agent" fall out for free: their chain-work instances are conversation-backed.

A conversation is bound 1:1 to a durable agent **session** (`AgentInstance`), locked when the instance is created. Both `agent_id` (identity) and `agent_instance_id` (the session) are permanent for the conversation's life; the session is restartable (7.7) so the conversation continues by relaunching the same instance, not by repointing to a new one.

```ts
ChatConversation {
  conversation_id: string
  owner_user_id: string
  agent_id: string             // permanent identity binding, set at creation
  agent_instance_id: string    // permanent 1:1 session binding, set at creation
  project_id?: string          // locked launch param (may be empty for no project)
  chain_id: string             // same immutable chain as AgentInstance.chain_id
  title?: string               // UI may show instance id instead of title where useful
  unread_count: number
  last_message_preview?: string
  last_message_at?: string
  created_at: string
  updated_at: string
}
```

Rules:

- An instance and its conversation are created together; the conversation is never without an instance once bound. There are three creation triggers, all producing the same conversation+instance pair:
  - **First message (composer):** the New Conversation UI collects launch params (agent, project, advanced provider/tier); the first send creates a private/default task chain, then the instance + conversation bound to that chain.
  - **Explicit launch (Agent page):** the user configures launch params and clicks Launch; if no `chain_id` is supplied the Hub creates a private/default task chain, then starts the instance immediately into an empty but live conversation (no first message required). The user is dropped into that conversation to chat.
  - **System launch (task chain):** when the Hub hydrates a chain agent (coordinator, assignee, or reviewer) for an existing chain, it creates the agent's conversation bound to the same instance and existing `chain_id`. This conversation is the user's channel to that agent.
- `agent_id` + `agent_instance_id` + `chain_id` are set at creation and immutable thereafter; there is no change-agent operation and no move-chain operation.
- The conversation owns exactly one instance session for its whole life, and that instance belongs to exactly one task chain. Two conversations with the same `agent_id` get two separate sessions/chains unless they were explicitly hydrated into the same existing chain at creation.
- Continuing an idle conversation restarts the same `agent_instance_id` (same bridge); it does not create a new instance.
- The coordinator's conversation is the chain's coordinator instance conversation; "message coordinator" from the chain view opens it. Individual chain agents are chatted with via their own conversations the same way.
- `sender_agent_instance_id` on messages equals the conversation's instance, but still marks restart boundaries because the underlying process (and its in-memory context) changed even though the id did not.

```ts
ChatMessage {
  message_id: string
  conversation_id: string
  owner_user_id: string
  direction: "user_to_agent" | "agent_to_user" | "system"
  sender_agent_id?: string
  sender_agent_instance_id?: string
  body: string
  artifact_ids?: string[]
  created_at: string
  delivered_at?: string
  read_at?: string
}
```

Rules:

- Conversation and message ownership are single-owner.
- `ChatMessage.owner_user_id` must equal `ChatConversation.owner_user_id`.
- `agent_to_user` messages authored with an instance token derive owner from `AgentInstance.owner_user_id`.
- Cross-user chat and cross-user agent messaging are not part of v1.

### 7.14 Artifact

```ts
Artifact {
  artifact_id: string
  owner_user_id: string
  kind: "file" | "text" | "image" | "json" | "diff" | "other"
  name: string                 // human display label; free-form, non-unique
  description?: string         // optional longer note/context
  content_type?: string
  size_bytes?: number
  agent_id?: string
  agent_instance_id?: string
  chain_id?: string
  task_id?: string
  project_id?: string
  created_at: string
  updated_at: string
}
```

Rules:

- Artifact content access is scoped by `owner_user_id`.
- `name` is a human display label, independent of the underlying filename/content-type. It is free-form and non-unique; `artifact_id` is the identity.
- On agent-created artifacts, `name` defaults to the supplied filename when omitted; the owner can rename anytime.
- `description` is an optional longer human note shown in the Library and viewer.

---

## 7A. Persistence and data-access architecture

This section defines how durable state is stored and accessed. It is a hard requirement, not a preference. It implements invariants 23–27.

### 7A.1 All durable state in a relational database

- Every durable resource in Section 7 (users, bridges, enrollments, agents, agent bridge support, agent instances, projects, project bridge paths, task chains, tasks, task comments, memory, chat conversations/messages, artifacts metadata, templates, tokens) is stored in relational tables.
- No JSONL, no append-only text logs, no per-record files, no bespoke on-disk formats for durable product state.
- Artifact blob bytes may live in a blob store (filesystem or object storage) but their metadata and the blob location/handle live in the database.
- The only state allowed outside the database is ephemeral runtime projection: live WebSocket handles, in-memory connection/socket registries, and per-request context. These are rebuilt on restart and never treated as a source of truth.

### 7A.2 Engine independence (SQLite now, PostgreSQL later)

SQLite is the v1 engine, but it must not be deeply integrated. The design goal is that replacing SQLite with PostgreSQL is a data-access-layer change with no impact on services, handlers, or contracts.

Rules:

- Only the repository layer imports or references the database driver.
- No SQLite-specific types, pragmas, or file-path semantics leak above the repository layer.
- Prefer portable SQL. Avoid SQLite-only constructs (e.g. dynamic typing reliance, `AUTOINCREMENT` semantics, `INSERT OR REPLACE`-style upserts) unless wrapped behind a repository method whose contract is engine-neutral.
- Represent types portably: use explicit column types that map cleanly to both engines (timestamps as ISO-8601 text or a defined timestamp type, booleans as an agreed representation, IDs as text).
- Schema is defined and evolved through ordered, engine-neutral migration files, not ad hoc `CREATE TABLE` calls scattered across stores.
- Transactions are expressed through a repository/unit-of-work abstraction, not raw engine calls in services.
- Connection acquisition is abstracted so a single SQLite connection/pool can be replaced by a PostgreSQL pool without touching call sites.

### 7A.3 Layering and separation of concerns

Three explicit layers, each with a single responsibility:

```text
Transport layer   (HTTP handlers, WS handlers)
  - parse/validate requests, authn/authz context, serialize responses
  - NO SQL, NO business rules

Service layer     (business logic per resource/domain)
  - ownership checks, state transitions, validation, orchestration
  - NO SQL, NO transport concerns

Repository layer  (persistence per resource)
  - CRUD/query methods with engine-neutral signatures
  - owns SQL and the DB driver
  - NO business rules
```

Rules:

- A handler calls a service; a service calls one or more repositories.
- Repositories expose intent-revealing methods (e.g. `agents.Create`, `agents.ListByOwner`, `agents.SetState`), not generic "run this SQL".
- Contracts/DTOs at the transport boundary are separate from persistence row structs; repositories map between them.

### 7A.4 No singletons; explicit dependency injection

- No package-level mutable globals for stores, services, connections, config, or caches.
- Construct dependencies once in a composition root at startup (DB connection/pool → repositories → services → handlers) and pass them explicitly.
- Anything a component needs is received via its constructor/params, making dependencies testable and replaceable (e.g. inject a fake repository in tests).

### 7A.5 Centralized, non-scattered state mutation

- Each durable resource has exactly one owning service/repository responsible for its writes.
- All mutations for a resource funnel through that owner; no other module issues writes to that resource's tables.
- Denormalized `owner_user_id` and derived counters are maintained inside the owning service so consistency rules (invariant 17) live in one place.
- State transitions (e.g. task status, instance runtime_status, memory status) are implemented as explicit methods on the owning service, not as inline updates spread across handlers.
- Cross-resource mutations that must be atomic run in a single transaction coordinated by a service, using the repository/unit-of-work abstraction.

### 7A.6 Testability expectations

- Services are unit-testable with in-memory/fake repositories, no database required.
- Repositories are integration-tested against the real engine.
- Because the engine sits behind the repository interface, the same service tests remain valid when the engine changes from SQLite to PostgreSQL.

---

## 8. REST API conventions


### 8.1 Base path

All new APIs should be versioned:

```http
/api/v1
```

All UI/CLI/Bridge code targets `/api/v1`. This is a green-field rewrite; there are no legacy routes to keep.

Action endpoint convention:

```text
POST /api/v1/{resources}/{id}/{action}
```

Use action endpoints for non-CRUD transitions such as `revoke`, `rotate-token`, `complete`, `stop`, `validate`, `read`, `archive`, `approve`, and `reject`. The main exception is the collection action `POST /api/v1/bridges/enroll`, which has no resource ID because it is authenticated by a one-time enrollment token.

V1-minimal API conventions:

- versioned `/api/v1` base path
- success/list/error envelopes
- cursor pagination
- basic filters/sort/search
- whitelisted expansions limited to `instances`, `bridge_support`, `bridge_paths`, and `tasks`

Post-v1 API conventions:

- sparse fields
- ETag/`If-None-Match`
- optimistic concurrency with `version`/`If-Match`
- batch lookup

Idempotency convention:

- `POST /api/v1/agent-instances` must support `Idempotency-Key` because it creates an instance and sends a Bridge command.
- Async command endpoints that can be double-submitted by the SPA, such as project path validation, should support `Idempotency-Key`.
- Idempotency keys are scoped to the authenticated principal, method, and path.
- Reusing a key with the same request returns the original response.
- Reusing a key with a different request returns `409 conflict`.

Example:

```http
POST /api/v1/agent-instances
Idempotency-Key: 018f7c2a-bridge-launch-click-1
```

### 8.2 Success envelope

```json
{
  "data": {},
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

### 8.3 List envelope

```json
{
  "data": [],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

### 8.4 Error envelope

```json
{
  "error": {
    "code": "forbidden",
    "message": "You do not have access to this resource",
    "details": {}
  },
  "meta": {
    "request_id": "req_123"
  }
}
```

Common error codes:

| Code | Meaning |
|---|---|
| `unauthenticated` | No valid auth context. |
| `forbidden` | Authenticated but operation is forbidden for this principal; owner-scoped resource misses should normally return `not_found`. |
| `not_found` | Resource does not exist or is not owned by caller. |
| `validation_failed` | Request body/query validation failed. |
| `conflict` | Version conflict, duplicate slug, invalid state transition. |
| `bridge_offline` | Requested Bridge is offline. |
| `bridge_revoked` | Bridge token/record revoked. |
| `provider_unavailable` | Bridge does not support requested provider/tier. |
| `instance_not_running` | Runtime action requires running instance. |
| `rate_limited` | Caller hit a rate limit. |
| `internal_error` | Unexpected server error. |

Cross-user disclosure policy:

- For owner-scoped resources, if the resource does not belong to the caller, return `404 not_found` instead of `403 forbidden`.
- Use `403 forbidden` for authenticated principals that are known but not allowed to perform the operation category, such as a Bridge token calling a user-management endpoint.
- This avoids leaking whether another user's resource ID exists.

### 8.5 HTTP status mapping

Recommended mapping:

| Status | Use |
|---|---|
| 200 | Successful read/update/action. |
| 201 | Resource created. |
| 202 | Async command accepted. |
| 204 | Delete/no-body success. |
| 304 | ETag not modified. |
| 400 | Validation error. |
| 401 | Unauthenticated. |
| 403 | Forbidden. |
| 404 | Not found or intentionally hidden. |
| 409 | Conflict/state/version issue. |
| 422 | Semantically invalid request. |
| 429 | Rate limited. |
| 500 | Internal error. |
| 503 | Bridge/provider temporarily unavailable. |

### 8.6 Pagination

All growing list endpoints support cursor pagination:

```http
?limit=50&cursor=...
```

Rules:

- default `limit = 50`
- max `limit = 200`
- stable cursor pagination preferred over offset
- sort order must be stable and deterministic
- cursors are opaque to clients

List response:

```json
{
  "data": [],
  "page": {
    "limit": 50,
    "next_cursor": "cursor_abc",
    "has_more": true
  }
}
```

### 8.7 Filtering

Use simple query parameters for common filters:

```http
GET /api/v1/agents?q=backend
GET /api/v1/bridges?status=online
GET /api/v1/task-chains?status=active
GET /api/v1/agent-instances?agent_id=agt_123&bridge_id=brg_123
```

Multi-value filters use repeated query parameters:

```http
GET /api/v1/task-chains?status=active&status=blocked
```

Comma-separated multi-values are not part of the target v1 API. If a legacy parser temporarily accepts comma-separated values, it should normalize them internally and the public contract should still document repeated parameters only.

### 8.8 Sorting

Sort syntax:

```http
?sort=-updated_at
?sort=name
?sort=status,-updated_at
```

Rules:

- `field` means ascending
- `-field` means descending
- fields must be whitelisted per endpoint
- if sort omitted, use endpoint-specific default, usually `-updated_at`

### 8.9 Search

Use:

```http
?q=search text
```

Search should be bounded and appropriate for list summaries. Avoid returning huge full-text matches by default.

### 8.10 Sparse fields

Sparse fields are post-v1. V1 should ship compact list responses and explicit detail endpoints first. When added, use:

```http
?fields=agent_id,name,updated_at
```

Rules:

- Optional optimization for large list/table UIs.
- Unknown fields should return `validation_failed`.
- Required identity fields may still be included by server.

### 8.11 Expansions


Use:

```http
?expand=instances,bridge_support
```

Rules:

- Default responses stay compact.
- Detail pages request related data explicitly.
- Avoid `expand=everything`.
- Expansions must be whitelisted per endpoint.
- V1 expansions are limited to `instances`, `bridge_support`, `bridge_paths`, and `tasks`.

### 8.12 Resource versioning

Optimistic concurrency with mutable-resource `version` and `If-Match` is post-v1. V1 keeps `updated_at` on mutable resources and may add `version` later when a concrete stale-write conflict case needs it.

When added, mutable resources should include:

```json
{
  "version": 12,
  "updated_at": "2026-07-22T10:00:00Z"
}
```

This supports:

- optimistic UI updates
- stale write detection
- WebSocket invalidation
- ETag generation

Optional update precondition:

```http
If-Match: "resource-version"
```

Conflict response:

```json
{
  "error": {
    "code": "conflict",
    "message": "Resource version changed",
    "details": {
      "current_version": 13
    }
  }
}
```

### 8.13 ETag support

ETag / `If-None-Match` support is post-v1. V1 should rely on compact list responses, cursor pagination, and WebSocket invalidation first.

When added, cacheable GETs can use:

```http
ETag: "chains-tanmay-v42"
```

Client can send:

```http
If-None-Match: "chains-tanmay-v42"
```

Server returns:

```http
304 Not Modified
```

This is post-v1 and should not block the first Hub/Bridge cutover.

Delete/archive convention:

- Reserve `DELETE` for true removal or cancellation where the resource is no longer active and the response can be `204 No Content`.
- Use action endpoints for soft-state transitions.
- Agent soft archive is `POST /api/v1/agents/{agent_id}/archive`, not `DELETE /agents/{agent_id}`.
- Memory archive remains `POST /api/v1/memories/{memory_id}/archive`.

---

## 9. User API

### 9.1 Get current user

```http
GET /api/v1/me
```

Auth:

- trusted proxy browser auth
- or user bearer token

Response:

```json
{
  "data": {
    "user_id": "tanmay",
    "name": "tanmay",
    "display_name": "Tanmay Vijay",
    "email": "tanmay@example.com"
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

### 9.2 Get logout URL

```http
GET /api/v1/me/logout-url
```

Response:

```json
{
  "data": {
    "logout_url": "https://auth.example.com/application/o/heimdall/end-session/"
  }
}
```

UI behavior:

- If user clicks logout, UI redirects to this URL.
- Heimdall does not own browser login/logout state.

---

## 10. Bridge management API

These APIs are user-facing and use authenticated user context.

### 10.1 List Bridges

```http
GET /api/v1/bridges?status=online&limit=50&cursor=...
```

Filters:

- `status`: `online`, `offline`, `revoked`
- `q`: label/hostname search

Sorts:

- `label`
- `machine_hostname`
- `status`
- `-last_seen_at`
- `-updated_at`

Response:

```json
{
  "data": [
    {
      "bridge_id": "brg_123",
      "label": "tanmay-macbook",
      "machine_hostname": "tanmay-macbook",
      "machine_os": "macos",
      "machine_arch": "arm64",
      "status": "online",
      "capabilities": [
        {
          "provider": "claude",
          "tiers": ["normal", "smart"],
          "default_tier": "normal"
        }
      ],
      "active_instance_count": 2,
      "last_seen_at": "2026-07-22T10:00:00Z",
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

### 10.2 Get Bridge detail

```http
GET /api/v1/bridges/{bridge_id}?expand=instances,project_paths
```

Expansions:

- `instances`: active/recent agent instances located on this Bridge
- `project_paths`: project path overrides on this Bridge

### 10.3 Create Bridge enrollment

```http
POST /api/v1/bridge-enrollments
```

Request:

```json
{
  "label": "Tanmay MacBook",
  "expires_in_seconds": 900
}
```

Notes:

- `label` is optional.
- If label is omitted, Hub uses Bridge-reported hostname during enrollment.
- `expires_in_seconds` should default to 900 and have a max such as 86400.

Response:

```json
{
  "data": {
    "enrollment_id": "enr_123",
    "expires_at": "2026-07-22T10:15:00Z",
    "setup_command": "ham-bridge enroll --hub https://heimdall.example.com",
    "enrollment_token": "hbe_secret_once"
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

Security:

- `enrollment_token` is returned once.
- Hub stores only token hash.
- UI should warn user to treat it as a secret.

### 10.4 List Bridge enrollments

```http
GET /api/v1/bridge-enrollments?status=pending&limit=50
```

Response should not include raw enrollment token.

```json
{
  "data": [
    {
      "enrollment_id": "enr_123",
      "label": "Tanmay MacBook",
      "expires_at": "2026-07-22T10:15:00Z",
      "consumed_at": null,
      "created_at": "2026-07-22T10:00:00Z"
    }
  ]
}
```

### 10.5 Revoke Bridge enrollment

```http
DELETE /api/v1/bridge-enrollments/{enrollment_id}
```

### 10.6 Enroll Bridge

This endpoint is called by `ham-bridge`, not browser UI.

```http
POST /api/v1/bridges/enroll
Authorization: Bearer hbe_secret_once
```

Request:

```json
{
  "machine": {
    "hostname": "tanmay-macbook",
    "os": "macos",
    "arch": "arm64"
  },
  "capabilities": [
    {
      "provider": "claude",
      "tiers": ["normal", "smart"],
      "default_tier": "normal"
    }
  ]
}
```

Response:

```json
{
  "data": {
    "bridge_id": "brg_123",
    "bridge_token": "hbr_secret",
    "hub_url": "https://heimdall.example.com"
  }
}
```

Validation:

- token exists
- token not expired
- token not consumed
- enrollment owner user exists and is active
- hostname is present

Bridge label assignment:

```text
if enrollment.label exists:
  bridge.label = enrollment.label
else:
  bridge.label = request.machine.hostname
```

### 10.7 Rename Bridge

```http
PATCH /api/v1/bridges/{bridge_id}
```

Request:

```json
{
  "label": "Work MacBook"
}
```

Response:

```json
{
  "data": {
    "bridge_id": "brg_123",
    "label": "Work MacBook",
    "label_is_user_customized": true,
    "machine_hostname": "tanmay-macbook"
  }
}
```

Handler rule: any successful `PATCH` that sets `label` must set `label_is_user_customized = true`, so later hostname reports do not overwrite the user-facing label.

### 10.8 Revoke Bridge

```http
POST /api/v1/bridges/{bridge_id}/revoke
```

Response:

```json
{
  "data": {
    "bridge_id": "brg_123",
    "status": "revoked",
    "revoked_at": "2026-07-22T10:00:00Z"
  }
}
```

Behavior:

- invalidate bridge token
- disconnect active Bridge WS
- mark bridge revoked/offline
- running instances should be marked unreachable or stopping depending on supervision policy

### 10.9 Rotate Bridge token


```http
POST /api/v1/bridges/{bridge_id}/rotate-token
```

Response:

```json
{
  "data": {
    "bridge_id": "brg_123",
    "bridge_token": "hbr_new_secret"
  }
}
```

Token shown once.

---

## 11. Agent API

### 11.1 List Agents

```http
GET /api/v1/agents?q=backend&limit=50&cursor=...&sort=name
```

Filters:

- `q`
- `state`: `active`, `archived`
- `provider`: default provider
- `tier`: default tier
- `bridge_id`: agents supported by Bridge

Sorts:

- `name`
- `slug`
- `-updated_at`
- `-created_at`

Compact response:

```json
{
  "data": [
    {
      "agent_id": "agt_123",
      "name": "Backend Agent",
      "slug": "backend-agent",
      "default_provider": "claude",
      "default_tier": "smart",
      "supported_bridge_count": 2,
      "active_instance_count": 1,
      "state": "active",
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  }
}
```

### 11.2 Create Agent

```http
POST /api/v1/agents
```

Request:

```json
{
  "name": "Backend Agent",
  "slug": "backend-agent",
  "template_id": "template_default",
  "default_provider": "claude",
  "default_tier": "smart",
  "instructions": "Focus on backend implementation and tests."
}
```

Response:

```json
{
  "data": {
    "agent_id": "agt_123",
    "name": "Backend Agent",
    "slug": "backend-agent",
    "state": "active"
  }
}
```

Validation:

- slug unique for authenticated user
- default provider/tier are allowed values if present
- template belongs to user or is system built-in if system templates are kept

### 11.3 Get Agent detail

```http
GET /api/v1/agents/{agent_id}?expand=bridge_support,instances,memory_summary
```

Default response:

```json
{
  "data": {
    "agent_id": "agt_123",
    "name": "Backend Agent",
    "slug": "backend-agent",
    "template_id": "template_default",
    "default_provider": "claude",
    "default_tier": "smart",
    "instructions": "Focus on backend implementation and tests.",
    "supported_bridge_count": 2,
    "active_instance_count": 1,
    "state": "active",
    "version": 7,
    "created_at": "2026-07-22T09:00:00Z",
    "updated_at": "2026-07-22T10:00:00Z"
  }
}
```

With `expand=bridge_support`:

```json
{
  "bridge_support": [
    {
      "bridge_id": "brg_123",
      "bridge_label": "tanmay-macbook",
      "bridge_status": "online",
      "enabled": true,
      "provider": "claude",
      "tier": "smart",
      "priority": 10,
      "max_instances": 2,
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ]
}
```

### 11.4 Update Agent

```http
PATCH /api/v1/agents/{agent_id}
```

Request:

```json
{
  "name": "Backend Agent",
  "default_provider": "claude",
  "default_tier": "normal",
  "instructions": "Updated instructions."
}
```

### 11.5 Archive Agent

Recommended v1 behavior: archive instead of hard delete.

```http
POST /api/v1/agents/{agent_id}/archive
```

Response:

```json
{
  "data": {
    "agent_id": "agt_123",
    "state": "archived"
  }
}
```

Hard delete is not part of the v1 user API for agents.

---

## 12. Agent bridge support API

### 12.1 List supported Bridges for Agent

```http
GET /api/v1/agents/{agent_id}/bridge-support
```

Response:

```json
{
  "data": [
    {
      "agent_id": "agt_123",
      "bridge_id": "brg_123",
      "bridge_label": "tanmay-macbook",
      "bridge_status": "online",
      "enabled": true,
      "provider": "claude",
      "tier": "smart",
      "priority": 10,
      "max_instances": 2,
      "bridge_capabilities": [
        {
          "provider": "claude",
          "tiers": ["normal", "smart"]
        }
      ],
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ]
}
```

### 12.2 Replace full support config

Useful for a UI save form.

```http
PUT /api/v1/agents/{agent_id}/bridge-support
```

Request:

```json
{
  "bridges": [
    {
      "bridge_id": "brg_123",
      "enabled": true,
      "provider": "claude",
      "tier": "smart",
      "priority": 10,
      "max_instances": 2
    },
    {
      "bridge_id": "brg_456",
      "enabled": false
    }
  ]
}
```

Validation:

- all bridge IDs are owned by authenticated user
- provider/tier must be supported by Bridge if provided
- priorities are numeric and bounded
- max_instances is positive if provided

### 12.3 Patch one support entry

Useful for toggles.

```http
PATCH /api/v1/agents/{agent_id}/bridge-support/{bridge_id}
```

Request:

```json
{
  "enabled": true,
  "provider": "claude",
  "tier": "normal"
}
```

### 12.4 Remove support entry

```http
DELETE /api/v1/agents/{agent_id}/bridge-support/{bridge_id}
```

Behavior:

- removes support record
- does not necessarily stop currently running instances unless policy says so

---

## 13. Agent instance API

### 13.1 List instances

```http
GET /api/v1/agent-instances?agent_id=agt_123&bridge_id=brg_123&runtime_status=running&limit=50
```

Filters:

- `agent_id`
- `bridge_id`
- `project_id`
- `runtime_status`
- `q` for agent/bridge labels if useful

Response:

```json
{
  "data": [
    {
      "agent_instance_id": "inst_123",
      "agent_id": "agt_123",
      "agent_name": "Backend Agent",
      "bridge_id": "brg_123",
      "bridge_label": "tanmay-macbook",
      "chain_id": "chain_123",
      "conversation_id": "conv_123",
      "provider": "claude",
      "tier": "smart",
      "project_id": "proj_123",
      "runtime_status": "running",
      "startup_status": "ready",
      "activity_status": "idle",
      "last_seen_at": "2026-07-22T10:00:00Z",
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  }
}
```

### 13.2 Start instance

Use one canonical endpoint. Avoid duplicate start actions under Agents or Bridges.

```http
POST /api/v1/agent-instances
Idempotency-Key: <required-for-user-initiated-start>
```

`Idempotency-Key` is required for UI/user-initiated starts and strongly recommended for CLI starts, because this endpoint creates a durable instance and sends a launch command.

Explicit Bridge request, creating a new private/default chain because `chain_id` is omitted:

```json
{
  "agent_id": "agt_123",
  "bridge_id": "brg_123",
  "provider": "claude",
  "tier": "smart",
  "project_id": "proj_123",
  "chain": {
    "kind": "private_conversation",
    "title": "Backend Agent session",
    "default_reviewer_refs": [
      { "type": "user", "user_id": "usr_123" }
    ]
  }
}
```

Hydrate into an existing task chain:

```json
{
  "agent_id": "agt_reviewer",
  "bridge_id": "brg_123",
  "chain_id": "chain_123",
  "provider": "claude",
  "tier": "normal",
  "project_id": "proj_123"
}
```

Hub-selected Bridge request:

```json
{
  "agent_id": "agt_123",
  "project_id": "proj_123"
}
```

If `chain_id` is omitted, the Hub creates a private/default `TaskChain` in the same transaction as the `AgentInstance` and `ChatConversation`. If `chain_id` is supplied, the instance is hydrated into that existing chain. In both cases the response includes both ids.

Validation:

1. authenticated user owns Agent
2. authenticated user owns Bridge if supplied
3. Agent supports Bridge
4. Bridge is online
5. Bridge supports provider/tier
6. Project belongs to user if supplied
7. Project effective path resolves for Bridge
8. If `chain_id` is supplied, chain belongs to user and is not terminal/archived
9. If `chain_id` is omitted, optional `chain.default_reviewer_refs` are valid refs for the user (agent-instance refs are not allowed because no chain exists yet; default to the user if omitted)
10. Bridge has capacity if capacity limits are enforced

Provider/tier resolution:

```text
request override
  > agent bridge-support override
  > agent default provider/tier
  > bridge provider default
```

Bridge selection if `bridge_id` omitted:

1. consider enabled AgentBridgeSupport rows
2. filter online Bridges
3. filter provider/tier capability match
4. filter capacity
5. sort by priority descending
6. tie-break by least active instances or stable created_at

Response:

```json
{
  "data": {
    "agent_instance_id": "inst_123",
    "agent_id": "agt_123",
    "bridge_id": "brg_123",
    "chain_id": "chain_123",
    "conversation_id": "conv_123",
    "provider": "claude",
    "tier": "smart",
    "project_id": "proj_123",
    "runtime_status": "launching"
  }
}
```

HTTP status:

- `201 Created` if chain/instance/conversation records were created and launch command queued/sent
- `202 Accepted` if async launch command accepted but not started
- repeat request with same `Idempotency-Key` returns the original response

### 13.3 Get instance detail

```http
GET /api/v1/agent-instances/{instance_id}
```

### 13.4 Stop instance

```http
POST /api/v1/agent-instances/{instance_id}/stop
```

Request:

```json
{
  "reason": "user_requested"
}
```

Behavior:

- Hub validates ownership.
- Hub sends stop command to Bridge.
- Instance moves to `stopping` then `stopped`, or `failed` on error.
- Stop keeps the durable instance record (restartable session); it does not delete the instance.

### 13.5 Restart instance

Relaunch a stopped/idle session on the same pinned bridge, reusing the same `agent_instance_id` and launch params.

```http
POST /api/v1/agent-instances/{instance_id}/restart
```

Request: empty body.

Response (`202 Accepted`):

```json
{
  "data": {
    "agent_instance_id": "inst_123",
    "agent_id": "agt_123",
    "bridge_id": "brg_123",
    "chain_id": "chain_123",
    "conversation_id": "conv_123",
    "provider": "claude",
    "tier": "smart",
    "project_id": "proj_123",
    "runtime_status": "launching",
    "run_count": 2,
    "last_applied_seq": 41
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

Behavior:

- Same `agent_instance_id`, same `bridge_id`, same immutable `chain_id`/`conversation_id`, same `provider`/`tier`/`project`.
- New process; `run_count` increments; `state_seq` continues monotonically.
- Fails with `409 bridge_offline` if the pinned bridge is unavailable.
- Continuity is via history/bootstrap replay, not in-process memory.

Error (`409 conflict`, pinned bridge offline):

```json
{
  "error": {
    "code": "bridge_offline",
    "message": "Pinned bridge brg_123 is offline; the session cannot resume until it reconnects"
  },
  "meta": { "request_id": "req_123" }
}
```

### 13.6 Reconfigure instance (change provider/tier)

Change the runtime tuning of an existing session mid-life (e.g. mid-conversation) while preserving `agent_instance_id`. This is the only mutation to a running instance's launch params; `agent_id`, `bridge_id`, and `project` are immutable.

```http
PATCH /api/v1/agent-instances/{instance_id}
```

Request:

```json
{
  "provider": "claude",
  "tier": "normal"
}
```

Validation:

- `provider`/`tier` must be in the intersection of the pinned bridge's capabilities and the agent-bridge-support policy for (agent, bridge).
- Attempts to change `agent_id`, `bridge_id`, or `project_id` are rejected with `409 conflict` (those define a different instance).

Behavior:

- If running: Hub restarts the process on the same `agent_instance_id` with the new provider/tier (`running -> stopping -> launching -> running`); conversation history is replayed for continuity.
- If stopped: the new provider/tier is stored and applied on next start/restart.
- All task-chain references to this `agent_instance_id` are unaffected.

Response (`200 OK`):

```json
{
  "data": {
    "agent_instance_id": "inst_123",
    "agent_id": "agt_123",
    "bridge_id": "brg_123",
    "provider": "claude",
    "tier": "normal",
    "project_id": "proj_123",
    "runtime_status": "launching",
    "run_count": 3
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

Error (`409 conflict`, attempt to change an immutable field):

```json
{
  "error": {
    "code": "conflict",
    "message": "agent_id, bridge_id, and project_id are immutable for an instance; changing them requires a new instance"
  },
  "meta": { "request_id": "req_123" }
}
```

Error (`422 provider_unavailable`, provider/tier not offered by the pinned bridge / support policy):

```json
{
  "error": {
    "code": "provider_unavailable",
    "message": "tier 'normal' for provider 'claude' is not available on bridge brg_123 under this agent's support policy"
  },
  "meta": { "request_id": "req_123" }
}
```

---

## 14. Project API

### 14.1 List Projects

```http
GET /api/v1/projects?q=heimdall&sort=-updated_at&limit=50
```

Filters:

- `q`
- `vcs_kind`

Sorts:

- `name`
- `slug`
- `-updated_at`
- `-created_at`

Compact response:

```json
{
  "data": [
    {
      "project_id": "proj_123",
      "name": "Heimdall",
      "slug": "heimdall",
      "repo_url": "https://github.com/example/heimdall",
      "vcs_kind": "git",
      "default_path": "/Users/tanmayvijay/heimdall-agent-manager",
      "bridge_path_count": 1,
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  }
}
```

### 14.2 Create Project

```http
POST /api/v1/projects
```

Request:

```json
{
  "name": "Heimdall",
  "slug": "heimdall",
  "description": "Agent manager",
  "repo_url": "https://github.com/example/heimdall",
  "vcs_kind": "git",
  "default_path": "/Users/tanmayvijay/heimdall-agent-manager"
}
```

Validation:

- `default_path` required
- slug unique per user
- `vcs_kind` valid

### 14.3 Get Project detail

```http
GET /api/v1/projects/{project_id}?expand=bridge_paths
```

With `expand=bridge_paths`:

```json
{
  "data": {
    "project_id": "proj_123",
    "name": "Heimdall",
    "default_path": "/Users/tanmayvijay/heimdall-agent-manager",
    "bridge_paths": [
      {
        "bridge_id": "brg_123",
        "bridge_label": "tanmay-macbook",
        "path": "/Users/tanmayvijay/heimdall-agent-manager",
        "is_validated": true,
        "last_validated_at": "2026-07-22T10:00:00Z",
        "validation_error": null
      },
      {
        "bridge_id": "brg_456",
        "bridge_label": "linuxbox",
        "path": "/home/tanmay/src/heimdall-agent-manager",
        "is_validated": false,
        "last_validated_at": null,
        "validation_error": null
      }
    ]
  }
}
```

### 14.4 Update Project

```http
PATCH /api/v1/projects/{project_id}
```

Request:

```json
{
  "name": "Heimdall Agent Manager",
  "default_path": "/Users/tanmayvijay/heimdall-agent-manager"
}
```

### 14.5 Set Bridge path override

```http
PUT /api/v1/projects/{project_id}/bridge-paths/{bridge_id}
```

Request:

```json
{
  "path": "/home/tanmay/src/heimdall-agent-manager"
}
```

Response:

```json
{
  "data": {
    "project_id": "proj_123",
    "bridge_id": "brg_456",
    "path": "/home/tanmay/src/heimdall-agent-manager",
    "is_validated": false,
    "validation_error": null
  }
}
```

### 14.6 Delete Bridge path override

```http
DELETE /api/v1/projects/{project_id}/bridge-paths/{bridge_id}
```

Behavior:

- effective path falls back to Project.default_path

### 14.7 Validate Project path on Bridge

```http
POST /api/v1/projects/{project_id}/bridge-paths/{bridge_id}/validate
```

Behavior:

1. Hub validates user owns Project and Bridge.
2. Hub resolves effective path.
3. Hub sends validation command to Bridge.
4. Bridge checks filesystem/VCS.
5. Hub stores validation result.

Immediate response may be synchronous if command completes quickly:

```json
{
  "data": {
    "project_id": "proj_123",
    "bridge_id": "brg_456",
    "path": "/home/tanmay/src/heimdall-agent-manager",
    "is_validated": true,
    "validation_error": null,
    "validation_details": {
      "vcs_kind": "git",
      "current_branch": "main"
    }
  }
}
```

If async:

```json
{
  "data": {
    "command_id": "cmd_123",
    "status": "queued"
  }
}
```

---

## 15. Task chain API

### 15.1 List Task Chains

```http
GET /api/v1/task-chains?status=active&q=bridge&project_id=proj_123&sort=-updated_at&limit=50
```

Filters:

- `publish_state` (`draft` | `published`)
- `status`
- `project_id`
- `coordinator_agent_instance_id`
- `kind` (`private_conversation` | `team_work`)
- `q`

Sorts:

- `title`
- `status`
- `-updated_at`
- `-created_at`

Compact response:

```json
{
  "data": [
    {
      "chain_id": "chain_123",
      "title": "Bridge Migration",
      "publish_state": "published",
      "status": "active",
      "kind": "team_work",
      "project_id": "proj_123",
      "project_name": "Heimdall",
      "coordinator_agent_instance_id": "inst_coord",
      "default_reviewer_refs": [
        { "type": "user", "user_id": "usr_123" },
        { "type": "agent_instance", "agent_instance_id": "inst_reviewer" }
      ],
      "task_counts": {
        "total": 8,
        "draft": 0,
        "assigned": 2,
        "in_progress": 1,
        "in_validation": 1,
        "validated_good": 0,
        "validated_not_good": 0,
        "paused": 0,
        "completed": 4,
        "cancelled": 0
      },
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": "cursor_abc",
    "has_more": true
  }
}
```

### 15.2 Create Task Chain

```http
POST /api/v1/task-chains
```

Request:

```json
{
  "title": "Bridge Migration",
  "description": "Move Heimdall to Hub/Bridge model",
  "kind": "team_work",
  "project_id": "proj_123",
  "coordinator_agent_id": "agt_coord",
  "default_reviewer_refs": [
    { "type": "user", "user_id": "usr_123" }
  ]
}
```

Behavior:

- This is a convenience endpoint for team-chain creation. The request names a coordinator `agent_id`; the Hub hydrates a new coordinator `AgentInstance` for the new chain, creates the 1:1 coordinator `ChatConversation`, then stores `coordinator_agent_instance_id` on the chain.
- The stored TaskChain references concrete instance ids only; the request uses `coordinator_agent_id` because no coordinator instance exists before creation.
- For private/default conversation chains, callers normally use `POST /api/v1/agent-instances` without `chain_id` instead of this endpoint.

Response (`201 Created`):

```json
{
  "data": {
    "chain_id": "chain_123",
    "kind": "team_work",
    "title": "Bridge Migration",
    "project_id": "proj_123",
    "coordinator_agent_instance_id": "inst_coord",
    "coordinator_conversation_id": "conv_coord",
    "default_reviewer_refs": [
      { "type": "user", "user_id": "usr_123" }
    ],
    "publish_state": "draft",
    "status": "active"
  }
}
```

Validation:

- project belongs to user if provided
- coordinator agent belongs to user and has enabled bridge support
- default reviewer refs are either the owning user or agent instances already in this new chain (usually only user at create time; add chain instances first if an agent reviewer is needed)

### 15.3 Get Task Chain detail

```http
GET /api/v1/task-chains/{chain_id}?expand=tasks,graph
```

Default detail includes chain metadata and counts. Tasks require `expand=tasks`. The dependency graph + canonical order require `expand=graph`.

### 15.3a Chain dependency graph and canonical task order

The chain's task ordering is a **backend-owned, single-source concept**. The Hub derives it from the tasks' `depends_on` edges and exposes it so that:

- the UI renders the dependency graph and execution order from it, and
- next-task selection for a freed-up assignee walks the **same** order.

The UI never computes its own ordering; the backend never picks "next" by a different rule. They read the same structure, so the graph can never disagree with what actually runs next.

The Hub computes two things from the `depends_on` DAG:

1. **Transitive reduction** (minimal edges): redundant edges implied by transitivity are removed. If `A -> B -> C` and also `A -> C`, the `A -> C` edge is dropped. The graph shows only the minimal edge set so dependency structure reads cleanly.
2. **Canonical order**: a deterministic topological sort of the DAG, tie-broken by (a) explicit `priority`, then (b) `created_at`. This linearization is the single source of truth for "in which order tasks are worked."

`expand=graph` response shape:

```json
{
  "graph": {
    "nodes": [
      {
        "task_id": "task_1",
        "order_rank": 0,
        "depth": 0,
        "publish_state": "published",
        "status": "completed",
        "assignee_ref": { "type": "agent_instance", "agent_instance_id": "inst_coder" },
        "unblocked": true
      },
      {
        "task_id": "task_7",
        "order_rank": 6,
        "depth": 3,
        "publish_state": "published",
        "status": "in_progress",
        "assignee_ref": { "type": "agent_instance", "agent_instance_id": "inst_coder" },
        "unblocked": true
      }
    ],
    "edges": [
      { "from": "task_1", "to": "task_2" }
    ],
    "is_dag": true
  }
}
```

Field meaning:

- `order_rank` — position in the canonical linearization (0-based). Deterministic and stable for a given DAG + priorities.
- `depth` — longest-path distance from a root; used for top-to-bottom graph layout "levels."
- `edges` — the transitively reduced (minimal) dependency edges.
- `unblocked` — all dependencies are `completed`/`cancelled` (per the unblock rule in 20b); the set of `unblocked` + not-yet-started tasks is the runnable frontier.
- `is_dag` — false if a cycle is detected; creating a dependency that would form a cycle is rejected at task create/update with `409 conflict`.

Next-task selection rule (used when an assignee instance becomes free): among tasks whose effective assignee is that same-chain `agent_instance_id`, and that are `published`, `unblocked`, and not yet started, pick the one with the lowest `order_rank`. This is the same order the graph shows.

### 15.4 Update Task Chain

```http
PATCH /api/v1/task-chains/{chain_id}
```

### 15.4a Publish Task Chain

A chain is created as `draft`. Publishing finalizes the chain and its tasks and sets `status = active`.

```http
POST /api/v1/task-chains/{chain_id}/publish
```

Response:

```json
{
  "data": {
    "chain_id": "chain_123",
    "publish_state": "published",
    "status": "active"
  }
}
```

### 15.5 Complete Task Chain

```http
POST /api/v1/task-chains/{chain_id}/complete
```

Request:

```json
{
  "final_summary": "Implemented Hub/Bridge migration design and API plan. Evidence: ...",
  "quality_rating": "good"
}
```

Acceptance requirement for coordinator agents:

- final summary should include verifiable evidence, file paths, commits if applicable, and rationale.

---

## 16. Task API

Tasks are nested under task chains because ownership is inherited from the parent chain.

### 16.1 List Tasks in Chain

```http
GET /api/v1/task-chains/{chain_id}/tasks?status=in_progress&assignee_agent_instance_id=inst_coder&limit=100
```

Filters:

- `publish_state` (`draft` | `published`)
- `status`
- `assignee_agent_instance_id`
- `reviewer_agent_instance_id`
- `reviewer_user_id`
- `q`

Response:

```json
{
  "data": [
    {
      "task_id": "task_123",
      "chain_id": "chain_123",
      "title": "Implement bridge enrollment",
      "publish_state": "published",
      "status": "in_progress",
      "assignee_ref": { "type": "agent_instance", "agent_instance_id": "inst_backend" },
      "assignee_agent_name": "Backend Agent",
      "reviewer_refs": [
        { "type": "user", "user_id": "usr_123" },
        { "type": "agent_instance", "agent_instance_id": "inst_reviewer" }
      ],
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 100,
    "next_cursor": null,
    "has_more": false
  }
}
```

### 16.2 Create Task

```http
POST /api/v1/task-chains/{chain_id}/tasks
```

Request:

```json
{
  "title": "Implement bridge enrollment",
  "description": "Add user-owned bridge enrollment API and store.",
  "acceptance_criteria": [
    "Enrollment token is one-time",
    "Bridge token is stored hashed",
    "Bridge label defaults to hostname"
  ],
  "assignee_ref": { "type": "agent_instance", "agent_instance_id": "inst_backend" },
  "reviewer_refs": [
    { "type": "user", "user_id": "usr_123" }
  ]
}
```

If `assignee_ref` is omitted, the task uses the chain coordinator instance. If `reviewer_refs` is omitted, the task uses the chain's default reviewers. Any agent-instance ref must belong to the same chain.

### 16.3 Update Task

```http
PATCH /api/v1/task-chains/{chain_id}/tasks/{task_id}
```

Edits task definition/content (title, description, acceptance criteria, assignee, reviewer, dependencies). Allowed while `draft`; content edits on a `published` task are limited to metadata that does not invalidate in-flight work.

### 16.3a Publish Task

Finalizes the task content and moves it from `draft` into the execution axis at `status = assigned` (or the first workable state). A task may omit assignee/reviewer fields because the chain coordinator/default reviewers apply, but explicit overrides must validate before publish.

```http
POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/publish
```

Response:

```json
{
  "data": {
    "task_id": "task_123",
    "publish_state": "published",
    "status": "assigned"
  }
}
```

### 16.4 Change Task status

Execution transitions only; valid on `published` tasks. The service validates the transition against the state machine in 7.11 and rejects invalid ones with `409 conflict`.

```http
POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/status
```

Request:

```json
{
  "status": "in_validation",
  "comment": "Implementation complete. Tests pass."
}
```

Valid target values: `assigned`, `in_progress`, `in_validation`, `validated_good`, `validated_not_good`, `paused`, `completed`, `cancelled`. Only `completed` and `cancelled` unblock dependent tasks.

### 16.4a Nudge Task

Manual nudge, triggerable by an agent or by a user from the UI. There is no automatic/scheduled nudging in v1. A nudge notifies the relevant party (assignee for active work, reviewer when `in_validation`) via the notification/WS path; it does not change task status.

```http
POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/nudge
```

Request:

```json
{
  "message": "Any update on this? Reviewer is waiting."
}
```

Response:

```json
{
  "data": {
    "task_id": "task_123",
    "nudged": true,
    "notified_refs": [
      { "type": "agent_instance", "agent_instance_id": "inst_backend" }
    ]
  }
}
```

### 16.5 Task comments

```http
GET /api/v1/task-chains/{chain_id}/tasks/{task_id}/comments?limit=50&cursor=...
POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/comments
```

Comments should be paginated.

---

## 17. Memory API

### 17.1 List Memories

```http
GET /api/v1/memories?agent_id=agt_123&type=fact&status=active&q=python&limit=50
```

Filters:

- `agent_id`
- `type`
- `status`
- `q`

Response:

```json
{
  "data": [
    {
      "memory_id": "mem_123",
      "agent_id": "agt_123",
      "type": "fact",
      "status": "active",
      "title": "Prefers concise summaries",
      "body_preview": "User prefers concise summaries...",
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  }
}
```

### 17.2 Create Memory

```http
POST /api/v1/memories
```

Request:

```json
{
  "agent_id": "agt_123",
  "type": "fact",
  "title": "Prefers concise summaries",
  "body": "User prefers concise summaries in implementation plans.",
  "evidence": "Direct user feedback."
}
```

### 17.3 Get Memory

```http
GET /api/v1/memories/{memory_id}
```

### 17.4 Update Memory

```http
PATCH /api/v1/memories/{memory_id}
```

### 17.5 Approve Memory

Only the owning authenticated user may approve pending memory.

```http
POST /api/v1/memories/{memory_id}/approve
```

Response:

```json
{
  "data": {
    "memory_id": "mem_123",
    "status": "active"
  }
}
```

### 17.6 Reject Memory

Only the owning authenticated user may reject pending memory.

```http
POST /api/v1/memories/{memory_id}/reject
```

Request:

```json
{
  "reason": "Not useful enough to store."
}
```

Response:

```json
{
  "data": {
    "memory_id": "mem_123",
    "status": "rejected"
  }
}
```

### 17.7 Archive Memory

```http
POST /api/v1/memories/{memory_id}/archive
```

---

## 18. Chat API

Chat in v1 is only between an authenticated user and that user's own agents/instances. There is no cross-user chat and no agent-to-agent inbox API in the v1 target model.

### 18.1 List conversations

```http
GET /api/v1/chats?agent_id=agt_123&chain_id=chain_123&limit=50
```

Compact response:

```json
{
  "data": [
    {
      "conversation_id": "chat_123",
      "agent_id": "agt_123",
      "agent_name": "Backend Agent",
      "chain_id": "chain_123",
      "title": "Backend Agent",
      "unread_count": 2,
      "last_message_preview": "Done with implementation...",
      "last_message_at": "2026-07-22T10:00:00Z",
      "updated_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": null,
    "has_more": false
  }
}
```

### 18.2 Create conversation

Create or return a user-owned conversation with one of the user's agents. This is the canonical first-message path for direct user↔agent chat.

```http
POST /api/v1/chats
```

Request:

```json
{
  "agent_id": "agt_123",
  "agent_instance_id": "inst_123",
  "chain_id": "chain_123",
  "initial_message": {
    "body": "Please inspect the bridge enrollment flow.",
    "artifact_ids": []
  }
}
```

Rules:

- `agent_id` is required.
- `agent_instance_id` is optional; if omitted Hub may route to an active instance or schedule one according to normal agent/Bridge policy.
- `chain_id` is optional context.
- `initial_message` is optional; if present, Hub creates the first `user_to_agent` message atomically with the conversation.
- Hub may return an existing deterministic conversation for the same `(owner_user_id, agent_id, chain_id)` if product policy wants one thread per context.

### 18.3 Fetch messages

```http
GET /api/v1/chats/{conversation_id}/messages?limit=50&cursor=older_cursor
```

Message pagination uses opaque cursors only. A message cursor may internally encode "messages older than X", but clients must treat it as opaque. Do not fetch entire transcripts by default.

Response:

```json
{
  "data": [
    {
      "message_id": "msg_123",
      "conversation_id": "chat_123",
      "direction": "agent_to_user",
      "body": "Done.",
      "artifact_ids": [],
      "created_at": "2026-07-22T10:00:00Z"
    }
  ],
  "page": {
    "limit": 50,
    "next_cursor": "older_cursor",
    "has_more": true
  }
}
```

### 18.4 Send message

```http
POST /api/v1/chats/{conversation_id}/messages
```

Request:

```json
{
  "body": "Please continue.",
  "artifact_ids": ["art_123"]
}
```

Validation:

- conversation belongs to user
- artifact IDs belong to user

### 18.5 Mark read

```http
POST /api/v1/chats/{conversation_id}/read
```

Request:

```json
{
  "through_message_id": "msg_123"
}
```

---

## 19. Artifact API

### 19.1 List Artifacts

```http
GET /api/v1/artifacts?chain_id=chain_123&agent_id=agt_123&kind=file&limit=50
```

Filters:

- `chain_id`
- `task_id`
- `agent_id`
- `agent_instance_id`
- `project_id`
- `kind`
- `q`

### 19.2 Create/upload Artifact

```http
POST /api/v1/artifacts
```

Use multipart for file content where needed.

Metadata fields:

```json
{
  "kind": "file",
  "name": "Q3 Validation Report",
  "description": "Pass/fail matrix for the reporting-convergence tests",
  "chain_id": "chain_123",
  "task_id": "task_123",
  "agent_id": "agt_123"
}
```

### 19.3 Get Artifact metadata

```http
GET /api/v1/artifacts/{artifact_id}
```

### 19.4 Get Artifact content

```http
GET /api/v1/artifacts/{artifact_id}/content
```

Authorization:

- artifact owner must match authenticated user

### 19.5 Update Artifact (rename / edit description)

Edit human metadata. Content bytes are replaced via re-upload (see versioning), not here.

```http
PATCH /api/v1/artifacts/{artifact_id}
```

Request (any subset of the editable fields):

```json
{
  "name": "Q3 Validation Report (final)",
  "description": "Updated after reviewer feedback"
}
```

Response (`200 OK`):

```json
{
  "data": {
    "artifact_id": "art_123",
    "name": "Q3 Validation Report (final)",
    "description": "Updated after reviewer feedback",
    "kind": "markdown",
    "content_type": "text/markdown",
    "size_bytes": 4096,
    "updated_at": "2026-07-22T10:00:00Z"
  },
  "meta": {
    "request_id": "req_123",
    "server_time": "2026-07-22T10:00:00Z"
  }
}
```

### 19.6 Delete Artifact

```http
DELETE /api/v1/artifacts/{artifact_id}
```

Request: empty body.

Response: `204 No Content` (empty body).

Behavior:

- owner-scoped; returns `204` on success, `404 not_found` if not owned/absent.
- Deletes the artifact metadata and its blob content.
- References to the deleted `artifact_id` from chat messages/comments render as an unavailable/deleted placeholder rather than erroring.

---

## 20. Template API

Templates can be user-owned. If built-in/system templates remain, they should be handled as read-only system records, but without a general visibility model.

### 20.1 List Templates

```http
GET /api/v1/templates?q=reviewer&limit=50
```

### 20.2 Create Template

```http
POST /api/v1/templates
```

Request:

```json
{
  "name": "Reviewer",
  "description": "Careful code reviewer",
  "persona": "You review code for correctness.",
  "instructions": "Focus on tests, edge cases, and maintainability."
}
```

---

## 21. User WebSocket API

### 21.1 Connect

```http
GET /api/v1/user-ws
```

Auth:

- Browser SPA: relies on the Authentik/Authelia proxy session cookie and trusted proxy headers. Browsers must not pass bearer tokens in the WebSocket URL.
- Non-browser clients that can set headers, such as CLI, Bridge tooling, or Electron main-process code: may use `Authorization: Bearer <user_api_token>`.
- Query-string WS tokens are not part of the v1 API.

### 21.2 Event model

WebSocket events are lightweight invalidation and summary events. They should not stream full durable resource bodies by default.

Generic event:

```json
{
  "type": "resource_changed",
  "event_id": "evt_123",
  "resource": "task_chain",
  "resource_id": "chain_123",
  "change": "updated",
  "version": 14,
  "occurred_at": "2026-07-22T10:00:00Z"
}
```

Optional summary:

```json
{
  "type": "resource_changed",
  "event_id": "evt_124",
  "resource": "agent_instance",
  "resource_id": "inst_123",
  "change": "status_changed",
  "version": 5,
  "summary": {
    "runtime_status": "running",
    "startup_status": "ready",
    "activity_status": "idle"
  },
  "occurred_at": "2026-07-22T10:00:00Z"
}
```

### 21.3 UI behavior

UI should:

1. Update local cache if event summary is sufficient.
2. Otherwise refetch exactly the changed resource.
3. Avoid refreshing entire pages for one resource change.
4. Ignore events for resources not currently cached or visible unless they affect counters/badges.

### 21.4 Event resource names

Suggested resource names:

```text
user
bridge
bridge_enrollment
agent
agent_bridge_support
agent_instance
project
project_bridge_path
task_chain
task
task_comment
task_nudge
memory
chat
chat_message
artifact
template
```

---

## 22. SPA/API best practices

### 22.1 Summary list endpoints

List pages should not fetch full details for every row.

Good:

```http
GET /api/v1/task-chains
```

Returns:

- chain ID
- title
- status
- project name
- task counts
- updated time

Detail page fetches:

```http
GET /api/v1/task-chains/{id}?expand=tasks
```

### 22.2 Use expansions sparingly

Allowed examples:

```http
GET /api/v1/agents/{id}?expand=bridge_support,instances
GET /api/v1/projects/{id}?expand=bridge_paths
GET /api/v1/task-chains/{id}?expand=tasks
```

Avoid:

```http
?expand=everything
```

### 22.3 Paginate chat/comments/tasks/artifacts

Potentially large collections:

- chat messages
- task comments
- artifacts
- task lists in large chains
- memories

Must support pagination.

### 22.4 Batch lookup endpoint


For UI cache hydration, support a batch lookup endpoint.

```http
POST /api/v1/batch/get
```

Request:

```json
{
  "agents": ["agt_1", "agt_2"],
  "bridges": ["brg_1"],
  "projects": ["proj_1"],
  "task_chains": ["chain_1"]
}
```

Response:

```json
{
  "data": {
    "agents": [],
    "bridges": [],
    "projects": [],
    "task_chains": []
  }
}
```

Authorization:

- omit or return not_found entries for resources caller does not own.

### 22.5 Avoid authoritative user IDs in UI requests

Bad:

```json
{
  "user_id": "tanmay",
  "title": "My Chain"
}
```

Good:

```json
{
  "title": "My Chain"
}
```

The Hub assigns:

```text
owner_user_id = auth.user_id
```

### 22.6 401/403 UI behavior

- `401 unauthenticated`: show not-authenticated state with link to external login/reload.
- `403 forbidden`: show access denied or route away.
- UI should not offer a local Heimdall login form.

---

## 23. Bridge runtime API preview

This section is only a preview. The next document should define the Hub ↔ Bridge runtime protocol in full detail.

### 23.1 Bridge WebSocket connect

```http
GET /api/v1/bridge-ws
Authorization: Bearer hbr_secret
```

On connect, Hub authenticates token and binds socket to exactly one Bridge.

### 23.2 Bridge hello/capability report

Bridge sends:

```json
{
  "type": "bridge_hello",
  "protocol_version": 1,
  "machine": {
    "hostname": "tanmay-macbook",
    "os": "macos",
    "arch": "arm64"
  },
  "capabilities": [
    {
      "provider": "claude",
      "tiers": ["normal", "smart"],
      "default_tier": "normal"
    }
  ],
  "active_instance_ids": ["inst_123"]
}
```

Hub updates:

- `machine_hostname`
- `machine_os`
- `machine_arch`
- `capabilities`
- `last_seen_at`
- Bridge online status

### 23.3 Hub sends launch command

```json
{
  "type": "launch_agent",
  "command_id": "cmd_123",
  "agent_instance_id": "inst_123",
  "agent_id": "agt_123",
  "bridge_id": "brg_123",
  "project_id": "proj_123",
  "project_path": "/Users/tanmayvijay/heimdall-agent-manager",
  "provider": "claude",
  "tier": "smart",
  "bootstrap_url": "/api/v1/agent-instances/inst_123/bootstrap"
}
```

### 23.4 Bridge command result

```json
{
  "type": "command_result",
  "command_id": "cmd_123",
  "status": "accepted"
}
```

Failure:

```json
{
  "type": "command_result",
  "command_id": "cmd_123",
  "status": "failed",
  "error": {
    "code": "provider_unavailable",
    "message": "Provider claude smart is not available on this bridge"
  }
}
```

### 23.5 Bridge reports instance status

The Bridge does not stream a message per micro-change. Significant transitions are sent promptly as coalesced edge events; noisy signals (activity flapping, load) ride the periodic heartbeat digest. Every report carries a monotonic `state_seq` so the Hub applies updates idempotently and self-heals any missed event within one heartbeat. Full design: runtime protocol doc §7.4.

```json
{
  "type": "agent_instance_status",
  "agent_instance_id": "inst_123",
  "state_seq": 7,
  "runtime_status": "running",
  "startup_status": "ready",
  "activity_status": "active",
  "occurred_at": "2026-07-22T10:00:00Z"
}
```

### 23.6 Project path validation command

Hub sends:

```json
{
  "type": "validate_project_path",
  "command_id": "cmd_456",
  "project_id": "proj_123",
  "bridge_id": "brg_123",
  "path": "/home/tanmay/src/heimdall-agent-manager",
  "vcs_kind": "git",
  "repo_url": "https://github.com/example/heimdall"
}
```

Bridge responds:

```json
{
  "type": "project_path_validation_result",
  "command_id": "cmd_456",
  "project_id": "proj_123",
  "path": "/home/tanmay/src/heimdall-agent-manager",
  "ok": true,
  "details": {
    "vcs_kind": "git",
    "current_branch": "main"
  }
}
```

### 23.7 Bridge protocol details to define next

The next document should define:

- protocol versioning
- command IDs and idempotency
- command acknowledgements
- retry/reconnect behavior
- offline command queues
- bridge heartbeat intervals
- launch lifecycle state machine
- wrapper bootstrap fetch auth
- instance token issuance
- tmux session reporting
- stop/kill semantics
- path validation semantics
- VCS command routing
- artifact upload/download via Bridge if needed
- security boundaries for Bridge token

---

## 24. Build and rollout plan

This is a green-field rewrite. There is no data migration: no legacy records are imported and no federation/proxy compatibility shims are built. The phases below are a build order, not a migration path.

### Phase 0: Decide target invariants

Deliverables:

- This architecture/API document reviewed and accepted.
- Clear decision that Team/federation/proxy models are not built in v1.
- Agreement on Authentik/Authelia trusted-proxy auth for browser UI.
- Agreement on bearer-only machine auth.

### Phase 1: Add `/api/v1` and persistence foundation

Tasks:

1. Add versioned router prefix `/api/v1`.
2. Add standard success/list/error envelope helpers.
3. Add request ID and server time metadata.
4. Add common error code helpers.
5. Add pagination parser.
6. Add filter/sort/search parser helpers.
7. Add expansion/fields parser helpers.
8. Establish the data-access layer per Section 7A: engine-neutral repository interfaces, a single SQLite-backed implementation behind them, a unit-of-work/transaction abstraction, and ordered migration files.
9. Establish a composition root that constructs DB connection → repositories → services → handlers and injects them explicitly (no singletons/globals).

Acceptance criteria:

- New endpoints can use consistent response shapes.
- Pagination/filter/sort helpers are shared.
- Errors are consistent.
- No SQLite-specific code exists above the repository layer.
- Services can be unit-tested against fake repositories with no database.
- Swapping the SQLite repository implementation for another engine requires no service/handler changes.

### Phase 2: Add trusted proxy auth and users

Tasks:

1. Add auth config for trusted proxy headers/CIDRs.
2. Implement auth middleware.
3. Add users durable store/table.
4. Auto-provision users from trusted headers.
5. Add `/api/v1/me`.
6. Add `/api/v1/me/logout-url`.
7. Build the `ham-dev-proxy` stand-in (Section 6.6): strips client trusted headers, injects the selected dev user, forwards bearer tokens and everything else unchanged. Separate binary; no auth bypass inside the Hub.

Acceptance criteria:

- Requests without identity get 401.
- Spoofed trusted headers from untrusted IP get 401.
- Valid proxy-authenticated requests get AuthContext.
- UI can fetch current user.
- Hub runs only in `trusted_proxy` mode; dev and prod differ only by the front proxy.
- `ham-dev-proxy` can switch the active user to exercise cross-user isolation.

### Phase 3: Owner-scope core resources

Every core resource is designed with `owner_user_id` from the start.

Resources:

- Agent
- AgentInstance
- TaskChain
- Project
- Memory
- ChatConversation
- ChatMessage
- Artifact
- Template if user-created

Tasks:

1. Include `owner_user_id` in each schema.
2. Create paths set `owner_user_id = auth.user_id`.
3. List/get/update/delete filter by owner.
4. Add cross-user denial tests.

Acceptance criteria:

- User A cannot list/read/mutate User B resources.
- No handler trusts body/query user ID.

### Phase 4: No Teams in the model

Teams are a non-goal (Section 3). In a green-field rewrite there is nothing to remove; the requirement is simply to not build them.

Tasks:

1. Do not model Teams or team-owned resources.
2. Task chains are created without Teams.
3. Memory has no team-scoped dimension.

Acceptance criteria:

- New chains do not require Teams.
- UI does not expose Teams.
- API has no Team endpoints.

### Phase 5: Bridge registry and enrollment

Tasks:

1. Add Bridge store.
2. Add BridgeEnrollment store.
3. Add bridge token hashing.
4. Add create/list/revoke enrollment endpoints.
5. Add bridge enroll endpoint.
6. Default Bridge label to hostname if enrollment label omitted.
7. Add Bridge list/detail/rename/revoke endpoints.

Acceptance criteria:

- User can create enrollment.
- Bridge can enroll using one-time token.
- Bridge belongs to enrolling user.
- Bridge label defaults to hostname.
- User sees only own Bridges.

### Phase 6: Agent bridge support

Tasks:

1. Add AgentBridgeSupport store.
2. Add support endpoints.
3. Add UI controls for supported Bridges.
4. Validate provider/tier against Bridge capabilities.

Acceptance criteria:

- Agent is owned by user.
- Agent can be configured for one or more user-owned Bridges.
- Agent cannot be configured for another user's Bridge.

### Phase 7: Project path overrides

Tasks:

1. Add mandatory `default_path` to Project.
2. Add ProjectBridgePath store.
3. Add bridge path override endpoints.
4. Add synchronous path validation over the Bridge WebSocket (per Section 25.2).
5. Show effective path in UI when selecting Bridge/project.

Acceptance criteria:

- Project can have different paths per Bridge.
- Effective path resolution works.
- Launch uses effective path.

### Phase 8: Agent instance launch through Bridge

Tasks:

1. Convert start flow to `POST /api/v1/agent-instances`.
2. Create Hub-owned instance records.
3. Resolve Bridge/provider/tier/project path.
4. Send launch command to Bridge.
5. Update instance status from Bridge result.

Acceptance criteria:

- Agent starts on selected/scheduled Bridge.
- Instance is Hub-owned and Bridge-located.
- No proxy mapping exists.

### Phase 9: User WebSocket invalidation

Tasks:

1. Add `/api/v1/user-ws` under auth context.
2. Emit resource_changed events for relevant resources.
3. Update UI cache invalidation.

Acceptance criteria:

- UI receives status changes without polling huge endpoints.
- UI refetches only changed resources.

### Phase 10: API conversion for UI surfaces

Convert UI to `/api/v1` endpoints:

- `/me`
- Bridges
- Agents
- Agent bridge support
- Agent instances
- Projects/project paths
- Task chains/tasks
- Memory
- Chat
- Artifacts

Acceptance criteria:

- UI sends no authoritative user IDs.
- UI relies on current user context.
- UI list views use paginated compact endpoints.

### Phase 11: No federation/proxy model

Federation, remote proxy agents, and local proxy instance mappings are non-goals (Section 3). In a green-field rewrite there is nothing to remove; the requirement is to not build them.

Tasks:

1. Do not model remote proxy agents.
2. Do not model federation peer mappings.
3. Use no federation/proxy terminology in API or UI.

Acceptance criteria:

- No proxy or federation records exist in the model.
- User mental model is Agent + Bridge, not local proxy remote agent.

### Phase 12: Bootstrap the first environment

This is not a data migration. It is first-run setup for a fresh Hub.

Tasks:

1. On first run, auto-provision the authenticated user from trusted proxy headers.
2. User enrolls their first Bridge via one-time enrollment token.
3. User creates their first Project, Agent, and enables the Agent on the Bridge.

Acceptance criteria:

- A fresh Hub reaches a usable single-user state through normal API flows.
- No import/backfill tooling is required.

### Phase 13: Tests and cutover

V1 critical test set:

- trusted-proxy auth
- cross-user denial / owner isolation
- one-time Bridge enrollment token
- explicit-Bridge launch
- offline-Bridge error

Broader tests should follow after the first cutover.

Required broader tests:

- trusted proxy auth success/failure
- user auto-provisioning
- disabled user rejected
- cross-user resource isolation
- bridge enrollment one-time token
- bridge token auth
- bridge revoke/rotate
- agent bridge support validation
- project path override resolution
- start instance explicit Bridge
- start instance Hub-selected Bridge
- offline Bridge errors
- provider unavailable errors
- user WS invalidation events
- no token accepted in query/body

End-to-end scenario:

1. User authenticates through trusted proxy.
2. User creates Bridge enrollment.
3. Bridge enrolls and reports hostname/capabilities.
4. User creates Project with default path.
5. User adds Bridge path override and validates it.
6. User creates Agent.
7. User enables Agent on Bridge.
8. User starts Agent instance on Bridge.
9. Bridge launches wrapper.
10. Instance status becomes running.
11. User sends chat/task.
12. Agent responds/status updates.
13. UI receives WS invalidation and refetches changed resources only.

---

## 25. V1 decisions

Resolved default-simple v1 decisions:

1. Use `user_id = normalized username` for v1. Revisit immutable IdP subject before production environments where usernames can be renamed.
2. Bridge path validation is synchronous over the Bridge WebSocket for v1. If validation becomes slow or flaky, promote it to an async command resource later.
3. Wrapper/agent runtime status reports through the Bridge in v1. Direct wrapper-to-Hub instance-token reporting can be added later if it simplifies agent-facing APIs.
4. Artifact blobs are centrally stored by the Hub in v1. Bridge-backed large local artifact content is post-v1.
5. System/built-in templates are ownerless, read-only system records, not user resources; they are available to all users without introducing a general visibility model. User-created templates are owned by `owner_user_id`. This is an explicit carve-out from invariant 3, which governs user-owned durable resources.
6. Bridge enrollment token entry should support both interactive paste and environment variable input in `ham-bridge enroll`; the token is never passed in URL params.
7. This is a green-field rewrite with no data migration. No federation/proxy compatibility shims are built, and v1 APIs never create federation/proxy records.

---

## 26. Runtime protocol document


The detailed **Hub ↔ Bridge Runtime Protocol** is defined in `docs/plans/hub-bridge-runtime-protocol.md`.

That document covers Bridge connection lifecycle, auth/token handling, protocol versioning, WebSocket event envelopes, command IDs/idempotency, launch/stop/path-validation commands, bootstrap fetch, instance token issuance, reconnect behavior, runtime state reporting, and security boundaries.

