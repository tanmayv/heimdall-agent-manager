import { useRef, useState } from 'react';
import type { AttentionItem, AttentionTaskItem } from '../../api/endpoints/attention';
import { acceptCard } from '../../services/attention/attentionActions';
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
  const start = async (item: AttentionItem) => {
    if (item.kind !== "task") return;
    if (pending.current.has(item.card_id)) return;
    pending.current.add(item.card_id);
    setStates((s) => ({ ...s, [item.card_id]: { busy: true, error: '' } }));
    try {
      await acceptCard(item.card_id, false, { expected_block: item.details.block_id });
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

export function StartAgentAction({ onStart, busy = false, error = '', debugPrefix, cardId = '' }: {
  onStart: () => void; busy?: boolean; error?: string; debugPrefix: string; cardId?: string;
}) {
  const suffix = cardId ? '-' + cardId : '';
  return (
    <div className="min-w-0 space-y-1">
      <button type="button" data-debug-id={debugPrefix + "-start-agent" + suffix} disabled={busy} onClick={onStart}
        className="inline-flex min-h-10 items-center justify-center rounded-full bg-accent px-3.5 text-[14px] font-medium text-accent-fg disabled:opacity-50">
        {busy ? 'Starting…' : 'Start agent'}
      </button>
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
