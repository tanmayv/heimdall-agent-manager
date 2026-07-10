# 10 · Review invariants and reviewer checklist

This is the canonical reviewer checklist cross-linked by the rest of `docs/teams-v1/`; self-reference path: [`10-review-invariants.md`](./10-review-invariants.md).

Every task in the `Introduce Teams model` chain is reviewed against the invariants below. Reviewers must cite the invariant they verified in their LGTM comment (e.g. "LGTM. Verified INV-1, INV-4, VCS-2.").

## Model-level (from [`01-model.md`](./01-model.md))

- **INV-1** No user-facing surface introduces a "start team" affordance on the main path (settings/debug pages exempt).
- **INV-2** No user-facing surface introduces a direct-to-agent chat composer on the main path.
- **INV-3** No user-facing feature name introduces a fourth noun beyond Project / Team / Task Chain / Agent.
- **INV-4** All VCS write ops require explicit user click. No automated `git push` / `jj git push` / `git merge` / `jj rebase`.
- **INV-5** Chain `completed` is the terminal state. Merge decision is an approval, not a state.
- **INV-6** Behavior is identical between git and jj backends beyond the specific backend calls.
- **INV-7** Non-VCS chains show no VCS UI/CLI cruft. Sections and buttons are absent, not disabled.

## Lifecycle (from [`03-lifecycle.md`](./03-lifecycle.md))

- **LC-1** No user CLI/UI action starts a team directly. Team allocation is inside `POST /task-chains`.
- **LC-2** Agents boot only on the triggers listed in §Boot triggers.
- **LC-3** Idle shutdown grace defaults to 30 minutes and is configurable per team kind.
- **LC-4** Boot budget: at most one concurrent boot per team_instance.
- **LC-5** Warm-on-focus uses `priority = low` and yields to `review_ready` boots.
- **LC-6** Chain completion archives team immediately for non-VCS chains and after merge decision for VCS chains.

## VCS (from [`04-vcs.md`](./04-vcs.md))

- **VCS-1** Backend interface is the sole abstraction; daemon and UI never call `git`/`jj` directly.
- **VCS-2** Workspace naming: git branch `team/<team_id>/<chain_slug>`; jj workspace `ws_<team_id>_<chain_slug>`; disk path `<worktree_root>/<team_slug>/<chain_slug>`.
- **VCS-3** `workspace_status`, `workspace_diff`, `merge_preview` do not mutate the working tree.
- **VCS-4** `merge_execute` runs only after operator click and is idempotent on retry.
- **VCS-5** `workspace_remove` respects `keep_on_archive` and writes a `.heimdall-kept` marker.
- **VCS-6** Backend selection is anchor-driven; auto-detect writes the resolved value back to the `vcs_kind` anchor.

## Memory (from [`05-memory.md`](./05-memory.md))

- **MEM-1** Every memory row has a non-empty `scope` after Task 15.
- **MEM-2** `Personal` memories are never returned to a non-auditor caller.
- **MEM-3** `Template` memories are never subject-filtered.
- **MEM-4** Wrapper fetch never issues more than three list calls per bootstrap.
- **MEM-5** Auditor default subject is `Team_Project`.

## Bootstrap (from [`06-bootstrap.md`](./06-bootstrap.md))

- **BS-1** Section order is fixed and identical across providers.
- **BS-2** `# Workspace` appears iff chain has a `vcs_workspace_id`.
- **BS-3** `# Team` roster reflects team_member rows at render time.
- **BS-4** `# Tools` never exceeds 400 lines of Markdown.
- **BS-5** Token count for a `coding` role member's `AGENTS.md` is ≤ 30% of pre-refactor size (measured on Task 9).

## UI (from [`07-ui.md`](./07-ui.md))

- **UI-1** No `Start Team` button on the main path.
- **UI-2** No direct-to-agent chat composer on the main path.
- **UI-3** `Needs attention` is the sole funnel for approvals, blocks, merge decisions.
- **UI-4** `+ New chain` is available under every project in the sidebar.
- **UI-5** Chain view chat composer sends only to coordinator.
- **UI-6** Workspace box appears iff chain has a `vcs_workspace_id`.
- **UI-7** Every interactive element has a `data-debug-id` per AGENTS.md convention.

## API / config (from [`08-http-and-cli.md`](./08-http-and-cli.md))

- **API-1** `POST /teams/start` does not exist on the main API surface.
- **API-2** VCS write endpoints require operator token; agent tokens can only call read endpoints.
- **API-3** Chat from `operator@local` routes to the chain's coordinator on the main path.
- **CFG-1** No new `config.toml` key requires per-agent tuning to run the common path.

## Migration (from [`09-migration.md`](./09-migration.md))

- **MIG-1** Migration is env-gated (`HEIMDALL_MIGRATE_V1=1`) and idempotent on rerun.
- **MIG-2** Migration writes a Markdown report at `<data_dir>/migrations/`.
- **MIG-3** Anchor rewrites never lose data (dropped anchors are appended to `project.description`).
- **MIG-4** Task 14 begins by backing up `data_dir` and can restore on failure.
- **MIG-5** Migration test runs against a **copy** of the operator's `data_dir` on a **non-default port daemon**; never touches the live DB.

## Task-authoring conventions

Every task in the chain must:

1. Cite the doc section it implements in the description (e.g. "Implements §3.6 of `docs/teams-v1/03-lifecycle.md`").
2. List **explicit non-goals** so reviewers can reject scope creep.
3. State the **acceptance evidence** the assignee must attach in the completion comment (paths, commands, output snippets).
4. Reference the invariant IDs the reviewer must verify.

Reviewer LGTM template:

```
LGTM.
- Verified: INV-<id>, LC-<id>, ...
- Evidence checked: <what and where>
- Follow-ups filed: <task ids or none>
```

Reviewer NGTM template:

```
Requesting changes.
- Invariant violated: <id>
- Where: <file:line>
- Suggested fix: <one sentence>
```
