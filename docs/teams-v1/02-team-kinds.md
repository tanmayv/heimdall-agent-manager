# 02 · Team kinds

Team kinds are a **closed set** compiled into the daemon. Adding a new kind requires a code change and a reviewer sign-off. Users cannot define custom kinds.

The kind decides:

- **Role slots** — which roles the team has and how many.
- **Memory templates** — which curated template memories the team's agents load at bootstrap.
- **Chain scaffold** — the default task graph created when a new chain of this kind is opened.
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
    description_key:  string,             // #load'd prompt file
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
    memory_templates:  []string,          // template memory ids/titles
    scaffolds:         []Team_Chain_Scaffold, // first is default
    wants_vcs:         bool,
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
- **Scaffolds** (default first):
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
- **Scaffolds**:
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
- **Scaffolds**:
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
- **Scaffolds**:
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
- **Scaffolds**:
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
- **Scaffolds**:
  - **`chore`** — apply → verify → summary

### 2.7 `solo`

A team of one, backed by a synthetic `user_proxy` reviewer that routes approvals to `operator@local` via smart-reply chat cards.

| Role | Template | Count | Default tier | Provider |
|---|---|---|---|---|
| coordinator | `lead` | 1 | smart | pi |
| worker | (chosen at chain create, one of `coder` / `specialist`) | 1 | normal | pi |
| user_proxy (reviewer) | — synthetic — | 1 | — | — |

- **`wants_vcs`** — follows project's `vcs_kind`; user can toggle in `+ New chain` modal.
- **Memory templates**: inherits from the worker's underlying kind mapping.
- **Scaffolds**:
  - **`solo`** — plan → work → user-review → summary
- The `user_proxy` member has `agent_record_id = NULL`, `is_user_proxy = true`, `route_to = "operator@local"`. LGTM votes on tasks reviewed by `user_proxy` come from smart-reply cards to operator.

## Tester note

There is **no `tester` role slot on any kind**. Testers are agents in the roster who become **assignees on explicit test tasks** (e.g. Task 3.T = "Test: teams.db init"). They are never a default reviewer for implementation tasks. This is intentional — see INV of [`01-model.md`](./01-model.md) and reviewer guidance in [`10-review-invariants.md`](./10-review-invariants.md).

## Scaffold rendering

When `POST /task-chains` runs for a chain with a scaffold:

1. Resolve `team_kind_def` for the chain's kind.
2. Pick scaffold by `--scaffold <key>` or default (first in list).
3. For each `Team_Chain_Scaffold_Task`:
   - Instantiate a task with `title_template` interpolated over `{chain_title}`, `{project_name}`, `{team_kind}`.
   - Assignee = first team member with matching `role_key` (round-robin if multiple).
   - Reviewer(s) = team member(s) with matching `reviewer_role` as `lgtm_required`.
   - `depends_on` resolved to concrete task IDs after all scaffold tasks are created (two-pass).
4. Emit `Task_Chain_Created` + N × `Task_Created` events atomically (transaction on task DB).

`--no-scaffold` at chain create skips step 3–4; user/coordinator creates tasks manually.

## Adding a new kind

1. Append a `Team_Kind_Def` in `src/daemon/team_kinds.odin`.
2. Add prompts for scaffold task descriptions in `src/prompts/scaffold-<kind>-<task>.md`.
3. Update `docs/teams-v1/02-team-kinds.md` with the same content.
4. Update `07-ui.md`'s kind-picker list.
5. Add a test entry in `tests/team_kinds_test.odin`.

That's a five-file diff. It's meant to be easy; it's also meant to be reviewed each time.
