// Owner-local Bridge reads → the ticket wire shape (TaskWire) that the
// origin/main ticket components render. Bridge-owned chains have no Hub task
// endpoints; the owner Bridge answers chain.read / task.read / runtime.read /
// review reads instead. This adapter is the one place that maps them, shared
// by the Task Chains page and the aux panes, so the restored presentational
// components never learn about owner operations.

import type { Tone } from '@ui';
import type { TaskReviewWire, TaskWire } from '../../api/taskWire';
import type { RequirementRevisionEntry } from './ticketModel';
import type { TicketCommentItem, TicketEventItem, TicketHandoffItem, TicketReviewItem } from './TicketActivity';
import {
  ownerTaskState, type OwnerActivity, type OwnerComment, type OwnerDependency, type OwnerHandoff, type OwnerRequirementChange, type OwnerReview,
  type OwnerRuntime, type OwnerTaskDetail, type OwnerTaskRow,
} from '../../api/ownerChains';

export interface OwnerTaskSource {
  chainId: string;
  /** The owner Bridge: the ticket's bridge unless its brief pins run_bridge_id. */
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
    bridge_id: ownerRunBridge(brief, src.bridgeId),
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

/** The ticket's run Bridge: the brief's run_bridge_id, else the owner Bridge. */
export function ownerRunBridge(brief: Record<string, unknown>, ownerBridgeId: string): string {
  const pin = typeof brief.run_bridge_id === 'string' ? brief.run_bridge_id.trim() : '';
  return pin || ownerBridgeId;
}

/**
 * The run-Bridge choices: the owner Bridge first (the default), then the
 * account's other non-revoked Bridges.
 */
export function ownerRunBridgeOptions(
  bridges: { bridge_id?: string; id?: string; name?: string; label?: string; status?: string; revoked_at?: string }[],
  ownerBridgeId: string,
  ownerName: string,
): { value: string; text: string }[] {
  const others = bridges
    .map((b) => ({ id: String(b.bridge_id || b.id || ''), name: String(b.name || b.label || ''), revoked: Boolean(b.revoked_at) || String(b.status || '').toLowerCase() === 'revoked' }))
    .filter((b) => b.id && b.id !== ownerBridgeId && !b.revoked)
    .map((b) => ({ value: b.id, text: b.name || b.id }));
  return [{ value: ownerBridgeId, text: `${ownerName || ownerBridgeId} (owner, default)` }, ...others];
}

/**
 * The next requirements document with the run Bridge pinned to `bridgeId`;
 * '' or the owner Bridge clears the pin (the owner Bridge is the default).
 */
export function ownerRunBridgeDoc(raw: string, bridgeId: string, ownerBridgeId: string): string {
  const brief: Record<string, unknown> = { ...rawBrief(raw) };
  delete brief.requirements_reason;
  const pin = bridgeId.trim();
  if (pin && pin !== ownerBridgeId) brief.run_bridge_id = pin; else delete brief.run_bridge_id;
  brief.requirements_reason = pin && pin !== ownerBridgeId ? `Run Bridge set to ${pin}.` : 'Run Bridge reset to the owner Bridge.';
  return JSON.stringify(brief);
}

/**
 * The task's per-agent provider/model overrides (brief agent_models) as
 * "provider[/model]" per agent id; an agent without one is absent.
 */
export function ownerAgentModels(raw: string): Record<string, string> {
  const models = rawBrief(raw).agent_models;
  const out: Record<string, string> = {};
  if (!models || typeof models !== 'object' || Array.isArray(models)) return out;
  for (const [agent, entry] of Object.entries(models as Record<string, unknown>)) {
    const e = (entry ?? {}) as { provider?: unknown; model?: unknown };
    const provider = typeof e.provider === 'string' ? e.provider : '';
    const model = typeof e.model === 'string' ? e.model : '';
    if (provider) out[agent] = model ? `${provider}/${model}` : provider;
  }
  return out;
}

/**
 * The next requirements document with `agentId`'s override set to
 * "provider[/model]"; '' clears it. Other agents' overrides are kept. The
 * owner Bridge launches that agent for this task with it (beats the fleet).
 */
export function ownerAgentModelDoc(raw: string, agentId: string, value: string): string {
  const brief: Record<string, unknown> = { ...rawBrief(raw) };
  delete brief.requirements_reason;
  const current = brief.agent_models && typeof brief.agent_models === 'object' && !Array.isArray(brief.agent_models) ? { ...(brief.agent_models as Record<string, unknown>) } : {};
  const v = value.trim();
  const slash = v.indexOf('/');
  const provider = slash >= 0 ? v.slice(0, slash).trim() : v;
  const model = slash >= 0 ? v.slice(slash + 1).trim() : '';
  if (provider) current[agentId] = { provider, model }; else delete current[agentId];
  brief.agent_models = current;
  brief.requirements_reason = provider ? `Model for ${agentId} set to ${model ? `${provider}/${model}` : provider}.` : `Model override for ${agentId} cleared.`;
  return JSON.stringify(brief);
}

/**
 * Owner requirement history (newest first, readOwnerRequirementHistory) as
 * origin/main's revision entries: each change's "before" is the next older
 * change (empty for the first one, or when it could not be decrypted). A
 * device actor is the user.
 */
export function ownerRequirementHistoryEntries(changes: OwnerRequirementChange[]): RequirementRevisionEntry[] {
  return changes.map((c, i) => {
    const prev = changes[i + 1];
    const ms = c.at ? Date.parse(c.at) : 0;
    return {
      revision: Number(c.revision) || 0,
      actorKind: c.actorKind === 'device' ? 'user' : c.actorKind,
      actorId: c.actorId,
      tsMs: Number.isFinite(ms) ? ms : 0,
      reason: c.reason,
      before: prev?.readable ? { goal: prev.goal, acceptance: prev.acceptance } : { goal: '', acceptance: [] },
      after: { goal: c.goal, acceptance: c.acceptance },
      eventId: Number(c.seq) || null,
    };
  });
}

/* Ticket tab (TicketView) feeds -------------------------------------- */

function isoMs(at: string): number {
  const ms = at ? Date.parse(at) : 0;
  return Number.isFinite(ms) ? ms : 0;
}

/** An owner history actor in the ticket feeds' terms: a device is the user. */
export function ownerActorKind(kind: string): string {
  return kind === 'device' ? 'user' : kind || 'agent';
}

const TICKET_EVENT_TEXT: Record<string, string> = {
  'task.create': 'created the ticket', 'task.edit': 'edited the ticket', 'task.delete': 'deleted the ticket',
  'task.priority': 'changed the priority', 'task.hold': 'held the ticket', 'task.release': 'released the hold',
  'task.cancel': 'cancelled the ticket', 'task.reopen': 'reopened the ticket', 'task.resolve': 'answered the blocker',
  'task.comment': 'commented', 'requirements.edit': 'changed the requirements', 'review.post': 'posted a review',
  'work.dependency.add': 'added a dependency', 'work.dependency.remove': 'removed a dependency',
  'lease.claim': 'took the ticket', 'lease.submit': 'submitted for review', 'lease.handoff': 'handed the ticket off',
  'lease.block': 'blocked the ticket', 'lease.switch': 'switched away', 'lease.release': 'released the lease',
  'merge.merged': 'merged the work', 'merge.retry': 'retried the merge',
};

/** What an owner history event did to a ticket, as a sentence rest ("commented"). */
export function ownerTicketEventText(kind: string): string {
  return TICKET_EVENT_TEXT[kind] ?? kind;
}

/** A ticket's owner history (newest first) as its Activity events. */
export function ownerTicketEvents(events: OwnerActivity[]): TicketEventItem[] {
  return events.map((e) => ({
    id: e.seq || `${e.kind}:${e.at}`,
    kind: e.kind,
    actorKind: ownerActorKind(e.actorKind),
    actorId: e.actorId,
    text: ownerTicketEventText(e.kind),
    tsMs: isoMs(e.at),
    raw: e,
  }));
}

const HANDOFF_KIND: Record<OwnerHandoff['kind'], { label: string; tone: Tone }> = {
  'lease.submit': { label: 'Submitted', tone: 'success' },
  'lease.handoff': { label: 'Handed off', tone: 'info' },
  'lease.block': { label: 'Blocked', tone: 'warning' },
  'lease.switch': { label: 'Switched away', tone: 'neutral' },
};

/** Owner handoffs (handoff, block, switch, submit; newest first) as the Handoffs feed. */
export function ownerHandoffItems(handoffs: OwnerHandoff[]): TicketHandoffItem[] {
  return handoffs.map((h) => ({
    id: h.seq,
    label: HANDOFF_KIND[h.kind]?.label ?? h.kind,
    tone: HANDOFF_KIND[h.kind]?.tone ?? 'neutral',
    actorKind: 'agent',
    actorId: h.actorId,
    tsMs: isoMs(h.at),
    summary: h.summary,
    nextSteps: h.nextSteps,
    waitingOn: h.waitingOn,
    head: h.head,
    requirementsRevision: h.requirementsRevision,
  }));
}

/** Owner and archived reviews as the Reviews feed (a device-signed review is the user's). */
export function ownerReviewItems(reviews: OwnerReview[]): TicketReviewItem[] {
  return reviews.map((r, i) => ({
    id: `${r.source}-${i}`,
    verdict: r.verdict,
    actorKind: r.byDevice ? 'user' : 'agent',
    actorId: r.byDevice ? 'user' : r.reviewer,
    role: r.role,
    attempt: r.attempt,
    tsMs: isoMs(r.at),
    summary: r.summary,
    archived: r.source === 'archived',
  }));
}

/** Owner comments (oldest first) as the Comments feed, newest first. */
export function ownerCommentItems(comments: OwnerComment[], author: (principalId: string) => string): TicketCommentItem[] {
  return comments.map((c) => ({ id: c.operation_id || `${c.principal_id}:${c.seq}`, author: author(c.principal_id), body: c.body, at: c.created_at })).reverse();
}

/** The tickets `taskId` waits for, per the owner dependencies. */
export function ownerPrerequisites(taskId: string, deps: OwnerDependency[]): string[] {
  return deps.filter((d) => d.dependent === taskId).map((d) => d.prerequisite);
}

/**
 * The dependency edits that make `taskId` wait for exactly `wanted`: the
 * prerequisites to add, and the dependency ids to remove.
 */
export function ownerDependencyChanges(taskId: string, deps: OwnerDependency[], wanted: string[]): { add: string[]; remove: string[] } {
  const current = deps.filter((d) => d.dependent === taskId);
  const want = new Set(wanted.filter((id) => id && id !== taskId));
  return {
    add: [...want].filter((id) => !current.some((d) => d.prerequisite === id)),
    remove: current.filter((d) => !want.has(d.prerequisite)).map((d) => d.dependencyId),
  };
}
