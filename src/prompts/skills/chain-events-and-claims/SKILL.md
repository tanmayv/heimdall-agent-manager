---
name: chain-events-and-claims
description: How `[events]` nudges, the durable event inbox, durable claims, transfer and cancel, and requirement-revision acknowledgement work. Load on an `[events]` nudge, a requirements-changed notice, `409 lease_lost`, or before claiming, transferring or cancelling a task.
---

# Chain events and durable claims

Commands use `./bin/ham-ctl`. Role-specific handling of a task event stays in `worker-task-management` and `coordinator-task-management`; this skill owns the mechanics they share.

## Event inbox and migration notices

On an `[events]` nudge, pull the durable inbox:

```bash
./bin/ham-ctl events next --limit 20
# After handling each returned event:
./bin/ham-ctl events ack <event_id...>
```

- Process events within your current role and task scope. Fetch current task/chain state before acting: envelopes contain IDs and enums, not instructions or message bodies.
- Deduplicate by `event_id`: delivery is at least once, and unacked events return after five minutes. After ten attempts the hub republishes to `ev.dlq.<owner>…`.
- Acknowledge only after handling or recording the required follow-up durably (`1..100` ids per `events ack`).
- A `resolved` notice (with `resolved_event_id`) closes an earlier request: do not repeat the resolved action. It needs no acknowledgement (acking it is a no-op). Stale resolvable events are skipped and state events roll up to the latest state.
- Drain further batches as needed. `events next [--wait 30s] [--limit 20]` waits `0s` by default (maximum `30s`, seconds or milliseconds; limit `1..100`).
- Catalog events use v2: `entity.kind` and `entity.id` identify the entity; task events carry the parent in `data.chain_id`. There are no top-level `chain_id` or `task_id` fields.

What each role does with an event:
- **Coordinators** handle review requests, human blocks, merge conflicts and finished batches with the existing task controls and the required user gates.
- **Workers** refresh with `lease next`, read `TASK.md`, reconcile requirements and acknowledge the exact revision (below). Event acknowledgement does not acknowledge requirements. Only work claims subscribe to requirements-change events.
- **Reviewers** learn about mid-review changes from the `[taskv2]` checkpoint nudge (enabled regardless of the legacy-notice flag) and `lease next`. They refresh their pack and checkpoint with `lease handoff` rather than posting a stale verdict.

During migration, existing `[taskv2]` notices remain enabled. Handle them with their existing instructions (`coordinator-task-management` §5) and deduplicate follow-up against inbox events using current task state. Other taskv2 triggers still use that path. The hub flag `--legacy-event-notices true|false` defaults to true and controls only catalog triggers #3/#4/#5/#7/#8; leave it on until staging parity is approved.

## Subscriptions, watches and limits

- `events watch --chain <id>` / `events unwatch --chain <id>` add or remove an explicit watch on a chain owned by your user. `events subscriptions` lists this instance's subscriptions, including automatic role defaults.
- Subscriptions belong to an agent *instance*, not the durable agent: another instance of the same agent has its own. Coordinator defaults belong to the chain's coordinator instance and follow chain membership. Work-claim defaults belong to the claim holder, receive only that task's requirements changes, remain while the claim is waiting and end when ownership ends or moves. Explicit watches belong to the instance that ran `events watch` and receive chain state, human review requests, human blocks and work-finished events.
- `[events]` notices go only to the owning instance, never to another instance or chain, and are counted and rate-limited per instance.
- An idle-stopped instance, or one relaunched in place after a crash, keeps its subscriptions (a wake-worthy event can start it). When the user stops the instance, or it is replaced (its roles move to another instance after it died), its subscriptions and pending events are deleted.
- Every new subscription (including after a restart, a coordinator reassignment or a claim transfer) starts at its creation: earlier events are never replayed.
- Delivery metadata is kept for 14 days, matching the stream. The hub keeps the latest 256 completed acknowledgement receipts per subscription for idempotent retries, and an acknowledgement outside that window may return not found. A subscription admits at most 4,096 delivery records; at capacity, pull leaves further events queued until you acknowledge or resolve existing ones.

## Requirement revisions: acknowledging on your own claim

`task show <task-id>` exposes `requirements_revision`, the submitted revision and head, checkpoint state, acknowledgements and recent history (decrypted when the signed detail capability is available). The coordinator amends requirements (`coordinator-task-management` §9); the holder then:

1. Refreshes with `lease next` and reads the new `TASK.md` (goal, acceptance, revision).
2. Reconciles the work and checks with the amendment.
3. Acknowledges exactly the revision and lease it read:
   ```bash
   ./bin/ham-ctl lease heartbeat --lease <lease-id> --acknowledge-requirements-revision <n>
   ```

- Only the holder may acknowledge its own lease; nobody acknowledges for another agent, and an ordinary heartbeat, comment or event ack is not acknowledgement. If requirements change again, reread and acknowledge the newer revision.
- Submit binds the current lease and revision: a stale or unread revision must be reconciled before submission.
- Submit and review evidence is revision-bound. A change after submission requires worker rework and a fresh review; a comment cannot substitute for a native amendment or an acknowledgement.

## Durable claims, cancellation and transfer

Claims do not expire or need renewal. Active ownership permits execution; waiting ownership retains task, role and owner through review and blocking. Submission and verdicts retain responsibility until completion or explicit release.

```bash
ham-ctl lease <task-id>
ham-ctl lease <task-id> --instance <instance-id>
ham-ctl lease transfer <task-id> --instance <instance-id>
ham-ctl task cancel <task-id>
```

- A plain claim requests work for the calling instance. Its durable agent ID must match the assignee or an eligible reviewer; the server derives the role from current task state. Repeating a claim returns existing responsibility.
- A coordinator can name an eligible instance, including itself when its own durable identity matches. Context goes to that instance; assigning another instance does not overwrite the coordinator's task context.
- Claims never silently replace another holder; use explicit transfer. The old writer is fenced immediately; replacement execution waits for the exact process stop receipt. Offline cleanup remains `stop_pending`.
- Any agent instance of the task's owner may cancel it, without chain membership or coordinator role (cross-owner tasks are refused). Cancellation preserves history and revokes work/review ownership; it can finish while process cleanup is pending, and late callbacks cannot revive the task.
- No prior inspection or manual generation/request ID is needed: the CLI supplies request identity and a default audit reason. Use `--reason` to explain intent; explicit request IDs and generation checks serve advanced callers.
- `task hold`, `task release`, `task unblock` and `task recheck` keep their established meanings; `task release` clears a hold.
- `lease next` refreshes current responsibility. Stay with a waiting task rather than pulling unrelated work. `lease heartbeat` only reports progress or acknowledges requirements; it does not renew ownership.
- `409 lease_lost` on any command: stop at once and touch nothing; the hub re-wakes you with a fresh pack if needed.
