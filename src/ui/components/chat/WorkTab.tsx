import type { ChainLike, ChainProgressInfo, TaskLike } from './chainTaskInference';
import { chainIdOfTask, isUserEffectiveReviewer, taskStatusOf } from './chainTaskInference';

export type WorkTabProps = {
  chain: ChainLike | null;
  tasks: TaskLike[];
  progress: ChainProgressInfo;
  reviewNeededTasks: TaskLike[];
  agentInstanceId: string;
  debugPrefix: string;
  onOpenChain?: (chainId: string) => void;
  onOpenTask?: (taskId: string) => void;
  onCreateTask?: () => void;
};

function statusDot(status: string): string {
  const s = status.toLowerCase();
  if (s === 'in_progress') return 'bg-teal-400';
  if (s === 'review_ready') return 'bg-sky-400';
  if (s === 'completed' || s === 'approved' || s === 'done') return 'bg-emerald-400';
  if (s === 'blocked') return 'bg-rose-400';
  if (s === 'cancelled' || s === 'archived' || s === 'abandoned') return 'bg-zinc-600';
  return 'bg-zinc-500';
}

const ACTIVE_STATUSES = new Set(['in_progress', 'review_ready', 'queued', 'ready', 'planning', 'blocked']);
const DONE_STATUSES = new Set(['approved', 'completed', 'done']);

// UI-6: compact chain dashboard for the conversation inspector Work tab.
// Not the full chain editor — no dependency graph editing.
export default function WorkTab({ chain, tasks, progress, reviewNeededTasks, agentInstanceId, debugPrefix, onOpenChain, onOpenTask, onCreateTask }: WorkTabProps) {
  const chainId = String(chain?.chainId || chain?.chain_id || '');
  const chainTitle = String(chain?.title || chainId || 'session');
  const chainStatus = String(chain?.status || '');
  const chainKind = String(chain?.kind || '');
  const coordinator = String(chain?.coordinatorAgentInstanceId || chain?.coordinator_agent_instance_id || '');

  const active = tasks.filter((task) => ACTIVE_STATUSES.has(taskStatusOf(task)));
  const completed = tasks.filter((task) => DONE_STATUSES.has(taskStatusOf(task)));
  const isEmpty = tasks.length === 0;

  return (
    <div data-debug-id={`${debugPrefix}-work-tab`} className="space-y-3 text-[12.5px] text-zinc-300">
      <div data-debug-id={`${debugPrefix}-work-chain-header`} className="rounded-xl border border-white/10 bg-white/[0.03] p-3">
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="truncate font-medium text-zinc-100">{chainTitle}</div>
            <div className="mt-0.5 text-[11px] text-zinc-500">{chainKind ? `${chainKind} · ` : ''}{chainStatus || 'active'}</div>
          </div>
          {onOpenChain && chainId ? <button type="button" data-debug-id={`${debugPrefix}-work-open-chain`} onClick={() => onOpenChain(chainId)} className="shrink-0 rounded-full border border-white/10 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-white/10">Open full chain</button> : null}
        </div>
        <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-zinc-500">
          <span>Progress: <span className="text-zinc-300">{progress.completed}/{progress.total}</span></span>
          {coordinator ? <span>Coordinator: <code className="text-zinc-400">{coordinator}</code></span> : null}
        </div>
      </div>

      {reviewNeededTasks.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-work-review-group`} className="rounded-xl border border-sky-400/25 bg-sky-400/[0.05] p-3">
          <div className="mb-1.5 text-[11px] font-medium uppercase tracking-wide text-sky-300/80">Needs your review</div>
          <div className="space-y-1.5">
            {reviewNeededTasks.map((task) => (
              <TaskRow key={chainIdOfTask(task) || taskStatusOf(task)} task={task} debugPrefix={`${debugPrefix}-work-review`} onOpenTask={onOpenTask} tone="sky" />
            ))}
          </div>
        </div>
      ) : null}

      {isEmpty ? (
        <div data-debug-id={`${debugPrefix}-work-empty`} className="rounded-xl border border-dashed border-white/10 bg-[#111111]/70 p-4 text-center text-zinc-500">
          <div className="text-zinc-300">No concrete tasks yet.</div>
          <p className="mt-1 leading-5">Ask the agent to make a plan, or create a task.</p>
          {onCreateTask ? <button type="button" data-debug-id={`${debugPrefix}-work-create-task`} onClick={onCreateTask} className="mt-2 rounded-full border border-white/10 px-3 py-1 text-[11px] text-zinc-300 hover:bg-white/10">Create task</button> : null}
        </div>
      ) : (
        <>
          {active.length > 0 ? (
            <div data-debug-id={`${debugPrefix}-work-active-group`} className="space-y-1.5">
              <div className="text-[11px] font-medium uppercase tracking-wide text-zinc-500">Active / next</div>
              {active.map((task) => (
                <TaskRow key={chainIdOfTask(task) || taskStatusOf(task)} task={task} debugPrefix={`${debugPrefix}-work-active`} onOpenTask={onOpenTask} />
              ))}
            </div>
          ) : null}
          {completed.length > 0 ? (
            <div data-debug-id={`${debugPrefix}-work-completed-group`} className="space-y-1.5">
              <div className="text-[11px] font-medium uppercase tracking-wide text-zinc-500">Completed</div>
              {completed.slice(0, 6).map((task) => (
                <TaskRow key={chainIdOfTask(task) || taskStatusOf(task)} task={task} debugPrefix={`${debugPrefix}-work-done`} onOpenTask={onOpenTask} />
              ))}
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}

function TaskRow({ task, debugPrefix, onOpenTask, tone }: { task: TaskLike; debugPrefix: string; onOpenTask?: (taskId: string) => void; tone?: 'sky' }) {
  const taskId = String(task.taskId || task.task_id || '');
  const status = taskStatusOf(task);
  const title = String(task.title || taskId);
  const userReview = isUserEffectiveReviewer(task);
  return (
    <div className={`flex items-center justify-between gap-2 rounded-lg border px-2.5 py-1.5 ${tone === 'sky' ? 'border-sky-400/20 bg-sky-400/[0.04]' : 'border-white/10 bg-white/[0.02]'}`}>
      <div className="flex min-w-0 items-center gap-2">
        <span className={`h-2 w-2 shrink-0 rounded-full ${statusDot(status)}`} />
        <span className="truncate text-zinc-200">{title}</span>
        {userReview ? <span className="shrink-0 rounded-full border border-sky-400/30 bg-sky-400/10 px-1.5 py-0.5 text-[10px] text-sky-200">review</span> : null}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <span className="text-[10.5px] text-zinc-500">{status}</span>
        {onOpenTask ? <button type="button" data-debug-id={`${debugPrefix}-open-${taskId}`} onClick={() => onOpenTask(taskId)} className="text-[11px] text-zinc-400 hover:text-zinc-100">open</button> : null}
      </div>
    </div>
  );
}
