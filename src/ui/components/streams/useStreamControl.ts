import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent, type PointerEvent, type RefObject } from 'react';
import { streamKey, streamPoint, streamText, type StreamInputEvent } from './streamInput.ts';

type Pointer = Extract<StreamInputEvent, { kind: 'pointer' }>;
type Key = Extract<StreamInputEvent, { kind: 'key' }>;
const buttonsByIndex = [1, 4, 2, 8, 16];
const delta = (n: number) => Math.min(100_000, Math.max(-100_000, n));

export function useStreamControl(
  ready: boolean,
  viewport: RefObject<HTMLDivElement | null>,
  image: RefObject<HTMLImageElement | null>,
  send: (events: StreamInputEvent[]) => void,
) {
  const [enabled, setEnabled] = useState(false);
  const active = ready && enabled;
  const input = useRef<HTMLTextAreaElement>(null);
  const toggle = useRef<HTMLButtonElement>(null);
  const pointer = useRef<{ id: number; last: Pointer }>(undefined);
  const keys = useRef(new Map<string, Key>());
  const composing = useRef(false);
  const touch = useRef(false);
  const pending = useRef<StreamInputEvent[]>([]);
  const animation = useRef(0);
  const sender = useRef(send);
  sender.current = send;

  function flush() {
    cancelAnimationFrame(animation.current);
    animation.current = 0;
    const events = pending.current;
    pending.current = [];
    if (events.length) sender.current(events);
  }

  function queue(event: StreamInputEvent) {
    const events = pending.current;
    const last = events.at(-1);
    if (event.kind === 'pointer' && event.action === 'move' &&
        last?.kind === 'pointer' && last.action === 'move' && last.buttons === event.buttons) {
      events[events.length - 1] = event;
    } else {
      events.push(event);
    }
    if (events.length === 32) flush();
    else if (!animation.current) animation.current = requestAnimationFrame(flush);
  }

  function release(e?: PointerEvent<HTMLDivElement>) {
    const current = pointer.current;
    if (!current || (e && e.pointerId !== current.id)) return;
    const rect = image.current?.getBoundingClientRect();
    const point = e && rect && streamPoint(rect, e.clientX, e.clientY, true);
    let { buttons } = current.last;
    for (const [button, mask] of buttonsByIndex.entries()) {
      if (!(buttons & mask)) continue;
      buttons &= ~mask;
      queue({ ...current.last, ...point, action: 'up', button, buttons });
    }
    pointer.current = undefined;
    const node = viewport.current;
    if (node?.hasPointerCapture(current.id)) node.releasePointerCapture(current.id);
  }

  function blur() {
    release();
    for (const key of keys.current.values()) queue({ ...key, action: 'up', modifiers: 0 });
    keys.current.clear();
    composing.current = false;
    if (input.current) input.current.value = '';
    flush();
  }

  function disable(restoreFocus = false) {
    blur();
    if (restoreFocus) toggle.current?.focus();
    else input.current?.blur();
    setEnabled(false);
  }

  function onPointer(event: PointerEvent<HTMLDivElement>, action: Pointer['action']) {
    if (!event.isPrimary && event.pointerType !== 'mouse') return;
    const current = pointer.current;
    if (current && current.id !== event.pointerId) return;
    const rect = image.current?.getBoundingClientRect();
    const point = rect && streamPoint(rect, event.clientX, event.clientY, !!current);
    if (!point) return;
    event.preventDefault();
    if (action === 'down') {
      touch.current = event.pointerType === 'touch';
      input.current?.focus({ preventScroll: true });
      event.currentTarget.setPointerCapture(event.pointerId);
    }
    const payload: Pointer = {
      kind: 'pointer', action, ...point, button: action === 'move' ? -1 : event.button,
      buttons: event.pointerType === 'touch' ? Number(action !== 'up') : event.buttons & 31,
    };
    if (payload.button > 4 || (action !== 'move' && payload.button < 0)) return;
    queue(payload);
    if (current || action === 'down') {
      pointer.current = { id: event.pointerId, last: payload };
      if (!payload.buttons) release();
    }
  }

  function onKey(event: KeyboardEvent<HTMLTextAreaElement>, action: Key['action']) {
    if (event.nativeEvent.isComposing || composing.current || event.key === 'Process' || event.key === 'Dead') return;
    if (event.key === 'Escape') {
      event.preventDefault();
      if (action === 'down') disable(true);
      return;
    }
    if (touch.current && [...event.key].length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) return;
    const payload = streamKey(event, action);
    if (payload?.kind !== 'key') return;
    event.preventDefault();
    const identity = payload.code || payload.key;
    if (action === 'down') keys.current.set(identity, payload);
    else if (!keys.current.delete(identity)) return;
    queue(payload);
  }

  function commitText(event: FormEvent<HTMLTextAreaElement>) {
    if (composing.current) return;
    const field = event.currentTarget;
    for (const item of streamText(field.value)) queue(item);
    field.value = '';
  }

  useEffect(() => {
    if (!ready) {
      setEnabled(false);
      pointer.current = undefined;
      keys.current.clear();
      composing.current = false;
      cancelAnimationFrame(animation.current);
      animation.current = 0;
      pending.current = [];
    }
  }, [ready]);

  useEffect(() => () => cancelAnimationFrame(animation.current), []);

  useEffect(() => {
    const field = input.current;
    if (!active || !field) return;
    // Some virtual keyboards emit editing intent without a useful keydown.
    function beforeInput(event: InputEvent) {
      if (event.isComposing || composing.current) return;
      const fallback = {
        deleteContentBackward: ['Backspace', 'Backspace'],
        deleteContentForward: ['Delete', 'Delete'],
        insertLineBreak: ['Enter', 'Enter'],
        insertParagraph: ['Enter', 'Enter'],
      }[event.inputType];
      if (!fallback) return;
      event.preventDefault();
      const [key, code] = fallback;
      queue({ kind: 'key', action: 'down', key, code, modifiers: 0 });
      queue({ kind: 'key', action: 'up', key, code, modifiers: 0 });
    }
    field.addEventListener('beforeinput', beforeInput);
    return () => field.removeEventListener('beforeinput', beforeInput);
  }, [active]);

  useEffect(() => {
    const node = viewport.current;
    if (!active || !node) return;
    function wheel(event: WheelEvent) {
      const rect = image.current?.getBoundingClientRect();
      const point = rect && streamPoint(rect, event.clientX, event.clientY);
      if (!point) return;
      event.preventDefault();
      const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? node!.clientHeight : 1;
      queue({ kind: 'wheel', ...point, dx: delta(event.deltaX * scale), dy: delta(event.deltaY * scale) });
    }
    node.addEventListener('wheel', wheel, { passive: false });
    return () => node.removeEventListener('wheel', wheel);
  }, [active, image, viewport]);

  return {
    active, input, toggle, disable, release, blur, onPointer, onKey, commitText,
    compositionStart: () => { composing.current = true; },
    compositionEnd: (event: FormEvent<HTMLTextAreaElement>) => {
      composing.current = false;
      commitText(event);
    },
    enable: (focus: boolean) => {
      touch.current = !focus;
      setEnabled(true);
    },
  };
}
