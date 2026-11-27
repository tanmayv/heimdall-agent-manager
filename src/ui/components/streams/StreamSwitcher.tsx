import { useEffect, useRef, useState } from 'react';
import { Icon, Menu } from '@ui';
import { listOtherStreams, type ActiveStream } from './useStreamViewer.ts';

export function StreamSwitcher({ id, title, onSwitch }: { id: string; title: string; onSwitch: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  const [streams, setStreams] = useState<ActiveStream[] | 'error'>();
  const first = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (open && Array.isArray(streams) && document.activeElement === trigger.current) {
      first.current?.closest('button')?.focus();
    }
  }, [open, streams]);
  useEffect(() => {
    if (!open) return;
    const controller = new AbortController();
    const { signal } = controller;
    void listOtherStreams(id, signal).then(
      rows => { if (!signal.aborted) setStreams(rows); },
      () => { if (!signal.aborted) setStreams('error'); },
    );
    return () => controller.abort();
  }, [id, open]);

  return (
    <Menu label="Switch stream" open={open} onOpenChange={next => {
      if (next) setStreams(undefined);
      setOpen(next);
    }} className="max-h-64 w-56 max-w-[calc(100vw-4rem)] overflow-y-auto"
      trigger={<button type="button" ref={trigger} onKeyDown={event => {
        if (event.key === 'Escape' && open) {
          event.preventDefault();
          setOpen(false);
        }
        if (event.key === 'ArrowDown') {
          event.preventDefault();
          if (open) first.current?.closest('button')?.focus();
          else {
            setStreams(undefined);
            setOpen(true);
          }
        }
      }} title={title} aria-label={`${title}, switch stream`}
        className="flex h-11 w-full min-w-0 items-center gap-1 rounded-[var(--radius-md)] text-left font-semibold text-primary hover:text-accent focus-visible:outline-none focus-visible:shadow-focus">
        <span className="min-w-0 truncate">{title}</span><Icon name="chevron-down" className="shrink-0" />
      </button>}>
      <Menu.Label>Active streams</Menu.Label>
      {Array.isArray(streams) && streams.length ? streams.map((row, index) =>
        <Menu.Item key={row.stream_id} onClick={() => onSwitch(row.stream_id)}>
          <span ref={index === 0 ? first : undefined} className="block truncate">{row.title || 'Shared tab'}</span>
        </Menu.Item>) : <Menu.Item disabled>
        <span role="status">{streams === undefined ? 'Loading streams…' : streams === 'error' ? 'Could not load streams' : 'No other active streams'}</span>
      </Menu.Item>}
    </Menu>
  );
}
