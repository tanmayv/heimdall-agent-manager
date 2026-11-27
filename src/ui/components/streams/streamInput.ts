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
