import { useEffect, useRef } from 'react';
import { useSelector } from 'react-redux';
import { Alert, Badge, Button, EmptyState, Icon, Spinner, StatusPill, Text } from '@ui';
import { useListShellsQuery } from '../../../api/endpoints/shells';
import { selectMainLeafIds } from '../../../store/workspaceLayoutSlice';
import { bridgeLabel } from '../../../utils/bridgeLaunchOptions';
import { composerBridgeIsOnline } from '../../../utils/composerBridgeOptions';
import { resolveProjectBridgeShellCwd } from '../../shells/interactiveShellLaunch';
import { attachableShells, shellPaneName, shellUptime } from '../../shells/shellPaneModel';
import { statusPresentation } from '../../shells/shellModel';
import { useShellLaunch } from '../../shells/useShellLaunch';
import UpgradePrompt from '../../billing/UpgradePrompt';

export interface ShellPickerProps {
  projects: any[];
  bridges: any[];
  projectId: string;
  disabled?: boolean;
  bridgesLoading?: boolean;
  bridgesError?: boolean;
  onRetryBridges: () => void;
  autoFocus?: boolean;
  onBusyChange: (busy: boolean) => void;
  onOpenShell: (sessionId: string) => void;
}

/** The headline owns the project. Bridge rows launch directly; session rows reopen. */
export function ShellPicker({ projects, bridges, projectId, disabled, bridgesLoading, bridgesError, onRetryBridges, autoFocus, onBusyChange, onOpenShell }: ShellPickerProps) {
  const launch = useShellLaunch({ projects, bridges, projectId, onStarted: onOpenShell, enabled: false });
  const shells = useListShellsQuery({ status: 'live', projectId, limit: 200 }, { skip: !projectId });
  const sessions = attachableShells(shells.data?.sessions, { projectId });
  const openIds = useSelector(selectMainLeafIds);
  const firstBridge = useRef<HTMLButtonElement>(null);
  const focused = useRef(false);
  const project = projects.find((row) => row.project_id === projectId);
  const startDisabled = Boolean(disabled || launch.busy || !launch.shellsEnabled || !project || project.state !== 'active' || launch.blocked === 'vault');

  useEffect(() => { onBusyChange(launch.busy); }, [launch.busy, onBusyChange]);
  useEffect(() => () => onBusyChange(false), [onBusyChange]);
  useEffect(() => {
    if (!autoFocus || focused.current || startDisabled || !launch.onlineBridges.length) return;
    const frame = requestAnimationFrame(() => { firstBridge.current?.focus(); focused.current = true; });
    return () => cancelAnimationFrame(frame);
  }, [autoFocus, startDisabled, launch.onlineBridges.length]);

  return (
    <div data-debug-id="new-convo-shell-picker" className="min-w-0">
      <section aria-labelledby="new-shell-bridges-heading">
        <div className="flex items-center justify-between gap-3 p-4">
          <div>
            <Text as="h2" role="title" id="new-shell-bridges-heading" className="m-0">Start a shell on</Text>
            <Text role="body-sm" tone="muted" className="mb-0 mt-1">Choose a connected bridge to start in this project.</Text>
          </div>
          <Badge className="shrink-0 max-md:hidden">{launch.onlineBridges.length} connected</Badge>
        </div>
        {launch.upgradeDetails ? <div className="px-4 pb-3"><UpgradePrompt details={launch.upgradeDetails} debugId="shell-launch-upgrade" subtle /></div> : null}
        {launch.blocked === 'vault' ? <div className="px-4 pb-3"><Text role="body-sm" tone="muted">Unlock your vault to start a shell. Shell commands are encrypted.</Text></div> : null}
        {launch.errorMessage ? <div data-debug-id="new-shell-start-error" className="px-4 pb-3"><Alert tone="danger">{launch.errorMessage}</Alert></div> : null}
        {bridgesLoading ? <div role="status" className="flex items-center gap-2 px-4 pb-4"><Spinner size="sm" /><Text role="body-sm" tone="muted">Loading bridges…</Text></div> : bridgesError ? (
          <div className="px-4 pb-4"><Alert tone="danger">Could not load connected bridges. <Button variant="ghost" size="sm" onClick={onRetryBridges} data-debug-id="new-shell-retry-bridges">Try again</Button></Alert></div>
        ) : !launch.onlineBridges.length ? (
          <EmptyState className="mx-4 mb-4" icon="device" title="No connected bridges" description="Connect a bridge to start a shell." />
        ) : (
          <ul className="m-0 list-none p-0" aria-label="Start a shell on a connected bridge">
            {launch.onlineBridges.map((bridge, index) => {
              const name = bridgeLabel(bridge) || bridge.bridge_id;
              const path = resolveProjectBridgeShellCwd(project, bridge.bridge_id);
              const starting = launch.startingBridgeId === bridge.bridge_id;
              return <li key={bridge.bridge_id} className="border-t border-subtle">
                <Button
                  ref={index === 0 ? firstBridge : undefined}
                  variant="ghost" width="full" className="min-h-16 gap-3 rounded-none px-4 py-3 text-left !justify-start"
                  data-debug-id={'new-shell-bridge-' + bridge.bridge_id}
                  aria-label={'Start a shell on ' + name}
                  aria-busy={starting || undefined}
                  disabled={startDisabled || !composerBridgeIsOnline(bridge)}
                  onClick={() => void launch.startOnBridge(bridge.bridge_id)}
                >
                  <span className="grid h-8 w-8 shrink-0 place-items-center rounded-[var(--radius-md)] bg-neutral-soft text-muted"><Icon name="device" size="md" /></span>
                  <span className="min-w-0 flex-1">
                    <Text as="span" role="body" className="block">{name}</Text>
                    <Text as="span" role={path ? 'code-sm' : 'body-sm'} tone="muted" className="mt-1 block truncate" title={path}>{path || 'Home folder'}</Text>
                  </span>
                  {starting ? <span className="flex shrink-0 items-center gap-2"><Spinner size="sm" /><Text as="span" role="caption" tone="muted">Starting…</Text></span> : <StatusPill tone="success">Online</StatusPill>}
                  <Icon name="arrow-right" size="md" className="shrink-0 text-muted" />
                </Button>
              </li>;
            })}
          </ul>
        )}
      </section>
      <section aria-labelledby="new-shell-running-heading" className="border-t border-strong">
        <div className="flex items-center justify-between gap-3 p-4">
          <Text as="h2" role="title" id="new-shell-running-heading" className="m-0">Already running</Text>
          {!shells.isLoading && !shells.isError ? <Badge>{sessions.length}</Badge> : null}
        </div>
        {shells.isLoading || !projectId ? <div role="status" className="flex items-center gap-2 px-4 pb-4"><Spinner size="sm" /><Text role="body-sm" tone="muted">Loading shells…</Text></div> : shells.isError ? (
          <div data-debug-id="new-shell-list-error" className="px-4 pb-4"><Alert tone="danger">Could not load running shells. <Button variant="ghost" size="sm" data-debug-id="new-shell-retry-list" onClick={() => void shells.refetch()}>Try again</Button></Alert></div>
        ) : !sessions.length ? <EmptyState data-debug-id="new-shell-empty" className="mx-4 mb-4" icon="terminal" title="No shells running in this project" description="Choose a bridge above to start one." /> : (
          <ul className="m-0 list-none p-0" aria-label="Running shells in this project">
            {sessions.map((session) => {
              const bridge = bridges.find((row) => row.bridge_id === session.bridge_id);
              const presentation = statusPresentation({ ...session, status_unknown: session.status_unknown || Boolean(bridge && !composerBridgeIsOnline(bridge)) });
              const tone = presentation.label === 'Running' ? 'info' : presentation.tone;
              return <li key={session.session_id} className="border-t border-subtle">
                <Button variant="ghost" width="full" className="min-h-16 gap-3 rounded-none px-4 py-3 text-left !justify-start" data-debug-id={'new-shell-session-' + session.session_id} disabled={Boolean(disabled || launch.busy)} onClick={() => onOpenShell(session.session_id)}>
                  <span className="grid h-8 w-8 shrink-0 place-items-center rounded-[var(--radius-md)] bg-neutral-soft text-muted"><Icon name="terminal" size="md" /></span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2"><Text as="span" role="body" truncate>{shellPaneName(session)}</Text>{openIds.includes(session.session_id) ? <Badge className="shrink-0 max-md:hidden">Open</Badge> : null}</span>
                    <Text as="span" role="code-sm" tone="muted" className="mt-1 block truncate">{bridgeLabel(bridge) || session.bridge_id} · {session.cwd || 'Home folder'}</Text>
                  </span>
                  <span className="shrink-0 text-right"><StatusPill tone={tone} title={presentation.title}>{presentation.label}</StatusPill><Text as="span" role="caption" tone="faint" className="mt-1 block max-md:hidden">{shellUptime(session.started_at)}</Text></span>
                  <Icon name="chevron-right" size="md" className="shrink-0 text-faint" />
                </Button>
              </li>;
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
