import { createContext, useContext, useEffect, useRef, useState, type DragEvent, type ReactNode } from 'react';
import { Drawer, IconButton, Menu } from '@ui';
import { HOME_WIDGETS, defaultHomeLayout, setWidgetHidden, type HomeLayout, type HomeWidgetLayout } from './homeLayout';

export interface WidgetLayoutControls {
  widget: HomeWidgetLayout;
  mobile: boolean;
  earlier?: () => void;
  later?: () => void;
  edit: (change: (layout: HomeLayout) => HomeLayout) => void;
  onDragStart: (event: DragEvent<HTMLButtonElement>) => void;
  onDragEnd: () => void;
}
export const WidgetLayoutContext = createContext<WidgetLayoutControls | null>(null);

/** Shared title slot keeps handles and remove actions beside the actual widget title. */
export function WidgetTitle({ children }: { children: ReactNode }) {
  const controls = useContext(WidgetLayoutContext);
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const mobile = controls?.mobile ?? false;
  const editing = !!controls;
  useEffect(() => { setOpen(false); }, [mobile, editing]);
  useEffect(() => {
    if (!open || !editing) return;
    const button = trigger.current;
    const dashboard = button?.closest('.home-dashboard');
    return () => {
      queueMicrotask(() => {
        if (!button?.isConnected) {
          const edit = dashboard?.querySelector<HTMLButtonElement>('[data-debug-id="home-layout-edit"]');
          if (edit?.isConnected) edit.focus({ preventScroll: true });
          else document.querySelector<HTMLButtonElement>('[data-debug-id="home-layout-edit"]')?.focus({ preventScroll: true });
        }
      });
    };
  }, [open, mobile, editing]);
  if (!controls) return <>{children}</>;
  const { widget, earlier, later, edit } = controls;
  const name = HOME_WIDGETS.find((item) => item.id === widget.id)!.name;
  const remove = () => edit((layout) => setWidgetHidden(layout, widget.id, true));
  const actions = <>
    {!mobile && <>
      <Menu.Item disabled={!earlier} data-debug-id={`home-layout-earlier-${widget.id}`} onClick={earlier}>Move earlier</Menu.Item>
      <Menu.Item disabled={!later} data-debug-id={`home-layout-later-${widget.id}`} onClick={later}>Move later</Menu.Item>
      <Menu.Item data-debug-id={`home-layout-width-${widget.id}`} onClick={() => edit((layout) => ({ ...layout, widgets: layout.widgets.map((item) => item.id === widget.id ? { ...item, width: item.width === 1 ? 2 : 1 } : item) }))}>
        {widget.width === 1 ? 'Make full width' : 'Make half width'}
      </Menu.Item>
    </>}
    <Menu.Item data-debug-id={`home-layout-menu-remove-${widget.id}`} onClick={remove}>Remove widget</Menu.Item>
    <Menu.Separator />
    <Menu.Item data-debug-id={`home-layout-reset-${widget.id}`} onClick={() => edit((layout) => ({ ...defaultHomeLayout(), version: layout.version }))}>Reset layout</Menu.Item>
  </>;
  return <div className="home-widget-title">
    {mobile && <>
      {children}
      <span className="home-layout-arrows" role="group" aria-label={`Reorder ${name} widget`}>
        <IconButton icon="arrow-up" label={`Move ${name} widget up`} disabled={!earlier} onClick={earlier} data-debug-id={`home-layout-up-${widget.id}`} />
        <IconButton icon="arrow-down" label={`Move ${name} widget down`} disabled={!later} onClick={later} data-debug-id={`home-layout-down-${widget.id}`} />
      </span>
    </>}
    {mobile ? <>
      <IconButton ref={trigger} icon="more-horizontal" label={`Layout actions for ${name}`} className="home-layout-options"
        data-debug-id={`home-layout-options-${widget.id}`} aria-haspopup="dialog" aria-expanded={open} onClick={() => setOpen((value) => !value)} />
      <Drawer open={open} onOpenChange={setOpen} side="bottom" variant="sheet" title={`Layout actions for ${name}`}
        hideHeader autoFocus={false} returnFocusRef={trigger} data-debug-id={`home-layout-actions-sheet-${widget.id}`}>
        <Menu.Panel key={String(open)} label={`Layout actions for ${name}`} variant="sheet" autoFocus={open}
          onClose={() => setOpen(false)} className="px-2 pb-4 pt-1">{actions}</Menu.Panel>
      </Drawer>
    </> : <Menu label={`Layout actions for ${widget.id}`} className="home-layout-menu" open={open} onOpenChange={setOpen} trigger={
        <IconButton ref={trigger} icon="grip" label={`Reorder ${widget.id} widget`} className="home-layout-handle" draggable
          data-debug-id={`home-layout-handle-${widget.id}`} onDragStart={controls.onDragStart} onDragEnd={controls.onDragEnd} />
    }>
      {actions}
    </Menu>}
    {!mobile && children}
    <IconButton icon="close" label={`Remove ${widget.id} widget`} className="home-layout-remove" data-debug-id={`home-layout-remove-${widget.id}`} onClick={remove} />
  </div>;
}
