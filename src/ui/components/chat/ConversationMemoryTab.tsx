import { useMemo } from 'react';
import { useDecideMemoryProposalMutation, useListApplicableMemoryQuery } from '../../api/endpoints/memory';

export type ConversationMemoryTabProps = {
  agentId: string;
  durableAgentId: string;
  projectId: string;
  session: any;
  debugPrefix: string;
  // Optional: preloaded records + fetch state from the owning page (avoids a
  // duplicate query when the badge count is also needed in the inspector header).
  records?: any[];
  fetching?: boolean;
  error?: boolean;
};

// UI-7: Memory tab for the conversation right inspector.
// Identity-scoped (shared across the agent's conversations). Surfaces pending
// memory proposals with inline approve/reject so the user never leaves the chat.
// Updates through the same RTK Query + WS invalidation path as the page.
export default function ConversationMemoryTab({ agentId, durableAgentId, projectId, session, debugPrefix, records: preloadedRecords, fetching: preloadedFetching, error: preloadedError }: ConversationMemoryTabProps) {
  const memoryQuery = useListApplicableMemoryQuery(
    { targetAgentId: durableAgentId, targetProjectId: projectId || '' },
    { skip: !durableAgentId || !session?.clientToken || Array.isArray(preloadedRecords) },
  );
  const [decideProposal] = useDecideMemoryProposalMutation();
  const records = Array.isArray(preloadedRecords) ? preloadedRecords : (memoryQuery.data?.records || []);
  const isFetching = preloadedFetching ?? memoryQuery.isFetching;
  const isError = preloadedError ?? memoryQuery.isError;

  const pending = useMemo(() => records.filter((record: any) => String(record.status || '').toLowerCase() === 'pending'), [records]);
  const active = useMemo(() => records.filter((record: any) => String(record.status || '').toLowerCase() !== 'pending'), [records]);

  async function decide(memoryId: string, proposalId: string | undefined, decision: 'approve' | 'reject') {
    if (!proposalId) return;
    try {
      await decideProposal({ proposalId, decision }).unwrap();
    } catch {
      // RTK Query surfaces the error in the cache; the row stays pending.
    }
  }

  return (
    <div data-debug-id={`${debugPrefix}-memory-tab`} className="space-y-3 text-[12.5px] text-zinc-300">
      <div data-debug-id={`${debugPrefix}-memory-header`} className="rounded-xl border border-white/10 bg-white/[0.03] p-3">
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="truncate text-sm font-medium text-zinc-100">Agent memory</div>
            <div className="mt-0.5 truncate text-[11px] text-zinc-500">Shared across all conversations with <code className="text-zinc-400">{durableAgentId || agentId}</code></div>
          </div>
          <span data-debug-id={`${debugPrefix}-memory-count`} className="shrink-0 rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-400">{records.length}</span>
        </div>
      </div>

      {pending.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-memory-pending-group`} className="space-y-2">
          <div className="text-[11px] font-medium uppercase tracking-wide text-fuchsia-300/80">Pending proposals · {pending.length}</div>
          {pending.map((record: any) => (
            <MemoryRow key={`p-${record.memoryId}`} record={record} debugPrefix={`${debugPrefix}-memory-pending`} pending onApprove={(proposalId) => void decide(record.memoryId, proposalId, 'approve')} onReject={(proposalId) => void decide(record.memoryId, proposalId, 'reject')} />
          ))}
        </div>
      ) : null}

      {active.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-memory-active-group`} className="space-y-2">
          <div className="text-[11px] font-medium uppercase tracking-wide text-zinc-500">Active memory</div>
          {active.slice(0, 20).map((record: any) => (
            <MemoryRow key={`a-${record.memoryId}`} record={record} debugPrefix={`${debugPrefix}-memory-active`} />
          ))}
        </div>
      ) : null}

      {records.length === 0 && !isFetching ? (
        <div data-debug-id={`${debugPrefix}-memory-empty`} className="rounded-xl border border-dashed border-white/10 bg-[#111111]/70 p-4 text-center text-sm text-zinc-500">
          <div className="text-zinc-300">No memory yet.</div>
          <p className="mt-1 leading-5">Memories approved here are shared across every conversation with this agent.</p>
        </div>
      ) : null}
      {isFetching && records.length === 0 ? <div className="rounded-xl border border-white/10 bg-black/20 p-4 text-sm text-zinc-500">Loading memory…</div> : null}
      {isError ? <div data-debug-id={`${debugPrefix}-memory-error`} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">Unable to load memory.</div> : null}
    </div>
  );
}

function MemoryRow({ record, debugPrefix, pending = false, onApprove, onReject }: { record: any; debugPrefix: string; pending?: boolean; onApprove?: (proposalId: string) => void; onReject?: (proposalId: string) => void }) {
  const memoryId = String(record.memoryId || record.id || '');
  const title = String(record.title || memoryId);
  const status = String(record.status || 'pending');
  const proposalId = record.proposalId ? String(record.proposalId) : undefined;
  return (
    <div data-debug-id={`${debugPrefix}-item-${memoryId}`} className={`rounded-xl border px-3 py-2 ${pending ? 'border-fuchsia-400/25 bg-fuchsia-400/[0.05]' : 'border-white/10 bg-white/[0.02]'}`}>
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate text-sm text-zinc-100">{title}</div>
          <div className="mt-0.5 truncate text-[11px] text-zinc-500">{record.type || 'fact'} · {status}{record.target || record.target_agent_id ? ` · ${record.target || record.target_agent_id}` : ''}</div>
        </div>
        {pending && proposalId ? (
          <div className="flex shrink-0 items-center gap-1">
            <button type="button" data-debug-id={`${debugPrefix}-approve-${memoryId}`} onClick={() => onApprove?.(proposalId)} className="rounded-full border border-emerald-400/30 bg-emerald-400/10 px-2 py-0.5 text-[11px] text-emerald-100 hover:bg-emerald-400/20">Approve</button>
            <button type="button" data-debug-id={`${debugPrefix}-reject-${memoryId}`} onClick={() => onReject?.(proposalId)} className="rounded-full border border-rose-400/30 bg-rose-400/10 px-2 py-0.5 text-[11px] text-rose-100 hover:bg-rose-400/20">Reject</button>
          </div>
        ) : null}
      </div>
      {record.body ? <div className="mt-1.5 line-clamp-3 whitespace-pre-wrap text-[11.5px] text-zinc-400">{record.body}</div> : null}
    </div>
  );
}
