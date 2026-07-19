# Teams: Usage Analysis and Removal Proposal

**Date:** 2026-07-19
**Author:** engineering analysis
**Goal:** Document exactly how the `team` concept is used today, show that
`agent_instance_id` + task roles already carry the collaboration model, and propose
removing teams so Heimdall ships with a small set of **default durable agent ids**:
`conversation`, `guide`, `coordinator`, `worker` (default assignee), `reviewer`
(default reviewer).

---

## 1. TL;DR

- A **team** today is a **per-chain roster object** (`Team_Record` + `Team_Member_Record`)
  plus a **template of roles/scaffolds** (`Team_Kind_Def`). It exists mostly to answer one
  question: *"for role X on this chain, which `agent_instance_id` should I use?"*
- That question is already answerable **without** a team: a task carries its own
  `assignee_agent_instance_id`, `reviewer_agent_instance_id`, `coordinator_agent_instance_id`,
  and `participants[]`. The chain carries `coordinator_agent_instance_id` and
  `default_reviewer_agent_instance_id`. **Collaboration is keyed on `agent_instance_id`, not
  on team membership.**
- Teams add a **second, redundant identity/roster store** (`teams/teams.db`) that must be
  provisioned, kept in sync, migrated, archived, and surfaced in UI/CLI — for information the
  daemon can derive from tasks + a few default agent ids.
- **Recommendation:** delete the durable team store and the `team_id` field; keep a tiny,
  code-only notion of **role → default agent id** and **chain kind → scaffold** (no per-chain
  roster rows). Ship 5 default durable `agent_id`s. This removes ~1,200+ LOC of daemon code,
  one SQLite DB, a migration path, and a whole HTTP/CLI/UI surface.

---

## 2. What a "team" is, concretely

Two distinct things share the word "team":

### 2.1 The durable per-chain roster (the part to delete)

Defined in `src/daemon/team_db_service.odin`, stored in `teams/teams.db`:

```odin
Team_Record        { team_id, project_id, kind, status, chain_id, created/updated }
Team_Member_Record { team_member_id, team_id, role_key, role_index,
                     agent_instance_id, agent_record_id, is_user_proxy, route_to }
```

- One `Team_Record` is created **per chain** (`team_service_create_for_chain`), 1:1 with the
  chain (`chain.team_id`).
- Its `members[]` are just `(role_key, role_index) → agent_instance_id` rows. Creating a team
  **provisions a concrete agent instance for every role slot** of the chain's kind
  (coordinator/coder/tester/reviewer for `coding`).
- `status` (`latent | warming | active | archived`) is a lifecycle mirror of the chain.

### 2.2 The code-only role/scaffold template (keep, slimmed)

Defined in `src/daemon/team_kinds.odin` as compile-time constants:

```odin
Team_Kind_Def { key, roles[], memory_templates[], scaffolds[], wants_vcs, ... }
// key ∈ { coding, research, solo }
```

- `roles[]` = which role slots a kind has (coding → coordinator, coder, tester, reviewer).
- `scaffolds[]` = the canned task graph (`plan → contracts → implement → test → summary`),
  each scaffold task naming a `role_key` + `reviewer_role`.
- `memory_templates[]` = which bootstrap memories that kind's agents get.

This is **static config**, not per-chain state. It does not need a database or a `Team_Record`.
Its only real coupling to teams is that scaffold assignment maps `role_key → team member`.

---

## 3. Where teams are used (call-site inventory)

Daemon reference counts (`team_id | Team_Record | team_service | Team_Member | team_kind`):

| File | Refs | What it does with teams |
|------|-----:|-------------------------|
| `team_db_service.odin` | 101 | The `teams.db` store itself (delete). |
| `task_service.odin` | 91 | Chain create → `team_service_create_for_chain`; scaffold assignee resolution via `team_db_list_members` → `role_key` → `agent_instance_id`. |
| `team_service.odin` | 70 | Roster provisioning, member routing, role→template defaults (delete/slim). |
| `task_nudge_scheduler.odin` | 51 | **Boot leases keyed on `chain.team_id`** to throttle concurrent agent launches; reconcile logs. |
| `team_http.odin` | 43 | `GET /teams`, `/teams/{id}`, `POST /teams/add-member` (delete). |
| `teams_v1_migration.odin` | 40 | One-shot legacy migration (delete after transition). |
| `memory_service.odin` | 35 | `target_team_kind` memory targeting dimension (keep as `kind`, decouple from team store). |
| `task_db_service.odin` | 15 | `task_chains.team_id` column + backfill. |
| `memory_db_service.odin` | 12 | `target_team_kind` column/index. |
| `task_projection.odin`, `task_queries.odin`, `json.odin`, `merge_lifecycle.odin`, `task_store.odin`, `agents_start.odin`, `vcs_http.odin` | 2–9 each | Carry/emit `team_id` in chain JSON, VCS labels, projections. |

UI/CLI:
- UI: `App.tsx` (Chain agents panel — **already migrated off teams** to task-derived roster in a
  prior change), `ChainEditor.tsx`, `SettingsPage.tsx`, memory slices (kind selector).
- CLI: `ham-ctl teams list|show|show-members|add-member`.
- Docs: `docs/teams-v1/*` (15 files).

**Rough removable surface:** `team_db_service.odin` (304) + `team_service.odin` (224) +
`team_http.odin` (238) + `teams_v1_migration.odin` (277) ≈ **1,043 LOC** deleted outright,
plus `team_kinds.odin` (181) slimmed to role/scaffold constants, plus the `teams.db` file,
the `/teams` routes, the `ham-ctl teams` family, and `docs/teams-v1`.

---

## 4. Why teams are redundant

### 4.1 Collaboration is already keyed on `agent_instance_id`

A task is self-describing:

```
Task_State {
  assignee_agent_instance_id
  coordinator_agent_instance_id
  reviewer_agent_instance_id
  participants[] : { agent_instance_id, role ∈ assignee|coordinator|lgtm_required|lgtm_optional|subscriber }
}
Task_Chain_State {
  coordinator_agent_instance_id
  default_reviewer_agent_instance_id
}
```

Everything the system needs to route work, votes, notifications, and nudges is **on the task
and the chain**, keyed by `agent_instance_id`. Nothing in the runtime routing consults the team
roster after assignment:
- Review gating counts `lgtm_required` **participants**, not team members.
- Notifications route by task status → assignee/coordinator/reviewer **ids**.
- The UI "Chain agents" panel was just changed to derive its roster from **task assignees/
  reviewers/participants** (teams no longer needed there, and it fixed a real bug where the
  team-sourced roster showed only the coordinator).

### 4.2 The team only mattered at two moments

1. **Chain creation / scaffold expansion:** map each scaffold task's `role_key` (e.g. `coder`)
   to a concrete `agent_instance_id`. This is a **provisioning** step, not durable state — it
   can be done from `role → default agent id` without persisting a roster.
2. **Boot-lease throttling** (`task_nudge_scheduler.odin`): the autoscaler groups launches by
   `chain.team_id` to avoid stampeding all of a chain's agents at once. Since team is 1:1 with
   chain, **`chain_id` is an identical grouping key** — the lease can key on `chain_id`.

Neither requires a durable `teams.db`.

### 4.3 `target_team_kind` is a taxonomy, not a team

Memory targeting uses `target_team_kind` (`coding`/`research`/`solo`) to scope bootstrap
memories. That is a **kind/taxonomy label**, already independent of any `Team_Record`. Rename
the dimension to `target_kind` (or keep the column, drop the word "team") — no roster needed.

---

## 5. Target model (after removal)

### 5.1 Default durable agent ids shipped with Heimdall

Seed these `Agent_Id_Record`s on first boot (they already have matching templates:
`guide`, `lead`, `coder`, `reviewer`):

| `agent_id` | template | default tier | Default use (this is the *default map value*, not an intrinsic role) |
|------------|----------|--------------|------------------------------------------------------------------|
| `conversation` | `conversation`* | normal | Default free-form chat/ask agent (Home "Ask"). |
| `guide` | `guide` | smart | Product guide / UI copilot (already exists). |
| `coordinator` | `lead` | smart | Default chain coordinator. |
| `worker` | `coder`** | normal | Default task **assignee**. |
| `reviewer` | `reviewer` | smart | Default task **reviewer**. |

\* A small `conversation` template may need seeding (persona = general assistant).
\** `worker` can alias the existing `coder` template, or a new generic `worker` template.

No `role_hint`/`agent_role` column: the "default use" is only which slot this id is the
**configured default** for (§5.2) — the agent itself carries no fixed role. Each is an ordinary
durable identity (`src/daemon/agent_id_store.odin`), overridable in config, spawning concrete
`agent_instance_id`s per chain/run exactly as today (`worker@s-…`, `reviewer@s-…`), and freely
usable in any other slot when a task assigns it there.

### 5.2 Role → default agent id (code-only)

Replace `Team_Role_Slot`/roster provisioning with a static map used **only at chain/scaffold
creation**:

```
role_key   → default agent_id
"coordinator" → "coordinator"
"assignee"/"coder"/"worker"/"tester"/"researcher" → "worker"
"reviewer"    → "reviewer"
```

Scaffold expansion resolves `role_key → default agent_id → new/selected agent_instance_id`
and writes it straight onto the task's `assignee/reviewer` fields. No `Team_Member_Record`.

### 5.3 Chain kind → scaffold (code-only, kept)

Keep `Team_Kind_Def` but rename to `Chain_Kind_Def` and strip the roster/team coupling: it
becomes `{ key, scaffolds[], memory_kinds[], wants_vcs }`. `coding|research|solo` stay as
scaffolds; they no longer allocate a team.

### 5.4 Boot lease re-key

`task_nudge_scheduler.odin`: change `Team_Boot_Lease.team_id` → `chain_id`, and
`task_autoscaler_lease_index(chain.team_id)` → `(chain.chain_id)`. Behavior is identical
(team was 1:1 with chain).

---

## 6. Data-structure/type reductions

Removed types & stores:
- `Team_Record`, `Team_Member_Record`, `Team_With_Members`, `Team_DB` — **deleted**.
- `teams/teams.db` file and its schema/migrations — **deleted**.
- `task_chains.team_id` column, `Task_Chain_State.team_id`, all `team_id` JSON fields — **deleted**.
- `/teams`, `/teams/{id}`, `/teams/add-member` routes — **deleted**.
- `ham-ctl teams` command family — **deleted**.
- `teams_v1_migration.odin` — **deleted** (after a final one-way data migration; see §7).

Kept, slimmed, renamed:
- `Team_Kind_Def` → `Chain_Kind_Def` (code constants; no DB).
- `Team_Role_Slot` → `Chain_Role_Slot` used only for scaffold/default-assignee resolution.
- `target_team_kind` → `target_kind` (memory taxonomy; column can keep its name to avoid a
  memory-DB migration, only the wire/label changes).

Net: **one fewer durable store, one fewer 1:1 join object, ~1,000+ LOC removed**, and the
"who's on this chain" answer comes from the single source of truth (tasks).

---

## 7. Migration / rollout plan

Because team is 1:1 with chain and only referenced for role→agent resolution, migration is
mechanical:

1. **Backfill tasks (one-way):** for every existing chain, ensure each task's
   `assignee/reviewer/coordinator` ids are populated (they already are for active chains). For
   any scaffold task that only had a team-member pointer, resolve it once from the current
   roster and write the id onto the task. After this, no reads need `teams.db`.
2. **Drop `team_id` reads:** replace `chain.team_id` groupings with `chain.chain_id`
   (boot lease, logs, VCS labels).
3. **Seed default agent ids:** add the 5 durable identities in the first-boot seeding path
   (next to template seeding in `agent_template_db_service.odin` / an `agent_id` seeder).
4. **Delete stores/routes/CLI/docs:** remove `teams.db`, `/teams*`, `ham-ctl teams`,
   `docs/teams-v1` (fold anything still relevant into `AGENTS.md`).
5. **Rename kind taxonomy:** `team_kind` → `kind` at the API boundary; keep DB column names to
   avoid touching `memory.db`.

Ship behind a phase flag if desired, but the end state deletes the flag too.

### Risks / call-outs
- **VCS labels / logs** embedding `team_id` — cosmetic; switch to `chain_id`.
- **`is_user_proxy` / `route_to`** (solo kind's synthetic reviewer) — preserve by making the
  `solo` scaffold set `reviewer = user_proxy` directly on the task (already supported:
  `default_reviewer_agent_instance_id = "user_proxy"`).
- **`add-member` "add agent to chain"** UX — replace with "add participant to task" (already
  exists via `/tasks/participant`) or a chain-level default-agents editor.
- **Memory targeting** must keep a `kind` dimension so bootstrap memories still scope by
  coding/research/solo.

---

## 8. Agent property audit: keep vs. remove

Beyond teams, the agent data model carries several descriptive properties. Since the goal is
"fewer redundant data types, keep things simple as long as core functionality works," each is
audited below for whether it earns its place. Core functionality = launch an agent, route
tasks/reviews/notifications by `agent_instance_id`, bootstrap it with the right persona, and
scope memory.

### 8.1 Durable identity (`Agent_Id_Record`) and instance (`Agent_Instance_Record`)

| Property | Where | Function today | Verdict |
|----------|-------|----------------|---------|
| `agent_id` | id + instance (prefix) | Durable identity shared across runs (`worker`, `reviewer`). The whole "default agent ids" goal rests on this. | **KEEP (core).** |
| `agent_instance_id` | instance | The collaboration key: tasks/votes/notifications route on it. | **KEEP (core, the source of truth).** |
| `template_id` | id + instance | Selects persona/instructions for bootstrap. Distinct personas (guide vs coder vs reviewer) genuinely change agent behavior. | **KEEP (core).** |
| `display_name` | id + instance | Human label in UI/CLI. Cheap, purely presentational. | **KEEP.** |
| `provider_profile` | id (default) + instance | Which model backend to launch (`pi`, `claude`). Required to spawn. | **KEEP (core).** |
| `model_tier` | id (default) + instance | cheap/normal/smart model selection. Required to spawn. | **KEEP (core).** |
| `project_id` / `default_project_id` | both | Optional project binding / bootstrap context. Loose hint. | **KEEP**, but keep it optional (see the invalid-project fix). |
| `run_dir` | instance (runtime) | Where the wrapper launched. Runtime bookkeeping. | **KEEP** (runtime), not identity. |
| `state` / `identity_state` | both | provisioned/running/archived lifecycle. | **KEEP (core).** |
| `agent_kind` (`local` \| `remote_proxy`) | instance | Distinguishes a real local agent from a federation proxy pointer. Drives "don't launch a wrapper" + federation forwarding. Load-bearing. | **KEEP (core for federation).** |
| `remote_peer_id` / `remote_origin_daemon_id` / `remote_agent_instance_id` | instance | Federation proxy target. Only meaningful when `agent_kind = remote_proxy`. | **KEEP (federation).** |
| `current_task_id` / `current_task_since` / `last_needed_at_unix_ms` / `order` | instance | Autoscaler/UI hints (what it's doing, ordering). | **KEEP** (cheap runtime projection). |
| `default_project_explicit` | id | Guards backfill from clobbering an explicitly-cleared default project. | **KEEP** (correctness flag, small). |

### 8.2 `role_hint` vs `agent_role` — why two? (answer: we don't need two)

**They are the same value stored twice.** The code makes this explicit:

```odin
// agent_store.odin
agent_role_from_template :: proc(template_id) -> string {
    role := agent_template_records[tidx].role_hint   // <-- agent_role IS the template's role_hint
    if role != "" do return role
    if template_id == "lead" do return "coordinator" // <-- plus a hardcoded fixup
    return template_id
}
// agent_id_store.odin / agent_store.odin, every upsert:
agent_role = (agent_role != "" ? agent_role : agent_role_from_template(template_id))
```

- `role_hint` lives **once** on the `Agent_Template_Record` (the template row).
- `agent_role` is then **copied onto the durable `agent_id` AND onto every
  `agent_instance` record AND cached on the runtime `Agent_Record`** — i.e. the same string
  is duplicated into 3 more places and must be kept in sync on every event/clone/JSON emit.

That duplication buys nothing: no code path reads `agent_role` and `role_hint` as *different*
facts. The only functional branch on `agent_role` anywhere is
`if rec.agent_role == "conversation"` (federation), which is already equivalent to
`template_id == "conversation"`.

**Verdict: remove BOTH as agent properties. Role is contextual, not intrinsic.**

The deeper point: **an agent has no fixed role — it plays whatever role the task gives it.**
The same `worker@s-…` (or a customer's custom agent) can be the *assignee* on task A, a
*reviewer* on task B, and a *subscriber* on task C. Baking a single `agent_role`/`role_hint`
onto the identity contradicts that: it pretends "this agent IS a reviewer," which is only ever
true *relative to a task*. The authority already exists and is per-task:
`task.participants[].role ∈ {assignee, coordinator, lgtm_required, lgtm_optional, subscriber}`.

Evidence that neither field is load-bearing:
- **No behavior branches on them** except `agent_role == "conversation"` (federation), which is
  identical to `template_id == "conversation"`.
- **The UI treats them as interchangeable display text:** `AgentPicker` resolves a label via
  `templateId || agentRole || roleHint || agentId` — they are one "what kind of agent" string,
  not three facts. Grouping/labels can use `template_id` (or its `display_name`) directly.
- Review-gating, notification routing, and the chain roster already read the **task's** role,
  not the agent's (that was the Chain-agents panel fix).

**So:**
- Delete the stored `agent_role` from `Agent_Id_Record`, `Agent_Instance_Record`, and the
  runtime `Agent_Record`.
- Delete `role_hint` from `Agent_Template_Record` and `agent_role_from_template()` (including
  its hardcoded `"lead" → "coordinator"` fixup).
- Anywhere a human-facing "kind" label is wanted, use the template's `display_name`/`template_id`
  — which a custom agent defines itself.
- Replace `agent_role == "conversation"` with a `template_id`/durable-id check.

Result: **zero intrinsic role fields.** "Who is the reviewer" is answered only by the task,
which is the whole point — any agent, including a customer's, can be dropped into any slot
without the daemon believing it has a fixed role.

#### `agent_scope` (`durable` \| `generated_chain` \| `system`)
- **What it does:** was meant to separate "durable identities" from "throwaway per-chain
  instances" (for cleanup/idle-shutdown). The idle-shutdown sweep that consumed it is
  **already disabled** (`task_autoscaler_tick` phase-1 note). Today it mainly gates whether an
  instance may seed a durable default project, and is otherwise carried/normalized.
- **Argument for removal:** with teams gone, every agent is just a durable `agent_id` plus its
  concrete `agent_instance_id`s; the "generated_chain" class largely disappears (those
  instances were the team-provisioned role slots). Its main live consumer (idle shutdown) is
  dead code slated for deletion.
- **Verdict: REMOVE (phase 2), or collapse to a boolean.** Fold the one remaining rule
  ("only durable identities seed a durable default project") into an explicit
  `is_durable_identity` check, or drop it since default-project seeding is already guarded by
  `default_project_explicit`. This deletes a 3-valued field that must be inferred, normalized,
  and stored on both the identity and instance.

### 8.3 Memory targeting descriptors

| Property | Function | Verdict |
|----------|----------|---------|
| `target_agent_id` | Scope a memory to one durable identity. | **KEEP (core).** |
| `target_project_id` | Scope to a project. | **KEEP (core).** |
| `target_role` | Scope bootstrap memory to a role (e.g. all reviewers). | **REPLACE with `target_template_id`** (or `target_agent_id`). "role" here is really "which kind of agent" — which the template already identifies. Drop the free-standing role dimension. |
| `target_team_kind` | Scope to a chain kind (`coding`/`research`/`solo`). Not a team roster — a taxonomy. | **KEEP as `target_kind`** (rename; drop the word "team"). Keep the DB column name to avoid a memory-DB migration. |

### 8.4 Summary of property changes

- **Keep (core):** `agent_id`, `agent_instance_id`, `template_id`, `display_name`,
  `provider_profile`, `model_tier`, `project_id`, `state`, `agent_kind` + `remote_*`, runtime
  task/needed/order fields, memory `target_agent_id`/`target_project_id`.
- **Rename only:** `target_team_kind` → `target_kind` (chain taxonomy, no roster).
- **Remove entirely:**
  - `agent_role` (stored on `Agent_Id_Record`, `Agent_Instance_Record`, runtime `Agent_Record`)
    — role is a per-task fact, not an identity fact.
  - `role_hint` (on `Agent_Template_Record`) and `agent_role_from_template()` — the only reason
    `agent_role` existed.
  - `agent_scope` (dead idle-shutdown consumer; the one live rule folds into
    `default_project_explicit`).
  - memory `target_role` → fold into `target_template_id`/`target_agent_id`.
  - everything in §2.1 (the team roster).

Guiding principle: **the task is the authority on who does what; the identity carries only
what's needed to launch and bootstrap an agent.** Any field that merely *restates* a role the
task already owns — `agent_role`, `role_hint`, `target_role` — is redundant and goes.

### 8.5 No hardcoding: custom agents must be first-class

The target model must let a customer register an arbitrary agent (their own template + durable
`agent_id`) and use it for any slot. Today several **hardcoded string checks** would make that
awkward or broken — these are the real blockers, and they must go regardless of the team work:

| Hardcoded assumption | Location | Why it breaks custom agents | Fix |
|----------------------|----------|-----------------------------|-----|
| `template_id == "lead"` → role `coordinator` | `agent_store.odin` | A custom coordinator template (`acme_lead`) is not recognized as coordinating. | Remove; coordinator-ness comes from the task/chain `coordinator_agent_instance_id`, not the template name. |
| `agent_id_ref == "coordinator"` → force `template = "lead"` | `agents_start.odin` | Ties the `coordinator` id to one specific template. | Resolve template from the `agent_id`'s own record, not a hardcoded pair. |
| scaffold `role_key → agent_template_id` map (`coordinator→lead, coder→coder, reviewer→reviewer, tester→tester`) | `team_kinds.odin` | Custom agents can't be the default for a scaffold slot. | Replace with configurable **role → default `agent_id`** (§5.2), operator-overridable. |
| `template_id == "guide"` / `memory_auditor` / `memory_reviewer` singleton handling | `agent_store.odin`, `agents_start.odin`, `guide_service.odin` | Special system agents identified by literal template name. | Keep as an explicit, small **allowlist of system agent ids** in config — not scattered `== "guide"` checks. |
| `agent_role == "conversation"` | `federation_peers.odin` | A custom chat agent with a different template isn't recognized. | Check the durable `conversation` id / a `is_conversation` template flag. |
| `derive_agent_class()` parses the id prefix for "class" | `registry.odin` | Assumes `class@suffix` naming encodes behavior. | Fine as a *display* fallback; never use it to decide behavior. |

**Principle for custom agents:** behavior is decided by (a) the **task** (who is
assignee/reviewer/coordinator here) and (b) an explicit, **operator-configurable** "default
agent for role X" map — never by matching a built-in template or id string. The five shipped
defaults (`conversation`, `guide`, `coordinator`, `worker`, `reviewer`) are just the initial
values of that map and of the durable-id set; every one must be replaceable by a customer
agent id in config without a code change. System singletons (guide, memory auditor/reviewer)
live in a named config allowlist, so even they are swappable rather than hardcoded.

---

## 8.6 Bootstrap: replace per-role persona/instructions with core skills + on-demand memory

This is the biggest simplification, and it removes the *last* reason `template`/`role` needs to
carry behavior. Today bootstrap injects **role-specific instructions** into every agent's
`AGENTS.md`:

- The daemon ships **~13 hardcoded prompt files** — `coder_persona.md` + `coder_instructions.md`,
  `reviewer_*`, `planner_*`, `tester_*`, `lead_*`, `researcher_*`, `specialist_*`,
  `coordinator_instructions.md`, etc. (`src/prompts/`).
- Each agent **template** stores a `persona` + `instructions` (loaded from those files).
- The wrapper's `build_agents_md()` picks which to inject **by role/template**: shared
  `# Agent Operating Rules` for everyone, then `# Coordinator Instructions` iff
  `role_key == "coordinator"`, then the template's `# Role Persona` / `# Role Instructions`.

So the whole "role" apparatus (`role_key`, `is_coordinator`, per-template persona/instructions)
survives mostly to decide **which instruction blob to paste**. That is exactly what the memory/
skills system already does better.

### What already exists (reuse, don't rebuild)
- **`type: skill` memories** are already rendered to on-demand `SKILL.md` files
  (`write_skills()` → `.agents/skills/<slug>/SKILL.md`) with provider-native frontmatter, so an
  agent **reads a skill only when the task needs it** (Claude/codex skill discovery).
- **`type: template` memories** are already injected as durable guidance.
- **`/memory/applicable`** already filters by `target_agent_id`, `target_project_id`, and a
  taxonomy dim — the exact targeting needed to say "all agents get these core skills."

### Proposed model
1. **Core skills shipped with Heimdall, applied to every agent.** Convert the role instruction
   files into a small set of **seeded, active memories** (`type: skill`/`template`) with **no
   target** (= applies to all): e.g. `task-workflow`, `review-and-evidence`, `coordinator-
   playbook`, `git-hygiene`, `contracts-first`, `testing-discipline`. Every agent boots with the
   shared **Agent Operating Rules** inline (kept small) plus these core skills available on disk
   to read on demand.
2. **Role instructions become skills, not identity.** `reviewer_instructions.md` → a
   `review-and-evidence` skill; `coordinator_instructions.md` → a `coordinator-playbook` skill;
   etc. They are **available to any agent** and **read when the task calls for it** ("you are the
   reviewer on this task → read the review skill"), instead of being pasted because the identity
   is tagged `reviewer`. This is precisely the user's point: *an agent plays any role based on
   context*, so the instructions for a role live in a skill the agent opens when it takes that
   role — not in its identity.
3. **Persona shrinks to (optional) one line or disappears.** With behavior in shared skills, a
   template's `persona`/`instructions` become optional flavor. A custom agent can ship with an
   empty template and still be fully functional off the core skills.
4. **Customization = propose a memory, not fork a template.** Users tailor behavior by
   proposing/approving memories (`type: skill|template`, optionally `target_agent_id` or
   `target_project_id`) through the existing approval pipeline — no code, no new template row,
   no per-role prompt file. Project- or agent-specific tweaks target that scope; universal ones
   target nothing.

### What this lets us delete/collapse
- The per-template `persona`/`instructions` **as the behavior source** (keep an optional short
  persona at most). The 13 `*_persona.md` / `*_instructions.md` files collapse into a handful of
  seeded core-skill memories.
- `role_key`/`is_coordinator` branching in `build_agents_md()` — bootstrap becomes: shared rules
  + core skills + task/chain/project/workspace context + applicable memories. **No role fork.**
- The coupling "template ⇒ which instructions" — removed, because instructions are skills any
  agent can read.

### Guardrails
- Keep the **shared Agent Operating Rules** inline in `AGENTS.md` (small, always-on) so an agent
  knows *how to discover and read skills* and *how to use the task CLI* before it needs any
  specific skill.
- Core skills are **seeded as normal approved memories** on first boot (idempotent), so they are
  visible, versioned, and editable through the same memory UI/CLI — not a second hidden config.
- Coordinator's user-contact rules must stay reliably available; ship them as a core skill that
  the bootstrap explicitly points the current coordinator at (by task/chain role, not identity).

**Net:** behavior lives in the **memory/skills system** (one customization surface, on-demand,
versioned, per-scope), identities carry only launch/bootstrap essentials, and "role" exists
only on the task. This is the maximal simplification: teams gone, intrinsic roles gone,
per-role prompt files gone — all replaced by core skills any agent reads by need.

---

## 8.7 How do we still do a "coding" or "research" chain? (the scaffold question)

A fair objection: today `--kind coding` allocates a team **and** expands a canned task graph
(`plan → contracts → implement → test → summary`, each task pre-assigned to a role). If teams
and `team_kind` are gone, how does a user still get a *typed* chain quickly?

Key realization: **the scaffold was never the team.** A scaffold is just a script that emits
`tasks create --depends-on …` + `tasks participant --role lgtm_required …`, mapping each
`role_key` to an agent. Removing teams removes the *roster*, not the *task graph*. There are
three ways to produce a typed chain, in increasing automation — all built on the same primitive
(`agent_instance_id` on tasks):

### Option A — Manual (always available, zero magic)
The coordinator (or user) creates the chain and its tasks directly, choosing agent ids:
```bash
ham-ctl task-chains create --kind coding --title "Fix X"        # kind = taxonomy label only
ham-ctl tasks create --chain-id <c> --title "Plan"      --assignee coordinator@…
ham-ctl tasks create --chain-id <c> --title "Implement" --assignee worker@… \
        --depends-on <plan> ;  ham-ctl tasks participant --task-id <impl> --role lgtm_required --agent-instance-id reviewer@…
ham-ctl tasks create --chain-id <c> --title "Test"      --assignee worker@… --depends-on <impl>
```
This already works today. `--kind` stays as a **label** (drives which core memories/skills
apply and whether VCS is wanted) but allocates **no team**. A custom agent id drops straight
into `--assignee`.

### Option B — Scaffold as a skill/template the coordinator runs (recommended default)
Instead of the daemon hardcoding `coding_feature_tasks[]`, ship the scaffold as a **core skill**
(§8.6): `scaffold-coding-feature`, `scaffold-research`, etc. When a chain is created with
`kind=coding`, the coordinator is pointed at that skill and **executes it** — it is literally a
numbered recipe of `tasks create`/`participant` commands with the role→default-agent mapping
inlined. Benefits:
- **No hardcoded task graph in daemon code.** The recipe lives in the memory system, versioned
  and editable through the memory UI/CLI like any other skill.
- **Fully customizable per user/project.** A user proposes an edited `scaffold-coding-feature`
  memory (or a new `scaffold-mobile-release`) scoped to their project; no code change, no new
  `team_kind`.
- **Custom agents just work:** the recipe resolves `role → default agent id` from the
  operator-configurable map (§5.2), so `worker`/`reviewer` can be any agent id.

### Option C — Thin daemon scaffold helper (optional, keeps one-click UX)
If we want the current "pick coding, get 5 tasks" one-click UX without the coordinator doing it,
keep a **small, data-driven scaffold table in code** (`Chain_Kind_Def.scaffolds`, already exists)
but strip its team coupling: each scaffold task is `{ title, role_key, reviewer_role,
depends_on }`, and expansion resolves `role_key → default agent id` from the config map and
writes the id onto the task. This is §5.2/§5.3 — same output as today, minus `teams.db`.

### Decision: **Option B — scaffolds are skills.**
We are going with Option B. The daemon does **not** hardcode `coding_feature_tasks[]` or any
task graph. Each scaffold is a **core skill (seeded memory)** that the coordinator executes
when a chain of that kind is created. Option A's primitives (`tasks create` / `participant`)
remain the substrate; Option C's in-code table is **not** built. `kind` stays a taxonomy label
that (a) selects which scaffold skill the coordinator runs and (b) selects applicable core
memories + VCS default — never a team, never an intrinsic agent role.

---

## 8.8 Implementation plan for Option B (scaffolds as skills)

**Goal:** typed chains stay one action, but the "type" is a skill the coordinator runs, not a
hardcoded team/task graph.

### 8.8.1 Author the scaffold skills (seeded core memories)
- Convert each existing scaffold into a `type: skill` memory, seeded active on first boot
  (idempotent), e.g.:
  - `scaffold-coding-feature` (plan → contracts → implement → test → summary)
  - `scaffold-coding-bugfix` (reproduce → fix → test → summary)
  - `scaffold-research` (investigate → synthesize → summary)
  - `scaffold-solo` (single-assignee + `user_proxy` reviewer)
- Each skill body is a **numbered recipe** the coordinator can execute verbatim, with the
  role→default-agent mapping written as `ham-ctl` calls. Reuse the existing per-task guidance
  text (`scaffold-coding-plan`, `…-contracts`, etc.) as the task **descriptions** inside the
  recipe. Example (abbreviated):
  ```markdown
  # scaffold-coding-feature
  Run these in order for a feature chain. Resolve {coordinator}/{worker}/{reviewer} from the
  chain's default-agent map (ham-ctl agents defaults).
  1. tasks create --chain-id {chain} --title "Plan: {title}"      --assignee {coordinator}
  2. tasks create --chain-id {chain} --title "Contracts: {title}" --assignee {worker} --depends-on {plan}
     tasks participant --task-id {contracts} --role lgtm_required --agent-instance-id {reviewer}
  3. tasks create --chain-id {chain} --title "Implement: {title}" --assignee {worker} --depends-on {contracts}
     tasks participant --task-id {implement} --role lgtm_required --agent-instance-id {reviewer}
  4. tasks create --chain-id {chain} --title "Test: {title}"      --assignee {worker} --depends-on {implement}
     tasks participant --task-id {test} --role lgtm_required --agent-instance-id {reviewer}
  5. tasks create --chain-id {chain} --title "Summary: {title}"    --assignee {coordinator} --depends-on {test}
  ```
- These live in the memory store: **versioned, visible, editable** through the memory UI/CLI.

### 8.8.2 Chain create becomes roster-free
- `POST /task-chains/create` keeps `kind`, `title`, `description`, `wants_vcs`, and an optional
  `coordinator_agent_instance_id`; it **stops** calling `team_service_create_for_chain` and
  **stops** expanding `Team_Kind_Def.scaffolds` in code.
- It creates the chain + a **coordinator discovery/kickoff task** (already exists) whose
  description says: *"This is a `coding` chain. Read and execute the `scaffold-coding-feature`
  skill to lay out the tasks, or create tasks manually."*
- The coordinator (already auto-booted for a chain) reads the skill on disk (it is delivered as
  a `SKILL.md` because it is an applicable `type: skill` memory) and runs it. Result: identical
  5-task chain, produced by the coordinator, no `teams.db`.

### 8.8.3 Role → default agent resolution
- Add a small **operator-configurable map** `role → default agent_id`
  (`coordinator→coordinator`, `assignee/worker/coder/tester→worker`, `reviewer→reviewer`),
  surfaced via `ham-ctl agents defaults` and the daemon config. The scaffold recipe resolves
  its `{coordinator}/{worker}/{reviewer}` placeholders from this map, so custom agent ids slot
  in without editing the skill.
- `solo` maps `reviewer → user_proxy` (preserves the synthetic-reviewer behavior on the task
  directly).

### 8.8.4 Customization story (the payoff)
- A user tailors a scaffold by **proposing an edited/added skill memory** (e.g.
  `scaffold-mobile-release`, or a project-scoped override of `scaffold-coding-feature` via
  `target_project_id`) through the normal approval pipeline. **No code change, no new
  `team_kind`, no template fork.**
- Because scaffolds are just skills, adding a whole new work type = adding a memory. `kind` on a
  chain becomes free-form-ish (a label that maps to "which scaffold skill to suggest").

### 8.8.5 What gets deleted as a result
- `Team_Kind_Def.scaffolds`, `Team_Chain_Scaffold`, `Team_Chain_Scaffold_Task`, and the
  in-daemon expansion (`task_service_create_chain_scaffold`, `task_service_scaffold_*`).
- The `scaffold-*` `description_key` → prompt-file plumbing (the text moves into the skill
  bodies).
- Everything in §2.1 (the team roster) and the intrinsic role fields (§8.2/§8.5).

### 8.8.6 Guardrails
- Keep the **discovery/kickoff task** so a chain always has a visible next action even if the
  coordinator hasn't run the scaffold yet.
- Seed scaffold skills idempotently and mark them `heimdall_managed` so upgrades can refresh the
  shipped defaults without clobbering user edits (user overrides target a scope and win).
- The coordinator's operating rules (a core skill, §8.6) must instruct it to **run the
  applicable scaffold skill on chain kickoff** so typed chains still feel one-click.

---

## 9. Recommendation

**Remove teams as a durable concept, and remove all intrinsic "role" fields from agents.**
Keep only:
1. Five seeded default durable agent ids: `conversation`, `guide`, `coordinator`, `worker`,
   `reviewer` — all overridable in config.
2. An **operator-configurable `role → default agent id`** map (no per-chain roster rows).
3. A `kind` taxonomy label on chains/memory that selects **which scaffold skill to run** and
   which core memories/VCS default apply (no roster).
4. **Scaffolds as skills (Option B):** typed chains (coding/research/solo) are produced by the
   coordinator running a seeded, editable `scaffold-*` skill — not a hardcoded in-daemon task
   graph. See §8.7–§8.8.

And delete:
- The team store (`teams.db`, `Team_Record`/`Team_Member_Record`, `/teams*`, `ham-ctl teams`).
- The in-daemon scaffold graph (`Team_Kind_Def.scaffolds`, `Team_Chain_Scaffold*`,
  `task_service_create_chain_scaffold`) — moved into `scaffold-*` skill memories.
- `agent_role`, `role_hint`, `agent_role_from_template()`, and memory `target_role` — role is
  a **per-task** fact, so no agent/template/identity carries a fixed role.
- `agent_scope` (dead consumer).
- The hardcoded template/id special-cases in §8.5, so **custom agents are drop-in** for any
  slot.
- The per-role prompt files and template `persona`/`instructions` **as the behavior source**
  (§8.6): replace with a small set of **core skills shipped as seeded memories**, applied to
  all agents and read **on demand** by whichever agent takes that role on a task.

Three invariants make the whole thing coherent:
- **The task decides roles.** "Who is the reviewer" = the task's `lgtm_required` participant,
  never an agent property. An agent can be assignee here and reviewer there.
- **Behavior never keys on a built-in name.** Defaults and system singletons live in config as
  agent ids, so a customer swaps any of them without a code change.
- **Customization lives in the memory/skills system.** Core skills ship as approved memories;
  users tailor behavior by proposing memories (optionally scoped to an agent/project), not by
  forking templates or editing prompt files. One versioned, on-demand customization surface.

This deletes a redundant store, a 1:1 join object, three duplicated role fields, ~13 per-role
prompt files, an HTTP/CLI/UI/doc surface, and a pile of hardcoded string checks — matching the
goal: fewer data types, no hardcoding, and any agent (built-in or custom) usable in any role by
context, customized entirely through memory.
