import type { ReactNode } from 'react';

export default function WorkspaceLeftSidebar({
  children,
  className = '',
}: {
  children: ReactNode;
  className?: string;
}) {
  return <div data-debug-id="workspace-left-sidebar" className={`flex min-h-0 shrink-0 ${className}`.trim()}>{children}</div>;
}
