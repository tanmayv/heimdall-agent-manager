// Network calls for deferred attention actions. Plain JSON calls (no vault
// encryption needed), sent with fetch keepalive when flushing on page exit, which
// RTK mutations cannot do. Callers invalidate caches after success.
import { apiUrl } from '../../api/cookieFetch';
import { ownerTaskAnswer, ownerTaskCardRef, ownerTaskVerdict } from './ownerTaskActions';

async function send(path: string, method: string, body: unknown, keepalive: boolean): Promise<void> {
  const res = await fetch(apiUrl(path), {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
    credentials: 'include',
    keepalive,
  });
  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const parsed = JSON.parse(await res.text());
      if (parsed?.error?.message) message = parsed.error.message;
    } catch { /* keep the status line */ }
    throw new Error(message);
  }
}

const enc = encodeURIComponent;

/**
 * Primary action: runs the card's operations. On a task card that is Approve
 * (task.review) or, with `{note}`, Answer (task.answer) — checked server-side
 * against the card's guard, so a stale card never acts on a newer attempt.
 */
export const acceptCard = (cardId: string, keepalive: boolean, body: { note?: string; expected_block?: string; replacement_agent_id?: string; expected_attempt?: number } = {}) => {
  // An owner-chain task acts on its owner Bridge, not on a Hub card; its
  // verdict is tied to the attempt the item showed (expected_attempt).
  const { expected_attempt, ...hubBody } = body;
  const owner = ownerTaskCardRef(cardId);
  if (owner) return body.note !== undefined ? ownerTaskAnswer(owner, body.note) : ownerTaskVerdict(owner, 'approve', '', undefined, expected_attempt);
  return send(`/cards/${enc(cardId)}/accept`, 'POST', hubBody, keepalive);
};

/**
 * Rejects the card's source: a memory proposal is rejected; a task review card
 * becomes Request changes with `{summary}` (a gate re-plans with it).
 */
export const rejectCard = (cardId: string, keepalive: boolean, body: { summary?: string; findings?: unknown[]; expected_attempt?: number } = {}) => {
  const { expected_attempt, ...hubBody } = body;
  const owner = ownerTaskCardRef(cardId);
  if (owner) return ownerTaskVerdict(owner, 'request_changes', body.summary ?? '', undefined, expected_attempt);
  return send(`/cards/${enc(cardId)}/reject`, 'POST', hubBody, keepalive);
};

export const snoozeCard = (cardId: string, until: string, keepalive: boolean) => {
  // Owner-chain items are live Bridge state, not stored cards: nothing to snooze.
  if (ownerTaskCardRef(cardId)) return Promise.reject(new Error('Owner-chain tasks cannot be snoozed'));
  return send(`/cards/${enc(cardId)}/snooze`, 'POST', { snooze_until: until }, keepalive);
};

export const markConversationRead = (conversationId: string, keepalive: boolean) =>
  send(`/chats/${enc(conversationId)}/read`, 'POST', {}, keepalive);

