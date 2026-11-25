import { createContext, useContext, type DragEvent, type ReactNode } from 'react';
import { IconButton, Menu } from '@ui';
import { defaultHomeLayout, setWidgetHidden, type HomeLayout, type HomeWidgetLayout } from './homeLayout';

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
  if (!controls) return <>{children}</>;
  const { widget, mobile, earlier, later, edit } = controls;
  const remove = () => edit((layout) => setWidgetHidden(layout, widget.id, true));
  return <div className="home-widget-title">
    <Menu label={`Layout actions for ${widget.id}`} className="home-layout-menu" trigger={
      <IconButton icon="grip" label={`Reorder ${widget.id} widget`} className="home-layout-handle" draggable
        data-debug-id={`home-layout-handle-${widget.id}`} onDragStart={controls.onDragStart} onDragEnd={controls.onDragEnd} />
    }>
      <Menu.Item disabled={!earlier} data-debug-id={`home-layout-earlier-${widget.id}`} onClick={earlier}>Move earlier</Menu.Item>
      <Menu.Item disabled={!later} data-debug-id={`home-layout-later-${widget.id}`} onClick={later}>Move later</Menu.Item>
      {!mobile && <Menu.Item data-debug-id={`home-layout-width-${widget.id}`} onClick={() => edit((layout) => ({ ...layout, widgets: layout.widgets.map((item) => item.id === widget.id ? { ...item, width: item.width === 1 ? 2 : 1 } : item) }))}>
        {widget.width === 1 ? 'Make full width' : 'Make half width'}
      </Menu.Item>}
      <Menu.Item data-debug-id={`home-layout-menu-remove-${widget.id}`} onClick={remove}>Remove widget</Menu.Item>
      <Menu.Separator />
      <Menu.Item data-debug-id={`home-layout-reset-${widget.id}`} onClick={() => edit((layout) => ({ ...defaultHomeLayout(), version: layout.version }))}>Reset layout</Menu.Item>
    </Menu>
    {children}
    <IconButton icon="close" label={`Remove ${widget.id} widget`} className="home-layout-remove" data-debug-id={`home-layout-remove-${widget.id}`} onClick={remove} />
  </div>;
}
