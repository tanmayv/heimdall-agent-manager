import React from 'react';
import { bridgeLabel, type ActionCatalog } from './actionCatalog';
import { Alert, Badge, Button } from '@ui';
import { useLazyActionRunsQuery, type ActionRun } from '../../api/endpoints/actions';
import { buildConversationHash } from '../../utils/conversationUrl';
export const RUN_REASON_TEXT: Record<string, string> = {
  bridge_offline: 'The machine stayed offline', no_answer: 'The machine did not answer',
  start_failed: 'The agent could not be started on that machine', bridge_too_old: "The machine's bridge needs an update",
  no_placement: 'No machine matched the rules', target_missing: 'The target no longer exists',
  delivery_failed: 'The prompt could not be stored', experiment_off: 'Actions experiment is off',
  disabled: 'Action is disabled', rate_limited: 'Minimum interval has not elapsed',
  stale_rev: 'Trigger has changed', outside_window: 'Outside the active window', blackout: 'Blackout date',
};
export function runRowText(run: ActionRun, machine = 'machine') {
  const text = run.state === 'queued' ? 'Waiting'
    : run.state === 'deferred' ? 'Deferred until ' + run.not_before
    : run.state === 'routed' ? 'Sent to ' + machine + ', waiting for it' + (run.delivery_expires_at ? ' · expires ' + run.delivery_expires_at : '')
    : run.state === 'delivered' ? 'Delivered'
    : run.state === 'joined' ? 'Merged into ' + run.joined_run_id.slice(0, 12)
    : RUN_REASON_TEXT[run.reason] || run.reason || run.state;
  return text + (run.joined_count > 0 ? ' · +' + run.joined_count + ' merged' : '');
}
export default function RunHistory({ actionId, catalog }: { actionId: string; catalog: ActionCatalog }) {
  const [fetchRuns, query] = useLazyActionRunsQuery();
  const [rows, setRows] = React.useState<ActionRun[]>([]);
  const [more, setMore] = React.useState(false);
  const generation = React.useRef(0);
  React.useEffect(() => {
    const current = ++generation.current;
    setRows([]); setMore(false);
    const request = fetchRuns({ id: actionId, limit: 50 });
    request.unwrap().then(page => { if (current === generation.current) { setRows(page); setMore(page.length === 50); } }).catch(() => {});
    return () => { generation.current++; request.abort(); };
  }, [actionId, fetchRuns]);
  async function loadMore() {
    const current = generation.current;
    try {
      const page = await fetchRuns({ id: actionId, limit: 50, before: rows[rows.length - 1]?.created_at }).unwrap();
      if (current !== generation.current) return;
      setRows(prev => [...prev, ...page.filter(row => !prev.some(p => p.id === row.id))]); setMore(page.length === 50);
    } catch { /* query renders the error */ }
  }
  return <div className="flex flex-col gap-3">
    {query.error ? <Alert tone="danger" title="Couldn't load run history" /> : null}
    {query.isFetching ? <p role="status">Loading runs…</p> : null}
    {!query.isFetching && !rows.length && !query.error ? <p>No runs yet.</p> : null}
    {rows.map(run => <div key={run.id} data-debug-id={'action-run-' + run.id} className="border-b border-subtle py-2">
      <time dateTime={run.created_at}>{run.created_at}</time> · {run.trigger_id} · {run.event_type} <Badge>{run.state}</Badge>
      <p>{runRowText(run, bridgeLabel(catalog.instances.byId.get(run.target_instance_id)?.bridgeId, catalog) || run.target_instance_id || 'machine')}</p>
      {run.target_instance_id ? <a data-debug-id={'action-run-instance-' + run.id} href={buildConversationHash([run.target_instance_id])}>Open instance</a> : null}
    </div>)}
    {more ? <Button variant="secondary" data-debug-id="action-runs-more" disabled={query.isFetching} onClick={() => void loadMore()}>Load more</Button> : null}
  </div>;
}
