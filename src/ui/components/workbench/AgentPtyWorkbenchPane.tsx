import React, { Suspense, useCallback, useMemo } from 'react';
import { useAgentLifecycle, type LifecycleResult } from '../../hooks/useAgentLifecycle';
import {
  useFetchAgentInstanceQuery,
} from '../../api/endpoints/agents';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import { useAuxTabActions, type AuxTabAction } from '../auxiliary/auxTabActions';

// xterm stays out of the entry chunk until an agent PTY pane mounts.
const AgentPaneComposerPanel = React.lazy(() => import('../chat/AgentPaneComposerPanel'));

export interface AgentPtyWorkbenchPaneProps {
  agentInstanceId: string;
  isActiveTab?: boolean;
}

/**
 * Agent PTY aux tab: the live terminal ONLY. The agent comes from the tab
 * content, its status shows as a dot on the tab, and start / restart / stop
 * live in the aux ⋮ menu.
 */
export function AgentPtyWorkbenchPane({
  agentInstanceId,
  isActiveTab = true,
}: AgentPtyWorkbenchPaneProps) {
  const { currentData: instanceData } = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    // No steady poll: agent_instance resource events patch this cache (and a failure
    // refetches it for last_error), as in AgentChatPane; reconnect resync covers gaps.
    { skip: !agentInstanceId },
  );
  const { data: liveData } = useGetAgentsLiveQuery();

  const instance = instanceData?.instance;
  const [result, setResult] = React.useState<LifecycleResult | null>(null);
  const { start, stop, restart, isPending } = useAgentLifecycle({ inline: setResult });
  const actionBusy = isPending();
  const actionError = result?.status === 'failed' ? result.message : null;

  const liveAgent = useMemo(() => {
    const allLive = (liveData || []).flatMap((p) =>
      (p.chains || []).flatMap((c) => c.liveAgents || []),
    );
    return allLive.find((a) => a.agentInstanceId === agentInstanceId);
  }, [liveData, agentInstanceId]);

  const rawStatus = String(
    liveAgent?.runtimeStatus || instance?.runtime_status || instance?.runtimeStatus || 'running',
  ).toLowerCase();
  const agentId = String(instance?.agent_id || instance?.agentId || '');
  const isStopped = rawStatus === 'stopped' || rawStatus === 'failed';
  const isStarting = isPending('start') || rawStatus === 'starting';

  const run = useCallback(
    async (kind: 'start' | 'stop' | 'restart') => {
      if (!agentInstanceId || actionBusy) return;
      await ({ start, stop, restart })[kind]({ instanceId: agentInstanceId, agentId });
    },
    [actionBusy, agentId, agentInstanceId, restart, start, stop],
  );

  const actions: AuxTabAction[] = isStopped
    ? [{ id: 'pty-start', label: 'Start agent', icon: 'play', disabled: Boolean(actionBusy), onSelect: () => void run('start') }]
    : [
        { id: 'pty-restart', label: 'Restart agent', icon: 'refresh', disabled: Boolean(actionBusy), onSelect: () => void run('restart') },
        { id: 'pty-stop', label: 'Stop agent', icon: 'stop', tone: 'danger', disabled: Boolean(actionBusy), onSelect: () => void run('stop') },
      ];
  useAuxTabActions(actions);

  return (
    <div
      data-debug-id={`workbench-agent-pty-pane-${agentInstanceId}`}
      className="relative flex h-full min-h-0 w-full flex-1 flex-col overflow-hidden bg-surface text-primary"
    >
      {actionError && (
        <p role="alert" data-debug-id={`workbench-agent-pty-error-${agentInstanceId}`} className="shrink-0 px-3 py-1 text-xs text-danger">
          {actionError}
        </p>
      )}
      <Suspense fallback={null}>
        <AgentPaneComposerPanel
          agentInstanceId={agentInstanceId}
          runtimeTransport={instance?.runtime_transport}
          isExpanded={true}
          isActiveTab={isActiveTab}
          runtimeStatus={rawStatus}
          isStarting={isStarting}
          runCount={instance?.run_count}
          startedAt={instance?.started_at}
          fillPane={true}
          hideHeader={true}
          className="h-full w-full flex-1 min-h-0"
        />
      </Suspense>
    </div>
  );
}

export default AgentPtyWorkbenchPane;
