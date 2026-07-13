# Plan: Authoritative Agent Identity (stop guessing agent-vs-user)

Status: Draft (plan only)
Scope: `src/daemon/` identity classification. Goal: make "is this id an agent or a
user?" an authoritative lookup recorded at the moment we generate the id, not a
fragile runtime guess. Fixes the coordinator-boot deadlock and the
running-agent-misclassified-after-restart window.

**Breaking changes are acceptable — this is not production code.** We therefore
prefer the cleanest end-state (one source of truth, delete the guessing) over
backward-compatible layering. Existing on-disk DBs may be dropped/reinitialised
(handle as a schema-version bump, per the established pattern), and legacy
heuristics are removed outright rather than kept as fallbacks.

## 0. Exact code sites (current state, for the implementer)

Measured references as of the emergency fix (line numbers approximate; grep the
symbol to be safe):

| Symbol | File:line | Role |
|---|---|---|
| `task_actor_is_user` | `src/daemon/task_queries.odin:294` | the guess to replace; currently checks live registry + (emergency) durable record |
| `task_runtime_agent_target` | `src/daemon/task_queries.odin:8` | boot-path gate; returns "" when `task_actor_is_user` true |
| `HUMAN_RECIPIENT_ID` | `src/daemon/task_queries.odin:6` | = `"operator@local"`; the single human-placeholder constant |
| `task_actor_can_override` | `src/daemon/task_queries.odin` (~325) | caller-authorization use of the predicate |
| `task_force_advance_authorized` | `src/daemon/task_queries.odin` (~329) | caller-authorization use |
| `task_normalize_user_reviewer` | `src/daemon/task_service.odin:28` | maps a "user" actor to `user_proxy` reviewer |
| `agent_record_index_by_instance` | `src/daemon/agent_store.odin:131` | O(n) lookup: `agent_instance_id` -> record index (the authoritative check) |
| `Agent_Instance_Record` | `src/daemon/agent_store.odin:15` | durable record struct (add `state` field here) |
| `agent_record_upsert` | `src/daemon/agents_start.odin:156` | the only writer of agent records today (called lazily at boot) |
| `registry_agent_exists` / `registry_init` | `src/daemon/registry.odin:246` / `:172` | live WS registry; `registry_init` sets `agent_count = 0` (wiped on restart) |
| `team_service_create_for_chain` | `src/daemon/team_service.odin:22` | where coordinator/member `agent_instance_id`s are GENERATED (add record write here) |
| `team_service_member_agent_instance_id` | `src/daemon/team_service.odin:95` | the id generator: `coordinator@<scope>`, `coder-1@<scope>`, ... |
| `task_autoscaler_ensure_chain_coordinator` | `src/daemon/task_nudge_scheduler.odin:199` | boot path that hit the deadlock; emergency human-placeholder skip lives here |
| `agent_record_upsert` (boot) | `src/daemon/task_nudge_scheduler.odin:333` | lazy record creation during boot — the dependency Phase 1 removes |

Emergency fix already in the tree (to be superseded): `task_actor_is_user` also
checks `agent_record_index_by_instance`; `ensure_chain_coordinator` skips only
`""`/`HUMAN_RECIPIENT_ID`/`user_proxy`/`operator@local` instead of routing the
coordinator through the guess.

## 1. The design smell

`agent_instance_id` is a key **we generate ourselves** at team/chain creation
(`team_service_member_agent_instance_id` → `coordinator@<scope>`,
`coder-1@<scope>`, …). At that instant we know, with certainty, that the id
belongs to an **agent**. Yet later the daemon *re-derives* that fact by guessing:

```
task_actor_is_user(actor) := actor != "" && !registry_agent_exists(actor)
```

`registry_agent_exists` checks the **live WS registry** (`agents[]`), which:
- is **empty for a never-connected agent** (brand-new coordinator), and
- is **wiped on daemon restart** (`registry_init` sets `agent_count = 0`) and only
  repopulated when agents reconnect/heartbeat.

So "is user" really means "is not currently connected," which is a completely
different question. Two concrete failures:

1. **Coordinator-boot deadlock:** a new chain's coordinator has never connected →
   guessed as user → `task_runtime_agent_target` returns "" → boot skipped with
   `no_runtime_coordinator`. It can't boot because it hasn't connected, and it
   can't connect because it won't boot.
2. **Restart misclassification window:** after a daemon restart, a **running**
   agent (tmux + process alive) is absent from `agents[]` until it heartbeats →
   momentarily classified as a user → wrong authorization / routing decisions.

### 1.1 Root cause: identity type is scattered, never authoritative

The fact "this id is an agent" is implied by **three separate stores**, none of
which is consulted as the authority, and none written at id-generation time:

| Store | Holds | Written when | Problem as an authority |
|---|---|---|---|
| live registry `agents[]` | connected sessions | on register/heartbeat | wiped on restart; empty pre-connect |
| `agent_instance_records` | durable agent list | **only at first boot** (`agent_record_upsert`) | not written at id generation |
| `team_members` | role membership | at team creation | not consulted by `task_actor_is_user` |
| auth_db `tokens.identity_type` | token→(user\|agent) | at token issue | only present for a caller *with a token* |

The generator (`team_service_create_for_chain`) writes the id into `team_members`
but **never records it as a known agent identity** anywhere the classifier looks.

## 2. Expectation (what "fixed" means)

1. When we **generate** an agent_instance_id (team/chain creation, coordinator
   assignment, member add), we **record it as an agent identity** in one
   authoritative place, immediately — before any boot.
2. "Is this id an agent?" becomes a **single authoritative lookup** against that
   record, independent of live connection state.
3. The classification is **correct across daemon restarts** and **before first
   connect** — a running or not-yet-started agent is always known to be an agent.
4. The token path stays authoritative for *callers*: when a request arrives with a
   token, its `identity_type` (already in auth_db) is the source of truth; the
   id-based classifier is only for reasoning about **stored** identities (routing,
   boot, reviewer normalization).
5. Simpler call sites: `task_actor_is_user` / `task_runtime_agent_target` reduce to
   one lookup with no registry/heuristic coupling.

Non-goals: no change to how ids are formatted; no new wire protocol; no removal of
the live registry (it stays for *connection* state, not *identity* state).

## 3. Design: one authoritative "agent identity" record, written at generation

### 3.1 Principle
**Identity is declared at creation, not inferred at use.** The moment the daemon
mints an agent_instance_id, it persists an assertion "this id is an agent." All
classification reads that assertion.

### 3.2 Single source of truth (breaking change: one store owns it)

Because breaking changes are fine, we do **not** layer a multi-signal fallback.
We pick **one** authoritative store for "this id is an agent" and write it at
generation:

**Chosen store: `agent_instance_records`** (durable, event-sourced, already
replayed on startup, already keyed by `agent_instance_id`). It becomes the single
registry of *known agent identities*. An `agent_instance_id` exists as a record
IFF it is an agent. Records get a lifecycle field (e.g. `state = provisioned |
running | archived`) so "declared but never booted" is representable without
runtime/session data.

Rejected alternatives (kept for rationale):
- *Multi-signal `identity_is_agent` with fallbacks* — this is what we are removing;
  fallbacks are exactly the scattered-state smell. One store, no fallbacks.
- *Derive from `team_members`* — team membership is a role concern, not an
  identity concern; not every agent identity need be a team member long-term.
- *Live registry* — connection state, explicitly NOT identity state.

### 3.3 The single classifier

One function, one lookup, no heuristics, no registry coupling:

```
// Authoritative: is this stored identity a known AGENT?
// Backed solely by the durable agent-identity record; connection state is
// irrelevant and never consulted here.
identity_is_agent(id: string) -> bool:
    return id != "" && agent_record_index_by_instance(id) >= 0

task_actor_is_user(id) := id != "" && !identity_is_agent(id)
```

Everything (`task_runtime_agent_target`, `task_actor_can_override`,
`task_force_advance_authorized`, `task_normalize_user_reviewer`) routes through
this one predicate. `registry_agent_exists` is demoted to answering only "is this
agent currently connected?" and is **removed from all identity/authorization
decisions**.

This works across restart because `agent_instance_records` is DB-backed and
replayed on startup — a running agent (and even a never-booted one) is a known
agent regardless of live-registry state.

### 3.4 Caller (token) path stays separate and authoritative
For request handlers, the caller's type must come from the **token**
(`auth_db_get_identity` → `identity_type`), already available via
`task_author_and_type_from_body`. The id-based `identity_is_agent` is for
reasoning about **stored** identities, not for authorizing a token-bearing caller.
This plan keeps that separation explicit (and dovetails with the caller-identity
chain, which threads `identity_type` through the vote path).

## 4. Why this is robust

| Failure today | Fixed by |
|---|---|
| New coordinator can't boot (never connected) | Agent record written at generation → `identity_is_agent` true before first boot |
| Running agent misclassified after restart | Record + team membership are DB-backed and replayed on startup → classification independent of live registry |
| Identity type scattered across 3 stores | **One** store (`agent_instance_records`) owns it; written at generation; no fallbacks |
| `task_actor_is_user` couples identity to connection | Decoupled: `registry_agent_exists` removed from all identity decisions |

## 4b. Desired end state (what the code looks like when done)

A fresh session should aim the implementation at exactly this end state:

1. **One source of truth.** `agent_instance_records` is the sole registry of
   "known agent identities." An `agent_instance_id` is an agent **iff** a record
   exists for it. The record carries a `state` (`provisioned | running |
   archived`) so a declared-but-never-booted identity is representable without any
   runtime/session data.

2. **Identity is declared at generation.** Every place that mints an agent
   `agent_instance_id` (coordinator on chain create, team members, later member
   adds) writes a `provisioned` agent record in the same operation — before any
   boot. There is no code path that produces an agent id without a record.

3. **One classifier, no heuristics.**
   ```
   identity_is_agent(id) := id != "" && agent_record_index_by_instance(id) >= 0
   task_actor_is_user(id) := id != "" && !identity_is_agent(id)
   ```
   All four call sites (`task_runtime_agent_target`, `task_actor_can_override`,
   `task_force_advance_authorized`, `task_normalize_user_reviewer`) go through
   this. No fallbacks, no multi-signal OR-chains.

4. **`registry_agent_exists` answers only “is this agent currently connected?”**
   It appears nowhere in any identity or authorization decision. A grep-guard test
   enforces this.

5. **Connection ≠ identity.** Classification is correct (a) before an agent has
   ever connected, and (b) immediately after a daemon restart while a running
   agent has not yet re-registered — because the record is DB-backed and replayed
   on startup, independent of the live registry.

6. **Boot path has zero identity guessing.** `ensure_chain_coordinator` /
   `task_runtime_agent_target` skip only a genuine human placeholder
   (`HUMAN_RECIPIENT_ID`, single constant). The emergency string list and the
   registry-based guess are deleted.

7. **Caller identity stays token-authoritative and separate.** For request
   handlers, the caller’s type comes from the token (`auth_db_get_identity` ->
   `identity_type`, via `task_author_and_type_from_body`). `identity_is_agent` is
   only for reasoning about *stored* identities, never for authorizing a
   token-bearing caller. (This is the boundary the caller-identity chain owns.)

When all seven hold, the coordinator-boot deadlock and the restart
misclassification window are impossible by construction, and “agent vs user” is a
single O(1)-able lookup instead of a scattered guess.

## 5. Phased delivery (breaking changes OK; tests green each phase)

Because breaking changes are acceptable, phases move directly to the clean
end-state. DB schema may bump (drop/reinit older versions per the established
pattern) if the record gains a `state` field.

### Phase 1 — Declare agent identity at generation
- Add a `state` (`provisioned|running|archived`) to the agent identity record.
- In `team_service_create_for_chain` / coordinator assignment / member add, upsert
  a durable agent record (`provisioned`) for every generated non-user_proxy
  agent_instance_id, the moment the id is minted.
- Bump the agent/task schema version if needed; old DBs drop+reinit (no
  migration), consistent with prior practice.
- Exit: every generated agent id has a durable record from birth; builds green.

### Phase 2 — Single classifier, delete the guessing
- Add `identity_is_agent(id) := agent_record_index_by_instance(id) >= 0`.
- Rewrite `task_actor_is_user` to `!identity_is_agent(id)`.
- Remove `registry_agent_exists` from `task_actor_is_user` and every other
  identity/authorization decision; it stays only as a connection-state query.
- Delete the emergency ad-hoc checks (the temporary `agent_record_index_by_instance`
  line and the human-placeholder string list in `ensure_chain_coordinator`).
- Exit: exactly one predicate decides agent-vs-user for stored identities.

### Phase 3 — Simplify boot & collapse `task_runtime_agent_target`
- `ensure_chain_coordinator` / `task_runtime_agent_target` rely solely on
  `identity_is_agent`; the only skip is a genuine human placeholder, expressed via
  a single `HUMAN_RECIPIENT_ID` constant (no scattered string list).
- Consider inlining/removing `task_runtime_agent_target` if it reduces to the
  classifier.
- Exit: boot path has zero identity heuristics.

### Phase 4 — Guard & verify
- `nix build .#ham-daemon .#ham-ctl .#ham-wrapper` + `tsc` + task/team tests.
- Regression tests: (a) create chain → coordinator classified as agent and boots
  without ever having connected; (b) simulate restart with a persisted running
  agent → still classified as agent before it re-registers; (c) a real user id
  classifies as user.
- Grep-guard: `registry_agent_exists` appears ONLY inside connection-state code /
  `identity_is_agent` is the ONLY agent-vs-user predicate for stored identities.

## 6. Relationship to the emergency fix already applied
An emergency fix already landed in the working tree:
- `task_actor_is_user` now also checks `agent_record_index_by_instance`.
- `ensure_chain_coordinator` skips only genuine human placeholders instead of
  routing the coordinator through the guess.

This plan **supersedes and deletes** that emergency fix: Phase 1 declares identity
at generation, Phase 2 replaces the ad-hoc record check with the single
`identity_is_agent` and strips `registry_agent_exists` from identity decisions,
and Phase 3 removes the emergency human-placeholder string list. Keep the
emergency fix working until Phase 1–2 land, then remove it.

## 7. Acceptance criteria
- A brand-new chain coordinator is classified as an agent and boots without ever
  having connected.
- A running agent remains classified as an agent immediately after a daemon
  restart (before it re-registers).
- Exactly one predicate (`identity_is_agent`) decides agent-vs-user for stored
  identities; the token path decides it for callers.
- No identity/authorization decision depends on the live registry alone.
- Daemon builds; existing + new tests pass; wire format unchanged; no cheap-tier
  agents used.
