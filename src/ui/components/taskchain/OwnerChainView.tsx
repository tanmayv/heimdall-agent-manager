// The ordinary chain view for a Bridge-owned chain (R4b). Everything shown
// past the registry metadata is read from the owner Bridge with signed,
// encrypted owner operations; every change is one signed owner command. When
// the owner is offline only the registry metadata (decrypted titles) shows,
// with an explicit offline state. The raw method console (OwnerLocalPanel)
// stays reachable behind "Advanced/debug".

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Badge, Button, StatusDot, type Tone } from '@ui';
import {
  freshOwnerSession, isOwnerOffline, ownerCall, ownerErrorMessage, ownerOfflineMessage, ownerRelaySend, ownerTaskState,
  ownerExpectedRevision, readArchivedReviews, readOwnerChain, readOwnerChainStatus, readOwnerReviews, readOwnerRuntime, readOwnerSubmission, readOwnerTask,
  type OwnerChainDetail, type OwnerChainStatus, type OwnerChainSummary, type OwnerReview, type OwnerRuntime, type OwnerSend,
  type OwnerSubmission, type OwnerTaskDetail, type OwnerTaskState,
} from '../../api/ownerChains';
import { ownerId, type OwnerInput, type OwnerSession } from '../../api/ownerLocalClient';
import type { OwnerCommand } from '../../api/ownerLocal';
import { TASK_STATE_LABELS } from '../tasks/taskV2Types';
import OwnerLocalPanel from './OwnerLocalPanel';

const STATE_TONE: Record<OwnerTaskState, Tone> = {
  ready: 'info', in_progress: 'pending', in_review: 'warning', done: 'success', cancelled: 'neutral',
};
const RUNTIME_LIMIT = 50;

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

export interface OwnerChainViewProps {
  chain: OwnerChainSummary;
  focusTaskId?: string;
  submissionAttempt?: string;
  onClose?: () => void;
  /** The owner relay; tests replace it. */
  send?: OwnerSend;
  /** Session provider; tests replace it. */
  session?: () => Promise<OwnerSession>;
}

export function OwnerChainView({ chain, focusTaskId, submissionAttempt, onClose, send: sendProp = ownerRelaySend, session: sessionProp = freshOwnerSession }: OwnerChainViewProps) {
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
  const [reviewSummary, setReviewSummary] = useState('');
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

  const loadChain = useCallback(async () => {
    setLoading(true);
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
      if (live.current) setStates(next);
    } catch (e) { fail(e); } finally { if (live.current) setLoading(false); }
  }, [bridge, chain.chainId, send, session, fail]);

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

  async function mutate(method: OwnerCommand['method'], input: Omit<OwnerInput, 'chainId' | 'expectedRevision'>, done: string): Promise<boolean> {
    setBusy(true); setError(''); setNotice('');
    try {
      const s = await session();
      // Task-scoped methods are checked against the task revision, everything
      // else (task.create included) against the chain revision.
      const taskRevision = input.taskId && task?.taskId === input.taskId ? task.detail.revision : '0';
      const expectedRevision = ownerExpectedRevision(method, detail?.revision ?? '0', taskRevision);
      await ownerCall(s, bridge, method, { chainId: chain.chainId, expectedRevision, ...input }, send);
      if (!live.current) return true;
      setNotice(done);
      await loadChain();
      if (input.taskId) await loadTask(input.taskId);
      return true;
    } catch (e) {
      fail(e);
      if (e instanceof Error && e.message === 'stale_revision') { await loadChain(); if (input.taskId) await loadTask(input.taskId); }
      return false;
    } finally { if (live.current) setBusy(false); }
  }

  const tasks = useMemo(() => {
    if (detail) return detail.tasks.map((t) => ({ taskId: t.task_id, title: t.title, priority: t.priority }));
    return chain.tasks.map((t) => ({ taskId: t.taskId, title: t.title, priority: '' }));
  }, [detail, chain.tasks]);

  const title = detail?.title || chain.title || chain.chainId;
  const description = detail?.description ?? chain.description;
  const s = sessionRef.current;
  const ts = task ? ownerTaskState(task.runtime) : null;
  // Changes only on a reachable owner whose chain is confirmed active.
  const editable = !offline && Boolean(detail) && chainStatus === 'active';

  return (
    <div data-debug-id="owner-chain-view" className="flex h-full min-w-0 flex-col overflow-y-auto text-left">
      <header className="flex flex-wrap items-start justify-between gap-2 border-b border-subtle px-4 py-3">
        <div className="min-w-0">
          <h2 data-debug-id="owner-chain-title" className="truncate text-base font-semibold text-primary">{title}</h2>
          <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted">
            <Badge tone="info" data-debug-id="owner-chain-owner-badge">Bridge-owned</Badge>
            <span className="inline-flex items-center gap-1.5" data-debug-id="owner-chain-bridge-state">
              <StatusDot size="sm" tone={offline ? 'neutral' : 'success'} label={offline ? 'Owner offline' : 'Owner online'} />
              {chain.bridgeName} · {offline ? 'offline' : 'online'}
            </span>
            {!offline && detail && (
              <Badge tone={chainStatus === 'active' ? 'info' : chainStatus === 'completed' ? 'success' : 'neutral'} data-debug-id="owner-chain-status">
                {chainStatus === 'active' ? 'Active' : chainStatus === 'completed' ? 'Completed' : 'Status unknown'}
              </Badge>
            )}
            {chain.migrated && <Badge tone="neutral">Moved from Hub</Badge>}
            {chain.pending && <Badge tone="pending">Registering</Badge>}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Button size="sm" variant="ghost" data-debug-id="owner-chain-refresh" disabled={loading || busy} onClick={() => { setOffline(false); void loadChain(); if (selected) void loadTask(selected); }}>Refresh</Button>
          <Button size="sm" variant="ghost" data-debug-id="owner-chain-debug-toggle" aria-pressed={debug} onClick={() => setDebug((v) => !v)}>Advanced/debug</Button>
          {onClose && <Button size="sm" variant="ghost" data-debug-id="owner-chain-close" onClick={onClose}>Close</Button>}
        </div>
      </header>

      {offline && (
        <div role="status" data-debug-id="owner-chain-offline" className="mx-4 mt-3 rounded-lg border border-warning/30 bg-warning-soft px-3 py-2 text-sm text-warning">
          {ownerOfflineMessage(chain.bridgeName)}
        </div>
      )}
      {error && <div role="alert" data-debug-id="owner-chain-error" className="mx-4 mt-3 rounded-lg border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">{error}</div>}
      {notice && !error && <div role="status" data-debug-id="owner-chain-notice" className="mx-4 mt-3 text-xs text-muted">{notice}</div>}
      {!offline && detail && chainStatus !== 'active' && (
        <p data-debug-id="owner-chain-readonly" className="mx-4 mt-3 text-xs text-muted">
          {chainStatus === 'completed' ? 'This chain is completed; it is read-only.' : 'The chain’s status could not be read; changes are unavailable.'}
        </p>
      )}
      {chain.sealed && <p className="mx-4 mt-3 text-xs text-muted">Some titles are sealed with a key this device does not hold.</p>}

      {description ? <p data-debug-id="owner-chain-description" className="whitespace-pre-wrap px-4 pt-3 text-sm text-muted">{description}</p> : null}

      <div className="grid min-h-0 flex-1 gap-4 p-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
        <section aria-label="Tickets" className="min-w-0 space-y-2">
          <h3 className="text-xs font-semibold uppercase tracking-wider text-muted">Tickets {loading && <span className="normal-case">· loading…</span>}</h3>
          {tasks.length === 0 && !loading && <p data-debug-id="owner-chain-no-tasks" className="text-xs italic text-faint">No tickets yet.</p>}
          <ul className="space-y-1.5">
            {tasks.map((t) => {
              const rt = states[t.taskId];
              const st = rt ? ownerTaskState(rt) : null;
              return (
                <li key={t.taskId}>
                  <button type="button" data-debug-id={`owner-chain-task-${t.taskId}`} disabled={offline}
                    onClick={() => setSelected(t.taskId)}
                    className={`flex w-full min-w-0 flex-col gap-1 rounded-lg border px-3 py-2 text-left ${selected === t.taskId ? 'border-accent/40 bg-accent/10' : 'border-subtle bg-surface hover:bg-surface-raised'} disabled:cursor-default`}>
                    <span className="truncate text-sm text-primary">{t.title || t.taskId}</span>
                    <span className="flex flex-wrap items-center gap-1.5">
                      {st && <Badge tone={STATE_TONE[st.state]} data-debug-id={`owner-chain-task-state-${t.taskId}`}>{TASK_STATE_LABELS[st.state]}</Badge>}
                      {st?.held && <Badge tone="warning">Held</Badge>}
                      {st?.blocked && <Badge tone="danger">Blocked</Badge>}
                      {t.priority && t.priority !== 'p2' && <Badge tone="neutral">{t.priority.toUpperCase()}</Badge>}
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
          {detail?.truncated && <p className="text-xs text-muted">Showing the first {detail.tasks.length} tickets.</p>}
          {editable && (
            <form data-debug-id="owner-chain-create-task-form" className="space-y-1.5 rounded-lg border border-subtle p-3" onSubmit={(e) => {
              e.preventDefault();
              if (!newTitle.trim()) return;
              const taskId = ownerId('task_');
              void mutate('task.create', { taskId, title: newTitle.trim(), body: newBody.trim() }, 'Ticket created.').then((ok) => { if (ok) { setNewTitle(''); setNewBody(''); } });
            }}>
              <input aria-label="New ticket title" placeholder="New ticket title" data-debug-id="owner-chain-new-task-title" value={newTitle} onChange={(e) => setNewTitle(e.target.value)}
                className="w-full rounded-md border border-subtle bg-canvas px-2 py-1.5 text-sm text-primary" />
              <textarea aria-label="New ticket description" placeholder="Description (optional)" data-debug-id="owner-chain-new-task-body" value={newBody} onChange={(e) => setNewBody(e.target.value)} rows={2}
                className="w-full rounded-md border border-subtle bg-canvas px-2 py-1.5 text-sm text-primary" />
              <Button size="sm" type="submit" variant="primary" data-debug-id="owner-chain-create-task" disabled={busy || !newTitle.trim()}>Create ticket</Button>
            </form>
          )}
        </section>

        <section aria-label="Ticket details" data-debug-id="owner-chain-task-detail" className="min-w-0 space-y-4">
          {offline ? null : !selected ? (
            <p className="text-sm text-muted">Select a ticket to see its brief, comments, submissions and reviews.</p>
          ) : taskLoading && !task ? (
            <p role="status" className="text-sm text-muted">Loading ticket…</p>
          ) : task && ts ? (
            <>
              <div>
                <h3 data-debug-id="owner-chain-task-title" className="text-base font-semibold text-primary">{task.detail.title || task.taskId}</h3>
                <div className="mt-1 flex flex-wrap gap-1.5">
                  <Badge tone={STATE_TONE[ts.state]} data-debug-id="owner-chain-task-detail-state">{TASK_STATE_LABELS[ts.state]}</Badge>
                  {ts.held && <Badge tone="warning">Held{task.runtime.control?.reason ? ': ' + task.runtime.control.reason : ''}</Badge>}
                  {ts.blocked && <Badge tone="danger">Blocked{task.runtime.control?.waitingOn ? ' on ' + task.runtime.control.waitingOn : ''}</Badge>}
                  {ts.merge && <Badge tone="pending">{ts.merge === 'merge_blocked' ? 'Merge blocked' : 'Merge pending'}</Badge>}
                  <Badge tone="neutral">{task.detail.priority.toUpperCase()}</Badge>
                </div>
              </div>

              {editable && <div className="flex flex-wrap gap-2">
                {ts.held
                  ? <Button size="sm" data-debug-id="owner-chain-release" disabled={busy} onClick={() => void mutate('task.release', { taskId: task.taskId, body: reason }, 'Hold released.')}>Release hold</Button>
                  : ts.state !== 'cancelled' && ts.state !== 'done' && <Button size="sm" data-debug-id="owner-chain-hold" disabled={busy} onClick={() => void mutate('task.hold', { taskId: task.taskId, body: reason }, 'Ticket held.')}>Hold</Button>}
                {ts.state === 'cancelled'
                  ? <Button size="sm" data-debug-id="owner-chain-reopen" disabled={busy} onClick={() => void mutate('task.reopen', { taskId: task.taskId, body: reason }, 'Ticket reopened.')}>Reopen</Button>
                  : ts.state !== 'done' && <Button size="sm" variant="danger" data-debug-id="owner-chain-cancel" disabled={busy} onClick={() => void mutate('task.cancel', { taskId: task.taskId, body: reason }, 'Ticket cancelled.')}>Cancel ticket</Button>}
                <input aria-label="Reason (optional)" placeholder="Reason (optional)" data-debug-id="owner-chain-control-reason" value={reason} onChange={(e) => setReason(e.target.value)}
                  className="min-w-0 flex-1 rounded-md border border-subtle bg-canvas px-2 py-1 text-xs text-primary" />
              </div>}

              <section data-debug-id="owner-chain-brief" className="space-y-1">
                <h4 className="text-xs font-semibold uppercase tracking-wider text-muted">Brief</h4>
                {task.detail.body ? <p className="whitespace-pre-wrap text-sm text-primary">{task.detail.body}</p> : <p className="text-xs italic text-faint">No description.</p>}
                {task.runtime.requirements ? (
                  <div data-debug-id="owner-chain-requirements" className="rounded-lg border border-subtle p-3">
                    <p className="text-xs text-muted">Requirements · Rev {task.runtime.requirements.revision}</p>
                    {task.runtime.requirements.goal && <p className="mt-1 whitespace-pre-wrap text-sm text-primary">{task.runtime.requirements.goal}</p>}
                    {task.runtime.requirements.acceptance.length > 0 && (
                      <ul className="mt-1 list-disc pl-5 text-sm text-primary">
                        {task.runtime.requirements.acceptance.map((a, i) => <li key={i}>{a}</li>)}
                      </ul>
                    )}
                  </div>
                ) : <p className="text-xs italic text-faint">No requirements saved.</p>}
              </section>

              <section data-debug-id="owner-chain-submissions" className="space-y-1">
                <h4 className="text-xs font-semibold uppercase tracking-wider text-muted">Submissions</h4>
                {task.runtime.attemptNo === 0 && !task.runtime.submission
                  ? <p className="text-xs italic text-faint">No attempts yet.</p>
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
                  <div data-debug-id="owner-chain-submission" className="rounded-lg border border-subtle p-3 text-sm">
                    <p className="text-xs text-muted">Attempt {submission.attempt}{submission.author ? ' · by ' + submission.author : ''}{submission.head ? ' · ' + submission.head.slice(0, 12) : ''}</p>
                    <p className="mt-1 whitespace-pre-wrap text-primary">{submission.summary || 'No summary.'}</p>
                  </div>
                )}
              </section>

              <section data-debug-id="owner-chain-reviews" className="space-y-1">
                <h4 className="text-xs font-semibold uppercase tracking-wider text-muted">Reviews</h4>
                {task.reviewsLoading && <p role="status" data-debug-id="owner-chain-reviews-loading" className="text-xs text-muted">Loading reviews…</p>}
                {task.reviewsError && <p role="alert" className="text-xs text-danger">{task.reviewsError}</p>}
                {task.reviewsTruncated && (
                  <p role="status" data-debug-id="owner-chain-reviews-truncated" className="text-xs text-warning">
                    This chain’s history is longer than the view scans; newer reviews may be missing. Use Advanced/debug to read the full history.
                  </p>
                )}
                {task.reviewsMore && <p data-debug-id="owner-chain-reviews-more" className="text-xs text-muted">Showing the latest owner reviews only.</p>}
                {task.reviews.length === 0 && !task.reviewsLoading && !task.reviewsError && !task.reviewsTruncated && <p className="text-xs italic text-faint">No reviews.</p>}
                <ul className="space-y-1.5">
                  {task.reviews.map((r, i) => (
                    <li key={i} data-debug-id={`owner-chain-review-${r.source}-${i}`} className="rounded-lg border border-subtle p-2 text-sm">
                      <span className="flex flex-wrap items-center gap-1.5 text-xs text-muted">
                        <Badge tone={r.verdict === 'approve' ? 'success' : 'danger'}>{r.verdict === 'approve' ? 'Approved' : 'Changes requested'}</Badge>
                        <span>{r.reviewer}{r.role ? ' (' + r.role + ')' : ''}</span>
                        {r.attempt && <span>· attempt {r.attempt}</span>}
                        {r.at && <span>· {formatWhen(r.at)}</span>}
                        {r.source === 'archived' && <Badge tone="neutral">Archived from Hub</Badge>}
                      </span>
                      {r.summary && <p className="mt-1 whitespace-pre-wrap text-primary">{r.summary}</p>}
                    </li>
                  ))}
                </ul>
                {editable && ts.state === 'in_review' && task.runtime.submission && (
                  <div className="space-y-1.5 rounded-lg border border-subtle p-3">
                    <textarea aria-label="Review summary" placeholder="Review summary" data-debug-id="owner-chain-review-summary" value={reviewSummary} onChange={(e) => setReviewSummary(e.target.value)} rows={2}
                      className="w-full rounded-md border border-subtle bg-canvas px-2 py-1.5 text-sm text-primary" />
                    <div className="flex gap-2">
                      {(['approve', 'request_changes'] as const).map((verdict) => (
                        <Button key={verdict} size="sm" variant={verdict === 'approve' ? 'primary' : 'secondary'} data-debug-id={`owner-chain-review-${verdict}`} disabled={busy}
                          onClick={() => void mutate('review.post', {
                            taskId: task.taskId, verdict, body: reviewSummary,
                            attempt: task.runtime.submission!.attempt, head: task.runtime.submission!.head, requirementsRevision: task.runtime.submission!.requirementsRevision,
                          }, verdict === 'approve' ? 'Approval recorded.' : 'Change request recorded.').then((ok) => { if (ok) setReviewSummary(''); })}>
                          {verdict === 'approve' ? 'Approve' : 'Request changes'}
                        </Button>
                      ))}
                    </div>
                  </div>
                )}
              </section>

              <section data-debug-id="owner-chain-comments" className="space-y-1">
                <h4 className="text-xs font-semibold uppercase tracking-wider text-muted">Comments</h4>
                {task.detail.comments.length === 0 && <p className="text-xs italic text-faint">No comments yet.</p>}
                <ul className="space-y-1.5">
                  {task.detail.comments.map((c) => (
                    <li key={c.principal_id + ':' + c.operation_id} data-debug-id={`owner-chain-comment-${c.operation_id}`} className="rounded-lg border border-subtle p-2">
                      <span className="flex flex-wrap gap-1.5 text-xs text-muted">
                        <span className="font-semibold text-primary">{principalLabel(s, c.principal_id)}</span>
                        {c.created_at && <time dateTime={c.created_at}>{formatWhen(c.created_at)}</time>}
                      </span>
                      <p className="mt-1 whitespace-pre-wrap text-sm text-primary">{c.body}</p>
                    </li>
                  ))}
                </ul>
                {task.detail.truncated && <p className="text-xs text-muted">Showing the first {task.detail.comments.length} comments.</p>}
                {editable && <form className="space-y-1.5" onSubmit={(e) => {
                  e.preventDefault();
                  if (!comment.trim()) return;
                  void mutate('task.comment', { taskId: task.taskId, body: comment.trim() }, 'Comment added.').then((ok) => { if (ok) setComment(''); });
                }}>
                  <textarea aria-label="Add a comment" placeholder="Add a comment" data-debug-id="owner-chain-comment-input" value={comment} onChange={(e) => setComment(e.target.value)} rows={2}
                    className="w-full rounded-md border border-subtle bg-canvas px-2 py-1.5 text-sm text-primary" />
                  <Button size="sm" type="submit" data-debug-id="owner-chain-comment-submit" disabled={busy || !comment.trim()}>Comment</Button>
                </form>}
              </section>
            </>
          ) : null}
        </section>
      </div>

      {debug && (
        <OwnerLocalPanel initialChainId={chain.chainId} initialBridgeId={bridge} initialTaskId={selected || undefined}
          initialSubmissionAttempt={submission?.attempt} onClose={() => setDebug(false)} />
      )}
    </div>
  );
}

export default OwnerChainView;
