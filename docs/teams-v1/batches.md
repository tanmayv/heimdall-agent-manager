# Teams v1 operational batches

Task chain: `chain-teams-v1` / `Introduce Teams model`.

This document is the pre-flight operating plan for the cognitive batches used by the chain. It is not a merge or deployment plan. The implementation remains autonomous and agent-reviewed, with the operator involved only for the final chain review or a genuinely blocked decision.

## Non-negotiable runtime guardrails

- **Do not restart the live daemon.** The operator's live daemon/session must remain untouched for the entire chain.
- **Do not install chain builds.** Build outputs land only in local Nix result symlinks such as `./result-*`; do not run `nix profile install` and do not overwrite `~/.local/bin/ham-daemon`, `~/.local/bin/ham-wrapper`, or `~/.local/bin/ham-ctl`.
- **Do not touch the live data directory.** Functional and migration verification must use a copied `data_dir`, never `~/.local/share/heimdall/` directly.
- **Use a test daemon for functional verification.** Any daemon-backed functional test runs against a separate daemon instance on **port `49422`** with its own copied data directory.
- **VCS writes remain operator-gated.** The chain may build and test local artifacts, but it must not merge, push, or modify the operator's live runtime.

## Required build artifacts for every batch gate

Before the coordinator advances from any batch, the affected implementation tasks for that batch must have produced successful local builds of the core artifacts:

```bash
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
```

Expected artifacts are local `./result-*` symlinks only. They are used for verification and handoff; they are not installed into the operator's live environment.

## Batch A — Core team model and read-only surfacing

**Tasks:** 1–6

**Purpose:** Establish the closed team-kind registry, team data model, read-only team observability, and CLI listing/showing surfaces without changing existing task-chain ownership semantics yet.

**Tests that must pass before advancing:**

- Team-kind registry/unit coverage for the seven locked kinds: `coding`, `research`, `debugging`, `data-analysis`, `writing`, `ops`, and `solo`.
- Teams DB initialization/migration tests on a scratch data directory.
- Read-only HTTP tests for `/teams`, `/teams/{team_id}`, and `/teams/{team_id}/members`.
- CLI smoke tests for `ham-ctl teams list` and `ham-ctl teams show` against the test daemon on port `49422`.
- Regression checks that no `POST /teams/start` main-path endpoint or `ham-ctl teams start` command is introduced.

**Artifacts that must be built:**

```bash
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
```

**Coordinator verifies:**

- The team kind set is closed and matches `docs/teams-v1/02-team-kinds.md`.
- Testers are not permanent reviewer slots on any team kind.
- Team HTTP/CLI surfaces are read-only observability surfaces; there is no user-facing start-team affordance.
- Evidence comments cite relevant invariants, especially `INV-1`, `INV-3`, `LC-1`, and `API-1`.

## Batch B — Chain/team binding, solo routing, bootstrap, and anchors

**Tasks:** 7–10

**Purpose:** Bind task chains to teams, implement the solo `user_proxy` review path, redesign generated bootstrap files around chain/team context, and enforce the closed project-anchor vocabulary.

**Tests that must pass before advancing:**

- Task-chain schema tests showing `team_id` is populated and existing chain operations still work.
- Solo-mode tests proving `user_proxy` routes approvals to `operator@local` without adding a permanent tester reviewer slot.
- Bootstrap rendering tests for the fixed section order: `You`, `Project`, `Task Chain`, `Team`, optional `Workspace`, `Memory`, `Tools`.
- Bootstrap size/line checks, including `# Tools` ≤ 400 lines and the Task 9 token/byte-count comparison target.
- Anchor validation/migration-prep tests proving only `git_repo`, `base_ref`, `vcs_kind`, `worktree_root`, `docs`, and `scratch` are accepted on the main path.

**Artifacts that must be built:**

```bash
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
```

**Coordinator verifies:**

- User chat remains coordinator-routed; no direct-to-agent main-path composer appears.
- Generated bootstrap content contains chain/team context and omits legacy per-agent project/bootstrap override semantics.
- Solo review behavior is auditable and uses the synthetic `user_proxy` pattern from the spec.
- Evidence comments cite relevant invariants, especially `INV-2`, `BS-1` through `BS-5`, `API-3`, and closed-anchor expectations from `VCS-6`/migration docs.

## Batch C — VCS backend abstraction and workspace provisioning

**Tasks:** 11–13

**Purpose:** Introduce the VCS abstraction for git worktrees and jj workspaces, provision per-chain workspaces, and connect workspace-aware chain scaffolds without allowing automated merge/push behavior.

**Tests that must pass before advancing:**

- Git backend tests on scratch repos for workspace add/status/diff/pull-base/merge-preview/remove.
- Jj backend tests on scratch repos for workspace add/status/diff/pull-base/merge-preview/remove.
- Workspace provisioning tests proving names follow the spec:
  - git branch: `team/<team_id>/<chain_slug>`
  - jj workspace: `ws_<team_id>_<chain_slug>`
  - disk path: `<worktree_root>/<team_slug>/<chain_slug>`
- Chain-create tests proving VCS workspaces are created only when project anchors and chain settings require them.
- Negative tests proving non-VCS chains have no workspace UI/API/CLI cruft.

**Artifacts that must be built:**

```bash
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
```

**Coordinator verifies:**

- Daemon and UI call VCS only through the backend interface; no direct git/jj calls leak outside the abstraction.
- Status, diff, and merge-preview paths are non-mutating.
- Any merge/forget/write operation remains operator-token and explicit-click gated.
- Evidence comments cite relevant invariants, especially `INV-4`, `INV-6`, `INV-7`, and `VCS-1` through `VCS-6`.

## Batch D — Migration, memory, lifecycle completion, UI, and lazy boot

**Tasks:** 14–18 plus supporting UI/nudge tasks 19–25

**Purpose:** Complete the risky integration layer: legacy migration, memory-scope rewrite, merge/archive lifecycle, config cleanup, end-to-end validation, UI reshape, and nudge-scheduler lazy boot/shutdown support.

**Tests that must pass before advancing or closing the chain:**

- Migration dry run against a copied operator data directory with a separate daemon on port `49422`; never against the live DB.
- Migration assertions from `docs/teams-v1/09-migration.md`: agents still list, every existing chain has `team_id`, memory rows have non-empty `scope`, and the Markdown report is well formed.
- Memory-scope tests for `Team_Project`, `Project`, `Template`, and internal-only `Personal` behavior.
- Lifecycle tests for non-VCS completion immediate archive and VCS completion merge-decision pending behavior.
- Config cleanup/deprecation tests for removed per-agent tuning keys.
- UI tests for Home, Needs attention, Chain view, Settings, workspace visibility, coordinator-only chat, and required `data-debug-id` values.
- Nudge-scheduler/lazy-boot tests for boot triggers, warm-on-focus low priority, one concurrent boot per team instance, and 30-minute idle shutdown defaults.
- End-to-end test using only the test daemon on port `49422` and local `./result-*` artifacts.

**Artifacts that must be built:**

```bash
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
```

**Coordinator verifies:**

- The live daemon was never restarted and the live data directory was never modified.
- Migration evidence includes backup/copy paths, report paths, before/after summaries, and confirms idempotency.
- `Needs attention` is the single funnel for approvals, blocks, and merge decisions.
- Lazy boot comes from scheduler triggers rather than user-facing start-team controls.
- Chain completion semantics match the spec: `completed` is terminal; VCS merge decision is an approval item, not a new chain state.
- Evidence comments cite relevant invariants, especially `LC-2` through `LC-6`, `MEM-1` through `MEM-5`, `MIG-1` through `MIG-5`, `UI-1` through `UI-7`, `API-2`, and `CFG-1`.

## Coordinator advancement checklist

At every batch boundary, the coordinator should confirm and record in task comments:

1. All tasks in the batch are terminal and have required reviewer LGTMs.
2. Required tests for the batch passed with command snippets and output summaries.
3. `nix build .#ham-daemon .#ham-wrapper .#ham-ctl` passed for the batch's final state.
4. Functional checks, when daemon-backed, used the test daemon on port `49422` and a copied data directory.
5. No task restarted the live daemon, installed artifacts globally, touched the live DB, pushed, merged, or committed to `main`.
6. Follow-up risks are either resolved, captured in dependent tasks, or explicitly accepted in the chain summary.
