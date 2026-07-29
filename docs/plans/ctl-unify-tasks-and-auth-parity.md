# Unify `tasks` / `task-chains` CLI + User/Agent Operation Parity — Plan

## Goal

1. **Move `tasks` and `task-chains` out of the `hub` and `agent` sub-command
   namespaces** so they are top-level `ham-ctl` commands:
   - `ham-ctl task-chains ...`
   - `ham-ctl tasks ...`
   (today they are `ham-ctl hub task-chains ...` for users and
   `ham-ctl agent tasks ...` for agents.)
2. **Eliminate capability differences by token type.** Any operation that can be
   done with a **user token** should be doable with an **agent (instance)
   token**, and vice-versa (subject only to ownership/authorization, never to
   "which surface you happen to be on"). The CLI verb set and behavior must be
   identical regardless of whether the caller authenticates as a user or an
   agent.

## Current State (why there are two worlds)

### CLI dispatch (`src/ctl/main.odin`)
- `ham-ctl hub <resource> ...` → `ctl_hub_user_mode` (user token, talks REST
  `/api/v1/...` with `Authorization: Bearer hut_…`).
- `ham-ctl agent <resource> ...` → `ctl_agent_mode` (instance token, talks the
  **bridge local endpoint** over JSONL, which relays to Hub `/agent-actions/*`).
- So `tasks`/`task-chains` live in **two** places:
  - `ctl_hub_tasks` / `ctl_hub_task_chains` (`src/ctl/hub_mode.odin`) — full REST
    surface: chains list/create/show/update/members/add-agent/publish/complete;
    tasks list/create/update/status/done/depend/publish/cancel/comments/votes/
    nudge.
  - `ctl_agentmode_tasks` (`src/ctl/agent_mode.odin`) — a **subset**:
    fetch/list, create, done, status, comment, vote, nudge, depend. No chain
    create/update/members, no task update/publish/cancel/comments/votes list.

### Hub auth model (the root of the asymmetry)
- `resolve_auth` (`src/hub/service/auth/auth_service.odin`) accepts:
  - `hut_…` user API tokens → `User_Token`
  - trusted-proxy header → `Trusted_Proxy`
  - explicitly **rejects** bridge/enrollment tokens; **does not accept instance
    (`hit_…`) tokens at all.**
- Agent operations go through a **different** handler tree,
  `/api/v1/agent-actions/*` (`agent_action_handlers.odin`), authenticated by
  `require_instance_action_auth`: the **bridge** presents its `hbr_…` token +
  `X-Heimdall-Instance-Token: hit_<instance_id>` header; the Hub derives an
  `Instance_Token` Auth_Context.
- Net effect: **REST `/api/v1/task-chains/*` accepts only user/proxy auth**;
  **`/agent-actions/tasks/*` accepts only bridge-relayed instance auth**. The two
  never overlap, so the verb sets diverged and behavior can differ.

### Service layer (already mostly unified — good news)
- `taskchain_service.*` procs take a generic `contracts.Auth_Context` and already
  branch on `auth.kind == .Instance_Token` where needed (e.g. `create_comment`
  scopes an instance to its chain). So **the domain/service layer already
  supports both token kinds**; the divergence is purely at the **transport +
  CLI** layers.

## Design

Two independent but complementary changes:

### Part A — CLI: promote `tasks` / `task-chains` to top-level, single implementation

- Add top-level dispatch in `main.odin`:
  - `ham-ctl task-chains ...` and `ham-ctl tasks ...` (also accept singular
    `task`, `chain`/`chains` aliases as today).
- **One implementation** for each, in a new `src/ctl/tasks.odin`, that is
  **transport-agnostic**: it builds the request (method, path, body) and hands
  off to a **caller-selected transport**:
  - **User transport** (has user token / hub url): REST to `/api/v1/...` with
    `Authorization: Bearer hut_…` (reuse `ctl_hub_request`).
  - **Agent transport** (has bridge endpoint + instance token): the bridge-local
    JSONL path (reuse `ctl_agent_local_call`), OR — preferred once Part B lands —
    **the same REST call with the instance token** (see Part B).
- Transport is auto-selected from the environment/flags already used today:
  - if `--hub-url`/`--user-token` (or `HAM_HUB_URL`/`HAM_USER_TOKEN`) present →
    user transport;
  - else if `HEIMDALL_BRIDGE_ENDPOINT` + `HEIMDALL_AGENT_TOKEN` present → agent
    transport;
  - explicit override: `--as user` / `--as agent`.
- Keep `ham-ctl hub tasks …` and `ham-ctl agent tasks …` as **thin deprecated
  aliases** that forward to the unified path (one release), then remove.

Result: identical verb set and flags no matter who you are; the CLI picks the
transport, not the feature set.

### Part B — Hub: accept bridge-relayed instance auth on the shared REST surface

**Security invariant (do not violate): the instance token is NEVER a standalone
bearer credential to the Hub.** The **bridge token (`hbr_…`) is the trust
anchor.** A request that carries a valid bridge token is trusted, and the bridge
**asserts which instance it is acting for** (via the `X-Heimdall-Instance-Token:
hit_<instance_id>` header, exactly as `require_instance_action_auth` does today).
The `hit_<instance_id>` value is only an in-band assertion the trusted bridge
makes — it is not, and must not become, a secret the Hub authenticates on its
own. Agents never present a Hub-facing bearer; they talk to their local bridge,
and the bridge (holding `hbr_…`) relays to the Hub.

The goal is parity of **operations**, not a new credential type. Achieve it by
making the **same REST endpoints** accept the **bridge-relayed instance auth**,
so there is exactly one handler per operation.

- **B1 (recommended): let the shared REST task-chain handlers accept bridge +
  instance-assertion auth.**
  - Generalize the existing `require_instance_action_auth` logic (bridge token +
    `X-Heimdall-Instance-Token` header → `Instance_Token` Auth_Context) into a
    reusable `resolve_bridge_instance_auth` used by `require_auth`-style entry.
  - Update the REST auth entry (`require_auth` / a new `require_auth_any`) so a
    request authenticates as EITHER:
    - user (`hut_…`) / trusted-proxy → `User_Token` / `Trusted_Proxy`, OR
    - bridge (`hbr_…`) + valid `X-Heimdall-Instance-Token` → `Instance_Token`.
  - Then `/api/v1/task-chains/*` (and tasks/chat/artifacts/memory later) serve
    both, with the service layer authorizing per-op. The bespoke
    `/agent-actions/*` tree becomes redundant and can be kept as a compat shim
    or removed once the bridge relays generic REST calls.
  - **No per-instance Hub bearer is introduced.** The bridge remains the only
    Hub-facing credential for agent operations.

- **B2 (smaller, but keeps two trees): mirror the full verb set under
  `/agent-actions`.**
  - Add the missing agent-actions endpoints (chain create/update/members,
    task update/publish/cancel, comments list, votes list) so the agent surface
    matches the user surface 1:1, keeping the same bridge+assertion auth.
  - Downside: two parallel handler trees to keep in sync forever — exactly the
    drift we are trying to kill. Only pick this if B1's shared-auth change is
    deemed too risky.

**Recommendation: B1.** One handler tree, one auth resolver that yields either a
user or a bridge-asserted instance context. No new secret is exposed.

### What the CLI agent transport actually sends

`ham-ctl` running inside a Bridge-launched agent still talks **only to its local
bridge endpoint** (JSONL over the unix socket), never directly to the Hub with an
instance secret. The bridge is what holds `hbr_…` and attaches the
`X-Heimdall-Instance-Token` assertion when it relays to the Hub. So Part A's
"agent transport" = local-bridge relay; the bridge upgrades to calling the
generic REST task-chain routes (Part B) instead of the bespoke
`/agent-actions/tasks/*` method map. Agents never gain a Hub bearer.

## Authorization parity rules (what "same operations" means)

Parity is about **capability**, not bypassing authorization. Define per-op auth
in the **service layer** (single source of truth), applied identically no matter
the transport:

- **User/owner** (User_Token or Trusted_Proxy): full CRUD on their own chains,
  tasks, members, votes, comments (already the case).
- **Instance** (Instance_Token): may operate within chains it belongs to —
  create/update tasks in its chain, comment, change status, vote (if reviewer),
  nudge, add/remove members it is coordinator for, create chains it will
  coordinate. Reject cross-owner or out-of-chain actions with `Forbidden`
  (service already does this for comments; extend consistently).
- The **CLI exposes the same verbs to both**; the Hub **service** decides
  allow/deny uniformly. No verb is hidden merely because of token type — if the
  service would allow it, the CLI offers it.

## API / Route Changes

- (B1) Add a shared auth resolver that yields EITHER user/proxy auth OR
  bridge-asserted instance auth:
  - user (`hut_…`) / trusted-proxy → as today, OR
  - bridge token (`hbr_…`) + `X-Heimdall-Instance-Token: hit_<instance_id>`
    header → `Instance_Token` (reuse the exact checks from
    `require_instance_action_auth`: verify bridge token, load instance, confirm
    `inst.bridge_id == bridge.bridge_id`, confirm the assertion header matches).
  - **No instance bearer is accepted on its own.** Absent a valid bridge token,
    an `X-Heimdall-Instance-Token` is meaningless and rejected.
- (B1) Point the task-chain REST handlers at this shared resolver; they already
  call generic `taskchain_service.*` (Auth_Context) — remove any user-only
  assumptions.
- (B1) Deprecate `/api/v1/agent-actions/tasks/*` in favor of the unified REST
  routes once the bridge relays generic REST calls; keep as alias for one
  release.
- No new routes required beyond the shared auth; the REST task-chain surface
  already exists and is complete.

## CLI Surface (unified, final)

```
ham-ctl task-chains list
ham-ctl task-chains create --title <t> [--description <text>] [--project <name-or-select>] [--coordinator <agent>]
ham-ctl task-chains show    --chain <id>
ham-ctl task-chains update  --chain <id> [--title ..] [--description ..] [--status ..]
ham-ctl task-chains members --chain <id>
ham-ctl task-chains add-agent --chain <id> --agent <id> [--bridge ..] [--provider ..] [--tier ..]
ham-ctl task-chains publish  --chain <id>
ham-ctl task-chains complete --chain <id>

ham-ctl tasks list     --chain <id>
ham-ctl tasks create   --chain <id> --title <t> [--description ..] [--assignee ..] [--reviewer ..] [--depends-on a,b]
ham-ctl tasks update   --chain <id> --task <id> [..]
ham-ctl tasks status   --chain <id> --task <id> --status <s>
ham-ctl tasks done     --chain <id> --task <id>
ham-ctl tasks depend   --chain <id> --task <id> --depends-on <id>
ham-ctl tasks cancel   --chain <id> --task <id>
ham-ctl tasks comment  --chain <id> --task <id> --body <text>
ham-ctl tasks comments --chain <id> --task <id>
ham-ctl tasks vote     --chain <id> --task <id> --result lgtm|ngtm [--comment ..]
ham-ctl tasks votes    --chain <id> --task <id>
ham-ctl tasks nudge    --chain <id> --task <id> [--message ..]
```

Identical for user and agent callers. Agent convenience: when run inside a
Bridge-launched agent, `--chain` defaults to the agent's current chain (from
`agent context`), so agents rarely pass it.

## Expected API Responses

Parity requirement: **the response body for a given operation is identical
regardless of token type** (user vs bridge-asserted instance). Only
authorization (allow/deny) may differ, surfaced as the standard error envelope.
All responses use the shared envelope:

- Success (single): `{ "data": <object>, "meta": { request_id, server_time } }`
- Success (list): `{ "data": [ <object>, … ], "page": { limit, next_cursor,
  has_more }, "meta": { … } }`
- Error: `{ "error": { code, message, details }, "meta": { … } }`
  (e.g. `forbidden` when the caller may not perform the op — same code for user
  or agent when authorization fails).

Object shapes (from the current handlers — unchanged by this work):

### Task chain (detail) — `GET /api/v1/task-chains/{id}`

```jsonc
{
  "data": {
    "chain_id": "chain_18c6…",
    "title": "Payments refactor",
    "description": "migrate to new gateway",
    "publish_state": "published",
    "status": "active",
    "kind": "team_work",
    "coordinator_agent_instance_id": "inst_18c6…",
    "default_reviewer_refs": [],
    "created_at": "2026-07-28T…Z",
    "updated_at": "2026-07-28T…Z",
    "members": [
      { "chain_id": "chain_18c6…", "agent_instance_id": "inst_18c6…",
        "agent_id": "agt_18c6…", "role": "coordinator",
        "created_at": "2026-07-28T…Z" }
    ],
    "tasks": [ /* task detail objects, see below */ ]
  },
  "meta": { "request_id": "req_…", "server_time": "…Z" }
}
```

### Task chain (list) — `GET /api/v1/task-chains`

```jsonc
{
  "data": [
    { "chain_id": "chain_18c6…", "title": "…", "description": "…",
      "publish_state": "published", "status": "active", "kind": "team_work",
      "coordinator_agent_instance_id": "inst_…", "default_reviewer_refs": [],
      "created_at": "…Z", "updated_at": "…Z" }
  ],
  "page": { "limit": 50, "next_cursor": null, "has_more": false },
  "meta": { … }
}
```

### Task (summary) — create/update/status responses

`POST /task-chains/{id}/tasks`, `PATCH …/tasks/{tid}`,
`POST …/tasks/{tid}/status|cancel|publish` → `data` is a task summary:

```jsonc
{
  "data": {
    "task_id": "task_18c6…",
    "chain_id": "chain_18c6…",
    "title": "Implement gateway client",
    "description": "…",
    "publish_state": "published",
    "status": "in_progress",
    "assignee_ref": { "type": "agent_instance", "agent_instance_id": "inst_…" },
    "reviewer_refs": [ { "type": "agent_instance", "agent_instance_id": "inst_…" } ],
    "unblocks_dependents": false,
    "updated_at": "…Z"
  },
  "meta": { … }
}
```

### Task (detail, embedded in chain detail / `GET …/tasks`)

Includes dependencies, blocked flag, comments, and votes:

```jsonc
{
  "task_id": "task_18c6…",
  "chain_id": "chain_18c6…",
  "title": "Migrate settlement job",
  "description": "…",
  "publish_state": "published",
  "status": "in_validation",
  "assignee_ref": { "type": "agent_instance", "agent_instance_id": "inst_…" },
  "reviewer_refs": [ { "type": "agent_instance", "agent_instance_id": "inst_…" } ],
  "blocked": false,
  "depends_on": [ "task_18c6…" ],
  "comments": [
    { "comment_id": "cmt_…", "task_id": "task_…", "chain_id": "chain_…",
      "author_agent_instance_id": "inst_…", "body": "submitted for review",
      "created_at": "…Z" }
  ],
  "votes": [
    { "task_id": "task_…", "reviewer_agent_instance_id": "inst_…",
      "vote": "ngtm", "comment": "handle retry", "created_at": "…Z" }
  ]
}
```

### Comment — `POST …/tasks/{tid}/comments` (201) / `GET …/comments` (list)

```jsonc
// single (201)
{ "data": { "comment_id": "cmt_18c6…", "task_id": "task_…", "chain_id": "chain_…",
            "author_agent_instance_id": "inst_…", "body": "…", "created_at": "…Z" },
  "meta": { … } }
// list
{ "data": [ { "comment_id": "…", … } ], "page": { … }, "meta": { … } }
```

### Vote — `POST …/tasks/{tid}/vote` (200) / `GET …/votes` (list)

```jsonc
// single
{ "data": { "task_id": "task_…", "reviewer_agent_instance_id": "inst_…",
            "vote": "lgtm", "comment": "", "created_at": "…Z" },
  "meta": { … } }
```

### Member — `GET/POST …/members`, `DELETE …/members/{aiid}`

```jsonc
// list / add
{ "data": { "chain_id": "chain_…", "agent_instance_id": "inst_…",
            "agent_id": "agt_…", "role": "worker", "created_at": "…Z" },
  "meta": { … } }
// delete
{ "data": { "removed": true }, "meta": { … } }
```

### Nudge — `POST …/tasks/{tid}/nudge`

```jsonc
{ "data": { "task_id": "task_…", "target": "assignee", "message": "…",
            "created_at": "…Z" }, "meta": { … } }
```

### Parity contract for the CLI

`ham-ctl tasks …` / `task-chains …` prints the **`data`** object (or the full
envelope with `--raw`), byte-identical whether the transport was user-REST or
bridge-relayed agent. The agent transport (local bridge JSONL) unwraps the Hub
envelope and returns the same `data` shape, so downstream parsing is
token-agnostic. Errors surface the same `error.code`/`message` from either path.

## Tasks & Sequencing

1. **B0 — audit**: list every task/chain op and confirm the service layer
   authorizes it correctly for `Instance_Token` (comments already do; extend to
   create/update/status/vote/members). Add missing service-side checks.
2. **B1 — Hub auth**: extract the bridge+instance-assertion checks from
   `require_instance_action_auth` into a shared resolver; add `require_auth_any`
   that accepts user/proxy OR bridge-asserted instance auth; point task-chain
   REST handlers at it. **No per-instance Hub bearer.** Bridge-relay path keeps
   working unchanged.
3. **CLI-A — unified command module**: new `src/ctl/tasks.odin` implementing
   `task-chains`/`tasks` transport-agnostically; top-level dispatch in
   `main.odin`; transport auto-select: user → REST (`hut_…`); agent → local
   bridge relay (unix socket JSONL), never a Hub bearer.
4. **CLI-A2 — aliases**: `ham-ctl hub tasks…` / `ham-ctl agent tasks…` forward to
   unified path (deprecation notice).
5. **Bridge/wrapper**: extend the bridge relay so it forwards generic REST
   task-chain calls to the Hub with its `hbr_…` token + the
   `X-Heimdall-Instance-Token` assertion (reusing the current relay mechanism).
   Deprecate the bespoke `/agent-actions/tasks/*` method map once callers move
   over.
6. **Docs/help/skills**: update `ham-ctl` help, AGENTS.md task block, and the
   task-workflow skill to the unified `ham-ctl tasks …` / `task-chains …` verbs
   (drop `agent`/`hub` prefixes).
7. **Tests**: parity test — run the full verb set once with a user token and once
   with an instance token against the same chain; assert identical behavior/results.

## Validation

- `odin build src/hub`, `odin build src/ctl`, `odin build src/bridge`.
- Parity E2E: create chain + tasks + comment + vote + status transitions using
  `--as user` and `--as agent` (instance token); diff the resulting chain state —
  must match.
- Back-compat: old `ham-ctl hub tasks…` / `ham-ctl agent tasks…` still work via
  aliases; existing bridge-relay agents unaffected during migration.

## Risks / Notes

- **Security invariant (hard rule)**: the instance token is NOT a Hub bearer.
  Only a valid **bridge token** authenticates a request; the bridge asserts the
  instance via `X-Heimdall-Instance-Token`. Never authenticate `hit_<id>` on its
  own. This keeps the guessable instance id from being a credential and preserves
  the existing bridge-as-trust-anchor model.
- **Single source of authorization**: put allow/deny in the service layer so
  transport can never grant more than intended. The CLI must not implement its
  own gating.
- **Migration**: keep `/agent-actions/*` and the `hub`/`agent` CLI aliases for
  one release; remove only after wrapper/bridge/agents move to the unified path.
- **Agent ergonomics**: default `--chain`/`--task` context for Bridge-launched
  agents so the unified verbs stay as terse as today's `agent tasks`.
- Don't reintroduce per-transport verb drift: the unified `tasks.odin` is the
  only place that knows task/chain verbs.
