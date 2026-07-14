# Plan: Flexible Agent Runtime Model

Status: Ready-for-implementation design (revised after code audit; 3-tier identity + Rule A)
Scope: Heimdall agent identity, per-agent memory, runtime context, task assignment, and team/template model.
Compatibility: **High compatibility by design.** `agent_instance_id` keeps its existing `agent_id@project` shape and its 1:1 relationship to a live session, so wrapper/tmux/registry/conversation code is largely preserved. The change is *additive*: a new durable `agent_id` identity above the instance, a new per-agent memory dimension, and association records for chain involvement. DB/schema/contract additions are allowed; we avoid changing the instance-id primary-key shape.

## Identity model at a glance (3-tier, Rule A)

```text
agent_id            durable identity  = name + role/template + defaults + MEMORY target
   │  1
   └──< agent_instance_id   runtime binding = agent_id @ HOME project   (NO chain in id)
            │  1:1
            └── one live session (tmux pane, token, ONE conversation stream)
                     └──< serves MANY task chains concurrently (via associations)
```

Invariants (locked):
- `agent_instance_id = agent_id @ project` and maps to **at most one** live session (1:1). Never spawn a second session for the same instance-id; reuse it.
- Chain is **not** part of the instance id; a running instance can service multiple chains concurrently through association records.
- **Rule A (home is authoritative):** the project in the instance id is the agent's *home* (run_dir, repo anchors, tools/creds). On restart, the assignee's stored `agent_instance_id` is relaunched into its home project — no re-resolution, no auto-clone.
- Guardrail: **coding/implementation tasks require `assignee_instance.project == chain.project`**; review/research/advisory tasks may be cross-project.
- Per-agent memory targets `agent_id` (applies to all of that agent's project-instances).

---

## 0. Product outcome this plan must guarantee

The concrete end-state the user wants:

1. **Agent create button.** Create an `agent_id` by giving it a name and picking a predefined role (template). No project required at creation time.
2. **Per-agent memory.** Create memories scoped to a specific `agent_id`; they apply to that agent (all its project-instances) only.
3. **Run anywhere.** The same `agent_id` can run in any project as `agent_id@project`; project is the instance's home, not part of the durable identity.
4. **Assign to an idle/never-run agent.** Assigning a task to an agent that is not running is allowed; if it has no live session the task system relaunches it from its durable instance record (Rule A: into its home project).
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

Guiding principle:

> Templates propose agents. An `agent_id` is the durable identity. An `agent_instance_id = agent_id@project` is the runtime binding (home project) with a 1:1 live session. Assignments define chain involvement; one instance serves many chains.

Binding decisions follow.

### 2.1 Three-tier identity (compatibility-preserving)

Decision: introduce a durable `agent_id` **above** the existing instance id, and preserve the instance-id shape.

- **`agent_id`** — NEW durable identity. Project-free slug from the display name (uniquified). Examples: `coder-alice`, `reviewer-smart`, `researcher-7`. This is the thing the "Create Agent" button creates, the memory target, and the carrier of template/persona + defaults.
- **`agent_instance_id = agent_id @ project`** — PRESERVED shape (`coder-alice@project-1`). This remains the runtime id used by wrapper/tmux/registry/conversation. Chain is **not** in the id.
- `derive_agent_class(id)` (split on `@`) is **kept**, but its result is now the **`agent_id`**, which resolves to a stored `Agent_Id_Record` (previously the prefix was an ephemeral, unstored "class").
- `valid_agent_instance_id`: `agent_id@project` where both parts are `[a-zA-Z0-9-]`. `operator@local` and `user_proxy` remain reserved and are not creatable.
- **1:1 invariant:** an `agent_instance_id` maps to at most one live session. Launch guard: if a live session exists for the instance-id, reuse it; never spawn a second (enforced in `agent_runtime_tracker_try_begin_launch` + wrapper's existing exact-window check).

Migration: the instance-id shape is unchanged, so existing `instance-events.jsonl` rows remain valid. We backfill an `Agent_Id_Record` for each distinct `agent_id` (the `@`-prefix) seen. Document a one-shot backfill on daemon start.

### 2.2 Records: durable identity vs runtime binding

`Agent_Id_Record` (NEW — durable identity, one per agent):

- `agent_id`, `display_name`, `template_id`,
  `default_provider_profile`, `default_model_tier`,
  `state` (active/archived), `created_unix_ms`, `updated_unix_ms`, `archived_at_unix_ms`, `order`.

`Agent_Instance_Record` (PRESERVED — one per `(agent_id, project)`, the runtime binding):

- `agent_record_id`, `agent_instance_id`, **`agent_id` (NEW back-reference)**,
  `project_id` (the home project), `run_dir`,
  `provider_profile`, `model_tier` (resolved for this instance),
  `current_task_id`, `current_task_since`, `last_needed_at_unix_ms`,
  `state`, timestamps, `order`.

The live socket/pane/heartbeat state stays **in-memory** on `Agent_Record` in `registry.odin` (the boundary rule from `agent_store.odin` header stays). We do **not** introduce a separate persisted run record; the instance record already is the per-(agent,project) runtime binding, and Rule A means it is authoritative for restart. Chain-level involvement lives in association records (§3.4), not on the instance.

### 2.3 Conversation id stays per-instance (compatibility-preserving)

Decision: **keep one conversation stream per `agent_instance_id`.** Because a running instance intentionally serves multiple chains, its conversation is the instance's stream, not per-chain. `conversation_id_for_instance(agent_instance_id)` is retained as-is. (The earlier per-chain proposal is dropped; it conflicts with "runtime not tied to a chain.")

### 2.4 Provider/tier resolution order (deterministic)

When launching an instance, resolve provider profile and tier in this exact order (first non-empty wins):

1. explicit value on the start/assign request,
2. the instance record's `provider_profile` / `model_tier`,
3. the `agent_id`'s `default_provider_profile` / `default_model_tier`,
4. the template's `default_provider_profile` / `suggested_model_tier`,
5. config `[wrapper].default_agent` / global default tier.

Note on the `"pi"` template seed: in *this* repo `pi` **is** a runnable provider (`config.toml` `[wrapper.agent-cmd.pi]`, `default_agent = "pi"`), so the seed is valid and is intentionally left unchanged. The earlier audit assumed the AGENTS.md example providers (`Claude Code`/`claude`) were the only runnable ones — that was wrong for the checked-in config. The real requirement is only that the resolution order above always yields a profile that exists in `[wrapper.agent-cmd.*]`; if a deployment removes `pi`, seeds must point at a profile it does define.

### 2.5 Concurrency: one active task per instance; one session per instance

Decision:

- **One live session per `agent_instance_id`** (the 1:1 invariant, §2.1).
- **One active task at a time per instance** for execution (existing `task_active_slot_blocker`), but the single session may hold multiple *assigned* chains/tasks and pick the next via `tasks next`.
- Assigning to a busy instance → task accepted, queued for that instance; response includes `queued_behind_task_id`. Do not spawn a second session; do not reject.

### 2.6 Restart on failure (Rule A — home is authoritative)

Decision: the task stores `assignee_agent_instance_id` (`agent_id@project`) as the durable restart key. When a task needs attention and its assignee has **no live session**:

1. Look up the durable `Agent_Instance_Record` for that instance-id (home project, run_dir, provider, tier) — and through `agent_id`, its template/persona.
2. If present and non-archived, `try_begin_launch(instance_id)` (coalesced → restart exactly once) and relaunch into its **home project**; regenerate token/pane/conversation.
3. If archived/missing, do **not** hot-loop; raise an attention item (`assignee_unavailable`) for reassignment.
4. Backoff + cap restart attempts (build on `agent_startup_janitor` + `startup_failed`).

**Rule A guardrail:** because restart always uses the assignee's home project, **coding/implementation tasks require `assignee_instance.project == chain.project`** at assignment time (else error `assignee_project_mismatch`). Review/research/advisory task types may be assigned cross-project (the agent advises from its home run_dir). This keeps restart deterministic while keeping hands-on code work in the right worktree.

### 2.7 Per-agent memory (new targeting dimension, scoped to `agent_id`)

Decision: add `target_agent_id` as a first-class memory targeting dimension, **alongside** `target_team_kind`, `target_role`, `target_project_id`.

- Memory is scoped to the durable **`agent_id`**, so it applies to all of that agent's project-instances (a specialist keeps its expertise everywhere it runs).
- Remove `agent_instance_id` from the blocked legacy-keys list in `memory_service.odin:20`; introduce canonical field `target_agent_id`.
- Add DB column + index: `ALTER TABLE memories ADD COLUMN target_agent_id TEXT NOT NULL DEFAULT '';` and extend `idx_memories_targets`.
- Extend contract structs in `src/contracts/memory_provider.odin`: `Memory_Event`, `Memory_Record`, `Memory_List_Request` all get `target_agent_id`.
- Matching: a per-agent memory applies only when the requesting instance's `agent_id` matches. Bootstrap injection precedence (most specific first): agent-id → project → role → team-kind → global. Document dedup/ordering.
- Validation: `target_agent_id` must reference an existing non-archived `Agent_Id_Record`.

This is the key schema change for outcome #2 and must land before the UI "add memory to this agent" control.

---

## 3. Assignment & runtime binding (outcomes #4 and #5)

### 3.1 Remove the team-membership gate as a hard wall

- Replace `task_agent_instance_allowed_for_chain` hard-fail with a soft rule:
  - Allowed if agent instance exists and is non-archived.
  - If not currently associated with the chain, **auto-create an association record** (`association_kind = ad_hoc` or `assigned`) instead of rejecting.
- Keep these protections (unchanged): assignee ≠ reviewer, reviewer/assignee separation, `user_proxy`/operator reviewer rules, archived-agent rejection.
- `task_active_slot_blocker` stays but is reinterpreted per §2.5 (queue, don't hard-reject at assignment time; still gate `tasks next` promotion).

### 3.2 Assign to a never-run / idle agent (Rule A: home is authoritative)

Exact rule for outcome #4:

1. You assign work by picking an **`agent_id`** (or a concrete instance). The task's chain has a `project_id`.
2. The effective assignee instance is resolved as `agent_id @ instance.home_project`. Under **Rule A the instance's home project is authoritative** — we do NOT rebind it to the chain's project.
3. **Guardrail (§2.6):** if the task type is coding/implementation, require `assignee_instance.project == chain.project`, else reject with `assignee_project_mismatch`. Review/research/advisory task types may be cross-project.
4. If the instance does not exist yet, it is auto-created as `agent_id@project` (project = the picked instance's project, or for the guardrailed coding case, the chain's project). `run_dir` follows managed layout `<agent_run_dir>/<safe-project>/<safe-agent-instance>`; per-agent `run_dir` override still wins.
5. On launch (manual or via nudge/restart), the instance runs in **its own home project** — deterministic and identical to the restart path (§2.6). This removes the `agents_start.odin:242` ambiguity: project comes from the instance record, never re-derived per assignment.

Tiebreaks:

- Standalone task (no chain): assignment requires the picked instance to already carry a project; else error `project_required_for_unchained_task`.
- Chain has no project: only cross-project-eligible (review/research/advisory) assignments allowed; coding assignment errors `chain_missing_project`.

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

- On an agent's detail/side sheet: "Add memory (this agent only)" control that sends `target_agent_id` (§2.7).
- Memory management page gains an agent filter.
- `data-debug-id`s: `agent-memory-add-btn-${agentId}`, `agent-memory-body-textarea`, `agent-memory-submit-btn`, plus a filter select `memory-filter-agent-select`.

### 5.3 Assignment pickers (outcomes #4/#5)

- Assignee/reviewer selectors list: live agents, idle existing agents, and "create from template" options — with clear status badges (running / idle / not-started / template).
- Use shared `AgentSelect` with `debugId` per AGENTS.md.

---

## 6. Contract / API / schema change checklist (authoritative)

Each item is a concrete edit target so implementation has zero ambiguity.

Identity (3-tier, compatibility-preserving):
- [ ] `agent_generated_instance_id` — generate a project-free **`agent_id`** slug; instance id remains `agent_id@project` composed at bind time (`agent_store.odin:181`).
- [ ] `derive_agent_class` — keep `@`-split, but treat the result as **`agent_id`** that resolves to an `Agent_Id_Record` (`registry.odin:507`).
- [ ] `valid_agent_instance_id` — keep `agent_id@project` shape; operator/user_proxy reserved + non-creatable (`registry.odin:527`). *(Done in P0 commit — revisit to restore `@` composition.)*
- [ ] `conversation_id_for_instance` — **keep per-instance** (revert the per-run variant); one stream per instance across chains.

Records:
- [ ] Add `Agent_Id_Record` store (durable identity: template, defaults, state) + backfill from existing instance `@`-prefixes.
- [ ] Add `agent_id` back-reference to `Agent_Instance_Record`; keep `project_id/run_dir/current_task_*/provider_profile/model_tier` (they are the per-(agent,project) runtime binding under Rule A).
- [ ] Live socket/pane/heartbeat stays in-memory on `registry.odin` `Agent_Record` (no new persisted run record).

Assignment + restart:
- [ ] Soften `task_agent_instance_allowed_for_chain` to auto-associate (`task_service.odin:985`).
- [ ] Define queue-on-busy using `task_active_slot_blocker` (`task_queries.odin:183`), return `queued_behind_task_id`.
- [ ] Rule A restart: nudge/tracker relaunches assignee from its durable instance record into its home project; coalesced restart-once; backoff + `assignee_unavailable` attention item (`task_nudge_scheduler.odin`, `agent_runtime_tracker.odin`, `agent_startup_janitor.odin`).
- [ ] Coding-task guardrail: `assignee_instance.project == chain.project` else `assignee_project_mismatch`.
- [ ] Persist association records (new store) and derive roster from them.

Memory (outcome #2):
- [ ] Add `target_agent_id` to `Memory_Event`, `Memory_Record`, `Memory_List_Request` (`memory_provider.odin`).
- [ ] Remove `agent_instance_id` from blocked legacy keys; wire `target_agent_id` through propose/list/apply (`memory_service.odin:20`).
- [ ] DB migration: add `target_agent_id` column + index (`memory_db_service.odin:49,68`).
- [ ] Matching + precedence in `memory_record_applies` / `memory_record_matches_filters` (agent-id most specific).
- [ ] Validation that the referenced `agent_id` exists.

Provider:
- [x] Resolution order §2.4 implemented in the launch path (`agent_resolve_provider_profile` / `agent_resolve_model_tier`, `agent_id_store.odin`; wired in `agents_start.odin` manual start).
- [x] `"pi"` seed verified runnable in this repo's config — left unchanged (see §2.4 note).

UI:
- [ ] Create Agent modal + button + debug ids.
- [ ] Per-agent memory control + debug ids.
- [ ] Assignment pickers show live/idle/template with badges.

---

## 7. Phased delivery (sequenced so each phase is testable)

Phase 0 — Identity decoupling
- Reserved-id rejection; instance id keeps `agent_id@project` shape; `agent_id` slug generation. (Done: reserved-id + validation; **revisit** to restore `@` composition and per-instance conversation.)
- Exit: create an agent by name+role → durable `agent_id`; running it in a project yields `agent_id@project`.

Phase 1 — `Agent_Id_Record` + provider resolution
- Add durable identity store + `agent_id` back-reference on instance; backfill from existing `@`-prefixes; deterministic provider/tier; fix `"pi"` seed.
- Exit: same `agent_id` runs in project A and project B as two instances sharing one durable identity/defaults.

Phase 2 — Per-agent memory (scoped to `agent_id`)
- Contract + DB + service + validation + precedence.
- Exit: add a memory to `agent_id` X; it appears in X's instances' bootstrap only, never in Y's.

Phase 3 — Flexible assignment + associations + Rule A restart
- Remove team gate; auto-associate; queue-on-busy; roster from associations; Rule A restart-from-durable-record with coding-task project guardrail.
- Exit: assign a task to an idle/never-run agent; kill it → task system relaunches it into its home project; assign/review with a live non-team agent.

Phase 4 — UI
- Create Agent button, per-agent memory control, assignment pickers with badges + debug ids.
- Exit: full flow via UI with debug-api-driven test.

Phase 5 — Team reframe
- Team kind → staffing template; roster from associations; drop/relegate team tables.
- Exit: new chains still scaffold; manual assignment needs no team membership.

---

## 8. Open questions now resolved

- Identity: **3-tier** — durable `agent_id` → `agent_instance_id = agent_id@project` (1:1 live session) → many chains via associations (§2.1).
- Project reconciliation on restart: **Rule A** — home project is authoritative; assignee relaunches into its home; coding tasks guardrailed to `instance.project == chain.project` (§2.6).
- Multi-chain: one live **session** and one active **task** per instance; a session may hold multiple assigned chains and pick next via `tasks next` (§2.5).
- Memory scope: **`agent_id`** dimension (§2.7); project/chain/task remain runtime context injected at bootstrap.
- `user_proxy`/operator: reserved, non-creatable, excluded from runnable rosters; only ids allowed to keep `@` as a whole literal.
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

Target model (locked, 3-tier + Rule A):

```text
agent_id            = durable identity (name + role/template + defaults + memory target)
agent_instance_id   = agent_id@project = runtime binding, 1:1 with a live session, home project authoritative
                      one session serves many chains via association records
Memory targets agent_id (applies to all its project-instances).
Assignment works for any non-archived agent; picking an agent restarts/reuses its home-project instance.
Restart (Rule A): task stores agent_instance_id; if no live session, relaunch from the durable instance record into its home project (coalesced, backoff, attention item if archived).
Coding tasks guardrailed to instance.project == chain.project; review/research may be cross-project.
One live session + one active task per instance; extra assignments queue.
Team kinds are staffing scaffolds, not assignment gates.
```

This delivers the five product outcomes with a compatibility-preserving, unambiguous implementation path and calls out every place the code must change.
