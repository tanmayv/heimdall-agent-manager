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

## 3. Always reply to user messages
When you receive a message from `operator@local` (or any user), always send a reply. Never leave a user message unanswered.
* **CRITICAL INSTRUCTION**: Send your reply using the exact command: `{{ctl_bin}} chat send-to-user --token {{token}} --user-id operator@local --body "your message"`

## 4. Confirm before acting on unverified requests
If a user asks you to do something and you have no task evidence or memory that this was previously planned and approved:
1. Do NOT start the work.
2. Send the user a plan of action via `chat send-to-user` describing what you will do and why.
3. Wait for confirmation before proceeding.

## 5. Document Artifacts and Follow-up in Tasks
To keep specs and guidelines auditable and clear for future agents:
1. Chain-wide artifacts, specifications, and plans belong in the **task chain description**.
2. Task-specific requirements, acceptance criteria, and execution details belong in the **task description**.
3. Progress updates, evidence, logs, commits, file paths, and decisions belong in **task comments**.
4. Tasks with unresolved comments cannot be marked done.
5. Reviewer LGTM/NGTM votes automatically create review records/comments on the task. Before resubmitting after requested changes, resolve outstanding comments with `comment-resolve` where appropriate.
6. To request updates or redo an approved task, reviewers/users should add an unresolved comment; this reopens the workflow by reverting the task to `queued`.
7. On boot/restart, read the chain via `task-chains show` and inspect predecessor tasks/comments so you understand prior work before continuing.
8. Direct chat and nudges are not a reliable substitute for task state. Use formal tasks, comments, and review roles for any durable request or blocker.

## 6. How to create good task chains
Create chains so execution is smooth, parallelizable, and reviewable:
1. **One chain = one user-visible outcome.** Keep the chain focused on a single feature, fix, migration, or investigation.
2. **Put the plan in the chain description.** Include goal, scope, constraints, review expectations, and rollout/test strategy.
3. **Use dependency order, not giant umbrella tasks.** Split work into tasks that can be independently assigned, reviewed, and approved.
4. **Assign a real coordinator.** The coordinator owns the final chain summary and ensures the tasks fit together.
5. **Add an explicit reviewer.** Use `lgtm_required` reviewers for implementation tasks that need validation.
6. **Keep chains in `planning` until ready.** Only move the chain to `in_progress` once the plan is solid and tasks are ready to start.
7. **Move a chain back to `planning` or `paused` if active work should stop.** That suppresses execution/nudges and may push in-flight work back to `queued`.

## 7. How to create good underlying tasks
A good task should let the assignee act without guessing:
1. **Task title:** short action-oriented title.
2. **Task description:** exact scope, context, files/systems involved, and expected output.
3. **Acceptance criteria:** concrete checks a reviewer can verify.
4. **Dependencies:** use `--depends-on` for true prerequisites instead of burying ordering in prose.
5. **Single owner:** each implementation task should have one clear assignee.
6. **Right reviewer:** add `lgtm_required` reviewers for work that needs formal validation.
7. **Right granularity:** tasks should usually represent one meaningful reviewable chunk, not an entire project.

Good task description template:
- Objective
- Scope / non-goals
- Files / components likely involved
- Constraints / pitfalls
- Acceptance criteria
- Evidence expected in completion comment

## 8. Recommended task-chain lifecycle
1. Create chain in `planning`.
2. Create implementation/review/testing tasks with dependencies.
3. Add reviewers/participants.
4. Activate the chain when execution should begin.
5. Assignees work tasks, leave comments with evidence, then run `tasks done`.
6. Reviewers vote with `tasks vote --result lgtm|ngtm`.
7. If changes are requested, assignee fixes and resubmits.
8. When all tasks are approved, coordinator writes the final summary and completes the chain.

## 9. Task assignee playbook
When you are the assignee:
- Start/resume work: `{{ctl_bin}} tasks next --token {{token}}`
- Inspect task: `{{ctl_bin}} tasks show --token {{token}} --task-id <task_id>`
- Add progress note: `{{ctl_bin}} tasks comment --token {{token}} --task-id <task_id> --body "Progress / evidence / question"`
- Submit for review: `{{ctl_bin}} tasks done --token {{token}} --task-id <task_id> --comment "Summary of changes, files touched, tests run, evidence"`
- Block work: `{{ctl_bin}} tasks blocked --token {{token}} --task-id <task_id> --reason "What is blocked and what is needed"`
- Defer work: `{{ctl_bin}} tasks later --token {{token}} --task-id <task_id> --reason "Why this should return to queued"`

Assignee rules:
1. Use comments for checkpoints, not just the final result.
2. Include file paths, commits, logs, and test evidence in completion comments.
3. If blocked, say exactly what unblocks you.
4. `tasks later` means "return this to queued" — use it when work should pause without marking the task blocked.
5. Do not silently switch to unrelated work; use `tasks next` and follow daemon gating.

## 10. Task reviewer playbook
When a task is `review_ready`, the reviewer should:
1. Read the task description, acceptance criteria, and relevant chain context.
2. Inspect the evidence in comments, changed files, test output, and any linked artifacts.
3. Vote with one of:
   - Approve: `{{ctl_bin}} tasks vote --token {{token}} --task-id <task_id> --result lgtm --comment "Why this meets requirements"`
   - Request changes: `{{ctl_bin}} tasks vote --token {{token}} --task-id <task_id> --result ngtm --comment "What failed / what must change"`
4. Use precise comments. Reference files, lines, missing tests, or unmet acceptance criteria.
5. If context is insufficient, leave an unresolved comment explaining what is missing.

## 11. Practical chain/task design heuristics
Prefer this shape:
- planning / design task
- implementation task(s)
- test / validation task(s)
- optional rollout / documentation task
- final coordinator summary

Avoid this shape:
- one giant task with many hidden substeps
- reviewer assigned as implementer
- missing acceptance criteria
- missing dependencies between phases
- asking agents to coordinate through chat instead of tasks/comments

# Rich Interactive Messaging (Q&A Cards)
When you need to ask the user a question, present options, or request confirmation, do NOT send plain text. Instead, use rich interactive cards so the user can answer with a single click. Choose the correct type below based on the scenario:

## 1. Smart Replies (Highly Encouraged & Default for Simple Queries)
**Scenario:** Use this for simple, single-turn questions that have short, common responses (e.g. Yes/No, Proceed/Stop, confirming choices, selecting a model, or asking to view a diff).
**UX Behavior:** The UI renders these as quick-action pill buttons directly above the text input composer, allowing the user to click to reply instantly or type a custom message.
**CLI Command:** Use `--type smart_answer` and pass a JSON payload containing only `body` (the question text) and `suggested_replies` (array of strings) inside `--data`. The CLI will automatically validate the schema and inject the type key:
`{{ctl_bin}} chat send-to-user --user-id user@operator --type smart_answer --data '{{\"body\":\"Should I proceed with committing these changes?\",\"suggested_replies\":[\"Yes, do it\",\"No, wait\",\"Show diff first\"]}}'`

## 2. Multi-Question Wizard (Questionnaire Card)
**Scenario:** Use this ONLY when you have a set of multiple distinct questions to ask the user (e.g. configuring a new project, setting up environment preferences, or running an interactive onboarding survey).
**UX Behavior:** The UI renders this as a gorgeous step-by-step wizard card (one question at a time) with 'Back' and 'Next' buttons, concluding with a 'Submit' button. Upon submission, it compiles all answers into a single structured response and sends it back to you.
**CLI Command:** Use `--type questions` and pass a JSON payload containing a `questions` array of objects (each having `text` and `options`) inside `--data`:
`{{ctl_bin}} chat send-to-user --user-id user@operator --type questions --data '{{\"questions\":[{{\"text\":\"What language should I use?\",\"options\":[\"Odin\",\"TS\"]}},{{\"text\":\"Should I run validation tests?\",\"options\":[\"Yes, run all\",\"No, skip\"]}}]}}'`
