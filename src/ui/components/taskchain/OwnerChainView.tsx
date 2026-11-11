// The ordinary chain view for a Bridge-owned chain (R4b). Everything shown
// past the registry metadata is read from the owner Bridge with signed,
// encrypted owner operations; every change is one signed owner command. When
// the owner is offline only the registry metadata (decrypted titles) shows,
// with an explicit offline state. The raw method console (OwnerLocalPanel)
// stays reachable behind "Advanced/debug".

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Badge, Button, EmptyState, FormField, Input, StatusDot, StatusPill, Text, Textarea } from '@ui';
import {
  freshOwnerSession, isOwnerOffline, ownerCall, ownerErrorMessage, ownerOfflineMessage, ownerRelaySend, ownerTaskState,
  ownerActivityLabel, ownerExpectedRevision, readArchivedReviews, readOwnerActivity, readOwnerRequirementHistory, readOwnerChain, readOwnerChainStatus, readOwnerFleetPolicies, readOwnerHandoffs, readOwnerReviews, ownerFleetPolicyDocument, readOwnerRuntime, readOwnerDependencies, readOwnerSubmission, readOwnerTask, readOwnerTaskActivity, readOwnerWorkRevision,
  type OwnerActivity, type OwnerRequirementChange, type OwnerChainDetail, type OwnerChainStatus, type OwnerDependency, type OwnerChainSummary, type OwnerReview, type OwnerRuntime, type OwnerSend,
  type OwnerSubmission, type OwnerTaskDetail, type OwnerFleetPolicy, type OwnerFleetPolicyChange,
} from '../../api/ownerChains';
import { ownerId, type OwnerInput, type OwnerSession } from '../../api/ownerLocalClient';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import type { OwnerCommand } from '../../api/ownerLocal';
import { buildTaskNames } from '../tasks/taskNames';
import { ticketKeys } from '../tasks/ticketModel';
import type { TicketDecisionActions } from '../tasks/TicketDecisionBlock';
import {
  ownerCommentItems, ownerDependencyChanges, ownerHandoffItems, ownerPrerequisites, ownerRequirementHistoryEntries, ownerRequirementsDoc, ownerReviewItems, ownerRunBridgeDoc, ownerRunBridgeOptions, ownerAgentModelDoc, ownerAgentModels,
  ownerTicketEvents, ownerTaskWire, ownerTaskWires,
} from '../tasks/ownerTaskAdapter';
import { TicketView, type TicketEditFocus, type TicketViewActions } from '../tasks/TicketView';
import type { TaskEditChange, TaskEditField as TicketEditField } from '../tasks/TaskEditModal';
import type { TicketFeed, TicketEventItem, TicketHandoffItem } from '../tasks/TicketActivity';
import type { BoardTicketActions } from '../tasks/BoardTicketCard';
import ChainOverviewPanel, { type ChainOverviewActions, type ChainOverviewMember, type ChainOverviewPanelProps } from '../chat/ChainOverviewPanel';
import { TaskChainOverview, type TaskChainCreateActions } from './TaskChainOverview';
import { ownerAgentOptions, ownerAttention, ownerCreateTaskPlan, ownerOverviewMembers, ownerTaskNames } from '../tasks/ownerChainAdapter';
import type { TaskWire } from '../../api/taskWire';
import type { OwnerTicketEditFocus } from '../../store/auxTabId';
import type { TaskEditField } from '../tasks/BoardTicketCard';
import OwnerLocalPanel from './OwnerLocalPanel';
import OwnerCoordinatorControl, { hubCoordinatorApi, type OwnerCoordinatorApi } from './OwnerCoordinatorControl';
import OwnerAddAgentControl, { type ChainAgentRole } from './OwnerAddAgentControl';
import OwnerFleetTable from './OwnerFleetTable';
import { ownerChainById, resolveOwnerChainCoordinator, setOwnerChainCoordinator } from '../../api/ownerChainsStore';
import { bindOwnerCoordinator, readOwnerChainMembers, type OwnerChainMember } from '../../api/ownerCoordinator';

const RUNTIME_LIMIT = 50;
/** The board card Edit menu: reviewers live in the requirements (reviewer ids + your approval). */
const OWNER_EDIT_FIELDS: readonly TaskEditField[] = ['requirements', 'reviewers', 'deps'];
/** The ticket tab's More menu: reviewers (requirements), dependencies, and title and description (task.edit). */
const OWNER_TICKET_EDIT_FIELDS: readonly TicketEditField[] = ['reviewers', 'deps', 'details'];
/** A board card's editor focus as the ticket tab's editor. */
const EDIT_FOCUS: Record<OwnerTicketEditFocus, TicketEditFocus> = { edit_requirements: 'requirements', edit_reviewers: 'reviewers', edit_deps: 'deps' };

/** What a background refresh compares to decide whether the open ticket changed. */
function runtimeKey(rt: OwnerRuntime | undefined): string {
  if (!rt) return '';
  return [rt.revision, rt.lifecycle, rt.leased, rt.holder, rt.control?.mode ?? '', rt.attemptNo, rt.submission?.attempt ?? ''].join('|');
}

function formatWhen(value: string): string {
  if (!value) return '';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function principalLabel(session: OwnerSession | null, principal: string): string {
  if (!principal) return 'Unknown';
  if (session && principal === session.identity.deviceId) return 'You';
  const device = session?.chain.trusted.get(principal);
  if (device) return String(device.row.label || (device.kind === 'browser' ? 'Browser' : device.kind));
  if (/^(inst|agt)_/.test(principal)) return principal;
  if (session && principal === session.identity.userId) return 'You';
  return 'Device ' + principal.slice(0, 8);
}

interface TaskView {
  taskId: string;
  detail: OwnerTaskDetail;
  runtime: OwnerRuntime;
  reviews: OwnerReview[];
  /** The review history scan is still running; the ticket renders meanwhile. */
  reviewsLoading: boolean;
  reviewsError: string;
  /** The history scan hit its page cap: newer owner reviews may be missing. */
  reviewsTruncated: boolean;
  /** Older owner reviews were left out (only the latest are kept). */
  reviewsMore: boolean;
}

/**
 * `page` (the Task Chains page): origin/main's chain board (TaskChainOverview);
 * a ticket opens in place of the board. The aux panes of a coordinator
 * conversation show one part each: `overview` (origin/main's
 * ChainOverviewPanel: agents, attention, ongoing tickets, activity), `board`
 * (TaskChainOverview) and `ticket` (one ticket); their ticket clicks open
 * ticket tabs via onOpenTicket.
 */
export type OwnerChainLayout = 'page' | 'overview' | 'board' | 'ticket';

export interface OwnerChainViewProps {
  chain: OwnerChainSummary;
  layout?: OwnerChainLayout;
  /** Aux layouts: a ticket click opens it (the page selects it in place). */
  onOpenTicket?: (taskId: string, title: string) => void;
  /** Board layout (aux): a card's Edit menu opens the ticket with that editor. */
  onEditTicket?: (taskId: string, title: string, focus: OwnerTicketEditFocus) => void;
  /** Open this editor once the focused ticket loads; reported consumed once. */
  editFocus?: OwnerTicketEditFocus | null;
  onEditFocusConsumed?: () => void;
  /** Ticket layout: back to the board, and prev / next in the same tab. */
  onShowBoard?: () => void;
  onSwitchTicket?: (taskId: string, title: string) => void;
  /** An agent (member or lease holder) was clicked. */
  onOpenAgent?: (instanceId: string, title?: string) => void;
  /** Ticket layout: the ticket's title once read. */
  onTitle?: (title: string) => void;
  /** Re-read the owner this often (ms) while the page is visible; 0 = only on Refresh. */
  refreshMs?: number;
  focusTaskId?: string;
  submissionAttempt?: string;
  onClose?: () => void;
  /** Extra sections under the description (the page passes the chain's token usage); the overview shows it as its token usage section. */
  extra?: React.ReactNode;
  /** Overview layout: what the aux host adds to the chain overview (project VCS, terminals, the conversation's agent). */
  overview?: Pick<ChainOverviewPanelProps, 'vcs' | 'onOpenFileDiff' | 'onOpenVcsFiles' | 'onOpenAgentPty' | 'agentInstanceId'>;
  /** The owner relay; tests replace it. */
  send?: OwnerSend;
  /** Session provider; tests replace it. */
  session?: () => Promise<OwnerSession>;
  /** Hub calls of Start coordinator; tests replace them. */
  coordinatorApi?: OwnerCoordinatorApi;
  /** The account's Bridges (run-Bridge choices); tests replace the Hub list. */
  bridges?: any[];
}

export function OwnerChainView({
  chain, layout = 'page', onOpenTicket, onEditTicket, editFocus, onEditFocusConsumed, onShowBoard, onSwitchTicket, onOpenAgent, onTitle, refreshMs = 0,
  focusTaskId, submissionAttempt, onClose, extra, overview, send: sendProp = ownerRelaySend, session: sessionProp = freshOwnerSession, coordinatorApi, bridges: bridgesProp,
}: OwnerChainViewProps) {
  const bridge = chain.ownerBridgeId;
  // The account's Bridges: a ticket's run Bridge may be any of them.
  const bridgesQuery = useListBridgesQuery(undefined, { skip: Boolean(bridgesProp) });
  const accountBridges: any[] = useMemo(() => bridgesProp ?? bridgesQuery.data?.bridges ?? [], [bridgesProp, bridgesQuery.data]);
  const runBridgeOptions = useMemo(() => ownerRunBridgeOptions(accountBridges, bridge, chain.bridgeName), [accountBridges, bridge, chain.bridgeName]);
  // Injected transports are read through refs so a caller's inline function
  // never re-triggers the loads.
  const sendRef = useRef(sendProp); sendRef.current = sendProp;
  const sessionPropRef = useRef(sessionProp); sessionPropRef.current = sessionProp;
  const send: OwnerSend = useCallback((relay: unknown) => sendRef.current(relay), []);
  const sessionOf = useCallback(() => sessionPropRef.current(), []);
  const [offline, setOffline] = useState(!chain.online && !chain.pending);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [detail, setDetail] = useState<OwnerChainDetail | null>(null);
  const [chainStatus, setChainStatus] = useState<OwnerChainStatus>(chain.status ?? '');
  const [states, setStates] = useState<Record<string, OwnerRuntime>>({});
  const [members, setMembers] = useState<OwnerChainMember[] | null>(null);
  // Hub runtime_status per agent instance (overview agent rows).
  const [agentStatus, setAgentStatus] = useState<Record<string, string>>({});
  // The open ticket's Activity feeds, each read when its tab first opens.
  const [handoffs, setHandoffs] = useState<(TicketFeed<TicketHandoffItem> & { taskId: string }) | null>(null);
  const [taskEvents, setTaskEvents] = useState<(TicketFeed<TicketEventItem> & { taskId: string }) | null>(null);
  const [reqHistory, setReqHistory] = useState<{ taskId: string; changes: OwnerRequirementChange[] | null; error: string; more: boolean } | null>(null);
  // The overview's recent chain history (history.read); null until read.
  const [activity, setActivity] = useState<{ events: OwnerActivity[]; truncated: boolean } | null>(null);
  const [selected, setSelected] = useState(focusTaskId || '');
  const [task, setTask] = useState<TaskView | null>(null);
  const [taskLoading, setTaskLoading] = useState(false);
  const [submission, setSubmission] = useState<OwnerSubmission | null>(null);
  const [submissionState, setSubmissionState] = useState<{ attempt: string; loading: boolean; error: string }>({ attempt: '', loading: false, error: '' });
  const [busy, setBusy] = useState(false);
  const [debug, setDebug] = useState(false);
  // Inline editors: null when closed, else the draft.
  const [chainDraft, setChainDraft] = useState<{ title: string; description: string } | null>(null);
  // Ticket dependencies (work.read), read when a ticket opens; null until read.
  const [deps, setDeps] = useState<{ items: OwnerDependency[]; truncated: boolean } | null>(null);
  // Complete chain: the summary being written (null when the form is closed).
  const [completeSummary, setCompleteSummary] = useState<string | null>(null);
  // undefined while the coordinator is not known yet (never shown as "none").
  const [coordinatorId, setCoordinatorId] = useState<string | undefined>(chain.coordinatorAgentInstanceId);
  useEffect(() => { setCoordinatorId(chain.coordinatorAgentInstanceId); }, [chain.chainId, chain.coordinatorAgentInstanceId]);
  const coordinatorUnknown = coordinatorId === undefined && chain.online && !chain.pending;
  useEffect(() => {
    if (!coordinatorUnknown) return;
    // Shares the snapshot's read when one is in flight; a chain the snapshot
    // does not list resolves here (a failure is recorded on the snapshot).
    let cancelled = false;
    void resolveOwnerChainCoordinator(chain.chainId).then((id) => {
      if (!cancelled && live.current && !ownerChainById(chain.chainId)) setCoordinatorId((prev) => prev ?? id);
    });
    return () => { cancelled = true; };
  }, [coordinatorUnknown, chain.chainId]);
  const sessionRef = useRef<OwnerSession | null>(null);
  // The latest loadTask call; an older call's review scan never overwrites it.
  const taskLoadSeq = useRef(0);
  // The last refused change, worded (the ticket dialogs show it).
  const lastError = useRef({ message: '', stale: false });
  // The ticket whose event feed is open: a re-read of that ticket refreshes it.
  const eventsFor = useRef('');
  const live = useRef(true);
  useEffect(() => () => { live.current = false; }, []);

  const fail = useCallback((e: unknown) => {
    if (!live.current) return;
    if (isOwnerOffline(e)) { setOffline(true); setError(''); return; }
    setError(ownerErrorMessage(e, chain.bridgeName));
  }, [chain.bridgeName]);

  const session = useCallback(async () => {
    const s = await sessionOf();
    sessionRef.current = s;
    return s;
  }, [sessionOf]);

  // `quiet` (background refresh) keeps the list as is instead of showing loading.
  const loadChain = useCallback(async (quiet = false): Promise<{ detail: OwnerChainDetail; states: Record<string, OwnerRuntime> } | null> => {
    if (!quiet) setLoading(true);
    try {
      const s = await session();
      const [d, status] = await Promise.all([
        readOwnerChain(s, bridge, chain.chainId, send),
        readOwnerChainStatus(s, bridge, chain.chainId, send).catch((e) => { if (isOwnerOffline(e)) throw e; return '' as OwnerChainStatus; }),
      ]);
      if (!live.current) return;
      setOffline(false); setDetail(d); setChainStatus(status); setError('');
      // Task states come from one bounded runtime observation per task.
      const next: Record<string, OwnerRuntime> = {};
      const queue = d.tasks.slice(0, RUNTIME_LIMIT).map((t) => t.task_id);
      await Promise.all(Array.from({ length: Math.min(4, queue.length) }, async () => {
        for (let id = queue.shift(); id; id = queue.shift()) {
          try { next[id] = await readOwnerRuntime(s, bridge, chain.chainId, id, send); } catch (e) { if (isOwnerOffline(e)) throw e; }
        }
      }));
      // The overview lists the chain's agents: its member rows.
      if (layout === 'overview') {
        const m = await readOwnerChainMembers(s, bridge, chain.chainId, send).catch((e) => { if (isOwnerOffline(e)) throw e; return null; });
        if (live.current) setMembers(m);
      }
      if (live.current) setStates(next);
      return { detail: d, states: next };
    } catch (e) { fail(e); return null; } finally { if (live.current && !quiet) setLoading(false); }
  }, [bridge, chain.chainId, send, session, fail, layout]);

  // A ticket's Activity events (its history.read events), newest first.
  const loadEvents = useCallback(async (taskId: string) => {
    eventsFor.current = taskId;
    setTaskEvents((cur) => (cur?.taskId === taskId ? { ...cur, loading: true } : { taskId, items: null, loading: true }));
    try {
      const r = await readOwnerTaskActivity(await session(), bridge, chain.chainId, taskId, send);
      if (live.current) setTaskEvents((cur) => (cur?.taskId === taskId ? { taskId, items: ownerTicketEvents(r.events), truncated: r.truncated, loading: false } : cur));
    } catch (e) {
      if (isOwnerOffline(e)) fail(e);
      if (live.current) setTaskEvents((cur) => (cur?.taskId === taskId ? { ...cur, loading: false, error: ownerErrorMessage(e, chain.bridgeName) } : cur));
    }
  }, [bridge, chain.chainId, chain.bridgeName, send, session, fail]);

  // The ticket (brief, comments, runtime) renders as soon as it is read; the
  // review history scan, which may page through the whole chain history, fills
  // in the reviews afterwards with its own loading state.
  const loadTask = useCallback(async (taskId: string) => {
    const seq = ++taskLoadSeq.current;
    if (!taskId) { setTask(null); return; }
    setTaskLoading(true);
    let s: OwnerSession;
    try {
      s = await session();
      const [d, rt] = await Promise.all([readOwnerTask(s, bridge, chain.chainId, taskId, send), readOwnerRuntime(s, bridge, chain.chainId, taskId, send)]);
      if (!live.current || seq !== taskLoadSeq.current) return;
      // A reload of the same ticket keeps its reviews visible while they refresh.
      setTask((prev) => prev && prev.taskId === taskId
        ? { ...prev, detail: d, runtime: rt, reviewsLoading: true }
        : { taskId, detail: d, runtime: rt, reviews: [], reviewsLoading: true, reviewsError: '', reviewsTruncated: false, reviewsMore: false });
      setStates((prev) => ({ ...prev, [taskId]: rt }));
      if (eventsFor.current === taskId) void loadEvents(taskId);
    } catch (e) { fail(e); return; } finally { if (live.current && seq === taskLoadSeq.current) setTaskLoading(false); }
    let reviews: OwnerReview[] = [], reviewsError = '', reviewsTruncated = false, reviewsMore = false;
    try {
      const [archived, owned] = await Promise.all([readArchivedReviews(s, bridge, chain.chainId, taskId, send), readOwnerReviews(s, bridge, chain.chainId, taskId, send)]);
      reviews = [...owned.reviews, ...archived];
      reviewsTruncated = owned.truncated; reviewsMore = owned.more;
    } catch (e) {
      // A failed scan never leaves "Loading reviews…" behind: an offline owner
      // also switches the view to its offline state, and the (current) ticket
      // keeps a worded reviews error for when it is shown again.
      if (isOwnerOffline(e) && seq === taskLoadSeq.current) fail(e);
      reviewsError = ownerErrorMessage(e, chain.bridgeName);
    }
    if (!live.current || seq !== taskLoadSeq.current) return;
    setTask((prev) => prev && prev.taskId === taskId ? { ...prev, reviews, reviewsLoading: false, reviewsError, reviewsTruncated, reviewsMore } : prev);
  }, [bridge, chain.chainId, chain.bridgeName, send, session, fail, loadEvents]);

  // One attempt's submission (the ticket's Changes); a failed read stays in the card.
  const openSubmission = useCallback(async (taskId: string, attempt: string) => {
    setSubmissionState({ attempt, loading: true, error: '' });
    try {
      const s = await session();
      const sub = await readOwnerSubmission(s, bridge, chain.chainId, taskId, attempt, send);
      if (live.current) { setSubmission(sub); setSubmissionState({ attempt, loading: false, error: '' }); }
    } catch (e) {
      if (isOwnerOffline(e)) fail(e);
      if (live.current) setSubmissionState({ attempt, loading: false, error: ownerErrorMessage(e, chain.bridgeName) });
    }
  }, [bridge, chain.chainId, chain.bridgeName, send, session, fail]);

  useEffect(() => { if (chain.online || chain.pending) void loadChain(); }, [chain.chainId, chain.online, chain.pending, loadChain]);
  useEffect(() => {
    setSubmission(null); setSubmissionState({ attempt: '', loading: false, error: '' });
    eventsFor.current = '';
    if (selected && !offline) void loadTask(selected);
  }, [selected]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (focusTaskId && submissionAttempt && !offline) void openSubmission(focusTaskId, submissionAttempt);
  }, [focusTaskId, submissionAttempt]); // eslint-disable-line react-hooks/exhaustive-deps

  // Background refresh (aux panes): owner chains have no push events, so the
  // chain is re-read on an interval while the page is visible and the owner is
  // reachable; the open ticket is re-read only when its revision or runtime moved.
  const pollState = useRef({ offline, busy, selected, task });
  pollState.current = { offline, busy, selected, task };
  useEffect(() => {
    if (!refreshMs || !(chain.online || chain.pending)) return;
    let running = false;
    const timer = setInterval(() => {
      const p = pollState.current;
      if (running || p.offline || p.busy || (typeof document !== 'undefined' && document.visibilityState === 'hidden')) return;
      running = true;
      void loadChain(true).then((r) => {
        const cur = pollState.current;
        if (!r || !cur.selected || !live.current) return;
        const row = r.detail.tasks.find((t) => t.task_id === cur.selected);
        const loaded = cur.task?.taskId === cur.selected ? cur.task : null;
        if (!loaded || (row && row.revision !== loaded.detail.revision) || (r.states[cur.selected] && runtimeKey(r.states[cur.selected]) !== runtimeKey(loaded.runtime))) {
          return loadTask(cur.selected);
        }
      }).finally(() => { running = false; });
    }, refreshMs);
    return () => clearInterval(timer);
  }, [refreshMs, chain.online, chain.pending, loadChain, loadTask]);

  // `taskRevision` names the revision of a ticket that is not the open one
  // (board card actions); the open ticket's revision is used otherwise.
  async function mutate(method: OwnerCommand['method'], input: Omit<OwnerInput, 'chainId' | 'expectedRevision'>, done: string, taskRevisionOverride?: string, reloadTask = true): Promise<boolean> {
    setBusy(true); setError(''); setNotice('');
    lastError.current = { message: '', stale: false };
    try {
      const s = await session();
      // Task-scoped methods are checked against the task revision, everything
      // else (task.create included) against the chain revision.
      const taskRevision = taskRevisionOverride ?? (input.taskId && task?.taskId === input.taskId ? task.detail.revision : '0');
      const expectedRevision = ownerExpectedRevision(method, detail?.revision ?? '0', taskRevision);
      await ownerCall(s, bridge, method, { chainId: chain.chainId, expectedRevision, ...input }, send);
      if (!live.current) return true;
      setNotice(done);
      await loadChain();
      // Only the open ticket is re-read: task.create names a new task that is
      // not selected, and loading it would show it under another selection.
      if (reloadTask && input.taskId && input.taskId === selected) await loadTask(input.taskId);
      return true;
    } catch (e) {
      fail(e);
      lastError.current = { message: isOwnerOffline(e) ? ownerOfflineMessage(chain.bridgeName) : ownerErrorMessage(e, chain.bridgeName), stale: e instanceof Error && e.message === 'stale_revision' };
      if (e instanceof Error && e.message === 'stale_revision') { await loadChain(); if (input.taskId && input.taskId === selected) await loadTask(input.taskId); }
      return false;
    } finally { if (live.current) setBusy(false); }
  }

  const loadDeps = useCallback(async () => {
    try {
      const d = await readOwnerDependencies(await session(), bridge, chain.chainId, send);
      if (live.current) setDeps(d);
    } catch (e) {
      if (live.current) setDeps(null);
      if (isOwnerOffline(e)) fail(e);
    }
  }, [bridge, chain.chainId, send, session, fail]);
  const showsTicket = layout === 'page' || layout === 'ticket';
  // Only once the owner answered the chain read: an offline owner is asked nothing.
  const ownerReady = !offline && Boolean(detail);
  // The overview's Activity is re-read when the chain, a ticket or a ticket's
  // runtime changed, not on every background poll.
  const activityKey = layout === 'overview' && ownerReady && detail
    ? [detail.revision, ...detail.tasks.map((t) => t.revision), ...Object.keys(states).sort().map((id) => runtimeKey(states[id]))].join('|') : '';
  useEffect(() => {
    if (!activityKey) return;
    let cancelled = false;
    void (async () => {
      try {
        const a = await readOwnerActivity(await session(), bridge, chain.chainId, send);
        if (!cancelled && live.current) setActivity(a);
      } catch (e) { if (isOwnerOffline(e)) fail(e); }
    })();
    return () => { cancelled = true; };
  }, [activityKey, bridge, chain.chainId, send, session, fail]);
  useEffect(() => { if (showsTicket && selected && ownerReady) void loadDeps(); }, [showsTicket, selected, ownerReady, loadDeps]);
  // The ticket names its agents from the chain's member rows, read once (the overview re-reads them with the chain).
  useEffect(() => {
    if (!showsTicket || !ownerReady || members !== null) return;
    let cancelled = false;
    void (async () => {
      try {
        const m = await readOwnerChainMembers(await session(), bridge, chain.chainId, send);
        if (!cancelled && live.current) setMembers(m);
      } catch (e) { if (isOwnerOffline(e)) fail(e); }
    })();
    return () => { cancelled = true; };
  }, [showsTicket, ownerReady, members, bridge, chain.chainId, send, session, fail]);

  async function addDependency(taskId: string, prerequisite: string): Promise<boolean> {
    const doc = { dependency_id: ownerId('dep_'), dependent: { kind: 'task', id: taskId }, prerequisite: { kind: 'task', id: prerequisite } };
    const ok = await mutate('work.dependency.add', { body: JSON.stringify(doc) }, 'Dependency added.');
    if (ok) await loadDeps();
    return ok;
  }
  async function removeDependency(dependencyId: string): Promise<boolean> {
    const ok = await mutate('work.dependency.remove', { body: JSON.stringify({ dependency_id: dependencyId, reason: 'Removed from the ticket page' }) }, 'Dependency removed.');
    if (ok) await loadDeps();
    return ok;
  }

  // chain.complete names the owner's current work revision (work.read).
  async function completeChain(summary: string): Promise<boolean> {
    let workRevision: string;
    try {
      workRevision = await readOwnerWorkRevision(await session(), bridge, chain.chainId, send);
    } catch (e) {
      fail(e);
      return false;
    }
    return mutate('chain.complete', { body: JSON.stringify({ expected_work_revision: workRevision, summary }) }, 'Chain completed.');
  }

  const hubApi = coordinatorApi ?? hubCoordinatorApi;
  const hubApiRef = useRef(hubApi); hubApiRef.current = hubApi;
  // Each member row's instance status, re-read whenever the members are.
  const readAgentStatus = useCallback(async (ids: string[]) => {
    const next: Record<string, string> = {};
    await Promise.all(ids.map(async (id) => { next[id] = await hubApiRef.current.status(id).catch(() => ''); }));
    if (live.current) setAgentStatus((prev) => ({ ...prev, ...next }));
  }, []);
  useEffect(() => {
    if (layout !== 'overview' || offline || !members) return;
    const ids = members.filter((m) => m.enabled).map((m) => m.instanceId);
    if (ids.length) void readAgentStatus(ids);
  }, [layout, offline, members, readAgentStatus]);

  // Agent display names (Hub agents list), read once per view.
  const [agentNames, setAgentNames] = useState<Record<string, string>>({});
  useEffect(() => {
    if (offline) return;
    let cancelled = false;
    Promise.resolve().then(() => hubApiRef.current.listAgents()).then((list) => {
      if (!cancelled && live.current) setAgentNames(Object.fromEntries(list.map((a) => [a.agentId, a.name])));
    }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [layout, offline]);

  // Fleet rows (fleet.policy.read) for the board's fleet slot, re-read when the
  // chain revision changes: every fleet.policy.set bumps it.
  const [fleet, setFleet] = useState<{ rows: OwnerFleetPolicy[] | null; error: string }>({ rows: null, error: '' });
  const fleetKey = (layout === 'page' || layout === 'board') && !offline && detail ? detail.revision : '';
  useEffect(() => {
    if (!fleetKey) return;
    let cancelled = false;
    (async () => {
      try {
        const rows = await readOwnerFleetPolicies(await session(), bridge, chain.chainId, send);
        if (!cancelled && live.current) setFleet({ rows, error: '' });
      } catch (e) {
        if (!cancelled && live.current) setFleet((f) => ({ rows: f.rows, error: f.rows ? '' : ownerErrorMessage(e) }));
      }
    })();
    return () => { cancelled = true; };
  }, [fleetKey, bridge, chain.chainId, send, session]);
  function saveFleet(row: OwnerFleetPolicy, change: OwnerFleetPolicyChange): Promise<boolean> {
    let body: string;
    try { body = ownerFleetPolicyDocument(row, change); } catch (e) { setError(e instanceof Error ? e.message : String(e)); return Promise.resolve(false); }
    const done = change.paused === true ? 'Fleet row paused.' : change.paused === false ? 'Fleet row resumed.' : 'Fleet row saved.';
    return mutate('fleet.policy.set', { body }, done);
  }

  // Start / stop / restart a chain agent's instance through the Hub.
  async function agentRuntime(instanceId: string, action: 'start' | 'stop' | 'restart') {
    const call = action === 'restart' ? hubApi.restart : hubApi[action];
    if (!call) return;
    setBusy(true); setError(''); setNotice('');
    try {
      await call(instanceId);
      if (!live.current) return;
      setAgentStatus((prev) => ({ ...prev, [instanceId]: action === 'stop' ? 'stopping' : 'launching' }));
      setNotice(action === 'stop' ? 'Stopping the agent.' : action === 'start' ? 'Starting the agent.' : 'Restarting the agent.');
    } catch (e) {
      if (live.current) setError(e instanceof Error ? e.message : String(e));
    } finally { if (live.current) setBusy(false); }
  }

  // Removes a worker or reviewer from the chain: its member row is disabled
  // (the coordinator is replaced, never removed). Its instance keeps running.
  function removeAgent(a: Pick<ChainOverviewMember, 'instanceId' | 'agentId' | 'role'>) {
    if (!window.confirm(`Remove ${a.instanceId} from this chain? Its instance keeps running until you stop it.`)) return Promise.resolve(false);
    return mutate('chain.member.set', { instanceId: a.instanceId, agentId: a.agentId, memberRole: a.role || 'worker', enabled: false }, 'Agent removed from the chain.');
  }

  async function showHandoffs(taskId: string) {
    setHandoffs({ taskId, items: null });
    try {
      const h = await readOwnerHandoffs(await session(), bridge, chain.chainId, taskId, send);
      if (live.current) setHandoffs((cur) => (cur?.taskId === taskId ? { taskId, items: ownerHandoffItems(h.handoffs), more: h.more, truncated: h.truncated } : cur));
    } catch (e) {
      if (isOwnerOffline(e)) fail(e);
      if (live.current) setHandoffs((cur) => (cur?.taskId === taskId ? { taskId, items: [], error: ownerErrorMessage(e, chain.bridgeName) } : cur));
    }
  }

  async function showRequirementHistory(taskId: string) {
    setReqHistory({ taskId, changes: null, error: '', more: false });
    try {
      const h = await readOwnerRequirementHistory(await session(), bridge, chain.chainId, taskId, send);
      if (live.current) setReqHistory((prev) => prev?.taskId === taskId ? { taskId, changes: h.changes, error: '', more: h.more || h.truncated } : prev);
    } catch (e) {
      if (isOwnerOffline(e)) fail(e);
      if (live.current) setReqHistory((prev) => prev?.taskId === taskId ? { taskId, changes: [], error: ownerErrorMessage(e, chain.bridgeName), more: false } : prev);
    }
  }

  // chain.member.set for an added worker or reviewer, against the chain
  // revision read right before binding (the launch wait may outlast the loaded one).
  const bindMember = useCallback(async (instanceId: string, agentId: string, role: ChainAgentRole) => {
    const s = await session();
    const { revision } = await readOwnerChain(s, bridge, chain.chainId, send);
    await ownerCall(s, bridge, 'chain.member.set', { chainId: chain.chainId, expectedRevision: revision, instanceId, agentId, memberRole: role }, send);
  }, [bridge, chain.chainId, send, session]);
  const memberAdded = useCallback((instanceId: string, role: ChainAgentRole) => {
    if (!live.current) return;
    setNotice(`Added ${instanceId} as ${role}.`);
    void loadChain(true);
  }, [loadChain]);

  // chain.member.set role=coordinator (and demotion of a replaced one).
  const bindCoordinator = useCallback(async (instanceId: string, agentId: string) => {
    await bindOwnerCoordinator(await session(), bridge, chain.chainId, instanceId, agentId, send);
  }, [bridge, chain.chainId, send, session]);

  const coordinatorBound = useCallback((instanceId: string) => {
    if (!live.current) return;
    setCoordinatorId(instanceId);
    setOwnerChainCoordinator(chain.chainId, instanceId);
    setNotice('Coordinator started and bound.');
    void loadChain();
  }, [chain.chainId, loadChain]);

  const tasks = useMemo(() => {
    if (detail) return detail.tasks.map((t) => ({ taskId: t.task_id, title: t.title, priority: t.priority }));
    return chain.tasks.map((t) => ({ taskId: t.taskId, title: t.title, priority: '' }));
  }, [detail, chain.tasks]);

  const title = detail?.title || chain.title || chain.chainId;
  const description = detail?.description ?? chain.description;
  // The open ticket in the ticket wire shape the restored ticket cards render.
  const wire = useMemo(() => (task ? ownerTaskWire({
    chainId: chain.chainId, bridgeId: bridge, taskId: task.taskId, detail: task.detail, runtime: task.runtime, reviews: task.reviews,
  }) : null), [task, chain.chainId, bridge]);
  // Changes only on a reachable owner whose chain is confirmed active.
  const editable = !offline && Boolean(detail) && chainStatus === 'active';
  const aux = layout !== 'page';
  const showChainInfo = layout === 'page' || layout === 'overview';
  // The page selects a ticket in place; aux panes open it in a ticket tab.
  const openTicket = (taskId: string, ticketTitle: string) => {
    if (aux) onOpenTicket?.(taskId, ticketTitle || taskId); else setSelected(taskId);
  };

  // The board's ticket wires, keys and per-ticket card actions (owner commands).
  const boardWires = useMemo(() => (detail ? ownerTaskWires(chain.chainId, bridge, detail.tasks, states) : []), [detail, states, chain.chainId, bridge]);
  const boardKeys = useMemo(() => ticketKeys(boardWires), [boardWires]);
  // The overview's agent rows and the names every ticket view resolves with.
  const overviewMembers = useMemo(() => (layout === 'overview'
    ? ownerOverviewMembers({ members, coordinatorId, tasks: boardWires, agentNames, agentStatus }) : []), [layout, members, coordinatorId, boardWires, agentNames, agentStatus]);
  const names = useMemo(() => (layout === 'overview'
    ? ownerTaskNames(boardWires, overviewMembers, agentNames)
    : buildTaskNames({
      tasks: boardWires,
      identities: Object.entries(agentNames).map(([agent_id, name]) => ({ agent_id, name })),
      members: (members ?? []).map((m) => ({ agentInstanceId: m.instanceId, agentId: m.agentId })),
    })), [layout, boardWires, overviewMembers, agentNames, members]);
  // Linked tickets: the owner's dependencies (work.read), not the brief, say what waits for what.
  const linkedWires = useMemo(() => {
    if (!deps) return boardWires;
    const waits = new Map<string, string[]>();
    for (const d of deps.items) waits.set(d.dependent, [...(waits.get(d.dependent) ?? []), d.prerequisite]);
    return boardWires.map((w) => ({ ...w, depends_on: waits.get(w.task_id) ?? [] }));
  }, [boardWires, deps]);
  const boardActions = (t: TaskWire): BoardTicketActions => {
    const revision = detail?.tasks.find((r) => r.task_id === t.task_id)?.revision ?? '0';
    const run = (method: OwnerCommand['method'], done: string, body = '') => mutate(method, { taskId: t.task_id, body }, done, revision);
    return {
      busy: busy || offline || !editable,
      error: '',
      hold: (reason) => (reason.trim() ? run('task.hold', 'Ticket held.', reason.trim()) : Promise.resolve(false)),
      release: () => run('task.release', 'Hold released.'),
      cancel: () => run('task.cancel', 'Ticket cancelled.'),
      reopen: () => run('task.reopen', 'Ticket reopened.'),
    };
  };

  // The board's Edit menu: the aux board opens a ticket tab with the editor;
  // the page selects the ticket in place and the ticket opens that editor.
  const [pendingEdit, setPendingEdit] = useState<OwnerTicketEditFocus | null>(editFocus ?? null);
  function editTicket(taskId: string, title: string, field: TaskEditField) {
    const focus: OwnerTicketEditFocus = field === 'deps' ? 'edit_deps' : field === 'reviewers' ? 'edit_reviewers' : 'edit_requirements';
    if (aux) { onEditTicket?.(taskId, title || taskId, focus); return; }
    setSelected(taskId); setPendingEdit(focus);
  }

  // The decision block's actions as owner commands on the open ticket.
  const decisionActions = (t: TaskView): TicketDecisionActions => {
    const sub = t.runtime.submission;
    const verdict = (v: 'approve' | 'request_changes', body: string) => (sub
      ? mutate('review.post', { taskId: t.taskId, verdict: v, body, attempt: sub.attempt, head: sub.head, requirementsRevision: sub.requirementsRevision },
        v === 'approve' ? 'Approval recorded.' : 'Change request recorded.')
      : Promise.resolve(false));
    return {
      busy: busy || !editable,
      release: () => mutate('task.release', { taskId: t.taskId, body: '' }, 'Hold released.'),
      // The owner review payload needs a summary; Approve carries no note (as on origin/main).
      approve: () => verdict('approve', 'Approved.'),
      requestChanges: (body) => verdict('request_changes', body.trim()),
      comment: (body) => mutate('task.comment', { taskId: t.taskId, body: body.trim() }, 'Comment added.'),
      // An answer is a comment, then task.resolve returns the blocked ticket to ready.
      answer: async (body) => {
        if (!(await mutate('task.comment', { taskId: t.taskId, body: body.trim() }, 'Answer sent.'))) return false;
        try {
          const fresh = await readOwnerTask(await session(), bridge, chain.chainId, t.taskId, send);
          return await mutate('task.resolve', { taskId: t.taskId }, 'Answer sent; the ticket is ready again.', fresh.revision);
        } catch (e) { fail(e); return false; }
      },
    };
  };

  // Every change the ticket tab offers, as owner commands on the open ticket.
  const ticketActions = (t: TaskView, w: TaskWire): TicketViewActions => {
    const run = (method: OwnerCommand['method'], done: string, body = '') => mutate(method, { taskId: t.taskId, body }, done);
    const failure = (ok: boolean) => (ok ? '' : lastError.current.message || 'The change was not saved.');
    const flags = ownerTaskState(t.runtime);
    const req = t.runtime.requirements;
    const reqRevision = Number(req?.revision) || 0;
    // requirements.edit replaces the whole document: fields not edited are kept.
    const saveRequirements = async (edit: { goal: string; acceptance: string[]; reviewers: string[]; requiresUserApproval: boolean; reason: string }) => {
      const body = ownerRequirementsDoc(req?.raw ?? '', edit);
      const ok = await mutate('requirements.edit', { taskId: t.taskId, body, requirementsRevision: String(reqRevision + 1) }, 'Requirements updated.');
      if (ok && reqHistory?.taskId === t.taskId) void showRequirementHistory(t.taskId);
      return ok;
    };
    const reviewers = w.brief?.reviewers ?? [];
    return {
      ...decisionActions(t),
      error,
      hold: (reason) => (reason.trim() ? run('task.hold', 'Ticket held.', reason.trim()) : Promise.resolve(false)),
      release: () => run('task.release', 'Hold released.'),
      cancel: () => run('task.cancel', 'Ticket cancelled.'),
      reopen: () => run('task.reopen', 'Ticket reopened.'),
      // Only an unstarted ticket (no attempt, no lease) may be deleted.
      remove: flags.state === 'ready' && t.runtime.attemptNo === 0 && !t.runtime.holder
        ? async () => {
          const ok = await mutate('task.delete', { taskId: t.taskId }, 'Ticket deleted.', undefined, false);
          if (ok && live.current) {
            setSelected(''); setTask(null);
            if (layout === 'ticket') onShowBoard?.();
          }
          return ok;
        }
        : undefined,
      setPriority: async (priority) => failure(await mutate('task.priority', { taskId: t.taskId, priority: priority as 'p0' | 'p1' | 'p2' }, 'Priority updated.')),
      amendRequirements: async (a) => {
        // The draft was based on an older revision: keep it beside the newer one.
        if (a.baseRevision !== reqRevision) return { error: 'The requirements changed.', conflict: true };
        const ok = await saveRequirements({ goal: a.goal, acceptance: a.acceptance, reviewers, requiresUserApproval: Boolean(req?.requiresUserApproval), reason: a.reason });
        return ok ? { error: '' } : { error: lastError.current.message || 'The requirements were not saved.', conflict: lastError.current.stale };
      },
      saveEdit: async (change: TaskEditChange) => {
        if (change.field === 'reviewers') {
          // Reviewers and your approval live in the requirements document.
          if (!req) return 'Add requirements first: the reviewers are part of them.';
          return failure(await saveRequirements({ goal: req.goal, acceptance: req.acceptance, reviewers: change.reviewers, requiresUserApproval: change.requiresUserApproval, reason: 'Changed the reviewers.' }));
        }
        if (change.field === 'deps') {
          if (!deps) return 'The dependencies are still loading.';
          const plan = ownerDependencyChanges(t.taskId, deps.items, change.dependsOn);
          for (const id of plan.add) if (!(await addDependency(t.taskId, id))) return failure(false);
          for (const id of plan.remove) if (!(await removeDependency(id))) return failure(false);
          return '';
        }
        if (change.field === 'details') {
          return failure(await mutate('task.edit', { taskId: t.taskId, title: change.title, body: change.description }, 'Ticket updated.'));
        }
        return 'The assignee of a Bridge-owned ticket is set by its fleet.';
      },
      // The run Bridge lives in the brief (run_bridge_id); the owner Bridge clears it.
      pinBridge: async (bridgeId: string) => {
        if (!req) { setError('Add requirements first: the run Bridge is part of them.'); return false; }
        if (bridgeId === (w.bridge_id || bridge)) return true;
        const ok = await mutate('requirements.edit', { taskId: t.taskId, body: ownerRunBridgeDoc(req.raw ?? '', bridgeId, bridge), requirementsRevision: String(reqRevision + 1) }, 'Run Bridge updated.');
        if (ok && reqHistory?.taskId === t.taskId) void showRequirementHistory(t.taskId);
        return ok;
      },
      // Per-agent provider/model override (brief agent_models): beats the fleet for this task.
      setAgentModel: async (agentId: string, value: string) => {
        if (!req) { setError('Add requirements first: the model overrides are part of them.'); return false; }
        const ok = await mutate('requirements.edit', { taskId: t.taskId, body: ownerAgentModelDoc(req.raw ?? '', agentId, value), requirementsRevision: String(reqRevision + 1) }, 'Model override updated.');
        if (ok && reqHistory?.taskId === t.taskId) void showRequirementHistory(t.taskId);
        return ok;
      },
    };
  };

  // New ticket (origin/main's CreateTaskModal): task.create, then its brief
  // (requirements.edit, revision 1) and what it waits for (work.dependency.add),
  // each against the revision read right before it.
  async function createTicket(input: Parameters<TaskChainCreateActions['create']>[0]): Promise<string> {
    const plan = ownerCreateTaskPlan(input);
    const taskId = ownerId('task_');
    let created = false;
    setBusy(true); setError(''); setNotice('');
    try {
      const s = await session();
      const { revision } = await readOwnerChain(s, bridge, chain.chainId, send);
      await ownerCall(s, bridge, 'task.create', { chainId: chain.chainId, expectedRevision: revision, taskId, title: plan.task.title, body: plan.task.body }, send);
      created = true;
      if (plan.requirements) {
        const t = await readOwnerTask(s, bridge, chain.chainId, taskId, send);
        await ownerCall(s, bridge, 'requirements.edit', { chainId: chain.chainId, expectedRevision: t.revision, taskId, body: plan.requirements, requirementsRevision: '1' }, send);
      }
      for (const prerequisite of plan.dependsOn) {
        const { revision: chainRevision } = await readOwnerChain(s, bridge, chain.chainId, send);
        const doc = { dependency_id: ownerId('dep_'), dependent: { kind: 'task', id: taskId }, prerequisite: { kind: 'task', id: prerequisite } };
        await ownerCall(s, bridge, 'work.dependency.add', { chainId: chain.chainId, expectedRevision: chainRevision, body: JSON.stringify(doc) }, send);
      }
      if (live.current) setNotice('Ticket created.');
      return '';
    } catch (e) {
      if (isOwnerOffline(e)) fail(e);
      const message = ownerErrorMessage(e, chain.bridgeName);
      return created ? `The ticket was created, but its brief or what it waits for was not saved: ${message}` : message;
    } finally {
      if (live.current) setBusy(false);
      if (created) void loadChain(true);
    }
  }
  const createActions: TaskChainCreateActions | undefined = editable
    ? {
      agentOptions: ownerAgentOptions(agentNames),
      create: createTicket,
      // The owner Bridge is the default: '' pins nothing.
      bridgeOptions: runBridgeOptions.map((o) => (o.value === bridge ? { ...o, value: '' } : o)),
    }
    : undefined;

  // The chain overview's actions: agent runtime through the Hub, removal and
  // your review as owner commands.
  const overviewActions: ChainOverviewActions = {
    busy: busy || offline,
    start: (id) => agentRuntime(id, 'start'),
    stop: (id) => agentRuntime(id, 'stop'),
    restart: (id) => agentRuntime(id, 'restart'),
    remove: editable ? (m) => removeAgent(m) : undefined,
    loadDescription: async (taskId) => (await readOwnerTask(await session(), bridge, chain.chainId, taskId, send)).body,
    review: editable ? async (taskId, verdict, comment) => {
      const sub = states[taskId]?.submission;
      if (!sub) return false;
      const revision = detail?.tasks.find((r) => r.task_id === taskId)?.revision ?? '0';
      return mutate('review.post', { taskId, verdict, body: comment || (verdict === 'approve' ? 'Approved.' : ''), attempt: sub.attempt, head: sub.head, requirementsRevision: sub.requirementsRevision },
        verdict === 'approve' ? 'Approval recorded.' : 'Change request recorded.', revision);
    } : undefined,
  };
  const attention = useMemo(() => ownerAttention(states), [states]);
  const openOverviewAgent = onOpenAgent ? (instanceId: string, title?: string) => onOpenAgent(instanceId, title) : undefined;

  // The overview's recent chain history (history.read), its Activity section.
  const activityList = activity ? (
    <div aria-label="Activity" data-debug-id="owner-chain-activity" className="space-y-1.5">
      {activity.events.length === 0 ? <EmptyState data-debug-id="owner-chain-no-activity" title="No activity yet" description="Changes to the chain and its tickets appear here." />
        : (
          <ul className="space-y-1">
            {activity.events.map((e) => {
              const title = e.taskId ? (tasks.find((t) => t.taskId === e.taskId)?.title || e.taskId) : '';
              return (
                <li key={e.seq} data-debug-id={`owner-chain-activity-${e.seq}`} className="flex min-w-0 flex-wrap items-baseline gap-x-1.5">
                  <Text as="span" role="body-sm">{principalLabel(sessionRef.current, e.actorId)}</Text>
                  <Text as="span" role="body-sm" tone="muted">{ownerActivityLabel(e.kind)}</Text>
                  {title && (
                    <button type="button" data-debug-id={`owner-chain-activity-ticket-${e.seq}`} onClick={() => openTicket(e.taskId, title)}
                      className="min-w-0 truncate text-body-sm text-accent hover:underline">{title}</button>
                  )}
                  {e.at && <Text as="span" role="caption" tone="faint" className="ml-auto">{formatWhen(e.at)}</Text>}
                </li>
              );
            })}
          </ul>
        )}
      {activity.truncated && <Text as="p" role="caption" tone="muted">Older activity is not shown.</Text>}
    </div>
  ) : null;

  // origin/main's ticket tab over the owner-local reads and owner commands.
  const ticketWire = useMemo(() => (wire && deps ? { ...wire, depends_on: ownerPrerequisites(wire.task_id, deps.items) } : wire), [wire, deps]);
  const ticketTickets = useMemo(() => (ticketWire ? linkedWires.map((w) => (w.task_id === ticketWire.task_id ? ticketWire : w)) : linkedWires), [linkedWires, ticketWire]);
  const agentChoices = useMemo(() => Object.entries(agentNames).map(([agentId, name]) => ({ agentId, name })), [agentNames]);
  // The task's agents (assignee, reviewers, and any agent with an override) with their override.
  const ticketAgentModels = (raw: string, w: TaskWire) => {
    const overrides = ownerAgentModels(raw);
    const listed: unknown = w.brief?.reviewers ?? w.reviewers;
    const briefReviewers: string[] = Array.isArray(listed) ? listed.filter((x): x is string => typeof x === 'string') : [];
    const assignee = typeof w.assignee === 'string' ? w.assignee : '';
    const ids: string[] = [assignee, ...briefReviewers, ...Object.keys(overrides)].filter((id, i, all) => id !== '' && all.indexOf(id) === i);
    return ids.map((agent) => ({ agent, label: agentNames[agent] || agent, value: overrides[agent] ?? '' }));
  };
  const commentAuthor = (principal: string) => (/^inst_/.test(principal) && names.instance(principal)) || principalLabel(sessionRef.current, principal);
  const attemptCount = task ? Math.max(task.runtime.attemptNo, Number(task.runtime.submission?.attempt ?? 0)) : 0;
  const ticketView = task && ticketWire && task.taskId === selected ? (
    <TicketView
      key={task.taskId}
      chainId={chain.chainId}
      taskId={task.taskId}
      task={ticketWire}
      loading={taskLoading}
      tickets={ticketTickets}
      keys={boardKeys}
      names={names}
      actions={ticketActions(task, ticketWire)}
      placement={{
        bridge: runBridgeOptions.find((o) => o.value === (ticketWire.bridge_id || bridge))?.text || ticketWire.bridge_id || chain.bridgeName || bridge,
        model: '',
        bridgeOptions: runBridgeOptions.some((o) => o.value === ticketWire.bridge_id) ? runBridgeOptions : [...runBridgeOptions, { value: ticketWire.bridge_id, text: ticketWire.bridge_id }],
        agentModels: ticketAgentModels(task.runtime.requirements?.raw ?? '', ticketWire),
      }}
      readOnly={!editable}
      editFields={OWNER_TICKET_EDIT_FIELDS}
      agents={agentChoices}
      allowFirstRequirements
      requirementHistory={{
        entries: reqHistory?.taskId === task.taskId && reqHistory.changes ? ownerRequirementHistoryEntries(reqHistory.changes) : null,
        loading: reqHistory?.taskId === task.taskId && reqHistory.changes === null,
        error: reqHistory?.taskId === task.taskId ? reqHistory.error : '',
        onNeed: () => { if (reqHistory?.taskId !== task.taskId) void showRequirementHistory(task.taskId); },
      }}
      activity={{
        comments: { items: ownerCommentItems(task.detail.comments, commentAuthor), more: task.detail.truncated },
        events: taskEvents?.taskId === task.taskId ? taskEvents : { items: null },
        handoffs: handoffs?.taskId === task.taskId ? handoffs : { items: null },
        reviews: {
          items: task.reviewsLoading && !task.reviews.length ? null : ownerReviewItems(task.reviews),
          loading: task.reviewsLoading, error: task.reviewsError, truncated: task.reviewsTruncated, more: task.reviewsMore,
        },
        onOpen: (tab) => {
          if ((tab === 'all' || tab === 'raw') && eventsFor.current !== task.taskId) void loadEvents(task.taskId);
          if (tab === 'handoffs' && handoffs?.taskId !== task.taskId) void showHandoffs(task.taskId);
        },
      }}
      changes={{
        changes: submission ? {
          attempt: Number(submission.attempt) || 0, files: [], output: submission.summary || (submission.head ? 'No summary.' : ''), head: submission.head,
          author: submission.author ? names.participant(submission.author) || submission.author : '',
        } : null,
        loading: submissionState.loading,
        error: submissionState.error,
        attempts: Array.from({ length: attemptCount }, (_, i) => i + 1),
        focusAttempt: focusTaskId === task.taskId && submissionAttempt ? Number(submissionAttempt) || null : null,
        onLoad: (n) => {
          // An attempt that never started has no submission to read.
          if (n > attemptCount) { setSubmission({ attempt: String(n), summary: '', head: '', author: '', requirementsRevision: '', complete: true }); return; }
          if (submission?.attempt !== String(n)) void openSubmission(task.taskId, String(n));
        },
      }}
      submission={task.runtime.submission ? { summary: task.runtime.submission.summary, head: task.runtime.submission.head } : undefined}
      reviewable={ownerTaskState(task.runtime).state === 'in_review' && Boolean(task.runtime.submission)}
      editFocus={pendingEdit ? EDIT_FOCUS[pendingEdit] : null}
      onEditFocusConsumed={() => { setPendingEdit(null); onEditFocusConsumed?.(); }}
      onShowBoard={() => (layout === 'ticket' ? onShowBoard?.() : setSelected(''))}
      onOpenTicket={(id, ticketTitle) => openTicket(id, ticketTitle)}
      onSwitchTicket={(id, ticketTitle) => (layout === 'ticket' && onSwitchTicket ? onSwitchTicket(id, ticketTitle) : setSelected(id))}
      onOpenAgent={(id, name) => onOpenAgent?.(id, name)}
      onTitle={layout === 'ticket' ? onTitle : undefined}
    />
  ) : taskLoading || (selected && !offline && !task) ? <Text as="p" role="body-sm" tone="muted" aria-live="polite" className="p-4">Loading ticket…</Text> : null;

  return (
    <div data-debug-id="owner-chain-view" className="flex h-full min-w-0 flex-col overflow-y-auto text-left">
      <header className="flex flex-wrap items-start justify-between gap-2 border-b border-subtle px-4 py-3">
        <div className="min-w-0">
          <Text as="h2" role="heading" truncate data-debug-id="owner-chain-title">{title}</Text>
          <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted">
            <Badge tone="info" data-debug-id="owner-chain-owner-badge">Bridge-owned</Badge>
            <span className="inline-flex items-center gap-1.5" data-debug-id="owner-chain-bridge-state">
              <StatusDot size="sm" tone={offline ? 'neutral' : 'success'} label={offline ? 'Owner offline' : 'Owner online'} />
              {chain.bridgeName} · {offline ? 'offline' : 'online'}
            </span>
            {!offline && detail && (
              <StatusPill tone={chainStatus === 'active' ? 'info' : chainStatus === 'completed' ? 'success' : 'neutral'} data-debug-id="owner-chain-status">
                {chainStatus === 'active' ? 'Active' : chainStatus === 'completed' ? 'Completed' : 'Status unknown'}
              </StatusPill>
            )}
            {chain.migrated && <Badge tone="neutral">Moved from Hub</Badge>}
            {chain.pending && <Badge tone="pending">Registering</Badge>}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {editable && showChainInfo && !chainDraft && (
            <Button size="sm" variant="ghost" data-debug-id="owner-chain-edit" disabled={busy} onClick={() => setChainDraft({ title, description: description ?? '' })}>Edit chain</Button>
          )}
          {editable && showChainInfo && completeSummary === null && (
            <Button size="sm" variant="ghost" data-debug-id="owner-chain-complete" disabled={busy} onClick={() => setCompleteSummary('')}>Complete chain</Button>
          )}
          <Button size="sm" variant="ghost" data-debug-id="owner-chain-refresh" disabled={loading || busy} onClick={() => { setOffline(false); void loadChain(); if (selected) void loadTask(selected); }}>Refresh</Button>
          <Button size="sm" variant="ghost" data-debug-id="owner-chain-debug-toggle" aria-pressed={debug} onClick={() => setDebug((v) => !v)}>Advanced/debug</Button>
          {onClose && <Button size="sm" variant="ghost" data-debug-id="owner-chain-close" onClick={onClose}>Close</Button>}
        </div>
      </header>

      {editable && chainDraft && (
        <form data-debug-id="owner-chain-edit-form" className="mx-4 mt-3 space-y-2 rounded-lg border border-subtle bg-surface-raised p-3" onSubmit={(e) => {
          e.preventDefault();
          if (!chainDraft.title.trim()) return;
          void mutate('chain.edit', { title: chainDraft.title.trim(), description: chainDraft.description.trim() }, 'Chain updated.').then((ok) => { if (ok) setChainDraft(null); });
        }}>
          <FormField label="Title">
            <Input size="sm" data-debug-id="owner-chain-edit-title" value={chainDraft.title} onChange={(v) => setChainDraft((d) => d && { ...d, title: v })} />
          </FormField>
          <FormField label="Description">
            <Textarea size="sm" rows={3} data-debug-id="owner-chain-edit-description" value={chainDraft.description} onChange={(v) => setChainDraft((d) => d && { ...d, description: v })} />
          </FormField>
          <div className="flex gap-2">
            <Button size="sm" type="submit" variant="primary" data-debug-id="owner-chain-edit-save" disabled={busy || !chainDraft.title.trim()}>Save</Button>
            <Button size="sm" type="button" variant="ghost" disabled={busy} onClick={() => setChainDraft(null)}>Cancel</Button>
          </div>
        </form>
      )}
      {editable && completeSummary !== null && (
        <form data-debug-id="owner-chain-complete-form" className="mx-4 mt-3 space-y-2 rounded-lg border border-subtle bg-surface-raised p-3" onSubmit={(e) => {
          e.preventDefault();
          if (!completeSummary.trim()) return;
          void completeChain(completeSummary.trim()).then((ok) => { if (ok) setCompleteSummary(null); });
        }}>
          <FormField label="Summary" hint="What the chain delivered. Completing makes the chain read-only.">
            <Textarea size="sm" rows={3} data-debug-id="owner-chain-complete-summary" value={completeSummary} onChange={(v) => setCompleteSummary(v)} />
          </FormField>
          <div className="flex gap-2">
            <Button size="sm" type="submit" variant="primary" data-debug-id="owner-chain-complete-save" disabled={busy || !completeSummary.trim()}>Complete chain</Button>
            <Button size="sm" type="button" variant="ghost" disabled={busy} onClick={() => setCompleteSummary(null)}>Cancel</Button>
          </div>
        </form>
      )}
      {offline && (
        <div data-debug-id="owner-chain-offline" className="mx-4 mt-3"><Alert tone="warning">{ownerOfflineMessage(chain.bridgeName)}</Alert></div>
      )}
      {/* A ticket tab shows a failed change under the ticket's header instead. */}
      {error && !(layout === 'ticket' && ticketWire) && <div data-debug-id="owner-chain-error" className="mx-4 mt-3"><Alert tone="danger">{error}</Alert></div>}
      {notice && !error && <Text as="p" role="caption" tone="muted" aria-live="polite" data-debug-id="owner-chain-notice" className="mx-4 mt-3">{notice}</Text>}
      {!offline && detail && chainStatus !== 'active' && (
        <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-readonly" className="mx-4 mt-3">
          {chainStatus === 'completed' ? 'This chain is completed; it is read-only.' : 'The chain’s status could not be read; changes are unavailable.'}
        </Text>
      )}
      {!offline && detail && showChainInfo && (
        <div className="mx-4 mt-3">
          <OwnerCoordinatorControl
            chainId={chain.chainId}
            ownerBridgeId={bridge}
            coordinatorId={coordinatorId ?? (chain.pending ? '' : undefined)}
            lookupFailed={chain.coordinatorReadFailed}
            disabled={!editable || busy}
            bind={bindCoordinator}
            onBound={coordinatorBound}
            api={coordinatorApi}
          />
        </div>
      )}
      {chain.sealed && <Text as="p" role="caption" tone="muted" className="mx-4 mt-3">Some titles are sealed with a key this device does not hold.</Text>}

      {showChainInfo && description ? <Text as="p" role="body-sm" tone="muted" data-debug-id="owner-chain-description" className="whitespace-pre-wrap px-4 pt-3">{description}</Text> : null}
      {showChainInfo && extra && layout !== 'overview' ? <div className="px-4 pt-3">{extra}</div> : null}

      {offline && layout !== 'ticket' && (
        // An offline owner answers nothing: the registry still names the tickets.
        <section aria-label="Tickets" data-debug-id={`owner-chain-tickets-${layout}`} className="p-4">
          <ul className="space-y-1.5">
            {tasks.map((t) => (
              <li key={t.taskId} data-debug-id={`owner-chain-task-${t.taskId}`} className="rounded-[var(--radius-lg)] border border-subtle bg-surface-raised px-3 py-2">
                <Text as="span" role="body-sm" truncate>{t.title || t.taskId}</Text>
              </li>
            ))}
          </ul>
        </section>
      )}

      {layout === 'overview' && !offline && (
        // origin/main's aux Chain overview over the owner reads (ownerChainAdapter).
        <div data-debug-id="owner-chain-overview" className="pt-2">
          <ChainOverviewPanel
            className="flex min-h-0 flex-col"
            members={overviewMembers}
            membersLoading={members === null && loading}
            tasks={boardWires}
            names={names}
            loading={loading && !detail}
            actions={overviewActions}
            attention={attention}
            agentInstanceId={overview?.agentInstanceId}
            agentsAction={detail
              ? <OwnerAddAgentControl chainId={chain.chainId} ownerBridgeId={bridge} disabled={busy} bind={bindMember} onAdded={memberAdded} api={coordinatorApi} />
              : undefined}
            activitySlot={activityList ?? undefined}
            tokenUsageSlot={extra}
            vcs={overview?.vcs}
            onSelectTask={(taskId) => openTicket(taskId, boardWires.find((w) => w.task_id === taskId)?.title ?? '')}
            onOpenFileDiff={overview?.onOpenFileDiff}
            onOpenVcsFiles={overview?.onOpenVcsFiles}
            onOpenAgentChat={openOverviewAgent}
            onOpenAgentPty={overview?.onOpenAgentPty}
          />
        </div>
      )}

      {(layout === 'board' || (layout === 'page' && !selected)) && !offline && (detail || loading) && (
        // origin/main's chain board over the owner reads (ownerTaskAdapter).
        <div data-debug-id={`owner-chain-tickets-${layout}`} className="min-w-0">
          <TaskChainOverview
            chainId={chain.chainId}
            title={title}
            hideTitleBar
            tasks={boardWires}
            keys={boardKeys}
            names={names}
            loading={loading && !detail}
            actionsFor={boardActions}
            editFields={OWNER_EDIT_FIELDS}
            fleetSlot={<OwnerFleetTable rows={fleet.rows} error={fleet.error} names={agentNames} editable={editable} busy={busy} save={saveFleet} />}
            onOpenTicket={(taskId, ticketTitle) => openTicket(taskId, boardWires.find((w) => w.task_id === taskId)?.title || ticketTitle)}
            onEditTicket={(taskId, field) => editTicket(taskId, boardWires.find((w) => w.task_id === taskId)?.title ?? '', field)}
            create={createActions}
          />
          {detail?.truncated && <Text as="p" role="caption" tone="muted" className="px-4">Showing the first {detail.tasks.length} tickets.</Text>}
        </div>
      )}

      {(layout === 'ticket' || (layout === 'page' && selected)) && <div className="grid min-h-0 flex-1 gap-4 p-4">

        {(layout === 'page' || layout === 'ticket') && <section aria-label="Ticket details" data-debug-id="owner-chain-task-detail" className="min-w-0">
          {offline ? null : !selected ? (
            <EmptyState title="No ticket selected" description="Select a ticket to see its requirements, activity and changes." />
          ) : ticketView}
        </section>}
      </div>}

      {debug && (
        <OwnerLocalPanel initialChainId={chain.chainId} initialBridgeId={bridge} initialTaskId={selected || undefined}
          initialSubmissionAttempt={submission?.attempt} onClose={() => setDebug(false)} />
      )}
    </div>
  );
}

export default OwnerChainView;
