import { useState, useMemo, useEffect } from 'react';

import { Button, Checkbox, Icon, Modal, Select } from '@ui';
import {
  useListTaskChainsQuery,
  useFetchTaskChainDetailQuery,
  ChainListItem,
} from '../../api/endpoints/tasks';
import {
  useListAgentIdentitiesQuery,
  useListAgentInstancesQuery,
  useStartAgentInstanceMutation,
  useLaunchAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';

export type ProjectLaunchModalProps = {
  isOpen: boolean;
  project: { projectId: string; name: string } | null;
  onClose: () => void;
  /**
   * Called after a successful launch/start with the instance id to navigate to.
   * When provided, the caller is responsible for closing the modal (e.g. by
   * clearing the project that controls `isOpen`); when omitted, onClose() is
   * still invoked so behavior is backward compatible.
   */
  onLaunched?: (instanceId: string) => void;
};

type TabKey = 'chain' | 'new' | 'existing';

const ACTIVE_STATUSES = new Set([
  'running',
  'idle',
  'busy',
  'launching',
  'starting',
  'stopping',
  'blocked',
  'connected',
  'ready',
  'live',
  'active',
]);

function isInstanceActive(status: string): boolean {
  return ACTIVE_STATUSES.has(String(status || '').trim().toLowerCase());
}

export default function ProjectLaunchModal({
  isOpen,
  project,
  onClose,
  onLaunched,
}: ProjectLaunchModalProps) {
  const [activeTab, setActiveTab] = useState<TabKey>('chain');

  // Tab 1 state
  const [chainCursor, setChainCursor] = useState<string>('');
  const [chainCursorHistory, setChainCursorHistory] = useState<string[]>([]);
  const [selectedChainId, setSelectedChainId] = useState<string>('');
  const [selectedChainAgentIds, setSelectedChainAgentIds] = useState<Set<string>>(new Set());

  // Tab 2 state
  const [agentsPage, setAgentsPage] = useState<number>(0);
  const [selectedNewAgentIds, setSelectedNewAgentIds] = useState<Set<string>>(new Set());
  const [selectedBridgeId, setSelectedBridgeId] = useState<string>('');

  // Tab 3 state
  const [existingPage, setExistingPage] = useState<number>(0);
  const [selectedExistingInstanceIds, setSelectedExistingInstanceIds] = useState<Set<string>>(new Set());

  // Action status & feedback
  const [isActionRunning, setIsActionRunning] = useState<boolean>(false);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null);

  // Mutations
  const [startAgentInstance] = useStartAgentInstanceMutation();
  const [launchAgentInstance] = useLaunchAgentInstanceMutation();

  // Queries
  const projectId = project?.projectId || '';

  // Tab 1: Task chains for project
  const chainsQuery = useListTaskChainsQuery(
    { projectId, limit: 10, cursor: chainCursor },
    { skip: !isOpen || !projectId || activeTab !== 'chain' }
  );
  const chains: ChainListItem[] = chainsQuery.data?.chains || [];
  const chainHasMore = Boolean(chainsQuery.data?.hasMore);
  const chainNextCursor = chainsQuery.data?.nextCursor || '';

  // Selected chain detail
  const chainDetailQuery = useFetchTaskChainDetailQuery(
    { chainId: selectedChainId },
    { skip: !isOpen || !selectedChainId || activeTab !== 'chain' }
  );
  const chainDetail = chainDetailQuery.data?.chain || null;
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const chainMembers: any[] = chainDetail?.members || [];
  const coordinatorAgentInstanceId = chainDetail?.coordinatorAgentInstanceId || '';

  // Tab 2: Durable agents catalog via useListAgentIdentitiesQuery (cookie-auth /api/v1/agents)
  const AGENTS_PAGE_SIZE = 10;
  const identitiesQuery = useListAgentIdentitiesQuery(
    { limit: 200 },
    { skip: !isOpen || activeTab !== 'new' }
  );
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const rawIdentities: any[] = identitiesQuery.data?.agents || [];
  const durableAgents = useMemo(() => {
    const list: Array<{ agentId: string; name: string; tier: string; provider: string; state: string }> = [];
    for (const item of rawIdentities) {
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const agentId = String(item.agent_id || item.agentId || item.id || '').trim();
      const state = String(item.state || '').trim().toLowerCase();
      // Filter out archived agents
      if (!agentId || state === 'archived') continue;
      list.push({
        agentId,
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        name: String(item.name || item.slug || agentId),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        tier: String(item.default_tier || item.defaultTier || ''),
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        provider: String(item.default_provider || item.defaultProvider || ''),
        state: item.state || 'active',
      });
    }
    return list;
  }, [rawIdentities]);
  const totalAgentPages = Math.max(1, Math.ceil(durableAgents.length / AGENTS_PAGE_SIZE));
  const paginatedDurableAgents = durableAgents.slice(
    agentsPage * AGENTS_PAGE_SIZE,
    (agentsPage + 1) * AGENTS_PAGE_SIZE
  );

  // Tab 2: Available bridges query and normalization
  const bridgesQuery = useListBridgesQuery(undefined, {
    skip: !isOpen,
  });
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const rawBridges: any[] = bridgesQuery.data?.bridges || [];
  const availableBridges = useMemo(() => {
    const list: Array<{ bridgeId: string; label: string; status: string; isOnline: boolean }> = [];
    for (const raw of rawBridges) {
      const b = raw?.bridge || raw;
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const bridgeId = String(b?.bridge_id || b?.bridgeId || b?.id || '').trim();
      if (!bridgeId) continue;
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const status = String(b?.status || b?.runtime_status || 'offline').toLowerCase();
      if (status === 'revoked') continue;
      const isOnline = status === 'online' || status === 'connected';
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const label = String(b?.label || b?.machine_hostname || b?.hostname || bridgeId);
      list.push({ bridgeId, label, status, isOnline });
    }
    // Prefer online bridges first, then alphabetical by label
    return list.sort((a, b) => {
      if (a.isOnline && !b.isOnline) return -1;
      if (!a.isOnline && b.isOnline) return 1;
      return a.label.localeCompare(b.label);
    });
  }, [rawBridges]);

  // Tab 3: Existing agent instances for project (filtered to stopped / inactive only)
  const EXISTING_PAGE_SIZE = 10;
  const instancesQuery = useListAgentInstancesQuery(
    { projectId, limit: 100 },
    { skip: !isOpen || !projectId || activeTab !== 'existing' }
  );
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const rawInstances: any[] = instancesQuery.data?.instances || [];
  const stoppedInstances = useMemo(() => {
    return rawInstances.filter((inst) => {
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const instanceId = String(
        inst.agent_instance_id ||
        inst.agentInstanceId ||
        inst.instance_id ||
        inst.instanceId ||
        inst.id ||
        ''
      ).trim();
      if (!instanceId) return false;
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const status = String(inst.runtime_status || inst.runtimeStatus || inst.status || '').toLowerCase();
      return !isInstanceActive(status);
    });
  }, [rawInstances]);
  const hasOnlyActiveInstances = rawInstances.length > 0 && stoppedInstances.length === 0;
  const totalExistingPages = Math.max(1, Math.ceil(stoppedInstances.length / EXISTING_PAGE_SIZE));
  const currentInstances = stoppedInstances.slice(
    existingPage * EXISTING_PAGE_SIZE,
    (existingPage + 1) * EXISTING_PAGE_SIZE
  );

  // Reset state when modal opens or active project changes
  useEffect(() => {
    if (isOpen) {
      setChainCursor('');
      setChainCursorHistory([]);
      setSelectedChainId('');
      setSelectedChainAgentIds(new Set());
      setAgentsPage(0);
      setSelectedNewAgentIds(new Set());
      setSelectedBridgeId('');
      setExistingPage(0);
      setSelectedExistingInstanceIds(new Set());
      setFeedback(null);
    }
  }, [isOpen, projectId]);

  // Auto-select first bridge by default (preferring online status)
  useEffect(() => {
    if (availableBridges.length > 0) {
      if (!selectedBridgeId || !availableBridges.some((b) => b.bridgeId === selectedBridgeId)) {
        setSelectedBridgeId(availableBridges[0].bridgeId);
      }
    } else if (!bridgesQuery.isLoading) {
      setSelectedBridgeId('');
    }
  }, [availableBridges, selectedBridgeId, bridgesQuery.isLoading]);

  // When chains load, auto-select first chain if none selected
  useEffect(() => {
    if (activeTab === 'chain' && !selectedChainId && chains.length > 0) {
      setSelectedChainId(chains[0].chainId);
    }
  }, [activeTab, selectedChainId, chains]);

  // When chainDetail loads, coordinator agent is checked by default ONLY if not already active
  useEffect(() => {
    if (chainDetail) {
      const coordId = chainDetail.coordinatorAgentInstanceId;
      if (coordId) {
        const coordMember = (chainDetail.members || []).find(
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          (m: any) =>
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            m.agentInstanceId === coordId ||
            m.agent_instance_id === coordId ||
            m.role === 'coordinator'
        );
        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
        const coordStatus = coordMember?.runtimeStatus || coordMember?.runtime_status || '';
        if (!isInstanceActive(coordStatus)) {
          setSelectedChainAgentIds(new Set([coordId]));
        } else {
          setSelectedChainAgentIds(new Set());
        }
      } else {
        setSelectedChainAgentIds(new Set());
      }
    }
  }, [chainDetail?.chainId, chainDetail?.coordinatorAgentInstanceId, chainDetail?.members]);

  if (!isOpen || !project) return null;

  // Tab 1 handlers
  const toggleChainAgent = (instanceId: string, isActive?: boolean) => {
    if (!instanceId || isActive) return;
    setSelectedChainAgentIds((prev) => {
      const next = new Set(prev);
      if (next.has(instanceId)) next.delete(instanceId);
      else next.add(instanceId);
      return next;
    });
  };

  const handleStartChainAgents = async () => {
    const ids = Array.from(selectedChainAgentIds).filter(Boolean);
    if (ids.length === 0) return;
    setIsActionRunning(true);
    setFeedback(null);
    try {
      let startedCount = 0;
      let alreadyRunningCount = 0;
      for (const instanceId of ids) {
        try {
          await startAgentInstance({ instanceId }).unwrap();
          startedCount++;
        } catch (err: any) {
          const errStr = String(
            err?.data?.error?.message ||
            err?.data?.error ||
            err?.error ||
            err?.message ||
            ''
          ).toLowerCase();
          const isAlreadyRunning =
            err?.status === 409 ||
            err?.data?.status === 409 ||
            errStr.includes('already_running') ||
            errStr.includes('already running');
          if (isAlreadyRunning) {
            alreadyRunningCount++;
          } else {
            throw err;
          }
        }
      }
      setFeedback({
        type: 'success',
        message: `Successfully started ${startedCount} chain agent instance(s)${
          alreadyRunningCount > 0 ? ` (${alreadyRunningCount} already running)` : ''
        }.`,
      });
      // Navigate to the first started instance when a handler is provided;
      // otherwise fall back to just closing the modal (backward compatible).
      if (onLaunched) {
        onLaunched(ids[0]);
      } else {
        onClose();
      }
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: String(err?.data?.error?.message || err?.error || err?.message || 'Failed to start agents'),
      });
    } finally {
      setIsActionRunning(false);
    }
  };

  // Tab 2 handlers
  const toggleNewAgent = (agentId: string) => {
    setSelectedNewAgentIds((prev) => {
      const next = new Set(prev);
      if (next.has(agentId)) next.delete(agentId);
      else next.add(agentId);
      return next;
    });
  };

  const handleLaunchNewAgents = async () => {
    if (selectedNewAgentIds.size === 0 || !projectId || !selectedBridgeId) return;
    setIsActionRunning(true);
    setFeedback(null);
    try {
      const ids = Array.from(selectedNewAgentIds);
      let firstLaunchedId = '';
      for (const agentId of ids) {
        // The POST /agent-instances response carries the new instance id at the
        // top level; capture the first one so we can navigate to it afterwards.
        const result: any = await launchAgentInstance({ agentId, projectId, bridgeId: selectedBridgeId }).unwrap();
        const newId = String(result?.agent_instance_id || result?.agentInstanceId || '').trim();
        if (newId && !firstLaunchedId) firstLaunchedId = newId;
      }
      setFeedback({
        type: 'success',
        message: `Successfully launched ${ids.length} new agent instance(s) for ${project.name}.`,
      });
      setSelectedNewAgentIds(new Set());
      // Navigate to the first launched instance when a handler is provided and
      // we recovered an id; otherwise fall back to closing (backward compatible).
      if (firstLaunchedId && onLaunched) {
        onLaunched(firstLaunchedId);
      } else {
        onClose();
      }
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: String(err?.data?.error?.message || err?.error || err?.message || 'Failed to launch agent instances'),
      });
    } finally {
      setIsActionRunning(false);
    }
  };

  // Tab 3 handlers
  const toggleExistingInstance = (instanceId: string) => {
    if (!instanceId) return;
    setSelectedExistingInstanceIds((prev) => {
      const next = new Set(prev);
      if (next.has(instanceId)) next.delete(instanceId);
      else next.add(instanceId);
      return next;
    });
  };

  const handleStartExistingInstances = async () => {
    const ids = Array.from(selectedExistingInstanceIds).filter(Boolean);
    if (ids.length === 0) return;
    setIsActionRunning(true);
    setFeedback(null);
    try {
      let startedCount = 0;
      let alreadyRunningCount = 0;
      for (const instanceId of ids) {
        try {
          await startAgentInstance({ instanceId }).unwrap();
          startedCount++;
        } catch (err: any) {
          const errStr = String(
            err?.data?.error?.message ||
            err?.data?.error ||
            err?.error ||
            err?.message ||
            ''
          ).toLowerCase();
          const isAlreadyRunning =
            err?.status === 409 ||
            err?.data?.status === 409 ||
            errStr.includes('already_running') ||
            errStr.includes('already running');
          if (isAlreadyRunning) {
            alreadyRunningCount++;
          } else {
            throw err;
          }
        }
      }
      setFeedback({
        type: 'success',
        message: `Successfully started ${startedCount} existing instance(s)${
          alreadyRunningCount > 0 ? ` (${alreadyRunningCount} already running)` : ''
        }.`,
      });
      setSelectedExistingInstanceIds(new Set());
      // Navigate to the first started instance when a handler is provided;
      // otherwise fall back to just closing the modal (backward compatible).
      if (onLaunched) {
        onLaunched(ids[0]);
      } else {
        onClose();
      }
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: String(err?.data?.error?.message || err?.error || err?.message || 'Failed to start instances'),
      });
    } finally {
      setIsActionRunning(false);
    }
  };

  return (
    <Modal
      open={isOpen}
      onOpenChange={(next) => { if (!next) onClose(); }}
      size="lg"
      className="h-[640px] text-primary"
      data-debug-id="project-launch-modal"
      title={<>Launch Agent — <span className="text-accent">{project.name}</span></>}
    >
      <div className="flex h-full flex-col px-6 pb-2">
        <p className="shrink-0 -mt-1 mb-3 text-xs text-muted">
          Start or launch agents scoped to this project
        </p>

        {/* Tab Navigation */}
        <div className="shrink-0 flex items-center gap-2 border-b border-subtle pb-2.5 mb-3">
          <button
            type="button"
            data-debug-id="project-launch-tab-chain"
            onClick={() => {
              setActiveTab('chain');
              setFeedback(null);
            }}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
              activeTab === 'chain'
                ? 'bg-neutral-soft text-primary font-semibold shadow-sm'
                : 'text-muted hover:text-primary hover:bg-neutral-soft'
            }`}
          >
            Existing Task Chain Agent
          </button>
          <button
            type="button"
            data-debug-id="project-launch-tab-new"
            onClick={() => {
              setActiveTab('new');
              setFeedback(null);
            }}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
              activeTab === 'new'
                ? 'bg-neutral-soft text-primary font-semibold shadow-sm'
                : 'text-muted hover:text-primary hover:bg-neutral-soft'
            }`}
          >
            New Agent Instance
          </button>
          <button
            type="button"
            data-debug-id="project-launch-tab-existing"
            onClick={() => {
              setActiveTab('existing');
              setFeedback(null);
            }}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
              activeTab === 'existing'
                ? 'bg-neutral-soft text-primary font-semibold shadow-sm'
                : 'text-muted hover:text-primary hover:bg-neutral-soft'
            }`}
          >
            Existing Agent Instance
          </button>
        </div>

        {/* Feedback Alert */}
        {feedback && (
          <div
            data-debug-id="project-launch-feedback-banner"
            className={`shrink-0 mb-3 flex items-center gap-2 rounded-xl px-3 py-2 text-xs leading-5 ${
              feedback.type === 'success'
                ? 'border border-success/30 bg-success-soft text-success'
                : 'border border-danger/30 bg-danger-soft text-danger'
            }`}
          >
            <Icon name={feedback.type === 'success' ? 'check' : 'alert'} size={14} />
            <span className="flex-1">{feedback.message}</span>
          </div>
        )}

        {/* Scrollable / Flexible Content Area */}
        <div className="flex-1 min-h-0 flex flex-col overflow-hidden">
          {/* TAB 1: Existing Task Chain Agent */}
          {activeTab === 'chain' && (
            <div className="flex-1 min-h-0 flex flex-col space-y-3 overflow-hidden">
              {chainsQuery.isLoading ? (
                <div className="py-8 text-center text-xs text-muted">Loading task chains…</div>
              ) : chains.length === 0 ? (
                <div
                  data-debug-id="project-launch-chains-empty"
                  className="rounded-xl border border-subtle bg-surface-raised py-8 text-center text-xs text-muted"
                >
                  No task chains found for this project.
                </div>
              ) : (
                <>
                  {/* Task chains list section */}
                  <div className="shrink-0 space-y-1.5">
                    <div className="flex items-center justify-between">
                      <span className="text-caption font-semibold uppercase tracking-[0.14em] text-muted">
                        Select Task Chain
                      </span>
                      {(chainHasMore || chainCursorHistory.length > 0) && (
                        <div className="flex items-center gap-1.5">
                          <Button
                            variant="secondary"
                            size="sm"
                            disabled={chainCursorHistory.length === 0 || isActionRunning}
                            onClick={() => {
                              const newHistory = [...chainCursorHistory];
                              const prev = newHistory.pop() || '';
                              setChainCursorHistory(newHistory);
                              setChainCursor(prev);
                            }}
                          >
                            Previous
                          </Button>
                          <Button
                            variant="secondary"
                            size="sm"
                            disabled={!chainHasMore || !chainNextCursor || isActionRunning}
                            onClick={() => {
                              setChainCursorHistory((prev) => [...prev, chainCursor]);
                              setChainCursor(chainNextCursor);
                            }}
                          >
                            Next
                          </Button>
                        </div>
                      )}
                    </div>

                    {/* Scrollable chains grid */}
                    <div className="max-h-36 overflow-y-auto pr-1 grid gap-2 sm:grid-cols-2">
                      {chains.map((chain) => {
                        const isSelected = chain.chainId === selectedChainId;
                        return (
                          <button
                            key={chain.chainId}
                            type="button"
                            data-debug-id={`project-launch-chain-item-${chain.chainId}`}
                            onClick={() => setSelectedChainId(chain.chainId)}
                            className={`flex flex-col items-start rounded-xl border p-2.5 text-left transition-all ${
                              isSelected
                                ? 'border-accent/60 bg-accent/10 shadow-sm'
                                : 'border-subtle bg-surface hover:bg-surface-raised'
                            }`}
                          >
                            <span className="truncate w-full text-xs font-medium text-primary">
                              {chain.title || chain.chainId}
                            </span>
                            <div className="mt-1 flex items-center gap-2 text-[10px] text-muted">
                              <span className="rounded bg-neutral-soft px-1.5 py-0.5 capitalize">
                                {chain.status || 'active'}
                              </span>
                              <span>{chain.taskCount} task{chain.taskCount === 1 ? '' : 's'}</span>
                            </div>
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Chain Agents List */}
                  {selectedChainId && (
                    <div className="flex-1 min-h-0 flex flex-col rounded-xl border border-subtle bg-surface p-3 overflow-hidden">
                      <div className="shrink-0 flex items-center justify-between pb-2">
                        <span className="text-caption font-semibold uppercase tracking-[0.14em] text-muted">
                          Chain Agents
                        </span>
                        {chainMembers.length > 0 && (
                          <span className="text-[10px] text-faint">
                            {selectedChainAgentIds.size} of {chainMembers.length} selected
                          </span>
                        )}
                      </div>

                      <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-1.5">
                        {chainDetailQuery.isLoading ? (
                          <div className="py-4 text-center text-xs text-muted">Loading chain agents…</div>
                        ) : chainMembers.length === 0 ? (
                          <div className="py-3 text-center text-xs text-muted">
                            No agents found in this task chain.
                          </div>
                        ) : (
                          chainMembers.map((member) => {
                            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                            const memberInstanceId = String(
                              member.agent_instance_id ||
                              member.agentInstanceId ||
                              member.instance_id ||
                              member.id ||
                              ''
                            ).trim();
                            if (!memberInstanceId) return null;
                            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                            const isCoordinator =
                              memberInstanceId === coordinatorAgentInstanceId ||
                              member.agentInstanceId === coordinatorAgentInstanceId ||
                              member.agent_instance_id === coordinatorAgentInstanceId ||
                              member.role === 'coordinator';
                            const isChecked = selectedChainAgentIds.has(memberInstanceId);
                            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                            const memberStatus = String(
                              member.runtimeStatus || member.runtime_status || 'offline'
                            ).toLowerCase();
                            const isActive = isInstanceActive(memberStatus);

                            return (
                              <label
                                key={memberInstanceId}
                                data-debug-id={`project-launch-chain-agent-row-${memberInstanceId}`}
                                className={`flex items-center gap-3 rounded-lg border px-3 py-2 transition-colors ${
                                  isActive
                                    ? 'border-transparent opacity-60 cursor-not-allowed bg-neutral-soft/30'
                                    : isChecked
                                    ? 'border-subtle bg-neutral-soft cursor-pointer'
                                    : 'border-transparent hover:bg-neutral-soft cursor-pointer'
                                }`}
                              >
                                <Checkbox
                                  data-debug-id={`project-launch-chain-agent-checkbox-${memberInstanceId}`}
                                  checked={isChecked}
                                  disabled={isActive}
                                  onChange={() => toggleChainAgent(memberInstanceId, isActive)}
                                />
                                <div className="min-w-0 flex-1 flex items-center gap-2">
                                  <span
                                    className={`truncate text-xs ${
                                      isCoordinator
                                        ? 'text-warning font-semibold'
                                        : 'text-primary'
                                    }`}
                                  >
                                    {/* TODO(FIX): Replace loose fallback chain with canonical typed schema property */}
                                    {member.displayName || member.agentId || memberInstanceId}
                                  </span>
                                  {isCoordinator && (
                                    <span className="rounded-full bg-warning-soft border border-warning/30 px-2 py-0.5 text-[10px] font-semibold text-warning">
                                      Coordinator
                                    </span>
                                  )}
                                  {member.role && !isCoordinator && (
                                    <span className="rounded bg-neutral-soft px-1.5 py-0.2 text-[10px] text-muted capitalize">
                                      {member.role}
                                    </span>
                                  )}
                                </div>
                                {isActive ? (
                                  <span
                                    data-debug-id={`project-launch-chain-agent-active-badge-${memberInstanceId}`}
                                    className="rounded-full bg-success-soft border border-success/30 px-2 py-0.5 text-[10px] font-semibold text-success"
                                  >
                                    Active ({memberStatus})
                                  </span>
                                ) : (
                                  <span className="font-mono text-[10.5px] text-faint">
                                    {memberStatus}
                                  </span>
                                )}
                              </label>
                            );
                          })
                        )}
                      </div>
                    </div>
                  )}
                </>
              )}
            </div>
          )}

          {/* TAB 2: New Agent Instance */}
          {activeTab === 'new' && (
            <div className="flex-1 min-h-0 flex flex-col space-y-2 overflow-hidden">
              {/* Bridge Selector */}
              <div className="shrink-0 flex items-center justify-between gap-3 rounded-xl border border-subtle bg-surface px-3 py-2">
                <label
                  htmlFor="project-launch-bridge-select"
                  className="text-xs font-medium text-primary shrink-0"
                >
                  Target Bridge:
                </label>
                <div className="flex-1 min-w-0 flex items-center justify-end">
                  {bridgesQuery.isLoading ? (
                    <span className="text-xs text-muted">Loading bridges…</span>
                  ) : availableBridges.length === 0 ? (
                    <span className="text-xs text-warning">No bridges available</span>
                  ) : (
                    <Select
                      id="project-launch-bridge-select"
                      data-debug-id="project-launch-bridge-select"
                      value={selectedBridgeId}
                      onChange={setSelectedBridgeId}
                      size="sm"
                      width="full"
                      className="max-w-xs"
                    >
                      {availableBridges.map((b) => (
                        <option key={b.bridgeId} value={b.bridgeId}>
                          {b.label} ({b.status})
                        </option>
                      ))}
                    </Select>
                  )}
                </div>
              </div>

              <div className="shrink-0 flex items-center justify-between pb-1 pt-1">
                <span className="text-caption font-semibold uppercase tracking-[0.14em] text-muted">
                  Durable Agents Catalog
                </span>
                {durableAgents.length > 0 && (
                  <span className="text-caption text-faint">
                    Showing {agentsPage * AGENTS_PAGE_SIZE + 1}–{Math.min((agentsPage + 1) * AGENTS_PAGE_SIZE, durableAgents.length)} of {durableAgents.length}
                  </span>
                )}
              </div>

              <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-1.5">
                {identitiesQuery.isLoading ? (
                  <div className="py-8 text-center text-xs text-muted">Loading agents…</div>
                ) : durableAgents.length === 0 ? (
                  <div
                    data-debug-id="project-launch-new-agents-empty"
                    className="rounded-xl border border-subtle bg-surface-raised py-8 text-center text-xs text-muted"
                  >
                    No durable agents found.
                  </div>
                ) : (
                  paginatedDurableAgents.map((agent) => {
                    const isChecked = selectedNewAgentIds.has(agent.agentId);
                    return (
                      <label
                        key={agent.agentId}
                        data-debug-id={`project-launch-new-agent-row-${agent.agentId}`}
                        className={`flex items-center gap-3 rounded-lg border px-3 py-2 cursor-pointer transition-colors ${
                          isChecked
                            ? 'border-subtle bg-neutral-soft'
                            : 'border-transparent hover:bg-neutral-soft'
                        }`}
                      >
                        <Checkbox
                          data-debug-id={`project-launch-new-agent-checkbox-${agent.agentId}`}
                          checked={isChecked}
                          onChange={() => toggleNewAgent(agent.agentId)}
                        />
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-xs font-medium text-primary">
                            {agent.name}
                          </div>
                          <div className="truncate font-mono text-[10.5px] text-faint">
                            {agent.agentId}
                          </div>
                        </div>
                        {agent.tier && (
                          <span className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted">
                            {agent.tier}
                          </span>
                        )}
                        {agent.provider && (
                          <span className="text-[10.5px] text-faint capitalize">
                            {agent.provider}
                          </span>
                        )}
                      </label>
                    );
                  })
                )}
              </div>

              {/* Pagination Controls */}
              {totalAgentPages > 1 && (
                <div className="shrink-0 flex items-center justify-between border-t border-subtle pt-2">
                  <span className="text-caption text-faint">
                    {selectedNewAgentIds.size} agent(s) selected
                  </span>
                  <div className="flex items-center gap-2">
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={agentsPage === 0 || isActionRunning}
                      onClick={() => setAgentsPage(Math.max(0, agentsPage - 1))}
                    >
                      Previous
                    </Button>
                    <span className="text-caption text-muted">
                      {agentsPage + 1} / {totalAgentPages}
                    </span>
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={agentsPage >= totalAgentPages - 1 || isActionRunning}
                      onClick={() => setAgentsPage(agentsPage + 1)}
                    >
                      Next
                    </Button>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* TAB 3: Existing Agent Instance */}
          {activeTab === 'existing' && (
            <div className="flex-1 min-h-0 flex flex-col space-y-2 overflow-hidden">
              <div className="shrink-0 flex items-center justify-between pb-1">
                <span className="text-caption font-semibold uppercase tracking-[0.14em] text-muted">
                  Project Instances
                </span>
                {stoppedInstances.length > 0 && (
                  <span className="text-caption text-faint">
                    Showing {existingPage * EXISTING_PAGE_SIZE + 1}–{Math.min((existingPage + 1) * EXISTING_PAGE_SIZE, stoppedInstances.length)} of {stoppedInstances.length} ({stoppedInstances.length} stopped instance{stoppedInstances.length === 1 ? '' : 's'})
                  </span>
                )}
              </div>

              <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-1.5">
                {instancesQuery.isLoading ? (
                  <div className="py-8 text-center text-xs text-muted">Loading instances…</div>
                ) : rawInstances.length === 0 ? (
                  <div
                    data-debug-id="project-launch-existing-instances-empty"
                    className="rounded-xl border border-subtle bg-surface-raised py-8 text-center text-xs text-muted"
                  >
                    No existing instances for this project yet.
                  </div>
                ) : hasOnlyActiveInstances ? (
                  <div
                    data-debug-id="project-launch-existing-instances-all-active"
                    className="rounded-xl border border-subtle bg-surface-raised py-8 text-center text-xs text-muted"
                  >
                    All existing instances for this project are currently running.
                  </div>
                ) : (
                  currentInstances.map((inst) => {
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    const instanceId = String(
                      inst.agent_instance_id ||
                      inst.agentInstanceId ||
                      inst.instance_id ||
                      inst.instanceId ||
                      inst.id ||
                      ''
                    ).trim();
                    if (!instanceId) return null;
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    const agentId = String(inst.agent_id || inst.agentId || '');
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    const displayName = String(inst.display_name || inst.displayName || agentId || instanceId);
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    const runtimeStatus = String(inst.runtime_status || inst.runtimeStatus || 'stopped').toLowerCase();
                    const isChecked = selectedExistingInstanceIds.has(instanceId);

                    return (
                      <label
                        key={instanceId}
                        data-debug-id={`project-launch-existing-instance-row-${instanceId}`}
                        className={`flex items-center gap-3 rounded-lg border px-3 py-2 cursor-pointer transition-colors ${
                          isChecked
                            ? 'border-subtle bg-neutral-soft'
                            : 'border-transparent hover:bg-neutral-soft'
                        }`}
                      >
                        <Checkbox
                          data-debug-id={`project-launch-existing-instance-checkbox-${instanceId}`}
                          checked={isChecked}
                          onChange={() => toggleExistingInstance(instanceId)}
                        />
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-xs font-medium text-primary">
                            {displayName}
                          </div>
                          <div className="truncate font-mono text-[10.5px] text-faint">
                            {instanceId}
                          </div>
                        </div>
                        <span className="rounded-full px-2 py-0.5 text-[10px] font-semibold border border-subtle bg-neutral-soft text-muted">
                          {runtimeStatus}
                        </span>
                      </label>
                    );
                  })
                )}
              </div>

              {/* Pagination Controls */}
              {totalExistingPages > 1 && (
                <div className="shrink-0 flex items-center justify-between border-t border-subtle pt-2">
                  <span className="text-caption text-faint">
                    {selectedExistingInstanceIds.size} instance(s) selected
                  </span>
                  <div className="flex items-center gap-2">
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={existingPage === 0 || isActionRunning}
                      onClick={() => setExistingPage(Math.max(0, existingPage - 1))}
                    >
                      Previous
                    </Button>
                    <span className="text-caption text-muted">
                      {existingPage + 1} / {totalExistingPages}
                    </span>
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={existingPage >= totalExistingPages - 1 || isActionRunning}
                      onClick={() => setExistingPage(existingPage + 1)}
                    >
                      Next
                    </Button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>

      </div>

      {/* Modal Footer with Action Buttons */}
      <Modal.Footer className="px-6">
        <div className="flex w-full items-center justify-between">
          <Button
            variant="secondary"
            data-debug-id="project-launch-cancel-btn"
            disabled={isActionRunning}
            onClick={onClose}
          >
            Cancel
          </Button>

          {activeTab === 'chain' && (
            <Button
              variant="primary"
              data-debug-id="project-launch-start-chain-agents-btn"
              disabled={selectedChainAgentIds.size === 0 || isActionRunning}
              onClick={handleStartChainAgents}
            >
              {isActionRunning ? 'Starting…' : 'Start Selected Agents'}
            </Button>
          )}

          {activeTab === 'new' && (
            <Button
              variant="primary"
              data-debug-id="project-launch-launch-new-agents-btn"
              disabled={selectedNewAgentIds.size === 0 || !selectedBridgeId || isActionRunning}
              onClick={handleLaunchNewAgents}
            >
              {isActionRunning ? 'Launching…' : 'Launch Selected Agents'}
            </Button>
          )}

          {activeTab === 'existing' && (
            <Button
              variant="primary"
              data-debug-id="project-launch-start-existing-instances-btn"
              disabled={selectedExistingInstanceIds.size === 0 || isActionRunning}
              onClick={handleStartExistingInstances}
            >
              {isActionRunning ? 'Starting…' : 'Start Selected Instances'}
            </Button>
          )}
        </div>
      </Modal.Footer>
    </Modal>
  );
}
