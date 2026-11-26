import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { Button, ButtonLink, Drawer, Icon, Menu, Text } from '@ui';
import NewConversationPage from '../chat/NewConversationPage';
import { useAuthUser } from '../auth/AuthUserContext';
import type { LauncherIntent } from '../../store/workspaceLayoutSlice';
import ActivityWidget from './ActivityWidget';
import TaskChainsWidget from './TaskChainsWidget';
import UptimeWidget from './UptimeWidget';
import FleetWidget from './FleetWidget';
import { getRouteSearch } from '../../utils/appLocation';
import { HOME_WIDGETS, visibleHomeWidgets, moveHomeWidget, packHomeRows, setWidgetHidden, type HomeLayoutAdapter, type HomeWidgetId } from './homeLayout';
import { useHomeLayout } from './useHomeLayout';
import { WidgetLayoutContext } from './WidgetLayoutChrome';
import './HomePage.css';

export interface HomePageProps {
  /** The new-chat workspace pane keeps its embedded composer. */
  pane?: { onOpenAgent: (agentInstanceId: string) => void; launchIntent?: LauncherIntent };
}
export function HomeHeader({ editing, onEdit, addWidget, busy, today = new Date() }: {
  editing: boolean; onEdit: () => void; addWidget?: ReactNode; busy?: boolean; today?: Date;
}) {
  return <header className="home-header">
    <div><Text role="overline" tone="muted">{today.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'short' })}</Text><Text as="h1" role="display">Here’s where the fleet stands</Text></div>
    <div className="home-header-actions">
      <div className="home-edit-actions">
        {editing && addWidget}
        <Button variant={editing ? 'secondary' : 'ghost'} leading={!editing ? <Icon name="pencil" size="sm" /> : undefined} disabled={busy} aria-pressed={editing} data-debug-id="home-layout-edit" onClick={onEdit}>{editing ? 'Done' : 'Edit'}</Button>
      </div>
      <ButtonLink href="#/new?intent=shell" variant="secondary" leading={<Icon name="terminal" size="sm" />} data-debug-id="home-new-shell">New shell</ButtonLink>
      <ButtonLink href="#/new?intent=agent" variant="primary" leading={<Icon name="plus" size="sm" />} data-debug-id="home-new-conversation">New conversation</ButtonLink>
    </div>
  </header>;
}
const widgetContent: Record<HomeWidgetId, ReactNode> = {
  activity: <ActivityWidget />, chains: <TaskChainsWidget />, uptime: <UptimeWidget />, fleet: <FleetWidget />,
};
function useMobileHome() {
  const [mobile, setMobile] = useState(() => window.matchMedia('(max-width: 767px)').matches);
  useEffect(() => {
    const query = window.matchMedia('(max-width: 767px)');
    const update = () => setMobile(query.matches);
    update(); query.addEventListener('change', update);
    return () => query.removeEventListener('change', update);
  }, []);
  return mobile;
}
/** Exported to let visual fixtures exercise the real layout with independent widget states. */
export function HomeDashboard({ userId, adapter, widgets = widgetContent }: {
  userId: string; adapter?: HomeLayoutAdapter; widgets?: Partial<Record<HomeWidgetId, ReactNode>>;
}) {
  const [editing, setEditing] = useState(false);
  const mobile = useMobileHome();
  const { layout, status, error, canEdit, edit, reload } = useHomeLayout(userId, adapter);
  const [dragging, setDragging] = useState<HomeWidgetId | null>(null);
  const [target, setTarget] = useState<HomeWidgetId | null>(null);
  const dragSource = useRef<HomeWidgetId | null>(null);
  const [announcement, announce] = useState('');
  const [addOpen, setAddOpen] = useState(false);
  const addTriggerRef = useRef<HTMLButtonElement>(null);
  const reorderFocus = useRef<HTMLButtonElement | null>(null);
  const definitions = HOME_WIDGETS.filter((item) => !mobile || item.id !== 'activity');
  // Recovery links must work even when Fleet was removed from the saved layout.
  // Reveal it for this route without rewriting the user's layout preference.
  const requestedFleet = new URLSearchParams(getRouteSearch()).get('widget') === 'fleet';
  const visible = visibleHomeWidgets(requestedFleet ? setWidgetHidden(layout, 'fleet', false) : layout, mobile);
  const hidden = definitions.filter((definition) => layout.widgets.find((item) => item.id === definition.id)?.hidden);
  const endDrag = () => { dragSource.current = null; setDragging(null); setTarget(null); };
  useEffect(() => { endDrag(); setAddOpen(false); }, [editing, mobile]);
  useEffect(() => { if (!canEdit) setEditing(false); }, [canEdit]);
  useEffect(() => {
    if (!addOpen || !mobile) return;
    const button = addTriggerRef.current;
    return () => queueMicrotask(() => {
      if (!button?.isConnected) document.querySelector<HTMLButtonElement>('[data-debug-id="home-layout-edit"]')?.focus({ preventScroll: true });
    });
  }, [addOpen, mobile]);
  useLayoutEffect(() => {
    const button = reorderFocus.current;
    reorderFocus.current = null;
    if (!button?.isConnected) return;
    // The last step disables the activated arrow. Keep focus on its enabled sibling.
    const next = button.disabled ? button.parentElement?.querySelector<HTMLButtonElement>('button:not(:disabled)') : button;
    next?.focus({ preventScroll: true });
  }, [layout]);
  const move = (id: HomeWidgetId, to: HomeWidgetId) => {
    if (mobile && document.activeElement?.tagName === 'BUTTON') reorderFocus.current = document.activeElement as HTMLButtonElement;
    edit((value) => moveHomeWidget(value, id, to, mobile));
    announce(`${HOME_WIDGETS.find((item) => item.id === id)!.name} moved to position ${visible.findIndex((item) => item.id === to) + 1} of ${visible.length}.`);
  };
  const addRows = definitions.map((item) => <Menu.CheckboxItem key={item.id} keepOpen={mobile} checked={!layout.widgets.find((widget) => widget.id === item.id)?.hidden}
      description={item.description} data-debug-id={`home-layout-toggle-${item.id}`}
      onClick={() => edit((value) => setWidgetHidden(value, item.id, !value.widgets.find((widget) => widget.id === item.id)!.hidden))}>
      {item.name}
    </Menu.CheckboxItem>);
  const addTrigger = <Button ref={addTriggerRef} variant="ghost" leading={<Icon name="grid" size="sm" />} data-debug-id="home-layout-add-menu"
    aria-haspopup={mobile ? 'dialog' : 'menu'} aria-expanded={addOpen} onClick={() => setAddOpen((value) => !value)}>Add widget</Button>;
  const addMenu = mobile ? <>
    {addTrigger}
    <Drawer open={addOpen} onOpenChange={setAddOpen} side="bottom" variant="sheet" title="Home widgets"
      hideHeader aria-label="Home widgets" autoFocus={false} returnFocusRef={addTriggerRef} data-debug-id="home-layout-add-sheet">
      <Menu.Panel key={String(addOpen)} label="Home widgets" onClose={() => setAddOpen(false)} variant="sheet" autoFocus={addOpen}
        data-debug-id="home-layout-add-options" className="home-add-sheet-options px-2 pb-4 pt-1">
        {addRows}
      </Menu.Panel>
    </Drawer>
  </> : <Menu align="end" label="Home widgets" open={addOpen} onOpenChange={setAddOpen}
    className="home-layout-menu home-add-menu" trigger={addTrigger}>{addRows}</Menu>;
  const packed = packHomeRows<{ id: HomeWidgetId | 'add'; width: 1 | 2 }>([
    ...visible, ...(editing ? [{ id: 'add' as const, width: 1 as const }] : []),
  ]);
  return <div data-debug-id="home-page" className="home-dashboard" data-home-editing={editing}>
    <HomeHeader editing={editing} busy={!canEdit} addWidget={addMenu} onEdit={() => setEditing((value) => !value)} />
    {(status === 'conflict' || status === 'error') && <div className="home-layout-feedback" role="alert" data-debug-id="home-layout-error">
      <Text role="body-sm">{status === 'conflict' ? 'Your layout changed elsewhere. Your last saved layout has been restored.' : error}</Text>
      <Button variant="secondary" size="sm" data-debug-id="home-layout-reload" onClick={reload}>Reload saved layout</Button>
    </div>}
    <span className="sr-only" aria-live="polite" data-debug-id="home-layout-announcement">{announcement}</span>
    {!visible.length && <div className="home-widget-state home-layout-empty" data-debug-id="home-layout-empty">
      <Text role="heading">No widgets on your home page</Text>
      <Button variant="secondary" data-debug-id="home-layout-add-all" onClick={() => edit((value) => ({ ...value, widgets: value.widgets.map((item) => ({ ...item, hidden: false })) }))}>Add all widgets</Button>
    </div>}
    <div className="home-widget-grid" aria-busy={status === 'loading'}>
      {packed.map(({ item, span }) => {
        if (item.id === 'add') return <div key="add" className="home-add-tile" style={{ gridColumn: `span ${mobile ? 1 : span}` }} data-debug-id="home-layout-add-tile">
          <Text role="heading">Add a widget</Text><Text role="body-sm" tone="muted">Put a removed widget back on your home page.</Text>
          <div className="home-add-tile-buttons">{hidden.map((definition) =>
            <Button key={definition.id} variant="secondary" size="sm" leading={<Icon name="plus" size="sm" />} data-debug-id={`home-layout-add-${definition.id}`} onClick={() => edit((value) => setWidgetHidden(value, definition.id, false))}>{definition.name}</Button>)}</div>
        </div>;
        const id = item.id;
        const widget = visible.find((value) => value.id === id)!;
        const index = visible.indexOf(widget);
        return <div key={id} className={`home-widget-slot home-slot-${id}${dragging === id ? ' is-dragging' : ''}${target === id ? ' is-drop-target' : ''}`}
          style={{ gridColumn: `span ${span}` }} data-debug-id={`home-layout-slot-${id}`} data-stored-width={widget.width}
          onDragOver={(event) => {
            if (!editing || !dragSource.current || dragSource.current === id) return;
            event.preventDefault(); event.dataTransfer.dropEffect = 'move'; setTarget(id);
          }}
          onDragLeave={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node)) setTarget(null); }}
          onDrop={(event) => {
            const source = dragSource.current;
            if (!editing || !source) return;
            event.preventDefault();
            if (source !== id) move(source, id);
            endDrag();
          }}>
          <WidgetLayoutContext.Provider value={editing ? {
            widget, mobile, edit,
            earlier: index > 0 ? () => move(id, visible[index - 1].id) : undefined,
            later: index < visible.length - 1 ? () => move(id, visible[index + 1].id) : undefined,
            onDragStart: (event) => {
              dragSource.current = id; setDragging(id); setTarget(null);
              event.dataTransfer.effectAllowed = 'move';
              event.dataTransfer.setData('application/x-heimdall-home-widget', id);
              const slot = event.currentTarget.closest('.home-widget-slot');
              if (slot && event.dataTransfer.setDragImage) event.dataTransfer.setDragImage(slot, 20, 20);
            }, onDragEnd: endDrag,
          } : null}>{widgets[id]}</WidgetLayoutContext.Provider>
        </div>;
      })}
    </div>
  </div>;
}
export function HomePage({ pane }: HomePageProps = {}) {
  const user = useAuthUser();
  if (pane) return <div data-debug-id="home-page-pane" className="h-full w-full min-h-0 overflow-y-auto pb-8 max-md:flex max-md:flex-col max-md:pb-0">
    <NewConversationPage embedded launchIntent={pane.launchIntent} onLaunched={pane.onOpenAgent} />
  </div>;
  return <HomeDashboard key={user?.user_id || ''} userId={user?.user_id || ''} />;
}
export default HomePage;
