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
