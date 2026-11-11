// Actions on owner-chain attention items (Hub card id
// otask:<bridge_id>:<chain_id>:<task_id>, provider owner_task). The Hub only
// relays an in-memory "needs you" flag from the owner Bridge (design B); the
// task itself lives on that Bridge, so Answer / Approve / Request changes run
// as signed owner operations through the owner relay, exactly as the chain's
// ticket view does (OwnerChainView decisionActions); Start agent is
// task.resolve, which returns an agent_not_running task to dispatch (the
// dispatcher launches its agent again). There is no Hub card to accept,
// reject or snooze.
import { freshOwnerSession, ownerCall, ownerRelaySend, readOwnerRuntime, readOwnerTask, type OwnerSend } from '../../api/ownerChains';
import type { OwnerSession } from '../../api/ownerLocalClient';

export const OWNER_TASK_PROVIDER = 'owner_task';

export interface OwnerTaskRef { bridgeId: string; chainId: string; taskId: string }

/** The owner task an attention card id names, or null for an ordinary Hub card. */
export function ownerTaskCardRef(cardId: string): OwnerTaskRef | null {
  if (!cardId.startsWith('otask:')) return null;
  const parts = cardId.split(':');
  if (parts.length !== 4 || !parts[1] || !parts[2] || !parts[3]) return null;
  return { bridgeId: parts[1], chainId: parts[2], taskId: parts[3] };
}

export interface OwnerTaskDeps { session: () => Promise<OwnerSession>; send: OwnerSend }
const DEFAULT_DEPS: OwnerTaskDeps = { session: freshOwnerSession, send: ownerRelaySend };

/** Answer: a comment, then task.resolve returns the blocked task to dispatch. */
export async function ownerTaskAnswer(ref: OwnerTaskRef, text: string, deps: OwnerTaskDeps = DEFAULT_DEPS): Promise<void> {
  const body = text.trim();
  if (!body) throw new Error('Write an answer first');
  const s = await deps.session();
  const { bridgeId, chainId, taskId } = ref;
  const before = await readOwnerTask(s, bridgeId, chainId, taskId, deps.send);
  await ownerCall(s, bridgeId, 'task.comment', { chainId, taskId, expectedRevision: before.revision, body }, deps.send);
  const after = await readOwnerTask(s, bridgeId, chainId, taskId, deps.send);
  await ownerCall(s, bridgeId, 'task.resolve', { chainId, taskId, expectedRevision: after.revision }, deps.send);
}

/** Start agent: clear the agent_not_running block so dispatch launches the agent again. */
export async function ownerTaskStartAgent(ref: OwnerTaskRef, deps: OwnerTaskDeps = DEFAULT_DEPS): Promise<void> {
  const s = await deps.session();
  const { bridgeId, chainId, taskId } = ref;
  const task = await readOwnerTask(s, bridgeId, chainId, taskId, deps.send);
  await ownerCall(s, bridgeId, 'task.resolve', { chainId, taskId, expectedRevision: task.revision }, deps.send);
}

/**
 * The user's review verdict on the task's current submission. With
 * `expectedAttempt` (the attempt the deck item showed) a newer submission is
 * refused, as main's card guard refuses a stale card: the user never approves
 * an attempt they did not see.
 */
export async function ownerTaskVerdict(ref: OwnerTaskRef, verdict: 'approve' | 'request_changes', text: string, deps: OwnerTaskDeps = DEFAULT_DEPS, expectedAttempt?: number): Promise<void> {
  // The owner review payload needs a summary (Approve carries none of its own).
  const body = text.trim() || (verdict === 'approve' ? 'Approved.' : '');
  if (!body) throw new Error('Say what should change');
  const s = await deps.session();
  const { bridgeId, chainId, taskId } = ref;
  const rt = await readOwnerRuntime(s, bridgeId, chainId, taskId, deps.send);
  const sub = rt.submission;
  if (!sub) throw new Error('This task has no submission to review');
  if (expectedAttempt !== undefined && expectedAttempt > 0 && sub.attempt !== String(expectedAttempt)) {
    throw new Error(`This task was resubmitted (attempt ${sub.attempt}); open it to review the new submission`);
  }
  const task = await readOwnerTask(s, bridgeId, chainId, taskId, deps.send);
  await ownerCall(s, bridgeId, 'review.post', {
    chainId, taskId, expectedRevision: task.revision, verdict, body,
    attempt: sub.attempt, head: sub.head, requirementsRevision: sub.requirementsRevision,
  }, deps.send);
}
