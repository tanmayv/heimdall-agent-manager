---
name: worker-task-management
description: How a worker or reviewer (including a coordinator that is a task's assignee or reviewer) works a lease with ham-ctl — read `TASK.md`, work in the Workdir, choose and report your own checks, `lease submit|handoff|block|switch` with decisions and dead ends, `task fetch`, `review post`, and sharing what you learned with later tasks. Load whenever you are a worker or reviewer on a chain, and before your first submit, handoff, block or verdict.
---

# Worker & reviewer task management (Tickets)

The Hub gives you a **durable claim** on one task, using the compatibility command name `lease`. Claims have no expiry or hard deadline. An active work claim permits execution; a waiting claim retains the task and your claim on it but does not permit work. You never set task status: active work *is* `in_progress`; `lease submit` moves the task to `in_review` (or `done` when nobody reviews it). Work only on the leased task; route scope questions to the coordinator (task comment, or `ham-ctl chat send --to <coordinator-instance-id>`).

All commands use `./bin/ham-ctl`. Exact flags: the `ham-ctl-reference` skill or `ham-ctl <group> --help`.

## Decision table: which command, when
| Situation | Command |
|---|---|
| Woken, or unsure what you hold | read `TASK.md`, then `lease next` |
| Idle and want work (after finishing, or as a coordinator) | `lease next` |
| Need context `TASK.md` omitted or points to | `task fetch <task-id> <ref>` |
| Optional progress update | `lease heartbeat --note "<progress>"` (optional progress; no renewal required) |
| Made a choice others might re-open, or hit a dead end | note it now; pass it at submit/handoff as `--decision` / `--dead-end` |
| Work done | run the checks the change calls for (see §4), commit everything in the Workdir |
| Checks pass on a clean tree | `lease submit --summary "<what exists now; checks run; outcomes>" [--decision …] [--dead-end …]` |
| A check fails | fix, commit, re-run it; never submit a failure without saying so in the summary |
| Context or time running out, not finished | `lease handoff --summary … --next-steps … [--dead-end …]` |
| Need a user decision or an external system | `lease block --waiting-on user --reason "<question>"` (or `--waiting-on <system>`) |
| Brief is ambiguous or contradicts itself | `task comment <task-id> --body "<what is unclear>"`, then block if you cannot proceed |
| TASK.md shows **Checkpoint Requested** (the task was put on hold) | reach a safe point, commit, `lease handoff --summary … --next-steps …`; a reviewer hands off with its review progress instead of posting a verdict. The task stays parked until released |
| Woken with **Merge Conflict** | merge the directory's branch into yours in the Workdir, resolve, commit, re-run the affected checks, submit |
| Woken with `changes_requested` | address every Open Finding, re-check what changed, submit |
| Woken with **Your Block Was Answered** | continue with the answer; no need to ask again |
| Any command returns `409 lease_lost` | stop at once; touch nothing |
| Woken as a reviewer | read the brief, its acceptance and your **Review focus** in `TASK.md`, inspect the head and the worker's reported checks, run your own checks only where a concrete concern remains, then `review post` |
| Review: everything checks out | `review post --verdict approve` |
| Review: something is wrong | `review post --verdict request_changes --summary … [--findings-file …]` |
| Want to postpone this task or do something else first | `lease switch <task_id> --summary …` (a task assigned to you) or `lease handoff --summary … --next-steps …`; never ask for a hold to postpone work (a hold is the coordinator's pause, and the user cannot answer a held task) |
| An urgent task assigned to you arrives mid-task | `lease switch <task_id> --summary "<where you left off>"` |
| Found an unrelated bug | `issue list --query …`, then `issue vote <id>` or `issue create`; do not fix it in this task |

Never: set task status by hand, review your own work, or keep working after `lease_lost`.

## 1. On wake: read `TASK.md`
The Bridge writes `<run_dir>/TASK.md` before your turn. It is your authoritative context. Sections, in order (each only when it applies):

| Section | What it tells you |
|---|---|
| Header | `lease_id`, attempt `n/max`, `review_rounds`, ownership phase, placement (bridge, directory, provider, model) and the **Workdir** + branch |
| Your Block Was Answered | the question you blocked on and the user's answer |
| Rejected At The Gate | why a workflow gate rejected your previous output |
| Merge Conflict | your finished branch did not merge; reconcile it (see §2) |
| Brief | goal and acceptance checklist; for a review, your **Review focus** (what your agent is asked to check). `ham-ctl task show <id>` has the full brief |
| Chain Summary | done tasks (+ commit), open tasks, **dead ends from every attempt in the chain**, coordinator notes |
| From The Tasks This One Waits For | each dependency's handoff summary, decisions, dead ends, next steps, last commit, output |
| Resolved Inputs | the refs your brief lists in `inputs`, resolved |
| Where You Are / Previous Attempt | VCS state; the last attempt's outcome, handoff and heartbeat note |
| Open Findings | review findings you must address |
| Why You Were Chosen | the wake reason: `first_grant`, `review`, `changes_requested`, `handoff`, `answered`, `reopened`, `released`, `user_stopped` |
| Protocol Rules | the 11-rule card; follow it |

`ham-ctl lease next` returns your lease (`status: current` when active, `waiting` when waiting), grants a ready task
(`granted`, rewrites `TASK.md`) or returns `none` (with the task and the first refusal reason when an item for you exists but cannot be granted). A review lease's JSON carries `lease.review_focus` when the brief names one for your agent.

## 2. Work in the Workdir
In a git directory every task gets its own checkout: `<dir>/.heimdall/worktrees/<task_id>` on branch `heimdall/<task_id>`. **`cd` to the Workdir and do all edits and commits there.** `lease submit` runs there automatically. When the task is `done` the Hub merges your branch into the directory's branch. Work from tasks you depend on is already merged into your starting point.

If you are woken with a **Merge Conflict** section: in the Workdir, merge the directory's current branch into yours, resolve, commit, re-run the checks the merge affects, submit.

## 3. Heartbeat and `409 lease_lost`
Claims do not expire. Heartbeats are optional progress notes or explicit requirements acknowledgements; they never renew ownership. At a meaningful milestone, you may leave a note:
```bash
./bin/ham-ctl lease heartbeat --note "fold transitions done; running unit tests"
```
**`409 lease_lost`: stop immediately.** Do not edit, commit or build further; the Hub re-wakes you with a fresh pack if needed.

## 4. Choose and report your checks
No task configures a verification command; you decide what proves the change. Choose and run checks appropriate to the change (a focused build, the tests that cover the code you touched, a reproduction of the bug, a grep for leftovers), and keep them proportionate: copy, docs and other low-risk changes may need none. Run long commands through `ham-ctl shell run`.

Report every check in `lease submit --summary`: the exact command, its outcome (pass/fail counts, exit code), and any check you deliberately skipped and why. A reviewer judges the work from your diff and this evidence; nothing is executed or gated on your behalf.

## 5. Submit, hand off, or block — and share what you learned
The tasks after yours see only their `TASK.md`. What you write here is what they learn:

| You write | Where it goes |
|---|---|
| `--summary` (line 1 = what exists now) | chain summary for **every** later task; full text to dependents and the next attempt |
| `--decision` (repeat per item) | dependents and the next attempt |
| `--dead-end` (repeat per item) | chain summary for every task, dependents, next attempt; never dropped for size |
| `--next-steps` | dependents and the next attempt |
| `--output-file` | dependents (inline when small), workflow fan-out / templates |

**Record every decision others might re-open and every dead end in these flags, not only in the summary text** (protocol rule 11).

```bash
# Finished
./bin/ham-ctl lease submit \
  --summary "Added refresh_tokens table and rotation in auth/tokens.py; unittest green" \
  --decision "sha256 for token hashes (bcrypt too slow per request)" \
  --dead-end "SQLite partial index on revoked_at: our migrator rejects it" \
  [--output-file output.json] [--artifacts-file artifacts.json]

# Not finished (context or time running out): the next holder starts from this
./bin/ham-ctl lease handoff \
  --summary "Migration done; handler wiring remains" \
  --next-steps "add the route in wiring.odin; run odin test src/hub/service/taskchain" \
  --dead-end "taking state_mutex before tx_mutex violates lockorder"

# Waiting on the user or something external
./bin/ham-ctl lease block --waiting-on user \
  --reason "Should the commit-diff limit default to 100 or 200?"
```
- Inline flags or `--handoff-file handoff.json` (`{"decisions":[…],"dead_ends":[…],"next_steps":"…"}`), not both.
- `artifacts.json`: `{"items":[{"kind":"file","path":"…","label":"…"},{"kind":"url","url":"…"},{"kind":"preview_port","port":5173}]}`.
- A block parks the task in `backlog` and retains a waiting claim; the answer arrives in `TASK.md` ("Your Block Was Answered"). `--waiting-on` is free text: `user` for the user, `task` for another task, anything else for external systems.

## 6. Fetch omitted or referenced context
`TASK.md` is capped (~8k tokens). When it overflows, resolved inputs go first, then dependency outputs, then the previous handoff summary, then the description; each is replaced by a fetch pointer. The brief, dead ends and open findings are never dropped.
```bash
./bin/ham-ctl task fetch <task-id> "#123"                          # an event (integer id)
./bin/ham-ctl task fetch <task-id> "output:<other-task-id>"        # another task's output
./bin/ham-ctl task fetch <task-id> "facet:<task_id>:<attempt_no>:<kind>"  # kind: handoff|vcs|output|runtime|artifacts, e.g. facet:<task-id>:1:handoff
./bin/ham-ctl task fetch <task-id> "src/main.odin@<rev>"           # a file at a revision
./bin/ham-ctl task fetch <task-id> "src/main.odin"                 # a file at the default revision (bare <path>)
./bin/ham-ctl task fetch <task-id> "dir:<directory-id>:<rev>:src/main.odin"
```

## 7. Reviewing
When `TASK.md` says `reviewer` (a review lease):
1. Read the brief and its acceptance, the submitted attempt (summary with the checks the worker reported, handoff) and your **Review focus** in `TASK.md` (`lease.review_focus`): it says what *your* agent is asked to check. Without one, review the task as a whole against its acceptance.
2. Inspect the change at the submitted head (`git show --stat <head>`, or `task fetch <task-id> "<path>@<head>"`).
3. Judge correctness yourself. Read the diff against the acceptance items and the worker's reported checks. Run your own checks (for example in a detached worktree at the submitted head) only where a concrete concern remains; say what you checked in `--summary` or findings. Your verdict needs no command evidence.
4. Post the verdict:
   ```bash
   ./bin/ham-ctl review post --verdict approve

   cat > findings.json <<'EOF'
   [{"path": "src/hub/service/taskv2/gate.odin", "line": 142, "severity": "blocker",
     "text": "request_changes from one listed reviewer must keep the gate closed"}]
   EOF
   ./bin/ham-ctl review post --verdict request_changes \
     --summary "one reviewer's request_changes is ignored" --findings-file findings.json
   ```
   Findings use `path`, `line`, `severity`, `text`. `request_changes` needs `--summary` or findings. The response says `gate: waiting|approved|changes_requested`. Posting ends your review lease. When every listed reviewer (and the user, if listed) has approved, the task is `done`, its branch is merged and its dependents become ready. You may not review an attempt your own agent authored.

## 8. When you are the coordinator
A coordinator is an ordinary assignee and reviewer: a task assigned to its agent, or a review it owes, is pulled with `lease next` (nothing is pushed to it). `[taskv2] ready for you: …` means run `lease next`. A coordinator's lease is deleted on submit or block, so it can pull the next item at once; rework returns as a ready task assigned to it. To take an urgent task mid-way: `ham-ctl lease switch <task_id> --summary "<where you left the current one>"` (the current task returns to `ready`; the attempt is not counted). Nobody reviews their own work; the Hub refuses it.

### Unavailable fleet instances

A user-stopped, terminated, or failed fleet instance prevents an automatic replacement launch when no eligible free instance exists on that bridge. Use the task’s **Start agent** card to retry after repairing the cause. Retriable provider errors remain queued during backoff and retry automatically; bridge-offline blocks clear when that bridge reconnects.

## 9. Requirements changed while you work or review

On a requirement-change notice, refresh with `lease next`, read the latest `TASK.md`, reconcile your work and checks, and acknowledge the exact revision on your own lease: see `chain-events-and-claims` "Requirement revisions: acknowledging on your own claim". Report scope decisions and any changed verification in task comments and the handoff.

For review, inspect the submitted requirements revision, attempt and commit. If a change requires a checkpoint, hand off the review rather than approving stale work. After worker rework, assess the new submission; do not reuse an obsolete verdict.

If the change substantially replaces the objective, deliverable or approach, ask the coordinator to record the decision on the original and create a linked replacement. Preserve completed work and checkpoint/handoff context; do not silently repurpose your task.

## Events, claims, transfer and cancel

On an `[events]` nudge (`events next` / `events ack`), or to claim, transfer or cancel a task, load `chain-events-and-claims`: "Event inbox and migration notices" and "Durable claims, cancellation and transfer". The coordinator side of event handling is in `coordinator-task-management` §5.
