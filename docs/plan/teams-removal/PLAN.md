# Plan: Remove Teams, Intrinsic Roles, and Per-Role Bootstrap

**Source analysis:** `reports/teams-removal-analysis.md`
**Decision:** Option B (scaffolds become editable skills). Teams deleted, intrinsic role fields
deleted, per-role prompt files replaced by seeded core skills; customization flows through the
memory/skills system.

## Ground rules (from the requester)

- **Single task chain**, phased.
- **No DB migration.** The user will **empty the DB** before running the new build. Every store
  may change shape freely; do not write migration/backfill code. (Bump/reset schema versions or
  just rely on the empty-DB assumption.)
- **Phase 0 is a discovery/audit task** that must enumerate every team/role/scaffold touchpoint
  so nothing is missed. **If anything is ambiguous or a decision is required, stop and involve
  the user** — do not guess.
- Includes **UI changes**.

## Target end state (invariants)

1. **The task is the authority on roles.** `assignee` / `lgtm_required` / `coordinator` /
   `subscriber` live on the task; no agent/identity/template carries a fixed role.
2. **No behavior keys on a built-in name.** Default agents + system singletons live in config as
   `agent_id`s; any can be swapped for a custom agent id without code changes.
3. **Customization lives in the memory/skills system.** Core skills ship as seeded approved
   memories; users tailor by proposing memories (optionally scoped to agent/project).
4. **Typed chains = a scaffold skill the coordinator runs** (Option B), not an in-daemon graph.

Ship 5 default durable agent ids: `conversation`, `guide`, `coordinator`, `worker`, `reviewer`
(all config-overridable).

---

## Phases

### Phase 0 — Discovery & decision gate (BLOCKS everything)
Audit the full surface before any deletion so nothing is missed.
- Enumerate every reference to: `team`, `team_id`, `Team_*`, `team_kind`, `team_service`,
  `role_key`, `agent_role`, `role_hint`, `agent_scope`, scaffold, `/teams`, `ham-ctl teams`,
  and the `scaffold-*` / `*_persona.md` / `*_instructions.md` prompt files.
- Produce an artifact: a checklist of touchpoints across daemon / wrapper / ctl / ui / docs /
  config / prompts, each mapped to the phase that handles it.
- Flag **open decisions** for the user (e.g. exact set of core skills, the `role → default
  agent id` map, whether `worker` reuses `coder` template or a new `worker` template,
  free-form `kind` vs fixed set). **Do not proceed past ambiguity — ask the user.**
- **Exit:** approved audit artifact + resolved decisions. Coordinator confirms scope with user.

### Phase 1 — Default agent identities + role→agent map
- Seed 5 durable `Agent_Id_Record`s on first boot (idempotent): `conversation`, `guide`,
  `coordinator`, `worker`, `reviewer`. Seed a `conversation` template if missing; decide
  `worker` template (per Phase 0).
- Add operator-configurable **`role → default agent id`** map (config + `ham-ctl agents
  defaults` read/set) used only at chain/scaffold time. `solo` reviewer → `user_proxy`.
- **Exit:** fresh daemon boots with the 5 ids; the map resolves each role to an id.

### Phase 2 — Remove intrinsic role fields
- Delete `agent_role` from `Agent_Id_Record`, `Agent_Instance_Record`, runtime `Agent_Record`
  and all JSON/events/clones.
- Delete `role_hint` from `Agent_Template_Record` and `agent_role_from_template()` (incl. the
  hardcoded `"lead" → "coordinator"` fixup).
- Replace `agent_role == "conversation"` with a durable-id / template check.
- Remove memory `target_role` (fold into `target_template_id`/`target_agent_id` per Phase 0).
- **Exit:** no stored role field anywhere; role is only on tasks. Build green.

### Phase 3 — De-hardcode agent selection (custom-agent safety)
- Remove hardcoded string checks that break custom agents (`template_id == "lead"`,
  `agent_id_ref == "coordinator" → "lead"`, scaffold `role_key → agent_template_id`, etc.).
- Move system singletons (`guide`, `memory_auditor`, `memory_reviewer`) into a **named config
  allowlist** of agent ids instead of scattered `== "guide"` literals.
- **Exit:** a custom agent id can be used for any slot (coordinator/assignee/reviewer/chat)
  with no code path matching a built-in name.

### Phase 4 — Bootstrap via core skills + on-demand memory
- Convert the ~13 role prompt files + shared rules into a small set of seeded core-skill/
  template memories (e.g. `task-workflow`, `review-and-evidence`, `coordinator-playbook`,
  `git-hygiene`, `contracts-first`, `testing-discipline`), applied to **all** agents.
- Wrapper `build_agents_md()` drops role/`is_coordinator` forks: shared Operating Rules inline
  + core skills on disk (read on demand) + task/chain/project/workspace context + applicable
  memories. Keep the coordinator playbook reliably available to whoever is the chain
  coordinator (by task/chain role, not identity).
- Template `persona`/`instructions` become optional/short (behavior now in skills).
- **Exit:** an empty-template agent is fully functional off core skills; no per-role injection.

### Phase 5 — Scaffolds as skills (Option B) + roster-free chain create
- Author `scaffold-*` skills (coding-feature, coding-bugfix, research, solo) as seeded memories:
  numbered `ham-ctl` recipes that resolve `{coordinator}/{worker}/{reviewer}` from the Phase 1
  map; task descriptions reuse existing scaffold guidance text.
- `POST /task-chains/create`: keep `kind`/`title`/`description`/`wants_vcs`/optional
  coordinator; **stop** calling `team_service_create_for_chain` and **stop** in-code scaffold
  expansion. Create chain + coordinator kickoff task pointing at the scaffold skill.
- Coordinator core skill instructs: on kickoff, run the applicable scaffold skill (keeps typed
  chains one-click).
- Delete `Team_Kind_Def.scaffolds`, `Team_Chain_Scaffold*`, `task_service_create_chain_scaffold`,
  `task_service_scaffold_*`, and `scaffold-*` description_key plumbing.
- **Exit:** `kind=coding` yields the same 5-task chain, produced by the coordinator via skill,
  no `teams.db`.

### Phase 6 — Delete the team store & surfaces
- Delete `team_db_service.odin`, `team_service.odin`, `team_http.odin`, `teams_v1_migration.odin`,
  and slim `team_kinds.odin` → `chain_kinds.odin` (kind label + wants_vcs + memory tags only).
- Remove `/teams`, `/teams/{id}`, `/teams/add-member` routes and `ham-ctl teams` family.
- Re-key boot lease from `chain.team_id` → `chain.chain_id` in `task_nudge_scheduler.odin`.
- Drop `team_id` from `Task_Chain_State` and all JSON; switch VCS labels/logs to `chain_id`.
- Rename memory `target_team_kind` → `target_kind` at the API boundary.
- **Exit:** no team types, stores, routes, or CLI remain; build + core flows green.

### Phase 7 — UI changes
- **Chain agents panel:** already task-derived (done earlier) — verify it needs no team data.
- Remove team fetch/usage: `fetchTeam`/`useFetchTeamQuery`, `team_id` plumbing, "add member"
  UX (`daemonApi.addTeamMember`), `chainTeam` props not otherwise needed.
- **New chain modal:** `kind` becomes a plain label selector; drop team/scaffold-roster UI;
  keep VCS toggle. Optionally show "will run scaffold: `scaffold-coding-feature`".
- **Settings / defaults:** add a **default agents** editor for the `role → default agent id`
  map (coordinator/worker/reviewer/conversation/guide), reusing `AgentSelect`.
- **Memory UI:** replace `team_kind` selector label with `kind`; ensure `scaffold-*` and core
  skills are visible/editable as memories.
- Add/adjust `data-debug-id`s per AGENTS.md registry for any new/changed elements.
- **Exit:** UI has no team concept; default-agents and scaffolds are managed via config/memory.

### Phase 8 — Docs, config, cleanup, verification
- Update `AGENTS.md` (identity model, remove team/role sections, add core-skills + scaffold-skill
  model + default-agents map). Retire `docs/teams-v1/*` (fold anything live into AGENTS.md).
- Update `config.toml` (default agents map, system-agent allowlist; remove team knobs).
- Remove now-dead prompt files replaced by skills.
- **End-to-end verification on an empty DB:** create a coding chain → coordinator runs scaffold
  skill → 5 tasks with correct assignee/reviewer → review gating works → notifications route →
  a **custom agent id** can be assigned as reviewer and function. Capture evidence artifact.
- **Exit:** full typed-chain lifecycle works with zero team concept and a custom agent proven
  drop-in.

---

## Cross-cutting rules
- **No DB migration code.** Empty-DB assumption; reset/bump schema versions as convenient.
- **Ask, don't guess.** Any ambiguity or missing decision → coordinator escalates to the user
  (Phase 0 is the primary gate, but the rule holds for every phase).
- Keep each phase independently buildable; land behind the single chain in order.
- Reviewer (`lgtm_required`) on each implementation task; coordinator writes the final summary
  with evidence, commits, and the custom-agent proof.
