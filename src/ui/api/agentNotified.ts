// When the agent was last pointed at its unread user messages, mirroring
// src/contracts/agent_notified.odin. GET /chats/{cid}/send-now carries the
// conversation's stored time as `agent_notified_at` (RFC 3339 UTC, '' when
// never); it only moves forward. Set when the bridge typed the unread-messages
// notice for a runtime whose Send now is a notice, or a notice Send now was
// delivered.
export const SEND_NOW_AGENT_NOTIFIED_AT_FIELD = 'agent_notified_at';

/** Unix ms of a send-now state's `agent_notified_at`; 0 when never, absent (older hub) or invalid. */
export function agentNotifiedUnixMs(sendNowState: unknown): number {
  const raw = (sendNowState as any)?.[SEND_NOW_AGENT_NOTIFIED_AT_FIELD];
  const ms = typeof raw === 'string' && raw ? Date.parse(raw) : NaN;
  return Number.isFinite(ms) && ms > 0 ? ms : 0;
}
