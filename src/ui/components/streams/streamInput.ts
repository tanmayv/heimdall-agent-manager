type Point = { x: number; y: number };
type Action = 'down' | 'up';
export type StreamInputEvent =
  | ({ kind: 'pointer'; action: Action | 'move'; button: number; buttons: number } & Point)
  | ({ kind: 'wheel'; dx: number; dy: number } & Point)
  | { kind: 'key'; action: Action; key: string; code: string; modifiers: number }
  | { kind: 'text'; text: string };

const unit = (n: number) => Math.min(1, Math.max(0, n));

export function streamPoint(rect: Pick<DOMRect, 'left' | 'top' | 'width' | 'height'>, x: number, y: number, clamp = false): Point | undefined {
  if (!rect.width || !rect.height) return;
  x = (x - rect.left) / rect.width;
  y = (y - rect.top) / rect.height;
  if (!clamp && (x < 0 || x > 1 || y < 0 || y > 1)) return;
  return { x: unit(x), y: unit(y) };
}

export function streamKey(event: Pick<KeyboardEvent, 'key' | 'code' | 'altKey' | 'ctrlKey' | 'metaKey' | 'shiftKey'>, action: Action): StreamInputEvent | undefined {
  const encoder = new TextEncoder();
  const { key, code } = event;
  if (!key || key === 'Unidentified' || encoder.encode(key).length > 128 || encoder.encode(code).length > 128) return;
  return { kind: 'key', action, key, code, modifiers: Number(event.altKey) + 2 * Number(event.ctrlKey) + 4 * Number(event.metaKey) + 8 * Number(event.shiftKey) };
}

export function* streamText(text: string): Generator<StreamInputEvent> {
  const encoder = new TextEncoder();
  let chunk = '', length = 0;
  for (const char of text) {
    const size = encoder.encode(char).length;
    if (length + size > 1024) {
      yield { kind: 'text', text: chunk };
      chunk = '';
      length = 0;
    }
    chunk += char;
    length += size;
  }
  if (chunk) yield { kind: 'text', text: chunk };
}

export function streamInputMessage(id: string, events: StreamInputEvent[]) {
  return JSON.stringify({ type: 'stream_input', protocol_version: 1, payload: { stream_id: id, events } });
}

export function isContinuousInput(event: StreamInputEvent) {
  return event.kind === 'wheel' || (event.kind === 'pointer' && event.action === 'move');
}

// The Hub counts eleven 100 ms buckets for all viewers of a route. Restrict this
// viewer's traffic in a full 1100 ms window, with separate headroom for discrete
// events and a small margin for timer/network jitter.
const WINDOW_MS = 1100;
const MAX_TOTAL = 54;
const MAX_CONTINUOUS = 36;
const CONTINUOUS_INTERVAL = 50;
const clampDelta = (value: number) => Math.min(100_000, Math.max(-100_000, value));

export function createStreamInputPacer(
  send: (batch: StreamInputEvent[]) => void,
  now = () => performance.now(),
  schedule = (fn: () => void, delay: number) => setTimeout(fn, delay),
  cancel = (timer: ReturnType<typeof setTimeout>) => clearTimeout(timer),
) {
  let queue: StreamInputEvent[] = [];
  let sent: number[] = [];
  let motionSent: number[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;
  let lastFlush = -Infinity;

  function flush() {
    if (timer !== undefined) cancel(timer);
    timer = undefined;
    const at = now();
    sent = sent.filter(time => at - time < WINDOW_MS);
    motionSent = motionSent.filter(time => at - time < WINDOW_MS);
    if (!queue.length) return;
    const hasDiscrete = queue.some(event => !isContinuousInput(event));
    if (!hasDiscrete && at - lastFlush < CONTINUOUS_INTERVAL) {
      timer = schedule(flush, CONTINUOUS_INTERVAL - (at - lastFlush));
      return;
    }
    const batch: StreamInputEvent[] = [];
    const available = Math.min(MAX_TOTAL - sent.length, 32);
    let remainingDiscrete = queue.reduce((count, event) => count + Number(!isContinuousInput(event)), 0);
    let consumed = 0;
    for (; consumed < queue.length && batch.length < available; consumed++) {
      const event = queue[consumed];
      if (isContinuousInput(event)) {
        // Give every discrete event already in the queue priority over motion.
        if (motionSent.length >= MAX_CONTINUOUS || available - batch.length <= remainingDiscrete) continue;
        motionSent.push(at);
      } else remainingDiscrete--;
      batch.push(event);
    }
    queue = queue.slice(consumed);
    if (batch.length) {
      lastFlush = at;
      sent.push(...batch.map(() => at));
      send(batch);
    }
    if (queue.length) {
      if (sent.length >= MAX_TOTAL && !queue.some(event => !isContinuousInput(event))) queue = [];
      else timer = schedule(flush, sent.length >= MAX_TOTAL ? sent[0] + WINDOW_MS - at : 0);
    }
  }

  return {
    push(event: StreamInputEvent) {
      const last = queue.at(-1);
      if (event.kind === 'pointer' && event.action === 'move' &&
          last?.kind === 'pointer' && last.action === 'move' && last.buttons === event.buttons) {
        queue[queue.length - 1] = event;
      } else if (event.kind === 'wheel' && last?.kind === 'wheel') {
        queue[queue.length - 1] = { ...event, dx: clampDelta(last.dx + event.dx), dy: clampDelta(last.dy + event.dy) };
      } else {
        queue.push(event);
      }
      if (!isContinuousInput(event)) flush();
      else if (timer === undefined) timer = schedule(flush, CONTINUOUS_INTERVAL);
    },
    flush,
    clear() {
      if (timer !== undefined) cancel(timer);
      timer = undefined;
      queue = [];
      // The Hub's rolling budget spans toggles and socket reconnects.
    },
  };
}
