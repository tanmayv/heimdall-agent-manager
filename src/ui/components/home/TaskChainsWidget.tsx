import { useEffect, useState } from 'react';
import { ButtonLink, IconButton, Link, StatusDot, StatusPill, Text } from '@ui';
import type { ChainListItem } from '../../api/endpoints/tasks';
import { useGetHomeTaskChainsQuery, useGetHomeChainDetailQuery } from '../../api/endpoints/home';
import { VaultText } from '../vault/VaultText';
import { activeWidgetChains, chainProgress, chainWidgetPage, type ChainProgress, type WidgetResource } from './widgetData';
import { Legend, WidgetHeading, WidgetState } from './WidgetShared';

export function ChainProgressBar({ counts }: { counts: ChainProgress }) {
  return <div className="home-chain-progress" role="img" aria-label={`${counts.done} of ${counts.total} tickets done, ${counts.review} in review, ${counts.progress} in progress`}>
    {(['done', 'review', 'progress'] as const).map((state) => <span key={state} className={`home-chain-segment home-chain-${state === 'progress' ? 'in-progress' : state}`} style={{ width: `${counts.total ? counts[state] / counts.total * 100 : 0}%` }} />)}
  </div>;
}
function updatedLabel(value: string) {
  const minutes = Math.floor((Date.now() - Date.parse(value)) / 60000);
  if (!Number.isFinite(minutes)) return '';
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  if (minutes < 1440) return `${Math.floor(minutes / 60)}h ago`;
  return `${Math.floor(minutes / 1440)}d ago`;
}
function TaskChainCard({ chain }: { chain: ChainListItem }) {
  const detail = useGetHomeChainDetailQuery(chain.chainId);
  const counts = detail.data ? chainProgress(detail.data.tasks || []) : null;
  const review = chain.hasUserValidation || chain.status === 'needs_review' || chain.status === 'in_review';
  const coordinator = detail.data?.members?.find((member: { role: string }) => member.role === 'coordinator');
  return <article className="home-chain-card">
    <div className="home-row home-chain-title-row"><Link href={`#/chains/${encodeURIComponent(chain.chainId)}`} tone="muted" variant="standalone" className="home-chain-title" data-debug-id={`home-chain-open-${chain.chainId}`}><Text role="title"><VaultText value={chain.title} fallback="Task chain" /></Text></Link>
      <StatusPill tone={review ? 'warning' : 'info'}><StatusDot size="sm" tone={review ? 'warning' : 'info'} label={review ? 'Needs review' : 'Running'} />{review ? 'Needs review' : 'Running'}</StatusPill><Text role="caption" tone="muted">{updatedLabel(chain.updatedAt)}</Text>
    </div>
    <div className="home-chain-meta"><Text role="body-sm" tone="muted">{chain.projectName || 'No project'}</Text>{coordinator?.display_name && <Text role="code-sm" tone="muted">{coordinator.display_name}@{coordinator.bridge_label || 'bridge'}</Text>}</div>
    {counts ? <div className="home-chain-progress-row"><ChainProgressBar counts={counts} /><Text role="caption" tone="muted">{counts.done} of {counts.total} tickets done</Text></div>
      : <Text role="caption" tone="muted">{detail.isError ? 'Ticket progress unavailable' : 'Loading ticket progress…'}</Text>}
  </article>;
}
export function TaskChainsWidget({ resource: supplied, onRetry }: { resource?: WidgetResource<ChainListItem[]>; onRetry?: () => void } = {}) {
  const [pageIndex, setPageIndex] = useState(0);
  const query = useGetHomeTaskChainsQuery({ page: pageIndex }, { skip: Boolean(supplied) });
  const resource: WidgetResource<ChainListItem[]> = supplied || (query.isError ? { status: 'error', message: 'Unable to load task chains' } : query.data ? { status: 'ready', data: query.data.chains.map((chain) => ({ chainId: chain.chain_id, title: chain.title, status: chain.status, projectName: chain.project_name, updatedAt: chain.updated_at, hasUserValidation: Boolean(chain.user_validation_count) } as ChainListItem)) } : { status: 'loading' });
  const chains = resource.status === 'ready' ? activeWidgetChains(resource.data) : [];
  const total = supplied ? chains.length : query.data?.total || 0;
  const page = supplied ? chainWidgetPage(chains, pageIndex) : { index: pageIndex, rows: chains, start: total ? pageIndex * 3 + 1 : 0, end: Math.min(pageIndex * 3 + chains.length, total) };
  useEffect(() => { if (total && pageIndex * 3 >= total) setPageIndex(Math.ceil(total / 3) - 1); }, [total, pageIndex]);
  return <section data-debug-id="home-widget-chains" className="home-chains" aria-labelledby="home-chains-title">
    <WidgetHeading id="home-chains-title" title="Task chains"><Text role="body-sm" tone="muted">{total ? `${total} active` : 'None running'}</Text><Link variant="standalone" href="#/chains" data-debug-id="home-chains-all">All chains</Link></WidgetHeading>
    <div className="home-card">
      {resource.status !== 'ready' ? <WidgetState status={resource.status} name="Task chains" message={resource.status === 'error' ? resource.message : undefined} onRetry={onRetry || (() => { void query.refetch(); })} />
        : !chains.length ? <div className="home-widget-state"><Text role="body-sm" tone="muted">No active task chains</Text><Text role="body-sm" tone="muted">Nothing is running right now. Start a conversation and its chain will show up here.</Text><ButtonLink href="#/new" variant="secondary" data-debug-id="home-chains-new-conversation">New conversation</ButtonLink></div>
        : <>{page.rows.map((chain) => <TaskChainCard key={chain.chainId} chain={chain} />)}
          <footer className="home-widget-footer"><Legend items={[{ label: 'Done', tone: 'success' }, { label: 'In review', tone: 'warning' }, { label: 'In progress', tone: 'info' }]} />{total > 3 && <div className="home-chain-pagination"><Text role="caption" tone="muted" aria-live="polite">{page.start === page.end ? page.start : `${page.start}–${page.end}`} of {total}</Text>
            <IconButton icon="chevron-left" label="Previous task chains" size="sm" disabled={page.index === 0} data-debug-id="home-chains-previous" onClick={() => setPageIndex(page.index - 1)} />
            <IconButton icon="chevron-right" label="Next task chains" size="sm" disabled={page.end >= total} data-debug-id="home-chains-next" onClick={() => setPageIndex(page.index + 1)} />
          </div>}</footer></>}
    </div>
  </section>;
}
export default TaskChainsWidget;
