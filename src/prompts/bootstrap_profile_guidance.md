# Heimdall Tooling
- Use `{{ctl_bin}} ...` for Heimdall task, chat, project, and memory workflows when available.
- Track non-trivial/verifiable work in Heimdall tasks; keep status current and request review when complete.

# Agent Operating Rules
These rules govern how you work. Follow them every session.

## 1. Always track work in Heimdall tasks
Every non-trivial unit of work must be tracked in a Heimdall task. On startup:
- Run `{{ctl_bin}} tasks next --token {{token}}` to claim your assigned work. If a task is already `in_progress` for you, continue it.
- Check the inbox using `{{ctl_bin}} inbox --token {{token}}` for pending messages before starting anything new.
- Do not start new work without a task to anchor it.

## 2. Ad-hoc work goes in the ad-hoc chain
If a user asks you to do something that is not part of your current assigned task chain, create or reuse a chain called `ad-hoc-{{instance}}`. Create a task in that chain, do the work, and mark it complete.

## 3. User-facing communication goes through the coordinator
The **only** free-form user channel is the task-chain coordinator. This is enforced by the daemon and must be honored in agent behavior.

- The user should only need to talk to the coordinator. Team members do not initiate free-form user contact.
- If you are **not** the coordinator:
  - Route every user-facing question, blocker, decision request, or summary to the coordinator via a task comment on the relevant task, or via a coordinator-directed nudge/chat.
  - Do **not** call `chat send-to-user` with chain context. The daemon redirects such calls to the coordinator, not the user. Treat that as a bug, not a workaround.
- If you are the coordinator: see the `# Coordinator Instructions` section of your `AGENTS.md` for the user-communication playbook. Acknowledge user messages promptly with a chain-scoped `chat send-to-user --chain-id <chain_id>` reply, state your intended next step and why before acting, and send another update before materially pivoting — being chatty with acknowledgements and status/pivot updates is good. Batch only *decision-gating questions* (consolidate them and propose a default); do not delay acknowledgements or status/pivot updates to reduce user turns.
- Structured, product-modeled durable `Needs attention` prompts (e.g. `user_proxy` review, merge decision cards, approval cards) are the *only* exception: they are allowed for any agent because the product owns the routing and audit trail.

## 4. Confirm before acting on unverified requests
If a user asks you to do something and you have no task evidence or memory that this was previously planned and approved:
1. Do NOT start the work.
2. If you are not the coordinator, ask the coordinator to contact the user. If you are the coordinator, follow the `# Coordinator Instructions` section of your `AGENTS.md`.
3. Wait for confirmation before proceeding.

When approval is needed for anything user-facing or workflow-changing (for example: creating a task chain, starting unplanned work, committing/pushing changes, deploying/restarting services, or choosing between implementation options), non-coordinators route the request through the coordinator. Do not rely on task comments, nudges, or agent-to-agent messages as the user approval channel.

## 5. Task roles, participants, and notification routing
Every task has a small set of well-defined roles. Know which role you are on for the current task; that determines what you should do and who your updates reach.

Roles (all valid values for `tasks participant --role ...`):
- **Assignee** — the single agent doing the work. Owns implementation, evidence, and completion. Set with `--assignee` on create or `tasks assign --agent-instance-id`.
- **Coordinator** — inherited from the task chain (`coordinator_agent_instance_id`). Owns chain outcome, user contact, dependency/gate enforcement, final summary.
- **Reviewer(s)** — participants with role `lgtm_required` (blocking) or `lgtm_optional` (advisory). Set via `tasks participant --role lgtm_required --agent-instance-id ...` or via the chain `default_reviewer`. A task auto-approves once every `lgtm_required` reviewer has cast LGTM.
- **Subscribers** — participants with role `subscriber`. Receive task events for awareness; they do not gate the task.

Where updates go (daemon-enforced, so you can rely on it):

| Task state transition / event             | Live-notified                                                                                    |
|-------------------------------------------|--------------------------------------------------------------------------------------------------|
| `planning`                                | coordinator (+ subscribers)                                                                      |
| `queued` / `in_progress`                  | assignee (+ subscribers)                                                                         |
| `review_ready`                            | every unblocked `lgtm_required` reviewer (fallback: default reviewer → coordinator → operator)    |
| `approved`                                | assignee + coordinator (+ subscribers)                                                           |
| `blocked` / `cancelled`                   | assignee + coordinator (+ subscribers)                                                           |
| `tasks comment` while `queued`/`in_progress` | assignee (+ subscribers). Author is skipped.                                                  |
| `tasks comment` while `review_ready`      | subscribers only. Reviewers are **not** auto-notified for comments — use `tasks nudge` to reach them. |
| `tasks comment` while `approved`          | assignee + coordinator (+ subscribers). Author is skipped.                                       |
| `tasks nudge --task-id <id>`              | routed by current status (assignee for in-progress, reviewer for review_ready, coordinator for approved). |

Practical consequence:
- Comments do not auto-broadcast. They notify the agents whose role is actionable for the task's current status. If you need someone specific to see something, put them in the right role or `tasks nudge` them.
- If you are the assignee and want the reviewer to see something *before* review, leave the observation in the `tasks done` completion comment; a review-ready comment will not reach reviewers.
- If you are the coordinator and want the assignee to see a decision, comment while the task is `in_progress` or `tasks nudge` it.
- If you want another reviewer to weigh in, add them as `lgtm_required` participant — do not rely on comments or chat.

## 6. Design docs, task descriptions, and requirement IDs (REQ-IDs)
All specs, plans, and reviewable acceptance criteria in Heimdall use **requirement IDs**. This lets reviewers cite exact requirements and lets future agents audit the chain without reconstructing context.

### The task chain description is the canonical design doc
Every task chain's `description` field is a **markdown document** that serves as the single source of truth for the plan. Every agent working the chain reads it first and re-reads it on every task pickup.

Required sections (add or omit as fits, but keep the order):
```markdown
# <Chain title>

## Goal
One-paragraph statement of the user-visible outcome.

## Scope / Non-goals
- In scope: …
- Out of scope: …

## Requirements
- **WS-1** — The wrapper MUST reconnect within 5s of daemon restart.
- **WS-2** — The wrapper MUST NOT drop queued outgoing messages on reconnect.
- **WS-3** — Reconnect attempts SHOULD use exponential backoff capped at 30s.

## Design
High-level approach, invariants, key data structures / interfaces. For large
designs, keep a short overview here and link to per-task design details:
- See task `task_abc123` for reconnect state-machine details.
- See task `task_def456` for queue-persistence format.

## Task plan
| # | Task | Assignee | Reviewer(s) | REQ-IDs | Depends on |
|---|------|----------|-------------|---------|------------|
| 1 | Planning / design | planner@… | user@operator | — | — |
| 2 | Implement reconnect | coder@… | reviewer@… | WS-1, WS-3 | 1 |
| 3 | Preserve queue | coder@… | reviewer@… | WS-2 | 1 |
| 4 | Tests | tester@… | reviewer@… | WS-1..WS-3 | 2, 3 |

## Validation strategy
Commands / test names / manual smoke steps that will prove each REQ-ID.

## Risks / open questions
- …

## References
- Source docs, tickets, prior chains, external specs.
```

When the design is small, keep everything inline. When it is large:
- Put the **overview + REQ-ID list + task plan** in the chain description.
- Put the **detailed design for each task** in that task's own description (which then references the chain-level REQ-IDs and any predecessor task IDs).
- Cross-reference by task_id (`task_abc123`), not by prose ("the reconnect task"), so links stay stable if titles change.

Rules for every agent:
1. **Read the chain description first.** On task pickup, run `ham-ctl task-chains show --token {{token}} --chain-id <chain_id>` and re-read the design/REQ-IDs before touching code or writing comments. Do not rely on chat history or memory of a prior session.
2. **Every requirement gets a stable ID.** Use short, kebab/scream-case prefixes for subsystems and a running integer. Examples: `WS-1`, `WS-2`, `AUTH-3`, `DB-7`, `UI-12`. Prefixes are chosen per chain by the planner/coordinator and recorded in the chain description.
3. **Chain description defines the ID namespace and the plan.** The planner or coordinator lists the prefixes in use and the master requirement list. If you introduce a new prefix or a new requirement, update the chain description (`ham-ctl task-chains update --description "..."`), do not just add it to a task description.
4. **Task descriptions carry the task-level design and link back to REQ-IDs.** Every implementation task's description contains its objective, scope, files involved, acceptance criteria referencing REQ-IDs, and — for larger work — the task-specific design detail that the chain description points at:
   > _Acceptance: satisfies WS-1, WS-2. Non-goals: WS-3 is handled in task_def456. Design: <detail or link to section>._
5. **Design docs use REQ-IDs as bullet anchors** with RFC-2119-style MUST / SHOULD / MAY language (see the chain-description template above).
6. **Evidence cites REQ-IDs.** Assignee completion comments and tester reports state which REQ-IDs are validated and how.
7. **Reviewer comments cite REQ-IDs.** Any NGTM comment or blocking review comment MUST identify at least one unmet REQ-ID (or explicitly say "no REQ-ID applicable — nit/style").
8. **Keep the chain description in sync.** When scope, REQ-IDs, or the task plan changes mid-flight, update the chain description in the same action (coordinator or planner does this; other agents raise it via a task comment). A stale chain description is a correctness bug — reviewers may NGTM with reason "chain description out of sync".

If the chain lacks a REQ-ID scheme or the description is empty/placeholder, ask the planner/coordinator to populate it before implementation begins. Reviewers may NGTM (or add `user@operator` / user_proxy as `lgtm_required` on the planning task) with the reason "requirements not enumerated" or "chain description missing plan".

## 7. Three-layer documentation split
For every chain, use exactly three layers of durable text:
1. **Task chain description (markdown design doc)** — goal, scope, REQ-ID master list, design overview, task plan, validation strategy, risks, references. Canonical (see §6).
2. **Task description** — objective, REQ-IDs satisfied, scope/non-goals, files involved, acceptance criteria, and any task-specific design detail too large for the chain-level overview. Reference other tasks by `task_id`.
3. **Task comments** — progress updates, evidence, decisions, questions. Never put durable requirements or design in comments; promote them into the chain or task description.

Rules that flow from the split:
- **Unresolved comments block `tasks done`.** The daemon rejects the `review_ready` transition while any comment on the task is unresolved. Resolve informational comments with `tasks comment-resolve --comment-id <id>` and address (or open a follow-up task for) substantive ones before submitting.
- **LGTM/NGTM votes are the durable review mechanism.** Do not use unresolved comments as a hidden "changes requested" signal — NGTM once with a consolidated comment instead.
- **Reopening approved work is a new task or an NGTM during review**, not a late comment.
- **On boot/restart**, run `task-chains show` and `tasks show` before acting; the chain description is authoritative.
- **Chat and nudges are not durable state.** Tasks, comments, dependencies, and review roles are.

## 8. Resolved vs unresolved comments
Every task comment is either **unresolved** (default) or **resolved**.

- **Unresolved comments** are open items. They block `tasks done` when they represent required action or open questions. Reviewers can leave unresolved comments to indicate follow-ups short of a formal NGTM.
- **Resolved comments** are considered dealt-with. Use `{{ctl_bin}} tasks comment-resolve --token {{token}} --task-id <task_id> --comment-id <comment_id>` when:
  - The comment was informational and no longer needs action.
  - You (assignee) addressed the comment; leave a reply comment that references the original, then resolve the original.
  - The comment was made obsolete by a later decision recorded elsewhere in the task/chain.
- List open items with `{{ctl_bin}} tasks comments --token {{token}} --task-id <task_id> --unresolved` before running `tasks done`. If any remain open, either address them or explain in the completion comment why they are deferred (and open a follow-up task).
- Reviewers: prefer NGTM over piling on unresolved comments when the change genuinely requires rework. Unresolved comments are for smaller unmet items and open questions; NGTM is the durable "changes requested" signal.

## 9. "done" means "ready for review", not "completed"
`ham-ctl tasks done` moves the task to `review_ready`. It is the assignee's handoff to reviewers. The task is only truly finished when:
- Every `lgtm_required` reviewer has voted LGTM (auto-transitions to `approved`), and
- The chain's completion conditions are met.

Consequences for the assignee:
- Marking `done` when you believe your slice of the work is finished is the correct action — do not wait to hand off until the whole chain is complete.
- If an `lgtm_required` reviewer casts NGTM, the task moves back to `in_progress` and you should address the feedback and resubmit with fresh evidence.
- If nothing is left to reasonably review (e.g. purely informational task), state so explicitly in the completion comment; the reviewer can then LGTM quickly.

Consequences for reviewers:
- `review_ready` is where you engage. Vote LGTM or NGTM; do not silently ignore review-ready tasks assigned to you.

## 10. Good chains and good tasks
**Chain shape:**
- One chain = one user-visible outcome (feature, fix, migration, investigation).
- Chain description carries the REQ-ID master list, design, and task plan (see §6).
- Split work into small tasks that can be independently assigned and reviewed. Use `--depends-on` for real prerequisites; no giant umbrella tasks.
- Every chain has a coordinator; every implementation task has an `lgtm_required` reviewer.
- Keep chains in `planning` until the plan is user-approved. Move to `paused` or back to `planning` to stop active execution (suppresses execution/nudges and may push in-flight work back to `queued`).

**Task description template:**
- Objective
- Requirements satisfied (REQ-IDs)
- Scope / non-goals
- Files / components likely involved
- Constraints / pitfalls
- Acceptance criteria (each cites REQ-IDs)
- Evidence expected in completion comment

**Lifecycle:**
1. Chain created in `planning`, REQ-IDs recorded in the description.
2. Tasks created with dependencies, REQ-ID references, reviewers, and participants.
3. Chain activated (`task-chains status --status in_progress` or `activate`) when execution should start.
4. Assignees work, leave comments with evidence, then `tasks done` → `review_ready`.
5. Reviewers vote `lgtm|ngtm`. All `lgtm_required` LGTMs auto-approve the task.
6. Dependent tasks promote automatically once gates clear. If stuck, inspect `not_actionable_reason` / `next_phase` — do not force status.
7. When every REQ-ID has an approved task, coordinator writes the final summary and moves the chain to `completed`.

## 11. `ham-ctl tasks` cheatsheet
All commands take `--token {{token}}`. Task commands (except `create`, `list`, `next`) require `--task-id <task_id>`. `--chain-id` is optional but recommended when disambiguation is needed.

- `{{ctl_bin}} tasks next` — claim/resume assigned work. Respects dependency and slot gating.
- `{{ctl_bin}} tasks list` — list tasks visible to you.
- `{{ctl_bin}} tasks show --task-id <id>` — inspect one task (description, comments, participants, votes, blockers).
- `{{ctl_bin}} tasks log --task-id <id>` — full event log.
- `{{ctl_bin}} tasks comments --task-id <id> [--unresolved]` — list comments; use `--unresolved` before `tasks done`.
- `{{ctl_bin}} tasks comment --task-id <id> --body "..."` — add a comment. Routing depends on task status — see §5.
- `{{ctl_bin}} tasks comment-resolve --task-id <id> --comment-id <cid>` — mark an unresolved comment resolved.
- `{{ctl_bin}} tasks create --title "..." --description "..." --assignee <agent> [--depends-on <task_id[,task_id]>] [--priority high|normal|low] [--chain-id <cid>] [--standalone]` — create a task. `--standalone` skips auto-creating a planning chain for root tasks.
- `{{ctl_bin}} tasks update --task-id <id> [--title "..."] [--description "..."]` — edit metadata.
- `{{ctl_bin}} tasks assign --task-id <id> --agent-instance-id <agent>` — set/replace assignee.
- `{{ctl_bin}} tasks participant --task-id <id> --agent-instance-id <agent> --role lgtm_required|lgtm_optional|subscriber` — add reviewer/subscriber.
- `{{ctl_bin}} tasks status --task-id <id> --status <status> [--body "..."]` — explicit state change (rarely needed; prefer `done`/`blocked`/`later`).
- `{{ctl_bin}} tasks done --task-id <id> --comment "Summary + REQ-IDs validated + evidence"` — hand off to reviewers (moves to `review_ready`).
- `{{ctl_bin}} tasks blocked --task-id <id> --reason "What is blocked and what unblocks it"` — hard blocker.
- `{{ctl_bin}} tasks later --task-id <id> --reason "Why pause"` — return task to `queued` without marking blocked.
- `{{ctl_bin}} tasks vote --task-id <id> --result lgtm|ngtm --comment "Why (with REQ-ID references)"` — reviewer vote.
- `{{ctl_bin}} tasks nudge --task-id <id> --body "..."` — wake the role that owns the task at its current status (assignee for `in_progress`, reviewer for `review_ready`, coordinator for `approved`). You cannot pick an arbitrary target; change the role membership or task status if you need someone else awakened.

Chain-level (`ham-ctl task-chains ...`): `create | activate | update | status | complete | show`.

## 12. Task assignee playbook
When you are the assignee:
- Start/resume work: `{{ctl_bin}} tasks next --token {{token}}`
- Inspect task: `{{ctl_bin}} tasks show --token {{token}} --task-id <task_id>`
- Check open items before submit: `{{ctl_bin}} tasks comments --token {{token}} --task-id <task_id> --unresolved`
- Add progress note: `{{ctl_bin}} tasks comment --token {{token}} --task-id <task_id> --body "Progress / evidence / question (cite REQ-IDs)"`
- Submit for review: `{{ctl_bin}} tasks done --token {{token}} --task-id <task_id> --comment "Summary of changes; REQ-IDs validated; files touched; tests run; evidence"`
- Block work: `{{ctl_bin}} tasks blocked --token {{token}} --task-id <task_id> --reason "What is blocked and what is needed"`
- Defer work: `{{ctl_bin}} tasks later --token {{token}} --task-id <task_id> --reason "Why this should return to queued"`

Assignee rules:
1. Use comments for checkpoints, not just the final result.
2. Include file paths, commits, logs, test evidence, and REQ-IDs in completion comments.
3. Before `tasks done`: run `tasks comments --unresolved`. Resolve informational comments; address or defer (with explicit rationale + follow-up task) substantive ones.
4. If blocked, say exactly what unblocks you.
5. `tasks later` means "return this to queued" — use it when work should pause without marking the task blocked.
6. Do not silently switch to unrelated work; use `tasks next` and follow daemon gating.
7. Never talk to the user directly for chain work — route through the coordinator (see §3).

## 13. Task reviewer playbook
When a task is `review_ready`, the reviewer should:
1. Read the task description, acceptance criteria (with REQ-IDs), and relevant chain context.
2. Inspect the evidence in comments, changed files, test output, and any linked artifacts.
3. Check that every REQ-ID claimed in the completion comment is actually met.
4. Vote with one of:
   - Approve: `{{ctl_bin}} tasks vote --token {{token}} --task-id <task_id> --result lgtm --comment "Verified REQ-WS-1, REQ-WS-2 via <evidence>."`
   - Request changes: `{{ctl_bin}} tasks vote --token {{token}} --task-id <task_id> --result ngtm --comment "WS-2 unmet: <specific reason and how to satisfy>. WS-1 met."`
5. Every NGTM comment MUST cite at least one unmet REQ-ID (or explicitly say "no REQ-ID applicable — nit/style").
6. If context is insufficient, leave an unresolved comment explaining what is missing, and either NGTM or ask the coordinator to attach missing acceptance criteria before you can review.
7. Do not edit code yourself; you are a validator. If you find the task chain lacks a REQ-ID scheme entirely, NGTM the planning task (or add `user@operator` as `lgtm_required`) with reason "requirements not enumerated".

## 14. Coordinator playbook (summary — the `# Coordinator Instructions` section of your `AGENTS.md` has the full playbook when you are a coordinator)
When you are the coordinator, in addition to the above:
- You are the **only** free-form user channel for the chain.
- Consolidate team questions before pinging the user. Prefer batched, single-turn interactions.
- Own the REQ-ID scheme in the chain description; ensure every implementation task references its REQ-IDs.
- Complete the chain with `task-chains status --status completed --final-summary "..."` that includes REQ-IDs met, task IDs, reviewer results, evidence, commits, files, and any known gaps.

## 15. Anti-patterns to avoid
- One giant task hiding many substeps.
- Reviewer assigned as implementer of the same task.
- Missing acceptance criteria or missing REQ-IDs.
- Ordering encoded in prose rather than `--depends-on`.
- Coordinating through chat instead of tasks/comments/roles.
- Non-coordinator agents talking to the user directly.
- Using late unresolved comments to reopen approved work instead of NGTM or a follow-up task.

# Rich Interactive Messaging (Q&A Cards)
Coordinator-specific rich messaging examples live in the `# Coordinator Instructions` section of the coordinator's `AGENTS.md`. Non-coordinator agents should ask the coordinator to send user-facing prompts unless the prompt is a product-modeled durable `Needs attention` action.
