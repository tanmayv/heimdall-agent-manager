/**
 * RuntimeSection — section 1 of the Agent settings panel (see DESIGN.md).
 *
 * A card with the runtime status pill and detail line, the current configuration
 * (`<bridge>` · Provider · `<model>` · PTY|ACP, then the project folder), and the
 * lifecycle actions: Restart / Stop / "…" → Force stop while running, Start when
 * stopped. Force stop is confirmed in ForceStopDialog.
 *
 * `runtimeSectionView` is the pure status model (exported for tests).
 */
import React, { useEffect, useState } from 'react';
import { Button, Icon, IconButton, Menu, StatusPill, Text, type Tone } from '@ui';
import { agentStopReasonLabel } from '../../utils/agentStatus';
import { FORCE_STOP_NOTE, ForceStopDialog } from './ForceStopDialog';

export type RuntimePillState = 'running' | 'restarting' | 'stopped';

export interface RuntimeSectionViewInput {
  runtimeStatus: string;
  startupStatus?: string;
  activityStatus?: string;
  /** ISO time the current run started (instance.started_at). */
  startedAt?: string;
  stopReason?: string;
  /** Raw reconfiguration operations, newest first. Phases this UI does not know are ignored. */
  operations?: ReadonlyArray<{ phase?: unknown }>;
  /** A reconfiguration this client accepted (or the hub reports) is moving the runtime. */
  operationInFlight?: boolean;
  /** A Restart request this client sent is still pending. */
  restartPending?: boolean;
  now?: number;
}

export interface RuntimeSectionView {
  state: RuntimePillState;
  label: 'Running' | 'Restarting' | 'Stopped';
  tone: Tone;
  detail: string;
}

const WORKING_ACTIVITY = new Set(['active', 'busy', 'working']);
const STOPPED_STATUSES = new Set(['', 'stopped', 'failed', 'unreachable']);

/** "2h 14m", "14m", "3d 2h", "<1m"; '' for an unknown or future start. */
export function formatUptime(startedAt: string | undefined, now: number): string {
  const started = Date.parse(String(startedAt || ''));
  if (!Number.isFinite(started) || started > now) return '';
  const minutes = Math.floor((now - started) / 60000);
  if (minutes < 1) return '<1m';
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  const mins = minutes % 60;
  if (days > 0) return hours ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return mins ? `${hours}h ${mins}m` : `${hours}h`;
  return `${mins}m`;
}

/** A reconfiguration queued for the next idle (T4 `waiting_for_idle`); absent until the hub supports it. */
export function restartQueued(operations: RuntimeSectionViewInput['operations']): boolean {
  return (operations || []).some((op) => String(op?.phase ?? '').toLowerCase() === 'waiting_for_idle');
}

export function runtimeSectionView(input: RuntimeSectionViewInput): RuntimeSectionView {
  const status = String(input.runtimeStatus || '').toLowerCase();
  const startup = String(input.startupStatus || '').toLowerCase();
  const activity = String(input.activityStatus || '').toLowerCase();
  const now = input.now ?? Date.now();

  if (input.operationInFlight || input.restartPending) {
    return { state: 'restarting', label: 'Restarting', tone: 'info', detail: 'Applying your changes' };
  }
  if (status === 'stopping') {
    return { state: 'restarting', label: 'Restarting', tone: 'info', detail: 'Stopping…' };
  }
  if (STOPPED_STATUSES.has(status)) {
    const reason = agentStopReasonLabel('stopped', input.stopReason);
    const detail = reason
      || (status === 'failed' ? 'Stopped after an error'
        : status === 'unreachable' ? 'Bridge unreachable'
          : 'Stopped');
    return { state: 'stopped', label: 'Stopped', tone: 'neutral', detail };
  }
  if (startup === 'starting' || status === 'starting' || status === 'pending') {
    return { state: 'restarting', label: 'Restarting', tone: 'info', detail: 'Starting…' };
  }
  const uptime = formatUptime(input.startedAt, now);
  const suffix = uptime ? ` · up ${uptime}` : '';
  if (restartQueued(input.operations)) {
    return { state: 'running', label: 'Running', tone: 'info', detail: 'Restart queued after this turn' };
  }
  const doing = WORKING_ACTIVITY.has(activity) ? 'Working on a turn' : 'Idle';
  return { state: 'running', label: 'Running', tone: 'info', detail: `${doing}${suffix}` };
}

const PROVIDER_NAMES: Record<string, string> = {
  claude: 'Claude Code',
  codex: 'Codex',
  gemini: 'Gemini CLI',
  opencode: 'OpenCode',
};

export function providerDisplayName(provider: string): string {
  const key = String(provider || '').trim();
  if (!key) return '—';
  return PROVIDER_NAMES[key.toLowerCase()] || key.charAt(0).toUpperCase() + key.slice(1);
}

export interface RuntimeSectionProps {
  view: RuntimeSectionView;
  bridgeLabel: string;
  provider: string;
  model: string;
  transport: 'pty' | 'acp';
  /** Project folder on the current bridge (instance.project_path). */
  folder?: string;
  agentLabel?: string;
  /** Lifecycle buttons are unavailable (another action or a reconfiguration is in flight). */
  actionsDisabled?: boolean;
  forceStopDisabled?: boolean;
  /** Which action this client is waiting on, for the button spinner. */
  pendingAction?: 'start' | 'stop' | 'restart' | null;
  /** Inline feedback from the last action (hub error or acknowledgement). */
  statusMessage?: string;
  /** Touch layout: every control at least 44px. */
  touch?: boolean;
  onStart: () => void;
  onStop: () => void;
  onRestart: () => void;
  onForceStop: () => void;
}

export function RuntimeSection(props: RuntimeSectionProps) {
  const { view, touch = false, actionsDisabled = false, pendingAction = null } = props;
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  // Inside the drawer/page (a modal @ui Drawer), the Drawer takes Esc in the document
  // capture phase. While the "…" menu is open, Esc closes only the menu.
  useEffect(() => {
    if (!menuOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.stopPropagation();
      event.preventDefault();
      setMenuOpen(false);
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [menuOpen]);
  const controlSize = touch ? 'min-h-11' : 'min-h-9';
  const stopped = view.state === 'stopped';
  const configParts = [
    { key: 'bridge', text: props.bridgeLabel || 'no bridge', mono: true },
    { key: 'provider', text: providerDisplayName(props.provider), mono: false },
    { key: 'model', text: props.model || '—', mono: true },
    { key: 'transport', text: props.transport === 'acp' ? 'ACP' : 'PTY', mono: false },
  ];

  return (
    <section
      data-debug-id="agent-panel-runtime"
      aria-labelledby="agent-panel-runtime-heading"
      className="flex flex-col gap-3"
    >
      <Text as="h3" role="overline" tone="muted" id="agent-panel-runtime-heading" className="sr-only">
        Runtime
      </Text>
      <div className="rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4">
        <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
          <StatusPill
            role="status"
            tone={view.tone}
            data-debug-id="agent-panel-runtime-status"
            data-state={view.state}
          >
            {view.state === 'restarting' ? (
              <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-full border border-current border-t-transparent motion-safe:animate-spin" />
            ) : (
              <span aria-hidden="true" className={`h-1.5 w-1.5 rounded-full ${stopped ? 'bg-current opacity-60' : 'bg-current'}`} />
            )}
            {view.label}
          </StatusPill>
          <Text as="span" role="body-sm" tone="muted" data-debug-id="agent-panel-runtime-detail" className="min-w-0">
            {view.detail}
          </Text>
        </div>

        <div data-debug-id="agent-panel-runtime-config" className="mt-3 flex min-w-0 flex-wrap items-baseline gap-x-1.5 text-primary">
          {configParts.map((part, index) => (
            <React.Fragment key={part.key}>
              {index > 0 ? <span aria-hidden="true" className="text-faint">·</span> : null}
              <Text as="span" role={part.mono ? 'code' : 'body-sm'} className="min-w-0 truncate" data-debug-id={`agent-panel-runtime-${part.key}`}>
                {part.text}
              </Text>
            </React.Fragment>
          ))}
        </div>
        {props.folder ? (
          <Text as="div" role="code-sm" tone="muted" data-debug-id="agent-panel-runtime-folder" className="mt-1 truncate" title={props.folder}>
            {props.folder}
          </Text>
        ) : null}

        <div className="mt-4 flex items-center gap-2">
          {stopped ? (
            <Button
              variant="secondary"
              data-debug-id="agent-panel-runtime-start"
              className={controlSize}
              leading={<Icon name="play" size="sm" />}
              disabled={actionsDisabled}
              loading={pendingAction === 'start'}
              onClick={props.onStart}
            >
              Start
            </Button>
          ) : (
            <>
              <Button
                variant="secondary"
                data-debug-id="agent-panel-runtime-restart"
                className={controlSize}
                leading={<Icon name="refresh" size="sm" />}
                disabled={actionsDisabled || view.state !== 'running'}
                loading={pendingAction === 'restart'}
                onClick={props.onRestart}
              >
                Restart
              </Button>
              <Button
                variant="secondary"
                data-debug-id="agent-panel-runtime-stop"
                className={controlSize}
                leading={<Icon name="stop" size="sm" />}
                disabled={actionsDisabled || view.state !== 'running'}
                loading={pendingAction === 'stop'}
                onClick={props.onStop}
              >
                Stop
              </Button>
            </>
          )}
          {/* Stopped with nothing left to kill: Start is the only action. */}
          {stopped && props.forceStopDisabled ? null : (
          <div className="ml-auto">
            <Menu
              align="end"
              label="More runtime actions"
              open={menuOpen}
              onOpenChange={setMenuOpen}
              className="w-72 max-w-[calc(100vw-2rem)]"
              trigger={
                <IconButton
                  icon="more-horizontal"
                  label="More runtime actions"
                  size={touch ? 'md' : 'sm'}
                  data-debug-id="agent-panel-runtime-more"
                />
              }
            >
              <Menu.Item
                danger
                description={FORCE_STOP_NOTE}
                data-debug-id="agent-panel-runtime-force-stop"
                disabled={props.forceStopDisabled}
                onClick={() => {
                  setMenuOpen(false);
                  setConfirmOpen(true);
                }}
              >
                Force stop
              </Menu.Item>
            </Menu>
          </div>
          )}
        </div>
        {props.statusMessage ? (
          <Text role="caption" tone="muted" data-debug-id="agent-panel-runtime-message" className="mt-2">
            {props.statusMessage}
          </Text>
        ) : null}
      </div>
      <ForceStopDialog
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        onConfirm={props.onForceStop}
        agentLabel={props.agentLabel}
      />
    </section>
  );
}

export default RuntimeSection;
