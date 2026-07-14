# Plan: Flexible Agent Runtime Model

Status: Ready-for-implementation design (revised after code audit)
Scope: Heimdall agent identity, per-agent memory, runtime context, task assignment, and team/template model.
Compatibility: **No backward compatibility required.** We may change the identity primary key, the memory targeting dimensions, DB schemas, wire contracts, and CLI/HTTP shapes. Old data may be dropped or one-shot migrated; do not add compat shims.

---

## 0. Product outcome this plan must guarantee

The concrete end-state the user wants:

1. **Agent create button.** Create an agent by giving it a name and picking a predefined role (template). No project required at creation time.
2. **Per-agent memory.** Create memories scoped to *one specific agent instance*; they apply to that agent only.
3. **Run anywhere.** The same agent identity can run in any project; project is runtime context, not identity.
4. **Assign to an idle/never-run agent.** Assigning a task to an agent that is not running is allowed. The agent inherits the task's chain and that chain's project as its runtime context for that run.
5. **Assign/review with an existing running instance.** Pick a live agent as assignee or reviewer even if it was never part of the chain's generated team.

Every section below is written so these five outcomes have exactly one unambiguous implementation path. Where the current code contradicts an outcome, the conflict is called out explicitly with the file/symbol.

---

## 1. Current-state audit (what actually exists in code today)

This is the ground truth the plan must change. Verified against the daemon source.

### 1.1 Identity encodes the project (blocks outcome #3)

- `agent_generated_instance_id(name, project_id)` returns `"<name>@<project>"` — `src/daemon/agent_store.odin:181`.
- `derive_agent_class` splits on `@` and treats the prefix as the class/role — `src/daemon/registry.odin:507`.
- `valid_agent_instance_id` *requires* exactly one `@` with non-empty both sides — `src/daemon/registry.odin:527`.
- `conversation_id_for_instance` is a pure function of the instance id — `src/daemon/registry.odin:~535`.

Implication: today the project is baked into the primary key and the conversation id. "Run the same agent in any project" is not expressible; you'd get a different identity per project.

### 1.2 Single identity record mixes identity + runtime (blocks outcomes #3, #4)

- `Agent_Instance_Record` holds `project_id`, `run_dir`, `current_task_id`, `current_task_since` on the *identity* record — `src/daemon/agent_store.odin:19`.
- `POST /agents/associate` overwrites `project_id` on the identity record — `src/daemon/agents_start.odin:127`.
- `POST /agents/start` reads `project_id` from the identity record, not from a task/chain — `src/daemon/agents_start.odin:242`.

Implication: there is no separate "run" concept. Starting the same agent for a different project mutates its identity. §3.3's "runtime session" does not exist yet.

### 1.3 Memory has no per-agent dimension and actively rejects one (blocks outcome #2)

- Memory targeting dimensions are only `target_team_kind`, `target_role`, `target_project_id` — `src/contracts/memory_provider.odin`, table schema `src/daemon/memory_db_service.odin:49`.
- `agent_instance_id` is on the **blocked legacy-keys list**; sending it returns HTTP 400 — `src/daemon/memory_service.odin:20`.

Implication: "memory for this agent only" is impossible today and explicitly forbidden by validation.

### 1.4 Assignment is gated by chain team membership (blocks outcomes #4, #5)

- `task_agent_instance_allowed_for_chain(chain_id, agent_instance_id)` returns false for any agent not in the chain's `team_id` members (except coordinator/default reviewer) — `src/daemon/task_service.odin:985`.
- Task create/assign both call this gate — `src/daemon/task_service.odin:99,105,892,949`.

Implication: assigning a live-but-non-team specialist is rejected with `"assignee is not a member of this chain team"`.

### 1.5 One active task slot per agent

- `task_active_slot_blocker` returns a blocking task id if the agent already has an `In_Progress`/`Review_Ready` task — `src/daemon/task_queries.odin:183`.

Implication: assignment to a busy live agent needs a defined behavior (queue vs reject).

### 1.6 Provider defaults are inconsistent with runnable providers

- Templates seed `default_provider_profile = "pi"` — `src/daemon/agent_template_db_service.odin` seeding.
- Runnable wrapper profiles are `Claude Code` / `claude` (see `config.toml` `[wrapper.agent-cmd.*]`).

Implication: "just name it and pick a role, then run" needs a deterministic provider-resolution rule, or launch fails.

---

## 2. Target model (decisions, not options)

Guiding principle stays:

> Templates propose agents. Assignments define involvement. A run binds an agent to a project + chain + task for execution.

But we make the following **binding decisions**.

### 2.1 Identity is a stable opaque id, decoupled from project

Decision:

- `agent_instance_id` becomes a stable slug **derived from the display name only**, uniquified with a short random/counter suffix. It MUST NOT contain the project.
  - Example: `reviewer-smart`, `alice-coder`, `researcher-7`.
- `agent_class`/role is **no longer derived by splitting on `@`**. Role comes from `template_id` → `role_hint`. Remove `derive_agent_class`-by-`@` semantics.
- `valid_agent_instance_id` is redefined: a non-empty slug of `[a-zA-Z0-9-]`, optionally with a `@`-suffix that is *cosmetic only* and never parsed for project/role. Recommended: drop `@` from generated ids entirely to avoid confusion.
- Special identities `operator@local` and `user_proxy` remain reserved literals and are excluded from runnable rosters (unchanged behavior, but they are the *only* ids allowed to contain `@`).

Migration: one-shot rename pass over `instance-events.jsonl` and any DB rows is acceptable; since no backcompat is required, wiping the agent store in dev is also acceptable. **Pick one and state it in the implementation PR.** Recommended: fresh store; document the reset.

### 2.2 Split identity record from runtime record

Decision: introduce two persisted concepts.

`Agent_Instance_Record` (identity only) keeps:

- `agent_record_id`, `agent_instance_id`, `display_name`, `template_id`,
  `default_provider_profile`, `default_model_tier`, `state` (provisioned/archived),
  `created_unix_ms`, `updated_unix_ms`, `archived_at_unix_ms`, `order`.

Remove from identity: `project_id`, `run_dir`, `current_task_id`, `current_task_since`, `last_needed_at_unix_ms`.
(Those describe a *run*, not the agent.)

`Agent_Run_Record` (new; one active per agent under the §2.5 decision) holds:

- `run_id`, `agent_instance_id`,
- `project_id`, `chain_id`, `task_id`,
- `run_dir`, `provider_profile`, `model_tier` (resolved for this run),
- `agent_token`, `tmux_session`, `tmux_pane`, `conversation_id`,
- `status` (launching/ready/blocked/failed/stopped), `current_task_id`, `current_task_since`,
- `started_unix_ms`, `last_active_unix_ms`, `last_needed_unix_ms`.

Note: the existing in-memory `Agent_Record` in `registry.odin` already holds live socket/pane/heartbeat state — fold `Agent_Run_Record`'s durable-run fields there or persist alongside; do not duplicate live socket state into the store (that in-memory boundary rule from `agent_store.odin` header stays).

### 2.3 Conversation id is per-run-context, not per-identity

Decision: `conversation_id` is derived from `agent_instance_id + chain_id` (or `+ project_id` when no chain). Reason: the same agent working two chains must not share one conversation stream. Update `conversation_id_for_instance` → `conversation_id_for_run(agent_instance_id, chain_id, project_id)`.

Consumers to update: register/reconnect responses (`lifecycle.odin`), `agents_start.odin` response builders, message provider lookups.

### 2.4 Provider/tier resolution order (deterministic)

When launching a run, resolve provider profile and tier in this exact order (first non-empty wins):

1. explicit value on the start/assign request,
2. the agent identity's `default_provider_profile` / `default_model_tier`,
3. the template's `default_provider_profile` / `suggested_model_tier`,
4. config `[wrapper].default_agent` / global default tier.

Also: template seed `default_provider_profile` must be a **runnable** profile that exists in `[wrapper.agent-cmd.*]` (e.g. `Claude Code`), or empty (so step 4 applies). The literal `"pi"` seed must be removed or mapped, otherwise every "create + run from template" fails. **This is a required fix, not optional.**

### 2.5 Concurrency decision: one active run per agent (locked for v1)

Decision: **one active run per agent instance at a time.** Assignment can target any eligible agent, but a given agent executes one task/run at a time.

Consequences that must be specified:

- Assigning a task to a busy live agent → task is accepted but stays `planned`/queued for that agent; it does not force a second run. `tasks next` promotes it when the agent frees up. (Do **not** silently reject; outcome #5 says assignment must be allowed.)
- Assigning a task to an idle-but-running agent in a *different* project/chain → since only one run is allowed, the run's project/chain context would have to switch. v1 rule: **the agent must be idle (no active task) to accept a run in a new chain.** If busy, the task queues as above. State this explicitly in the assign response (`queued_behind_task_id`).
- Concurrent multi-chain runs are **out of scope for v1** and listed as future work (§8).

### 2.6 Per-agent memory (new targeting dimension)

Decision: add `target_agent_instance_id` as a first-class memory targeting dimension, **alongside** existing `target_team_kind`, `target_role`, `target_project_id`.

- Remove `agent_instance_id` from the blocked legacy-keys list in `memory_service.odin:20`; introduce the new canonical field `target_agent_instance_id`.
- Add DB column + index: `ALTER TABLE memories ADD COLUMN target_agent_instance_id TEXT NOT NULL DEFAULT '';` and extend `idx_memories_targets`.
- Extend contract structs in `src/contracts/memory_provider.odin`: `Memory_Event`, `Memory_Record`, `Memory_List_Request` all get `target_agent_instance_id`.
- Matching rule (`memory_record_applies` / `memory_record_matches_filters`): a per-agent memory applies **only** when the requesting run's `agent_instance_id` matches. It is not returned for other agents even if role/project match.
- Precedence for bootstrap injection (most specific first): agent-instance → project → role → team-kind → global. Document dedup/ordering.
- Validation: `target_agent_instance_id` must reference an existing non-archived agent instance (mirror `memory_project_id_known`).

This is the single most important schema change for outcome #2 and must land before the UI "add memory to this agent" control.

---

## 3. Assignment & runtime binding (outcomes #4 and #5)

### 3.1 Remove the team-membership gate as a hard wall

- Replace `task_agent_instance_allowed_for_chain` hard-fail with a soft rule:
  - Allowed if agent instance exists and is non-archived.
  - If not currently associated with the chain, **auto-create an association record** (`association_kind = ad_hoc` or `assigned`) instead of rejecting.
- Keep these protections (unchanged): assignee ≠ reviewer, reviewer/assignee separation, `user_proxy`/operator reviewer rules, archived-agent rejection.
- `task_active_slot_blocker` stays but is reinterpreted per §2.5 (queue, don't hard-reject at assignment time; still gate `tasks next` promotion).

### 3.2 Assign to a never-run / idle agent → inherit chain + project

Exact rule for outcome #4:

1. Task already belongs to a chain (`task.chain_id`) which has a `project_id`.
2. On assignment, if the target agent has no active run, Heimdall records intent: `{agent_instance_id, project_id := chain.project_id, chain_id := task.chain_id, task_id}`.
3. When launched (manually or by autoscaler/nudge), the run's `project_id` comes from **the chain**, never from the old identity `project_id` field (which no longer exists). This removes the `agents_start.odin:242` ambiguity.
4. `run_dir` is derived from managed layout `<agent_run_dir>/<safe-project>/<safe-agent-instance>` using the *chain's* project. Per-agent `run_dir` override, if any, still wins (matches AGENTS.md managed-layout rules).

Tiebreak rules that MUST be written down (currently undefined):

- If a task has no chain (standalone task): assignment requires an explicit `project_id` on the request, else error `"project_required_for_unchained_task"`.
- If the chain has no project: run starts project-less; VCS/workspace features degrade gracefully (already partially handled — verify `task_service_project_supports_vcs`).

### 3.3 Assign/review with an existing running instance (outcome #5)

- Allow selecting any live, non-archived agent as assignee or reviewer regardless of original team.
- On selection, create/update the association record and (if needed) send a nudge/notification so the live agent picks up chain/task context.
- Reviewer selection keeps the non-user, non-self reviewer constraints (`task_service_pick_non_user_reviewer` logic) but no longer requires team membership.

### 3.4 Association record (formalized, persisted)

```text
association_id
agent_instance_id
project_id           # denormalized from chain at association time
chain_id
task_id              # empty for chain-level (coordinator/subscriber)
association_kind     # coordinator | assignee | reviewer | subscriber | ad_hoc
created_unix_ms
last_active_unix_ms
```

Derived chain roster = union of associations + live runs + (optionally) generated template slots shown as suggestions. This replaces "team_members is the source of truth."

---

## 4. Team template reframed (staffing scaffold only)

- `team_kind` → `chain_staffing_template`: used only to *suggest*/*generate* default agents and scaffold tasks at chain creation.
- Generated agents are normal `Agent_Instance_Record`s created via the same path as the create button; they are not special.
- Team tables are **not** the assignment gate anymore (§3.1). Since no backcompat is required, either drop `team_members` entirely and compute roster from associations, or keep it purely as scaffold history. **Decision: compute roster from associations; keep team tables only if scaffold generation needs them, otherwise delete.** State the choice in the PR.

---

## 5. UI: the "Create Agent" flow (outcome #1) and per-agent memory (outcome #2)

### 5.1 Create Agent button

- New button + modal. Fields: `display_name` (required), `role/template` (required select), optional `default_provider`, optional `default_model_tier`. **No project field.**
- Calls existing `POST /agents/create` (`agents_start.odin:~540`) but with the §2.1 id generation (name-based, project-free) and §2.4 provider defaults.
- Required `data-debug-id`s (per AGENTS.md UI rules): add a new registry row, e.g.:
  - `agents-new-agent-btn`, `create-agent-name-input`, `create-agent-template-select`, `create-agent-provider-select`, `create-agent-tier-select`, `create-agent-cancel-btn`, `create-agent-submit-btn`.

### 5.2 Per-agent memory UI

- On an agent's detail/side sheet: "Add memory (this agent only)" control that sends `target_agent_instance_id` (§2.6).
- Memory management page gains an agent filter.
- `data-debug-id`s: `agent-memory-add-btn-${agentId}`, `agent-memory-body-textarea`, `agent-memory-submit-btn`, plus a filter select `memory-filter-agent-select`.

### 5.3 Assignment pickers (outcomes #4/#5)

- Assignee/reviewer selectors list: live agents, idle existing agents, and "create from template" options — with clear status badges (running / idle / not-started / template).
- Use shared `AgentSelect` with `debugId` per AGENTS.md.

---

## 6. Contract / API / schema change checklist (authoritative)

Each item is a concrete edit target so implementation has zero ambiguity.

Identity:
- [ ] `agent_generated_instance_id` — drop project from id (`agent_store.odin:181`).
- [ ] `derive_agent_class` — stop deriving role from `@`; return template role instead, or delete callers (`registry.odin:507`).
- [ ] `valid_agent_instance_id` — allow project-free slugs; keep operator/user_proxy reserved (`registry.odin:527`).
- [ ] `conversation_id_for_instance` → `_for_run(agent, chain, project)` and update all callers.

Records:
- [ ] Remove `project_id/run_dir/current_task_*/last_needed_*` from `Agent_Instance_Record` (`agent_store.odin:19`); add `default_provider_profile`, `default_model_tier`.
- [ ] Add `Agent_Run_Record` (persisted) or extend in-memory `Agent_Record` (registry) with durable run context (§2.2).
- [ ] Update event JSON read/write in `agent_store.odin` (drop moved fields; bump event schema; since no compat, no dual-read needed).

Assignment:
- [ ] Soften `task_agent_instance_allowed_for_chain` to auto-associate (`task_service.odin:985`).
- [ ] Define queue-vs-reject for busy live agent using `task_active_slot_blocker` (`task_queries.odin:183`), return `queued_behind_task_id`.
- [ ] Start path: read run `project_id` from chain, not identity (`agents_start.odin:242`); handle unchained-task/no-project tiebreaks.
- [ ] Persist association records (new store) and derive roster from them.

Memory (outcome #2):
- [ ] Add `target_agent_instance_id` to `Memory_Event`, `Memory_Record`, `Memory_List_Request` (`memory_provider.odin`).
- [ ] Remove `agent_instance_id` from blocked legacy keys; wire the new field through propose/list/apply (`memory_service.odin:20`).
- [ ] DB migration: add column + index (`memory_db_service.odin:49,68`).
- [ ] Matching + precedence in `memory_record_applies` / `memory_record_matches_filters`.
- [ ] Validation that the referenced agent exists.

Provider:
- [ ] Replace `"pi"` template seed with a runnable profile or empty (`agent_template_db_service.odin`).
- [ ] Implement resolution order §2.4 in the launch path.

UI:
- [ ] Create Agent modal + button + debug ids.
- [ ] Per-agent memory control + debug ids.
- [ ] Assignment pickers show live/idle/template with badges.

---

## 7. Phased delivery (sequenced so each phase is testable)

Phase 0 — Identity decoupling
- Project-free ids, role-from-template, conversation-per-run. Reset agent store (documented).
- Exit: create an agent with only name+role; it has no project; it validates and lists.

Phase 1 — Runtime split + provider resolution
- Split identity/run records; start path takes project from chain/request; deterministic provider/tier.
- Exit: same agent runs in project A, then project B, without mutating identity.

Phase 2 — Per-agent memory
- Contract + DB + service + validation + precedence.
- Exit: add a memory to agent X; it appears in X's bootstrap only, never in agent Y's.

Phase 3 — Flexible assignment + associations
- Remove team gate; auto-associate; queue-on-busy; roster derived from associations.
- Exit: assign a task to an idle never-run agent (inherits chain+project on launch); assign/review with a live non-team agent.

Phase 4 — UI
- Create Agent button, per-agent memory control, assignment pickers with badges + debug ids.
- Exit: full flow via UI with debug-api-driven test.

Phase 5 — Team reframe
- Team kind → staffing template; roster from associations; drop/relegate team tables.
- Exit: new chains still scaffold; manual assignment needs no team membership.

---

## 8. Open questions now resolved (was §7)

- Multi-chain concurrency: **v1 = one active run per agent** (§2.5). Concurrent runs = future work.
- Memory scope: **add per-agent dimension** (§2.6); project/chain/task remain runtime context injected at bootstrap; project is not identity.
- "Eligible agent": exists + non-archived + not the reviewer/assignee conflict + (for immediate run) idle; busy agents queue.
- `user_proxy`/operator: reserved review/user identities, excluded from runnable rosters; only ids allowed to keep `@`.
- Teams persistence: roster from associations; team tables kept only if scaffold generation needs them, else removed.

## 9. Risks / things that will bite if not ironed out

1. **Store reset vs migration** — decide and document; a half-migrated `instance-events.jsonl` with `name@project` ids will silently keep the old coupling.
2. **Conversation-id change breaks existing message threads** — acceptable (no compat), but message provider + UI must read the new id consistently or history "disappears."
3. **Provider `"pi"` seed** — if not fixed, every create-from-template + run fails at launch; easy to miss because template creation succeeds.
4. **Queue semantics for busy agents** — if left undefined, assigning to a live busy agent either wrongly rejects (breaks outcome #5) or spawns a second run (breaks §2.5). Must return an explicit `queued_behind_task_id`.
5. **Unchained/no-project tasks** — define the error/degrade path or assignment will null-deref project lookups.
6. **Per-agent memory precedence** — without a defined order, an agent could get contradictory role vs instance memories; specify most-specific-wins.
7. **Roster derivation performance** — computing roster from associations + live runs on every chain view; ensure it's indexed, not O(agents×tasks) per request.
8. **Reserved-id enforcement** — after allowing project-free slugs, make sure `operator@local`/`user_proxy` can't be created via the new create button.

## 10. Summary

Target model (locked):

```text
Agents are independent identities (name + role), no project in the id.
Memory can target a single agent instance (new dimension), plus role/project/team as before.
A Run binds agent + project(from chain) + chain + task + run_dir + token + tmux.
Assignment works for any non-archived agent; idle never-run agents inherit chain+project on launch; live agents can be picked directly.
One active run per agent in v1; extra assignments queue.
Team kinds are staffing scaffolds, not assignment gates.
```

This delivers the five product outcomes with a single, unambiguous implementation path and calls out every place the current code must change.
