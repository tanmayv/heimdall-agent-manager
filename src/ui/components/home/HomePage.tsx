import React, { useEffect, useState } from 'react';
import { Icon, PageShell, Tab, Tabs, TabsList, TabsPanel } from '@ui';
import { useViewport, useIsMobile } from '../shell/responsive';
import { getRoutePathname, getRouteSearch, buildRouteHash } from '../../utils/appLocation';
import { RecentTaskChainsTab } from './RecentTaskChainsTab';
import { RecentIssuesTab } from './RecentIssuesTab';
import { ActionItemsTab } from './ActionItemsTab';

function getInitialTab(): string {
  const search = getRouteSearch();
  if (!search) return 'chains';
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = params.get('tab');
  if (tab === 'issues' || tab === 'actions') return tab;
  return 'chains';
}

export function HomePage() {
  const viewport = useViewport();
  const isMobile = useIsMobile();
  const [activeTab, setActiveTab] = useState<string>(getInitialTab);

  // Sync state when URL hash changes externally
  useEffect(() => {
    const onLocationChange = () => {
      setActiveTab(getInitialTab());
    };
    window.addEventListener('hashchange', onLocationChange);
    window.addEventListener('popstate', onLocationChange);
    return () => {
      window.removeEventListener('hashchange', onLocationChange);
      window.removeEventListener('popstate', onLocationChange);
    };
  }, []);

  // Update URL search parameter when tab changes
  const handleTabChange = (newTab: string) => {
    setActiveTab(newTab);
    const currentPath = getRoutePathname();
    const search = getRouteSearch();
    const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
    if (newTab === 'chains') {
      params.delete('tab');
    } else {
      params.set('tab', newTab);
    }
    const searchStr = params.toString() ? `?${params.toString()}` : '';
    const newHash = buildRouteHash(currentPath, searchStr);
    window.history.replaceState(window.history.state, '', newHash);
  };

  return (
    <PageShell
      width="full"
      rhythm="banded"
      title="Home"
      breadcrumbs={[{ label: 'Home' }]}
      description="Recent task chains, issues, and action items across your projects."
      className="h-full min-h-0 w-full overflow-hidden flex flex-col"
      data-debug-id="home-page"
    >
      <Tabs
        value={activeTab}
        onChange={handleTabChange}
        variant="underline"
        className="flex flex-col h-full min-h-0 w-full overflow-hidden"
      >
        {/* Horizontally scrollable TabsList for clean mobile navigation */}
        <div className="overflow-x-auto overscroll-x-contain pb-2 shrink-0 [-webkit-overflow-scrolling:touch]">
          <TabsList label="Home sections" className="flex-nowrap whitespace-nowrap min-w-max border-b border-subtle gap-2">
            <Tab
              value="chains"
              data-debug-id="home-tab-chains"
              className="flex items-center gap-2 min-h-[44px] sm:min-h-[38px] px-3.5"
            >
              <Icon name="tasks" size="sm" />
              <span>Recent Task chains</span>
            </Tab>
            <Tab
              value="issues"
              data-debug-id="home-tab-issues"
              className="flex items-center gap-2 min-h-[44px] sm:min-h-[38px] px-3.5"
            >
              <Icon name="alert" size="sm" />
              <span>Recent Issues</span>
            </Tab>
            <Tab
              value="actions"
              data-debug-id="home-tab-actions"
              className="flex items-center gap-2 min-h-[44px] sm:min-h-[38px] px-3.5"
            >
              <Icon name="spark" size="sm" />
              <span>Action Items</span>
            </Tab>
          </TabsList>
        </div>

        {/* Tab 1: Recent Task Chains */}
        <TabsPanel
          value="chains"
          className="flex-1 min-h-0 h-full overflow-hidden flex flex-col pt-3"
        >
          <RecentTaskChainsTab />
        </TabsPanel>

        {/* Tab 2: Recent Issues */}
        <TabsPanel
          value="issues"
          className="flex-1 min-h-0 h-full overflow-hidden flex flex-col pt-3"
        >
          <RecentIssuesTab />
        </TabsPanel>

        {/* Tab 3: Action Items */}
        <TabsPanel
          value="actions"
          className="flex-1 min-h-0 h-full overflow-hidden flex flex-col pt-3"
        >
          <ActionItemsTab />
        </TabsPanel>
      </Tabs>
    </PageShell>
  );
}

export default HomePage;
