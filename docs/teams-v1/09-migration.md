# 09 · Legacy migration

Existing data must survive this refactor. Migration runs once, gated by an env flag, produces a report file, and is idempotent on rerun.

## Trigger

Daemon startup: if `HEIMDALL_MIGRATE_V1=1` is set **and** the `teams` table is empty and `task_chains.team_id` column is null-populated only, run the migration. Otherwise skip.

Report: `<data_dir>/migrations/teams-v1-<timestamp>.report.md`.

## Steps

### 9.1 Agent-instance sweep → legacy solo teams

For every `agent_instance_records` row that:

- is not `archived`, and
- has no `team_id` (all today's rows),

create a synthetic team instance:

```
team_instance {
  team_id           = "legacy-<agent_instance_id>"
  kind              = "solo"
  project_id        = agent.project_id or "_orphan"
  status            = "idle"        # not archived; still runnable if wrapper reconnects
  created_unix_ms   = min(agent.created_unix_ms, now)
}
team_member {
  team_id           = "legacy-<agent_instance_id>"
  role_key          = "worker"
  role_index        = 0
  agent_record_id   = agent.agent_record_id
  is_user_proxy     = false
}
team_member {
  team_id           = "legacy-<agent_instance_id>"
  role_key          = "user_proxy"
  role_index        = 0
  agent_record_id   = NULL
  is_user_proxy     = true
  route_to          = "operator@local"
}
```

Rationale: every existing agent becomes a solo team-of-one so it continues to run and be visible. Users can archive at their leisure.

### 9.2 swe-team preservation

**Special case (from planning):** the `swe-team` "project" is being used today as an agent container. Preserve its members as a real team **on the `swe-team` project** first, then let subsequent chains that reference the `heimdall-agent-manager` project attach their own teams.

- Insert `team_instance { team_id = "swe-team-legacy", kind = "coding", project_id = "swe-team", status = "idle" }`.
- Members: `principal@swe-team` → coordinator; `coder@swe-team` → coder; `reviewer@swe-team` → reviewer; `tester@swe-team` → roster (idle); `planner@swe-team`, `researcher@swe-team`, `risk-analyst@swe-team` → roster with role `specialist` (informational).
- Do **not** overwrite the individual solo teams from 9.1 for the same agents. If both exist, 9.2 rows take precedence for `agent → team` resolution.

### 9.3 Task chain back-fill

For every `task_chains` row with null `team_id`:

- If `chain.coordinator_agent_instance_id` matches a team's coordinator, attach that team.
- Otherwise attach `"legacy-<coordinator_agent_instance_id>"`.
- Insert a `chain_team_assignment` row equivalent (or the direct `team_id` column, per Task 7 schema).

The **currently-in-flight `Introduce Teams model` chain** (this chain) is attached to `swe-team-legacy` at Task 7 execution, before Task 14 runs the wholesale migration.

### 9.4 Memory rewrite

For every `memories` row:

- Compute new `scope` and `subject_key`:
  - If `subject_agent` matches a real agent → `scope = Team_Project`, `subject_key = "tp:<resolve_team(agent)>:<agent.project_id or "_orphan">"`.
  - If `subject_agent` matches a heimdall-system agent → `scope = Template`, `subject_key = "tmpl:<title_slug>"`.
  - If `subject_agent` is empty and `title` matches a template scope → `Template`.
- Idempotent: rerun leaves rows alone if `scope` is already set.

Persist a mapping table `memory_migration_map(memory_id, old_scope, old_subject, new_scope, new_subject_key)` for auditability.

### 9.5 Anchor migration

For every project, walk anchors:

- Anchor `type` in closed vocabulary (`git_repo`, `base_ref`, `vcs_kind`, `worktree_root`, `docs`, `scratch`): keep as-is.
- Anchor `type = "directory"` (the old free-form default): rewrite to `git_repo` if a `.git` or `.jj` directory exists at the path; else move to `docs` (with the original `note` preserved) if it looks like a docs path; else move to `scratch`.
- Anchor `type` outside the vocabulary: append `"[migrated anchor]  <type>: <value>  (note: <note>)"` line to `project.description`, then drop the anchor.

Emit a per-project entry in the report file listing every transformation.

### 9.6 VCS workspace pre-provisioning

**Do not** pre-provision workspaces for existing chains. Migration only makes the data model consistent; workspaces are created on the next chain create.

### 9.7 Config file compatibility

If daemon boot reads a `config.toml` with deprecated keys (`wrapper.project`, `wrapper.memory_templates`, per-cmd `project`, `bootstrap.<FEATURE>.content`):

- Log one WARN per key at boot.
- Do not apply the deprecated values.
- Continue.

Deletion of these keys is scheduled for Task 17.

## Idempotency

- Every insert uses `INSERT OR IGNORE` on natural keys.
- Every rewrite guarded by "already set" check.
- Rerun is a no-op after successful first run.
- If migration fails midway, transactions roll back per section. Partial state on 9.1/9.3 is safe to rerun.

## Report file

Markdown, one section per migration step, with:

- Counts before/after.
- List of rows moved/rewritten.
- Any anchors dropped (with their old values).
- Any memory rows that could not be resolved (kept `subject_key = ""` and flagged).

Filed under `<data_dir>/migrations/`. Operator inspects before removing `HEIMDALL_MIGRATE_V1=1` from env.

## Rollback

Migration is destructive on anchor rewrites and memory subject_keys. Backup requirement in Task 14 acceptance:

- Task 14 begins with `cp -R <data_dir> <data_dir>.pre-teams-v1`.
- On failure, `mv` the backup back and remove `teams.db`, `vcs.db`.
- Documented in the report file.

## Test scenario (Task 14.T)

- Copy the operator's real `data_dir` to `<data_dir>-test-<timestamp>` (never operate on the live one during testing).
- Point a **separate daemon instance on a non-default port** at the copy.
- Run migration on the copy.
- Assert:
  - Every previously-listed agent still appears in `ham-ctl agents list`.
  - Every previously-existing chain has `team_id` set.
  - `ham-ctl memory list` returns non-zero counts and no rows have empty `scope`.
  - Report file is well-formed Markdown and enumerates every transformation.

Reviewer confirms by diffing before/after listings; risk-analyst signs off on Task 14 (see [`10-review-invariants.md`](./10-review-invariants.md)).

## Migration invariant mapping

- **MIG-1** maps to the env-gated trigger and idempotency rules above.
- **MIG-2** maps to the Markdown report requirement under `<data_dir>/migrations/`.
- **MIG-3** maps to the anchor migration rule that preserves dropped anchors in `project.description`.
- **MIG-4** maps to the rollback requirement that Task 14 begins by backing up `data_dir`.
- **MIG-5** maps to the test scenario requiring a copied data directory and a non-default-port daemon.
