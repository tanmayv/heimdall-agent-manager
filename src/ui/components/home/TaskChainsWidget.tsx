import { useState } from 'react';
import { Button, ButtonLink, IconButton, Link, StatusDot, StatusPill, Text } from '@ui';
import { useFetchHomeTaskChainsQuery, useFetchTaskChainDetailQuery, type ChainListItem } from '../../api/endpoints/tasks';
import { useGetHomeFleetQuery } from '../../api/endpoints/home';
import { chainConversationRoute, coordinatorFromChainDetail } from '../../utils/chainConversation';
import { buildRouteHash } from '../../utils/appLocation';
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
  // Only the visible page mounts these shared subscriptions. Task WS events patch
  // this same detail cache; chain changes invalidate it through existing tags.
  const detail = useFetchTaskChainDetailQuery({ chainId: chain.chainId });
  const record = detail.currentData?.chain;
  const unavailable = detail.isError || (detail.isSuccess && (!detail.currentData?.hasCompleteSnapshot || record?.chainId !== chain.chainId));
  const counts = record && !unavailable ? chainProgress(record.tasks) : null;
  const review = chain.hasUserValidation;
  const coordinatorId = record ? coordinatorFromChainDetail(record) : chain.coordinatorAgentInstanceId;
  const coordinator = record?.members?.find((member: { agentInstanceId: string }) => member.agentInstanceId === coordinatorId);
  const bridges = useGetHomeFleetQuery(undefined, { skip: !coordinator?.bridgeId || Boolean(coordinator?.bridgeLabel) });
  const bridge = coordinator?.bridgeLabel || bridges.currentData?.find((item) => item.id === coordinator?.bridgeId)?.label;
  const chainHref = buildRouteHash(`/chains/${encodeURIComponent(chain.chainId)}`, '');
  // A failed lookup is not evidence of an absent coordinator. Keep the chain
  // conversation destination until a successful detail proves there is none.
  const href = record && !unavailable && !coordinatorId ? chainHref : buildRouteHash(chainConversationRoute(chain.chainId), '');
  return <article className="home-chain-card">
    <div className="home-row home-chain-title-row"><Link href={href} tone="muted" variant="standalone" className="home-chain-title" data-debug-id={`home-chain-open-${chain.chainId}`}><Text role="title"><VaultText value={chain.title} fallback="Task chain" /></Text></Link>
      <StatusPill tone={review ? 'warning' : 'info'}><StatusDot size="sm" tone={review ? 'warning' : 'info'} label={review ? 'Needs review' : 'Running'} />{review ? 'Needs review' : 'Running'}</StatusPill><Text role="caption" tone="muted">{updatedLabel(chain.updatedAt)}</Text>
    </div>
    <div className="home-chain-meta"><Text role="body-sm" tone="muted"><VaultText value={chain.projectName} fallback="No project" /></Text>{coordinator?.displayName && <Text role="code-sm" tone="muted"><VaultText value={coordinator.displayName} fallback="Coordinator" />{bridge && <>@<VaultText value={bridge} fallback="Bridge" /></>}</Text>}</div>
    {counts ? <div className="home-chain-progress-row"><ChainProgressBar counts={counts} /><Text role="caption" tone="muted">{counts.done} of {counts.total} tickets done</Text></div>
      : <div role="status"><Text role="caption" tone="muted">{unavailable ? 'Ticket progress and coordinator unavailable' : 'Loading ticket progress…'}</Text>{unavailable && <>
        <Button variant="ghost" size="sm" disabled={detail.isFetching} data-debug-id={`home-chain-retry-${chain.chainId}`} onClick={() => { void detail.refetch(); }}>Retry</Button>
        <Link href={chainHref} data-debug-id={`home-chain-details-${chain.chainId}`}>Chain details</Link>
      </>}</div>}
  </article>;
}
export function TaskChainsWidget({ resource: supplied, onRetry }: { resource?: WidgetResource<ChainListItem[]>; onRetry?: () => void } = {}) {
  const [pageIndex, setPageIndex] = useState(0);
  const query = useFetchHomeTaskChainsQuery(undefined, { skip: Boolean(supplied) });
  const resource: WidgetResource<ChainListItem[]> = supplied || (query.isError ? { status: 'error', message: 'Unable to load task chains' } : query.currentData ? { status: 'ready', data: query.currentData.chains } : { status: 'loading' });
  const chains = resource.status === 'ready' ? activeWidgetChains(resource.data) : [];
  const total = chains.length;
  const page = chainWidgetPage(chains, pageIndex);
  // Clamp during render so a shrinking snapshot never mounts an empty/stale page.
  if (resource.status === 'ready' && page.index !== pageIndex) setPageIndex(page.index);
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
