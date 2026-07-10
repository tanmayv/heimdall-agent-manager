# Introduce Teams model — task chain description

**Host project:** `swe-team` (agents live here today)
**Code location:** `heimdall-agent-manager` at `/Users/tanmayvijay/heimdall-agent-manager` (all code edits target this repo)
**Coordinator:** `principal@swe-team`
**Default reviewer:** `reviewer@swe-team`

## Objective

Refactor Heimdall from an "individual agents pinned to projects" model to a **Projects → Task Chains → (lazy) Teams → Agents** model, with VCS-coupled parallel workstreams. Full spec lives in `docs/teams-v1/` in the code repo. Every task in this chain implements a specific numbered section from that spec.

## Reference documents (read first)

Every agent should read the docs in this order before picking up a task:

1. `docs/teams-v1/README.md` — index + locked decisions
2. `docs/teams-v1/01-model.md` — the three-noun mental model
3. `docs/teams-v1/03-lifecycle.md` — lazy teams, boot triggers, idle shutdown, chain completion, merge decision
4. `docs/teams-v1/04-vcs.md` — git + jj backend abstraction
5. `docs/teams-v1/02-team-kinds.md` — closed set of team kinds + scaffolds
6. `docs/teams-v1/05-memory.md` — memory scope rework
7. `docs/teams-v1/06-bootstrap.md` — new wrapper bootstrap sections
8. `docs/teams-v1/07-ui.md` — UI reshape
9. `docs/teams-v1/08-http-and-cli.md` — new HTTP routes and CLI surface
10. `docs/teams-v1/09-migration.md` — legacy migration path
11. `docs/teams-v1/10-review-invariants.md` — invariant IDs reviewers verify

Also required reading:

- `AGENTS.md` (repo root) — coding conventions, RG references, `data-debug-id` rules
- `REVIEW_GUIDELINES.md` — reviewer expectations
- `mocks/ui-v2/index.html` — illustrative UI mock (not authoritative; the docs are)

## Locked design decisions (do not re-open without user approval)

1. Three user-facing nouns: **Project, Team, Task Chain**. No "workstream" noun. Agents remain internal-ish.
2. Closed set of team kinds: `coding`, `research`, `debugging`, `data-analysis`, `writing`, `ops`, `solo`.
3. **One team instance per chain.** Team lifecycle bound to chain lifecycle.
4. **Lazy agent boot.** Nudge scheduler is the autoscaler.
5. Coordinator warm-on-focus (low priority).
6. Idle shutdown grace = **30 minutes** (per-kind overridable).
7. Chain `completed` is terminal. No VCS → team archives immediately. With VCS → merge decision surfaces on `Needs attention`; team archives after decision.
8. Solo mode = team-of-one with synthetic `user_proxy` reviewer routing to `operator@local`.
9. Chat routing: user → coordinator only. Coordinator forwards from other agents.
10. VCS backends: **git worktrees** and **jj workspaces** behind one interface. Both first-class.
11. Memory scope = `{Team_Project, Project, Template}`. `Personal` is internal-only.
12. Anchors are a **closed vocabulary**: `git_repo`, `base_ref`, `vcs_kind`, `worktree_root`, `docs`, `scratch`.
13. **Testers are assignees on test tasks, never permanent reviewer slots.**

## Guardrails — critical

### Do this

- **Do all code edits inside `/Users/tanmayvijay/heimdall-agent-manager`.** That is the code project; `swe-team` is only the chain host.
- **Do run tests against a separate daemon instance** using a copied `data_dir` on a non-default port, per `docs/teams-v1/09-migration.md` §Test scenario. Never touch the live DB (`~/.local/share/heimdall/`).
- **Do treat the daemon as immutable until Task 18.** The daemon binary and DB stay as-is throughout the chain. All builds go into `./result-*` symlinks; do not `nix profile install` or overwrite `~/.local/bin/ham-daemon`.
- **Do cite the spec section** in every task description and completion comment (e.g. "Implements §3.6 of `docs/teams-v1/03-lifecycle.md`").
- **Do cite invariant IDs** in LGTM comments (e.g. "Verified INV-1, LC-3, VCS-2").
- **Do write acceptance evidence** in every completion comment: file paths, commands run, output snippets, commit hashes.
- **Do use `ham-ctl tasks comment`** for progress checkpoints, not chat.
- **Do resolve unresolved comments** before submitting for review.
- **Do run `nix build` for each affected package** before marking a task done (`nix build .#ham-daemon .#ham-wrapper .#ham-ctl`).
- **Do use a git worktree** for the whole chain: `git -C /Users/tanmayvijay/heimdall-agent-manager worktree add ../hmg-teams-v1 -b teams-v1 main` and work there.

### Do not do this

- **Do not restart the live daemon.** The user is running the current daemon (`ham-agents` tmux session) and cannot afford it to break. Merge is a separate, later step.
- **Do not touch `~/.local/share/heimdall/*.db`** during development. Copy for testing; leave the live copy alone.
- **Do not require operator approval to make progress.** The chain is autonomous. If a task genuinely needs the user, block the task with a clear reason and move on to unrelated tasks in parallel.
- **Do not chat with the user directly.** Any user-facing question goes through `principal@swe-team` via chat (rare) or task comment tagged `USER APPROVAL NEEDED:` (rarer).
- **Do not add "workstream" as a user-visible noun.** Task chain stays.
- **Do not introduce free-form project anchors.** Use the closed vocabulary.
- **Do not add tester as a reviewer slot** on any team kind or any task.
- **Do not re-open locked design decisions** without explicit user approval routed through `principal@swe-team`.
- **Do not commit anything to `main`.** All work lives on the `teams-v1` branch (git worktree) or equivalent jj change.
- **Do not merge to main.** Merge is a separate operator-driven step after chain completion.

## Autonomy rule

**This chain is designed to complete without user intervention** except for one final review at chain completion. Reviewers on tasks are always agent-to-agent (coder ↔ reviewer, coder ↔ risk-analyst). If an agent thinks user approval is required for internal implementation choices, the correct action is:

1. Post a task comment with `USER APPROVAL NEEDED:` prefix explaining the *exact* implementation question with concrete options (A/B/C).
2. Set task status = `blocked` with reason "awaits user decision" so the queue keeps moving on independent tasks.
3. Continue picking up unblocked tasks via `tasks next`.

Do not spin waiting for the user. Do not ask about aesthetic or naming preferences — pick the option most consistent with the locked decisions above and note the reasoning in the completion comment.

## Coordinator (principal@swe-team) instructions

- You are the chain coordinator. Route any user chat that arrives to the appropriate assignee via task comments or agent-to-agent chat.
- Do **not** relay task-implementation decisions to the user. Make the call yourself using the spec + locked decisions.
- On chain completion write a final summary that includes: verifiable evidence for each phase, commit hashes on `teams-v1` branch, file paths changed, invariant coverage table (which task verified which invariant), and a proposed quality rating (`good` / `bad`) per §Task Chain Best Practices in root AGENTS.md.
- If a task is stuck > 6 hours in `blocked` awaiting a real decision, nudge the assignee to move on to independent work rather than escalating to the user prematurely.

## Reviewer expectations

- Every review comment must cite the invariant IDs verified (per `docs/teams-v1/10-review-invariants.md`).
- Every NGTM must name the specific invariant violated and a one-sentence fix.
- Reviews are agent-to-agent throughout. Do not solicit user input as a reviewer.

## Rollout plan

Phased tasks below. Do not batch phases; complete tasks in dependency order. Batches suggested for cognitive grouping only.

- **Pre-flight (Tasks 0a–0c):** dry-run environment, anchor audit, restart-window doc.
- **Phase 1 (Tasks 1–6):** team kinds + registry + teams DB + read-only HTTP + CLI.
- **Phase 2 (Tasks 7–10):** task_chain team_id column, solo user_proxy, bootstrap redesign, closed anchors.
- **Phase 3 (Tasks 11–13):** VCS backends, workspace provisioning, chain scaffolds.
- **Phase 4 (Tasks 14–17):** legacy migration, memory scope, merge lifecycle, config cleanup.
- **Phase 5 (Tasks 18–25):** E2E validation + UI reshape + nudge-scheduler lazy-boot + supporting daemon additions.

Test tasks (`*.T`) sit alongside their siblings. Nothing merges to `main` from this chain — the coordinator's final summary hands off a `teams-v1` branch that the user reviews and merges out-of-band.
