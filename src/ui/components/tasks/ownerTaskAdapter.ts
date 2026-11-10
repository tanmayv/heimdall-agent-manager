// Owner-local Bridge reads → the ticket wire shape (TaskWire) that the
// origin/main ticket components render. Bridge-owned chains have no Hub task
// endpoints; the owner Bridge answers chain.read / task.read / runtime.read /
// review reads instead. This adapter is the one place that maps them, shared
// by the Task Chains page and the aux panes, so the restored presentational
// components never learn about owner operations.

import type { TaskReviewWire, TaskWire } from '../../api/taskWire';
import { ownerTaskState, type OwnerComment, type OwnerReview, type OwnerRuntime, type OwnerTaskDetail, type OwnerTaskRow } from '../../api/ownerChains';

export interface OwnerTaskSource {
  chainId: string;
  /** The owner Bridge, reported as the ticket's bridge. */
  bridgeId: string;
  taskId: string;
  /** The chain listing row (always present). */
  row?: OwnerTaskRow;
  /** task.read (title, body, priority, comments); absent until the ticket is opened. */
  detail?: OwnerTaskDetail | null;
  /** runtime.read; absent while it is still loading. */
  runtime?: OwnerRuntime | null;
  reviews?: OwnerReview[];
}

/** Brief fields the owner store keeps verbatim in the requirements JSON. */
function rawBrief(raw: string): Record<string, unknown> {
  try {
    const b = JSON.parse(raw);
    return b && typeof b === 'object' && !Array.isArray(b) ? b : {};
  } catch { return {}; }
}

function commentSummary(comments: OwnerComment[]): TaskWire['comment_summary'] {
  if (!comments.length) return undefined;
  const last = comments[comments.length - 1];
  return {
    count: comments.length,
    last_comment_at: last.created_at,
    last_comment_author_agent_instance_id: /^inst_/.test(last.principal_id) ? last.principal_id : '',
    last_comment_preview: last.body.slice(0, 200),
  };
}

/** One owner review (device-signed = the user) in the wire's per-reviewer form. */
export function ownerReviewWire(r: OwnerReview): TaskReviewWire {
  const instance = /^inst_/.test(r.reviewer) ? r.reviewer : '';
  return {
    reviewer: r.byDevice ? 'user' : r.reviewer,
    reviewer_kind: r.byDevice ? 'user' : 'agent',
    reviewer_instance_id: instance,
    role: r.role,
    verdict: r.verdict,
    created_at: r.at,
  };
}

const MERGE_STATE: Record<string, NonNullable<TaskWire['merge']>['state']> = {
  merge_pending: 'pending', merge_blocked: 'conflict',
};

export function ownerTaskWire(src: OwnerTaskSource): TaskWire {
  const rt = src.runtime ?? null;
  const detail = src.detail ?? null;
  const flags = rt ? ownerTaskState(rt) : { state: 'ready' as const, held: false, blocked: false, merge: '' };
  const brief = rt?.requirements ? rawBrief(rt.requirements.raw) : {};
  const reviewers = Array.isArray(brief.reviewers) ? brief.reviewers.map(String).filter(Boolean) : [];
  const attempt = Number(rt?.attempt) || rt?.attemptNo || 0;
  // Reviews of the current attempt are the ones the gate counts.
  const reviews = (src.reviews ?? []).filter((r) => !rt || !r.attempt || r.attempt === rt.attempt).map(ownerReviewWire);

  let merge: TaskWire['merge'];
  if (flags.merge) merge = { state: MERGE_STATE[flags.merge] ?? 'pending', head: rt?.submission?.head || undefined };
  else if (flags.state === 'done') merge = { state: rt?.submission?.head ? 'merged' : 'none', head: rt?.submission?.head || undefined };

  const blockedOn = rt?.control && (flags.blocked || flags.held)
    ? { kind: flags.held ? 'hold' : (rt.control.waitingOn || 'user'), ref: rt.control.waitingOn, reason: rt.control.reason }
    : null;

  return {
    task_id: src.taskId,
    chain_id: src.chainId,
    title: detail?.title || src.row?.title || '',
    description: detail?.body || '',
    publish_state: 'published',
    state: flags.state,
    kind: 'work',
    priority: detail?.priority || src.row?.priority || 'p2',
    attempt_no: attempt,
    bridge_id: src.bridgeId,
    brief: rt?.requirements
      ? { ...brief, goal: rt.requirements.goal, acceptance: rt.requirements.acceptance, reviewers }
      : null,
    blocked_on: blockedOn,
    blocked: flags.blocked,
    requires_user_approval: Boolean(rt?.requirements?.requiresUserApproval),
    ready_since: '',
    depends_on: Array.isArray(brief.depends_on) ? brief.depends_on.map(String) : undefined,
    requirements: rt?.requirements
      ? {
        revision: Number(rt.requirements.revision) || 0,
        submitted_revision: Number(rt.submission?.requirementsRevision) || 0,
        submitted_head: rt.submission?.head ?? '',
        checkpoint_required: false,
        acknowledgements: [],
        history: '',
        history_truncated: false,
      }
      : undefined,
    merge,
    leases: rt?.holder
      ? [{
        lease_id: rt.lease?.id ?? '', kind: 'work', holder_instance_id: rt.holder, attempt_no: attempt, bridge_id: src.bridgeId,
        granted_at: '', confirmed_at: '',
        expires_at: rt.lease?.expiresMs ? new Date(rt.lease.expiresMs).toISOString() : '',
        hard_deadline_at: rt.lease?.hardMs ? new Date(rt.lease.hardMs).toISOString() : '',
        delivery: '',
      }]
      : [],
    reviews,
    comment_summary: commentSummary(detail?.comments ?? []),
    // Owner-only extras the ticket detail shows (not part of the Hub wire).
    owner_revision: rt?.revision ?? src.row?.revision ?? '',
    owner_submission: rt?.submission ?? null,
  };
}

/** The listing rows with whatever runtime is known, in listing order. */
export function ownerTaskWires(chainId: string, bridgeId: string, rows: OwnerTaskRow[], runtimes: Record<string, OwnerRuntime | undefined>): TaskWire[] {
  return rows.map((row) => ownerTaskWire({ chainId, bridgeId, taskId: row.task_id, row, runtime: runtimes[row.task_id] ?? null }));
}

/** The brief fields the ticket page edits (requirements.edit). */
export interface OwnerRequirementsEdit {
  goal: string;
  acceptance: string[];
  /** Reviewer agent ids (the reviewer-ids model). */
  reviewers: string[];
  requiresUserApproval: boolean;
  /** This revision's audit note; never part of the brief content. */
  reason: string;
}

/**
 * The next requirements document: the current brief with the edited fields
 * replaced. Fields the page does not edit (assignee, depends_on, inputs, …)
 * are kept verbatim; a previous revision's reason is never carried over.
 */
export function ownerRequirementsDoc(raw: string, edit: OwnerRequirementsEdit): string {
  const brief: Record<string, unknown> = { ...rawBrief(raw) };
  delete brief.requirements_reason;
  brief.goal = edit.goal.trim();
  brief.acceptance = edit.acceptance.map((a) => a.trim()).filter(Boolean);
  const reviewers = [...new Set(edit.reviewers.map((r) => r.trim()).filter(Boolean))];
  if (reviewers.length) brief.reviewers = reviewers; else delete brief.reviewers;
  if (edit.requiresUserApproval) brief.requires_user_approval = true; else delete brief.requires_user_approval;
  if (edit.reason.trim()) brief.requirements_reason = edit.reason.trim();
  return JSON.stringify(brief);
}
