import type { BotStatus, BotView, UnifiedBotMessage } from '../../api/endpoints/bots';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from '../chat/types';

/** The hub refuses web text above this many UTF-8 bytes (docs/bots-web-channel.md). */
export const BOT_WEB_TEXT_MAX_BYTES = 16384;
export const BOT_HISTORY_PAGE_SIZE = 50;

export const BOT_CHANNEL_LABELS: Record<UnifiedBotMessage['provider'], string> = {
  telegram: 'Telegram', whatsapp: 'WhatsApp', web: 'Web',
};

/** Statuses where the bot's agent process is up. Everything else reads as stopped. */
const RUNNING: ReadonlySet<BotStatus> = new Set<BotStatus>(['ready', 'working', 'starting']);
export function isBotRunning(status: BotStatus): boolean { return RUNNING.has(status); }

/** Channels the user can reach the bot on. Web is built in and always available. */
export function connectedBotChannels(bot: Pick<BotView, 'telegram' | 'whatsapp'>): string[] {
  const channels = ['Web'];
  if (bot.telegram?.binding?.state === 'active') channels.push('Telegram');
  if (bot.whatsapp?.binding?.state === 'active') channels.push('WhatsApp');
  return channels;
}

/** Hub ordering is (created_at, message_id); compare the same way, ascending. */
export function compareBotMessages(a: UnifiedBotMessage, b: UnifiedBotMessage): number {
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? -1 : 1;
  return a.message_id < b.message_id ? -1 : a.message_id > b.message_id ? 1 : 0;
}

/**
 * Upsert messages by id. A refreshed newest page replaces rows it still holds
 * (send_state/read_at change) without dropping older rows it has pushed out, so a
 * live update never opens a gap between the head and the pages loaded before it.
 * Returns the same map when nothing changed so React state can bail out.
 */
export function mergeBotMessages(
  known: ReadonlyMap<string, UnifiedBotMessage>,
  incoming: readonly UnifiedBotMessage[] | undefined,
): ReadonlyMap<string, UnifiedBotMessage> {
  if (!incoming?.length) return known;
  let next: Map<string, UnifiedBotMessage> | null = null;
  for (const message of incoming) {
    const previous = known.get(message.message_id);
    if (previous && sameMessage(previous, message)) continue;
    next ??= new Map(known);
    next.set(message.message_id, message);
  }
  return next ?? known;
}

function sameMessage(a: UnifiedBotMessage, b: UnifiedBotMessage): boolean {
  return a.body === b.body && a.body_purged === b.body_purged && a.send_state === b.send_state &&
    JSON.stringify(a.attachments ?? []) === JSON.stringify(b.attachments ?? []) && a.read_at === b.read_at && a.replied_at === b.replied_at && a.provider === b.provider && a.created_at === b.created_at;
}

/** Oldest first, so the newest message renders at the bottom. */
export function botTimeline(known: ReadonlyMap<string, UnifiedBotMessage>): UnifiedBotMessage[] {
  return [...known.values()].sort(compareBotMessages);
}

/** A composer send the history has not returned yet. */
export interface PendingBotSend {
  key: string;
  text: string;
  artifact_ids?: string[];
  state: 'sending' | 'sent' | 'failed';
  message_id: string;
  error: string;
}

/** A pending send disappears once its stored message arrives in history. */
export function visiblePendingSends(pending: readonly PendingBotSend[], known: ReadonlyMap<string, UnifiedBotMessage>): PendingBotSend[] {
  return pending.filter((send) => !send.message_id || !known.has(send.message_id));
}

export function utf8ByteLength(text: string): number {
  return new TextEncoder().encode(text).length;
}

export type ComposerCheck = 'empty' | 'too_long' | null;
export function checkBotComposerText(text: string): ComposerCheck {
  if (!text.trim()) return 'empty';
  if (utf8ByteLength(text) > BOT_WEB_TEXT_MAX_BYTES) return 'too_long';
  return null;
}

/** Client request id; the same key is reused when retrying the same text. */
export function newIdempotencyKey(): string {
  const c = (globalThis as { crypto?: Crypto }).crypto;
  if (c && typeof c.randomUUID === 'function') return 'web-' + c.randomUUID();
  return 'web-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12);
}

/**
 * The line shown above the composer while the bot cannot answer right away.
 * `waiting` means the user has an unanswered message (queued or just sent).
 */
export function botQueueNotice(status: BotStatus, waiting: boolean): { tone: 'info' | 'warning'; text: string } | null {
  switch (status) {
    case 'starting': return { tone: 'info', text: waiting ? 'Your bot is starting. Your message is queued and will be answered shortly.' : 'Your bot is starting…' };
    case 'waiting_for_machine': return { tone: 'warning', text: 'Waiting for a machine. Your messages are saved and will be answered when one is online.' };
    case 'sleeping': return waiting ? { tone: 'info', text: 'Waking your bot. Your message is queued.' } : null;
    case 'new': return waiting ? { tone: 'info', text: 'Starting your bot for the first time. Your message is queued.' } : null;
    case 'working': return waiting ? { tone: 'info', text: 'Your bot is answering…' } : null;
    default: return null;
  }
}

/** True when the newest stored message is the user's and the bot has not replied. */
export function awaitingBotReply(timeline: readonly UnifiedBotMessage[], pending: readonly PendingBotSend[]): boolean {
  if (pending.some((send) => send.state !== 'failed')) return true;
  const last = timeline[timeline.length - 1];
  return Boolean(last && last.direction === 'inbound' && !last.replied_at);
}

/** Error copy for a history or send failure, by HTTP status. */
export function botChatErrorText(status: number | undefined, fallback: string): string {
  if (status === 403) return 'Bots are not enabled for your account. Turn on Bots in Settings › Experimental.';
  if (status === 404) return "You don't have a bot yet. Create one in Settings › Bots.";
  return fallback;
}

/** Bot-specific fields carried on a `ChatMessage` for the shared list's meta row. */
export interface BotChatMeta {
  provider: UnifiedBotMessage['provider'];
  /** Outbound send_state, '' for inbound rows. */
  sendState: string;
  purged: boolean;
  /** Set on a composer send the history has not returned yet. */
  pending?: PendingBotSend['state'];
}

export function botChatMeta(message: ChatMessage): BotChatMeta | null {
  const meta = message.metadata?.bot;
  return meta && typeof meta === 'object' ? meta as BotChatMeta : null;
}

function isoToUnixMs(iso: string): number {
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? 0 : ms;
}

/**
 * The unified history and the unconfirmed sends as rows for the shared ChatMessageList.
 * A stored message that answers a composer send keeps that send's key (`sentKeys`:
 * message_id → idempotency key), so the send pin and the row survive the ack exactly as
 * the coordinator chat's optimistic rows do.
 */
export function botChatMessages(
  timeline: readonly UnifiedBotMessage[],
  pending: readonly PendingBotSend[],
  sentKeys: ReadonlyMap<string, string>,
): ChatMessage[] {
  const rows: ChatMessage[] = timeline.map((message) => {
    const mine = message.direction === 'inbound';
    const sendState = mine ? '' : message.send_state;
    const failed = !mine && (sendState === 'failed' || sendState === 'held');
    return {
      key: sentKeys.get(message.message_id) ?? message.message_id,
      messageId: message.message_id,
      body: message.body_purged ? '' : message.body,
      artifactIds: message.body_purged ? [] : (message.attachments ?? []).map(a => a.artifact_id).filter(Boolean),
      isUser: mine,
      createdUnixMs: isoToUnixMs(message.created_at),
      deliveredUnixMs: 0,
      readUnixMs: mine && message.read_at ? isoToUnixMs(message.read_at) || 1 : 0,
      deliveryFailedUnixMs: failed ? 1 : 0,
      deliveryError: failed ? 'Not delivered' : '',
      sending: !mine && Boolean(sendState) && sendState !== 'sent' && !failed,
      authorLabel: '',
      messageType: 'text',
      metadata: { bot: { provider: message.provider, sendState, purged: message.body_purged } satisfies BotChatMeta },
    };
  });
  for (const send of pending) {
    rows.push({
      key: send.key,
      messageId: send.message_id || send.key,
      body: send.text,
      artifactIds: send.artifact_ids,
      isUser: true,
      createdUnixMs: 0,
      deliveredUnixMs: 0,
      readUnixMs: 0,
      deliveryFailedUnixMs: send.state === 'failed' ? 1 : 0,
      deliveryError: send.state === 'failed' ? 'Not sent' : '',
      sending: send.state === 'sending',
      authorLabel: '',
      messageType: 'text',
      metadata: { bot: { provider: 'web', sendState: '', purged: false, pending: send.state } satisfies BotChatMeta },
    });
  }
  return rows;
}

/** True for a row the composer just appended (pins under the top like the coordinator's sends). */
export function isBotComposerSend(message: ChatMessage): boolean {
  return botChatMeta(message)?.pending !== undefined;
}

/** Delivery line for the user's own rows: sending, queued for the bot, read, or not sent. */
export function botDeliveryStatus(message: ChatMessage): ChatDeliveryStatus {
  if (!message.isUser) return { glyph: '', label: '', tone: '' };
  if (message.sending) return { glyph: '…', label: 'Sending', tone: 'text-muted' };
  if (message.deliveryFailedUnixMs > 0) return { glyph: '!', label: message.deliveryError || 'Not sent', tone: 'text-danger' };
  if (message.readUnixMs > 0) return { glyph: '✓✓', label: 'Read', tone: 'text-success' };
  return { glyph: '✓', label: 'Queued', tone: 'text-faint' };
}

/** Same short form as the coordinator chat (time only) for today; date and time otherwise. */
export function formatBotChatTimestamp(unixMs: number, now = Date.now()): ChatTimestamp {
  if (!unixMs) return { label: '', iso: '' };
  const date = new Date(unixMs);
  if (Number.isNaN(date.getTime())) return { label: '', iso: '' };
  const sameDay = new Date(now).toDateString() === date.toDateString();
  return {
    label: sameDay ? date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : formatBotMessageTime(date.toISOString()),
    iso: date.toISOString(),
  };
}

export function formatBotMessageTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}
