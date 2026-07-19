import type { ReactNode } from 'react';

export default function WorkspaceMainRegion({
  topBar,
  children,
  className = 'min-w-0 flex min-h-0 flex-1 flex-col',
  contentClassName = 'min-h-0 flex-1',
}: {
  topBar?: ReactNode;
  children: ReactNode;
  className?: string;
  contentClassName?: string;
}) {
  return (
    <section data-debug-id="workspace-main-region" className={className}>
      {topBar ? <div data-debug-id="workspace-top-bar">{topBar}</div> : null}
      <div data-debug-id="workspace-content-outlet" className={contentClassName}>{children}</div>
    </section>
  );
}
