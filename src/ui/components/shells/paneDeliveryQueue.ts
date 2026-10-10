/** Ordered, byte-bounded delivery shared by shell and agent panes. */
export const PANE_DELIVERY_MAX_BYTES = 4 * 1024 * 1024;
export const PANE_DELIVERY_MAX_FRAMES = 256;

export class PaneDeliveryQueue {
  private pending: Array<{ bytes: number; run: () => Promise<void> }> = [];
  private bytes = 0;
  private running = false;
  private stopped = false;
  private idle: Array<() => void> = [];

  private readonly onFailure: () => void;
  private readonly maxBytes: number;

  constructor(onFailure: () => void, maxBytes = PANE_DELIVERY_MAX_BYTES) {
    this.onFailure = onFailure;
    this.maxBytes = maxBytes;
  }

  enqueue(bytes: number, run: () => Promise<void>): boolean {
    if (this.stopped) return false;
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > this.maxBytes - this.bytes || this.pending.length >= PANE_DELIVERY_MAX_FRAMES) {
      this.cancel();
      this.onFailure();
      return false;
    }
    this.bytes += bytes;
    this.pending.push({ bytes, run });
    if (!this.running) void this.drain();
    return true;
  }

  cancel(): void {
    this.stopped = true;
    for (const item of this.pending) this.bytes -= item.bytes;
    this.pending = [];
  }

  whenIdle(): Promise<void> {
    return this.running ? new Promise(resolve => this.idle.push(resolve)) : Promise.resolve();
  }

  get queuedBytes(): number { return this.bytes; }

  private async drain(): Promise<void> {
    this.running = true;
    while (!this.stopped && this.pending.length) {
      const item = this.pending.shift()!;
      try { await item.run(); }
      catch { this.cancel(); this.onFailure(); }
      finally { this.bytes -= item.bytes; }
    }
    this.running = false;
    for (const resolve of this.idle) resolve();
    this.idle = [];
  }
}

/** Format an opaque captured grid after the UI decrypts it. */
export function repaintCapturedScreen(bytes: Uint8Array, row = -1, col = -1): Uint8Array {
  const lines = new TextDecoder().decode(bytes).split(/\r?\n/);
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  const body = lines.join('\r\n');
  const cursor = row >= 0 && col >= 0 ? `\x1b[${row + 1};${col + 1}H` : '';
  return new TextEncoder().encode(`\x1b[2J\x1b[H${body}${body ? '\r\n' : ''}${cursor}`);
}

/** Keep pasted input inside the Hub's frame budget without splitting a surrogate pair. */
export function splitPaneInput(data: string, maxCodeUnits = 8192): string[] {
  if (!Number.isSafeInteger(maxCodeUnits) || maxCodeUnits < 2) throw new RangeError('input chunk size must be at least two code units');
  const parts: string[] = [];
  for (let offset = 0; offset < data.length;) {
    let end = Math.min(offset + maxCodeUnits, data.length);
    const before = data.charCodeAt(end - 1);
    const after = data.charCodeAt(end);
    if (end < data.length && before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) end--;
    parts.push(data.slice(offset, end));
    offset = end;
  }
  return parts;
}
