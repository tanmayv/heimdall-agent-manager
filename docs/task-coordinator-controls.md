# Durable task claims, cancellation and transfer

Non-expiring ownership keeps a worker or reviewer responsible through submission,
review and external waits. The new commands claim a task, cancel it, or transfer
ownership to a named eligible instance.

## Agent commands

Claims do not expire or require renewal. Active ownership permits execution;
waiting ownership retains task, role and owner through review and blocking.
Submission and verdicts retain responsibility until completion or explicit release.

```bash
ham-ctl lease <task-id>
ham-ctl lease <task-id> --instance <instance-id>
ham-ctl lease transfer <task-id> --instance <instance-id>
ham-ctl task cancel <task-id>
```

- A plain claim requests work for the calling instance. Its durable agent ID must
  match the assignee or an eligible reviewer; the server derives the role from
  current task state. Repeating a claim returns existing responsibility.
- A coordinator can name an eligible instance, including itself when its own
  durable identity matches. Context goes to that instance; assigning another
  instance does not overwrite the coordinator's task context.
- Claims do not silently replace another holder. Use explicit transfer. The old
  writer is fenced immediately; replacement execution waits for the exact process
  stop receipt. Offline cleanup remains `stop_pending`.
- Cancellation preserves history and revokes work/review ownership. It can finish
  while process cleanup is pending; late callbacks cannot revive the task.
- No prior inspection or manual generation/request ID is needed. The CLI supplies
  request identity and a default audit reason. Use `--reason` to explain intent;
  optional explicit request IDs and generation checks serve advanced callers.
- Existing `task hold`, `task release`, `task unblock` and `task recheck` retain
  their established meanings. `task release` clears a hold.
- `lease next` refreshes current responsibility. Stay with a waiting task rather
  than pulling unrelated work. `lease heartbeat` only reports progress or
  acknowledges requirements; it does not renew ownership.


## Safety and storage

The Hub checks authorization, current state and durable identity inside its
transaction. A transfer reserves the named replacement, fences the former writer,
and confirms that exact process stopped before enabling execution. A repeated
request cannot create duplicate active owners. A stopped status projection alone
is not a stop receipt.

The schema adds one active/waiting phase column to existing claims. It adds no
tables or generation counters. Optional explicit concurrency checks reuse the
latest existing task event ID through an indexed scalar lookup.

## Scope

The new inspection/generic-control API, administrative completion, coordinator
override policy, re-review and release-owner commands have been removed from this
change. Preexisting task and workflow operations remain available. Ordinary
cancellation and transfer do not approve submissions or bypass review gates.
