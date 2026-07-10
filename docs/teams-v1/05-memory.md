# 05 · Memory scope rework

Memory scope narrows to what users actually reason about: **"how this team works in this project."**

Reviewer checklist: memory work is reviewed against [`10-review-invariants.md`](./10-review-invariants.md), especially `MEM-*` invariants.

## New scope enum

```
Memory_Scope :: enum {
    Team_Project,   // subject = (team_instance_id, project_id)   ← primary
    Project,        // subject = project_id
    Template,       // curated, referenced by config/kind
    Personal,       // subject = agent_instance_id                ← internal only
}
```

`Personal` remains for the auditor's private scratch and for one-off per-agent quirks, but **is not proposable via `ham-ctl memory propose new`**. `Global` collapses into `Template`.

## Schema change

`memories` table gains `scope TEXT` and `subject_key TEXT`. `subject_agent` is retained for migration lookback but is no longer authoritative.

```sql
ALTER TABLE memories ADD COLUMN scope       TEXT NOT NULL DEFAULT 'personal';
ALTER TABLE memories ADD COLUMN subject_key TEXT NOT NULL DEFAULT '';

CREATE INDEX idx_memories_scope_subject ON memories(scope, subject_key, status);
```

`subject_key` encoding:

- `Team_Project` → `"tp:<team_id>:<project_id>"`
- `Project` → `"pr:<project_id>"`
- `Template` → `"tmpl:<template_key>"` (template_key comes from the memory title slug)
- `Personal` → `"agent:<agent_instance_id>"`

Migration path in [`09-migration.md`](./09-migration.md) rewrites old `subject_agent = X` rows to `scope = Team_Project` with `subject_key = "tp:<legacy-team>:<X.project_id>"`.

## Wrapper fetch order

`fetch_all_active_memories` in `src/wrapper/main.odin` is collapsed to three sources, rendered last-wins:

```
1. Template memories       — from Team_Kind_Def.memory_templates + agent_cmd overrides.
2. Project memories        — scope=Project, subject_key="pr:<project_id>".
3. Team_Project memories   — scope=Team_Project, subject_key="tp:<team_id>:<project_id>".
```

Fetch calls (each is a POST to `/memory` action=memory_list):

```json
{ "action": "memory_list", "scope": "template", "status": "active" }
{ "action": "memory_list", "scope": "project",  "subject_key": "pr:<project_id>", "status": "active" }
{ "action": "memory_list", "scope": "team_project", "subject_key": "tp:<team_id>:<project_id>", "status": "active" }
```

Then render:

- **Template** — bullet-referenced (title + memory_id).
- **Project** — inline for `Expertise` / `Habit`; referenced for `Fact` / `Episode` (bodies in `MEMORY.md` if enabled).
- **Team_Project** — same rules as Project but rendered last so it visually dominates.

The legacy `active_memory_bootstrap` path is deleted.

## Proposing memories

`ham-ctl memory propose new` and API `/memory` accept `scope` and either `subject_key` or the pair fields:

```
--scope team_project --team <team_id> --project <project_id>
--scope project      --project <project_id>
--scope template     --template-key <slug>
```

Server derives `subject_key`. If both are provided and conflict, request is 400.

`Personal` cannot be proposed via user CLI; only internal callers (auditor orchestrator) may write personal memories.

## Auditor default subject

`handle_post_task_chain_audit` currently expects a `subject_agent`. It now takes the chain's `team_id` + `project_id` and proposes memories at `Team_Project` scope by default:

- Proposed memories from the audit run have `scope = Team_Project`, `subject_key = "tp:<team>:<project>"`.
- The auditor may propose `Project`-scope memories when the learning is agent-independent ("this repo builds with nix, not cargo"). This is a per-proposal decision made by the auditor prompt.

## Memory decision (approve/reject) flow

Unchanged except that `memory_reviewer` prompts receive `subject_key` and are expected to reason about scope fit. If a proposal's scope is too narrow or too broad, the reviewer may reject with a suggested corrected scope; requester re-proposes.

## Effective memory panel (UI)

The chain view drawer computes and shows effective memory for `(chain.team_id, chain.project_id)` from the same three sources in the same order. Read-only. Not editable from the drawer.

## Invariants

- **MEM-1** Every memory row has a non-empty `scope` after migration.
- **MEM-2** `Personal` memories are never returned to a non-auditor caller.
- **MEM-3** `Template` memories are never subject-filtered (they apply broadly).
- **MEM-4** Wrapper fetch never issues more than three list calls per bootstrap.
- **MEM-5** Auditor default scope for chain-audit proposals is `Team_Project`.
