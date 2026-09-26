import { useEffect, useMemo, useState, useCallback } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import Icon from '../Icon';
import {
  useListShellsQuery,
  useKillShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { NewShellDialog } from '../shells/NewShellDialog';
import { ShellTerminalPane } from '../shells/ShellTerminalPane';
import { openTab, selectPreviewTabs } from '../../store/previewTabsSlice';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
} from '../../store/vaultSlice';
import { buildRouteHash } from '../../utils/appLocation';
import {
  readBottomDockHeight,
  writeBottomDockHeight,
  readBottomDockOpen,
  writeBottomDockOpen,
  BOTTOM_DOCK_MIN_HEIGHT,
} from '../../utils/clientPersistence';

export interface BottomDockProps {
  isOpen?: boolean;
  onClose?: () => void;
  defaultBridgeId?: string;
}

export default function BottomDock({
  isOpen = true,
  onClose,
  defaultBridgeId,
}: BottomDockProps = {}) {
  const dispatch = useDispatch();

  // Dock sizing & window state
  const [height, setHeight] = useState<number>(() => readBottomDockHeight());
  const [isMinimized, setIsMinimized] = useState<boolean>(() => !readBottomDockOpen());
  const [isResizing, setIsResizing] = useState<boolean>(false);

  // Vault status (REQ-BOTTOMDOCK-VAULT-2)
  const isVaultConfigured = useSelector(selectIsVaultConfigured);
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);

  // Active tab: sessionId
  const [activeTab, setActiveTab] = useState<string>('');
  const [showNewShell, setShowNewShell] = useState<boolean>(false);
  const [closingSessionIds, setClosingSessionIds] = useState<Set<string>>(() => new Set());
  const [pendingSessions, setPendingSessions] = useState<ShellSession[]>([]);

  // Active interactive shells across all bridges (REQ-BAR-2)
  const { data: shellsData } = useListShellsQuery(
    { status: 'live' },
    { pollingInterval: 3000, refetchOnMountOrArgChange: true }
  );

  const [killShell] = useKillShellMutation();

  const allSessions: ShellSession[] = useMemo(() => {
    return shellsData?.sessions || [];
  }, [shellsData?.sessions]);

  // Clean up pendingSessions once they appear in allSessions
  useEffect(() => {
    if (pendingSessions.length > 0 && allSessions.length > 0) {
      const remaining = pendingSessions.filter(
        (p) => !allSessions.some((s) => s.session_id === p.session_id)
      );
      if (remaining.length !== pendingSessions.length) {
        setPendingSessions(remaining);
      }
    }
  }, [allSessions, pendingSessions]);

  // Clean up closingSessionIds once allSessions no longer contains them
  useEffect(() => {
    if (closingSessionIds.size > 0 && allSessions.length > 0) {
      const stillPresent = new Set<string>();
      for (const id of closingSessionIds) {
        if (allSessions.some((s) => s.session_id === id)) {
          stillPresent.add(id);
        }
      }
      if (stillPresent.size !== closingSessionIds.size) {
        setClosingSessionIds(stillPresent);
      }
    }
  }, [allSessions, closingSessionIds]);

  // Active running/starting interactive shells (or currently viewed session)
  const visibleSessions = useMemo(() => {
    const unconfirmedPending = pendingSessions.filter(
      (p) => !allSessions.some((s) => s.session_id === p.session_id)
    );
    const combined = [...allSessions, ...unconfirmedPending];
    return combined.filter((s) => {
      if (closingSessionIds.has(s.session_id)) return false;
      const isInteractive = s.kind === 'interactive' || s.kind === 'agent';
      const isLive = s.status === 'running' || s.status === 'starting';
      return (isInteractive && isLive) || s.session_id === activeTab;
    });
  }, [allSessions, pendingSessions, closingSessionIds, activeTab]);

  // Ensure activeTab points to a valid tab
  useEffect(() => {
    if (visibleSessions.length > 0) {
      const currentExists = visibleSessions.some((s) => s.session_id === activeTab);
      if (!currentExists) {
        setActiveTab(visibleSessions[0].session_id);
      }
    } else if (activeTab) {
      setActiveTab('');
    }
  }, [visibleSessions, activeTab]);

  // Toggle listener from Ctrl+` in AppShell
  useEffect(() => {
    const handler = () => {
      setIsMinimized((prev) => {
        const next = !prev;
        writeBottomDockOpen(!next);
        return next;
      });
    };
    window.addEventListener('heimdall:toggle-bottom-dock', handler);
    return () => window.removeEventListener('heimdall:toggle-bottom-dock', handler);
  }, []);

  // Kill shell handler when closing tab (REQ-OPT-CLOSE-1)
  const handleKillSession = useCallback(
    (sessionId: string, e?: React.MouseEvent) => {
      e?.stopPropagation();

      // Immediately add sessionId to closingSessionIds
      setClosingSessionIds((prev) => {
        const next = new Set(prev);
        next.add(sessionId);
        return next;
      });

      // Remove from pendingSessions if present
      setPendingSessions((prev) => prev.filter((s) => s.session_id !== sessionId));

      // Immediately switch activeTab to the next or previous visible session that is not in closingSessionIds (or empty string if none remain)
      if (activeTab === sessionId) {
        const remaining = visibleSessions.filter(
          (s) => s.session_id !== sessionId && !closingSessionIds.has(s.session_id)
        );
        if (remaining.length > 0) {
          const currentIndex = visibleSessions.findIndex((s) => s.session_id === sessionId);
          const nextSession = remaining[currentIndex] || remaining[currentIndex - 1] || remaining[0];
          setActiveTab(nextSession.session_id);
        } else {
          setActiveTab('');
        }
      }

      // Dispatch killShell asynchronously in background WITHOUT awaiting it before updating UI state
      killShell({ sessionId })
        .unwrap()
        .catch((err) => {
          console.error('Failed to kill shell session', err);
        });
    },
    [killShell, activeTab, visibleSessions, closingSessionIds]
  );

  // Resize handling (REQ-DOCK-BOUNDS-3)
  const handleResizeStart = useCallback(
    (e: React.MouseEvent) => {
      if (isMinimized) return;
      e.preventDefault();
      setIsResizing(true);
      const startY = e.clientY;
      const startHeight = height;

      const handleMouseMove = (moveEvent: MouseEvent) => {
        const delta = startY - moveEvent.clientY;
        const maxHeight = Math.min(
          Math.floor(window.innerHeight * 0.8),
          window.innerHeight - 100
        );
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
    [height, isMinimized]
  );

  // Active session object
  const activeSession = useMemo(() => {
    return (
      allSessions.find((s) => s.session_id === activeTab) ||
      pendingSessions.find((s) => s.session_id === activeTab) ||
      null
    );
  }, [allSessions, pendingSessions, activeTab]);

  // Previews from preview tabs slice
  const previewTabs = useSelector(selectPreviewTabs);

  if (!isOpen) return null;

  const effectiveHeight = isMinimized ? 36 : height;

  return (
    <div
      data-debug-id="bottom-dock-container"
      style={{ height: effectiveHeight, maxHeight: 'min(calc(100vh - 100px), 80vh)' }}
      className={`relative z-20 flex w-full shrink-0 flex-col border-t border-subtle bg-surface transition-[height] duration-150 ease-out max-h-[80vh] ${
        isResizing ? 'select-none pointer-events-none' : ''
      }`}
    >
      {/* Top resize handle (only active when restored) */}
      {!isMinimized && (
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
        {/* Left: Shell tabs and + button with horizontal sidescrolling (REQ-BAR-2) */}
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto scroll-smooth no-scrollbar py-0.5">
          {visibleSessions.map((session) => {
            const isTabActive = activeTab === session.session_id;
            const isRunning = session.status === 'running' || session.status === 'starting';
            const title = session.label || session.cmd || `Shell #${session.session_id.slice(-4)}`;

            return (
              <div
                key={session.session_id}
                data-debug-id={`bottom-dock-tab-${session.session_id}`}
                onClick={() => setActiveTab(session.session_id)}
                className={`group relative flex h-7 max-w-[190px] shrink-0 cursor-pointer items-center gap-1.5 rounded-lg border px-2 py-0.5 text-xs transition-colors ${
                  isTabActive
                    ? 'border-subtle bg-surface-secondary font-medium text-primary'
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

          {/* New Shell (+) button (REQ-BAR-4) */}
          <button
            type="button"
            data-debug-id="bottom-dock-new-shell-btn"
            title="Launch new shell (+)"
            onClick={() => setShowNewShell(true)}
            className="grid h-7 w-7 shrink-0 place-items-center rounded-lg text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="plus" size={14} />
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

        {/* Right: Controls & Vault Badge (REQ-BOTTOMDOCK-VAULT-2, REQ-BOTTOMDOCK-EXPAND-3) */}
        <div className="flex shrink-0 items-center gap-0.5 pl-2">
          <button
            type="button"
            data-debug-id="vault-header-status-badge"
            onClick={() => {
              window.location.hash = buildRouteHash('/settings/vault', '');
            }}
            className="inline-flex items-center gap-1.5 text-[11px] text-muted hover:text-primary transition-colors cursor-pointer mr-2"
            title={`User Vault: ${isVaultUnlocked ? 'Unlocked' : isVaultConfigured ? 'Locked' : 'Unconfigured'} (Click to manage)`}
          >
            <Icon name="lock" size={12} />
            <span>Vault: {isVaultUnlocked ? 'Unlocked' : isVaultConfigured ? 'Locked' : 'Unconfigured'}</span>
          </button>
          <button
            type="button"
            data-debug-id="bottom-dock-minimize-btn"
            onClick={() => {
              setIsMinimized((prev) => {
                const next = !prev;
                writeBottomDockOpen(!next);
                return next;
              });
            }}
            title={isMinimized ? 'Expand bottom dock' : 'Collapse bottom dock'}
            aria-label={isMinimized ? 'Expand bottom dock' : 'Collapse bottom dock'}
            className="grid h-7 w-7 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name={isMinimized ? 'chevron-up' : 'chevron-down'} size={14} />
          </button>
        </div>
      </div>

      {/* Dock Body - ShellTerminalPane occupies 100% of parent container (REQ-BAR-5) */}
      {!isMinimized && (
        <div className="flex flex-col flex-1 min-h-0 w-full overflow-hidden bg-canvas">
          {activeSession ? (
            <ShellTerminalPane
              session={activeSession}
              onClose={() => handleKillSession(activeSession.session_id)}
            />
          ) : (
            <div
              data-debug-id="bottom-dock-empty-state"
              className="grid h-full place-items-center p-6 text-center text-xs text-muted"
            >
              <div>
                <p className="font-semibold text-primary">No active shells</p>
                <p className="mt-1 text-faint">
                  Launch a new interactive shell to get started.
                </p>
                <div className="mt-4 flex items-center justify-center gap-2">
                  <button
                    type="button"
                    onClick={() => setShowNewShell(true)}
                    className="rounded-lg bg-accent px-3 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                  >
                    + Launch New Shell
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
          bridgeId={defaultBridgeId}
          onClose={() => setShowNewShell(false)}
          onCreated={(sessionId) => {
            setShowNewShell(false);
            const placeholder: ShellSession = {
              session_id: sessionId,
              status: 'starting',
              kind: 'interactive',
              label: 'New Shell',
              cmd: '',
              cwd: '',
              server_port: 0,
              bridge_id: defaultBridgeId || '',
              created_at: new Date().toISOString(),
            } as unknown as ShellSession;
            setPendingSessions((prev) => [...prev.filter((p) => p.session_id !== sessionId), placeholder]);
            setActiveTab(sessionId);
            setIsMinimized(false);
            writeBottomDockOpen(true);
          }}
        />
      )}
    </div>
  );
}
