# 02 · Team kinds

Team kinds are a **closed set** compiled into the daemon. Adding a new kind requires a code change and a reviewer sign-off. Users cannot define custom kinds.

The kind decides:

- **Role slots** — which roles the team has and how many.
- **Memory templates** — which curated template memories the team's agents load at bootstrap.
- **Task-bundle templates** — coordinator-invoked helpers that add related tasks/dependencies to an existing chain after the goal is clarified. They are not required during chain creation.
- **Default model tier per role** — cheap / normal / smart.
- **`wants_vcs`** — whether chains of this kind expect a VCS workspace by default.

## Registry shape

Location: `src/daemon/team_kinds.odin` (new file, code-only, no DB).

```odin
Team_Role_Slot :: struct {
    role_key:          string,           // "coordinator", "coder", "reviewer", ...
    agent_template_id: string,           // fk to existing agent_templates
    count:             int,               // fixed number of instances
    default_tier:      string,           // "cheap" | "normal" | "smart"
    default_provider:  string,           // "pi" | "claude" | "codex"
}

Team_Chain_Scaffold_Task :: struct {
    key:              string,             // stable id within scaffold, e.g. "plan"
    title_template:   string,             // "Plan: {chain_title}"
    role_key:         string,             // which role gets it as assignee
    reviewer_role:    string,             // which role reviews (lgtm_required)
    depends_on:       []string,           // scaffold task keys
    description_key:  string,             // stable scaffold-description id used by the renderer
}

Team_Chain_Scaffold :: struct {
    key:            string,               // "feature", "bugfix", "spike", ...
    title_template: string,
    tasks:          []Team_Chain_Scaffold_Task,
}

Team_Kind_Def :: struct {
    key:               string,            // "coding", "research", ...
    display_name:      string,
    description:       string,
    roles:             []Team_Role_Slot,
    memory_templates:  []string,          // template memory ids/titles when fixed for the kind
    memory_templates_inherit_from_role: string, // optional role key for kinds like solo that inherit from another kind mapping
    scaffolds:         []Team_Chain_Scaffold, // legacy name; treated as coordinator-invoked task-bundle templates
    wants_vcs:         bool,
    wants_vcs_follows_project: bool,      // optional flag for kinds like solo that mirror project vcs_kind by default
    idle_shutdown_ms:  int,               // default 30*60*1000; can override
}
```

## The seven kinds

Each kind is fully specified below. Wherever a role references an existing agent template, the template must already exist in the `agent_templates` DB (defaults seeded by `seed_default_templates_if_empty`).

### 2.1 `coding`

The default kind for changes to code repositories.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| coder | `coder` | 1 | normal | pi |
| reviewer | `reviewer` | 1 | smart | pi |

- **`wants_vcs`** = true
- **Memory templates**: `bootstrap-guidance`, `coding-conventions`, `git-hygiene`
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`feature`** — plan → implement → review → validate → summary
  - **`bugfix`** — reproduce → fix → verify → summary
  - **`refactor`** — plan → refactor → review → validate → summary

### 2.2 `research`

Non-code investigative work: source review, market scan, spike write-ups.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| researcher | `specialist` | 2 | smart | pi |
| reviewer | `reviewer` | 1 | smart | pi |

- **`wants_vcs`** = false
- **Memory templates**: `bootstrap-guidance`, `research-method`, `source-hygiene`
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`report`** — scope → gather → synthesize → review → summary
  - **`spike`** — question → explore → conclude → summary

### 2.3 `debugging`

Diagnostic work with an expected fix at the end. Assumes code changes but is optimized for RCA over feature-building.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| debugger | `coder` | 1 | smart | pi |
| reviewer | `reviewer` | 1 | smart | pi |

- **`wants_vcs`** = true
- **Memory templates**: `bootstrap-guidance`, `debugging-playbook`, `evidence-collection`
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`bug`** — reproduce → isolate → fix → verify → summary
  - **`incident`** — triage → mitigate → root-cause → fix → post-mortem

### 2.4 `data-analysis`

Notebooks, dataset exploration, model evaluation. Often in a repo (notebooks committed), so VCS is on by default but easy to switch off.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| analyst | `specialist` | 2 | normal | pi |
| reviewer | `reviewer` | 1 | smart | pi |

- **`wants_vcs`** = true
- **Memory templates**: `bootstrap-guidance`, `data-hygiene`, `notebook-discipline`
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`analysis`** — define → explore → analyze → validate → report

### 2.5 `writing`

Docs, blog posts, longer-form artifacts. Usually in a repo (docs/) so VCS defaults on.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| writer | `specialist` | 1 | normal | pi |
| reviewer | `reviewer` | 1 | smart | pi |

- **`wants_vcs`** = true
- **Memory templates**: `bootstrap-guidance`, `writing-style`
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`article`** — outline → draft → review → publish

### 2.6 `ops`

Repo/config maintenance, dependency bumps, small automations.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | normal | pi |
| operator | `coder` | 1 | normal | pi |
| reviewer | `reviewer` | 1 | normal | pi |

- **`wants_vcs`** = true
- **Memory templates**: `bootstrap-guidance`, `ops-runbooks`
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`chore`** — apply → verify → summary

### 2.7 `solo`

A team of one, backed by a synthetic `user_proxy` reviewer that routes approvals to `operator@local` via smart-reply chat cards.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| worker | (chosen at chain create, one of `coder` / `specialist`) | 1 | normal | pi |
| user_proxy (reviewer) | — synthetic — | 1 | — | — |

- **`wants_vcs`** — follows project's `vcs_kind`; user can toggle in `+ New chain` modal. In the baked registry this is represented by `wants_vcs_follows_project = true` rather than a fixed `wants_vcs = true|false` value.
- **Memory templates**: inherits from the worker's underlying kind mapping. In the baked registry this is represented by `memory_templates_inherit_from_role = "worker"` rather than a fixed `memory_templates` list.
- **Task-bundle templates** available to the coordinator after chain creation:
  - **`solo`** — plan → work → user-review → summary
- The `user_proxy` member has `agent_record_id = NULL`, `is_user_proxy = true`, `route_to = "operator@local"`. LGTM votes on tasks reviewed by `user_proxy` come from smart-reply cards to operator.

## Tester note

There is **no `tester` role slot on any kind**. Testers are agents in the roster who become **assignees on explicit test tasks** (e.g. Task 3.T = "Test: teams.db init"). They are never a default reviewer for implementation tasks. This is intentional — see INV of [`01-model.md`](./01-model.md) and reviewer guidance in [`10-review-invariants.md`](./10-review-invariants.md).

## Task-bundle template rendering

New chain creation does **not** require or automatically apply a full scaffold. A chain starts with exactly one coordinator discovery task; after clarifying the goal, the coordinator may apply a task-bundle template to the existing chain.

When a coordinator/operator applies a task-bundle template to an existing chain:

1. Resolve `team_kind_def` for the chain's kind.
2. Pick template by key (for example `feature`, `bugfix`, `report`). The current code-level name may still be `scaffold` during migration, but product/docs should call this a task bundle.
3. For each `Team_Chain_Scaffold_Task` in the template:
   - Instantiate a task with `title_template` interpolated over `{chain_title}`, `{project_name}`, `{team_kind}`.
   - Render the task description from the template's `description_key`; the current implementation uses a built-in generic description that records the key/task/kind metadata rather than prompt-file-specific prose.
   - Assignee = first team member with matching `role_key` (round-robin if multiple).
   - Reviewer(s) = team member(s) with matching `reviewer_role` as `lgtm_required`.
   - Coordinator-owned control-plane tasks keep visible review gates; the coordinator may explicitly bypass a workflow gate only through the audited coordinator-only `--force` path when no user/product decision is required.
   - Worker/reviewer execution tasks, including implementation/fix/refactor/review/validate work, keep their explicit reviewer gates.
   - `depends_on` resolves to concrete task IDs after all bundle tasks are created (two-pass).
4. Append the bundle's `Task_Created` / participant events in template order.

Backward compatibility: legacy `scaffold` / `no_scaffold` create-time fields may be accepted for one release, but default creation is team-type-first and creates only the coordinator discovery task. Explicit legacy scaffold-at-create callers should be treated as compatibility shims, not the main workflow.

## Workflow gates

- **WF-1** Coordinator authority is explicit and audited: the chain coordinator may use `tasks done --force` / approved-status force only to bypass a workflow gate they own, and the durable task log records `FORCE_REVIEW_BYPASS` evidence with task, chain, coordinator, prior/new status, reason, and timestamp.
- **WF-2** Review gates are not silently removed and no fake LGTM votes are created. Worker execution tasks remain independently review-gated unless an authorized coordinator/operator explicitly force-advances with audit evidence.
- **WF-3** New chain creation requires only project/team kind plus optional VCS preference; title/goal are optional and can be clarified by the coordinator after creation.
- **WF-4** New chains are active/ready by default and include exactly one initial ready coordinator discovery task; they do not remain in `planning` / `waiting_for_promotion`.
- **WF-5** Task-bundle templates are applied to an existing chain by coordinator/operator action; default creation does not silently generate a full implementation chain.
- **WF-6** Coordinator discovery task instructs the coordinator to clarify the goal, explain team roles, update chain title/description, and create/apply downstream tasks.

## Adding a new kind

1. Append a `Team_Kind_Def` in `src/daemon/team_kinds.odin`.
2. Update `docs/teams-v1/02-team-kinds.md` with the same content.
3. Update `07-ui.md`'s kind-picker list.
4. Add a test entry in `tests/team_kinds_test.odin`.
5. Optionally add prompt-backed scaffold descriptions later if/when the renderer moves beyond the current built-in generic scaffold-description text.

That's intended to stay a small reviewed diff each time.
