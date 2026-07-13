# Plan: Task Store Repository (encapsulate scattered task/chain state)

Status: Draft (plan only; no code changes)
Scope: `src/daemon/` task/chain in-memory state. Goal: replace direct access to
the six parallel global arrays + their manual count variables with a single
owning module exposing a typed query/mutation API. Behavior-preserving refactor.

## 1. Problem: the state is scattered

The task subsystem keeps its entire working set in **six package-global fixed
arrays, each with a separate `_count` variable that must be manually kept in
sync**, defined in `src/daemon/task_store.odin`:

```
task_events:       [TASK_MAX_EVENTS]Task_Event          task_event_count:       int
task_states:       [TASK_MAX_TASKS]Task_State           task_state_count:       int
task_participants: [TASK_MAX_PARTICIPANTS]Task_Participant  task_participant_count: int
task_chains:       [TASK_MAX_CHAINS]Task_Chain_State     task_chain_count:       int
task_comments:     [TASK_MAX_COMMENTS]Task_Comment_State  task_comment_count:     int
task_lgtm_votes:   [TASK_MAX_VOTES]Task_LGTM_Vote_State   task_lgtm_vote_count:   int
```

These globals are read and **mutated by raw index from 19 of 60 daemon files**.
There is no single owner; every caller open-codes scans, index math, and count
bookkeeping.

### 1.1 Measured evidence (exact sites)

Direct array/count access by file (`task_states[…]`, `task_chains[…]`, …,
`task_*_count`):

| Count | File |
|---|---|
| 94 | `task_projection.odin` |
| 71 | `task_queries.odin` |
| 60 | `task_store.odin` |
| 45 | `task_service.odin` |
| 28 | `task_nudge_scheduler.odin` |
| 28 | `task_db_service.odin` |
| 24 | `task_http.odin` |
| 22 | `task_notifications.odin` |
| 15 | `guide_rpc.odin` |
| 14 | `task_rest.odin` |
| 9 | `teams_v1_migration.odin` |
| 8 | `task_archive.odin` |
| 8 | `agent_rpc.odin` |
| 7 | `memory_auditor_orchestrator.odin` |
| 5 | `vcs_http.odin` |
| 2 | `team_http.odin` |
| 1 each | `merge_lifecycle.odin`, `memory_notifications.odin`, `chat_http.odin` |

Aggregate smell counts:

| Signal | Count | Why it's a problem |
|---|---|---|
| `task_states[…]` raw index | 103 | no bounds/existence guarantee at call site |
| `task_chains[…]` raw index | 107 | same |
| `task_events[…]` / `participants` / `comments` / `votes` raw index | 12 / 23 / 15 / 12 | same |
| `task_state_count`+`task_chain_count`+… references | 171 | the array/count invariant is maintained by hand in every mutator |
| `for i in 0..<task_*_count` hand-rolled loops | 101 | every query is re-implemented as a linear scan |
| re-implemented lookups (`task_existing_*_index`, inline scans) | 115 helper + 60 inline | duplicated find logic |
| 2-step "find index then index array" pattern | 37 | `idx, ok := task_existing_state_index(...)` then `task_states[idx]` — easy to misuse a stale/`-1` index |

### 1.2 Concrete failure modes this creates

- **Array/count desync:** count incremented in one path, forgotten in another;
  no compiler protection (e.g. `task_projection.odin` manually resets 5 counts to
  0 and does `task_*_count += 1` inline in many spots).
- **Stale-index bugs:** the find-then-index pattern returns `-1`/`idx` and callers
  index directly; a mutation between find and use invalidates the index.
- **O(n) everywhere:** 101 linear scans; no indexing possible while the arrays are
  public.
- **Impossible to evolve:** can't add caching, indexing, capacity growth, or swap
  in DB-backed storage without touching 19 files. The recent DB-reset incident
  and the caller-identity/status work all fight this scatter.

## 2. Expectation (what "fixed" means)

1. The six arrays and their counts become **private to one module**
   (`task_store`). No other file references them directly.
2. All reads go through **typed query functions** returning values/optionals or
   read-only views — never a raw index into a public array.
3. All writes go through **typed mutation functions** that are the *only* code
   allowed to touch the arrays and counts, so the array/count invariant cannot
   drift.
4. The 2-step find-then-index pattern is replaced by single-call accessors that
   return the record (or a not-found signal) directly.
5. Behavior is unchanged; the existing test suite passes before and after each
   phase. Wire/JSON output is byte-identical (contract tests guard it).
6. This is the seam for future work: indexing, capacity growth, and eventual
   DB-backed storage become single-module changes.

Non-goals: no new features; no persistence/schema change; no logic change; the
event-sourcing/replay model stays. This is pure encapsulation.

## 3. Proposed Task Store interface

A single module owns state and exposes an intention-revealing API. Names are
illustrative (Odin, package `main`); shapes match existing structs in
`task_store.odin` (`Task_State`, `Task_Chain_State`, `Task_Participant`,
`Task_Comment_State`, `Task_LGTM_Vote_State`, `Task_Event`).

### 3.1 Lifecycle
```
task_store_init(data_dir: string)          // existing
task_store_reset()                          // replaces manual count=0 resets in projection
```

### 3.2 Task (state) queries
```
store_get_task(task_id: string) -> (Task_State, bool)
store_get_task_in_chain(task_id, chain_id: string) -> (Task_State, bool)  // replaces task_existing_state_index
store_task_exists(task_id: string) -> bool
store_task_count() -> int
store_each_task(iter: proc(^Task_State))                // or a read-only slice view
store_tasks_in_chain(chain_id: string) -> []Task_State  // replaces 0..<count scans
store_tasks_for_assignee(agent_instance_id: string) -> []Task_State
```

### 3.3 Chain queries
```
store_get_chain(chain_id: string) -> (Task_Chain_State, bool)   // replaces task_existing_chain_index
store_chain_exists(chain_id: string) -> bool
store_chain_count() -> int
store_each_chain(iter: proc(^Task_Chain_State))
store_chains_for_project(project_id: string) -> []Task_Chain_State
```

### 3.4 Participant / comment / vote queries
```
store_participants_of(task_id: string) -> []Task_Participant
store_actor_has_role(task_id, agent_instance_id, role: string) -> bool
store_comments_of(task_id: string) -> []Task_Comment_State
store_votes_for(task_id: string) -> []Task_LGTM_Vote_State
store_reviewer_has_voted(task_id, reviewer: string) -> bool
```

### 3.5 Mutations (the ONLY writers of the arrays + counts)
```
store_append_event(event: Task_Event) -> bool           // existing entry; stays the write funnel
store_upsert_task(state: Task_State) -> bool
store_set_task_status(task_id, chain_id: string, status: Task_Status) -> bool
store_upsert_chain(chain: Task_Chain_State) -> bool
store_set_chain_field(...) / store_update_chain(chain: Task_Chain_State) -> bool
store_add_participant(p: Task_Participant) -> bool
store_remove_participant(task_id, agent_instance_id, role: string) -> bool
store_add_comment(c: Task_Comment_State) -> bool
store_resolve_comment(comment_id: string) -> bool
store_record_vote(v: Task_LGTM_Vote_State) -> bool
store_clear_votes_for_task(task_id: string) -> bool
```

### 3.6 Invariant ownership
- Only mutation functions modify `task_*_count`; callers never touch counts.
- Mutations enforce capacity (`TASK_MAX_*`) in one place and return `false` on
  overflow (today this is open-coded).
- Accessors return copies or read-only views; no caller holds a raw index across
  a mutation.

## 4. Phased delivery (behavior-preserving, tests green each phase)

Ordered by "hottest arrays first," each phase migrates all call sites for a
given array and then makes that array private.

### Phase 0 — Introduce the API surface (no call-site changes)
- Add the query/mutation functions above as thin wrappers over the existing
  globals. Keep globals public temporarily. Add unit tests for the accessors.
- Exit: builds; new API covered by tests; zero behavior change.

### Phase 1 — Chains (`task_chains`/`task_chain_count`, ~138 sites)
- Migrate all `task_chains[…]` / `task_chain_count` / `task_existing_chain_index`
  users to `store_get_chain` / `store_each_chain` / `store_upsert_chain`.
- Make `task_chains`/`task_chain_count` private to `task_store`.
- Exit: no file outside `task_store` references the chain array/count; tests green.

### Phase 2 — Tasks (`task_states`/`task_state_count`, ~152 sites)
- Migrate task-state access + the find-then-index pattern to `store_get_task*` /
  `store_tasks_in_chain` / `store_upsert_task` / `store_set_task_status`.
- Make `task_states`/`task_state_count` private.
- Exit: task array/count private; tests green.

### Phase 3 — Participants, comments, votes
- Migrate the participant/comment/vote arrays + counts to their accessors/mutators
  (`store_participants_of`, `store_votes_for`, `store_record_vote`, …).
- Make those arrays/counts private.
- Exit: all six arrays + counts private to `task_store`; tests green.

### Phase 4 — Events + projection reset
- Route `task_events`/`task_event_count` and the `task_projection.odin` manual
  count resets through `store_append_event` / `task_store_reset`.
- Exit: `task_projection.odin` no longer pokes counts directly; replay unchanged.

### Phase 5 — Verification & guard
- Full `nix build .#ham-daemon .#ham-ctl .#ham-wrapper` + `tsc` + task tests.
- Add a grep-guard test asserting the six arrays and `task_*_count` are referenced
  ONLY within `task_store.odin` (prevents regression of the scatter).
- Optional: internal index maps for hot lookups (task_id→idx, chain_id→idx) now
  that access is centralized — turns 101 O(n) scans into O(1).

## 5. Guardrails
- Each phase is an independent branch/chain; tests green before/after.
- Wire/JSON output must be byte-identical — contract/UI tests guard Phases 1–4.
- Smart-tier agents only; no cheap coder.
- No functional change; if a phase reveals a latent bug, file it separately.

## 6. Success criteria
- The six task-store arrays and their `_count` variables are private to
  `task_store.odin`; grep-guard test enforces it.
- All ~500 direct-access sites go through the typed API.
- The find-then-index and hand-rolled `0..<count` scan patterns are gone from
  callers (replaced by accessors).
- Array/count desync and stale-index bugs are impossible by construction.
- Daemon builds; existing + new tests pass; wire format unchanged.
