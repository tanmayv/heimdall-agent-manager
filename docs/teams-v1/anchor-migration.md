# Anchor migration inventory for teams-v1

Implements the pre-flight anchor audit requested by `task-19f4b58f2ab`, using the closed anchor vocabulary locked for teams-v1:

- `git_repo`
- `base_ref`
- `vcs_kind`
- `worktree_root`
- `docs`
- `scratch`

## Source and constraints

- Inventory source: `ham-ctl projects list --token …` against the current daemon.
- This is a read-only audit. No live project data was modified.
- The detailed spec files referenced by the task (`docs/teams-v1/04-vcs.md` §Project VCS binding and `docs/teams-v1/09-migration.md` §Anchor migration) were not present in the worktree at audit time, so this mapping follows the task text, chain-level locked decision for the closed vocabulary, and `docs/teams-v1/batches.md` Batch B anchor rules.

## Project anchor inventory and proposed mapping

| Project ID | Project name | Current anchor type | Current anchor value | Note | Proposed teams-v1 anchor | Proposed value | Migration action | Reversible mapping note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `project_1781875425386` | `Deep Dive Research` | `directory` | `/Users/tanmayvijay/Documents/superwhisper` | `Project Code Directory` | `git_repo` | `/Users/tanmayvijay/Documents/superwhisper` | Rename anchor type from `directory` → `git_repo`; preserve value and note in migration report. | Original type/value/note are fully preserved by this table, so the rewrite can be reversed if needed. |
| `heimdall-agent-manager` | `Heimdall Agent Manager` | `directory` | `/Users/tanmayvijay/heimdall-agent-manager` | `User-confirmed project directory` | `git_repo` | `/Users/tanmayvijay/heimdall-agent-manager` | Rename anchor type from `directory` → `git_repo`; preserve value and note in migration report. | Original type/value/note are fully preserved by this table, so the rewrite can be reversed if needed. |

## Anchors that will move into description prose

None from the current live anchor inventory.

All anchors currently in use are `directory` anchors that appear to denote repository roots, so they map directly to the closed-vocabulary `git_repo` anchor without losing information.

## Projects with no anchors today

These projects currently have no anchors and therefore require no anchor rewrite in the migration mapping table:

- `heimdall-system`
- `project_1782833506062`
- `project_1782833510248`
- `project_1782843846935`
- `project_1782843850321`
- `project_1782896046861`
- `project_1782896050459`
- `project_1782896150707`
- `project_1782896154053` (`ExcaliType`)
- `swe-team`

## Notes for migration execution

1. `directory` is the only legacy anchor type currently in use.
2. For the current inventory, `directory` should map to `git_repo` when the anchor note/value indicates a project code root.
3. No current anchor requires splitting into multiple closed-vocabulary anchors.
4. No current anchor requires description-only fallback to satisfy the closed vocabulary.
5. The mapping is reversible because the original project ID, anchor type, anchor value, and anchor note are all captured above.

## Follow-up observations (non-blocking)

- `project_1782896154053` (`ExcaliType`) includes `Project dir: ~/excali-type` in description prose but has no structured anchor. That is outside this read-only live-anchor inventory, but it is a candidate for a future explicit `git_repo` anchor if/when that project is normalized.
