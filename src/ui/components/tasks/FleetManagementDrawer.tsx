import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Badge,
  Button,
  Icon,
  IconButton,
  Modal,
  ModalBody,
  ModalFooter,
  Select,
  StatusDot,
  Text,
} from '@ui';
import {
  useGetTaskChainFleetsQuery,
  useUpdateTaskChainFleetMutation,
  type TaskChainFleet,
} from '../../api/endpoints/taskChains';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { useListBridgeProvidersQuery } from '../../api/endpoints/bridgeSupport';
import {
  activeTasksByRole,
  changedFleetEntries,
  fleetApplyRequests,
  fleetProviderCapabilities,
  getOriginalFleetCapacity,
  getOriginalProviderTier,
  liveInstancesByRole,
  nextTierOnProviderChange,
  restartAffectedEntries,
  seedProviderTierDrafts,
  summarizeFleetRestartResults,
  tierOptionsForProvider,
  type ChangedFleetEntry,
  type FleetProviderTier,
  type FleetRestartSummary,
} from './fleetSelection';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';

export function formatFleetRoleName(agentId?: string, identities?: any[]): string {
  if (!agentId) return 'Worker';
  const found = identities?.find(
    (a) => String(a.agent_id || a.agentId || a.id || '') === agentId
  );
  if (found?.name) return found.name;
  if (found?.display_name) return found.display_name;
  if (agentId.startsWith('agt_')) {
    const raw = agentId.slice(4);
    return raw.charAt(0).toUpperCase() + raw.slice(1);
  }
  return agentId.charAt(0).toUpperCase() + agentId.slice(1);
}

export function renderSlotDots(active: number, capacity: number): string {
  const cap = Math.max(1, Math.min(capacity, 10));
  const act = Math.max(0, Math.min(active, cap));
  let dots = '';
  for (let i = 0; i < cap; i++) {
    dots += i < act ? '●' : '○';
  }
  return dots;
}

export function getQueuedWaitingSlotName(task: any, identities?: any[]): string {
  if (!task) return 'Worker';
  const status = String(task.status || '').toLowerCase();
  if (status === 'in_validation') {
    return 'Reviewer';
  }
  const assigneeRef = task.assigneeRef || task.assignee_ref;
  const targetAgentId =
    assigneeRef?.agent_id ||
    assigneeRef?.agentId ||
    task.assigneeAgentId ||
    task.assignee_agent_id ||
    '';
  if (targetAgentId) {
    return formatFleetRoleName(targetAgentId, identities);
  }
  return 'Worker';
}

export {
  isRoleAssignedWithoutLiveInstance,
  canStartTask,
  hasLiveNudgeTarget,
  getUnpauseStatus,
} from './TaskCard';

export interface FleetSlotChipsProps {
  chainId: string;
  onOpenDrawer?: () => void;
  className?: string;
}

export const FleetSlotChips: React.FC<FleetSlotChipsProps> = ({
  chainId,
  onOpenDrawer,
  className = '',
}) => {
  const { data: rawFleets = [], isLoading } = useGetTaskChainFleetsQuery(
    { chainId },
    { skip: !chainId, pollingInterval: 5000 }
  );
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentIdentities = agentIdentitiesQuery.data?.agents || [];

  // REQ-AUTO-1: the Fleet renders exactly the persisted rows — no synthetic
  // standard-role cards. An empty Fleet is empty.
  const fleets = rawFleets;

  if (!chainId) return null;

  return (
    <div
      data-debug-id="fleet-slot-chips"
      className={`flex items-center gap-1.5 flex-wrap ${className}`}
    >
      {fleets.map((fleet) => {
        const roleName = formatFleetRoleName(fleet.agent_id, agentIdentities);
        const capacity = fleet.capacity ?? 1;
        const activeCount = fleet.active_count ?? fleet.activeCount ?? 0;
        const isSaturated = activeCount >= capacity;

        return (
          <button
            key={fleet.agent_id}
            type="button"
            data-debug-id={`fleet-slot-chip-${fleet.agent_id}`}
            onClick={onOpenDrawer}
            title={`Fleet ${roleName}: ${activeCount}/${capacity} active slots. Click to manage capacity.`}
            className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium border transition-colors cursor-pointer shadow-xs ${
              isSaturated
                ? 'border-warning/40 bg-warning-soft/30 text-warning hover:bg-warning-soft/50'
                : 'border-subtle bg-surface-raised hover:bg-neutral-soft text-primary'
            }`}
          >
            <span className="font-semibold">{roleName}:</span>
            <span className="font-mono text-[11px]">{activeCount}/{capacity} active</span>
            <span className="text-accent text-[11px] tracking-tighter select-none font-mono">
              {renderSlotDots(activeCount, capacity)}
            </span>
          </button>
        );
      })}

      {onOpenDrawer && (
        <button
          type="button"
          data-debug-id="fleet-slot-chips-manage-btn"
          onClick={onOpenDrawer}
          title="Open Fleet Management Drawer"
          className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] text-muted hover:text-primary hover:bg-neutral-soft transition-colors cursor-pointer border border-dashed border-subtle"
        >
          <Icon name="layers" size={12} />
          <span>Fleet</span>
        </button>
      )}
    </div>
  );
};

/** One row of the restart-confirmation modal: the affected role + what to warn about. */
interface PendingRestartRole extends ChangedFleetEntry {
  liveCount: number;
  activeTaskCount: number;
  originalProvider: string;
  originalTier: string;
}

export interface FleetManagementDrawerProps {
  chainId: string;
  isOpen: boolean;
  onClose: () => void;
}

export const FleetManagementDrawer: React.FC<FleetManagementDrawerProps> = ({
  chainId,
  isOpen,
  onClose,
}) => {
  const { data: rawFleets = [], refetch } = useGetTaskChainFleetsQuery(
    { chainId },
    { skip: !chainId, pollingInterval: 4000 }
  );
  const chainDetailQuery = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId }
  );
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentIdentities = agentIdentitiesQuery.data?.agents || [];
  const members = (chainDetailQuery.data?.chain?.members || []) as any[];
  const tasks = (chainDetailQuery.data?.chain?.tasks || []) as any[];
  const liveInstancesByRoleMap = useMemo(() => liveInstancesByRole(members), [members]);
  const activeTasksByRoleMap = useMemo(() => activeTasksByRole(tasks, members), [tasks, members]);

  // Provider/tier options come from the chain's first bridge directory; chains
  // without a bridge keep the capacity-only drawer.
  const directories = (chainDetailQuery.data?.chain?.directories || []) as any[];
  const bridgeId = directories.length > 0 ? String(directories[0]?.bridgeId || '') : '';
  const providersQuery = useListBridgeProvidersQuery({ bridgeId }, { skip: !bridgeId });
  const bridgeCapabilities = useMemo(
    () => fleetProviderCapabilities(providersQuery.data),
    [providersQuery.data]
  );

  const [updateFleet, { isLoading: isUpdating }] = useUpdateTaskChainFleetMutation();
  const [selectedNewAgentId, setSelectedNewAgentId] = useState('');
  const [errorMsg, setErrorMsg] = useState('');
  const [successMsg, setSuccessMsg] = useState('');
  const [isApplying, setIsApplying] = useState(false);
  const [draftCapacities, setDraftCapacities] = useState<Record<string, number>>({});
  const [draftProviderTiers, setDraftProviderTiers] = useState<Record<string, FleetProviderTier>>({});
  const [pendingRestart, setPendingRestart] = useState<PendingRestartRole[] | null>(null);
  const [restartSummary, setRestartSummary] = useState<FleetRestartSummary | null>(null);

  const prevIsOpenRef = useRef(false);
  // True when the current press started on the drawer backdrop itself (see the
  // backdrop's handlers): a press inside the panel — or on the restart modal's
  // portal overlay, whose mouseup lands on the backdrop once the modal unmounts —
  // must not dismiss the drawer.
  const backdropPressStartedRef = useRef(false);

  const seedDrafts = useCallback(() => {
    const init: Record<string, number> = {};
    for (const f of rawFleets) {
      init[f.agent_id] = f.capacity ?? 1;
    }
    setDraftCapacities(init);
    setDraftProviderTiers(seedProviderTierDrafts(rawFleets));
  }, [rawFleets]);

  // Sync drafts when drawer opens
  useEffect(() => {
    if (isOpen && !prevIsOpenRef.current) {
      seedDrafts();
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
      setPendingRestart(null);
    } else if (!isOpen && prevIsOpenRef.current) {
      setPendingRestart(null);
    }
    prevIsOpenRef.current = isOpen;
  }, [isOpen, seedDrafts]);

  // REQ-AUTO-1: render exactly the persisted rows plus any roles staged via
  // Add Role — no synthetic standard-role cards. An empty Fleet renders empty.
  const fleets = useMemo(() => {
    const list: TaskChainFleet[] = [...rawFleets];
    const seen = new Set(list.map((f) => f.agent_id));

    // Include any newly added agent roles staged in draftCapacities
    for (const [aid, cap] of Object.entries(draftCapacities)) {
      if (!seen.has(aid)) {
        list.push({
          task_chain_id: chainId,
          agent_id: aid,
          capacity: cap,
          active_count: 0,
        });
        seen.add(aid);
      }
    }

    return list;
  }, [rawFleets, chainId, draftCapacities]);

  const getOriginalCapacity = useCallback(
    (agentId: string) => getOriginalFleetCapacity(rawFleets, agentId),
    [rawFleets]
  );

  const handleDraftCapacityChange = useCallback((agentId: string, newCapacity: number) => {
    const clamped = Math.max(1, Math.min(20, newCapacity));
    setDraftCapacities((prev) => ({
      ...prev,
      [agentId]: clamped,
    }));
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftProviderChange = useCallback((agentId: string, provider: string) => {
    setDraftProviderTiers((prev) => {
      const currentTier = prev[agentId]?.tier ?? '';
      return {
        ...prev,
        [agentId]: {
          provider,
          tier: nextTierOnProviderChange(currentTier, provider, bridgeCapabilities),
        },
      };
    });
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, [bridgeCapabilities]);

  const handleDraftTierChange = useCallback((agentId: string, tier: string) => {
    setDraftProviderTiers((prev) => ({
      ...prev,
      [agentId]: { provider: prev[agentId]?.provider ?? '', tier },
    }));
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleAddFleet = useCallback((agentId: string) => {
    if (!agentId) return;
    setDraftCapacities((prev) => ({
      ...prev,
      [agentId]: prev[agentId] ?? 1,
    }));
    setDraftProviderTiers((prev) => ({
      ...prev,
      [agentId]: prev[agentId] ?? { provider: '', tier: '' },
    }));
    setSelectedNewAgentId('');
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const changedFleets = useMemo(
    () => changedFleetEntries(fleets, draftCapacities, draftProviderTiers, rawFleets),
    [fleets, draftCapacities, draftProviderTiers, rawFleets]
  );

  const hasPendingChanges = changedFleets.length > 0;

  const handleReset = useCallback(() => {
    seedDrafts();
    setErrorMsg('');
    setSuccessMsg('');
  }, [seedDrafts]);

  /** PUT every changed role; `restartAffected` roles additionally get the restart flag. */
  const applyFleetChanges = useCallback(
    async (restartAffected: ChangedFleetEntry[]) => {
      if (isUpdating || isApplying) return;
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
      setIsApplying(true);
      try {
        const requests = fleetApplyRequests(changedFleets, restartAffected);
        const results = await Promise.all(
          requests.map(async (cf) => {
            const response = await updateFleet({
              chainId,
              agentId: cf.agentId,
              capacity: cf.capacity,
              provider: cf.provider,
              tier: cf.tier,
              restartLiveInstances: cf.restartLiveInstances,
            }).unwrap();
            return {
              agentId: cf.agentId,
              restarted_instance_ids: response?.restarted_instance_ids,
              restart_failures: response?.restart_failures,
            };
          })
        );
        await refetch();
        await chainDetailQuery.refetch();
        setSuccessMsg(
          `Applied fleet updates for ${changedFleets.length} ${
            changedFleets.length === 1 ? 'role' : 'roles'
          }`
        );
        const flaggedIds = new Set(restartAffected.map((entry) => entry.agentId));
        const flaggedResults = results.filter((result) => flaggedIds.has(result.agentId));
        if (flaggedResults.length > 0) {
          setRestartSummary(summarizeFleetRestartResults(flaggedResults));
        }
      } catch (err: any) {
        setErrorMsg(
          String(err?.data?.error?.message || err?.message || 'Failed to update fleet settings')
        );
      } finally {
        setIsApplying(false);
      }
    },
    [isUpdating, isApplying, changedFleets, updateFleet, chainId, refetch, chainDetailQuery]
  );

  const handleApply = useCallback(() => {
    if (!hasPendingChanges || isUpdating || isApplying) return;
    const liveCounts: Record<string, number> = {};
    for (const [agentId, list] of Object.entries(liveInstancesByRoleMap)) {
      liveCounts[agentId] = list.length;
    }
    const affected = restartAffectedEntries(
      changedFleets,
      rawFleets,
      draftProviderTiers,
      liveCounts
    );
    // No provider/tier change on a role with live instances -> today's silent apply.
    if (affected.length === 0) {
      void applyFleetChanges([]);
      return;
    }
    setPendingRestart(
      affected.map((entry) => {
        const original = getOriginalProviderTier(rawFleets, entry.agentId);
        return {
          ...entry,
          liveCount: liveCounts[entry.agentId] ?? 0,
          activeTaskCount: (activeTasksByRoleMap[entry.agentId] || []).length,
          originalProvider: original.provider,
          originalTier: original.tier,
        };
      })
    );
  }, [
    hasPendingChanges,
    isUpdating,
    isApplying,
    changedFleets,
    rawFleets,
    draftProviderTiers,
    liveInstancesByRoleMap,
    activeTasksByRoleMap,
    applyFleetChanges,
  ]);

  const handleConfirmRestartNow = useCallback(() => {
    const affected = pendingRestart || [];
    setPendingRestart(null);
    void applyFleetChanges(affected);
  }, [pendingRestart, applyFleetChanges]);

  const handleApplyNewInstancesOnly = useCallback(() => {
    setPendingRestart(null);
    void applyFleetChanges([]);
  }, [applyFleetChanges]);

  const handleCancelRestart = useCallback(() => {
    setPendingRestart(null);
  }, []);

  // Available agent identities not yet in fleets
  const availableIdentitiesToAdd = useMemo(() => {
    const existing = new Set(fleets.map((f) => f.agent_id));
    return agentIdentities.filter(
      (a: any) => !existing.has(String(a.agent_id || a.agentId || a.id || ''))
    );
  }, [fleets, agentIdentities]);

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="fleet-management-drawer-backdrop"
      className="fixed inset-0 z-50 flex justify-end bg-surface-overlay/80 backdrop-blur-sm transition-opacity"
      onMouseDown={(e) => {
        backdropPressStartedRef.current = e.target === e.currentTarget;
      }}
      onClick={(e) => {
        if (backdropPressStartedRef.current && e.target === e.currentTarget) onClose();
      }}
    >
      <div
        data-debug-id="fleet-management-drawer"
        className="flex h-full w-full max-w-md flex-col bg-surface border-l border-subtle shadow-panel overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Drawer Header */}
        <div className="flex items-center justify-between border-b border-subtle px-4 py-3.5 bg-canvas/90">
          <div className="flex items-center gap-2">
            <Icon name="layers" size={18} className="text-accent" />
            <div>
              <h2 className="text-sm font-bold text-primary">Fleet Management</h2>
              <p className="text-[11px] text-muted">Concurrency quotas & live slots</p>
            </div>
          </div>
          <IconButton
            icon="close"
            label="Close drawer"
            size="sm"
            onClick={onClose}
          />
        </div>

        {errorMsg && (
          <div className="bg-danger-soft/30 border-b border-danger/30 px-4 py-2 text-xs text-danger">
            {errorMsg}
          </div>
        )}

        {/* Drawer Content. min-h-0 lets this region shrink below its intrinsic
            height so long role-card content scrolls instead of pushing the
            footer out of the viewport. */}
        <div className="flex-1 min-h-0 overflow-y-auto p-4 space-y-4">
          <div className="text-xs text-muted">
            Configure concurrency limits and provider/tier overrides per agent role. The scheduler JIT-provisions warm instances up to capacity when tasks become actionable.
          </div>

          <div className="space-y-3">
            {fleets.map((fleet) => {
              const agentId = fleet.agent_id;
              const roleName = formatFleetRoleName(agentId, agentIdentities);
              const effectiveCapacity = draftCapacities[agentId] ?? fleet.capacity ?? 1;
              const origCapacity = getOriginalCapacity(agentId);
              const activeCount = fleet.active_count ?? fleet.activeCount ?? 0;
              const isSaturated = activeCount >= effectiveCapacity;

              const origProviderTier = getOriginalProviderTier(rawFleets, agentId);
              const effectiveProvider = draftProviderTiers[agentId]?.provider ?? fleet.provider ?? '';
              const effectiveTier = draftProviderTiers[agentId]?.tier ?? fleet.tier ?? '';
              const capacityModified = origCapacity === null || effectiveCapacity !== origCapacity;
              const providerModified = effectiveProvider !== origProviderTier.provider;
              const tierModified = effectiveTier !== origProviderTier.tier;
              const isModified = capacityModified || providerModified || tierModified;
              const tierOptions = tierOptionsForProvider(bridgeCapabilities, effectiveProvider);

              const pendingParts: string[] = [];
              if (capacityModified) {
                pendingParts.push(`${origCapacity ?? 0} → ${effectiveCapacity}`);
              }
              if (providerModified) {
                pendingParts.push(`provider ${origProviderTier.provider || 'auto'} → ${effectiveProvider || 'auto'}`);
              }
              if (tierModified) {
                pendingParts.push(`tier ${origProviderTier.tier || 'auto'} → ${effectiveTier || 'auto'}`);
              }

              const liveInstances = liveInstancesByRoleMap[agentId] || [];
              const activeTasks = activeTasksByRoleMap[agentId] || [];

              return (
                <div
                  key={agentId}
                  data-debug-id={`fleet-drawer-role-card-${agentId}`}
                  className={`rounded-xl border p-3.5 space-y-3 transition-colors ${
                    isModified
                      ? 'border-warning/50 bg-warning-soft/10'
                      : 'border-subtle bg-surface-secondary/30'
                  }`}
                >
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <div className="grid h-8 w-8 place-items-center rounded-lg bg-accent/10 text-accent font-bold text-xs uppercase">
                        {roleName.slice(0, 2)}
                      </div>
                      <div>
                        <h4 className="text-xs font-bold text-primary flex items-center gap-1.5">
                          {roleName}
                          <span className="font-mono text-[10px] text-muted font-normal">({agentId})</span>
                        </h4>
                        <div className="flex items-center gap-1 text-[11px] text-muted font-mono mt-0.5">
                          <span className="text-accent">{renderSlotDots(activeCount, effectiveCapacity)}</span>
                          <span>{activeCount}/{effectiveCapacity} active</span>
                          {isModified && (
                            <span
                              data-debug-id={`fleet-staged-indicator-${agentId}`}
                              className="ml-1.5 rounded bg-warning-soft px-1.5 py-0.5 text-[10px] font-semibold text-warning"
                            >
                              Pending: {pendingParts.join(' · ')}
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                    <Badge tone={isSaturated ? 'warning' : 'neutral'}>
                      {isSaturated ? 'Saturated' : 'Available'}
                    </Badge>
                  </div>

                  {/* Inline +/- and Slider controls */}
                  <div className="rounded-lg border border-subtle bg-surface p-2.5 space-y-2">
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-medium text-primary">Capacity Limit</span>
                      <div className="flex items-center gap-1.5">
                        <button
                          type="button"
                          data-debug-id={`fleet-capacity-dec-${agentId}`}
                          onClick={() => handleDraftCapacityChange(agentId, Math.max(1, effectiveCapacity - 1))}
                          disabled={effectiveCapacity <= 1 || isUpdating || isApplying}
                          aria-label={`Decrease capacity for ${roleName}`}
                          className="h-6 w-6 rounded border border-subtle bg-surface-raised hover:bg-neutral-soft text-primary font-bold flex items-center justify-center disabled:opacity-40 cursor-pointer"
                        >
                          -
                        </button>
                        <span
                          data-debug-id={`fleet-capacity-val-${agentId}`}
                          className={`w-7 text-center font-mono font-bold text-xs ${
                            isModified ? 'text-warning font-black' : 'text-primary'
                          }`}
                        >
                          {effectiveCapacity}
                        </span>
                        <button
                          type="button"
                          data-debug-id={`fleet-capacity-inc-${agentId}`}
                          onClick={() => handleDraftCapacityChange(agentId, effectiveCapacity + 1)}
                          disabled={effectiveCapacity >= 20 || isUpdating || isApplying}
                          aria-label={`Increase capacity for ${roleName}`}
                          className="h-6 w-6 rounded border border-subtle bg-surface-raised hover:bg-neutral-soft text-primary font-bold flex items-center justify-center disabled:opacity-40 cursor-pointer"
                        >
                          +
                        </button>
                      </div>
                    </div>

                    <input
                      type="range"
                      min="1"
                      max="10"
                      value={effectiveCapacity}
                      data-debug-id={`fleet-capacity-slider-${agentId}`}
                      onChange={(e) => handleDraftCapacityChange(agentId, parseInt(e.target.value, 10))}
                      disabled={isUpdating || isApplying}
                      aria-label={`Capacity slider for ${roleName}`}
                      className="w-full h-1.5 bg-neutral-soft rounded-lg appearance-none cursor-pointer accent-accent"
                    />
                    <div className="flex justify-between text-[10px] text-muted">
                      <span>1 slot</span>
                      <span>5 slots</span>
                      <span>10 slots</span>
                    </div>
                  </div>

                  {/* Provider & Tier overrides (chains with a bridge directory only) */}
                  {Boolean(bridgeId) && (
                    <div
                      data-debug-id={`fleet-provider-tier-row-${agentId}`}
                      className="rounded-lg border border-subtle bg-surface p-2.5 space-y-2"
                    >
                      <div className="flex items-center justify-between">
                        <span className="text-xs font-medium text-primary">Provider &amp; Tier</span>
                        <span className="text-[10px] text-muted">Auto inherits the bridge defaults</span>
                      </div>
                      <div className="grid grid-cols-2 gap-2">
                        <div className="space-y-1">
                          <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">Provider</span>
                          <Select
                            data-debug-id={`fleet-provider-select-${agentId}`}
                            value={effectiveProvider}
                            onChange={(v) => handleDraftProviderChange(agentId, v)}
                            disabled={isUpdating || isApplying}
                            size="sm"
                            width="full"
                            aria-label={`Provider for ${roleName}`}
                            options={[
                              { value: '', label: 'Auto (inherit)' },
                              ...bridgeCapabilities.map((cap) => ({ value: cap.provider, label: cap.provider })),
                            ]}
                          />
                        </div>
                        <div className="space-y-1">
                          <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">Tier</span>
                          <Select
                            data-debug-id={`fleet-tier-select-${agentId}`}
                            value={effectiveTier}
                            onChange={(v) => handleDraftTierChange(agentId, v)}
                            disabled={effectiveProvider === '' || isUpdating || isApplying}
                            size="sm"
                            width="full"
                            aria-label={`Model tier for ${roleName}`}
                            options={[
                              { value: '', label: 'Auto (inherit)' },
                              ...tierOptions.map((tier) => ({ value: tier, label: tier })),
                            ]}
                          />
                        </div>
                      </div>
                    </div>
                  )}

                  {/* Live Instances */}
                  <div className="space-y-1">
                    <div className="flex items-center justify-between text-[11px] text-muted">
                      <span>Live Instances ({liveInstances.length})</span>
                      <span>Active Tasks ({activeTasks.length})</span>
                    </div>
                    {liveInstances.length === 0 ? (
                      <p className="text-[11px] text-faint italic py-0.5">No warm instances spawned yet.</p>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {liveInstances.map((inst) => {
                          const iid = String(inst.agentInstanceId || inst.agent_instance_id || '');
                          return (
                            <span
                              key={iid}
                              className="inline-flex items-center gap-1 rounded bg-surface px-1.5 py-0.5 text-[10px] font-mono border border-subtle text-primary"
                            >
                              <StatusDot size="sm" tone="success" label="Running" />
                              <span className="truncate max-w-[100px]">{inst.displayName || iid}</span>
                            </span>
                          );
                        })}
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Add Fleet Role if unconfigured roles exist */}
          {availableIdentitiesToAdd.length > 0 && (
            <div className="rounded-xl border border-dashed border-subtle p-3 space-y-2">
              <span className="text-xs font-semibold text-primary">Configure Another Agent Role</span>
              <div className="flex items-center gap-2">
                <Select
                  data-debug-id="fleet-drawer-add-role-select"
                  width="full"
                  value={selectedNewAgentId}
                  onChange={setSelectedNewAgentId}
                  options={[
                    { value: '', label: 'Select agent identity…' },
                    ...availableIdentitiesToAdd.map((a: any) => {
                      const id = String(a.agent_id || a.agentId || a.id || '');
                      const name = a.name || a.display_name || formatFleetRoleName(id, agentIdentities);
                      return { value: id, label: name };
                    }),
                  ]}
                />
                <button
                  type="button"
                  data-debug-id="fleet-drawer-add-role-btn"
                  disabled={!selectedNewAgentId || isUpdating || isApplying}
                  onClick={() => handleAddFleet(selectedNewAgentId)}
                  className="rounded bg-accent px-3 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90 disabled:opacity-40 cursor-pointer shrink-0"
                >
                  Add
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Drawer Footer with Batch Apply / Reset. shrink-0 keeps the controls
            pinned in view; the bottom padding lifts them above the persistent
            mobile tab bar / home-indicator safe area, and resolves to the plain
            0.75rem once --ui-bottom-chrome and the safe-area inset are 0. */}
        <div className="border-t border-subtle p-3 pb-[max(0.75rem,max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px)))] flex flex-wrap items-center justify-between gap-2.5 bg-canvas/90 shrink-0">
          {restartSummary &&
            (restartSummary.restartedByRole.length > 0 || restartSummary.failures.length > 0) && (
              <div
                data-debug-id="fleet-restart-summary"
                role="status"
                className="w-full space-y-1 rounded-lg border border-subtle bg-surface-secondary/40 px-3 py-2"
              >
                {restartSummary.restartedByRole.map((role) => (
                  <div key={role.agentId} className="flex items-center gap-1.5 text-xs text-success">
                    <span>✓</span>
                    <span>
                      {formatFleetRoleName(role.agentId, agentIdentities)}: restarted {role.count}{' '}
                      {role.count === 1 ? 'instance' : 'instances'}
                    </span>
                  </div>
                ))}
                {restartSummary.failures.map((failure, index) => (
                  <div
                    key={`${failure.instance_id}-${index}`}
                    data-debug-id="fleet-restart-failure"
                    className="text-xs text-warning"
                  >
                    {failure.instance_id}: {failure.message}
                  </div>
                ))}
              </div>
            )}
          <div className="text-xs text-muted">
            {hasPendingChanges ? (
              <span
                data-debug-id="fleet-drawer-pending-count"
                className="text-warning font-semibold flex items-center gap-1.5"
              >
                <span className="inline-block h-2 w-2 rounded-full bg-warning animate-pulse" />
                {changedFleets.length} {changedFleets.length === 1 ? 'role change' : 'role changes'} pending
              </span>
            ) : successMsg ? (
              <span className="text-success font-medium flex items-center gap-1">
                ✓ {successMsg}
              </span>
            ) : (
              <span className="text-faint">No pending changes</span>
            )}
          </div>
          <div className="flex items-center gap-2">
            {hasPendingChanges && (
              <button
                type="button"
                data-debug-id="fleet-drawer-reset-btn"
                onClick={handleReset}
                disabled={isUpdating || isApplying}
                className="rounded border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-muted hover:text-primary hover:bg-neutral-soft cursor-pointer transition-colors disabled:opacity-40"
              >
                Reset
              </button>
            )}
            <button
              type="button"
              data-debug-id="fleet-drawer-apply-btn"
              onClick={handleApply}
              disabled={!hasPendingChanges || isUpdating || isApplying}
              className="rounded bg-accent px-4 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90 cursor-pointer disabled:opacity-40 transition-opacity flex items-center gap-1.5"
            >
              {isApplying || isUpdating ? (
                <>
                  <span className="inline-block h-3 w-3 border-2 border-accent-fg border-t-transparent rounded-full animate-spin" />
                  Applying…
                </>
              ) : (
                'Apply'
              )}
            </button>
            <button
              type="button"
              data-debug-id="fleet-drawer-done-btn"
              onClick={onClose}
              className="rounded bg-neutral-soft px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised cursor-pointer"
            >
              Done
            </button>
          </div>
        </div>

        {/* Confirm-before-restart. Opens from Apply (before any PUT) only when a
            provider/tier edit would leave live instances on the old values. Mounted
            inside the panel so the drawer's backdrop click handler sees none of the
            portal's bubbled events; @ui Modal owns Esc / backdrop / focus return
            (the Apply button is the focus trigger). */}
        {pendingRestart && (
          <Modal
            open
            onOpenChange={(next) => {
              if (!next) setPendingRestart(null);
            }}
            title="Restart live instances?"
            size="md"
            data-debug-id="fleet-restart-confirm-modal"
          >
            <ModalBody>
              <Text role="body">
                Provider/tier changes only take effect for instances started after the change. These
                roles currently have live instances running with the old values:
              </Text>
              <ul className="mt-3 space-y-2">
                {pendingRestart.map((role) => {
                  const roleName = formatFleetRoleName(role.agentId, agentIdentities);
                  return (
                    <li
                      key={role.agentId}
                      data-debug-id={`fleet-restart-role-${role.agentId}`}
                      className="space-y-1 rounded-lg border border-subtle bg-surface-secondary/40 p-2.5"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-xs font-semibold text-primary">{roleName}</span>
                        <span className="font-mono text-[11px] text-muted">
                          {role.liveCount} live {role.liveCount === 1 ? 'instance' : 'instances'} ·{' '}
                          {role.activeTaskCount} active {role.activeTaskCount === 1 ? 'task' : 'tasks'}
                        </span>
                      </div>
                      <div className="font-mono text-[11px] text-muted">
                        provider {role.originalProvider || 'auto'} → {role.provider || 'auto'} · tier{' '}
                        {role.originalTier || 'auto'} → {role.tier || 'auto'}
                      </div>
                    </li>
                  );
                })}
              </ul>
              <Text role="body-sm" tone="warning" className="mt-3 block">
                Restarting interrupts in-progress agent runs — the active task count above is the
                interruption cost. "Apply to New Instances Only" leaves live instances untouched.
              </Text>
            </ModalBody>
            <ModalFooter>
              <Button
                variant="secondary"
                data-debug-id="fleet-restart-cancel-btn"
                onClick={handleCancelRestart}
              >
                Cancel
              </Button>
              <Button
                variant="secondary"
                data-debug-id="fleet-restart-new-only-btn"
                onClick={handleApplyNewInstancesOnly}
              >
                Apply to New Instances Only
              </Button>
              <Button
                variant="primary"
                data-debug-id="fleet-restart-now-btn"
                onClick={handleConfirmRestartNow}
              >
                Apply &amp; Restart Now
              </Button>
            </ModalFooter>
          </Modal>
        )}
      </div>
    </div>
  );
};
