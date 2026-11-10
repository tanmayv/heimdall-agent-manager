// origin/main's ticket tab (REQ-T1..T8) behind a props seam. The caller
// supplies the ticket and its chain as data (TaskWire, the chain's tickets,
// keys and names), the Activity feeds and the attempt changes, and every
// change as an action, so a Bridge-owned chain renders it from owner-local
// reads and owner commands (ownerTaskAdapter) and never a Hub task endpoint.
// Surfaces a caller cannot supply are left out: no `upload` → no attachments,
// no `recheck` / `publish` / `pinBridge` → those actions are not offered, no
// `roles` → no review roles, and a workflow-owned ticket is read-only as before.

import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Alert, Badge, Button, EmptyState, Icon, IconButton, Menu, StatusPill, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { showToast } from '../../store/toastSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { decryptEmbeddedVaultTokens } from '../../utils/vaultContent';
import { containsVaultArmored } from '../../utils/vaultCrypto';
import { DecryptedMarkdown, VaultText } from '../vault';
import { TASK_STATE_LABELS, TASK_STATE_TONE, getTaskPeople, normalizeTaskState, taskHold } from './taskV2Types';
import { TASK_ACTION_LABELS, blockedOnYou, editLock, getTaskActions, isDraft, recheckToast, type TaskActionId } from './taskActions';
import { TaskComposer, type TaskComposerUpload } from './TaskComposer';
import { TaskEditModal, type TaskEditAgent, type TaskEditChange, type TaskEditField, type TaskEditRole } from './TaskEditModal';
import { HoldReasonDialog } from './HoldReasonDialog';
import { RequirementsEditorModal, type RequirementsEditorModalProps } from './RequirementsEditorModal';
import { TicketActivity, type ActivityTab, type TicketActivityFeeds } from './TicketActivity';
import { VaultLockedBanner } from './TicketBoard';
import type { TaskNames } from './taskNames';
import { useTicketClock, usePrefersReducedMotion } from './useTicketClock';
import {
  attemptInfo, boardOrder, isFinishedTask, isRework, keyFor, leaseClock, parseRequirementsHistory, ticketPosition, ticketStateMenu, ticketTabTitle,
  type FleetMachine, type RequirementRevisionEntry,
} from './ticketModel';
import { TicketDecisionBlock, type TicketDecisionActions, type TicketDecisionSubmission } from './TicketDecisionBlock';
import { TicketAgentsCard } from './TicketAgentsCard';
import { TicketRequirementsCard } from './TicketRequirementsCard';
import { TicketLinkedCard } from './TicketLinkedCard';
import { TicketAttemptsCard } from './TicketAttemptsCard';
import { TicketChangesCard, type TicketChangesProps } from './TicketChangesCard';
import { TicketDetailsCard, type TicketDetailsActions, type TicketDetailsPlacement } from './TicketDetailsCard';
import { TicketCard, TicketSkeleton } from './TicketCard';

/** Below this width the side column stacks above the main column (REQ-T3). */
export const TICKET_TWO_COLUMN_MIN_PX = 900;

export type TicketFocus = 'decision' | 'requirement_changes' | null | undefined;
/** An editor to open once the ticket is shown (a board card's Edit menu). */
export type TicketEditFocus = 'requirements' | Exclude<TaskEditField, 'details'>;

/** The edit fields origin/main offers from the More menu. */
export const DEFAULT_TICKET_EDIT_FIELDS: readonly TaskEditField[] = ['assignee', 'reviewers', 'deps'];

export interface TicketRecheckResult { changed?: boolean; actions?: string[]; reasons?: string[]; message?: string }

/** Every change the ticket tab can make; optional ones are offered only when present. */
export interface TicketViewActions extends TicketDecisionActions, TicketDetailsActions {
  busy: boolean;
  /** The last action's failure, shown under the header and in the open dialog. */
  error: string;
  hold: (reason: string) => Promise<boolean>;
  release: () => Promise<boolean>;
  cancel: () => Promise<boolean>;
  reopen: () => Promise<boolean>;
  recheck?: () => Promise<TicketRecheckResult | null>;
  /** Deletes the ticket (offered only while it may be deleted). */
  remove?: () => Promise<boolean>;
  amendRequirements: RequirementsEditorModalProps['onAmend'];
  replaceTicket?: RequirementsEditorModalProps['onReplace'];
  /** Resolves to '' once saved, else the error. */
  saveEdit: (change: TaskEditChange) => Promise<string>;
}

/** A requirement history the caller reads (instead of the Hub's preformatted text). */
export interface TicketRequirementHistory {
  entries: RequirementRevisionEntry[] | null;
  loading?: boolean;
  error?: string;
  /** Ask for it (the Changes view or the Requirement changes tab opened). */
  onNeed: () => void;
}

export interface TicketViewProps {
  chainId: string;
  taskId: string;
  /** The ticket; null while it loads or once it is gone. */
  task: TaskWire | null;
  loading: boolean;
  /** Every ticket of the chain (order, linked tickets, the dependency picker). */
  tickets: TaskWire[];
  keys: Map<string, string>;
  names: TaskNames;
  actions: TicketViewActions;
  /** The chain's fleet rows (who works on and reviews it). */
  fleets?: any[];
  /** Agents for the Agents card; empty when no fleet machines are known. */
  machines?: FleetMachine[];
  placement: TicketDetailsPlacement;
  /** The chain is a workflow run's: people and requirements are set by the run. */
  workflowOwned?: boolean;
  chainKind?: string;
  /** Nothing can change (owner offline, chain completed): no actions are offered. */
  readOnly?: boolean;
  /** The More menu's editors (default: assignee, reviewers, dependencies). */
  editFields?: readonly TaskEditField[];
  agents?: TaskEditAgent[];
  roles?: TaskEditRole[];
  /** Absent: the history is parsed from task.requirements.history (the Hub text). */
  requirementHistory?: TicketRequirementHistory;
  /** A ticket without requirements may get its first ones. */
  allowFirstRequirements?: boolean;
  activity: TicketActivityFeeds;
  changes: Omit<TicketChangesProps, 'attemptNo'>;
  /** The attempt under review, for the decision block. */
  submission?: TicketDecisionSubmission;
  reviewable?: boolean;
  upload?: TaskComposerUpload;
  isMobile?: boolean;
  /** Transient section to reveal once (decision block / requirement changes). */
  focus?: TicketFocus;
  onFocusConsumed?: () => void;
  editFocus?: TicketEditFocus | null;
  onEditFocusConsumed?: () => void;
  /** Breadcrumb "Tickets" and Back: focus the board. */
  onShowBoard: () => void;
  /** Linked tickets, Replaces / Replaced by: open or focus that ticket's tab. */
  onOpenTicket: (taskId: string, title: string) => void;
  /** Previous / next: show another ticket in this same tab. */
  onSwitchTicket: (taskId: string, title: string) => void;
  /** Agent rows: that agent's conversation in Main. */
  onOpenAgent: (instanceId: string, name: string) => void;
  /** The tab's title once the ticket is known ("T-21 Bridges auto-update"). */
  onTitle?: (title: string) => void;
}

/** The ticket's link in the app (Copy link): opens this ticket tab. */
export function ticketLink(chainId: string, taskId: string): string {
  return buildRouteHash(`/chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`, '');
}

/** Decrypts vault tokens inside the hub's preformatted history text (gap G1). */
function useOpenHistory(text: string): string {
  const unlocked = useSelector(selectIsVaultUnlocked);
  const [open, setOpen] = useState(text);
  useEffect(() => {
    let live = true;
    if (!text || !unlocked || !containsVaultArmored(text)) {
      setOpen(text);
      return;
    }
    decryptEmbeddedVaultTokens(text)
      .then((t) => live && setOpen(t))
      .catch(() => live && setOpen(text));
    return () => {
      live = false;
    };
  }, [text, unlocked]);
  return open;
}

/** Width of an element, for the two-column breakpoint (the aux pane is narrower than the window). */
function useElementWidth(el: HTMLElement | null): number {
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    if (!el || typeof ResizeObserver === 'undefined') return;
    setWidth(el.getBoundingClientRect().width);
    const ro = new ResizeObserver((entries) => setWidth(entries[0]?.contentRect.width || 0));
    ro.observe(el);
    return () => ro.disconnect();
  }, [el]);
  return width;
}

/**
 * One ticket in its own aux tab, Jira style (REQ-T1..T8): toolbar, title and
 * state, the decision block when it needs you, then Requirements, Linked
 * tickets, Attempts, Changes and Activity, with the state, Agents and Details in
 * a side column once the tab is wide enough.
 */
export const TicketView: React.FC<TicketViewProps> = ({
  chainId, taskId, task, loading, tickets, keys, names, actions, fleets = [], machines = [], placement, workflowOwned: workflowChain = false,
  chainKind = '', readOnly = false, editFields = DEFAULT_TICKET_EDIT_FIELDS, agents, roles, requirementHistory, allowFirstRequirements = false,
  activity, changes, submission, reviewable, upload, isMobile = false, focus, onFocusConsumed, editFocus, onEditFocusConsumed,
  onShowBoard, onOpenTicket, onSwitchTicket, onOpenAgent, onTitle,
}) => {
  // A callback ref: the root mounts only once the ticket has loaded.
  const [rootEl, setRootEl] = useState<HTMLDivElement | null>(null);
  const width = useElementWidth(rootEl);
  const wide = !isMobile && width >= TICKET_TWO_COLUMN_MIN_PX;
  const now = useTicketClock();
  const reducedMotion = usePrefersReducedMotion();
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);
  const dispatch = useDispatch();

  const [holdOpen, setHoldOpen] = useState(false);
  const [editing, setEditing] = useState<TaskEditField | null>(null);
  const [reqEditorOpen, setReqEditorOpen] = useState(false);
  const [activityTab, setActivityTab] = useState<ActivityTab>('all');
  const [reqView, setReqView] = useState<'current' | 'changes'>('current');
  const [detailsOpen, setDetailsOpen] = useState(true);
  const [highlight, setHighlight] = useState(false);
  const decisionRef = useRef<HTMLDivElement>(null);
  const activityRef = useRef<HTMLDivElement>(null);
  const shownRevision = useRef<number | null>(null);

  const openHistory = useOpenHistory(requirementHistory ? '' : String(task?.requirements?.history || ''));
  const parsedHistory = useMemo(() => parseRequirementsHistory(openHistory), [openHistory]);
  const history = requirementHistory ? requirementHistory.entries : parsedHistory;
  const needHistory = () => requirementHistory?.onNeed();

  // REQ-T1 click map: Approve / Answer open the tab at its decision block; a
  // requirement-change line opens Activity › Requirement changes.
  useEffect(() => {
    if (!focus || !task) return;
    if (focus === 'decision') decisionRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
    if (focus === 'requirement_changes') {
      setActivityTab('requirements');
      requestAnimationFrame(() => activityRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' }));
    }
    onFocusConsumed?.();
  }, [focus, Boolean(task)]); // eslint-disable-line react-hooks/exhaustive-deps

  // A board card's Edit menu: open that editor once the ticket is shown.
  useEffect(() => {
    if (!editFocus || !task || readOnly) return;
    if (editFocus === 'requirements') setReqEditorOpen(true);
    else setEditing(editFocus);
    onEditFocusConsumed?.();
  }, [editFocus, Boolean(task), readOnly]); // eslint-disable-line react-hooks/exhaustive-deps

  // A requirement change arrives as a task update: when the revision moves under
  // an open tab, say so and highlight the card for 3 s (not under reduced motion).
  const revision = Number(task?.requirements?.revision) || 0;
  const [changedUnderYou, setChangedUnderYou] = useState(false);
  useEffect(() => {
    if (!revision) return;
    if (shownRevision.current !== null && revision > shownRevision.current) {
      setChangedUnderYou(true);
      if (!reducedMotion) {
        setHighlight(true);
        const t = setTimeout(() => setHighlight(false), 3000);
        shownRevision.current = revision;
        return () => clearTimeout(t);
      }
    }
    shownRevision.current = revision;
  }, [revision, reducedMotion]);

  const order = useMemo(() => boardOrder(tickets), [tickets]);
  const position = ticketPosition(order, taskId);
  const key = keyFor(keys, taskId);
  const titleOf = (id: string) => ticketTabTitle(keyFor(keys, id), tickets.find((t) => t.task_id === id)?.title || '');

  const go = (id: string | null) => {
    if (!id) return;
    onSwitchTicket(id, titleOf(id));
  };
  // j / k on desktop move between tickets (never while typing).
  useEffect(() => {
    if (isMobile) return;
    const el = rootEl;
    if (!el) return;
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
      if (e.key === 'j') go(position.next);
      if (e.key === 'k') go(position.prev);
    };
    el.addEventListener('keydown', onKey);
    return () => el.removeEventListener('keydown', onKey);
  }, [isMobile, rootEl, position.prev, position.next, tickets, keys, onSwitchTicket]); // eslint-disable-line react-hooks/exhaustive-deps

  // A deep-linked tab opens before the ticket loads; give it the real title.
  const tabTitle = task && keys.has(taskId) ? ticketTabTitle(key, task.title) : '';
  useEffect(() => {
    if (tabTitle) onTitle?.(tabTitle);
  }, [tabTitle]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!task) {
    if (loading) return <TicketSkeleton />;
    return (
      <div className="p-6">
        <EmptyState
          icon="tasks"
          title="This ticket isn't in this chain any more"
          description="It may have been deleted, or the link points at another chain."
          action={
            <Button size="sm" variant="secondary" onClick={onShowBoard} data-debug-id="ticket-view-back-to-board-btn">
              Back to Tickets
            </Button>
          }
          data-debug-id="ticket-view-missing"
        />
      </div>
    );
  }

  const state = normalizeTaskState(task.state);
  const finished = isFinishedTask(task);
  const attempt = attemptInfo(task);
  const lease = leaseClock(task, now);
  const hold = taskHold(task);
  const rework = isRework(task);
  const isGate = task.kind === 'gate';
  const workflowOwned = workflowChain || chainKind === 'workflow' || Boolean(task.stage_key) || Boolean(task.workflow_run_id);
  const lock = editLock(task, chainKind);
  // An action is offered only when the caller can run it.
  const available = (a: TaskActionId) => !readOnly && (a !== 'recheck' || Boolean(actions.recheck)) && (a !== 'publish' || Boolean(actions.publish));
  const more = getTaskActions(task).more.filter(available);
  const canChangeRequirements = !readOnly && !workflowOwned && !isGate && !finished;
  const priority = String(task.priority || 'p2').toLowerCase();
  const masked = !vaultUnlocked;
  const b: any = task.blocked_on || {};

  const copy = async (text: string, title: string) => {
    try {
      await navigator.clipboard?.writeText(text);
      dispatch(showToast({ kind: 'success', title, autoDismissMs: 2500 }));
    } catch {
      dispatch(showToast({ kind: 'error', title: 'Copy failed', message: text }));
    }
  };
  const copyLink = () => void copy(`${window.location.origin}${window.location.pathname}${ticketLink(chainId, taskId)}`, 'Link copied');

  const runAction = async (id: TaskActionId | 'remove') => {
    switch (id) {
      case 'publish':
        return void actions.publish?.();
      case 'approve':
        return void actions.approve();
      case 'request_changes':
      case 'answer':
        decisionRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
        return;
      case 'reopen':
        return void actions.reopen();
      case 'recheck': {
        const result = await actions.recheck?.();
        if (result) dispatch(showToast({ ...recheckToast(result), autoDismissMs: 6000 }));
        return;
      }
      case 'hold':
        return setHoldOpen(true);
      case 'release':
        return void actions.release();
      case 'cancel':
        if (window.confirm(`Cancel ${key}?`)) await actions.cancel();
        return;
      case 'remove':
        if (actions.remove && window.confirm(`Delete ${key} “${task.title || task.task_id}”? This cannot be undone.`)) await actions.remove();
        return;
      case 'copy_id':
        return void copy(task.task_id, 'Ticket id copied');
    }
  };

  const stateMenu = ticketStateMenu(task, actions.busy).filter(available);
  const editLabels: Record<TaskEditField, string> = {
    assignee: 'Change assignee',
    reviewers: 'Change reviewers',
    deps: 'Change dependencies',
    details: 'Edit title and description',
  };
  const editMenu: { field: TaskEditField; label: string }[] = readOnly || workflowOwned
    ? []
    : editFields.filter((f) => (f === 'details' ? !finished : !lock.locked)).map((field) => ({ field, label: editLabels[field] }));

  const toolbar = (
    <div
      className={[
        'flex min-h-11 items-center gap-1 border-b border-subtle bg-canvas px-3 py-1.5',
        isMobile ? 'sticky top-0 z-sticky' : '',
      ].join(' ')}
      data-debug-id="ticket-view-toolbar"
    >
      {isMobile ? (
        <>
          <IconButton icon="chevron-left" label="Back to Tickets" variant="ghost" size="md" onClick={onShowBoard} data-debug-id="ticket-view-back-btn" />
          <span className="min-w-0 flex-1 truncate font-mono text-body-sm text-primary">
            {key}
            {position.index >= 0 && <span className="text-muted"> · {position.index + 1} of {position.total}</span>}
          </span>
        </>
      ) : (
        <nav aria-label="Breadcrumb" className="flex min-w-0 flex-1 items-center gap-1 text-body-sm">
          <button type="button" onClick={onShowBoard} data-debug-id="ticket-view-breadcrumb-tickets" className="rounded-sm text-muted hover:text-primary focus-visible:outline-none focus-visible:shadow-focus">
            Tickets
          </button>
          <Icon name="chevron-right" size={12} className="text-faint" />
          <span className="font-mono text-primary" aria-current="page">{key}</span>
          {position.index >= 0 && <span className="ml-2 text-caption tabular-nums text-faint">{position.index + 1} of {position.total}</span>}
        </nav>
      )}
      {!isMobile && (
        <>
          <IconButton icon="chevron-left" label="Previous ticket (k)" variant="ghost" size="sm" disabled={!position.prev} onClick={() => go(position.prev)} data-debug-id="ticket-view-prev-btn" />
          <IconButton icon="chevron-right" label="Next ticket (j)" variant="ghost" size="sm" disabled={!position.next} onClick={() => go(position.next)} data-debug-id="ticket-view-next-btn" />
        </>
      )}
      <IconButton icon="copy" label="Copy link" variant="ghost" size={isMobile ? 'md' : 'sm'} onClick={copyLink} data-debug-id="ticket-view-copy-link-btn" />
      <Menu label={`More actions for ${key}`} align="end" trigger={<IconButton icon="more-horizontal" label="More actions" variant="ghost" size={isMobile ? 'md' : 'sm'} data-debug-id="ticket-view-more-btn" />}>
        {editMenu.map((it) => (
          <Menu.Item key={it.field} data-debug-id={`ticket-view-edit-${it.field}`} onClick={() => setEditing(it.field)}>
            {it.label}
          </Menu.Item>
        ))}
        {!readOnly && !workflowOwned && !finished && actions.pinBridge && (
          <Menu.Item data-debug-id="ticket-view-edit-bridge" onClick={() => setDetailsOpen(true)}>
            Change bridge pin
          </Menu.Item>
        )}
        {more.filter((a) => a !== 'copy_id').map((a) => (
          <Menu.Item key={a} danger={a === 'cancel'} data-debug-id={`ticket-view-menu-${a}`} onClick={() => void runAction(a)}>
            {TASK_ACTION_LABELS[a]}
          </Menu.Item>
        ))}
        {!readOnly && hold && !finished && (
          <Menu.Item data-debug-id="ticket-view-menu-release" onClick={() => void runAction('release')}>
            {TASK_ACTION_LABELS.release}
          </Menu.Item>
        )}
        {!readOnly && actions.remove && (
          <Menu.Item danger data-debug-id="ticket-view-menu-delete" onClick={() => void runAction('remove')}>
            Delete ticket
          </Menu.Item>
        )}
        <Menu.Item data-debug-id="ticket-view-menu-copy_id" onClick={() => void runAction('copy_id')}>
          Copy ID
        </Menu.Item>
      </Menu>
    </div>
  );

  const header = (
    <div className="flex flex-col gap-3" data-debug-id="ticket-view-header">
      <Text as="h2" role="heading" className="break-words font-[family-name:var(--font-display)] text-primary" data-debug-id="ticket-view-title">
        <VaultText value={task.title} fallback="Untitled ticket" />
      </Text>
      <div className="flex flex-wrap items-center gap-2">
        <Menu
          label="Change state"
          trigger={
            <button
              type="button"
              disabled={!stateMenu.length}
              data-debug-id="ticket-view-state-btn"
              className="inline-flex min-h-8 items-center gap-1 rounded-pill focus-visible:outline-none focus-visible:shadow-focus disabled:cursor-default"
            >
              <StatusPill tone={hold ? 'warning' : TASK_STATE_TONE[state]} data-debug-id="ticket-view-state">{hold ? 'Held' : TASK_STATE_LABELS[state]}</StatusPill>
              {stateMenu.length > 0 && <Icon name="chevron-down" size={12} className="text-muted" />}
            </button>
          }
        >
          {stateMenu.map((a) => (
            <Menu.Item key={a} danger={a === 'cancel'} data-debug-id={`ticket-view-state-${a}`} onClick={() => void runAction(a)}>
              {TASK_ACTION_LABELS[a]}
            </Menu.Item>
          ))}
        </Menu>
        <Text as="span" role="body-sm" tone="muted">
          {attempt.label} · {priority.toUpperCase()}
        </Text>
        {rework && <Badge tone="warning">Rework</Badge>}
        {isDraft(task) && <Badge tone="neutral">Draft</Badge>}
        {task.blocked && !hold && !blockedOnYou(task) && <Badge tone="danger" data-debug-id="ticket-view-blocked">Blocked{b.ref ? ` on ${b.ref}` : ''}</Badge>}
        {task.merge?.state === 'pending' && <Badge tone="info" data-debug-id="ticket-view-merge">Merging</Badge>}
        {task.merge?.state === 'conflict' && <Badge tone="danger" data-debug-id="ticket-view-merge">Merge blocked</Badge>}
        {task.merge?.state === 'failed' && <Badge tone="warning" data-debug-id="ticket-view-merge">Merge failed</Badge>}
      </div>
      {workflowOwned ? (
        <Text as="p" role="caption" tone="faint" data-debug-id="ticket-view-workflow-lock">
          The workflow run owns this ticket, so its requirements and people are set by the run.
        </Text>
      ) : readOnly ? null : (
        <div className={`flex gap-2 ${isMobile ? '-mx-4 overflow-x-auto px-4 pb-1' : 'flex-wrap'}`} data-debug-id="ticket-view-quick-actions">
          {finished ? (
            <Button size={isMobile ? 'md' : 'sm'} variant="secondary" onClick={() => void runAction('reopen')} disabled={actions.busy} data-debug-id="ticket-view-reopen-btn">
              Reopen
            </Button>
          ) : (
            <>
              {canChangeRequirements && (
                <Button
                  size={isMobile ? 'md' : 'sm'}
                  variant="secondary"
                  leading={<Icon name="pencil" size="sm" />}
                  disabled={masked}
                  title={masked ? 'Unlock your vault to edit' : undefined}
                  onClick={() => setReqEditorOpen(true)}
                  data-debug-id="ticket-view-change-requirements-btn"
                >
                  Change requirements
                </Button>
              )}
              {hold ? (
                <Button size={isMobile ? 'md' : 'sm'} variant="secondary" onClick={() => void runAction('release')} disabled={actions.busy} data-debug-id="ticket-view-release-btn">
                  Release hold
                </Button>
              ) : more.includes('hold') ? (
                <Button size={isMobile ? 'md' : 'sm'} variant="secondary" leading={<Icon name="stop" size="sm" />} onClick={() => void runAction('hold')} disabled={actions.busy} data-debug-id="ticket-view-hold-btn">
                  Hold
                </Button>
              ) : null}
              {!lock.locked && editFields.includes('deps') && (
                <Button size={isMobile ? 'md' : 'sm'} variant="secondary" leading={<Icon name="git-branch" size="sm" />} onClick={() => setEditing('deps')} data-debug-id="ticket-view-add-dependency-btn">
                  Add dependency
                </Button>
              )}
            </>
          )}
        </div>
      )}
      {actions.error && (
        <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words" data-debug-id="ticket-view-action-error">
          {actions.error}
        </Text>
      )}
    </div>
  );

  const people = getTaskPeople(task, fleets);
  const agentsCard = (
    <TicketAgentsCard task={task} names={names} machines={machines} people={people} now={now} onOpenAgent={onOpenAgent} />
  );

  const detailsCard = (
    <TicketDetailsCard
      task={task}
      chainId={chainId}
      keys={keys}
      placement={placement}
      open={detailsOpen}
      onToggle={() => setDetailsOpen((o) => !o)}
      actions={actions}
      now={now}
      locked={readOnly || workflowOwned || finished}
      onOpenTicket={(id) => onOpenTicket(id, titleOf(id))}
      onCopy={copy}
    />
  );

  const composer = readOnly ? undefined : (
    <TaskComposer
      debugId="comment-composer"
      rows={1}
      placeholder={masked ? 'Unlock your vault to comment' : 'Add a comment'}
      disabled={actions.busy || masked}
      upload={upload}
      renderActions={({ body, canSend, reset }) => (
        <Button
          size="sm"
          variant="secondary"
          disabled={!canSend}
          data-debug-id="ticket-view-comment-send-btn"
          onClick={async () => {
            if (await actions.comment(body)) reset();
          }}
        >
          Comment
        </Button>
      )}
    />
  );

  const goal = String(task.brief?.goal || '');
  const description = String(task.description || '');
  const mainColumn = (
    <div className="flex min-w-0 flex-col gap-5">
      {changedUnderYou && (
        <div data-debug-id="ticket-view-requirements-changed-notice">
          <Alert tone="info" title={`Requirements changed to rev ${revision}`} onDismiss={() => setChangedUnderYou(false)}>
            <button type="button" data-debug-id="ticket-view-see-what-changed-notice" className="text-accent underline" onClick={() => { setActivityTab('requirements'); needHistory(); }}>
              See what changed
            </button>
          </Alert>
        </div>
      )}
      {!readOnly && (
        <div ref={decisionRef}>
          <TicketDecisionBlock task={task} actions={actions} names={names} now={now} submission={submission} reviewable={reviewable} />
        </div>
      )}
      {/* A ticket's own description, when its goal does not already say it. */}
      {description && description.trim() !== goal.trim() && (
        <TicketCard title="Description" debugId="ticket-view-description">
          <DecryptedMarkdown source={description} compact copyAll={false} />
        </TicketCard>
      )}
      <TicketRequirementsCard
        task={task}
        history={history}
        names={names}
        now={now}
        view={reqView}
        onViewChange={(v) => { setReqView(v); if (v === 'changes') needHistory(); }}
        highlight={highlight}
        canEdit={canChangeRequirements}
        masked={masked}
        onChange={() => setReqEditorOpen(true)}
        onSeeChanges={() => {
          setActivityTab('requirements');
          needHistory();
          activityRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
        }}
      />
      <TicketLinkedCard task={task} tasks={tickets} keys={keys} onOpenTicket={(id) => onOpenTicket(id, titleOf(id))} />
      <TicketAttemptsCard task={task} names={names} lease={lease} />
      <TicketChangesCard attemptNo={attempt.no} {...changes} />
      <div ref={activityRef}>
        <TicketActivity
          task={task}
          names={names}
          now={now}
          history={history}
          rawHistory={openHistory}
          tab={activityTab}
          onTabChange={setActivityTab}
          feeds={{
            ...activity,
            requirementsLoading: requirementHistory?.loading,
            requirementsError: requirementHistory?.error,
            onOpen: (tab) => { if (tab === 'requirements') needHistory(); activity.onOpen?.(tab); },
          }}
          composer={!isMobile ? composer : undefined}
        />
      </div>
    </div>
  );

  return (
    <div ref={setRootEl} tabIndex={-1} data-debug-id={`ticket-view-${taskId}`} className="flex h-full min-h-0 flex-col bg-canvas text-left outline-none">
      {toolbar}
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={`mx-auto flex w-full flex-col gap-5 p-4 sm:p-5 ${wide ? 'max-w-6xl' : ''}`}>
          {masked && <VaultLockedBanner debugId="ticket-view-vault-locked" editing />}
          {header}
          {wide ? (
            <div className="grid grid-cols-[minmax(0,1fr)_18rem] gap-6">
              {mainColumn}
              <aside className="flex flex-col gap-4" data-debug-id="ticket-view-side-column">
                {agentsCard}
                {detailsCard}
              </aside>
            </div>
          ) : (
            <>
              <div className="flex flex-col gap-4" data-debug-id="ticket-view-side-column">
                {agentsCard}
              </div>
              {mainColumn}
              {detailsCard}
            </>
          )}
        </div>
      </div>
      {isMobile && composer && (
        <div className="sticky bottom-0 z-sticky border-t border-subtle bg-canvas p-3" data-debug-id="ticket-view-sticky-composer">
          {composer}
        </div>
      )}

      <TaskEditModal
        task={task}
        field={editing}
        onClose={() => setEditing(null)}
        onSave={actions.saveEdit}
        tasks={tickets}
        agents={agents}
        roles={roles}
        names={names}
      />
      <HoldReasonDialog ticketKey={key} open={holdOpen} busy={actions.busy} error={holdOpen ? actions.error : ''} onHold={actions.hold} onClose={() => setHoldOpen(false)} />
      <RequirementsEditorModal
        open={reqEditorOpen}
        onClose={() => setReqEditorOpen(false)}
        task={task}
        keys={keys}
        names={names}
        onAmend={actions.amendRequirements}
        onReplace={actions.replaceTicket}
        allowFirstRevision={allowFirstRequirements}
      />
    </div>
  );
};

export default TicketView;
