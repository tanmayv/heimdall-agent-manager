import type { ReactNode } from 'react';

export default function UnifiedWorkspaceShell({
  leftSidebar,
  mainRegion,
  inspector,
  inspectorCollapsed = false,
  className = '',
}: {
  leftSidebar?: ReactNode;
  mainRegion: ReactNode;
  inspector?: ReactNode;
  inspectorCollapsed?: boolean;
  className?: string;
}) {
  return (
    <div data-debug-id="workspace-shell" data-inspector-collapsed={inspectorCollapsed ? 'true' : 'false'} className={`flex h-full min-h-0 ${className}`.trim()}>
      {leftSidebar}
      {mainRegion}
      {inspector}
    </div>
  );
}
