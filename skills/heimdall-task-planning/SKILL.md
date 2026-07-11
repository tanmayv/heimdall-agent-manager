---
name: heimdall-task-planning
description: >
  Use this skill when creating or managing task chains in Heimdall. Covers
  task chain design, status lifecycle, reviewer setup, comment discipline,
  progress logging, and git audit trails. Apply whenever you are asked to
  plan, break down, or coordinate multi-step work with other agents.
type: core
---

# Heimdall Task Planning

## When to use this skill

- You are asked to plan or break down a feature, bug fix, or investigation into steps
- You are coordinating work across multiple agents
- You need to track progress and keep an audit trail
- You are reviewing another agent's work

---

## Task Chain Design

### One chain per feature/initiative

A task chain represents a single coherent initiative — a feature, a refactor, a
bug investigation. Do not mix unrelated work in one chain.

### Put the design doc in the chain description

The chain `description` field is the design document. Before creating any tasks,
write a clear description that covers:

- **Goal**: what the chain achieves and why
- **Scope**: what is in and out of scope
- **Approach**: high-level strategy
- **Open questions**: anything unresolved at planning time
- **Acceptance**: how you know the chain is done

Agents and reviewers reference this throughout the chain — keep it current if
the design evolves (use `task-chains update`).

### Chain statuses

| Status | Meaning | What to do |
|---|---|---|
| `planning` | Chain is being defined; no tasks should start yet | Add tasks, assign agents, add reviewers, finalize description |
| `in_progress` | Work is active | Activate with `task-chains activate` — tasks will auto-promote |
| `blocked` | Chain cannot proceed | Set with `task-chains status --status blocked`, explain blocker in summary |
| `completed` | All tasks approved | Auto-set when last task is approved, or manual with `task-chains complete` |

**Never activate a chain before the design is clear.** The `planning` state
exists to let you build the full task graph before any agent picks up work.

### One active chain per project

Only one chain can be `in_progress` per project at a time. If you need to start
a new chain while one is active, either complete/block the current chain first
or use a different project.

---

## Task Design

### One task = one unit of reviewable work

Each task should be small enough that a reviewer can meaningfully approve it in
one pass. A good task produces a concrete artifact: a file changed, a feature
implemented, a document written, a test passing.

### Task statuses lifecycle

```
planning → ready → in_progress → review_ready → approved
                ↘                             ↗
                  blocked (manual, from any state)
```

| Status | Who sets it | Meaning |
|---|---|---|
| `planning` | System | Task created, waiting for deps or chain activation |
| `ready` | System (auto) | Deps satisfied, chain active — assignee will be notified |
| `in_progress` | System (auto-claim) | Assignee picked it up |
| `review_ready` | Assignee | Work complete, submitted for review |
| `approved` | System (auto) | All required reviewers approved |
| `blocked` | Assignee / coordinator | Cannot proceed, needs attention |
| `cancelled` | Coordinator only | Task will not be done |

**You do not need to manually set `ready` or `approved`** — the system handles
these transitions automatically.

### Agents are auto-notified

- When a task becomes `ready`, the assignee receives an immediate notification
- When a task becomes `review_ready`, all `lgtm_required` participants are notified
- When a reviewer votes, they are nudged about their next pending review
- The nudge scheduler will re-notify if a task sits idle too long

**You do not need to ping agents manually** unless you want to add context
beyond what the task already contains.

### Dependency ordering

Use `depends_on` to enforce ordering within a chain. A task with unmet
dependencies stays `planning` until those tasks reach `approved`.

```
ham-ctl tasks create --token $TOKEN \
  --chain-id $CHAIN \
  --title "Implement feature X" \
  --depends-on "task-abc123,task-def456"
```

Prefer shallow dependency graphs — deep chains block progress and are hard to
reason about. If task C only needs task A's output (not B's), don't make C
depend on B.

### Assignee constraint

An agent can only work on one task at a time. If an agent is already
`in_progress` on a task, their next task will auto-claim only when the current
one is approved. Plan agent load accordingly — do not assign all tasks to one
agent if they can be parallelized across agents.

---

## Reviewer Setup

### Use `lgtm_required` for gates, `lgtm_optional` for input

```bash
# Required: task cannot auto-approve without this agent's LGTM
ham-ctl tasks participant --token $TOKEN --task-id $TASK \
  --agent-instance-id reviewer-agent \
  --role lgtm_required

# Optional: vote is recorded and visible but does not gate approval
ham-ctl tasks participant --token $TOKEN --task-id $TASK \
  --agent-instance-id auditor-agent \
  --role lgtm_optional
```

Auto-approval fires the moment all `lgtm_required` participants have voted
`lgtm`. Add `lgtm_optional` reviewers when you want additional eyes but do not
want to block progress.

### Reviewers work on one review at a time

A reviewer with an active `review_ready` task will not receive notifications
for another until they vote. After voting, they are automatically nudged about
their next pending review. This means: **do not assign the same agent as
`lgtm_required` on many tasks in the same chain** if you want reviews to
happen in parallel.

### How to vote

```bash
# Approve
ham-ctl tasks vote --token $TOKEN --task-id $TASK \
  --result lgtm --comment "Looks good. Logic is sound and tests pass."

# Reject — task moves back to in_progress automatically
ham-ctl tasks vote --token $TOKEN --task-id $TASK \
  --result ngtm --comment "The error handling in line 42 is incorrect — see comment C1."
```

A `ngtm` vote moves the task back to `in_progress` and notifies the assignee.
Always include a specific, actionable comment so the assignee knows exactly
what to fix.

---

## Comments: Sharing Feedback Effectively

### Comments are the review thread

Use comments to communicate specific, actionable feedback rather than vague
status updates. Good comments are:

- **Specific**: reference the file, function, or decision being discussed
- **Actionable**: tell the assignee what to change or why something is correct
- **Resolving**: once the issue is addressed, the assignee resolves the comment

```bash
# Add a comment
ham-ctl tasks comment --token $TOKEN --task-id $TASK \
  --body "auth.odin:47 — the token expiry check uses > instead of >=, which allows expired tokens through by one millisecond."

# Resolve it after fixing
ham-ctl tasks comment-resolve --token $TOKEN --task-id $TASK \
  --comment-id cmt_1234567
```

### Fetch unresolved comments before responding

When you are notified about a task, always fetch unresolved comments first —
nudge messages include a count and snippets, but the full list gives you
everything:

```bash
ham-ctl tasks comments --token $TOKEN --task-id $TASK --unresolved
```

### Resolve comments promptly

Unresolved comments appear in nudge messages and accumulate as noise. Resolve
a comment as soon as you have addressed it — do not wait until you submit for
review. If a comment is not actionable (e.g. a question that was answered
verbally), resolve it with a brief explanation.

### Do not use status changes as comment proxies

The `body` field on a status change (e.g. `tasks status --body "done"`) is for
a one-line summary of what changed, not a feedback thread. Substantive
discussion belongs in comments.

---

## Progress Logging for Audit

### Log progress in comments, not just status changes

After each meaningful unit of work, add a comment summarizing what you did,
what decisions you made, and what changed. This creates an audit trail inside
the task itself.

Good progress log comment format:

```
Progress: <what was done>

Decisions:
- <decision 1 and rationale>
- <decision 2 and rationale>

Blockers: <none | description>

Next: <what comes next>
```

### Capture git commits in the progress log

When you push code changes for a task, record the commit hash in a progress
comment so the task log links back to the exact state of the code:

```bash
ham-ctl tasks comment --token $TOKEN --task-id $TASK \
  --body "Progress: implemented auth token rotation

Commits:
- abc1234: add token rotation to auth_service.odin
- def5678: add unit tests for rotation edge cases

Decisions:
- Used HMAC-SHA256 over RSA for performance on constrained hardware

Next: submit for review"
```

This makes it possible to audit exactly what code was produced for each task,
trace bugs to specific changes, and reconstruct the history of a chain from
the task event log alone.

### Use task log for full audit trail

The full event log for a task (all status changes, comments, votes, nudges) is
queryable:

```bash
ham-ctl tasks log --token $TOKEN --task-id $TASK
```

This is the canonical audit source. When completing a chain, the coordinator
should verify the log is coherent before calling `task-chains complete`.

---

## Full Workflow: Creating a Task Chain

```bash
CTL="./bin/linux-x86_64/ham-ctl --config ./config.toml"
TOKEN="<your-agent-token>"
PROJECT="<project-id>"

# 1. Create the chain in planning state with a full design doc in description
CHAIN=$($CTL task-chains create --token $TOKEN \
  --project-id $PROJECT \
  --title "Add token rotation to auth system" \
  --description "Goal: rotate auth tokens on every request to limit exposure window.
Scope: auth_service.odin and dependent callers. Out of scope: session management.
Approach: HMAC-SHA256 chained rotation, 5-minute window.
Acceptance: all existing auth tests pass, rotation test added." \
  | jq -r .chain_id)

# 2. Create tasks with dependencies
T1=$($CTL tasks create --token $TOKEN --chain-id $CHAIN \
  --title "Implement token rotation in auth_service.odin" \
  --assignee agentA \
  --coordinator agentC | jq -r .task_id)

T2=$($CTL tasks create --token $TOKEN --chain-id $CHAIN \
  --title "Add tests for rotation edge cases" \
  --assignee agentA \
  --depends-on $T1 | jq -r .task_id)

# 3. Add reviewers
$CTL tasks participant --token $TOKEN --task-id $T1 \
  --agent-instance-id agentB --role lgtm_required
$CTL tasks participant --token $TOKEN --task-id $T2 \
  --agent-instance-id agentB --role lgtm_required

# 4. Activate — chain goes in_progress, T1 auto-promotes to ready,
#    agentA is auto-notified, T1 auto-claims to in_progress
$CTL task-chains activate --token $TOKEN --chain-id $CHAIN

# From here the system drives progress automatically:
# agentA works → sets review_ready → agentB notified → votes lgtm
# → T1 auto-approved → T2 auto-promotes → agentA auto-claimed
# → agentA works on T2 → review_ready → agentB votes → T2 approved
# → chain auto-completes
```

---

## Checklist Before Activating a Chain

- [ ] Chain description contains goal, scope, approach, acceptance criteria
- [ ] All tasks have clear titles and acceptance criteria in description
- [ ] Dependencies between tasks are set correctly
- [ ] Each task has at least one `lgtm_required` reviewer (unless coordinator-only review)
- [ ] Assignees are available (no other active tasks)
- [ ] Coordinator is set on the chain for escalation path
- [ ] Project ID is set if one-active-per-project enforcement is needed
