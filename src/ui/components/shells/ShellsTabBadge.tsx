// T11-UI-1: the running-session count shown on the sidebar's Shells tab, mirroring
// the Tasks tab's progress pill.
//
// It deliberately issues the SAME useListShellsQuery args as the ShellsPanel behind
// the tab, so RTK Query serves both from one cache entry and one poll — the badge
// costs nothing extra once the tab is open, and keeps the list warm before it is.
import { useListShellsQuery } from '../../api/endpoints/shells';

export function ShellsTabBadge({ chainId }: { chainId?: string }) {
  const { data } = useListShellsQuery(
    { chainId: chainId || undefined },
    { pollingInterval: 5000, skipPollingIfUnfocused: true },
  );
  const running = (data?.sessions ?? []).filter((session) => session.status === 'running').length;
  if (running === 0) return null;
  return (
    <span
      data-debug-id="conversation-right-panel-tab-shells-badge"
      className="rounded-full bg-neutral-soft px-1.5 py-0.5 text-[10px] font-bold text-accent"
    >
      {running}
    </span>
  );
}

export default ShellsTabBadge;
