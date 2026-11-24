# Prompt delivery acknowledgment

Prompt pipeline deliveries linked to a chat message finish only after both bridge
success and a read receipt. Bridge success first enters `delivered` (awaiting
read); reading first leaves the delivery pending until bridge success. The final
state is `done` with outcome `read`. Other delivery kinds and prompts without a
linked message retain their existing completion behavior.

The chat read service writes the receipt and completes matching deliveries in one
unit of work. The lookup uses the partial `pipeline_deliveries_message_read`
index. Forwarding, offline expiry, replacement, and no-answer handling consider
only `routed` and `forwarded` deliveries open.

Entering `delivered` appends a transactional outbox definition at
`sched.def.unread.<delivery_id>`, with `Nats-Schedule: @at` set 30 minutes ahead.
JetStream emits `ev.<owner>.delivery.<delivery_id>.unread`; the existing hub event
matcher handles it without a timer or sweep. An unread delivery enqueues one
ordinary notice, then fails with `not_read`, which is preserved on its action
run. A deleted or downgraded bridge cannot receive a reminder but still permits
the original delivery to fail. Storage errors roll back the operation for retry.
Completed reads purge the definition; a late or duplicate occurrence is harmless.

Action history exposes `delivery_state` and `delivery_outcome` alongside the run
state, so the UI distinguishes “Delivered (awaiting read)” from “Delivered (read)”.

## Runtime acknowledgment contract

Every agent runtime must acknowledge the linked chat message through `chat read`
or `ack_message_ids`; both write the same transactional read receipt. Inline
prompt delivery alone does not count as a read. This includes fresh launches
reporting `started` and ACP prompt injection: ACP transport `agent_read_at` is
a separate receipt and does not complete the prompt pipeline. A runtime that
never calls either chat acknowledgment path receives a reminder and `not_read`
even if it processed inline content. T4 live E2E must verify acknowledgment for
both a fresh `started` launch and an ACP instance.

## Coalescing and missed schedules

While a delivered prompt awaits a read receipt, matching events join its action
run instead of sending additional prompts. Joined history rows reference that
run through `joined_run_id`; its eventual `read` or `not_read` outcome applies
to the shared delivery. Joined events do not send their own prompt payload.

The primary unread deadline remains the NATS schedule at 30 minutes. On entering
`delivered`, its expiry becomes 35 minutes (30 minutes plus a named 5-minute
grace). Existing lazy action lookups, including a later matching event or run
history request, invoke the same unread handler after this bound. This recovers
unsupported, rejected, or missed schedules: one reminder and `not_read`, then a
later event can create a new run. No periodic sweep or hub tick is added; without
another lookup the fallback waits until one occurs. Other delivery states retain
the existing one-hour prompt lifetime.
