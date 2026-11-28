// The PTY unread tray's message high-water mark, mirroring
// src/contracts/agent_notified.odin. GET /chats/{cid}/send-now carries the
// newest user->agent message a typed unread notice covered
// (`agent_notified_through_message_id`, '' when never) and that message's
// created_at (`agent_notified_through_created_at`). The Hub moves it only
// forward in transcript order (created_at, then message_id); an older hub
// omits both fields. No clocks are compared.
export const SEND_NOW_NOTIFIED_THROUGH_MESSAGE_ID_FIELD = 'agent_notified_through_message_id';
export const SEND_NOW_NOTIFIED_THROUGH_CREATED_AT_FIELD = 'agent_notified_through_created_at';

export type AgentNotifiedThrough = {
  /** '' when the agent was never notified. */
  messageId: string;
  /** The message's created_at in unix ms; 0 when never or unparsable. */
  createdUnixMs: number;
};

// Canonical RFC 3339 UTC is 20 characters; anything much longer is not one.
const MAX_TIME_LENGTH = 40;
const MAX_ID_LENGTH = 256;

/**
 * The high-water mark of a send-now state; undefined when the hub does not report
 * it (an older hub), which callers must tell apart from "never notified".
 */
export function agentNotifiedThrough(sendNowState: unknown): AgentNotifiedThrough | undefined {
  const raw = sendNowState as any;
  const id = raw?.[SEND_NOW_NOTIFIED_THROUGH_MESSAGE_ID_FIELD];
  if (typeof id !== 'string') return undefined;
  if (!id || id.length > MAX_ID_LENGTH) return { messageId: '', createdUnixMs: 0 };
  const at = raw?.[SEND_NOW_NOTIFIED_THROUGH_CREATED_AT_FIELD];
  const ms = typeof at === 'string' && at && at.length <= MAX_TIME_LENGTH ? Date.parse(at) : NaN;
  return { messageId: id, createdUnixMs: Number.isFinite(ms) && ms > 0 ? ms : 0 };
}

/**
 * Whether a message is at or before the mark in transcript order (created_at, then
 * message_id, the Hub's order). A mark without a usable time covers only its own id.
 */
export function coveredByNotice(row: { messageId: string; createdUnixMs: number }, through: AgentNotifiedThrough | undefined): boolean {
  if (!through || !through.messageId) return false;
  if (row.messageId === through.messageId) return true;
  if (through.createdUnixMs <= 0 || row.createdUnixMs <= 0) return false;
  if (row.createdUnixMs !== through.createdUnixMs) return row.createdUnixMs < through.createdUnixMs;
  return row.messageId < through.messageId;
}
