/**
 * ACP user-message delivery for the Conversation view (docs/acp-send-now.md).
 *
 * Pure helpers only: what the Hub reports in `acp_delivery` decides where a user message
 * sits and what it says. Nothing here infers state from bridge connectivity, the legacy
 * `read_at` (bridge admission on ACP rows) or the agent's working indicator.
 *
 * - `tray_eligible` (queued or dispatching, hold_reason turn_active, unread) is the ONLY
 *   signal for the "After this turn" group and Send now.
 * - Rows not yet delivered or read (still sending, `sent`, `dispatch_pending`, a steer in
 *   flight) wait above the composer as "Sending" bubbles; a Hub save is not delivery, and
 *   no "Waiting for connection" is shown because no per-message offline state exists.
 * - `delivered` / `read` rows (and `not_delivered`, and failed sends) are in the
 *   transcript. PTY / non-ACP / pre-migration rows have no `acp_delivery` and keep
 *   today's behaviour.
 */

export type AcpDeliveryStatus = 'sent' | 'queued' | 'delivered' | 'read' | 'not_delivered';

export type AcpDelivery = {
  status: AcpDeliveryStatus;
  state: string;
  holdReason: string;
  trayEligible: boolean;
  mode: string;
  launchEpoch: string;
  batchId: string;
  error: string;
  deliveredUnixMs: number;
  agentReadUnixMs: number;
};

const STATUSES: ReadonlySet<string> = new Set(['sent', 'queued', 'delivered', 'read', 'not_delivered']);

function isoToUnixMs(value: unknown): number {
  if (typeof value !== 'string' || !value) return 0;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : 0;
}

/** The message JSON's `acp_delivery`, or null when the row has none (PTY, agent rows, legacy). */
export function parseAcpDelivery(raw: unknown): AcpDelivery | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const status = String(r.status ?? '');
  if (!STATUSES.has(status)) return null;
  return {
    status: status as AcpDeliveryStatus,
    state: String(r.state ?? ''),
    holdReason: String(r.hold_reason ?? ''),
    trayEligible: r.tray_eligible === true,
    mode: String(r.mode ?? ''),
    launchEpoch: String(r.launch_epoch ?? ''),
    batchId: String(r.batch_id ?? ''),
    error: String(r.error ?? ''),
    deliveredUnixMs: isoToUnixMs(r.delivered_at),
    agentReadUnixMs: isoToUnixMs(r.agent_read_at),
  };
}

/** The subset of a chat row these helpers read. */
export type DeliveryRow = {
  key: string;
  messageId: string;
  isUser: boolean;
  createdUnixMs: number;
  sending: boolean;
  deliveryFailedUnixMs: number;
  acpDelivery?: AcpDelivery | null;
  metadata?: any;
};

export type Placement = 'transcript' | 'queued' | 'sending';

/**
 * Where a row goes. `acpConversation` is the authoritative runtime transport (GET
 * send-now `runtime_transport === 'acp'`); it only matters for the optimistic row of a
 * send that has no server copy yet.
 */
export function placementFor(row: DeliveryRow, acpConversation: boolean): Placement {
  if (!row.isUser) return 'transcript';
  const d = row.acpDelivery;
  if (!d) {
    // An ACP send the Hub has not saved yet waits above the composer; everything else
    // without a delivery record (PTY, legacy rows) is a transcript row as today.
    return acpConversation && row.sending && row.deliveryFailedUnixMs <= 0 ? 'sending' : 'transcript';
  }
  if (row.deliveryFailedUnixMs > 0) return 'transcript';
  if (d.trayEligible) return 'queued';
  if (d.status === 'delivered' || d.status === 'read' || d.status === 'not_delivered') return 'transcript';
  return 'sending';
}

/** Assistant rows list the inputs they answer in metadata.acp.input_ids. */
export function answeredInputIds(metadata: any): string[] {
  const ids = metadata?.acp?.input_ids;
  return Array.isArray(ids) ? ids.map(String).filter(Boolean) : [];
}

/**
 * Causal transcript order for a conversation with ACP delivery records. A delivered or
 * read user row is placed when the agent got it (delivered_at, else agent_read_at), never
 * after a reply that answers it (metadata.acp.input_ids). Other rows keep created time.
 * Timestamps are whole seconds, so ties are broken by: an answering reply comes after its
 * input; otherwise the row created first goes first; otherwise input order.
 * Returns the input unchanged when no row has a delivery record (PTY / legacy).
 */
export function orderTranscript<T extends DeliveryRow>(rows: readonly T[]): T[] {
  if (!rows.some((row) => row.acpDelivery)) return rows as T[];
  const answeredBy = new Map<string, number>();
  for (const row of rows) {
    if (row.isUser) continue;
    for (const id of answeredInputIds(row.metadata)) {
      const prev = answeredBy.get(id);
      if (prev === undefined || row.createdUnixMs < prev) answeredBy.set(id, row.createdUnixMs);
    }
  }
  const keyOf = (row: T): number => {
    const d = row.acpDelivery;
    if (!row.isUser || !d) return row.createdUnixMs;
    const reached = d.deliveredUnixMs || d.agentReadUnixMs;
    let key = reached ? Math.max(row.createdUnixMs, reached) : row.createdUnixMs;
    const reply = answeredBy.get(row.messageId);
    if (reply !== undefined && reply > 0 && reply < key) key = reply;
    return key;
  };
  const answers = (reply: T, input: T) => !reply.isUser && input.isUser && answeredInputIds(reply.metadata).includes(input.messageId);
  return rows
    .map((row, index) => ({ row, index, key: keyOf(row) }))
    .sort((a, b) => {
      if (a.key !== b.key) return a.key - b.key;
      if (answers(a.row, b.row)) return 1;
      if (answers(b.row, a.row)) return -1;
      if (a.row.createdUnixMs !== b.row.createdUnixMs) return a.row.createdUnixMs - b.row.createdUnixMs;
      return a.index - b.index;
    })
    .map(({ row }) => row);
}

export type SendNowBatch = {
  batchId: string;
  requestId: string;
  launchEpoch: string;
  attempt: number;
  state: string;
  error: string;
  messageIds: string[];
};

/**
 * What Send now takes for this conversation's runtime (GET send-now `send_now`, declared
 * by the Hub per runtime): `members` sends the turn-held tray snapshot (ACP); `notice`
 * sends no members and the agent is asked to read its unread messages now (PTY); `''`
 * means no Send now.
 */
export type SendNowKind = 'members' | 'notice' | '';

export type SendNowState = {
  conversationId: string;
  runtimeTransport: string;
  sendNow: SendNowKind;
  launchEpoch: string;
  steeringSupported: boolean | null;
  batch: SendNowBatch | null;
};

export function parseSendNowBatch(raw: any): SendNowBatch | null {
  if (!raw || typeof raw !== 'object' || !raw.batch_id) return null;
  return {
    batchId: String(raw.batch_id),
    requestId: String(raw.request_id ?? ''),
    launchEpoch: String(raw.launch_epoch ?? ''),
    attempt: Number(raw.attempt) || 0,
    state: String(raw.state ?? ''),
    error: String(raw.error ?? ''),
    messageIds: Array.isArray(raw.message_ids) ? raw.message_ids.map(String) : [],
  };
}

export function parseSendNowState(raw: any): SendNowState {
  const steering = raw?.steering_supported;
  return {
    conversationId: String(raw?.conversation_id ?? ''),
    runtimeTransport: String(raw?.runtime_transport ?? ''),
    sendNow: raw?.send_now === 'members' || raw?.send_now === 'notice' ? raw.send_now : '',
    launchEpoch: String(raw?.launch_epoch ?? ''),
    steeringSupported: steering === true ? true : steering === false ? false : null,
    batch: parseSendNowBatch(raw?.batch),
  };
}

/** Batch states that are still in flight (the button shows Sending…). */
const BATCH_IN_FLIGHT: ReadonlySet<string> = new Set(['pending', 'sent', 'dispatching']);

export type TrayView<T> = {
  /** Not yet delivered and not turn-held: shown under "Sending", no action. */
  sending: T[];
  /** Turn-held members of the in-flight or failed batch, FIFO. */
  batch: T[];
  /** Turn-held rows outside that batch, FIFO (later arrivals while a batch runs). */
  waiting: T[];
  /** `pending` (Sending…), `failed` (Retry) or `idle` (Send now for `waiting`). */
  batchPhase: 'idle' | 'pending' | 'failed';
  batchError: string;
};

/**
 * Splits the rows above the composer. A batch only groups rows that are still
 * tray-eligible: delivered, read or stale members leave on their own. A batch whose
 * members have all left is ignored.
 */
export function trayView<T extends DeliveryRow>(
  rows: readonly T[],
  acpConversation: boolean,
  batch: SendNowBatch | null,
  localPending = false,
): TrayView<T> {
  const byFifo = (a: T, b: T) => a.createdUnixMs - b.createdUnixMs;
  const sending = rows.filter((row) => placementFor(row, acpConversation) === 'sending').sort(byFifo);
  const queued = rows.filter((row) => placementFor(row, acpConversation) === 'queued').sort(byFifo);
  const inFlight = localPending || Boolean(batch && BATCH_IN_FLIGHT.has(batch.state));
  const failed = !localPending && batch?.state === 'failed';
  const members = new Set(batch && (inFlight || failed) ? batch.messageIds : []);
  const inBatch = queued.filter((row) => members.has(row.messageId));
  const outside = queued.filter((row) => !members.has(row.messageId));
  const phase = inBatch.length === 0 && !localPending ? 'idle' : inFlight ? 'pending' : failed ? 'failed' : 'idle';
  return {
    sending,
    batch: phase === 'idle' ? [] : inBatch,
    waiting: phase === 'idle' ? queued : outside,
    batchPhase: phase,
    batchError: phase === 'failed' ? batch?.error ?? '' : '',
  };
}

/**
 * User rows the agent has not read yet in a `notice` conversation (PTY): saved, not
 * failed, no read evidence. They stay in the transcript; Send now only asks the agent to
 * read them now.
 */
export function unreadUserRows<T extends DeliveryRow & { readUnixMs: number }>(rows: readonly T[]): T[] {
  return rows.filter((row) => row.isUser && !row.acpDelivery && !row.sending && row.deliveryFailedUnixMs <= 0 && row.readUnixMs <= 0);
}

/** The phase of the latest memberless Send now: in flight, failed or settled. */
export function noticeSendNowPhase(batch: SendNowBatch | null): 'idle' | 'pending' | 'failed' {
  if (!batch) return 'idle';
  if (BATCH_IN_FLIGHT.has(batch.state)) return 'pending';
  return batch.state === 'failed' ? 'failed' : 'idle';
}

export function sendNowErrorText(error: string): string {
  switch (error) {
    case 'cancel_timeout': return "Couldn't stop the current turn in time. Still waiting.";
    case 'agent_restarted': return 'The agent restarted. Still waiting.';
    case 'agent_stopped': return 'The agent stopped. Still waiting.';
    case 'bridge_offline': return "The agent's bridge is offline. Still waiting.";
    case 'bridge_no_response': return "The agent's bridge did not respond. Still waiting.";
    case 'send_failed': return "The agent's terminal did not take it. Still waiting.";
    // Not delivered now; the bridge keeps the notice for the agent's next idle.
    case 'held': return 'The agent is restarting. It reads your messages when it is back.';
    case 'stale_epoch': return 'The agent restarted. Still waiting.';
    default: return "Couldn't send now. Still waiting.";
  }
}

export function sendNowTooltip(steeringSupported: boolean | null, kind: SendNowKind = 'members'): string {
  if (kind === 'notice') return 'Stop the current turn and have the agent read its messages now';
  if (steeringSupported === true) return 'Add them to the current turn now';
  if (steeringSupported === false) return 'Stop the current turn and send them now';
  return 'Send them now: added to the current turn, or the current turn stops first';
}

/** Transcript status for an ACP user row. `read_at` is never used: it is bridge admission. */
export function acpDeliveryLabel(d: AcpDelivery): { glyph: string; label: string; tone: string } {
  switch (d.status) {
    case 'read': return { glyph: '✓✓', label: 'Read', tone: 'text-success' };
    case 'delivered': return { glyph: '✓', label: 'Delivered', tone: 'text-muted' };
    case 'not_delivered': return { glyph: '!', label: 'Not delivered', tone: 'text-danger' };
    case 'queued': return { glyph: '…', label: 'Queued', tone: 'text-faint' };
    default: return { glyph: '✓', label: 'Sent', tone: 'text-faint' };
  }
}

/** One stable id per click intent; Retry reuses the batch's own request_id. */
export function newSendNowRequestId(): string {
  const c: any = (globalThis as any).crypto;
  if (c?.randomUUID) return `sn_${c.randomUUID()}`;
  return `sn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}
