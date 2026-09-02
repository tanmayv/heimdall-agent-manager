import { useState } from 'react';
import type { ChainLike, TaskLike } from './chainTaskInference';
import { taskStatusOf, taskReviewerOf, isUserEffectiveReviewer } from './chainTaskInference';

export type CurrentTaskStripProps = {
  task: TaskLike;
  chain?: ChainLike | null;
  agentInstanceId: string;
  role: 'assignee' | 'reviewer' | 'coordinator' | 'assigned' | 'observer';
  debugPrefix: string;
  // Task-comment creation: creates a task comment, NOT a chat message.
  onComment?: (taskId: string, body: string) => void | Promise<void>;
  // Submit the current task for review (assignee action).
  onSubmitForReview?: (taskId: string) => void | Promise<void>;
  // Nudge the assignee (coordinator/user action).
  onNudge?: (taskId: string) => void | Promise<void>;
  // Vote good/not-good (reviewer action).
  onVote?: (taskId: string, approved: boolean) => void | Promise<void>;
  // Open the task detail in the full chain view.
  onOpenTask?: (taskId: string) => void;
  // CT-9: candidate tasks the agent can be switched to (assignee/reviewer of).
  // When provided with onSwitchCurrentTask, renders a manual "switch current task"
  // control (user/coordinator action).
  switchableTasks?: TaskLike[];
  onSwitchCurrentTask?: (taskId: string) => void | Promise<void>;
  // CT-3: change this task's priority (P0/P1/P2) — user/coordinator action.
  onSetPriority?: (taskId: string, priority: string) => void | Promise<void>;
  collapsed?: boolean;
};

function statusTone(status: string): string {
  const s = status.toLowerCase();
  if (s === 'in_progress') return 'bg-teal-500/15 text-teal-200 border-teal-500/30';
  if (s === 'review_ready' || s === 'in_validation') return 'bg-sky-500/15 text-sky-200 border-sky-500/30';
  if (s === 'validated_not_good') return 'bg-rose-500/15 text-rose-200 border-rose-500/30';
  if (s === 'blocked') return 'bg-rose-500/15 text-rose-200 border-rose-500/30';
  // CT-2: Queued is a distinct held-back state — amber so it reads as "waiting".
  if (s === 'queued') return 'bg-amber-500/15 text-amber-200 border-amber-500/30';
  if (s === 'ready' || s === 'planning') return 'bg-zinc-500/15 text-zinc-300 border-zinc-500/30';
  return 'bg-white/5 text-zinc-400 border-white/10';
}

// CT-3: P0/P1/P2 priority indicator. P0 is most urgent (red), P1 amber, P2 muted.
export function priorityOf(task: { priority?: string }): string {
  return String(task?.priority || '').toLowerCase();
}
function priorityTone(priority: string): string {
  const p = priority.toLowerCase();
  if (p === 'p0') return 'bg-red-500/20 text-red-200 border-red-500/40';
  if (p === 'p1') return 'bg-amber-500/15 text-amber-200 border-amber-500/30';
  if (p === 'p2') return 'bg-zinc-500/10 text-zinc-400 border-zinc-500/25';
  return '';
}

// R8: the current-task role rendered as an explicit WORK vs REVIEW action label.
function roleActionLabel(role: string): string {
  const r = String(role || '').toLowerCase();
  if (r === 'reviewer') return 'REVIEW';
  if (r === 'assignee' || r === 'assigned') return 'WORK';
  if (r === 'coordinator') return 'COORDINATE';
  return String(role || '').toUpperCase();
}
function roleActionTone(role: string): string {
  const r = String(role || '').toLowerCase();
  if (r === 'reviewer') return 'bg-sky-500/15 text-sky-200 border-sky-500/30';
  if (r === 'assignee' || r === 'assigned') return 'bg-teal-500/15 text-teal-200 border-teal-500/30';
  return 'bg-white/5 text-zinc-300 border-white/10';
}

// Derive the first 1-2 acceptance criteria from the chain description / task description.
function acceptanceSummary(task: TaskLike): string {
  const raw = String(task.description || '').trim();
  if (!raw) return '';
  // Pull lines that look like acceptance criteria (## Acceptance, - bullet).
  const lines = raw.split('\n');
  const crit: string[] = [];
  let inAcceptance = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (/^#{1,6}\s*accept/i.test(trimmed)) { inAcceptance = true; continue; }
    if (inAcceptance && /^#{1,6}/.test(trimmed)) { inAcceptance = false; continue; }
    if (inAcceptance && trimmed.startsWith('-')) crit.push(trimmed.replace(/^[-*]\s*/, '').slice(0, 80));
  }
  if (crit.length > 0) return crit.slice(0, 2).join(' · ');
  // Fallback: first non-empty line.
  return raw.split('\n').map((l) => l.trim()).filter(Boolean)[0]?.slice(0, 80) || '';
}

export default function CurrentTaskStrip({
  task,
  chain,
  agentInstanceId,
  role,
  debugPrefix,
  onComment,
  onSubmitForReview,
  onNudge,
  onVote,
  onOpenTask,
  switchableTasks,
  onSwitchCurrentTask,
  onSetPriority,
  collapsed = false,
}: CurrentTaskStripProps) {
  const [commenting, setCommenting] = useState(false);
  const [commentBody, setCommentBody] = useState('');
  const [collapsedLocal, setCollapsedLocal] = useState(collapsed);

  const taskId = String(task.taskId || task.task_id || '');
  const status = taskStatusOf(task);
  const priority = priorityOf(task as any);
  const title = String(task.title || taskId);
  const reviewer = taskReviewerOf(task);
  const userIsReviewer = isUserEffectiveReviewer(task);
  const summary = acceptanceSummary(task);

  if (collapsedLocal) {
    return (
      <div data-debug-id={`${debugPrefix}-current-task-strip`} data-current-task-status={status} className="mb-2 flex items-center justify-between gap-2 rounded-xl border border-white/10 bg-[#101010] px-3 py-2 text-[11.5px] text-zinc-500">
        <span className="truncate">Current task: <span className="text-zinc-300">{title}</span></span>
        <button type="button" data-debug-id={`${debugPrefix}-current-task-expand`} onClick={() => setCollapsedLocal(false)} className="rounded-full border border-white/10 px-2 py-0.5 text-zinc-400 hover:bg-white/10">expand</button>
      </div>
    );
  }

  async function submitComment() {
    const body = commentBody.trim();
    if (!body || !onComment) return;
    setCommentBody('');
    setCommenting(false);
    try {
      await onComment(taskId, body);
    } catch {
      // caller surfaces its own error UI
    }
  }

  return (
    <div data-debug-id={`${debugPrefix}-current-task-strip`} data-current-task-status={status} data-task-comment-mode="true" className="mb-2 rounded-[15px] border border-teal-500/25 bg-teal-500/[0.04] px-3 py-2.5 text-[12px] text-zinc-200 shadow-[0_8px_30px_rgba(0,0,0,0.18)]">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="shrink-0 text-[10px] uppercase tracking-wide text-teal-300/70">Current task</span>
            <span className="truncate font-medium text-zinc-100">{title}</span>
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-1.5 text-[11px] text-zinc-500">
            {/* R8: explicit WORK vs REVIEW action label for the current-task role. */}
            <span data-debug-id={`${debugPrefix}-current-task-action`} data-current-task-action={roleActionLabel(role)} className={`rounded-full border px-2 py-0.5 font-semibold tracking-wide ${roleActionTone(role)}`}>{roleActionLabel(role)}</span>
            <span className={`rounded-full border px-2 py-0.5 ${statusTone(status)}`}>{status}</span>
            {/* CT-3: P0/P1/P2 priority indicator (hidden when unknown). */}
            {priorityTone(priority) ? <span data-debug-id={`${debugPrefix}-current-task-priority`} data-current-task-priority={priority} className={`rounded-full border px-2 py-0.5 font-semibold uppercase ${priorityTone(priority)}`}>{priority}</span> : null}
            <span>Assignee: <span className="text-zinc-300">{agentInstanceId}</span></span>
            {reviewer ? <span>Reviewer: <span className="text-zinc-300">{reviewer}</span></span> : null}
          </div>
          {summary ? <div data-debug-id={`${debugPrefix}-current-task-acceptance`} className="mt-1.5 truncate text-[11px] text-zinc-500">Acceptance: {summary}</div> : null}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          {onOpenTask ? <button type="button" data-debug-id={`${debugPrefix}-current-task-open`} onClick={() => onOpenTask(taskId)} className="rounded-full border border-white/10 px-2.5 py-1 text-zinc-300 hover:bg-white/10">Open</button> : null}
          <button type="button" data-debug-id={`${debugPrefix}-current-task-collapse`} onClick={() => setCollapsedLocal(true)} className="rounded-full border border-white/10 px-2 py-1 text-zinc-500 hover:bg-white/10">−</button>
        </div>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        {role === 'assignee' && onSubmitForReview ? (
          <button type="button" data-debug-id={`${debugPrefix}-current-task-submit-review`} onClick={() => void onSubmitForReview(taskId)} className="rounded-full border border-sky-400/30 bg-sky-400/10 px-2.5 py-1 text-sky-100 hover:bg-sky-400/20">Submit for review</button>
        ) : null}
        {(role === 'reviewer' || userIsReviewer) && onVote ? (
          <>
            <button type="button" data-debug-id={`${debugPrefix}-current-task-vote-good`} onClick={() => void onVote(taskId, true)} className="rounded-full border border-emerald-400/30 bg-emerald-400/10 px-2.5 py-1 text-emerald-100 hover:bg-emerald-400/20">Approve</button>
            <button type="button" data-debug-id={`${debugPrefix}-current-task-vote-bad`} onClick={() => void onVote(taskId, false)} className="rounded-full border border-rose-400/30 bg-rose-400/10 px-2.5 py-1 text-rose-100 hover:bg-rose-400/20">Request changes</button>
          </>
        ) : null}
        {role === 'coordinator' && onNudge ? (
          <button type="button" data-debug-id={`${debugPrefix}-current-task-nudge`} onClick={() => void onNudge(taskId)} className="rounded-full border border-amber-400/30 bg-amber-400/10 px-2.5 py-1 text-amber-100 hover:bg-amber-400/20">Nudge</button>
        ) : null}
        {onComment ? (
          <button type="button" data-debug-id={`${debugPrefix}-current-task-comment-btn`} onClick={() => setCommenting((open) => !open)} className="rounded-full border border-white/10 px-2.5 py-1 text-zinc-300 hover:bg-white/10">Comment</button>
        ) : null}
        {/* CT-9: manual "switch current task" control (user/coordinator). */}
        {onSwitchCurrentTask && switchableTasks && switchableTasks.length > 0 ? (
          <select
            data-debug-id={`${debugPrefix}-current-task-switch`}
            value={taskId}
            onChange={(event) => { const next = event.target.value; if (next && next !== taskId) void onSwitchCurrentTask(next); }}
            className="rounded-full border border-white/10 bg-black/30 px-2.5 py-1 text-[11px] text-zinc-300 outline-none hover:bg-white/10"
            title="Switch current task"
          >
            {switchableTasks.map((candidate) => {
              const cid = String(candidate.taskId || candidate.task_id || '');
              return <option key={cid} value={cid}>{String(candidate.title || cid)}</option>;
            })}
          </select>
        ) : null}
        {/* CT-3: set priority (P0/P1/P2) — user/coordinator. */}
        {onSetPriority ? (
          <select
            data-debug-id={`${debugPrefix}-current-task-set-priority`}
            value={priority || 'p2'}
            onChange={(event) => { const next = event.target.value; if (next && next !== priority) void onSetPriority(taskId, next); }}
            className="rounded-full border border-white/10 bg-black/30 px-2.5 py-1 text-[11px] uppercase text-zinc-300 outline-none hover:bg-white/10"
            title="Set priority"
          >
            <option value="p0">P0</option>
            <option value="p1">P1</option>
            <option value="p2">P2</option>
          </select>
        ) : null}
      </div>

      {commenting ? (
        <div data-debug-id={`${debugPrefix}-current-task-comment-composer`} className="mt-2 rounded-xl border border-white/10 bg-black/20 p-2">
          <textarea
            data-debug-id={`${debugPrefix}-current-task-comment-input`}
            value={commentBody}
            onChange={(event) => setCommentBody(event.target.value)}
            placeholder="Add a task comment (not a chat message)…"
            rows={2}
            className="w-full resize-none rounded-lg bg-transparent px-2 py-1 text-[12px] text-zinc-100 outline-none placeholder:text-zinc-600"
            onKeyDown={(event) => { if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); void submitComment(); } }}
          />
          <div className="mt-1 flex items-center justify-end gap-1.5">
            <button type="button" data-debug-id={`${debugPrefix}-current-task-comment-cancel`} onClick={() => { setCommenting(false); setCommentBody(''); }} className="rounded-full border border-white/10 px-2 py-0.5 text-[11px] text-zinc-400 hover:bg-white/10">Cancel</button>
            <button type="button" data-debug-id={`${debugPrefix}-current-task-comment-submit`} onClick={() => void submitComment()} disabled={!commentBody.trim()} className="rounded-full border border-teal-400/30 bg-teal-400/10 px-2.5 py-0.5 text-[11px] text-teal-100 hover:bg-teal-400/20 disabled:opacity-40">Add comment</button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
