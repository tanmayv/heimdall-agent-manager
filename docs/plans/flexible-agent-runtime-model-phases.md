# Flexible Agent Runtime Model — Phase-wise Breakdown

Companion to `flexible-agent-runtime-model.md`. This is the execution plan: each phase is
independently shippable, testable, and ends with a concrete acceptance check. Task IDs are
stable references for task-chain assignment. No backward compatibility is required.

Legend: **file targets** are the exact edit sites from the design doc's §6 checklist.

---

## Phase 0 — Identity decoupling

Goal: an agent identity is `name + role`, with no project baked into the id or role parsing.

### Tasks
- **P0-1 Decide store strategy.** Choose fresh-reset of the agent store vs one-shot rename.
  Document the choice in the PR. Recommended: fresh reset in dev; delete
  `~/.config/heimdall/**/agents/instance-events.jsonl` (and templates DB stays).
- **P0-2 Project-free id generation.** `agent_generated_instance_id(name)` → slug of name +
  short uniquifier; remove `project_id` param. `src/daemon/agent_store.odin:181`.
- **P0-3 Role from template, not `@`.** Remove `@`-splitting role semantics; role = template
  `role_hint`. Update/remove `derive_agent_class`. `src/daemon/registry.odin:507` and all callers
  (`lifecycle.odin:10,19`, `agents_start.odin:215,554`).
- **P0-4 Validation.** `valid_agent_instance_id` accepts project-free slugs `[a-zA-Z0-9-]`;
  keep `operator@local` / `user_proxy` as the only reserved `@` ids and reject creating them via
  create. `src/daemon/registry.odin:527`.
- **P0-5 Conversation per run.** Replace `conversation_id_for_instance` with
  `conversation_id_for_run(agent_instance_id, chain_id, project_id)`; update callers in
  `lifecycle.odin`, `agents_start.odin`.

### Acceptance
- Create an agent with only `name` + `role`; resulting `agent_instance_id` contains no project.
- `derive_agent_class`/`@`-parsing no longer referenced for role decisions (grep clean).
- Register/reconnect return a conversation id that varies by chain.

### Risks
- Half-migrated `name@project` ids silently preserve old coupling (P0-1 must be enforced).
- Conversation-id change detaches old message threads (acceptable; verify UI reads new id).

---

## Phase 1 — Runtime split + provider resolution

Goal: identity record no longer carries runtime; runs take project from chain/request; provider/tier resolve deterministically.

### Tasks
- **P1-1 Slim identity record.** Remove `project_id`, `run_dir`, `current_task_id`,
  `current_task_since`, `last_needed_at_unix_ms` from `Agent_Instance_Record`; add
  `default_provider_profile`, `default_model_tier`. `src/daemon/agent_store.odin:19`.
- **P1-2 Event schema.** Update `Agent_Instance_Event` read/write JSON to drop moved fields;
  bump event schema (no dual-read needed). `agent_store.odin` (`*_event_json`, `*_from_json`,
  `*_apply_event`, `*_clone`).
- **P1-3 Add run record.** New persisted `Agent_Run_Record` (or extend in-memory `Agent_Record`
  in `registry.odin`) with `project_id/chain_id/task_id/run_dir/provider_profile/model_tier/
  agent_token/tmux_*/conversation_id/status/current_task_*/timestamps`. Keep the in-memory
  socket boundary rule from `agent_store.odin` header.
- **P1-4 Start path reads project from chain/request, not identity.**
  `src/daemon/agents_start.odin:242` and the `/agents/start` handler; `/agents/associate`
  (`agents_start.odin:127`) becomes a run-context setter, not identity mutation.
- **P1-5 Provider/tier resolution order** (request → identity default → template default →
  config default). Implement in the launch path; ensure runnable profile is selected.
- **P1-6 Fix template provider seed.** Replace `"pi"` with a runnable profile (e.g. `Claude Code`)
  or empty. `src/daemon/agent_template_db_service.odin` seeding.

### Acceptance
- Same agent runs in project A, then project B, with identity record unchanged between runs.
- Create-from-template + immediate start succeeds (no `"pi"` launch failure).
- Run record shows correct project/chain/task/run_dir per launch.

### Risks
- Duplicating live socket state into the store (forbidden) — keep boundary.
- Managed run_dir layout must use the chain's project (`<agent_run_dir>/<safe-project>/<safe-agent>`).

---

## Phase 2 — Per-agent memory

Goal: memories can target one specific agent instance and apply only to it.

### Tasks
- **P2-1 Contract.** Add `target_agent_instance_id` to `Memory_Event`, `Memory_Record`,
  `Memory_List_Request`. `src/contracts/memory_provider.odin`.
- **P2-2 Unblock + wire field.** Remove `agent_instance_id` from blocked legacy keys; accept the
  canonical `target_agent_instance_id` through propose/list/apply. `src/daemon/memory_service.odin:20`.
- **P2-3 DB migration.** `ALTER TABLE memories ADD COLUMN target_agent_instance_id TEXT NOT NULL
  DEFAULT '';` extend `idx_memories_targets`; bump user_version. `src/daemon/memory_db_service.odin:49,68`.
- **P2-4 Matching + precedence.** `memory_record_applies` / `memory_record_matches_filters`:
  per-agent memory returns only for the matching run's agent; precedence most-specific-first
  (agent → project → role → team-kind → global) with dedup.
- **P2-5 Validation.** `target_agent_instance_id` must reference existing non-archived agent
  (mirror `memory_project_id_known`).
- **P2-6 Bootstrap injection.** Ensure per-agent memories are injected at run bootstrap for that
  agent only.

### Acceptance
- Add a memory to agent X → appears in X's bootstrap, never in agent Y's.
- List with agent filter returns only that agent's memories plus applicable broader scopes.
- Sending a per-agent memory no longer returns HTTP 400.

### Risks
- Precedence ambiguity → contradictory role vs instance memories (specify most-specific-wins).

---

## Phase 3 — Flexible assignment + associations

Goal: assign to any non-archived agent; idle never-run agents inherit chain+project on launch; live agents can be picked directly.

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

- P0 must land first (every later phase assumes project-free ids).
- P2 can proceed in parallel with P1 once P0 is in (memory only needs stable agent ids).
- P3 depends on P1 (run record + chain-sourced project).
- P4 depends on P2 + P3 (surfaces both).
- P5 depends on P3 (roster from associations).

## Definition of done (whole feature)

1. Create Agent button: name + role only, no project. ✔ P0/P1/P4
2. Per-agent memory applies to that agent only. ✔ P2/P4
3. Same agent runs in any project. ✔ P1
4. Assign to idle/never-run agent → inherits chain+project on launch. ✔ P3
5. Pick a live instance for assignment/review. ✔ P3/P4
