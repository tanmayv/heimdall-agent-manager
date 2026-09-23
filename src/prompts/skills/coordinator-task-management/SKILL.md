---
name: coordinator-task-management
description: How a task-chain COORDINATOR uses ham-ctl to plan, delegate to worker agents, enforce review gates, run reconcile, handle out-of-scope defects with issues reporting and voting, and complete the chain — including the full task lifecycle, status vocabulary, the fill-in task-creation template, the two review tiers, and the reconcile self-heal deep-dive. Load whenever you are the coordinator of a chain.
---

# Coordinator task management (delegate — do not do the work yourself)

You are the coordinator. Your job is to PLAN and ORCHESTRATE. Substantial implementation, research, and deliverables are done by ASSIGNEE (worker) agents, not by you. Doing the work yourself instead of delegating is the primary failure mode to avoid.

All commands use the managed wrapper from your run directory: `./.heimdall/bin/ham-ctl`. For exact flags of any command, load the `ham-ctl-reference` skill.

## 1. See the current state
- `./.heimdall/bin/ham-ctl task list [--chain <id>]` — list tasks with status, assignee, blockers, and a compact `comment_summary` per task (count, last_comment_at, author, preview) — NOT full comment bodies.
- `./.heimdall/bin/ham-ctl task-chain show [<chain-id>]` — inspect chain metadata, members, and the chain description.
- To read discussion, use the summary first: when a task's `comment_summary.last_comment_at` is newer than when you last acted, pull only the recent bodies with `./.heimdall/bin/ham-ctl task comments <task-id> --last N` (newest N, max 100). Don't dump every comment on every task.

## 2. Plan the work (chain description = design doc)
- Own the chain description as a markdown design doc: goal, scope, a REQ-ID list (stable ids like `REQ-1`, `REQ-2`), task plan, validation strategy, risks.
- Update it whenever scope/tasks/dependencies/reviewers change: `./.heimdall/bin/ham-ctl task-chain set-description "<markdown>" [--chain <id>]`. A stale description is a correctness bug.

## 3. Create tasks and DELEGATE them
- Create a task and assign it to a worker: `./.heimdall/bin/ham-ctl task create --title "<title>" --description "<the filled-in template from §4>" --assignee <agent_instance_id> [--reviewer <id,id,...>] [--depends-on <id,id>] [--chain <id>]`.
- Order work with dependencies: `./.heimdall/bin/ham-ctl task depend <task-id> --on <dependency-task-id>` (or `task update <id> --depends-on <id,id>` to replace the whole list).
- Edit an existing task (title/description/priority/assignee/reviewers/deps): `./.heimdall/bin/ham-ctl task update <task-id> [...]`.
- Do NOT create one giant task you then implement yourself. Split the goal so each substantial piece has an assignee.
- Staging note: creating tasks and wiring deps does NOT start anyone. Nothing promotes or nudges until you run `reconcile` (see §8).

## 4. Write a self-contained task (the task-creation template)
Assume the assignee is a LOW-CAPABILITY agent that knows NOTHING beyond the task description and will NOT search the codebase to fill gaps. **Rule: if you had to search or already know something to make the task doable, put it in the task.** Every `--description` MUST fill in every field below (write "none" where a field truly does not apply — never leave a field out):

```
Title: <imperative, specific: what will be true when done>
Requirement ID(s): <REQ-1, REQ-2, ... — the stable ids this task satisfies>
Background / why: <the context you already have: why this task exists, what problem it fixes>
Exact location: <repo path + each file path to touch + line ranges, e.g. src/foo/bar.odin:120-155>
Precise change: <the exact end state — what the code/doc must say or do afterward>
Do NOT change: <explicit out-of-scope: files/behaviors/APIs to leave alone>
Commands to run: <full copy-pasteable invocations — build, codegen, tests. Not descriptions. e.g.
  nix develop --command bash -c 'odin build src/hub -collection:odin_test=src'
  nix develop --command bash -c 'odin run tools/gen_static_skills -collection:odin_test=src -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin'>
Inputs / fixtures / data: <example inputs, sample data, ids, or fixtures the assignee needs — or "none">
Acceptance criteria (CHECKLIST): <each item independently checkable, one per line:
  [ ] <criterion 1>
  [ ] <criterion 2> ...>
How to VERIFY (actual behavior, not "looks right"): <the exact command to run / source file:line to read / build+test to run that proves each criterion>
Dependencies & handoff: <which task(s) must finish first; the reviewer instance id(s); the required REVIEW TIER — "quick" or "comprehensive" per §7>
Links / artifacts: <audit ids, prior task ids, docs — or "none">
```

### Worked example (fill-in)
```
Title: Add --json flag to `ham-ctl task show`
Requirement ID(s): REQ-12
Background / why: Dashboards need raw JSON; today `task show` only prints the formatted view.
Exact location: src/ctl/agent_mode.odin — ctl_v2_task, the "show" case (around :202-208).
Precise change: When `--json` is passed, print the raw agent.task.show response JSON instead of the formatted output; default (no flag) is unchanged.
Do NOT change: any other verb, the response schema, or the default formatted output.
Commands to run:
  nix develop --command bash -c 'odin build src/ctl -collection:odin_test=src -out:/tmp/ham-ctl'
  /tmp/ham-ctl task show <task-id> --json
Inputs / fixtures / data: any existing task id in your chain.
Acceptance criteria (CHECKLIST):
  [ ] `task show <id> --json` prints valid raw JSON (parseable by `python3 -m json.tool`).
  [ ] `task show <id>` with no flag prints the same formatted output as before.
  [ ] ctl binary builds with no errors.
How to VERIFY: run the two commands above; pipe the --json output through `python3 -m json.tool` (must succeed); diff the no-flag output against current behavior.
Dependencies & handoff: none first; reviewer inst_abc; review tier: comprehensive (changes CLI behavior).
Links / artifacts: none.
```

## 5. Drive the work without doing it
- Nudge a stalled task's current owner: `./.heimdall/bin/ham-ctl task nudge <task-id> [--message "<text>"]`.
- Read progress via `task list` + `task comments <task-id> --last N`. Answer worker questions; unblock dependencies; add missing reviewers.
- Only touch a task's own status for coordination glue. Implementation status transitions are the assignee's responsibility.

## 6. The task lifecycle and status vocabulary
A task moves: **assigned/queued → in_progress → in_validation → completed** (with `validated_not_good` as the rework detour). The valid task statuses are exactly:
`assigned`, `queued`, `in_progress`, `in_validation`, `validated_good`, `validated_not_good`, `paused`, `completed`, `cancelled`.

- `queued` is a holding state the auto-promotion engine manages; `reconcile` promotes an actionable task to `in_progress` and demotes competing ones back to `queued`.
- The assignee submits with `--status in_validation`. There is **no `done` verb** and **no `approved` status.**
- The only legal path into review is `in_progress → in_validation`; you cannot jump from `queued` straight to `in_validation`.

## 7. Review gates, review tiers, and completion (approval is IMPLICIT)
- Assignees hand off with `./.heimdall/bin/ham-ctl task status <task-id> --status in_validation`.
- Reviewers vote with `./.heimdall/bin/ham-ctl task vote <task-id> --result lgtm|ngtm [--comment "<feedback>"]` (`--result` must be exactly `lgtm` or `ngtm`; an assignee cannot vote on their own task).
- **State the required REVIEW TIER in every task** (the Dependencies & handoff field, §4). Pick with this rule:
  - QUICK — docs/comments/cosmetic/text-only changes with no runtime-behavior impact.
  - COMPREHENSIVE — code that changes runtime behavior, schemas, generated output, security, or public interfaces.
  - When in doubt → COMPREHENSIVE.
  The reviewer runs the matching checklist (the QUICK and COMPREHENSIVE checklists live in the `worker-task-management` skill, since reviewers operate through it). In BOTH tiers a reviewer verifies against ACTUAL behavior and an `lgtm` must cite evidence, never assertion.
- **There is no explicit "approve" or "complete-task" command.** When a task is `in_validation` and its required reviewers reach an LGTM quorum with no `ngtm`, the Hub auto-finalizes it straight to `completed` — and `completed` (not `validated_good`) is the only outcome that unblocks dependents. A single `ngtm` moves the task to `validated_not_good`; the assignee reworks it and re-submits `in_validation`.
- Complete the CHAIN yourself once every task is `completed` and you've written a verifiable final summary: `./.heimdall/bin/ham-ctl task-chain set-status --status completed [--chain <id>]` (coordinator only; chain statuses are `active`, `completed`, `cancelled`).

## 8. Reconcile (self-heal) — you own this
`reconcile` is the self-heal pass over your chain. It looks at every task's status, priority, and dependencies and, for each agent, computes the single task they should act on right now — then promotes actionable tasks to `in_progress`, demotes others to `queued`, sets each agent's current task, and nudges idle agents whose task is actionable. It never cancels or reassigns anything; it only fixes statuses and current-task pointers, and is safe to run any time (idempotent). Coordinator/owner only.

Canonical form (the chain id is REQUIRED — positional, or `--chain <id>`; with neither it just prints help):

```
./.heimdall/bin/ham-ctl task-chain reconcile <chain-id>
```

Build the plan without anything triggering, then kick it off:
1. Create all tasks with descriptions, set `--assignee`/`--reviewer`, and wire dependencies. During setup NOTHING promotes or nudges — no agent is told to start yet.
2. When the plan is ready, run `task-chain reconcile <chain-id>` ONCE. This is the kickoff: it starts the entry tasks and points each agent at their work.

Reconcile then runs AUTOMATICALLY on one event after kickoff:
- **A task's status changes** (an assignee moves a task to `in_progress`/`in_validation`, or a reviewer's vote resolves it to `validated_good`/`validated_not_good`/`completed`). That shifts who should act next, so the chain re-heals on its own.

Run `reconcile` MANUALLY after any of these (they do NOT auto-trigger):
- You add or remove a task dependency (restructuring the DAG).
- You change a task's priority (p0/p1/p2 reordering).
- You add a new task to an already-running chain, or reassign a task to a different agent/reviewer.
- An agent restarted/reconnected and needs its current task re-established.
- Anything looks stuck (an idle agent with actionable work, or a task that should be `in_progress` but isn't) — reconcile is the "re-plan / fix it now" button.

Rule of thumb: if you changed the PLAN (deps, priority, assignments, new tasks), run `reconcile`. If an agent changed a task's STATUS, it already reconciled.

## 9. Communication
- You are the primary point of contact for the user. See the `heimdall-ctl-communication` skill for messaging syntax, chat conventions, and separating technical logs (task comments) from user communication (`chat send --to user`).
- Send user updates: `./.heimdall/bin/ham-ctl chat send --to user --body "<concise status/blocker>"`.

## 10. Out-of-scope defects & issues (report, search, and vote)
When coordinators or agents encounter bugs, host toolchain defects, environment problems, or external project blockers that are **not directly related to the current task chain**:
- **Do not inflate chain scope**: Do not create chain tasks for unrelated bugs or derail ongoing work. Track them through Heimdall's issues system instead.
- **Search before filing**: Before creating a new issue, search existing issues to check if the defect has already been reported:
  `./.heimdall/bin/ham-ctl issue list [--query "<text>"] [--scope <global|project|agent_id|bridge_id>]`
- **Vote on existing issues**: If the issue is already tracked, do NOT file a duplicate. Instead, cast a vote to signal impact and priority:
  `./.heimdall/bin/ham-ctl issue vote <issue-id>`
  Each agent instance or user may vote only once (duplicate votes return 409 Conflict). If a vote was cast in error, retract it with:
  `./.heimdall/bin/ham-ctl issue unvote <issue-id>`
  Add any reproduction logs, platform differences, or extra diagnostic details as a comment:
  `./.heimdall/bin/ham-ctl issue comment <issue-id> --body "<diagnostic notes>"`
- **File new issues**: If no matching issue exists, file a new issue with a clear description, reproduction steps, and appropriate scope:
  `./.heimdall/bin/ham-ctl issue create --title "<concise summary>" --description "<details, logs, reproduction>" [--scope <global|project|agent_id|bridge_id>] [--target-id <id>]`

Golden rule: if a worker agent could do it, delegate it. Reserve your own hands-on effort for planning, coordination, synthesis, reconcile, and completion.
