import { useState, useMemo, useEffect } from 'react';
import Icon from '../Icon';
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
  const chainMembers: any[] = chainDetail?.members || [];
  const coordinatorAgentInstanceId = chainDetail?.coordinatorAgentInstanceId || '';

  // Tab 2: Durable agents catalog via useListAgentIdentitiesQuery (cookie-auth /api/v1/agents)
  const AGENTS_PAGE_SIZE = 10;
  const identitiesQuery = useListAgentIdentitiesQuery(
    { limit: 200 },
    { skip: !isOpen || activeTab !== 'new' }
  );
  const rawIdentities: any[] = identitiesQuery.data?.agents || [];
  const durableAgents = useMemo(() => {
    const list: Array<{ agentId: string; name: string; tier: string; provider: string; state: string }> = [];
    for (const item of rawIdentities) {
      const agentId = String(item.agent_id || item.agentId || item.id || '').trim();
      const state = String(item.state || '').trim().toLowerCase();
      // Filter out archived agents
      if (!agentId || state === 'archived') continue;
      list.push({
        agentId,
        name: String(item.name || item.slug || agentId),
        tier: String(item.default_tier || item.defaultTier || ''),
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
  const rawBridges: any[] = bridgesQuery.data?.bridges || [];
  const availableBridges = useMemo(() => {
    const list: Array<{ bridgeId: string; label: string; status: string; isOnline: boolean }> = [];
    for (const raw of rawBridges) {
      const b = raw?.bridge || raw;
      const bridgeId = String(b?.bridge_id || b?.bridgeId || b?.id || '').trim();
      if (!bridgeId) continue;
      const status = String(b?.status || b?.runtime_status || 'offline').toLowerCase();
      if (status === 'revoked') continue;
      const isOnline = status === 'online' || status === 'connected';
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
  const rawInstances: any[] = instancesQuery.data?.instances || [];
  const stoppedInstances = useMemo(() => {
    return rawInstances.filter((inst) => {
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
          (m: any) =>
            m.agentInstanceId === coordId ||
            m.agent_instance_id === coordId ||
            m.role === 'coordinator'
        );
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
    if (isActive) return;
    setSelectedChainAgentIds((prev) => {
      const next = new Set(prev);
      if (next.has(instanceId)) next.delete(instanceId);
      else next.add(instanceId);
      return next;
    });
  };

  const handleStartChainAgents = async () => {
    if (selectedChainAgentIds.size === 0) return;
    setIsActionRunning(true);
    setFeedback(null);
    try {
      const ids = Array.from(selectedChainAgentIds);
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
      onClose();
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
      for (const agentId of ids) {
        await launchAgentInstance({ agentId, projectId, bridgeId: selectedBridgeId }).unwrap();
      }
      setFeedback({
        type: 'success',
        message: `Successfully launched ${ids.length} new agent instance(s) for ${project.name}.`,
      });
      setSelectedNewAgentIds(new Set());
      onClose();
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
    setSelectedExistingInstanceIds((prev) => {
      const next = new Set(prev);
      if (next.has(instanceId)) next.delete(instanceId);
      else next.add(instanceId);
      return next;
    });
  };

  const handleStartExistingInstances = async () => {
    if (selectedExistingInstanceIds.size === 0) return;
    setIsActionRunning(true);
    setFeedback(null);
    try {
      const ids = Array.from(selectedExistingInstanceIds);
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
      onClose();
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
    <div
      data-debug-id="project-launch-modal-overlay"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm animate-fade-in"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        data-debug-id="project-launch-modal"
        className="flex flex-col w-full max-w-2xl max-h-[85vh] h-[640px] rounded-2xl border border-white/10 bg-[#121212] p-6 shadow-2xl text-white"
      >
        {/* Modal Header */}
        <div className="shrink-0 flex items-center justify-between pb-3">
          <div>
            <h2 className="text-base font-semibold text-white">
              Launch Agent — <span className="text-sky-400">{project.name}</span>
            </h2>
            <p className="text-xs text-zinc-400 mt-0.5">
              Start or launch agents scoped to this project
            </p>
          </div>
          <button
            type="button"
            data-debug-id="project-launch-modal-close-btn"
            aria-label="Close"
            onClick={onClose}
            className="rounded-lg p-1.5 text-zinc-400 hover:bg-white/10 hover:text-white transition-colors"
          >
            <Icon name="close" size={16} />
          </button>
        </div>

        {/* Tab Navigation */}
        <div className="shrink-0 flex items-center gap-2 border-b border-white/10 pb-2.5 mb-3">
          <button
            type="button"
            data-debug-id="project-launch-tab-chain"
            onClick={() => {
              setActiveTab('chain');
              setFeedback(null);
            }}
            className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
              activeTab === 'chain'
                ? 'bg-white/10 text-white font-semibold shadow-sm'
                : 'text-zinc-400 hover:text-zinc-200 hover:bg-white/5'
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
                ? 'bg-white/10 text-white font-semibold shadow-sm'
                : 'text-zinc-400 hover:text-zinc-200 hover:bg-white/5'
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
                ? 'bg-white/10 text-white font-semibold shadow-sm'
                : 'text-zinc-400 hover:text-zinc-200 hover:bg-white/5'
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
                ? 'border border-emerald-500/20 bg-emerald-500/10 text-emerald-300'
                : 'border border-red-500/20 bg-red-500/10 text-red-300'
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
                <div className="py-8 text-center text-xs text-zinc-500">Loading task chains…</div>
              ) : chains.length === 0 ? (
                <div
                  data-debug-id="project-launch-chains-empty"
                  className="rounded-xl border border-white/5 bg-white/[0.02] py-8 text-center text-xs text-zinc-500"
                >
                  No task chains found for this project.
                </div>
              ) : (
                <>
                  {/* Task chains list section */}
                  <div className="shrink-0 space-y-1.5">
                    <div className="flex items-center justify-between">
                      <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">
                        Select Task Chain
                      </span>
                      {(chainHasMore || chainCursorHistory.length > 0) && (
                        <div className="flex items-center gap-1.5">
                          <button
                            type="button"
                            disabled={chainCursorHistory.length === 0 || isActionRunning}
                            onClick={() => {
                              const newHistory = [...chainCursorHistory];
                              const prev = newHistory.pop() || '';
                              setChainCursorHistory(newHistory);
                              setChainCursor(prev);
                            }}
                            className="rounded border border-white/10 bg-white/5 px-2 py-0.5 text-[10.5px] text-zinc-300 hover:bg-white/10 disabled:opacity-40"
                          >
                            Previous
                          </button>
                          <button
                            type="button"
                            disabled={!chainHasMore || !chainNextCursor || isActionRunning}
                            onClick={() => {
                              setChainCursorHistory((prev) => [...prev, chainCursor]);
                              setChainCursor(chainNextCursor);
                            }}
                            className="rounded border border-white/10 bg-white/5 px-2 py-0.5 text-[10.5px] text-zinc-300 hover:bg-white/10 disabled:opacity-40"
                          >
                            Next
                          </button>
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
                                ? 'border-sky-500/60 bg-sky-500/10 shadow-sm'
                                : 'border-white/10 bg-white/[0.02] hover:bg-white/[0.05]'
                            }`}
                          >
                            <span className="truncate w-full text-xs font-medium text-zinc-200">
                              {chain.title || chain.chainId}
                            </span>
                            <div className="mt-1 flex items-center gap-2 text-[10px] text-zinc-400">
                              <span className="rounded bg-white/5 px-1.5 py-0.5 capitalize">
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
                    <div className="flex-1 min-h-0 flex flex-col rounded-xl border border-white/10 bg-black/20 p-3 overflow-hidden">
                      <div className="shrink-0 flex items-center justify-between pb-2">
                        <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-400">
                          Chain Agents
                        </span>
                        {chainMembers.length > 0 && (
                          <span className="text-[10px] text-zinc-500">
                            {selectedChainAgentIds.size} of {chainMembers.length} selected
                          </span>
                        )}
                      </div>

                      <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-1.5">
                        {chainDetailQuery.isLoading ? (
                          <div className="py-4 text-center text-xs text-zinc-500">Loading chain agents…</div>
                        ) : chainMembers.length === 0 ? (
                          <div className="py-3 text-center text-xs text-zinc-500">
                            No agents found in this task chain.
                          </div>
                        ) : (
                          chainMembers.map((member) => {
                            const isCoordinator =
                              member.agentInstanceId === coordinatorAgentInstanceId ||
                              member.role === 'coordinator';
                            const isChecked = selectedChainAgentIds.has(member.agentInstanceId);
                            const memberStatus = String(
                              member.runtimeStatus || member.runtime_status || 'offline'
                            ).toLowerCase();
                            const isActive = isInstanceActive(memberStatus);

                            return (
                              <label
                                key={member.agentInstanceId}
                                data-debug-id={`project-launch-chain-agent-row-${member.agentInstanceId}`}
                                className={`flex items-center gap-3 rounded-lg border px-3 py-2 transition-colors ${
                                  isActive
                                    ? 'border-transparent opacity-60 cursor-not-allowed bg-white/[0.01]'
                                    : isChecked
                                    ? 'border-white/20 bg-white/[0.06] cursor-pointer'
                                    : 'border-transparent hover:bg-white/[0.03] cursor-pointer'
                                }`}
                              >
                                <input
                                  type="checkbox"
                                  data-debug-id={`project-launch-chain-agent-checkbox-${member.agentInstanceId}`}
                                  checked={isChecked}
                                  disabled={isActive}
                                  onChange={() => toggleChainAgent(member.agentInstanceId, isActive)}
                                  className="h-4 w-4 rounded border-zinc-700 bg-black/40 text-sky-500 focus:ring-0 focus:ring-offset-0 disabled:opacity-40 cursor-pointer disabled:cursor-not-allowed"
                                />
                                <div className="min-w-0 flex-1 flex items-center gap-2">
                                  <span
                                    className={`truncate text-xs ${
                                      isCoordinator
                                        ? 'text-amber-400 font-semibold'
                                        : 'text-zinc-200'
                                    }`}
                                  >
                                    {member.displayName || member.agentId || member.agentInstanceId}
                                  </span>
                                  {isCoordinator && (
                                    <span className="rounded-full bg-amber-400/15 border border-amber-400/30 px-2 py-0.5 text-[10px] font-semibold text-amber-300">
                                      Coordinator
                                    </span>
                                  )}
                                  {member.role && !isCoordinator && (
                                    <span className="rounded bg-white/5 px-1.5 py-0.2 text-[10px] text-zinc-400 capitalize">
                                      {member.role}
                                    </span>
                                  )}
                                </div>
                                {isActive ? (
                                  <span
                                    data-debug-id={`project-launch-chain-agent-active-badge-${member.agentInstanceId}`}
                                    className="rounded-full bg-emerald-400/15 border border-emerald-400/30 px-2 py-0.5 text-[10px] font-semibold text-emerald-300"
                                  >
                                    Active ({memberStatus})
                                  </span>
                                ) : (
                                  <span className="font-mono text-[10.5px] text-zinc-500">
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
              <div className="shrink-0 flex items-center justify-between gap-3 rounded-xl border border-white/10 bg-black/20 px-3 py-2">
                <label
                  htmlFor="project-launch-bridge-select"
                  className="text-xs font-medium text-zinc-300 shrink-0"
                >
                  Target Bridge:
                </label>
                <div className="flex-1 min-w-0 flex items-center justify-end">
                  {bridgesQuery.isLoading ? (
                    <span className="text-xs text-zinc-500">Loading bridges…</span>
                  ) : availableBridges.length === 0 ? (
                    <span className="text-xs text-amber-400">No bridges available</span>
                  ) : (
                    <select
                      id="project-launch-bridge-select"
                      data-debug-id="project-launch-bridge-select"
                      value={selectedBridgeId}
                      onChange={(e) => setSelectedBridgeId(e.target.value)}
                      className="w-full max-w-xs rounded-lg border border-white/10 bg-black/40 px-2.5 py-1.5 text-xs text-zinc-100 outline-none focus:border-sky-400 cursor-pointer"
                    >
                      {availableBridges.map((b) => (
                        <option key={b.bridgeId} value={b.bridgeId}>
                          {b.label} ({b.status})
                        </option>
                      ))}
                    </select>
                  )}
                </div>
              </div>

              <div className="shrink-0 flex items-center justify-between pb-1 pt-1">
                <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-400">
                  Durable Agents Catalog
                </span>
                {durableAgents.length > 0 && (
                  <span className="text-[11px] text-zinc-500">
                    Showing {agentsPage * AGENTS_PAGE_SIZE + 1}–{Math.min((agentsPage + 1) * AGENTS_PAGE_SIZE, durableAgents.length)} of {durableAgents.length}
                  </span>
                )}
              </div>

              <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-1.5">
                {identitiesQuery.isLoading ? (
                  <div className="py-8 text-center text-xs text-zinc-500">Loading agents…</div>
                ) : durableAgents.length === 0 ? (
                  <div
                    data-debug-id="project-launch-new-agents-empty"
                    className="rounded-xl border border-white/5 bg-white/[0.02] py-8 text-center text-xs text-zinc-500"
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
                            ? 'border-white/20 bg-white/[0.06]'
                            : 'border-transparent hover:bg-white/[0.03]'
                        }`}
                      >
                        <input
                          type="checkbox"
                          data-debug-id={`project-launch-new-agent-checkbox-${agent.agentId}`}
                          checked={isChecked}
                          onChange={() => toggleNewAgent(agent.agentId)}
                          className="h-4 w-4 rounded border-zinc-700 bg-black/40 text-sky-500 focus:ring-0 focus:ring-offset-0 cursor-pointer"
                        />
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-xs font-medium text-zinc-200">
                            {agent.name}
                          </div>
                          <div className="truncate font-mono text-[10.5px] text-zinc-500">
                            {agent.agentId}
                          </div>
                        </div>
                        {agent.tier && (
                          <span className="rounded bg-white/5 px-1.5 py-0.5 text-[10px] text-zinc-400">
                            {agent.tier}
                          </span>
                        )}
                        {agent.provider && (
                          <span className="text-[10.5px] text-zinc-500 capitalize">
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
                <div className="shrink-0 flex items-center justify-between border-t border-white/5 pt-2">
                  <span className="text-[11px] text-zinc-500">
                    {selectedNewAgentIds.size} agent(s) selected
                  </span>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      disabled={agentsPage === 0 || isActionRunning}
                      onClick={() => setAgentsPage(Math.max(0, agentsPage - 1))}
                      className="rounded-lg border border-white/10 bg-white/5 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-40"
                    >
                      Previous
                    </button>
                    <span className="text-[11px] text-zinc-400">
                      {agentsPage + 1} / {totalAgentPages}
                    </span>
                    <button
                      type="button"
                      disabled={agentsPage >= totalAgentPages - 1 || isActionRunning}
                      onClick={() => setAgentsPage(agentsPage + 1)}
                      className="rounded-lg border border-white/10 bg-white/5 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-40"
                    >
                      Next
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* TAB 3: Existing Agent Instance */}
          {activeTab === 'existing' && (
            <div className="flex-1 min-h-0 flex flex-col space-y-2 overflow-hidden">
              <div className="shrink-0 flex items-center justify-between pb-1">
                <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-400">
                  Project Instances
                </span>
                {stoppedInstances.length > 0 && (
                  <span className="text-[11px] text-zinc-500">
                    Showing {existingPage * EXISTING_PAGE_SIZE + 1}–{Math.min((existingPage + 1) * EXISTING_PAGE_SIZE, stoppedInstances.length)} of {stoppedInstances.length} ({stoppedInstances.length} stopped instance{stoppedInstances.length === 1 ? '' : 's'})
                  </span>
                )}
              </div>

              <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-1.5">
                {instancesQuery.isLoading ? (
                  <div className="py-8 text-center text-xs text-zinc-500">Loading instances…</div>
                ) : rawInstances.length === 0 ? (
                  <div
                    data-debug-id="project-launch-existing-instances-empty"
                    className="rounded-xl border border-white/5 bg-white/[0.02] py-8 text-center text-xs text-zinc-500"
                  >
                    No existing instances for this project yet.
                  </div>
                ) : hasOnlyActiveInstances ? (
                  <div
                    data-debug-id="project-launch-existing-instances-all-active"
                    className="rounded-xl border border-white/5 bg-white/[0.02] py-8 text-center text-xs text-zinc-400"
                  >
                    All existing instances for this project are currently running.
                  </div>
                ) : (
                  currentInstances.map((inst) => {
                    const instanceId = String(inst.instance_id || inst.instanceId || inst.id || '');
                    const agentId = String(inst.agent_id || inst.agentId || '');
                    const displayName = String(inst.display_name || inst.displayName || agentId || instanceId);
                    const runtimeStatus = String(inst.runtime_status || inst.runtimeStatus || 'stopped').toLowerCase();
                    const isChecked = selectedExistingInstanceIds.has(instanceId);

                    return (
                      <label
                        key={instanceId}
                        data-debug-id={`project-launch-existing-instance-row-${instanceId}`}
                        className={`flex items-center gap-3 rounded-lg border px-3 py-2 cursor-pointer transition-colors ${
                          isChecked
                            ? 'border-white/20 bg-white/[0.06]'
                            : 'border-transparent hover:bg-white/[0.03]'
                        }`}
                      >
                        <input
                          type="checkbox"
                          data-debug-id={`project-launch-existing-instance-checkbox-${instanceId}`}
                          checked={isChecked}
                          onChange={() => toggleExistingInstance(instanceId)}
                          className="h-4 w-4 rounded border-zinc-700 bg-black/40 text-sky-500 focus:ring-0 focus:ring-offset-0 cursor-pointer"
                        />
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-xs font-medium text-zinc-200">
                            {displayName}
                          </div>
                          <div className="truncate font-mono text-[10.5px] text-zinc-500">
                            {instanceId}
                          </div>
                        </div>
                        <span className="rounded-full px-2 py-0.5 text-[10px] font-semibold border bg-zinc-700/50 border-zinc-600/50 text-zinc-400">
                          {runtimeStatus}
                        </span>
                      </label>
                    );
                  })
                )}
              </div>

              {/* Pagination Controls */}
              {totalExistingPages > 1 && (
                <div className="shrink-0 flex items-center justify-between border-t border-white/5 pt-2">
                  <span className="text-[11px] text-zinc-500">
                    {selectedExistingInstanceIds.size} instance(s) selected
                  </span>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      disabled={existingPage === 0 || isActionRunning}
                      onClick={() => setExistingPage(Math.max(0, existingPage - 1))}
                      className="rounded-lg border border-white/10 bg-white/5 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-40"
                    >
                      Previous
                    </button>
                    <span className="text-[11px] text-zinc-400">
                      {existingPage + 1} / {totalExistingPages}
                    </span>
                    <button
                      type="button"
                      disabled={existingPage >= totalExistingPages - 1 || isActionRunning}
                      onClick={() => setExistingPage(existingPage + 1)}
                      className="rounded-lg border border-white/10 bg-white/5 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-white/10 disabled:opacity-40"
                    >
                      Next
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Modal Footer with Action Buttons */}
        <div className="shrink-0 flex items-center justify-between border-t border-white/10 pt-3">
          <button
            type="button"
            data-debug-id="project-launch-cancel-btn"
            disabled={isActionRunning}
            onClick={onClose}
            className="rounded-xl border border-white/10 bg-white/5 px-4 py-2 text-xs font-semibold text-zinc-300 hover:bg-white/10 transition-colors"
          >
            Cancel
          </button>

          {activeTab === 'chain' && (
            <button
              type="button"
              data-debug-id="project-launch-start-chain-agents-btn"
              disabled={selectedChainAgentIds.size === 0 || isActionRunning}
              onClick={handleStartChainAgents}
              className="rounded-xl bg-sky-500 px-4 py-2 text-xs font-semibold text-black hover:bg-sky-400 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isActionRunning ? 'Starting…' : 'Start Selected Agents'}
            </button>
          )}

          {activeTab === 'new' && (
            <button
              type="button"
              data-debug-id="project-launch-launch-new-agents-btn"
              disabled={selectedNewAgentIds.size === 0 || !selectedBridgeId || isActionRunning}
              onClick={handleLaunchNewAgents}
              className="rounded-xl bg-sky-500 px-4 py-2 text-xs font-semibold text-black hover:bg-sky-400 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isActionRunning ? 'Launching…' : 'Launch Selected Agents'}
            </button>
          )}

          {activeTab === 'existing' && (
            <button
              type="button"
              data-debug-id="project-launch-start-existing-instances-btn"
              disabled={selectedExistingInstanceIds.size === 0 || isActionRunning}
              onClick={handleStartExistingInstances}
              className="rounded-xl bg-sky-500 px-4 py-2 text-xs font-semibold text-black hover:bg-sky-400 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isActionRunning ? 'Starting…' : 'Start Selected Instances'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
