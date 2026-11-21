import type { ChatTimestamp } from './types';
const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
export function formatMessageTimestamp(unixMs: number): ChatTimestamp {
  if (!unixMs) return EMPTY_TIMESTAMP;
  const date = new Date(unixMs);
  if (Number.isNaN(date.getTime())) return EMPTY_TIMESTAMP;
  return {
    label: date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
    iso: date.toISOString(),
  };
}
