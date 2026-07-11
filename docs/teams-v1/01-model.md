# 01 · The three-noun model

The user-facing conceptual model has exactly three nouns: **projects**, **teams**, and **task chains**. Agents are internal plumbing that materialize when work needs them.

## The three nouns

```
PROJECT      A body of work with optional VCS binding (repo + base ref).
             Long-lived. Owns anchors and durable project memory.

TEAM         The fixed-role group behind one task chain. A team is visible as
             kind + roster + live/idle status, but the user never starts it
             directly; it materializes with the chain and boots lazily.

TASK CHAIN   One focused effort inside a project (feature, bugfix, research
             question, refactor). The unit the user tracks and the unit the
             VCS workspace is attached to.
```

Agents are members of the lazy team behind a chain. They are not directly created by the user on the main path; they boot when work requires them. Team instances live and die with their chain, and the main UI shows the team as the chain's kind/roster/status rather than as a separate startable resource.

## What the user does

Three verbs, and only three appear in the main UI/CLI:

```
Create a project            (rare; once per body of work)
Open a new chain            (frequent; every focused effort)
Approve / decide            (constant; approvals, unblocks, merge decisions)
```

Everything else — starting teams, choosing providers, picking model tiers, assigning agents to tasks — is derived from `(project, chain kind)` and defaults.

## Vocabulary lock-in

- We do **not** introduce a "workstream" noun. The UI already understands "task chain" and users can too.
- We do **not** expose "team instance" as a user surface. It's a record with an ID; users see it only as the chain's coordinator + roster.
- We do **not** call chains "workspaces". A workspace is the VCS artifact attached to a chain.

## What's cut from the current system

Removed entirely from the user surface (some kept as debug affordances under Settings):

| Cut | Why |
|---|---|
| `ham-ctl agents start` on the main path | Solo work = `+ New chain` with kind = solo. Agents are internal. |
| `--project-id` on wrapper CLI | Wrappers are started by the daemon as team members; they know their chain. |
| `wrapper.project`, `wrapper.memory_templates`, per-cmd `project`, `bootstrap.*` overrides in `config.toml` | Team kind decides these. Config becomes daemon/provider settings only. |
| Model tier / provider selection at chain start | Kind implies defaults; overrides move behind `Advanced` disclosure. |
| Free-form project anchors | Replaced by closed vocabulary (see [`04-vcs.md`](./04-vcs.md)). |
| `active_memory_bootstrap` legacy path in wrapper | Collapses into `render_memory_for_agents_md`. |
| `bootstrap_defaults` opaque JSON on agent templates | Bootstrap decided by kind + chain context, not per-template overrides. |
| Global `Chat` tab in UI | Chats live inside a chain. |
| `Agents` tab in UI | Moved to Settings as raw registry. |
| `Memory` tab in UI | Moved to Settings as browser; effective memory shown per-chain. |
| Start-Agent page in UI | Deleted. Replaced by "+ New chain". |
| Pending-tasks tab in UI | Merged into per-chain board + `Needs attention` tab. |
| Team-instance start/stop endpoints and `ham-ctl teams start` | Team materializes when a chain is created; nothing to start. |

## What's added

| Added | Why |
|---|---|
| Closed team-kind registry in code (see [`02-team-kinds.md`](./02-team-kinds.md)) | Prevents role sprawl; one lookup for defaults. |
| Lazy boot in nudge scheduler (see [`03-lifecycle.md`](./03-lifecycle.md)) | Zero-cost teams when idle; auto-provision on demand. |
| `Team_Project` memory scope (see [`05-memory.md`](./05-memory.md)) | "How this team works in this project" — the durable learning surface. |
| VCS backend interface for git + jj (see [`04-vcs.md`](./04-vcs.md)) | Parallel work streams via worktrees/workspaces, backend-agnostic. |
| Chain scaffolds (see [`02-team-kinds.md`](./02-team-kinds.md)) | Team kind implies a default task graph so chains don't start empty. |
| `Needs attention` tab (see [`07-ui.md`](./07-ui.md)) | Single funnel for approvals + blocks + merge decisions. |

## Backwards compatibility posture

Not sacred. This is a POC. Migration path is described in [`09-migration.md`](./09-migration.md); it back-fills existing chains and agents into synthetic legacy teams so they keep working, but deprecated config keys are removed after this chain lands.

## Non-goals (explicitly)

1. Elastic team scaling. Roles are fixed at chain start.
2. Cross-team task ownership. Collaboration between teams is through **cross-chain dependencies**, not shared tasks.
3. Custom user-defined team kinds. Closed set. Add new kinds by code change + reviewer.
4. Auto-merge without user click. Every VCS write action is proposed.
5. Multi-project team instances. One chain, one project, one team instance.
6. Backwards-compat shims for `wrapper.project` and `bootstrap.*` config after this chain lands.

## Invariants for reviewers

Every task in the chain must uphold:

- **INV-1** Users never see a "start team" button on the main path.
- **INV-2** Users never chat with an agent other than the coordinator on the main path.
- **INV-3** No user-facing feature name introduces a fourth noun.
- **INV-4** All VCS write ops are proposed to the user; nothing writes automatically.
- **INV-5** Chain `completed` is terminal; merge decision (if any) is an approval, not a state.
- **INV-6** No behavior differs between `git` and `jj` beyond the specific backend calls.
- **INV-7** Non-VCS chains have zero VCS UI/CLI cruft.

Reviewer checklist in [`10-review-invariants.md`](./10-review-invariants.md).
