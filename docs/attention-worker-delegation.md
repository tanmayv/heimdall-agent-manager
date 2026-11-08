# Legacy attention worker delegation

The attention deck and chat action tray share the Start action, replacement picker,
and named failure body in `src/ui/components/attention/StartAgentAction.tsx:18`.
They render agent and Bridge names from the structured `details.start_agent`
projection, with readable unavailable/deleted fallbacks. IDs and old error prose
are retained in collapsed diagnostics (`src/hub/service/card/card_projector.odin:267`).
Names render through the vault text component.

## Decision contract

For a legacy `agent.start` card, the user can send this decision to
`POST /api/v1/cards/{card_id}/accept`:

```json
{
  "expected_block": "failure_observed",
  "replacement_agent_id": "agt_selected"
}
```

Omitting `replacement_agent_id` retains Start's existing behavior. Delegation
requires the displayed block identity, which also pins the assignee and attempt.
The card service checks the card and browser observation, then the engine checks
the full block, assignee and attempt again under its
transaction (`src/hub/service/card/card_service.odin:879`,
`src/hub/service/taskv2/dispatch.odin:173`). Newly recorded dispatch failures carry
a distinct `failure_id`; legacy blocks keep their hash identity
(`src/hub/service/card/card_projector.odin:296`). Identical failures in one clock
tick therefore cannot make an earlier card authorize another launch.

The server rechecks ownership, active durable identity, worker fleet role and
pause, coordinator exclusion, placement/provider support, workflow/hold fences,
live task leases and reviewer independence before changing the assignment
(`src/hub/service/taskv2/delegate_task_agent.odin:21`). It refuses selecting a
required named or role reviewer as author, preserving every review requirement.

Selection plus **Delegate and start** explicitly consents to starting that
durable worker for this ticket, including a stopped worker. Only the chosen idle
instance loses its stop/failure marker, atomically with its normal work lease;
other instances retain their user stops. Capacity, workspace and pending runtime
action checks still apply (`src/hub/service/taskv2/matcher.odin:238`). If a grant
cannot be created, the assignment, stop markers and block roll back together.

After commit, normal wake dispatch launches the child. A launch/admission failure
keeps the replacement assigned and projects a new retryable failure; it does not
restore the old worker or hide the card. Start on the fresh card retries that
replacement. The executor's `instance_not_drained` admission fence is unchanged
(`src/lib/executor_local/local_draft.odin:79`). No record is deleted to force a launch.

## Owner-local handoff

This endpoint handles legacy Hub task records only. Owner-local delegation must
use signed owner operations and must not call the legacy card/lease endpoint.
The current owner resolver accepts exactly one observed running enabled child
(`src/bridge/owner_agent_routing.odin:787`); it cannot resolve a stopped durable
worker by itself.

The owner-local slice should expose the same user intent and named diagnostics,
while implementing a signed launch → observe → recheck → exact-child binding
operation. Bind the task revision, selected durable identity, launch intent and
generation to the request. Retain successful launch state if binding fails, and
reuse that intended generation on retry. Recheck ownership, membership, leases,
drain, capacity, placement and reviewer independence at binding. Preserve global
user-stop behavior outside the explicit selected-worker operation. Unsupported
owner state must stay visible; this legacy slice provides no fallback mutation.
