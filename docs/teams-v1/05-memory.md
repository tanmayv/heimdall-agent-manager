# 05 · Memory scope rework

Memory targeting narrows to what users actually reason about: **which team/project/template context a memory applies to, plus optional role/task-chain qualifiers.**

Reviewer checklist: memory work is reviewed against [`10-review-invariants.md`](./10-review-invariants.md), especially `MEM-*` invariants.

## New scope enum

```
Memory_Scope :: enum {
    Team_Project,   // primary collaborative scope
    Project,        // project-wide guidance
    Template,       // curated, referenced by config/kind
    Personal,       // per-agent private scratch / quirks
}
```

`Personal` remains for the auditor's private scratch and for one-off per-agent quirks, but **is not broadly surfaced to ordinary users**. `Global` collapses into `Template`.

## Canonical public targeting

Memory APIs and UI now expose canonical targeting fields instead of deprecated legacy subject fields:

- `scope`
- `agent_instance_id`
- `team_id`
- `template_key`
- `project_ids[]`
- `role_keys[]`
- `task_chain_types[]`

Internally, legacy DB compatibility storage may still retain deprecated `subject_*` columns during migration/readback, but those fields are no longer part of the active public contract.

## Wrapper fetch order

`fetch_all_active_memories` in `src/wrapper/main.odin` is collapsed to three sources, rendered last-wins:

```
1. Template memories       — from Team_Kind_Def.memory_templates + agent_cmd overrides.
2. Project memories        — scope=Project with project_ids containing the active project.
3. Team_Project memories   — scope=Team_Project with matching team_id + project_ids.
```

Fetch calls (each is a POST to `/memory` action=`memory_list`):

```json
{ "action": "memory_list", "scope": "template", "status": "active" }
{ "action": "memory_list", "scope": "project", "project_ids": ["<project_id>"], "status": "active" }
{ "action": "memory_list", "scope": "team_project", "team_id": "<team_id>", "project_ids": ["<project_id>"], "status": "active" }
```

Then render:

- **Template** — bullet-referenced (title + memory_id).
- **Project** — inline for `Expertise` / `Habit`; referenced for `Fact` / `Episode` (bodies in `MEMORY.md` if enabled).
- **Team_Project** — same rules as Project but rendered last so it visually dominates.

The legacy `active_memory_bootstrap` path is deleted.

## Proposing memories

`ham-ctl memory propose new` and API `/memory` accept `scope` plus canonical targeting fields:

```
--scope team_project --team <team_id> --project <project_id>
--scope project      --project <project_id>
--scope template     --template-key <slug>
--scope personal     --agent-instance-id <agent_instance_id>
```

Optional qualifiers:

- `--project-ids <csv>`
- `--role-keys <csv>`
- `--task-chain-types <csv>`

Server normalizes these canonical fields and may derive internal compatibility storage as needed, but callers should not rely on deprecated subject fields.

## Auditor default target

`handle_post_task_chain_audit` uses the chain's `team_id` + `project_id` and proposes memories at `Team_Project` scope by default:

- Proposed memories from the audit run have `scope = Team_Project`, `team_id = <team>`, `project_ids = [<project>]`.
- The auditor may propose `Project`-scope memories when the learning is agent-independent (for example: "this repo builds with nix, not cargo").
- The auditor may add `role_keys` / `task_chain_types` when the lesson only applies to a narrower collaboration pattern.

## Memory decision (approve/reject) flow

Unchanged except that reviewer prompts and UI surfaces reason about canonical target fields (`scope`, `team_id`, `project_ids`, `role_keys`, `task_chain_types`, `template_key`) instead of deprecated subject keys.

## Effective memory panel (UI)

The chain view drawer computes and shows effective memory for `(chain.team_id, chain.project_id)` from the same three sources in the same order. Read-only. Not editable from the drawer.

## Invariants

- **MEM-1** Every memory row has a non-empty `scope` after migration.
- **MEM-2** `Personal` memories are never returned to a non-auditor caller.
- **MEM-3** `Template` memories are never subject-filtered; they apply by template targeting.
- **MEM-4** Wrapper fetch never issues more than three list calls per bootstrap.
- **MEM-5** Auditor default scope for chain-audit proposals is `Team_Project`.
