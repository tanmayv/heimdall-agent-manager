# Teams v1 — Design Reference

This directory is the source-of-truth spec for the **Projects → Chains → Teams (lazy) → Agents** refactor of Heimdall. Every task in the `Introduce Teams model` task chain references sections here by heading anchor. Reviewers verify implementation tasks against the invariants below, not against ad-hoc chat.

## Files

- [`README.md`](./README.md) — this index.
- [`01-model.md`](./01-model.md) — the three-noun user model, mental model, and what's cut.
- [`02-team-kinds.md`](./02-team-kinds.md) — closed set of team kinds, role slots, memory templates, chain scaffolds, defaults.
- [`03-lifecycle.md`](./03-lifecycle.md) — lazy team lifecycle: allocation, boot triggers, idle shutdown, chain completion, merge decision, archive.
- [`04-vcs.md`](./04-vcs.md) — VCS backend abstraction covering **git worktrees** and **jj workspaces**, workspace provisioning, merge preview, teardown.
- [`05-memory.md`](./05-memory.md) — memory scope rework (`Team_Project`, `Project`, `Template`), wrapper fetch order, auditor default subject.
- [`06-bootstrap.md`](./06-bootstrap.md) — new wrapper bootstrap sections (`You / Project / Task Chain / Team / Memory / Tools`) and what's removed.
- [`07-ui.md`](./07-ui.md) — UI reshape: Home / Needs-attention / Chain view / Settings, chat-with-coordinator-only rule.
- [`08-http-and-cli.md`](./08-http-and-cli.md) — HTTP routes and `ham-ctl` command surface after the refactor.
- [`09-migration.md`](./09-migration.md) — legacy migration path (existing agents, chains, memories, anchors).
- [`10-review-invariants.md`](./10-review-invariants.md) — the invariant checklist reviewers use for every task in the chain.

## Locked decisions (from planning discussion)

1. **Vocabulary** — `Project`, `Team`, `Task Chain`. No new "workstream" noun; the UI shows chains directly. Agents remain internal-ish (team members).
2. **Team = fixed roles, closed kind set.** Kinds: `coding`, `research`, `debugging`, `data-analysis`, `writing`, `ops`, `solo`.
3. **Team lifecycle bound to chain lifecycle.** One team instance **per chain**. When the chain completes and (if VCS) merge decision is made, the team archives. No user-visible "start team" action.
4. **Lazy agent boot.** Agents don't run until a role is *needed* — nudge scheduler is the autoscaler.
5. **Coordinator warm-on-focus.** Opening a chain view starts booting the coordinator in the background.
6. **Idle shutdown grace = 30 minutes.**
7. **Chain "completed" is the terminal state.** No VCS → team archives immediately. With VCS → merge decision appears in `Needs attention`; team archives after the decision.
8. **Solo mode = team of 1** with `user_proxy` reviewer routing approvals to `operator@local` via smart-reply chat cards.
9. **Chat routing.** User posts in the chain chat → delivered only to coordinator's inbox. Coordinator decides what to forward. Agents never chat with the user directly.
10. **VCS backend** supports **git worktrees** and **jj workspaces** behind a small interface. `jj` is a first-class citizen from day one.
11. **Memory scope** = `{Team_Project, Project, Template}` for user-facing memory. `Personal` is internal-only (auditor scratch). `Global` collapses into `Template`.
12. **Anchors are a closed vocabulary**: `git_repo`, `base_ref`, `vcs_kind`, `worktree_root`, `docs`, `scratch`. Free-form goes in `project.description`.
13. **Testers are assignees on test tasks, not permanent reviewer slots.**
14. **Coordinator of `Introduce Teams model` chain** = `principal@swe-team`. Coder assignee = `coder@swe-team`. Reviewers on migration-touching tasks include `risk-analyst@swe-team` as `lgtm_required`. Memory-scope task pulls `memory-reviewer-Heimdall-System@heimdall-system`.

## Chain hosting note

The chain **is created in the `swe-team` project** for organizational reasons (that's where the agents belong today). The **code lives in `heimdall-agent-manager`** — the wrapper worktree and all edits target that repo. This dual-project pattern is documented once in the chain description, then never again after Task 14 collapses "team-project" containers into real teams.

## Reading order

1. Skim [`01-model.md`](./01-model.md) — the mental model change is the whole point.
2. Then [`03-lifecycle.md`](./03-lifecycle.md) and [`04-vcs.md`](./04-vcs.md) — they're the largest and highest-risk deltas.
3. Then [`02-team-kinds.md`](./02-team-kinds.md), [`05-memory.md`](./05-memory.md), [`06-bootstrap.md`](./06-bootstrap.md) — smaller, mostly mechanical.
4. Then [`07-ui.md`](./07-ui.md), [`08-http-and-cli.md`](./08-http-and-cli.md) — user surface.
5. Finally [`09-migration.md`](./09-migration.md) and [`10-review-invariants.md`](./10-review-invariants.md) — before shipping any task.
