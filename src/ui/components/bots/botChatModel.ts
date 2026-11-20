import type { BotStatus, BotView, UnifiedBotMessage } from '../../api/endpoints/bots';

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
    a.read_at === b.read_at && a.replied_at === b.replied_at && a.provider === b.provider && a.created_at === b.created_at;
}

/** Oldest first, so the newest message renders at the bottom. */
export function botTimeline(known: ReadonlyMap<string, UnifiedBotMessage>): UnifiedBotMessage[] {
  return [...known.values()].sort(compareBotMessages);
}

/** A composer send the history has not returned yet. */
export interface PendingBotSend {
  key: string;
  text: string;
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

export function formatBotMessageTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}
