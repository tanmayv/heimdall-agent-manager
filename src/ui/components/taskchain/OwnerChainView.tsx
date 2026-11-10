// The ordinary chain view for a Bridge-owned chain (R4b). Everything shown
// past the registry metadata is read from the owner Bridge with signed,
// encrypted owner operations; every change is one signed owner command. When
// the owner is offline only the registry metadata (decrypted titles) shows,
// with an explicit offline state. The raw method console (OwnerLocalPanel)
// stays reachable behind "Advanced/debug".

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Badge, Button, Checkbox, EmptyState, FormField, IconButton, Input, Select, StatusDot, StatusPill, Text, Textarea, type Tone } from '@ui';
import {
  freshOwnerSession, isOwnerOffline, ownerAwaitingUser, ownerCall, ownerErrorMessage, ownerOfflineMessage, ownerRelaySend, ownerTaskState,
  ownerActivityLabel, ownerExpectedRevision, readArchivedReviews, readOwnerActivity, readOwnerRequirementHistory, readOwnerChain, readOwnerChainStatus, readOwnerFleetPolicies, readOwnerReviews, ownerFleetPolicyDocument, readOwnerRuntime, readOwnerDependencies, readOwnerSubmission, readOwnerTask, readOwnerWorkRevision, withOwnerRecovery,
  type OwnerActivity, type OwnerRequirementChange, type OwnerChainDetail, type OwnerChainStatus, type OwnerDependency, type OwnerChainSummary, type OwnerReview, type OwnerRuntime, type OwnerSend,
  type OwnerSubmission, type OwnerTaskDetail, type OwnerTaskState, type OwnerFleetPolicy, type OwnerFleetPolicyChange,
} from '../../api/ownerChains';
import { ownerId, type OwnerInput, type OwnerSession } from '../../api/ownerLocalClient';
import type { OwnerCommand } from '../../api/ownerLocal';
import { TASK_STATE_LABELS } from '../tasks/taskV2Types';
import { EMPTY_TASK_NAMES } from '../tasks/taskNames';
import { formatDuration, leaseClock, progressCaption, progressCounts, ticketKeys } from '../tasks/ticketModel';
import { TicketProgressBar } from '../tasks/TicketProgressBar';
import { TicketAttemptsCard } from '../tasks/TicketAttemptsCard';
import { TicketCard } from '../tasks/TicketCard';
import { TicketDecisionBlock, type TicketDecisionActions } from '../tasks/TicketDecisionBlock';
import { ownerRequirementsDoc, ownerTaskWire, ownerTaskWires } from '../tasks/ownerTaskAdapter';
import { TicketBoard } from '../tasks/TicketBoard';
import type { BoardTicketActions } from '../tasks/BoardTicketCard';
import type { TaskWire } from '../../api/taskWire';
import type { OwnerTicketEditFocus } from '../../store/auxTabId';
import type { TaskEditField } from '../tasks/BoardTicketCard';
import OwnerLocalPanel from './OwnerLocalPanel';
import OwnerCoordinatorControl, { hubCoordinatorApi, type OwnerCoordinatorApi } from './OwnerCoordinatorControl';
import OwnerAddAgentControl, { type ChainAgentRole } from './OwnerAddAgentControl';
import OwnerFleetTable from './OwnerFleetTable';
import { ownerChainById, resolveOwnerChainCoordinator, setOwnerChainCoordinator } from '../../api/ownerChainsStore';
import { bindOwnerCoordinator, readOwnerChainMembers, type OwnerChainMember } from '../../api/ownerCoordinator';

const STATE_TONE: Record<OwnerTaskState, Tone> = {
  ready: 'info', in_progress: 'pending', in_review: 'warning', done: 'success', cancelled: 'neutral',
};
const RUNTIME_LIMIT = 50;
const STATE_ORDER: OwnerTaskState[] = ['ready', 'in_progress', 'in_review', 'done', 'cancelled'];
/** The board card Edit menu: reviewers live in the requirements (reviewer ids + your approval). */
const OWNER_EDIT_FIELDS: readonly TaskEditField[] = ['requirements', 'reviewers', 'deps'];

/** A chain agent's instance runtime_status (Hub) as a pill; '' when unknown. */
const AGENT_STATUS: Record<string, { label: string; tone: Tone }> = {
  running: { label: 'Running', tone: 'success' },
  launching: { label: 'Starting', tone: 'pending' },
  starting: { label: 'Starting', tone: 'pending' },
  stopping: { label: 'Stopping', tone: 'pending' },
  stopped: { label: 'Stopped', tone: 'neutral' },
  failed: { label: 'Failed', tone: 'danger' },
};

/** Which runtime controls an agent row offers for its instance status. */
export function agentRuntimeActions(status: string): ('start' | 'stop' | 'restart')[] {
  if (status === 'running') return ['stop', 'restart'];
  if (status === 'stopped' || status === 'failed') return ['start'];
  return [];
}

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
 * `page` (the Task Chains page): ticket list beside the selected ticket. The
 * aux panes of a coordinator conversation show one part each: `overview`
 * (status, agents, attention, tickets), `board` (tickets by state) and
 * `ticket` (one ticket); their ticket clicks open ticket tabs via onOpenTicket.
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
  /** Extra sections under the description (the page passes the chain's token usage). */
  extra?: React.ReactNode;
  /** The owner relay; tests replace it. */
  send?: OwnerSend;
  /** Session provider; tests replace it. */
  session?: () => Promise<OwnerSession>;
  /** Hub calls of Start coordinator; tests replace them. */
  coordinatorApi?: OwnerCoordinatorApi;
}

export function OwnerChainView({
  chain, layout = 'page', onOpenTicket, onEditTicket, editFocus, onEditFocusConsumed, onShowBoard, onSwitchTicket, onOpenAgent, onTitle, refreshMs = 0,
  focusTaskId, submissionAttempt, onClose, extra, send: sendProp = ownerRelaySend, session: sessionProp = freshOwnerSession, coordinatorApi,
}: OwnerChainViewProps) {
  const bridge = chain.ownerBridgeId;
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
  // The open ticket's requirement history, read when shown: null when hidden.
  const [reqHistory, setReqHistory] = useState<{ taskId: string; changes: OwnerRequirementChange[] | null; error: string; more: boolean } | null>(null);
  // The overview's recent chain history (history.read); null until read.
  const [activity, setActivity] = useState<{ events: OwnerActivity[]; truncated: boolean } | null>(null);
  const [selected, setSelected] = useState(focusTaskId || '');
  const [task, setTask] = useState<TaskView | null>(null);
  const [taskLoading, setTaskLoading] = useState(false);
  const [submission, setSubmission] = useState<OwnerSubmission | null>(null);
  const [busy, setBusy] = useState(false);
  const [debug, setDebug] = useState(false);
  const [newTitle, setNewTitle] = useState('');
  const [newBody, setNewBody] = useState('');
  const [comment, setComment] = useState('');
  const [reason, setReason] = useState('');
  // Inline editors: null when closed, else the draft.
  const [chainDraft, setChainDraft] = useState<{ title: string; description: string } | null>(null);
  // Ticket dependencies (work.read), read when a ticket opens; null until read.
  const [deps, setDeps] = useState<{ items: OwnerDependency[]; truncated: boolean } | null>(null);
  const [newDep, setNewDep] = useState('');
  // The requirements being edited for the open ticket (null when closed).
  const [reqDraft, setReqDraft] = useState<{ taskId: string; goal: string; acceptance: string; reviewers: string; approval: boolean; reason: string } | null>(null);
  // Complete chain: the summary being written (null when the form is closed).
  const [completeSummary, setCompleteSummary] = useState<string | null>(null);
  const [taskDraft, setTaskDraft] = useState<{ taskId: string; title: string; body: string } | null>(null);
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
        withOwnerRecovery(s, chain, () => readOwnerChain(s, bridge, chain.chainId, send), send),
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
  }, [bridge, chain.chainId, chain.bridgeName, send, session, fail]);

  const openSubmission = useCallback(async (taskId: string, attempt: string) => {
    try {
      const s = await session();
      const sub = await readOwnerSubmission(s, bridge, chain.chainId, taskId, attempt, send);
      if (live.current) setSubmission(sub);
    } catch (e) { fail(e); }
  }, [bridge, chain.chainId, send, session, fail]);

  useEffect(() => { if (chain.online || chain.pending) void loadChain(); }, [chain.chainId, chain.online, chain.pending, loadChain]);
  useEffect(() => { setSubmission(null); if (selected && !offline) void loadTask(selected); }, [selected]); // eslint-disable-line react-hooks/exhaustive-deps
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

  useEffect(() => {
    if (layout === 'ticket' && task?.detail.title) onTitle?.(task.detail.title);
  }, [layout, task?.detail.title]); // eslint-disable-line react-hooks/exhaustive-deps

  // `taskRevision` names the revision of a ticket that is not the open one
  // (board card actions); the open ticket's revision is used otherwise.
  async function mutate(method: OwnerCommand['method'], input: Omit<OwnerInput, 'chainId' | 'expectedRevision'>, done: string, taskRevisionOverride?: string, reloadTask = true): Promise<boolean> {
    setBusy(true); setError(''); setNotice('');
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
    if ((layout !== 'overview' && layout !== 'board') || offline) return;
    let cancelled = false;
    Promise.resolve().then(() => hubApiRef.current.listAgents()).then((list) => {
      if (!cancelled && live.current) setAgentNames(Object.fromEntries(list.map((a) => [a.agentId, a.name])));
    }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [layout, offline]);

  // Fleet rows (fleet.policy.read), re-read when the chain revision changes:
  // every fleet.policy.set bumps it.
  const [fleet, setFleet] = useState<{ rows: OwnerFleetPolicy[] | null; error: string }>({ rows: null, error: '' });
  const fleetKey = (layout === 'overview' || layout === 'board') && !offline && detail ? detail.revision : '';
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
  function removeAgent(a: { instanceId: string; agentId: string; role: string }) {
    if (!window.confirm(`Remove ${a.instanceId} from this chain? Its instance keeps running until you stop it.`)) return Promise.resolve(false);
    return mutate('chain.member.set', { instanceId: a.instanceId, agentId: a.agentId, memberRole: a.role || 'worker', enabled: false }, 'Agent removed from the chain.');
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
  const s = sessionRef.current;
  const ts = task ? ownerTaskState(task.runtime) : null;
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
  const stateOf = (taskId: string) => (states[taskId] ? ownerTaskState(states[taskId]) : null);
  const awaitingUser = (taskId: string) => {
    const rt = states[taskId];
    return Boolean(rt && ownerAwaitingUser(rt, task?.taskId === taskId && !task.reviewsLoading ? task.reviews : undefined));
  };

  // Agents: the chain's member rows (overview reads them) and every live lease
  // holder, with the tickets each one holds.
  const agents = useMemo(() => {
    if (layout !== 'overview') return [];
    const rows = new Map<string, { instanceId: string; agentId: string; role: string; enabled: boolean; tickets: { taskId: string; title: string }[] }>();
    for (const m of members ?? []) rows.set(m.instanceId, { ...m, tickets: [] });
    if (coordinatorId && !rows.has(coordinatorId)) rows.set(coordinatorId, { instanceId: coordinatorId, agentId: '', role: 'coordinator', enabled: true, tickets: [] });
    for (const t of tasks) {
      const holder = states[t.taskId]?.holder;
      if (!holder) continue;
      const row = rows.get(holder) ?? { instanceId: holder, agentId: '', role: '', enabled: true, tickets: [] };
      row.tickets.push({ taskId: t.taskId, title: t.title || t.taskId });
      rows.set(holder, row);
    }
    return [...rows.values()].sort((a, b) => Number(b.role === 'coordinator') - Number(a.role === 'coordinator') || Number(b.enabled) - Number(a.enabled));
  }, [layout, members, coordinatorId, tasks, states]);

  // The board's ticket wires, keys and per-ticket card actions (owner commands).
  const boardWires = useMemo(() => ((layout === 'board' || layout === 'overview') && detail ? ownerTaskWires(chain.chainId, bridge, detail.tasks, states) : []), [layout, detail, states, chain.chainId, bridge]);
  const boardKeys = useMemo(() => ticketKeys(boardWires), [boardWires]);
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

  // Opens the requirements editor (goal, acceptance, reviewers, your approval).
  function startReqEdit(t: TaskView) {
    setReqDraft({
      taskId: t.taskId,
      goal: t.runtime.requirements?.goal ?? '',
      acceptance: (t.runtime.requirements?.acceptance ?? []).join('\n'),
      reviewers: (wire?.task_id === t.taskId ? wire.brief?.reviewers ?? [] : []).join(', '),
      approval: Boolean(t.runtime.requirements?.requiresUserApproval),
      reason: '',
    });
  }
  // The board's Edit menu: the aux board opens a ticket tab with the editor;
  // the page selects the ticket in place and opens it there.
  const [pendingEdit, setPendingEdit] = useState<OwnerTicketEditFocus | null>(editFocus ?? null);
  function editTicket(taskId: string, title: string, field: TaskEditField) {
    const focus: OwnerTicketEditFocus = field === 'deps' ? 'edit_deps' : 'edit_requirements';
    if (aux) { onEditTicket?.(taskId, title || taskId, focus); return; }
    setSelected(taskId); setPendingEdit(focus);
  }
  useEffect(() => {
    if (!pendingEdit || !task || task.taskId !== selected || !editable) return;
    if (pendingEdit === 'edit_requirements') startReqEdit(task);
    else document.querySelector<HTMLElement>('[data-debug-id="owner-chain-dependencies"]')?.scrollIntoView?.({ block: 'center' });
    setPendingEdit(null);
    onEditFocusConsumed?.();
  }, [pendingEdit, task, selected, editable]); // eslint-disable-line react-hooks/exhaustive-deps

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

  const ticketCard = (t: { taskId: string; title: string; priority: string }) => {
    const st = stateOf(t.taskId);
    return (
      <li key={t.taskId}>
        <button type="button" data-debug-id={`owner-chain-task-${t.taskId}`} disabled={offline}
          onClick={() => openTicket(t.taskId, t.title)}
          className={`flex w-full min-w-0 flex-col gap-1 rounded-lg border px-3 py-2 text-left ${selected === t.taskId && !aux ? 'border-strong bg-neutral-soft' : 'border-subtle bg-surface-raised hover:bg-neutral-soft'} disabled:cursor-default`}>
          <Text as="span" role="body-sm" truncate>{t.title || t.taskId}</Text>
          <span className="flex flex-wrap items-center gap-1.5">
            {st && <StatusPill tone={STATE_TONE[st.state]} data-debug-id={`owner-chain-task-state-${t.taskId}`}>{TASK_STATE_LABELS[st.state]}</StatusPill>}
            {st?.held && <StatusPill tone="warning">Held</StatusPill>}
            {st?.blocked && <StatusPill tone="danger">Blocked</StatusPill>}
            {awaitingUser(t.taskId) && <StatusPill tone="warning" data-debug-id={`owner-chain-task-awaiting-user-${t.taskId}`}>Waiting on you</StatusPill>}
            {t.priority && t.priority !== 'p2' && <Badge tone="neutral">{t.priority.toUpperCase()}</Badge>}
          </span>
        </button>
      </li>
    );
  };
  const selectedIndex = tasks.findIndex((t) => t.taskId === selected);
  const prevTicket = selectedIndex > 0 ? tasks[selectedIndex - 1] : null;
  const nextTicket = selectedIndex >= 0 && selectedIndex < tasks.length - 1 ? tasks[selectedIndex + 1] : null;
  const attention = tasks.filter((t) => awaitingUser(t.taskId) || stateOf(t.taskId)?.blocked || stateOf(t.taskId)?.held);

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
      {error && <div data-debug-id="owner-chain-error" className="mx-4 mt-3"><Alert tone="danger">{error}</Alert></div>}
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
      {showChainInfo && extra ? <div className="px-4 pt-3">{extra}</div> : null}

      {layout === 'overview' && (
        <div data-debug-id="owner-chain-overview" className="space-y-4 px-4 pt-4">
          {detail && boardWires.length > 0 && (() => {
            const counts = progressCounts(boardWires);
            const caption = progressCaption(counts);
            return (
              <div className="space-y-1.5">
                <TicketProgressBar counts={counts} debugId="owner-chain-progress" />
                <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-progress-caption">
                  <span className="font-semibold text-primary">{caption.lead}</span>{caption.rest ? ` · ${caption.rest}` : ''}
                </Text>
              </div>
            );
          })()}
          {detail && tasks.length > 0 && (
            <div data-debug-id="owner-chain-overview-counts" className="flex flex-wrap gap-1.5">
              {STATE_ORDER.map((state) => {
                const n = tasks.filter((t) => stateOf(t.taskId)?.state === state).length;
                return n ? <StatusPill key={state} tone={STATE_TONE[state]} data-debug-id={`owner-chain-count-${state}`}>{TASK_STATE_LABELS[state]} · {n}</StatusPill> : null;
              })}
            </div>
          )}
          <section aria-label="Agents" data-debug-id="owner-chain-agents" className="space-y-1.5">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <Text as="h3" role="overline" tone="muted">Agents</Text>
              {!offline && detail && (
                <OwnerAddAgentControl chainId={chain.chainId} ownerBridgeId={bridge} disabled={busy} bind={bindMember} onAdded={memberAdded} api={coordinatorApi} />
              )}
            </div>
            {offline ? <Text as="p" role="caption" tone="muted">Unavailable while the owner Bridge is offline.</Text>
              : members === null && loading ? <Text as="p" role="caption" tone="muted" aria-live="polite">Loading agents…</Text>
              : agents.length === 0 ? <EmptyState data-debug-id="owner-chain-no-agents" title="No agents yet" description="Start the coordinator; it adds workers and reviewers to the fleet." />
              : (
                <ul className="space-y-1.5">
                  {agents.map((a) => (
                    <li key={a.instanceId} data-debug-id={`owner-chain-agent-${a.instanceId}`} className="flex min-w-0 flex-wrap items-center gap-1.5 rounded-lg border border-subtle bg-surface-raised px-3 py-2">
                      <button type="button" data-debug-id={`owner-chain-agent-open-${a.instanceId}`} disabled={!onOpenAgent}
                        onClick={() => onOpenAgent?.(a.instanceId)}
                        className="min-w-0 truncate hover:underline disabled:no-underline" title={a.agentId || a.instanceId}>
                        {agentNames[a.agentId] ? <Text as="span" role="label">{agentNames[a.agentId]}</Text> : <Text as="code" role="code-sm">{a.instanceId}</Text>}
                      </button>
                      {agentNames[a.agentId] && <Text as="code" role="code-sm" tone="muted" data-debug-id={`owner-chain-agent-instance-${a.instanceId}`}>{a.instanceId}</Text>}
                      {a.role && <Badge tone={a.role === 'coordinator' ? 'info' : 'neutral'}>{a.role}</Badge>}
                      {!a.enabled && <StatusPill tone="neutral">Removed</StatusPill>}
                      {a.enabled && AGENT_STATUS[agentStatus[a.instanceId] ?? ''] && (
                        <StatusPill tone={AGENT_STATUS[agentStatus[a.instanceId]].tone} data-debug-id={`owner-chain-agent-status-${a.instanceId}`}>{AGENT_STATUS[agentStatus[a.instanceId]].label}</StatusPill>
                      )}
                      {a.tickets.map((t) => (
                        <button key={t.taskId} type="button" data-debug-id={`owner-chain-agent-ticket-${a.instanceId}-${t.taskId}`} onClick={() => openTicket(t.taskId, t.title)}
                          className="min-w-0 truncate text-caption text-accent hover:underline">
                          on {t.title}
                        </button>
                      ))}
                      {a.enabled && (
                        <span className="ml-auto flex items-center gap-0.5">
                          {agentRuntimeActions(agentStatus[a.instanceId] ?? '').map((action) => (
                            <IconButton key={action} size="sm" variant="ghost" disabled={busy}
                              icon={action === 'start' ? 'play' : action === 'stop' ? 'stop' : 'refresh'}
                              label={`${action === 'start' ? 'Start' : action === 'stop' ? 'Stop' : 'Restart'} ${a.instanceId}`}
                              data-debug-id={`owner-chain-agent-${action}-${a.instanceId}`}
                              onClick={() => void agentRuntime(a.instanceId, action)} />
                          ))}
                          {a.role !== 'coordinator' && a.agentId && (
                            <IconButton size="sm" variant="ghost" icon="trash" disabled={busy} label={`Remove ${a.instanceId} from the chain`}
                              data-debug-id={`owner-chain-agent-remove-${a.instanceId}`} onClick={() => void removeAgent(a)} />
                          )}
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              )}
          </section>
          {!offline && detail && (
            <OwnerFleetTable rows={fleet.rows} error={fleet.error} names={agentNames} editable={editable} busy={busy} save={saveFleet} />
          )}
          {attention.length > 0 && (
            <section aria-label="Needs attention" data-debug-id="owner-chain-attention" className="space-y-1.5">
              <Text as="h3" role="overline" tone="warning">Needs attention</Text>
              <ul className="space-y-1.5">{attention.map(ticketCard)}</ul>
            </section>
          )}
          {!offline && activity && (
            <section aria-label="Activity" data-debug-id="owner-chain-activity" className="space-y-1.5">
              <Text as="h3" role="overline" tone="muted">Activity</Text>
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
            </section>
          )}
        </div>
      )}

      <div className={`grid min-h-0 flex-1 gap-4 p-4 ${layout === 'page' ? 'lg:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]' : ''}`}>
        {layout !== 'ticket' && <section aria-label="Tickets" data-debug-id={`owner-chain-tickets-${layout}`} className="min-w-0 space-y-2">
          <Text as="h3" role="overline" tone="muted">Tickets {loading && <span role="status" className="normal-case">· loading…</span>}</Text>
          {tasks.length === 0 && !loading && <EmptyState data-debug-id="owner-chain-no-tasks" icon="layers" title="No tickets yet" description="Tickets the coordinator or you create appear here." />}
          {layout === 'board' ? (
            // origin/main's ticket board over the owner-local reads (ownerTaskAdapter).
            boardWires.length > 0 && (
              <TicketBoard
                chainId={chain.chainId}
                tasks={boardWires}
                keys={boardKeys}
                actionsFor={boardActions}
                editFields={OWNER_EDIT_FIELDS}
                fleetSlot={<OwnerFleetTable rows={fleet.rows} error={fleet.error} names={agentNames} editable={editable} busy={busy} save={saveFleet} />}
                onOpenTicket={(taskId) => openTicket(taskId, boardWires.find((w) => w.task_id === taskId)?.title ?? '')}
                onEditTicket={(taskId, field) => editTicket(taskId, boardWires.find((w) => w.task_id === taskId)?.title ?? '', field)}
              />
            )
          ) : (
            <ul className="space-y-1.5">{tasks.map(ticketCard)}</ul>
          )}
          {detail?.truncated && <Text as="p" role="caption" tone="muted">Showing the first {detail.tasks.length} tickets.</Text>}
          {editable && layout !== 'overview' && (
            <form data-debug-id="owner-chain-create-task-form" className="space-y-1.5 rounded-lg border border-subtle bg-surface-raised p-3" onSubmit={(e) => {
              e.preventDefault();
              if (!newTitle.trim()) return;
              const taskId = ownerId('task_');
              void mutate('task.create', { taskId, title: newTitle.trim(), body: newBody.trim() }, 'Ticket created.').then((ok) => { if (ok) { setNewTitle(''); setNewBody(''); } });
            }}>
              <Input size="sm" aria-label="New ticket title" placeholder="New ticket title" data-debug-id="owner-chain-new-task-title" value={newTitle} onChange={setNewTitle} />
              <Textarea size="sm" aria-label="New ticket description" placeholder="Description (optional)" data-debug-id="owner-chain-new-task-body" value={newBody} onChange={setNewBody} rows={2} />
              <Button size="sm" type="submit" variant="primary" data-debug-id="owner-chain-create-task" disabled={busy || !newTitle.trim()}>Create ticket</Button>
            </form>
          )}
        </section>}

        {(layout === 'page' || layout === 'ticket') && <section aria-label="Ticket details" data-debug-id="owner-chain-task-detail" className="min-w-0 space-y-4">
          {layout === 'ticket' && (
            <div data-debug-id="owner-chain-ticket-nav" className="flex flex-wrap items-center gap-2">
              {onShowBoard && <Button size="sm" variant="ghost" data-debug-id="owner-chain-show-board" onClick={onShowBoard}>Board</Button>}
              {onSwitchTicket && <>
                <Button size="sm" variant="ghost" data-debug-id="owner-chain-prev-ticket" disabled={!prevTicket} onClick={() => prevTicket && onSwitchTicket(prevTicket.taskId, prevTicket.title || prevTicket.taskId)}>Previous</Button>
                <Button size="sm" variant="ghost" data-debug-id="owner-chain-next-ticket" disabled={!nextTicket} onClick={() => nextTicket && onSwitchTicket(nextTicket.taskId, nextTicket.title || nextTicket.taskId)}>Next</Button>
              </>}
            </div>
          )}
          {offline ? null : !selected ? (
            <EmptyState title="No ticket selected" description="Select a ticket to see its brief, attempts, reviews and comments." />
          ) : taskLoading && !task ? (
            <Text as="p" role="body-sm" tone="muted" aria-live="polite">Loading ticket…</Text>
          ) : task && ts ? (
            <>
              <div>
                <Text as="h3" role="heading" data-debug-id="owner-chain-task-title">{task.detail.title || task.taskId}</Text>
                <Text as="code" role="code-sm" tone="muted">{task.taskId}</Text>
                <div className="mt-1 flex flex-wrap gap-1.5">
                  <StatusPill tone={STATE_TONE[ts.state]} data-debug-id="owner-chain-task-detail-state">{TASK_STATE_LABELS[ts.state]}</StatusPill>
                  {ts.held && <StatusPill tone="warning">Held{task.runtime.control?.reason ? ': ' + task.runtime.control.reason : ''}</StatusPill>}
                  {ts.blocked && <StatusPill tone="danger">Blocked{task.runtime.control?.waitingOn ? ' on ' + task.runtime.control.waitingOn : ''}</StatusPill>}
                  {ts.merge && <StatusPill tone="pending">{ts.merge === 'merge_blocked' ? 'Merge blocked' : 'Merge pending'}</StatusPill>}
                  <Badge tone="neutral">{task.detail.priority.toUpperCase()}</Badge>
                </div>
              </div>

              {editable && wire && (
                // origin/main's decision block (hold, blocked on you, your review) over owner commands.
                <div data-debug-id={ownerAwaitingUser(task.runtime, task.reviewsLoading ? undefined : task.reviews) ? 'owner-chain-awaiting-user' : undefined}>
                  <TicketDecisionBlock task={wire} names={EMPTY_TASK_NAMES} now={Date.now()} actions={decisionActions(task)}
                    submission={task.runtime.submission ? { summary: task.runtime.submission.summary, head: task.runtime.submission.head } : undefined}
                    reviewable={ts.state === 'in_review' && Boolean(task.runtime.submission)} />
                </div>
              )}

              {editable && taskDraft?.taskId === task.taskId && (
                <form data-debug-id="owner-chain-task-edit-form" className="space-y-2 rounded-lg border border-subtle bg-surface-raised p-3" onSubmit={(e) => {
                  e.preventDefault();
                  if (!taskDraft.title.trim()) return;
                  void mutate('task.edit', { taskId: task.taskId, title: taskDraft.title.trim(), body: taskDraft.body.trim() }, 'Ticket updated.').then((ok) => { if (ok) setTaskDraft(null); });
                }}>
                  <FormField label="Title">
                    <Input size="sm" data-debug-id="owner-chain-task-edit-title" value={taskDraft.title} onChange={(v) => setTaskDraft((d) => d && { ...d, title: v })} />
                  </FormField>
                  <FormField label="Description">
                    <Textarea size="sm" rows={3} data-debug-id="owner-chain-task-edit-body" value={taskDraft.body} onChange={(v) => setTaskDraft((d) => d && { ...d, body: v })} />
                  </FormField>
                  <div className="flex gap-2">
                    <Button size="sm" type="submit" variant="primary" data-debug-id="owner-chain-task-edit-save" disabled={busy || !taskDraft.title.trim()}>Save</Button>
                    <Button size="sm" type="button" variant="ghost" disabled={busy} onClick={() => setTaskDraft(null)}>Cancel</Button>
                  </div>
                </form>
              )}

              {editable && <div className="flex flex-wrap items-center gap-2">
                {ts.state !== 'done' && ts.state !== 'cancelled' && taskDraft?.taskId !== task.taskId && (
                  <Button size="sm" variant="ghost" data-debug-id="owner-chain-task-edit" disabled={busy} onClick={() => setTaskDraft({ taskId: task.taskId, title: task.detail.title, body: task.detail.body })}>Edit ticket</Button>
                )}
                <Select size="sm" aria-label="Priority" data-debug-id="owner-chain-task-priority" name="priority" value={task.detail.priority} disabled={busy}
                  onChange={(v) => { if (v !== task.detail.priority) void mutate('task.priority', { taskId: task.taskId, priority: v as 'p0' | 'p1' | 'p2' }, 'Priority updated.'); }}
                  options={[{ value: 'p0', label: 'P0 · urgent' }, { value: 'p1', label: 'P1 · high' }, { value: 'p2', label: 'P2 · normal' }]} />
                {ts.held
                  ? <Button size="sm" data-debug-id="owner-chain-release" disabled={busy} onClick={() => void mutate('task.release', { taskId: task.taskId, body: reason }, 'Hold released.')}>Release hold</Button>
                  : ts.state !== 'cancelled' && ts.state !== 'done' && <Button size="sm" data-debug-id="owner-chain-hold" disabled={busy} onClick={() => void mutate('task.hold', { taskId: task.taskId, body: reason }, 'Ticket held.')}>Hold</Button>}
                {ts.state === 'ready' && task.runtime.attemptNo === 0 && !task.runtime.holder && (
                  <Button size="sm" variant="danger" data-debug-id="owner-chain-delete" disabled={busy} onClick={() => {
                    if (!window.confirm(`Delete “${task.detail.title || task.taskId}”? This cannot be undone.`)) return;
                    void mutate('task.delete', { taskId: task.taskId }, 'Ticket deleted.', undefined, false).then((ok) => {
                      if (!ok || !live.current) return;
                      setSelected(''); setTask(null);
                      if (layout === 'ticket') onShowBoard?.();
                    });
                  }}>Delete ticket</Button>
                )}
                {ts.state === 'cancelled'
                  ? <Button size="sm" data-debug-id="owner-chain-reopen" disabled={busy} onClick={() => void mutate('task.reopen', { taskId: task.taskId, body: reason }, 'Ticket reopened.')}>Reopen</Button>
                  : ts.state !== 'done' && <Button size="sm" variant="danger" data-debug-id="owner-chain-cancel" disabled={busy} onClick={() => void mutate('task.cancel', { taskId: task.taskId, body: reason }, 'Ticket cancelled.')}>Cancel ticket</Button>}
                <Input size="sm" className="min-w-0 flex-1" aria-label="Reason (optional)" placeholder="Reason (optional)" data-debug-id="owner-chain-control-reason" value={reason} onChange={setReason} />
              </div>}

              <TicketCard debugId="owner-chain-brief" title="Brief" aside={wire?.requirements ? <Badge tone="neutral">Rev {wire.requirements.revision}</Badge> : undefined}>
                {task.detail.body ? <Text as="p" role="body-sm" className="whitespace-pre-wrap">{task.detail.body}</Text> : <Text as="p" role="caption" tone="muted">No description.</Text>}
                {task.runtime.requirements ? (
                  <div data-debug-id="owner-chain-requirements" className="mt-3 space-y-2">
                    {task.runtime.requirements.goal && <Text as="p" role="body-sm" className="whitespace-pre-wrap">{task.runtime.requirements.goal}</Text>}
                    {task.runtime.requirements.acceptance.length > 0 && (
                      <>
                        <Text as="h4" role="overline" tone="muted">Acceptance</Text>
                        <ul className="list-disc space-y-1 pl-5">
                          {task.runtime.requirements.acceptance.map((a, i) => <li key={i}><Text as="span" role="body-sm">{a}</Text></li>)}
                        </ul>
                      </>
                    )}
                    {(wire?.brief?.reviewers?.length || wire?.requires_user_approval) ? (
                      <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-reviewers">
                        Reviewers: {[...(wire?.brief?.reviewers ?? []), ...(wire?.requires_user_approval ? ['you'] : [])].join(', ')}
                      </Text>
                    ) : null}
                    {wire?.depends_on?.length ? (
                      <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-deps">Depends on: {wire.depends_on.map((d) => <Text key={d} as="code" role="code-sm" className="mr-1">{d}</Text>)}</Text>
                    ) : null}
                  </div>
                ) : <Text as="p" role="caption" tone="muted">No requirements saved.</Text>}
                {editable && ts.state !== 'done' && (reqDraft?.taskId !== task.taskId ? (
                  <Button size="sm" variant="ghost" className="mt-2" data-debug-id="owner-chain-requirements-edit" disabled={busy || ts.merge !== ''}
                    onClick={() => startReqEdit(task)}>{task.runtime.requirements ? 'Change requirements' : 'Add requirements'}</Button>
                ) : (
                  <form data-debug-id="owner-chain-requirements-form" className="mt-3 space-y-2" onSubmit={(e) => {
                    e.preventDefault();
                    if (!reqDraft.goal.trim()) return;
                    const body = ownerRequirementsDoc(task.runtime.requirements?.raw ?? '', {
                      goal: reqDraft.goal, acceptance: reqDraft.acceptance.split('\n'), reviewers: reqDraft.reviewers.split(/[\s,]+/),
                      requiresUserApproval: reqDraft.approval, reason: reqDraft.reason,
                    });
                    const next = String((Number(task.runtime.requirements?.revision) || 0) + 1);
                    void mutate('requirements.edit', { taskId: task.taskId, body, requirementsRevision: next }, 'Requirements updated.').then((ok) => {
                      if (!ok) return;
                      setReqDraft(null);
                      if (reqHistory?.taskId === task.taskId) void showRequirementHistory(task.taskId);
                    });
                  }}>
                    <FormField label="Goal" required>
                      <Textarea size="sm" rows={3} data-debug-id="owner-chain-requirements-goal" value={reqDraft.goal} onChange={(v) => setReqDraft((d) => d && { ...d, goal: v })} />
                    </FormField>
                    <FormField label="Acceptance" hint="One criterion per line.">
                      <Textarea size="sm" rows={4} data-debug-id="owner-chain-requirements-acceptance" value={reqDraft.acceptance} onChange={(v) => setReqDraft((d) => d && { ...d, acceptance: v })} />
                    </FormField>
                    <FormField label="Reviewers" hint="Agent ids, separated by commas. Not the assignee or the coordinator.">
                      <Input size="sm" data-debug-id="owner-chain-requirements-reviewers" value={reqDraft.reviewers} onChange={(v) => setReqDraft((d) => d && { ...d, reviewers: v })} />
                    </FormField>
                    <Checkbox size="sm" data-debug-id="owner-chain-requirements-approval" checked={reqDraft.approval} onChange={(v) => setReqDraft((d) => d && { ...d, approval: v })} label="Needs your approval before it is done" />
                    <FormField label="Why it changed" hint="Kept in the requirement history; agents see it.">
                      <Input size="sm" data-debug-id="owner-chain-requirements-reason" value={reqDraft.reason} onChange={(v) => setReqDraft((d) => d && { ...d, reason: v })} />
                    </FormField>
                    <Text as="p" role="caption" tone="muted">Saving sends the ticket back to Ready for a fresh submission.</Text>
                    <div className="flex gap-2">
                      <Button size="sm" type="submit" variant="primary" data-debug-id="owner-chain-requirements-save" disabled={busy || !reqDraft.goal.trim()}>Save requirements</Button>
                      <Button size="sm" type="button" variant="ghost" disabled={busy} onClick={() => setReqDraft(null)}>Cancel</Button>
                    </div>
                  </form>
                ))}
                {reqHistory?.taskId !== task.taskId ? (
                  <Button size="sm" variant="ghost" className="mt-2" data-debug-id="owner-chain-requirements-history-show" disabled={offline}
                    onClick={() => void showRequirementHistory(task.taskId)}>Requirement history</Button>
                ) : (
                  <section aria-label="Requirement history" data-debug-id="owner-chain-requirements-history" className="mt-3 space-y-2">
                    <div className="flex items-center justify-between gap-2">
                      <Text as="h4" role="overline" tone="muted">Requirement history</Text>
                      <IconButton size="sm" variant="ghost" icon="close" label="Hide requirement history" onClick={() => setReqHistory(null)} />
                    </div>
                    {reqHistory.changes === null ? <Text as="p" role="caption" tone="muted" aria-live="polite">Loading requirement history…</Text>
                      : reqHistory.error ? <Alert tone="danger">{reqHistory.error}</Alert>
                      : reqHistory.changes.length === 0 ? <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-requirements-history-empty">The requirements have not been changed since the ticket was created.</Text>
                      : (
                        <ol className="space-y-2">
                          {reqHistory.changes.map((c) => (
                            <li key={c.seq} data-debug-id={`owner-chain-requirements-change-${c.seq}`} className="space-y-1 border-l-2 border-subtle pl-3">
                              <div className="flex flex-wrap items-baseline gap-x-1.5">
                                {c.revision && <Badge tone="neutral">Rev {c.revision}</Badge>}
                                <Text as="span" role="caption">{principalLabel(sessionRef.current, c.actorId)}</Text>
                                {c.at && <Text as="span" role="caption" tone="faint">{formatWhen(c.at)}</Text>}
                              </div>
                              {c.reason && <Text as="p" role="body-sm">{c.reason}</Text>}
                              {!c.readable ? <Text as="p" role="caption" tone="muted">These requirements cannot be decrypted with this vault.</Text> : (
                                <>
                                  {c.goal && <Text as="p" role="body-sm" tone="muted" className="whitespace-pre-wrap">{c.goal}</Text>}
                                  {c.acceptance.length > 0 && (
                                    <ul className="list-disc space-y-0.5 pl-5">{c.acceptance.map((a, i) => <li key={i}><Text as="span" role="caption" tone="muted">{a}</Text></li>)}</ul>
                                  )}
                                </>
                              )}
                            </li>
                          ))}
                        </ol>
                      )}
                    {reqHistory.more && <Text as="p" role="caption" tone="muted">Older changes are not shown.</Text>}
                  </section>
                )}
                {(task.runtime.holder || wire?.merge) && (
                  <dl data-debug-id="owner-chain-lease" className="mt-3 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1">
                    {task.runtime.holder && <><Text as="span" role="caption" tone="muted">Lease holder</Text><Text as="code" role="code-sm" truncate>{task.runtime.holder}</Text></>}
                    {task.runtime.lease?.expiresMs ? <><Text as="span" role="caption" tone="muted">Lease left</Text><Text as="span" role="caption" data-debug-id="owner-chain-lease-left" className="tabular-nums">{formatDuration(Math.max(0, task.runtime.lease.expiresMs - Date.now()))}</Text></> : null}
                    {task.runtime.lease?.hardMs ? <><Text as="span" role="caption" tone="muted">Hard deadline</Text><Text as="span" role="caption" data-debug-id="owner-chain-lease-hard" className="tabular-nums">in {formatDuration(Math.max(0, task.runtime.lease.hardMs - Date.now()))}</Text></> : null}
                    {wire?.merge && <><Text as="span" role="caption" tone="muted">Merge</Text><Text as="span" role="caption">{wire.merge.state}{wire.merge.head ? ' · ' : ''}{wire.merge.head && <Text as="code" role="code-sm">{wire.merge.head.slice(0, 12)}</Text>}</Text></>}
                  </dl>
                )}
              </TicketCard>

              <TicketCard debugId="owner-chain-dependencies" title="Waits for">
                {deps === null ? <Text as="p" role="caption" tone="muted">Loading dependencies…</Text> : (() => {
                  const waits = deps.items.filter((d) => d.dependent === task.taskId);
                  const blocks = deps.items.filter((d) => d.prerequisite === task.taskId);
                  const titleOf = (id: string) => tasks.find((t) => t.taskId === id)?.title || id;
                  const options = tasks.filter((t) => t.taskId !== task.taskId && !waits.some((d) => d.prerequisite === t.taskId));
                  return (
                    <div className="space-y-2">
                      {waits.length === 0 ? <Text as="p" role="caption" tone="muted">This ticket waits for nothing.</Text> : (
                        <ul className="space-y-1">
                          {waits.map((d) => (
                            <li key={d.dependencyId} data-debug-id={`owner-chain-dep-${d.prerequisite}`} className="flex min-w-0 items-center gap-2">
                              <Text as="span" role="body-sm" truncate className="min-w-0 flex-1">{titleOf(d.prerequisite)}</Text>
                              {stateOf(d.prerequisite) && <StatusPill tone={STATE_TONE[stateOf(d.prerequisite)!.state]}>{TASK_STATE_LABELS[stateOf(d.prerequisite)!.state]}</StatusPill>}
                              {editable && <IconButton icon="close" size="sm" variant="ghost" label={`Stop waiting for ${titleOf(d.prerequisite)}`} data-debug-id={`owner-chain-dep-remove-${d.prerequisite}`} disabled={busy} onClick={() => void removeDependency(d.dependencyId)} />}
                            </li>
                          ))}
                        </ul>
                      )}
                      {blocks.length > 0 && <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-dep-blocks">Blocks: {blocks.map((d) => titleOf(d.dependent)).join(', ')}</Text>}
                      {deps.truncated && <Text as="p" role="caption" tone="muted">Only the first dependencies were read.</Text>}
                      {editable && options.length > 0 && (
                        <div className="flex items-end gap-2">
                          <FormField label="Add a ticket it waits for" className="min-w-0 flex-1">
                            <Select size="sm" name="owner-chain-dep-add" data-debug-id="owner-chain-dep-add" value={newDep} onChange={setNewDep}
                              options={options.map((t) => ({ value: t.taskId, label: t.title || t.taskId }))} placeholder="Choose a ticket" />
                          </FormField>
                          <Button size="sm" data-debug-id="owner-chain-dep-add-save" disabled={busy || !newDep} onClick={() => void addDependency(task.taskId, newDep).then((ok) => { if (ok) setNewDep(''); })}>Add</Button>
                        </div>
                      )}
                    </div>
                  );
                })()}
              </TicketCard>

              {wire && wire.attempt_no > 0 && <TicketAttemptsCard task={wire} names={EMPTY_TASK_NAMES} lease={leaseClock(wire, Date.now())} />}
              <section data-debug-id="owner-chain-submissions" className="space-y-1">
                <Text as="h4" role="overline" tone="muted">Submissions</Text>
                {task.runtime.attemptNo === 0 && !task.runtime.submission
                  ? <Text as="p" role="caption" tone="muted">No attempts yet.</Text>
                  : (
                    <ul className="flex flex-wrap gap-1.5">
                      {Array.from({ length: Math.max(task.runtime.attemptNo, Number(task.runtime.submission?.attempt ?? 0)) }, (_, i) => String(i + 1)).map((n) => (
                        <li key={n}>
                          <Button size="sm" variant={submission?.attempt === n ? 'primary' : 'secondary'} data-debug-id={`owner-chain-attempt-${n}`} onClick={() => void openSubmission(task.taskId, n)}>Attempt {n}</Button>
                        </li>
                      ))}
                    </ul>
                  )}
                {submission && (
                  <div data-debug-id="owner-chain-submission" className="rounded-lg border border-subtle bg-surface-raised p-3">
                    <Text as="p" role="caption" tone="muted">Attempt {submission.attempt}{submission.author ? ' · by ' + submission.author : ''}{submission.head ? ' · ' : ''}{submission.head && <Text as="code" role="code-sm">{submission.head.slice(0, 12)}</Text>}</Text>
                    <Text as="p" role="body-sm" className="mt-1 whitespace-pre-wrap">{submission.summary || 'No summary.'}</Text>
                  </div>
                )}
              </section>

              <section data-debug-id="owner-chain-reviews" className="space-y-1">
                <Text as="h4" role="overline" tone="muted">Reviews</Text>
                {task.reviewsLoading && <Text as="p" role="caption" tone="muted" aria-live="polite" data-debug-id="owner-chain-reviews-loading">Loading reviews…</Text>}
                {task.reviewsError && <Alert tone="danger">{task.reviewsError}</Alert>}
                {task.reviewsTruncated && (
                  <div data-debug-id="owner-chain-reviews-truncated"><Alert tone="warning">This chain’s history is longer than the view scans; newer reviews may be missing. Use Advanced/debug to read the full history.</Alert></div>
                )}
                {task.reviewsMore && <Text as="p" role="caption" tone="muted" data-debug-id="owner-chain-reviews-more">Showing the latest owner reviews only.</Text>}
                {task.reviews.length === 0 && !task.reviewsLoading && !task.reviewsError && !task.reviewsTruncated && <Text as="p" role="caption" tone="muted">No reviews.</Text>}
                <ul className="space-y-1.5">
                  {task.reviews.map((r, i) => (
                    <li key={i} data-debug-id={`owner-chain-review-${r.source}-${i}`} className="rounded-lg border border-subtle bg-surface-raised p-2">
                      <span className="flex flex-wrap items-center gap-1.5 text-caption text-muted">
                        <StatusPill tone={r.verdict === 'approve' ? 'success' : 'danger'}>{r.verdict === 'approve' ? 'Approved' : 'Changes requested'}</StatusPill>
                        <span>{r.byDevice ? 'You' : <Text as="code" role="code-sm">{r.reviewer}</Text>}{r.role ? ' (' + r.role + ')' : ''}</span>
                        {r.attempt && <span>· attempt {r.attempt}</span>}
                        {r.at && <span>· {formatWhen(r.at)}</span>}
                        {r.source === 'archived' && <Badge tone="neutral">Archived from Hub</Badge>}
                      </span>
                      {r.summary && <Text as="p" role="body-sm" className="mt-1 whitespace-pre-wrap">{r.summary}</Text>}
                    </li>
                  ))}
                </ul>
              </section>

              <section data-debug-id="owner-chain-comments" className="space-y-1">
                <Text as="h4" role="overline" tone="muted">Comments</Text>
                {task.detail.comments.length === 0 && <Text as="p" role="caption" tone="muted">No comments yet.</Text>}
                <ul className="space-y-1.5">
                  {task.detail.comments.map((c) => (
                    <li key={c.principal_id + ':' + c.operation_id} data-debug-id={`owner-chain-comment-${c.operation_id}`} className="rounded-lg border border-subtle bg-surface-raised p-2">
                      <span className="flex flex-wrap gap-1.5 text-caption text-muted">
                        <Text as="span" role="label">{principalLabel(s, c.principal_id)}</Text>
                        {c.created_at && <time dateTime={c.created_at}>{formatWhen(c.created_at)}</time>}
                      </span>
                      <Text as="p" role="body-sm" className="mt-1 whitespace-pre-wrap">{c.body}</Text>
                    </li>
                  ))}
                </ul>
                {task.detail.truncated && <Text as="p" role="caption" tone="muted">Showing the first {task.detail.comments.length} comments.</Text>}
                {editable && <form className="space-y-1.5" onSubmit={(e) => {
                  e.preventDefault();
                  if (!comment.trim()) return;
                  void mutate('task.comment', { taskId: task.taskId, body: comment.trim() }, 'Comment added.').then((ok) => { if (ok) setComment(''); });
                }}>
                  <Textarea size="sm" aria-label="Add a comment" placeholder="Add a comment" data-debug-id="owner-chain-comment-input" value={comment} onChange={setComment} rows={2} />
                  <Button size="sm" type="submit" data-debug-id="owner-chain-comment-submit" disabled={busy || !comment.trim()}>Comment</Button>
                </form>}
              </section>
            </>
          ) : null}
        </section>}
      </div>

      {debug && (
        <OwnerLocalPanel initialChainId={chain.chainId} initialBridgeId={bridge} initialTaskId={selected || undefined}
          initialSubmissionAttempt={submission?.attempt} onClose={() => setDebug(false)} />
      )}
    </div>
  );
}

export default OwnerChainView;
