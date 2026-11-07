# Owner checkpoint notification channel (M3b integration contract)

This additive contract is a checkpoint for the encrypted production integration;
its existence does not establish a connected producer or a provider/platform pass.
The only approved producer is the existing owner-authorized task.hold checkpoint
for its original exact Child and committed executor reservation.

The signed notification binds immutable owner/executor/account/chain, original
task/lease/reservation, exact instance/epoch/count/token/configuration/grant,
both incarnations, original prepare digest, executor reservation launch key,
current deadline version/expiry/hard limit, original hold intent/commit, and
message digest. Literal UTF-8 message bytes travel inside the encrypted outer
exchange; the ASCII authority envelope commits them by digest.

The executor must resolve the accepted bootstrap and original reservation,
verify current paired enrollment and deadline fences, and consume a fresh
action-scoped notification_fence_request/reply before physical dispatch. That
nonce embeds the complete signed notification so another owner thread can
verify its exact digest and original claimed hold intent. The owner snapshots
under its mutex, exchanges without that mutex, and rechecks before persistence.
Held-target checkpoint validation is separate from activation control_active.
These signatures cannot authorize activation, work, renewal or another child.

The local notification IPC startup key is the token digest. Executor launch,
query, close and renewal use the separate reservation launch key. Both remain
bound to the admitted bootstrap; neither may be replaced by an instance-only
lookup.

A delivery ID is the original intent ID. Before any dispatch, retain its exact
daemon PID, ticket, input profile and immutable message/identity. After uncertain
writes, query that same ticket. Daemon journal loss produces recovery_required;
never Prepare a replacement effect. Retained progress/result is observation
only, and may neither grant task authority nor acknowledge a source. Results
bind the complete signed request digest and exact physical progress; unsupported
delivery reports zero progress explicitly. Physical written, provider handled
and source visibility/ACK remain distinct.

Odin and TypeScript share signed substitution vectors in
fixtures/executor-notification-v1.json. The generator is
tests/helpers/generateExecutorNotificationFixture.ts. These are signature and
transport checks, not real-provider interruption evidence.
