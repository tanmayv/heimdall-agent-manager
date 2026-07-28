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
  collapsed?: boolean;
};

function statusTone(status: string): string {
  const s = status.toLowerCase();
  if (s === 'in_progress') return 'bg-teal-500/15 text-teal-200 border-teal-500/30';
  if (s === 'review_ready') return 'bg-sky-500/15 text-sky-200 border-sky-500/30';
  if (s === 'blocked') return 'bg-rose-500/15 text-rose-200 border-rose-500/30';
  if (s === 'queued' || s === 'ready' || s === 'planning') return 'bg-zinc-500/15 text-zinc-300 border-zinc-500/30';
  return 'bg-white/5 text-zinc-400 border-white/10';
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
  collapsed = false,
}: CurrentTaskStripProps) {
  const [commenting, setCommenting] = useState(false);
  const [commentBody, setCommentBody] = useState('');
  const [collapsedLocal, setCollapsedLocal] = useState(collapsed);

  const taskId = String(task.taskId || task.task_id || '');
  const status = taskStatusOf(task);
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
            <span className={`rounded-full border px-2 py-0.5 ${statusTone(status)}`}>{status}</span>
            <span className="rounded-full border border-white/10 bg-white/5 px-2 py-0.5 capitalize">{role}</span>
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
