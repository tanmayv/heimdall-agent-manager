# 02 · Team kinds

Team kinds are a **closed set** compiled into the daemon. Users choose from three user-facing kinds:

- `coding`
- `research`
- `solo`

Legacy top-level kinds (`debugging`, `data-analysis`, `writing`, `ops`) are no longer first-class registry entries. Their workflows are absorbed into consolidated scaffolds under the three active kinds.

## Registry shape

Location: `src/daemon/team_kinds.odin`

```odin
Team_Role_Slot :: struct {
    role_key:          string,
    agent_template_id: string,
    count:             int,
    default_tier:      string,
    default_provider:  string,
}

Team_Chain_Scaffold_Task :: struct {
    key:              string,
    title_template:   string,
    role_key:         string,
    reviewer_role:    string,
    depends_on:       []string,
    description_key:  string,
}

Team_Chain_Scaffold :: struct {
    key:                       string,
    title_template:            string,
    pace:                      string, // fast | normal | slow
    expected_task_count:       int,
    collaborating_agent_count: int,
    tasks:                     []Team_Chain_Scaffold_Task,
}

Team_Kind_Def :: struct {
    key:                       string,
    display_name:              string,
    description:               string,
    pace:                      string,
    expected_task_count:       int,
    collaborating_agent_count: int,
    roles:                     []Team_Role_Slot,
    memory_templates:          []string,
    memory_templates_inherit_from_role: string,
    scaffolds:                 []Team_Chain_Scaffold,
    wants_vcs:                 bool,
    wants_vcs_follows_project: bool,
    idle_shutdown_ms:          int,
}
```

### Metadata semantics

- **`pace`** — user-facing workflow speed hint.
- **`expected_task_count`** — expected number of tasks for the kind default or a scaffold.
- **`collaborating_agent_count`** — visible collaboration size for the kind/scaffold.
- **`wants_vcs`** — default VCS preference when fixed on/off.
- **`wants_vcs_follows_project`** — used by `solo` to follow project VCS support by default.

## Active kinds

### 1. `coding`

Code changes, bug fixes, refactors, chores, and incidents with separate implementation, testing, and review responsibilities.

| Role | Template | Count | Default tier |
|---|---|---:|---|
| coordinator | `lead` | 1 | smart |
| coder | `coder` | 1 | normal |
| tester | `tester` | 1 | normal |
| reviewer | `reviewer` | 1 | smart |

- Kind metadata: `pace = normal`, `expected_task_count = 1`, `collaborating_agent_count = 4`
- `wants_vcs = true`
- Memory templates: `bootstrap-guidance`, `coding-conventions`, `git-hygiene`

Scaffolds:

| Scaffold | Pace | Tasks | Agents | Shape |
|---|---|---:|---:|---|
| `feature` | slow | 5 | 4 | `plan -> contracts -> implement -> test -> summary` |
| `bugfix` | fast | 4 | 4 | `reproduce -> fix -> test -> summary` |
| `refactor` | normal | 4 | 4 | `plan -> refactor -> test -> summary` |
| `chore` | fast | 2 | 4 | `apply -> summary` |
| `incident` | slow | 5 | 4 | `triage -> mitigate -> root-cause -> fix -> post-mortem` |

Invariant: Coding scaffolds do **not** assign reproduction, final test validation, or RCA validation to the coder when tester/coordinator ownership is intended.

### 2. `research`

Non-code investigation, RCA, synthesis, and analysis with a dedicated `researcher` template.

| Role | Template | Count | Default tier |
|---|---|---:|---|
| coordinator | `lead` | 1 | smart |
| researcher | `researcher` | 1 | smart |
| reviewer | `reviewer` | 1 | smart |

- Kind metadata: `pace = normal`, `expected_task_count = 1`, `collaborating_agent_count = 3`
- `wants_vcs = false`
- Memory templates: `bootstrap-guidance`, `research-method`, `source-hygiene`

Scaffolds:

| Scaffold | Pace | Tasks | Agents | Shape |
|---|---|---:|---:|---|
| `report` | slow | 4 | 3 | `scope -> gather -> synthesize -> summary` |
| `spike` | normal | 4 | 3 | `question -> explore -> conclude -> summary` |
| `analysis` | normal | 4 | 3 | `define -> investigate -> synthesize -> summary` |

The `researcher` role is backed by seeded prompt files:
- `src/prompts/researcher_persona.md`
- `src/prompts/researcher_instructions.md`

### 3. `solo`

A coordinator plus one worker, backed by a synthetic `user_proxy` reviewer that routes approvals to the operator.

| Role | Template | Count | Default tier |
|---|---|---:|---|
| coordinator | `lead` | 1 | smart |
| worker | `specialist` | 1 | normal |
| user_proxy | synthetic | 1 | — |

- Kind metadata: `pace = fast`, `expected_task_count = 1`, `collaborating_agent_count = 3`
- `wants_vcs_follows_project = true`
- Memory templates inherit from `worker`

Scaffolds:

| Scaffold | Pace | Tasks | Agents | Shape |
|---|---|---:|---:|---|
| `solo` | fast | 4 | 3 | `plan -> work -> user-review -> summary` |

## Absorbed legacy workflows

The old seven-kind model is intentionally consolidated:

| Legacy kind/workflow | New home |
|---|---|
| `debugging/bug` | `coding/bugfix` |
| `debugging/incident` | `coding/incident` |
| `ops/chore` | `coding/chore` |
| `writing/article` | `research/report` |
| `data-analysis/analysis` | `research/analysis` |

This keeps the UI and registry small while preserving common workflow shapes as scaffolds.

## UI expectations

The UI mirrors the baked metadata and should show:

- only `Coding`, `Research`, and `Solo`
- kind labels with pace and collaborating-agent counts
- scaffold labels with pace, expected task count, and agent count
- `none — 1 task (Coordinator discovery only)` for chains created without a scaffold
- Solo VCS default following project support instead of a hard-coded off default

## Tester role note

The consolidated model **does** include a `tester` role on `coding` only.

- The tester owns reproduction/final verification tasks in Coding scaffolds.
- The tester is **not** the default reviewer assignee.
- Review still happens through `lgtm_required` reviewer participation on work tasks.

## Adding or changing a kind

1. Update `src/daemon/team_kinds.odin`.
2. Update this document.
3. Update static UI metadata in `src/ui/components/teamKinds.ts`.
4. Update affected tests (`tests/team_kinds_test.odin`, `tests/team_service_test/main.odin`, and any template/UI checks).
5. Validate daemon and UI checks before merge.
