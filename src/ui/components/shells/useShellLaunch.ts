import { useEffect, useMemo, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { useEntitlements } from '../../hooks/useEntitlements';
import { useCreateShellMutation } from '../../api/endpoints/shells';
import { useListBridgeDirQuery } from '../../api/endpoints/bridgeFs';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { composerBridgeIsArchived, composerBridgeIsOnline } from '../../utils/composerBridgeOptions';
import { describeApiError } from '../../utils/bridgeVaultStatus';
import { isPlanLimitError, planLimitDetails, type PlanLimitDetails } from '../../utils/planLimit';
import { buildInteractiveShellRequest, resolveProjectBridgeShellCwd } from './interactiveShellLaunch';

/** Why a new shell cannot start right now; '' when it can. Checked in this order. */
export type ShellLaunchBlock = '' | 'plan' | 'vault' | 'bridge';

export function shellLaunchBlock({ shellsEnabled, vaultUnlocked, bridge }: {
  shellsEnabled: boolean;
  vaultUnlocked: boolean;
  bridge: any;
}): ShellLaunchBlock {
  if (!shellsEnabled) return 'plan';
  if (!vaultUnlocked) return 'vault';
  if (!bridge || !composerBridgeIsOnline(bridge)) return 'bridge';
  return '';
}

export interface UseShellLaunchOptions {
  projects: any[];
  bridges: any[];
  projectId: string;
  /** Preferred bridge (the user's remembered launch bridge). */
  initialBridgeId?: string;
  /** Called with the new session id once the shell has started. */
  onStarted: (sessionId: string) => void;
  /**
   * False while the shell UI is not shown (the new-conversation page in
   * conversation mode): the bridge home-directory lookup is skipped. Default true.
   */
  enabled?: boolean;
}

export interface ShellLaunch {
  /** Non-archived bridges, online first. */
  usableBridges: any[];
  onlineBridges: any[];
  bridgeId: string;
  setBridgeId: (bridgeId: string) => void;
  bridge: any;
  project: any;
  /** The re-defaulting working directory: the project's path on the bridge, else the bridge's home. */
  defaultCwd: string;
  /** True while the bridge's home directory is being resolved for `defaultCwd`. */
  defaultCwdLoading: boolean;
  cwd: string;
  setCwd: (cwd: string) => void;
  /** Optional command; empty starts the user's interactive login shell. */
  command: string;
  setCommand: (command: string) => void;
  shellsEnabled: boolean;
  blocked: ShellLaunchBlock;
  /** A start request is in flight. */
  busy: boolean;
  /** The last start error, or undefined. */
  error: unknown;
  /** Human-readable `error`, or '' when there is none. */
  errorMessage: string;
  /** Plan-limit details when the plan disallows shells or the last start hit a plan limit; else null. */
  upgradeDetails: PlanLimitDetails | null;
  canStart: boolean;
  start: () => Promise<void>;
  /** Launch on the clicked bridge without changing the legacy form selection. */
  startOnBridge: (bridgeId: string) => Promise<void>;
  startingBridgeId: string;
}

/**
 * Launch logic of a new interactive shell (SH-1), shared by ShellLaunchPanel and the
 * new-conversation composer: bridge choice, working directory, optional command,
 * plan/vault/bridge validation and the createShell call with its busy/error state.
 */
export function useShellLaunch({ projects, bridges, projectId, initialBridgeId, onStarted, enabled = true }: UseShellLaunchOptions): ShellLaunch {
  const entitlements = useEntitlements();
  const shellsEnabled = Boolean(entitlements.shells_enabled);
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);
  const usableBridges = useMemo(
    () => bridges.filter((b) => !composerBridgeIsArchived(b)).sort((a, b) => Number(composerBridgeIsOnline(b)) - Number(composerBridgeIsOnline(a))),
    [bridges],
  );
  const onlineBridges = useMemo(() => usableBridges.filter(composerBridgeIsOnline), [usableBridges]);
  const [bridgeId, setBridgeId] = useState('');
  useEffect(() => {
    if (bridgeId && usableBridges.some((b) => b.bridge_id === bridgeId)) return;
    const preferred = onlineBridges.find((b) => b.bridge_id === initialBridgeId) || onlineBridges[0];
    setBridgeId(preferred?.bridge_id || '');
  }, [bridgeId, initialBridgeId, onlineBridges, usableBridges]);
  const bridge = usableBridges.find((b) => b.bridge_id === bridgeId);
  const project = projects.find((p) => p.project_id === projectId);

  // The working directory defaults to the project's path on the chosen bridge and
  // re-defaults whenever the project or bridge changes; the user can edit/browse.
  // Without a project path, fall back to the bridge's own default directory (the
  // path its filesystem API lists for an empty path, i.e. the user's home) so the
  // field always shows the real directory the shell will start in.
  const projectPath = (project && bridgeId && resolveProjectBridgeShellCwd(project, bridgeId)) || '';
  const bridgeHomeQuery = useListBridgeDirQuery({ bridgeId, path: '' }, { skip: !enabled || Boolean(projectPath) || !bridge || !composerBridgeIsOnline(bridge) });
  const defaultCwd = projectPath || (bridgeHomeQuery.data?.ok !== false ? String(bridgeHomeQuery.data?.path || '') : '');
  const [cwd, setCwd] = useState(defaultCwd);
  useEffect(() => { setCwd(defaultCwd); }, [defaultCwd]);
  const [command, setCommand] = useState('');

  const [createShell, createState] = useCreateShellMutation();
  const [startingBridgeId, setStartingBridgeId] = useState('');
  const [validationError, setValidationError] = useState('');
  // Close the same-tick double-click window before React disables rows.
  const inFlight = useRef(false);
  const latest = useRef({ projects, bridges, projectId, shellsEnabled, vaultUnlocked });
  latest.current = { projects, bridges, projectId, shellsEnabled, vaultUnlocked };
  const blocked = shellLaunchBlock({ shellsEnabled, vaultUnlocked, bridge });
  const run = async (request: Parameters<typeof buildInteractiveShellRequest>[0]) => {
    if (inFlight.current) return;
    const current = latest.current;
    const target = current.bridges.find((row) => row.bridge_id === request.bridgeId);
    const reason = shellLaunchBlock({ ...current, bridge: target });
    if (reason) {
      setValidationError(reason === 'bridge' ? 'This bridge is no longer connected. Choose another bridge.' : reason === 'vault' ? 'Unlock your vault to start a shell.' : 'Your plan does not include shells.');
      return;
    }
    inFlight.current = true;
    setStartingBridgeId(request.bridgeId);
    setValidationError('');
    try {
      const session = await createShell(buildInteractiveShellRequest(request)).unwrap();
      onStarted(session.session_id);
    } catch { /* surfaced through createState.error */ }
    finally { inFlight.current = false; setStartingBridgeId(''); }
  };
  const start = async () => {
    if (blocked || !bridgeId) return;
    await run({ bridgeId, cwd: cwd.trim() || undefined, cmd: command.trim() || undefined, projectId: projectId || undefined });
  };
  const startOnBridge = async (targetBridgeId: string) => {
    const current = latest.current;
    const targetProject = current.projects.find((row) => row.project_id === current.projectId);
    if (!targetProject || targetProject.state !== 'active') {
      setValidationError('Choose an active project above before starting a shell.');
      return;
    }
    // An omitted cwd starts in THIS bridge's home, never a cached cwd from another bridge.
    await run({
      bridgeId: targetBridgeId,
      cwd: resolveProjectBridgeShellCwd(targetProject, targetBridgeId),
      projectId: current.projectId,
    });
  };

  const planLimited = isPlanLimitError(createState.error);
  return {
    usableBridges,
    onlineBridges,
    bridgeId,
    setBridgeId,
    bridge,
    project,
    defaultCwd,
    defaultCwdLoading: bridgeHomeQuery.isFetching,
    cwd,
    setCwd,
    command,
    setCommand,
    shellsEnabled,
    blocked,
    busy: Boolean(startingBridgeId) || createState.isLoading,
    error: createState.error,
    errorMessage: validationError || (createState.error ? describeApiError(createState.error) || 'Could not start the shell.' : ''),
    upgradeDetails: planLimited ? planLimitDetails(createState.error) : !shellsEnabled ? { limit: 'shells_enabled' } : null,
    canStart: !blocked && Boolean(bridgeId) && !createState.isLoading,
    start,
    startOnBridge,
    startingBridgeId,
  };
}

export default useShellLaunch;
