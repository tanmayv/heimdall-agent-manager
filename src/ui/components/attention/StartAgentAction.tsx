import { useRef, useState } from 'react';
import type { AttentionItem, AttentionTaskItem } from '../../api/endpoints/attention';
import { acceptCard } from '../../services/attention/attentionActions';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useGetTaskChainFleetsQuery } from '../../api/endpoints/taskChains';
import { useFetchChainTaskDetailQuery } from '../../api/endpoints/tasks';
import { VaultText } from '../vault';

function startFailureText(message: string) {
  return message.includes('instance_not_drained') ? 'The previous agent process is still shutting down. Retry when it finishes.' : message;
}

export function needsAgentStart(item: AttentionItem): boolean {
  return item.kind === 'task' && item.operations.some((op) => op.op === 'agent.start');
}

/** Immediate action: leave a failed card visible so the user can retry it. */
export function useStartAgent(invalidate: () => void) {
  const pending = useRef(new Set<string>());
  const [states, setStates] = useState<Record<string, { busy: boolean; error: string }>>({});
  const start = async (item: AttentionItem, replacementAgentId?: string) => {
    if (item.kind !== "task") return;
    if (pending.current.has(item.card_id)) return;
    pending.current.add(item.card_id);
    setStates((s) => ({ ...s, [item.card_id]: { busy: true, error: '' } }));
    try {
      await acceptCard(item.card_id, false, { expected_block: item.details.block_id, ...(replacementAgentId ? { replacement_agent_id: replacementAgentId } : {}) });
      setStates((s) => ({ ...s, [item.card_id]: { busy: false, error: '' } }));
    } catch (err) {
      setStates((s) => ({ ...s, [item.card_id]: { busy: false, error: startFailureText(err instanceof Error ? err.message : 'Agent failed to start') } }));
    } finally {
      pending.current.delete(item.card_id);
      invalidate();
    }
  };
  return { start, states };
}

export function StartAgentAction({ onStart, onDelegate, item, busy = false, error = '', debugPrefix, cardId = '' }: {
  onStart: () => void; onDelegate?: (agentId: string) => void; item?: AttentionTaskItem; busy?: boolean; error?: string; debugPrefix: string; cardId?: string;
}) {
  const suffix = cardId ? '-' + cardId : '';
  return (
    <div className="min-w-0 space-y-1">
      <button type="button" data-debug-id={debugPrefix + "-start-agent" + suffix} disabled={busy} onClick={onStart}
        className="inline-flex min-h-10 items-center justify-center rounded-full bg-accent px-3.5 text-[14px] font-medium text-accent-fg disabled:opacity-50">
        {busy ? 'Starting…' : 'Start agent'}
      </button>
      {item?.details.start_agent?.can_delegate && onDelegate ? <DelegateWorker key={item.card_id} item={item} onDelegate={onDelegate} busy={busy} debugPrefix={debugPrefix} /> : null}
      {error ? <p role="alert" data-debug-id={debugPrefix + "-start-agent-error" + suffix} className="max-w-sm whitespace-normal text-[13px] text-danger">{error}</p> : null}
    </div>
  );
}

/** The same named failure body is used by the deck and the chat action tray. */
export function StartAgentFailure({ item }: { item: AttentionTaskItem }) {
  const context = item.details.start_agent;
  return <div className="space-y-2 text-[13px]">
    <p role="alert" className="text-danger">{context ? <><VaultText value={context.agent_name} /> on <VaultText value={context.bridge_name} /> is not running.</> : 'The assigned agent is not running.'}</p>
    {context?.detail ? <p className="text-muted">{startFailureText(context.detail)}</p> : null}
    {context ? <details data-debug-id={`attention-start-diagnostics-${item.card_id}`}><summary>Technical details</summary><p className="break-all">{context.agent_id} · {context.bridge_id}</p><p className="break-all">{context.diagnostic}</p></details> : null}
  </div>;
}

export function delegationCandidates(agents: readonly any[], fleets: readonly any[], excluded: readonly string[]) {
  return agents.filter((a) => {
    const id = String(a.agent_id || a.id || '');
    const fleet = fleets.find((f) => f.agent_id === id);
    return id.startsWith('agt_') && !excluded.includes(id) && (a.state || 'active') === 'active' && fleet &&
      (fleet.roles || ['worker', 'reviewer']).includes('worker') && !(fleet.paused_roles || []).some((r: string) => r === '*' || r === 'worker');
  });
}

function DelegateWorker({ item, onDelegate, busy, debugPrefix }: { item: AttentionTaskItem; onDelegate: (id: string) => void; busy: boolean; debugPrefix: string }) {
  const [selected, setSelected] = useState('');
  const identities = useListAgentIdentitiesQuery();
  const fleets = useGetTaskChainFleetsQuery({ chainId: item.action_refs.chain_id });
  const detail = useFetchChainTaskDetailQuery({ chainId: item.action_refs.chain_id, taskId: item.action_refs.task_id });
  const task = detail.data?.task;
  const reviewers: string[] = task?.brief?.reviewers || [];
  const roles: string[] = task?.brief?.review_roles || [];
  const candidates = delegationCandidates(identities.data?.agents || [], fleets.data || [], [item.details.start_agent?.agent_id || '', task?.brief?.assignee || '', ...reviewers])
    .filter((a) => !roles.some((r) => (fleets.data || []).find((f) => f.agent_id === (a.agent_id || a.id))?.roles?.includes(r)));
  const loading = identities.isFetching || fleets.isFetching || detail.isFetching;
  const failed = identities.isError || fleets.isError || detail.isError;
  const valid = !!task && !task.workflow_run_id && !task.stage_key && !(task.leases || []).length && candidates.some((a) => (a.agent_id || a.id) === selected);
  const id = `${debugPrefix}-delegate-worker-${item.card_id}`;
  return <div className="space-y-2 pt-2">
    <label htmlFor={id} className="block text-[13px] text-muted">Delegate to another durable worker</label>
    <select id={id} data-debug-id={id} value={selected} disabled={busy || loading || failed} onChange={(e) => setSelected(e.target.value)} className="w-full rounded border border-subtle bg-surface p-2 text-primary">
      <option value="">Choose a worker</option>
      {selected && !candidates.some((a) => (a.agent_id || a.id) === selected) ? <option value={selected} disabled>Selection unavailable</option> : null}
      {candidates.map((a) => <option key={a.agent_id || a.id} value={a.agent_id || a.id}>{a.name || a.display_name || a.slug || 'Unnamed agent'}</option>)}
    </select>
    <p className="text-[12px] text-muted">Delegating starts the selected worker if stopped, including a worker you stopped. This changes only this ticket’s assignee. Existing reviews stay required.</p>
    {failed ? <p role="alert">Could not load workers. Reopen this card to retry.</p> : null}
    {!loading && !failed && !candidates.length ? <p className="text-[12px] text-muted">No eligible replacement worker is configured in this chain’s fleet.</p> : null}
    <button type="button" data-debug-id={`${id}-apply`} disabled={busy || loading || failed || !valid || !item.details.block_id} onClick={() => onDelegate(selected)} className="min-h-10 rounded-full bg-accent px-3.5 text-[14px] text-accent-fg disabled:opacity-50">{busy ? 'Delegating…' : 'Delegate and start'}</button>
  </div>;
}
