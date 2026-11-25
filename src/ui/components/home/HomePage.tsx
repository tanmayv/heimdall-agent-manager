import { useState } from 'react';
import { Button, ButtonLink, Icon, Text } from '@ui';
import NewConversationPage from '../chat/NewConversationPage';
import type { LauncherIntent } from '../../store/workspaceLayoutSlice';
import ActivityWidget from './ActivityWidget';
import TaskChainsWidget from './TaskChainsWidget';
import UptimeWidget from './UptimeWidget';
import FleetWidget from './FleetWidget';
import './HomePage.css';

export interface HomePageProps {
  /** The new-chat workspace pane keeps its embedded composer. */
  pane?: { onOpenAgent: (agentInstanceId: string) => void; launchIntent?: LauncherIntent };
}
export function HomeHeader({ editing, onEdit, today = new Date() }: { editing: boolean; onEdit: () => void; today?: Date }) {
  return <header className="home-header">
    <div><Text role="overline" tone="muted">{today.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'short' })}</Text><Text as="h1" role="display">Here’s where the fleet stands</Text></div>
    <div className="home-header-actions">
      <Button variant="ghost" leading={<Icon name="pencil" size="sm" />} aria-pressed={editing} data-debug-id="home-layout-edit" onClick={onEdit}>{editing ? 'Done' : 'Edit'}</Button>
      <ButtonLink href="#/new?intent=shell" variant="secondary" leading={<Icon name="terminal" size="sm" />} data-debug-id="home-new-shell">New shell</ButtonLink>
      <ButtonLink href="#/new?intent=agent" variant="primary" leading={<Icon name="plus" size="sm" />} data-debug-id="home-new-conversation">New conversation</ButtonLink>
    </div>
  </header>;
}
export function HomePage({ pane }: HomePageProps = {}) {
  const [editing, setEditing] = useState(false);
  if (pane) return <div data-debug-id="home-page-pane" className="h-full w-full min-h-0 overflow-y-auto pb-8 max-md:flex max-md:flex-col max-md:pb-0">
    <NewConversationPage embedded launchIntent={pane.launchIntent} onLaunched={pane.onOpenAgent} />
  </div>;

  return <div data-debug-id="home-page" className="home-dashboard" data-home-editing={editing}>
    <HomeHeader editing={editing} onEdit={() => setEditing((value) => !value)} />
    <div className="home-widget-grid"><ActivityWidget /><TaskChainsWidget /><UptimeWidget /><FleetWidget /></div>
  </div>;
}
export default HomePage;
