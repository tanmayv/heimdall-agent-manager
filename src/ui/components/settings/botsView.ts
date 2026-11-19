import qrcode from 'qrcode-generator';
import type { BotWhatsApp, BotPlacementCandidate, BotPlacementOptions, BotStatus } from '../../api/endpoints/bots';

export const BOT_STATUS_LABELS: Record<BotStatus, string> = {
  ready: 'Ready', working: 'Answering…', starting: 'Starting…',
  sleeping: 'Asleep — wakes on your next message',
  waiting_for_machine: 'Waiting for a machine — your messages are saved', new: 'Not started yet',
};
export function resolveBotStatusLabel(status: BotStatus): string { return BOT_STATUS_LABELS[status]; }
export const BOT_STATUS_DETAILS: Record<string, string> = {
  no_bridge: 'None of your machines is online.',
  busy: 'Your machine is busy; trying again in a few minutes.',
  relocation_stranded: 'Waiting for the machine your bot last ran on to come back online.',
  gave_up: 'Your bot could not answer your last message. Send another message to try again.',
};
export function filterBotConversations<T extends { agentInstanceId?: string }>(rows: T[], botInstanceId: string | null): T[] {
  return botInstanceId ? rows.filter((row) => row.agentInstanceId !== botInstanceId) : rows;
}
export function validateBotPlacement(rows: BotPlacementCandidate[], options: BotPlacementOptions): string | null {
  if (rows.length > 32) return 'too_many_candidates';
  const providers = new Set(options.bridges.flatMap((bridge) => bridge.providers.map((provider) => provider.provider)));
  const triples = new Set<string>();
  for (const row of rows) {
    if (row.bridge_id !== '*' && !options.bridges.some((bridge) => bridge.bridge_id === row.bridge_id)) return 'unknown_bridge';
    if (row.provider !== '*' && !providers.has(row.provider)) return 'unknown_provider';
    if (row.model !== '*' && row.provider === '*') return 'model_requires_provider';
    const key = JSON.stringify([row.bridge_id, row.provider, row.model]);
    if (triples.has(key)) return 'duplicate_candidate';
    triples.add(key);
  }
  return null;
}

export function whatsAppQrDataUrl(url: string): string {
  const qr = qrcode(0, 'M');
  qr.addData(url);
  qr.make();
  return qr.createDataURL(4, 8);
}
export function whatsAppCardState(w: BotWhatsApp): 'unconfigured' | 'unpaired' | 'paired' | 'held' {
  if (!w.configured) return 'unconfigured';
  if (w.binding === null) return 'unpaired';
  return w.held_replies.length > 0 ? 'held' : 'paired';
}
