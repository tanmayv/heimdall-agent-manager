import { useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@ui';
import NewConversationPage from '../chat/NewConversationPage';
import { RecentTaskChainsTab } from './RecentTaskChainsTab';
import { RecentIssuesTab } from './RecentIssuesTab';
import { ActionItemsTab } from './ActionItemsTab';
import { useFetchTaskChainGroupsQuery } from '../../api/endpoints/tasks';
import { useListIssuesQuery } from '../../api/endpoints/issues';
import { useListCardsQuery } from '../../api/endpoints/cards';
import { useArchivedProjectIds } from '../projects/projectModel';
import { getRoutePathname, getRouteSearch, buildRouteHash } from '../../utils/appLocation';

type HomeSection = 'chains' | 'issues' | 'actions';
function routeSelection(): HomeSection | null {
  const tab = new URLSearchParams(getRouteSearch()).get('tab');
  return tab === 'chains' || tab === 'issues' || tab === 'actions' ? tab : null;
}
function scrollContainer(node: HTMLElement | null): HTMLElement | null {
  for (let parent = node?.parentElement; parent; parent = parent.parentElement) {
    if (/(auto|scroll)/.test(getComputedStyle(parent).overflowY) && parent.scrollHeight > parent.clientHeight + 1) return parent;
  }
  return document.scrollingElement as HTMLElement | null;
}

export function HomePage() {
  const [selected, setSelected] = useState<HomeSection | null>(routeSelection);
  // Keep the outgoing panel mounted during the return scroll. Removing it first
  // would clamp scrollTop and turn the requested smooth scroll into a jump.
  const [visible, setVisible] = useState<HomeSection | null>(selected);
  const rootRef = useRef<HTMLDivElement>(null);
  const buttonsRef = useRef<HTMLDivElement>(null);
  const firstRender = useRef(true);
  const chains = useFetchTaskChainGroupsQuery();
  const issues = useListIssuesQuery({ limit: 100 });
  const actions = useListCardsQuery();
  const archivedProjects = useArchivedProjectIds();
  const chainCount = useMemo(() => (chains.data?.groups || []).reduce((total, group) => {
    if (group.projectId && archivedProjects.has(group.projectId)) return total;
    return total + group.chains.filter(chain => (!chain.projectId || !archivedProjects.has(chain.projectId)) && ['active', 'completed'].includes(String(chain.status || '').toLowerCase())).length;
  }, 0), [chains.data, archivedProjects]);
  const sections = [
    { id: 'chains' as const, label: 'Recent tasks', subtitle: 'Latest task chains across projects', icon: 'tasks' as const, count: chainCount, loading: chains.isLoading, error: chains.isError },
    { id: 'issues' as const, label: 'Recent issues', subtitle: 'Reported bugs and blockers', icon: 'alert' as const, count: issues.data?.items.length || 0, loading: issues.isLoading, error: issues.isError },
    { id: 'actions' as const, label: 'Pending actions', subtitle: 'Suggestions awaiting your decision', icon: 'spark' as const, count: (actions.data?.cards || []).filter(card => card.status === 'pending').length, loading: actions.isLoading, error: actions.isError },
  ];

  useEffect(() => {
    const syncLocation = () => { const next = routeSelection(); setSelected(next); if (next) setVisible(next); };
    window.addEventListener('hashchange', syncLocation);
    window.addEventListener('popstate', syncLocation);
    return () => { window.removeEventListener('hashchange', syncLocation); window.removeEventListener('popstate', syncLocation); };
  }, []);

  useEffect(() => {
    if (firstRender.current) { firstRender.current = false; if (!selected) return; }
    let frame = 0;
    let timeout = 0;
    let container: HTMLElement | null = null;
    const finish = () => { if (!selected) setVisible(null); };
    frame = requestAnimationFrame(() => {
      if (selected) {
        const buttons = buttonsRef.current;
        const target = scrollContainer(buttons);
        if (buttons && target) {
          const top = target.scrollTop + buttons.getBoundingClientRect().top - target.getBoundingClientRect().top - 16;
          target.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
        }
        return;
      }
      container = scrollContainer(rootRef.current);
      if (!container || container.scrollTop <= 1) { finish(); return; }
      container.addEventListener('scrollend', finish, { once: true });
      container.scrollTo({ top: 0, behavior: 'smooth' });
      timeout = window.setTimeout(finish, 1000);
    });
    return () => { cancelAnimationFrame(frame); window.clearTimeout(timeout); container?.removeEventListener('scrollend', finish); };
  }, [selected]);

  function toggle(section: HomeSection) {
    const next = selected === section ? null : section;
    setSelected(next);
    if (next) setVisible(next);
    const params = new URLSearchParams(getRouteSearch());
    if (next) params.set('tab', next); else params.delete('tab');
    window.history.replaceState(window.history.state, '', buildRouteHash(getRoutePathname(), params.toString()));
  }

  return <div ref={rootRef} data-debug-id="home-page" className="w-full pb-8">
    <NewConversationPage embedded footer={<div className="relative w-full">
      <div ref={buttonsRef} data-debug-id="home-section-buttons" role="group" aria-label="Home activity" className="grid w-full scroll-mt-4 grid-cols-3 gap-2 sm:gap-3">
        {sections.map(section => <button key={section.id} type="button" data-debug-id={`home-tab-${section.id}`} aria-pressed={selected === section.id} aria-expanded={selected === section.id} aria-controls="home-activity-panel" onClick={() => toggle(section.id)} className={`relative flex min-h-28 min-w-0 flex-col items-start gap-2 rounded-2xl border px-3 py-4 text-left transition-colors sm:px-4 ${selected === section.id ? 'border-accent bg-accent/10' : 'border-subtle bg-surface hover:bg-neutral-soft'}`}>
          <div className="flex w-full items-center justify-between gap-2"><Icon name={section.icon} size={20} className={selected === section.id ? 'text-accent' : 'text-muted'} /><span data-debug-id={`home-count-${section.id}`} aria-label={section.loading ? 'Loading count' : section.error ? 'Count unavailable' : `${section.count} ${section.label.toLowerCase()}`} className={`inline-flex h-6 min-w-6 items-center justify-center rounded-full px-1.5 text-xs font-semibold ${selected === section.id ? 'bg-accent text-accent-fg' : 'bg-neutral-soft text-primary'}`}>{section.loading ? '…' : section.error ? '—' : section.count}</span></div>
          <span className="text-sm font-semibold text-primary sm:text-base">{section.label}</span>
          <span className="text-[11px] text-muted sm:text-xs">{section.subtitle}</span>
        </button>)}
      </div>
      {visible ? <section id="home-activity-panel" data-debug-id={`home-panel-${visible}`} aria-label={sections.find(section => section.id === visible)?.label} className="absolute top-full mt-5 h-[max(20rem,calc(var(--app-viewport-height)-6rem))] min-h-0 w-full overflow-hidden">
        {visible === 'chains' ? <RecentTaskChainsTab /> : visible === 'issues' ? <RecentIssuesTab /> : <ActionItemsTab />}
      </section> : null}
    </div>} />
    {visible ? <div aria-hidden="true" className="h-[max(20rem,calc(var(--app-viewport-height)-6rem))]" /> : null}
  </div>;
}
export default HomePage;
