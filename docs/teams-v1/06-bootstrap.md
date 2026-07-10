# 06 · Wrapper bootstrap redesign

Every wrapper writes an `AGENTS.md` (or `CLAUDE.md` for the Claude profile) into its cwd at boot. This file is the agent's operating manual for the session.

Reviewer checklist: bootstrap work is reviewed against [`10-review-invariants.md`](./10-review-invariants.md), especially `BS-*` invariants.

## New section list

Old sections (`IDENTITY / GUIDANCE / PROJECT / MEMORY`) replaced by:

```
# You
# Project
# Task Chain
# Team
# Workspace                (only if VCS-backed)
# Memory
# Tools
```

Sections are always emitted in this order. Empty sections are omitted (e.g. no `# Workspace` on non-VCS chains).

### 6.1 `# You`

- `display_name`
- `agent_instance_id`
- `role_key` within the team
- `role_index` (if `count > 1` for the role)
- `agent_token` (the bearer; short-lived)
- `start-success` command reminder (verbatim, first thing to run)

### 6.2 `# Project`

- `project_id`, `name`, `description`
- Anchors (closed vocabulary only), rendered as a table:
  - `git_repo`, `base_ref`, `vcs_kind`, `worktree_root`, `docs`, `scratch`
- If `vcs_kind == "none"`, the section notes "no VCS bindings" but is still emitted.

### 6.3 `# Task Chain`

- `chain_id`, `title`
- `chain.description` (the goal + scope + non-goals + reviewer expectations)
- Current task, if any (`current_task_id` from the agent record)
- Coordinator name
- Reviewer(s) for the chain (default_reviewer_agent_instance_id + any role-mapped reviewers)
- Number of tasks in each state (planned, ready, in-progress, review-ready, done)

### 6.4 `# Team`

- Team id, kind, status (`live | warming | idle`)
- Full roster with role_key, role_index, `live | idle | archived`
- Coordinator name repeated (emphasis: "route user-facing decisions through the coordinator")
- Reminder: agents shut down after **30 min idle** unless a task, mention, or nudge keeps them alive.

### 6.5 `# Workspace` (only if VCS)

- `path`, `vcs_kind`, `branch_or_change`, `base_ref`
- One-line status summary (`3 modified, 1 added`)
- Do-not-instructions:
  - Do not `cd` outside this workspace.
  - Do not run `git push` / `jj git push` — merge is user-approved.
  - Use `ham-ctl workspace pull` to sync base ref.

### 6.6 `# Memory`

Rendered from the three-source fetch (see [`05-memory.md`](./05-memory.md)):

- Template memory (bulleted references)
- Project memory (inline for expertise/habit, referenced otherwise)
- Team+project memory (inline for expertise/habit, referenced otherwise)

Section header notes explicitly: *"Only active approved memory is included. Pending/rejected/archived are excluded."*

### 6.7 `# Tools`

Compact ham-ctl guide (task/chat/memory/workspace). This replaces most of today's `bootstrap_profile_guidance.md`, which balloons every bootstrap. The full detailed guide moves to `ham-ctl help work-guide` (a subcommand that prints the long form). See [`08-http-and-cli.md`](./08-http-and-cli.md).

Token-count target: total generated `AGENTS.md` for a typical `coding` team member should be **≤ 30%** of today's size. Reviewer on Task 9 confirms with a byte-count diff.

## What's removed

- `# Guidance` section header (content redistributed into `# Team` and `# Tools`).
- `active_memory_bootstrap` code path.
- `bootstrap_defaults` opaque JSON on templates (unused; deleted from schema).
- Per-agent-cmd `bootstrap.*` overrides in `config.toml` (deprecated; see [`08-http-and-cli.md`](./08-http-and-cli.md)).
- `MEMORY.md` when there are no `Fact`/`Episode` memories (previously written as an empty stub).
- `skills/*/SKILL.md` writing when the profile does not opt in (previously emitted for all providers).

## Managed-file rules (unchanged)

- Every generated file starts with `BOOTSTRAP_HEADER` sentinel.
- `.heimdall-bootstrap-manifest` records what was written; only manifested files are removed on cleanup.
- `can_write_managed_file` still refuses to overwrite a file that doesn't carry the header.

## Feature-flag config surface

Existing `[wrapper.agent-cmd.<name>.bootstrap.<FEATURE>]` sections (`AGENTS_MD`, `MEMORY_MD`, `SKILLS`) remain as **profile-scoped** knobs for name/relative_dir/filename customization. `content = ["IDENTITY", ...]` per-section becomes obsolete (sections are fixed above).

New feature flag on `AGENTS_MD`:

```toml
[wrapper.agent-cmd.<name>.bootstrap.AGENTS_MD]
name = "AGENTS.md"    # or CLAUDE.md for claude profile
```

That's the only remaining knob. `content` is dropped from the schema.

## Invariants

- **BS-1** Section order is fixed and identical across all providers.
- **BS-2** `# Workspace` appears iff chain has a `vcs_workspace_id`.
- **BS-3** `# Team` roster reflects team_member rows at render time (not stale cache).
- **BS-4** `# Tools` never exceeds 400 lines of Markdown. Longer content lives in `ham-ctl help work-guide`.
- **BS-5** Token count for a `coding` role member's `AGENTS.md` is ≤ 30% of pre-refactor size (measured on Task 9).
