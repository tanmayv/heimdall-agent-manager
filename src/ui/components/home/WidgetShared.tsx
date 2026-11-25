import { useEffect, useState, type ReactNode } from 'react';
import { Button, Text } from '@ui';
import type { WidgetLoader, WidgetResource } from './widgetData';

export function useWidgetData<T>(loader: WidgetLoader<T>, supplied?: WidgetResource<T>) {
  const [resource, setResource] = useState<WidgetResource<T>>({ status: 'loading' });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (supplied) return;
    const controller = new AbortController();
    setResource({ status: 'loading' });
    Promise.resolve().then(() => loader(controller.signal)).then(
      (data) => { if (!controller.signal.aborted) setResource({ status: 'ready', data }); },
      (error) => { if (!controller.signal.aborted) setResource({ status: 'error', message: error instanceof Error ? error.message : 'Unable to load widget' }); },
    );
    return () => controller.abort();
  }, [loader, supplied, attempt]);
  return { resource: supplied || resource, retry: () => setAttempt((value) => value + 1) };
}

export function WidgetState({ status, name, message, onRetry }: { status: 'loading' | 'error'; name: string; message?: string; onRetry?: () => void }) {
  return <div className="home-widget-state" role={status === 'error' ? 'alert' : 'status'} aria-busy={status === 'loading'}>
    <Text role="body-sm" tone={status === 'error' ? 'danger' : 'muted'}>{status === 'loading' ? `Loading ${name.toLowerCase()}…` : message || `Unable to load ${name.toLowerCase()}`}</Text>
    {status === 'error' && onRetry && <Button variant="secondary" size="sm" data-debug-id={`home-${name.toLowerCase().replace(/ /g, '-')}-retry`} onClick={onRetry}>Try again</Button>}
  </div>;
}

export function WidgetHeading({ id, title, children }: { id: string; title: string; children?: ReactNode }) {
  return <header className="home-widget-heading"><Text as="h2" id={id} role="heading">{title}</Text><div className="home-widget-heading-actions">{children}</div></header>;
}

export function WidgetStat({ label, value, detail }: { label: string; value: ReactNode; detail?: string }) {
  return <div className="home-widget-stat"><Text role="label" tone="muted">{label}</Text><Text role="heading" className="home-stat-value">{value}</Text>{detail && <Text role="caption" tone="muted">{detail}</Text>}</div>;
}
export function Legend({ items }: { items: { label: string; tone: string }[] }) {
  return <div className="home-legend">{items.map((item) => <Text role="caption" tone="muted" key={item.label}><i aria-hidden="true" style={{ background: `var(--color-${item.tone})` }} />{item.label}</Text>)}</div>;
}
