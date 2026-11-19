import { useSyncExternalStore } from 'react';
import { useGetAttentionQuery, type AttentionBlockerItem } from '../../api/endpoints/attention';
import { attentionScheduler, type ActionScheduler } from '../../services/attention/actionScheduler';
import { AgentBlockerActions, AgentBlockerBody } from '../attention/AgentBlockerCard';
import { hideKey } from '../attention/attentionModel';

/** The ACP pane uses the same permission items, decisions and optimistic state as Needs you. */
export function AcpPermissionBlockers({ agentInstanceId, visible, runtimeStatus, scheduler = attentionScheduler }: {
  agentInstanceId: string; visible: boolean; runtimeStatus: string; scheduler?: ActionScheduler;
}) {
  const live = ['running', 'starting', 'blocked'].includes(runtimeStatus);
  const query = useGetAttentionQuery({ since: 'all', kind: 'agent_blocker' }, { skip: !agentInstanceId || !visible || !live });
  const state = useSyncExternalStore(scheduler.subscribe, scheduler.getSnapshot, scheduler.getSnapshot);
  const blockers = (query.currentData?.items || []).filter((item): item is AttentionBlockerItem =>
    item.kind === 'agent_blocker' && item.action_refs.agent_instance_id === agentInstanceId &&
    item.details.blocker_kind === 'permission' && !state.hidden.has(hideKey(item)));
  if (!visible || !live || !blockers.length) return null;
  return <div className="space-y-3" aria-label="Permission requests">
    {blockers.map((item) => <section key={item.card_id} data-debug-id={`agent-acp-permission-${item.action_refs.blocker_id}`}
      className="space-y-3 rounded-lg border border-subtle bg-surface-raised p-3">
      <AgentBlockerBody item={item} />
      <AgentBlockerActions item={item} compact scheduler={scheduler} />
    </section>)}
  </div>;
}
