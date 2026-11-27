import { useEffect, useRef, useState, type PointerEvent } from 'react';
import { IconButton, Spinner, Text } from '@ui';
import ViewerHeader from '../ViewerHeader';
import { StreamSecureForms } from '../chat/SecureForm';
import { useStreamViewer, type StreamStatus } from './useStreamViewer.ts';
import { centeredPan, clampPan, fitFrame, toggleFit, type FitMode, type Pan, type Size } from './streamViewport.ts';

import { StreamSwitcher } from './StreamSwitcher.tsx';
import { useStreamControl } from './useStreamControl.ts';

const labels = {
  loading: 'Connecting',
  waiting: 'Waiting',
  live: 'Live',
  paused: 'Paused',
  ended: 'Ended',
  expired: 'Expired',
  unavailable: 'Unavailable',
  unauthorized: 'Unauthorized',
  error: 'Disconnected',
} satisfies Record<StreamStatus, string>;

export default function StreamViewerPage({ streamId, onBack, onSwitch }: { streamId: string; onBack: () => void; onSwitch: (id: string) => void }) {
  const { status, image, meta, reconnect, sendInput } = useStreamViewer(streamId);
  const [formRefresh, setFormRefresh] = useState(0);
  const title = meta?.title || 'Shared tab';
  const viewportRef = useRef<HTMLDivElement>(null);
  const imageRef = useRef<HTMLImageElement>(null);
  const drag = useRef<{ id: number; x: number; y: number }>(undefined);
  const [dragging, setDragging] = useState(false);
  const [viewport, setViewport] = useState<Size>({ width: 0, height: 0 });
  const [natural, setNatural] = useState<Size>();
  const [{ mode, pan }, setView] = useState<{ mode: FitMode; pan: Pan }>({ mode: 'fit-width', pan: centeredPan });
  const frame = image && natural ? fitFrame(mode, natural, viewport) : viewport;
  const control = useStreamControl(status === 'live' && !!natural, viewportRef, imageRef, sendInput);
  const offset = clampPan(pan, frame, viewport);
  const canPan = frame.width > viewport.width || frame.height > viewport.height;

  useEffect(() => {
    const node = viewportRef.current;
    if (!node) return;
    const observer = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setViewport({ width, height });
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  function stopDrag() {
    const node = viewportRef.current;
    const id = drag.current?.id;
    drag.current = undefined;
    if (id !== undefined && node?.hasPointerCapture(id)) node.releasePointerCapture(id);
    setDragging(false);
  }

  function pointerDown(event: PointerEvent<HTMLDivElement>) {
    if (!canPan || drag.current || event.button !== 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY };
    setDragging(true);
  }

  function pointerMove(event: PointerEvent<HTMLDivElement>) {
    const active = drag.current;
    if (!active || active.id !== event.pointerId) return;
    const dx = event.clientX - active.x;
    const dy = event.clientY - active.y;
    drag.current = { id: active.id, x: event.clientX, y: event.clientY };
    setView(previous => {
      const current = clampPan(previous.pan, frame, viewport);
      return { ...previous, pan: clampPan({ x: current.x + dx, y: current.y + dy }, frame, viewport) };
    });
  }

  function pointerEnd(event: PointerEvent<HTMLDivElement>) {
    if (drag.current?.id === event.pointerId) stopDrag();
  }

  return (
    <div className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-canvas">
      <ViewerHeader title={title} onBack={onBack} titleControl={<StreamSwitcher id={streamId} title={title} onSwitch={onSwitch} />}>
        <div role="status" className={status === 'paused' ? undefined : 'sr-only'}>
          {status === 'paused' && <Text role="label" tone="muted">{labels.paused}</Text>}
        </div>
        <IconButton icon="refresh" label="Reconnect" variant={status === 'paused' ? 'solid' : 'ghost'} disabled={status === 'loading'} onClick={() => {
          stopDrag();
          control.disable();
          setNatural(undefined);
          setView(previous => ({ ...previous, pan: centeredPan }));
          reconnect();
          setFormRefresh(value => value + 1);
        }} />
        <IconButton icon="pointer" label="Control" pressed={control.active} ref={control.toggle}
          onKeyDown={event => { if (event.key === 'Escape' && control.active) control.disable(true); }}
          disabled={status !== 'live' || !natural} onClick={event => {
            stopDrag();
            if (control.active) control.disable(true);
            else {
              const keyboardOrMouse = event.detail === 0 || (event.nativeEvent as PointerEvent['nativeEvent']).pointerType === 'mouse';
              control.enable(keyboardOrMouse);
              if (keyboardOrMouse) control.input.current?.focus({ preventScroll: true });
            }
          }} />
        <IconButton icon={mode} label={mode === 'fit-width' ? 'Fit width (current). Switch to fit height' : 'Fit height (current). Switch to fit width'} onClick={() => {
          stopDrag();
          control.release();
          setView(previous => toggleFit(previous.mode));
        }} />
      </ViewerHeader>
      <div className="relative min-h-0 flex-1 overflow-hidden">
        <div
          ref={viewportRef}
          className={`relative h-full touch-none overflow-hidden ${control.active ? 'cursor-crosshair' : canPan ? dragging ? 'cursor-grabbing' : 'cursor-grab' : ''}`}
          onPointerDown={event => control.active ? control.onPointer(event, 'down') : pointerDown(event)}
          onPointerMove={event => control.active ? control.onPointer(event, 'move') : pointerMove(event)}
          onPointerUp={event => control.active ? control.onPointer(event, 'up') : pointerEnd(event)}
          onPointerCancel={event => control.active ? control.release(event) : pointerEnd(event)}
          onLostPointerCapture={event => control.active ? control.release(event) : pointerEnd(event)}
          onContextMenu={event => { if (control.active) event.preventDefault(); }}
        >
          {image ? (
            <img
              ref={imageRef}
              className="pointer-events-none absolute left-1/2 top-1/2 block max-w-none select-none"
              src={image}
              alt="Latest image of the shared tab"
              draggable={false}
              style={{ width: frame.width, height: frame.height, transform: `translate(calc(-50% + ${offset.x}px), calc(-50% + ${offset.y}px))`, visibility: natural ? undefined : 'hidden' }}
              onLoad={({ currentTarget }) => {
                const { naturalWidth: width, naturalHeight: height } = currentTarget;
                setNatural(previous => previous?.width === width && previous.height === height ? previous : { width, height });
              }}
            />
          ) : (
            <div className="grid h-full place-items-center">
              {status === 'loading' ? <Spinner size="lg" label="Connecting" /> :
                status !== 'paused' && <Text role="body-sm" tone="muted" aria-live="polite">{labels[status]}</Text>}
            </div>
          )}
        </div>
        <textarea ref={control.input} aria-label="Shared tab input" tabIndex={control.active ? 0 : -1}
          autoComplete="off" autoCapitalize="off" spellCheck={false} className="pointer-events-none absolute left-1/2 top-1/2 h-px w-px opacity-0"
          onBlur={control.blur} onKeyDown={event => { if (control.active) control.onKey(event, 'down'); }}
          onKeyUp={event => { if (control.active) control.onKey(event, 'up'); }}
          onInput={event => { if (control.active) control.commitText(event); }}
          onCompositionStart={control.compositionStart} onCompositionEnd={control.compositionEnd}
          aria-describedby={control.active ? 'stream-control-hint' : undefined} />
        {control.active && <div id="stream-control-hint" className="pointer-events-none absolute inset-x-0 bottom-0 border-t border-subtle bg-canvas px-3 py-2 text-center">
          <Text role="body-sm" tone="muted">Control on · Esc to exit · Use secure forms for passwords</Text>
        </div>}
        {meta && !['ended', 'expired', 'unavailable', 'unauthorized'].includes(status) && (
          <StreamSecureForms streamId={streamId} reconnect={formRefresh} />
        )}
      </div>
    </div>
  );
}
