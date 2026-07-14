# Flexible Agent Runtime Model — Phase-wise Breakdown

Companion to `flexible-agent-runtime-model.md`. This is the execution plan: each phase is
independently shippable, testable, and ends with a concrete acceptance check. Task IDs are
stable references for task-chain assignment. No backward compatibility is required.

Legend: **file targets** are the exact edit sites from the design doc's §6 checklist.

---

## Phase 0 — Identity guards (compatibility-preserving)

Goal: keep the `agent_id@project` instance-id shape; add reserved-id safety and project-free
`agent_id` slug generation. (No project removal, no conversation change.)

### Tasks — DONE in commit on `teams-v2`
- **P0-1 Project-free `agent_id` slug.** `agent_generated_instance_id(name)` returns a project-free
  slug (the `agent_id`); the instance id is composed as `agent_id@project` at bind time.
  `src/daemon/agent_store.odin`.
- **P0-2 Reserved ids.** `agent_instance_id_is_reserved` (`operator@local`, `user_proxy`);
  `/agents/create` rejects them. `src/daemon/registry.odin`, `agents_start.odin`.
- **P0-3 Validation tolerant.** `valid_agent_instance_id` accepts the `agent_id@project` shape and
  bare slugs. `src/daemon/registry.odin`.

### Follow-up (revisit in P1)
- Restore explicit `agent_id@project` **composition** at launch/bind (currently the slug is used
  directly when no project is supplied).
- Keep `conversation_id_for_instance` **per-instance** (revert the exploratory `_for_run` variant),
  since one instance intentionally serves many chains.

### Acceptance
- Create by name+role → a project-free `agent_id`; reserved ids rejected; daemon/wrapper/ctl build.

---

## Phase 1 — `Agent_Id_Record` + provider resolution

Goal: introduce the durable identity tier above the instance; instance keeps its runtime binding
(Rule A); provider/tier resolves deterministically.

### Tasks
- **P1-1 Durable identity store.** Add `Agent_Id_Record` (`agent_id`, `display_name`,
  `template_id`, `default_provider_profile`, `default_model_tier`, `state`, timestamps, `order`)
  with its own event log/DB. `src/daemon/agent_store.odin` (+ new file if cleaner).
- **P1-2 Back-reference + backfill.** Add `agent_id` field to `Agent_Instance_Record`; on start,
  backfill an `Agent_Id_Record` for every distinct `@`-prefix in existing instance events.
- **P1-3 Keep instance runtime fields.** `project_id`, `run_dir`, `provider_profile`,
  `model_tier`, `current_task_*` stay on the instance (per-(agent,project) binding, Rule A).
- **P1-4 Composition + conversation.** Compose `agent_id@project` at launch; keep
  `conversation_id_for_instance` per-instance.
- **P1-5 Provider/tier resolution order** (request → instance → agent_id default → template →
  config). Implement in the launch path; ensure a runnable profile is selected.
- **P1-6 Fix template provider seed.** Replace `"pi"` with a runnable profile (e.g. `Claude Code`)
  or empty. `src/daemon/agent_template_db_service.odin` seeding.
- **P1-7 Create/list surface `agent_id`.** `/agents/create` creates/links an `Agent_Id_Record`;
  `/agents` list and record JSON expose `agent_id`.

### Acceptance
- One `agent_id` runs in project A and project B as two instances sharing durable defaults/persona.
- Create-from-template + immediate start succeeds (no `"pi"` launch failure).
- Existing instance events backfill an `Agent_Id_Record` on daemon start.

### Risks
- Backfill must be idempotent across restarts.
- Managed run_dir layout stays `<agent_run_dir>/<safe-project>/<safe-agent-instance>`.

---

## Phase 2 — Per-agent memory (scoped to `agent_id`)

Goal: memories can target one durable `agent_id` and apply to all its project-instances only.

### Tasks
- **P2-1 Contract.** Add `target_agent_id` to `Memory_Event`, `Memory_Record`,
  `Memory_List_Request`. `src/contracts/memory_provider.odin`.
- **P2-2 Unblock + wire field.** Remove `agent_instance_id` from blocked legacy keys; accept the
  canonical `target_agent_id` through propose/list/apply. `src/daemon/memory_service.odin:20`.
- **P2-3 DB migration.** `ALTER TABLE memories ADD COLUMN target_agent_id TEXT NOT NULL
  DEFAULT '';` extend `idx_memories_targets`; bump user_version. `src/daemon/memory_db_service.odin:49,68`.
- **P2-4 Matching + precedence.** `memory_record_applies` / `memory_record_matches_filters`:
  a per-agent memory returns only when the requesting instance's `agent_id` matches; precedence
  most-specific-first (agent_id → project → role → team-kind → global) with dedup.
- **P2-5 Validation.** `target_agent_id` must reference an existing non-archived `Agent_Id_Record`.
- **P2-6 Bootstrap injection.** Inject `agent_id`-scoped memories at instance bootstrap for that
  agent only.

### Acceptance
- Add a memory to agent_id X → appears in X's instances' bootstrap, never in agent Y's.
- List with agent filter returns only that agent's memories plus applicable broader scopes.
- Sending a per-agent memory no longer returns HTTP 400.

### Risks
- Precedence ambiguity → contradictory role vs instance memories (specify most-specific-wins).

---

## Phase 3 — Flexible assignment + associations + Rule A restart

Goal: assign to any non-archived agent; if the assignee has no live session, the task system
relaunches it from its durable instance record into its home project (Rule A); live agents can be
picked directly. Coding tasks guardrailed to `instance.project == chain.project`.

### Tasks
- **P3-1 New association store.** Persist `Agent_Chain_Association` records
  (`association_id, agent_instance_id, project_id, chain_id, task_id, association_kind,
  created_unix_ms, last_active_unix_ms`).
- **P3-2 Soften membership gate.** `task_agent_instance_allowed_for_chain` no longer hard-fails;
  auto-creates association for non-member eligible agents. `src/daemon/task_service.odin:985`
  (and callers `:99,105,892,949`).
- **P3-3 Queue-on-busy.** Reinterpret `task_active_slot_blocker`: assignment to a busy agent is
  accepted but the task queues; return `queued_behind_task_id`. `src/daemon/task_queries.odin:183`.
- **P3-4 Inherit chain+project on assign.** On assignment to idle/never-run agent, record intent
  `{project_id := chain.project_id, chain_id := task.chain_id, task_id}`; launch reads project
  from chain. Define tiebreaks: unchained task → require explicit `project_id` else
  `"project_required_for_unchained_task"`; chain without project → project-less run.
- **P3-5 Reviewer selection.** Allow any live/eligible non-team agent as reviewer; keep
  non-self/non-user constraints (`task_service_pick_non_user_reviewer`).
- **P3-6 Derived roster.** Compute chain roster from associations + live runs (+ optional
  template suggestions); replace team_members as source of truth.

### Acceptance
- Assign a task to an idle never-run agent → on launch it runs in the chain's project/chain.
- Assign/review with a live non-team agent succeeds (auto-associated).
- Assigning to a busy live agent returns `queued_behind_task_id`, does not spawn a 2nd run.

### Risks
- Roster derivation O(agents×tasks) per request — index associations.
- Null project lookups for unchained/no-project tasks — cover the tiebreak paths.

---

## Phase 4 — UI

Goal: user can do the whole flow from the UI; every control has a `data-debug-id`.

### Tasks
- **P4-1 Create Agent button + modal.** Fields: name (required), role/template (required),
  optional provider, optional tier. No project field. Calls `POST /agents/create`.
  Debug ids: `agents-new-agent-btn`, `create-agent-name-input`, `create-agent-template-select`,
  `create-agent-provider-select`, `create-agent-tier-select`, `create-agent-cancel-btn`,
  `create-agent-submit-btn`.
- **P4-2 Per-agent memory control.** "Add memory (this agent only)" on agent detail sheet;
  memory page agent filter. Debug ids: `agent-memory-add-btn-${agentId}`,
  `agent-memory-body-textarea`, `agent-memory-submit-btn`, `memory-filter-agent-select`.
- **P4-3 Assignment pickers.** Assignee/reviewer selectors list live/idle/never-run/template
  options with status badges; use shared `AgentSelect` with `debugId`.
- **P4-4 Registry update.** Add all new ids to the AGENTS.md per-component registry table.

### Acceptance
- Full create → add per-agent memory → assign → run flow works via UI.
- Debug API can drive each new control by `data-debug-id`.

### Risks
- Missing debug ids block automated verification — enforce in review.

---

## Phase 5 — Team reframe

Goal: team kind becomes a staffing scaffold, not an assignment gate.

### Tasks
- **P5-1 Rename concept.** `team_kind` → `chain_staffing_template` in code/labels; used only to
  suggest/generate default agents + scaffold tasks at chain creation.
- **P5-2 Generated agents are normal.** Template-generated agents use the same create path as the
  button; no special-casing.
- **P5-3 Roster source.** Roster derives from associations (Phase 3); drop `team_members` as the
  assignment gate. Decide: delete team tables, or keep only for scaffold history.
- **P5-4 Cleanup.** Remove now-dead membership checks and migration shims.

### Acceptance
- New chains still scaffold default staffing.
- Manual/free-form assignment works with zero team membership.
- No code path treats team membership as an assignment requirement.

### Risks
- Removing team tables while scaffold generation still reads them — sequence P5-3 after P5-2.

---

## Cross-phase dependency graph

```text
P0 (identity) ──▶ P1 (runtime split) ──▶ P3 (assignment) ──▶ P4 (UI) ──▶ P5 (team reframe)
                      │                        ▲
                      └────────▶ P2 (memory) ──┘   (P2 depends on P0 ids; P4 surfaces P2+P3)
```

- P0 must land first (reserved-id guard + project-free `agent_id` slug).
- P2 can proceed in parallel with P1 once P0 is in (memory only needs stable agent ids).
- P3 depends on P1 (run record + chain-sourced project).
- P4 depends on P2 + P3 (surfaces both).
- P5 depends on P3 (roster from associations).

## Definition of done (whole feature)

1. Create Agent button: name + role only, no project. ✔ P0/P1/P4
2. Per-agent memory applies to that agent only. ✔ P2/P4
3. Same agent runs in any project. ✔ P1
4. Assign to idle/never-run agent → task system restarts it (Rule A, home project). ✔ P3
5. Pick a live instance for assignment/review. ✔ P3/P4
