# Explicit task claims and coordinator controls

Agents claim an exact task with `ham-ctl lease <task-id>`. The Hub infers the role
from current task state and resolves the authenticated durable agent identity.
A coordinator assigns a named eligible instance with
`ham-ctl lease <task-id> --instance <instance-id>`; target context is delivered
to that instance, preserving the coordinator’s own task context.

Inspect administrative state with `ham-ctl task inspect <task-id>`.
The result includes the task event generation, owners and process observations,
wait reason, cleanup state, and allowed actions with refusal reasons.

Administrative mutations use an explicit operation, reason, unique request ID,
and the generation returned by inspection:

```bash
ham-ctl task control task_123 --operation cancel --reason "Work superseded" --request-id cancel-123 --expected-generation 42
ham-ctl task reopen task_123 --reason "New work authorized" --request-id reopen-123 --expected-generation 43
```

Supported operations are `cancel`, `reopen`, `hold`, `resume`, `unblock`,
`release-owner`, `rereview`, `force-complete`, and `recheck`. Named CLI
aliases exist for inspect/cancel/reopen/resume/release-owner/rereview/force-complete.
`task release` retains its existing meaning: clear a hold.

`force-complete` records an administrative outcome and requires explicit
`--obligation <text>` entries for unmet obligations. It never creates a human
approval, successful test or successful merge. Policy and dependency safeguards
remain enforced by the service. Coordinator overrides require the chain policy
`allow_coordinator_override`; an authenticated human owner explicitly configures it through the narrow
policy controls below. An authenticated human owner may also invoke the
explicit override directly.

```bash
ham-ctl hub tasks control task_123 --chain chain_123 --operation allow-coordinator-override --reason "Authorize coordinator waivers" --request-id policy-123 --expected-generation 42
# Revoke the policy using --operation deny-coordinator-override.
```

Policy controls require owner authentication and preserve actor, reason, request
identity and expected task generation; coordinator instance tokens cannot enable
their own override authority.

Transfer and recovery use
`ham-ctl lease transfer <task-id> --instance <target> --reason <text> --request-id <id> --expected-generation <task-generation>`
(or `lease recover`). The expected generation is the task event generation returned by inspection.
Process `run_count` is reported separately for runtime observations.
A running previous holder is fenced first; `stop_pending` means replacement
execution still awaits confirmed process exit. Disconnection is not proof of exit.
Confirmation must match the persisted stop command, Bridge, instance and process
generation. Generic stopped status reports cannot clear it; reconnect retries
the same fenced command.

| Capability | Existing CLI surface |
| --- | --- |
| Definition, assignee, reviewers, dependencies, review policy | `task create/update/depend` |
| Dispatch placement/capacity/roles and pause/resume | `task-chain fleet set/pause/resume` |
| Block answer and repair reconciliation | `task unblock/recheck` |
| Process stop, resume, restart | `agents stop/start/restart <instance-id>` |
| Workflow lifecycle | `workflow retry/cancel` for the whole run |
| Chain lifecycle | `task-chain complete/archive/unarchive`; reopen with `task-chain status active --chain <id>`; cancel with `task-chain status cancelled --chain <id>` |

The operator CLI uses `ham-ctl hub task-chains reopen/archive/unarchive`;
chain cancellation uses `ham-ctl hub task-chains update --chain <id> --status cancelled`.

The operator-authenticated task controls use `ham-ctl hub tasks` and a
`--chain <id>` argument for administrative controls. Claims use the agent
authenticated interface so caller and beneficiary cannot be confused.
