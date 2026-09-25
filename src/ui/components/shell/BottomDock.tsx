import { useEffect, useMemo, useRef, useState, useCallback } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Select } from '@ui';
import Icon from '../Icon';
import {
  useListShellsQuery,
  useKillShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { bridgeIdOf, bridgeIsOnline, bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { NewShellDialog } from '../shells/NewShellDialog';
import { ShellTerminalPane } from '../shells/ShellTerminalPane';
import ShellJobsPanel from '../chat/ShellJobsPanel';
import { openTab, selectPreviewTabs } from '../../store/previewTabsSlice';
import {
  readBottomDockHeight,
  writeBottomDockHeight,
  BOTTOM_DOCK_DEFAULT_HEIGHT,
  BOTTOM_DOCK_MIN_HEIGHT,
} from '../../utils/clientPersistence';

export interface BottomDockProps {
  isOpen: boolean;
  onClose: () => void;
  defaultBridgeId?: string;
}

export default function BottomDock({
  isOpen,
  onClose,
  defaultBridgeId,
}: BottomDockProps) {
  const dispatch = useDispatch();

  // Dock sizing & window state
  const [height, setHeight] = useState<number>(() => readBottomDockHeight());
  const [isMinimized, setIsMinimized] = useState<boolean>(false);
  const [isMaximized, setIsMaximized] = useState<boolean>(false);
  const [isResizing, setIsResizing] = useState<boolean>(false);

  // Active tab: either a sessionId or 'jobs'
  const [activeTab, setActiveTab] = useState<string>('');
  const [showNewShell, setShowNewShell] = useState<boolean>(false);

  // Bridge selection
  const [selectedBridgeId, setSelectedBridgeId] = useState<string>(defaultBridgeId || '');
  const bridgesQuery = useListBridgesQuery();

  const bridges: any[] = useMemo(() => {
    const all: any[] = bridgesQuery.data?.bridges || [];
    return all
      .filter((b) => String(b?.status || '').toLowerCase() !== 'revoked')
      .slice()
      .sort((a, b) => Number(bridgeIsOnline(b)) - Number(bridgeIsOnline(a)));
  }, [bridgesQuery.data]);

  // Synchronize or default selected bridge
  useEffect(() => {
    if (selectedBridgeId && bridges.some((b) => bridgeIdOf(b) === selectedBridgeId)) {
      return;
    }
    if (bridges.length > 0) {
      const preferred = defaultBridgeId && bridges.some((b) => bridgeIdOf(b) === defaultBridgeId)
        ? defaultBridgeId
        : bridgeIdOf(bridges.find(bridgeIsOnline) || bridges[0]);
      if (preferred) setSelectedBridgeId(preferred);
    }
  }, [bridges, defaultBridgeId, selectedBridgeId]);

  // Shell sessions on the selected bridge
  const { data: shellsData } = useListShellsQuery(
    { bridgeId: selectedBridgeId || undefined },
    { pollingInterval: 3000, refetchOnMountOrArgChange: true, skip: !selectedBridgeId }
  );

  const [killShell] = useKillShellMutation();

  const allSessions: ShellSession[] = useMemo(() => {
    return shellsData?.sessions || [];
  }, [shellsData?.sessions]);

  // Active running/starting interactive shells (or currently viewed session)
  const visibleSessions = useMemo(() => {
    return allSessions.filter((s) => {
      const isInteractive = s.kind === 'interactive' || s.kind === 'agent';
      const isLive = s.status === 'running' || s.status === 'starting';
      return (isInteractive && isLive) || s.session_id === activeTab;
    });
  }, [allSessions, activeTab]);

  // Ensure activeTab points to a valid tab
  useEffect(() => {
    if (activeTab === 'jobs') return;
    if (visibleSessions.length > 0) {
      const currentExists = visibleSessions.some((s) => s.session_id === activeTab);
      if (!currentExists) {
        setActiveTab(visibleSessions[0].session_id);
      }
    } else if (!activeTab) {
      setActiveTab(allSessions.length > 0 ? allSessions[0].session_id : 'jobs');
    }
  }, [visibleSessions, allSessions, activeTab]);

  // Kill shell handler when closing tab
  const handleKillSession = useCallback(
    async (sessionId: string, e?: React.MouseEvent) => {
      e?.stopPropagation();
      try {
        await killShell({ sessionId }).unwrap();
      } catch (err) {
        console.error('Failed to kill shell session', err);
      }
      if (activeTab === sessionId) {
        const remaining = visibleSessions.filter((s) => s.session_id !== sessionId);
        if (remaining.length > 0) {
          setActiveTab(remaining[0].session_id);
        } else {
          setActiveTab('jobs');
        }
      }
    },
    [killShell, activeTab, visibleSessions]
  );

  // Resize handling
  const handleResizeStart = useCallback(
    (e: React.MouseEvent) => {
      if (isMinimized || isMaximized) return;
      e.preventDefault();
      setIsResizing(true);
      const startY = e.clientY;
      const startHeight = height;

      const handleMouseMove = (moveEvent: MouseEvent) => {
        const delta = startY - moveEvent.clientY;
        const maxHeight = Math.max(BOTTOM_DOCK_MIN_HEIGHT, window.innerHeight - 80);
        const next = Math.min(maxHeight, Math.max(BOTTOM_DOCK_MIN_HEIGHT, startHeight + delta));
        setHeight(next);
      };

      const handleMouseUp = () => {
        setIsResizing(false);
        setHeight((cur) => {
          writeBottomDockHeight(cur);
          return cur;
        });
        window.removeEventListener('mousemove', handleMouseMove);
        window.removeEventListener('mouseup', handleMouseUp);
      };

      window.addEventListener('mousemove', handleMouseMove);
      window.addEventListener('mouseup', handleMouseUp);
    },
    [height, isMinimized, isMaximized]
  );

  // Active session object
  const activeSession = useMemo(() => {
    return allSessions.find((s) => s.session_id === activeTab) || null;
  }, [allSessions, activeTab]);

  // Previews from preview tabs slice
  const previewTabs = useSelector(selectPreviewTabs);

  if (!isOpen) return null;

  const effectiveHeight = isMinimized ? 36 : isMaximized ? 'calc(100% - 40px)' : height;

  return (
    <div
      data-debug-id="bottom-dock-container"
      style={{ height: effectiveHeight }}
      className={`relative z-20 flex w-full shrink-0 flex-col border-t border-subtle bg-surface transition-[height] duration-150 ease-out ${
        isResizing ? 'select-none pointer-events-none' : ''
      }`}
    >
      {/* Top resize handle (only active when restored) */}
      {!isMinimized && !isMaximized && (
        <div
          data-debug-id="bottom-dock-resizer"
          onMouseDown={handleResizeStart}
          className="absolute inset-x-0 -top-1.5 h-3 cursor-row-resize transition-colors hover:bg-accent/40 z-30"
          title="Drag to resize dock"
        />
      )}

      {/* Dock Header Tab Bar */}
      <div
        data-debug-id="bottom-dock-header"
        className="flex h-9 shrink-0 items-center justify-between border-b border-subtle bg-surface-raised px-2 text-xs select-none"
      >
        {/* Left: Shell tabs, + button, Jobs tab */}
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto no-scrollbar py-0.5">
          {visibleSessions.map((session) => {
            const isTabActive = activeTab === session.session_id;
            const isRunning = session.status === 'running' || session.status === 'starting';
            const title = session.label || session.cmd || `Shell #${session.session_id.slice(-4)}`;

            return (
              <div
                key={session.session_id}
                data-debug-id={`bottom-dock-tab-${session.session_id}`}
                onClick={() => {
                  setActiveTab(session.session_id);
                  if (isMinimized) setIsMinimized(false);
                }}
                className={`group relative flex h-7 max-w-[190px] shrink-0 cursor-pointer items-center gap-1.5 rounded-lg border px-2 py-0.5 text-xs transition-colors ${
                  isTabActive
                    ? 'border-accent/40 bg-surface font-semibold text-primary shadow-xs'
                    : 'border-transparent text-muted hover:border-subtle hover:bg-neutral-soft hover:text-primary'
                }`}
                title={`${title} (${session.status})`}
              >
                <span
                  className={`h-2 w-2 shrink-0 rounded-full ${
                    session.status === 'running'
                      ? 'bg-success animate-pulse'
                      : session.status === 'starting'
                        ? 'bg-warning animate-pulse'
                        : session.status === 'killed' || session.status === 'failed'
                          ? 'bg-danger'
                          : 'bg-muted'
                  }`}
                />
                <span className="truncate">{title}</span>

                {/* Optional Preview button for port-bearing sessions */}
                {session.status === 'running' && session.server_port > 0 && (
                  <button
                    type="button"
                    title={`Open preview (port ${session.server_port})`}
                    onClick={(e) => {
                      e.stopPropagation();
                      dispatch(openTab(session));
                    }}
                    className="shrink-0 rounded p-0.5 text-accent hover:bg-accent/20"
                  >
                    <Icon name="eye" size={12} />
                  </button>
                )}

                {/* Kill / Close tab button */}
                <button
                  type="button"
                  data-debug-id={`bottom-dock-tab-close-${session.session_id}`}
                  title={isRunning ? 'Kill shell session (✕)' : 'Close tab'}
                  onClick={(e) => handleKillSession(session.session_id, e)}
                  className="shrink-0 rounded p-0.5 text-muted hover:bg-danger/20 hover:text-danger"
                >
                  <Icon name="close" size={12} />
                </button>
              </div>
            );
          })}

          {/* New Shell (+) button */}
          <button
            type="button"
            data-debug-id="bottom-dock-new-shell-btn"
            title="Launch new shell (+)"
            onClick={() => setShowNewShell(true)}
            className="grid h-7 w-7 shrink-0 place-items-center rounded-lg text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="plus" size={14} />
          </button>

          <div className="h-4 w-px shrink-0 bg-subtle mx-1" />

          {/* Background Jobs tab */}
          <button
            type="button"
            data-debug-id="bottom-dock-tab-jobs"
            onClick={() => {
              setActiveTab('jobs');
              if (isMinimized) setIsMinimized(false);
            }}
            className={`flex h-7 shrink-0 items-center gap-1.5 rounded-lg border px-2 py-0.5 text-xs transition-colors ${
              activeTab === 'jobs'
                ? 'border-accent/40 bg-surface font-semibold text-primary shadow-xs'
                : 'border-transparent text-muted hover:border-subtle hover:bg-neutral-soft hover:text-primary'
            }`}
            title="Background Shell Jobs (≥15s)"
          >
            <Icon name="clock" size={13} />
            <span>Jobs</span>
          </button>

          {/* Previews indicator if any active */}
          {previewTabs.length > 0 && (
            <span
              className="flex h-7 shrink-0 items-center gap-1 rounded-lg px-2 text-[11px] text-accent"
              title={`${previewTabs.length} preview tab(s) open`}
            >
              <Icon name="eye" size={12} />
              <span>{previewTabs.length} Preview</span>
            </span>
          )}
        </div>

        {/* Right: Bridge Selector & Window Controls */}
        <div className="flex shrink-0 items-center gap-2 pl-2">
          {/* Bridge Selector */}
          <div className="flex items-center gap-1">
            <span className="hidden lg:inline text-[11px] text-faint">Bridge:</span>
            <Select
              id="bottom-dock-bridge"
              data-debug-id="bottom-dock-bridge-select"
              value={selectedBridgeId}
              onChange={(value) => setSelectedBridgeId(value)}
              disabled={bridgesQuery.isLoading}
              className="min-h-[28px] max-w-[180px] rounded border border-subtle bg-surface px-2 py-0.5 text-xs text-primary"
            >
              <option value="">
                {bridgesQuery.isLoading
                  ? 'Loading bridges…'
                  : bridges.length === 0
                    ? 'No bridges'
                    : 'Select bridge'}
              </option>
              {bridges.map((bridge) => {
                const id = bridgeIdOf(bridge);
                return (
                  <option key={id} value={id}>
                    {bridgeLabel(bridge)}
                    {bridgeIsOnline(bridge) ? '' : ' (offline)'}
                  </option>
                );
              })}
            </Select>
          </div>

          {/* Window control buttons: Minimize, Maximize, Close */}
          <div className="flex items-center gap-0.5">
            <button
              type="button"
              data-debug-id="bottom-dock-minimize-btn"
              onClick={() => setIsMinimized((prev) => !prev)}
              title={isMinimized ? 'Expand bottom dock' : 'Minimize bottom dock'}
              aria-label={isMinimized ? 'Expand bottom dock' : 'Minimize bottom dock'}
              className="grid h-7 w-7 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name={isMinimized ? 'chevron-down' : 'minimize'} size={14} />
            </button>
            <button
              type="button"
              data-debug-id="bottom-dock-maximize-btn"
              onClick={() => {
                setIsMaximized((prev) => !prev);
                setIsMinimized(false);
              }}
              title={isMaximized ? 'Restore dock size' : 'Maximize bottom dock'}
              aria-label={isMaximized ? 'Restore dock size' : 'Maximize bottom dock'}
              className="grid h-7 w-7 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="maximize" size={14} />
            </button>
            <button
              type="button"
              data-debug-id="bottom-dock-close-btn"
              onClick={onClose}
              title="Close bottom dock"
              aria-label="Close bottom dock"
              className="grid h-7 w-7 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="close" size={14} />
            </button>
          </div>
        </div>
      </div>

      {/* Dock Body */}
      {!isMinimized && (
        <div className="flex-1 min-h-0 overflow-hidden bg-canvas">
          {activeTab === 'jobs' ? (
            <ShellJobsPanel bridgeId={selectedBridgeId} />
          ) : activeSession ? (
            <div className="h-full min-h-0 overflow-y-auto p-2">
              <ShellTerminalPane
                session={activeSession}
                onClose={() => handleKillSession(activeSession.session_id)}
              />
            </div>
          ) : (
            <div
              data-debug-id="bottom-dock-empty-state"
              className="grid h-full place-items-center p-6 text-center text-xs text-muted"
            >
              <div>
                <p className="font-semibold text-primary">No active shells on this bridge</p>
                <p className="mt-1 text-faint">
                  Launch a new interactive shell or view background jobs.
                </p>
                <div className="mt-4 flex items-center justify-center gap-2">
                  <button
                    type="button"
                    onClick={() => setShowNewShell(true)}
                    className="rounded-lg bg-accent px-3 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                  >
                    + Launch New Shell
                  </button>
                  <button
                    type="button"
                    onClick={() => setActiveTab('jobs')}
                    className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs text-muted hover:bg-neutral-soft hover:text-primary"
                  >
                    View Background Jobs
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
      )}

      {/* New Shell Modal */}
      {showNewShell && (
        <NewShellDialog
          bridgeId={selectedBridgeId}
          onClose={() => setShowNewShell(false)}
          onCreated={(sessionId) => {
            setShowNewShell(false);
            setActiveTab(sessionId);
            setIsMinimized(false);
          }}
        />
      )}
    </div>
  );
}
