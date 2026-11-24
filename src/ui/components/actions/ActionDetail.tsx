import React from 'react';
import { Alert, Badge, Button, Panel, Toggle } from '@ui';
import { useFetchActionQuery, useDeleteActionMutation, useSetActionEnabledMutation, type Action } from '../../api/endpoints/actions';
import { useActionCatalog, targetLabel, bridgeLabel } from './actionCatalog';
import { actionTitle, actionErrorText, actionEditHref, navigateTo, deleteConfirmBody, type ActionVerb } from './actionModel';
import { triggerSummary } from './scheduleUtils';
import RunHistory from './RunHistory';

export function usePaneIsWide(ref: React.RefObject<HTMLElement | null>) {
  const [wide, setWide] = React.useState(false);
  React.useEffect(() => { const el = ref.current; if (!el || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(([entry]) => setWide(entry.contentRect.width > 600));
    observer.observe(el); return () => observer.disconnect();
  }, [ref]); return wide;
}
export function useActionDetail(actionId: string, onAfterVerb?: (verb: ActionVerb) => void) {
  const query = useFetchActionQuery({ id: actionId }, { skip: !actionId });
  const [deleteAction] = useDeleteActionMutation();
  const [busy, setBusy] = React.useState<ActionVerb | ''>('');
  const [actionError, setError] = React.useState('');
  const record = query.data?.action || null;
  async function runVerb(verb: ActionVerb) {
    if (verb === 'edit') { navigateTo(actionEditHref(actionId)); return; }
    setBusy(verb); setError('');
    try { await deleteAction({ id: actionId }).unwrap(); onAfterVerb?.(verb); } catch (e) { setError(actionErrorText(e)); } finally { setBusy(''); }
  }
  return { query, record, busy, actionError, runNotice: '', runVerb };
}
export function CopyButton({ value, label, debugId }: { value: string; label: string; debugId: string }) {
  const [copied, setCopied] = React.useState(false);
  return <Button variant="secondary" data-debug-id={debugId} onClick={() => void navigator.clipboard.writeText(value).then(() => setCopied(true))}>{copied ? 'Copied' : label}</Button>;
}
export function ActionDetailActions({ record, busy, onVerb }: { record: Action; busy: ActionVerb | ''; onVerb: (verb: ActionVerb) => void }) {
  return <div className="flex gap-2">
    <Button variant="primary" data-debug-id="action-view-edit" onClick={() => onVerb('edit')}>Edit</Button>
    <Button variant="danger" data-debug-id="action-view-delete" disabled={Boolean(busy)} onClick={() => { if (window.confirm(deleteConfirmBody([actionTitle(record)]))) onVerb('delete'); }}>Delete</Button>
  </div>;
}
export function ActionDetailMeta({ record }: { record: Action }) { return <span>{record.enabled ? 'Enabled' : 'Disabled'} · {record.triggers.length} triggers</span>; }
export function ActionDetailHeader({ record, busy, onVerb, onBack }: { record: Action; busy: ActionVerb | ''; onVerb: (verb: ActionVerb) => void; onBack?: () => void }) {
  return <div><div className="flex justify-between gap-2"><h2>{actionTitle(record)}</h2>{onBack ? <Button data-debug-id="action-detail-back" variant="secondary" onClick={onBack}>Back</Button> : null}</div><ActionDetailMeta record={record} /><ActionDetailActions record={record} busy={busy} onVerb={onVerb} /></div>;
}
export function ActionDetailBody({ record, actionError, runNotice: _notice, wide: _wide }: { record: Action; actionError?: string; runNotice?: string; wide?: boolean }) {
  const catalog = useActionCatalog(record.target.kind === 'bot');
  const [setEnabled, enabledState] = useSetActionEnabledMutation();
  const target = record.target;
  return <div className="flex flex-col gap-4">
    {actionError ? <Alert tone="danger" title="Couldn't update action">{actionError}</Alert> : null}
    <Panel className="p-4"><h3>Prompt</h3><pre className="whitespace-pre-wrap">{record.prompt_text}</pre><CopyButton value={record.prompt_text} label="Copy prompt" debugId="action-copy-prompt" /></Panel>
    <Panel className="p-4"><h3>Triggers</h3><Toggle aria-label="Action enabled" data-debug-id="action-detail-enabled" checked={record.enabled} disabled={enabledState.isLoading} onChange={enabled => void setEnabled({ id: record.id, enabled }).unwrap().catch(() => {})} />
      {enabledState.error ? <Alert tone="danger" title="Couldn't change enabled state">{actionErrorText(enabledState.error)}</Alert> : null}
      {!record.triggers.length ? <p>No trigger</p> : record.triggers.map((t, i) => <p key={t.id || i}><Badge>{triggerSummary(t)}</Badge> · {t.enabled ? 'Enabled' : 'Disabled'}{t.next_fire_at ? ' · Next fire ' + t.next_fire_at : ''}</p>)}
    </Panel>
    <Panel className="p-4"><h3>Target</h3><p>{targetLabel(record, catalog)}</p>
      {target.kind === 'agent' ? <><p>{target.instance_strategy} · {target.project_id || 'No project'}</p>{!target.rules.length ? <p>Anywhere (the hub picks the first available machine)</p> : <ol>{target.rules.map((r, i) => <li key={i}>{i + 1}. {r.bridge_id === '*' ? 'Any machine' : bridgeLabel(r.bridge_id, catalog)} · {r.provider === '*' ? 'Any provider' : r.provider} · {r.model === '*' ? 'Any model' : r.model}</li>)}</ol>}</> : null}
      <p>An action also starts an agent that you stopped. Disable the action to stop that.</p>
    </Panel>
    <Panel className="p-4"><h3>Runs</h3><RunHistory key={record.id} actionId={record.id} catalog={catalog} /></Panel>
  </div>;
}
export function ActionDetailMobileActions(_props: { record: Action; onVerb: (verb: ActionVerb) => void }) { return null; }
export function ActionDetailPaneSkeleton() { return <div role="status">Loading action…</div>; }
export { actionTitle };
