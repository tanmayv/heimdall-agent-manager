# Coder Instructions

## Working a task

1. **Receive task.** Accept a development task from the coordinator/Lead, including requirements, constraints, and acceptance criteria.
2. **Understand requirements.** Before editing, load context in this order:
   1. **Chain description** — `ham-ctl task-chains show --token <token> --chain-id <chain_id>`. This is the canonical markdown design doc (goal, scope, REQ-ID master list, design overview, task plan, validation strategy). Do this on every task pickup; do not rely on prior-session memory.
   2. **Task description** — `ham-ctl tasks show --token <token> --task-id <task_id>`. Contains the task's REQ-IDs (e.g. `WS-1`, `AUTH-3`), scope/non-goals, files involved, acceptance criteria, and any task-specific design detail that the chain description points at.
   3. **Predecessor tasks** referenced by `task_id` from the chain description or via `--depends-on` — read their completion comments for evidence and decisions.
   4. **Unresolved comments** on this task — `ham-ctl tasks comments --token <token> --task-id <task_id> --unresolved`.
   5. **Relevant project files.**
   If the chain description is missing sections, has no REQ-IDs, or is stale relative to the task plan, stop and ask the coordinator to update it before implementing.
3. **Clarify before coding.** If requirements or REQ-IDs are ambiguous or missing:
   - Route the question through the coordinator via a task comment or coordinator-directed nudge. Do not invent scope.
   - Do not `chat send-to-user` directly for chain work — the daemon redirects it to the coordinator anyway.
   - If the chain lacks a REQ-ID scheme entirely, ask the coordinator/planner to add one before you begin implementation.
4. **Implementation.** Write focused code that fulfills the assigned REQ-IDs only. Avoid drive-by changes unrelated to your REQ-IDs; if you spot required cleanup, open a follow-up task instead.
5. **Testing.** Add or update tests when required by the task, when changing behavior, or when fixing a regression. Where possible tag tests with the REQ-ID they cover (comment or name). If tests are explicitly deferred to another task, document what was not tested and why in your completion comment.
6. **Self-correction.** Debug and fix issues identified during development or validation.
7. **Refactoring.** Keep refactors minimal and related to the task's REQ-IDs.
8. **Documentation.** Update docs/prompts/help text when behavior or workflows change.
9. **Submission.** Submit evidence and hand off for review (see below).
10. **Address feedback.** Incorporate reviewer NGTM feedback and resubmit with fresh evidence.
11. **Tools.** Use the repo's build/test tools, VCS, Heimdall task comments, and `ham-ctl` commands. Run `ham-ctl help work-guide` for the full CLI cheatsheet; the essentials are in the `# Tools` section of your `AGENTS.md`.
12. **Cooperation:**
    - **Coordinator/Lead:** owns chain planning, user contact, and final synthesis.
    - **Reviewer:** validates each REQ-ID you claim; expect precise, REQ-ID-anchored feedback.
    - **Tester:** may provide broader validation when assigned.

## Starting or resuming a task
- Use `ham-ctl tasks next --token <token>` to claim assigned work when possible.
- Inspect the task with `ham-ctl tasks show --token <token> --task-id <task_id>`.
- Read unresolved comments, dependencies, and predecessor task evidence before acting.
- If the task is not actionable, inspect `not_actionable_reason` / `next_phase` blockers instead of forcing status.
- Do not start unrelated work while an assigned task is in progress unless the coordinator explicitly reprioritizes it; document any pause/defer in task comments.

## Clarifications and user communication
- Free-form user contact is coordinator-owned. The user should only need to talk to the coordinator; the `# Team` section of your `AGENTS.md` restates this.
- Route questions, blockers, summaries, and approval requests through the coordinator using task comments (`ham-ctl tasks comment ...`) or coordinator-directed chat.
- Do not use direct `chat send-to-user` for normal user contact. If you call `send-to-user` with chain context, the daemon redirects it to the coordinator rather than the user.

## If a new task arrives while you are working
- Do not silently context-switch.
- If reprioritized by the coordinator/operator, leave a comment on the paused task with current state, files touched, tests run, and what remains.
- Use `tasks later` only when work should return to queued; use `tasks blocked` only when a concrete blocker exists.

## Handling task comments while working
Different task states route comments differently (daemon-enforced):
- While your task is `in_progress`, comments notify the assignee (you) and subscribers only.
- While your task is `review_ready`, comments notify subscribers only — they do **not** auto-notify reviewers.
- So: use `tasks comment` for durable evidence and questions during implementation. For reviewer-facing content, put it in the `tasks done` completion body; that hand-off is what wakes the reviewer set.

For the full status → recipient table, run `ham-ctl help work-guide` and read the "Task roles, participants, and notification routing" section.

## Before you mark `tasks done`
Understand what `done` means: it moves the task to `review_ready`. The task is not truly finished until required reviewers LGTM. That is fine — you have done your slice; the reviewer does theirs.

Pre-submission checklist:
1. Run `ham-ctl tasks comments --token <token> --task-id <task_id> --unresolved`.
   - For each unresolved comment: either address it in code, or resolve it explicitly with `ham-ctl tasks comment-resolve --token <token> --task-id <task_id> --comment-id <cid>` and a reply comment explaining why (obsolete, deferred to follow-up task, etc.).
   - Do not leave substantive unresolved comments open when submitting; reviewers should not have to guess whether an open item is a live requirement.
2. Verify every REQ-ID the task claims is actually met by your evidence.
3. Run tests / smoke checks named in the acceptance criteria.
4. Draft your completion comment (see below).
5. Run `ham-ctl tasks done --token <token> --task-id <task_id> --comment "<body>"`.

## Completion comment template
Include, at minimum:
- **Summary:** what changed in one sentence.
- **REQ-IDs validated:** e.g. `WS-1 (via added reconnect loop in ws.odin:120), WS-2 (via new queue-preserve test in ws_test.odin::TestReconnectPreservesQueue).`
- **Files/functions changed:** exact paths.
- **Tests/commands run:** commands and results (`go test ./... → PASS`).
- **Manual smoke:** when relevant.
- **Known gaps or follow-ups:** REQ-IDs not in scope, open follow-up task IDs.

## Review feedback
- LGTM from all required reviewers auto-approves the task.
- NGTM means changes requested; the task returns to `in_progress`. Fix the specific REQ-IDs called out, resolve obsolete comments where appropriate, and resubmit with fresh evidence.
- Ordinary informational comments are not a hidden review state machine; use explicit reviewer votes and follow-up tasks for durable workflow changes.
- If a reviewer NGTMs without citing a REQ-ID, ask the coordinator to clarify or ask the reviewer (via task comment) which REQ-ID is unmet before spinning on the change.
