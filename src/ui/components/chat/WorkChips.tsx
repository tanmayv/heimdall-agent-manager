import type { ChainLike, ChainProgressInfo, TaskLike } from './chainTaskInference';

export type WorkChipsProps = {
  chain: ChainLike | null;
  progress: ChainProgressInfo;
  reviewNeededTasks: TaskLike[];
  debugPrefix: string;
  onOpenChain?: (chainId: string) => void;
  onOpenReviewTask?: (taskId: string) => void;
};

// UI-6 header affordance: a compact Work chip (chain info) + a scoped Review-needed chip.
// The review chip is scoped to THIS conversation's chain only.
export default function WorkChips({ chain, progress, reviewNeededTasks, debugPrefix, onOpenChain, onOpenReviewTask }: WorkChipsProps) {
  const chainId = String(chain?.chainId || chain?.chain_id || '');
  const chainTitle = String(chain?.title || chainId || 'session');
  const reviewCount = reviewNeededTasks.length;
  const privateChain = String(chain?.kind || '').includes('private');

  return (
    <div data-debug-id={`${debugPrefix}-work-chips`} className="flex flex-wrap items-center gap-2">
      <button
        type="button"
        data-debug-id={`${debugPrefix}-work-chip`}
        data-chain-id={chainId}
        onClick={() => chainId && onOpenChain?.(chainId)}
        className="inline-flex items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] px-2.5 py-1 text-[11.5px] text-zinc-300 hover:border-white/20 hover:bg-white/[0.08] disabled:cursor-not-allowed disabled:opacity-50"
        disabled={!chainId || !onOpenChain}
      >
        <span className="text-teal-300/80">Work:</span>
        <span className="max-w-[220px] truncate text-zinc-200">{chainTitle}</span>
        <span className="text-zinc-500">· {progress.completed}/{progress.total}</span>
      </button>
      {reviewCount > 0 ? (
        <button
          type="button"
          data-debug-id={`${debugPrefix}-review-needed-chip`}
          data-review-needed-count={reviewCount}
          onClick={() => { const oldest = reviewNeededTasks[0]; if (oldest && onOpenReviewTask) onOpenReviewTask(String(oldest.taskId || oldest.task_id || '')); }}
          className="inline-flex items-center gap-1.5 rounded-full border border-sky-400/30 bg-sky-400/10 px-2.5 py-1 text-[11.5px] text-sky-100 hover:bg-sky-400/20"
          title={`Oldest task needing review: ${String(reviewNeededTasks[0]?.title || reviewNeededTasks[0]?.taskId || '')}`}
        >
          <span>Review needed: {reviewCount}</span>
        </button>
      ) : null}
      {privateChain && progress.total === 0 ? (
        <span data-debug-id={`${debugPrefix}-private-chain-chip`} className="inline-flex items-center gap-1 rounded-full border border-white/10 bg-white/[0.03] px-2.5 py-1 text-[11px] text-zinc-500">private chain · 0 tasks</span>
      ) : null}
    </div>
  );
}
