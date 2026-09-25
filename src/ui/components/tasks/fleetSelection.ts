// Fleet provider/tier selection logic (REQ-FLEET-PT-3) and the restart-confirmation
// decision that guards it (REQ-RS-3 / REQ-RS-4).
//
// DELIBERATELY DEPENDENCY-FREE leaf module (following repository conventions, see
// src/ui/search/scopedSearchLogic.ts) so `node --test` can exercise the Fleet
// Management drawer's provider/tier draft + change-detection logic directly,
// without a bundler or DOM. FleetManagementDrawer.tsx consumes these helpers.
//
// Semantics: provider/tier are per-fleet-role strings where '' means "inherit"
// (the bridge/agent defaults), matching the hub contract where fleet JSON always
// carries both fields and PUT /task-chains/:id/fleets/:agentId accepts them.

export interface FleetProviderTier {
  provider: string;
  tier: string;
}

export interface FleetProviderCapability {
  provider: string;
  tiers: string[];
  defaultTier?: string;
}

/**
 * Provider/tier options from a bridge providers payload. The live
 * GET /bridges/:id/providers response carries full profiles
 * ({name, enabled, models:{flag,cheap,normal,smart}}) with tiers expressed
 * implicitly by non-empty model slots (the same derivation the bridge itself
 * uses in its capability report, src/bridge/provider_store.odin
 * bridge_provider_capabilities_json); the capability-report/mock shape carries
 * them explicitly ({provider, tiers, default_tier}). Both are accepted.
 */
export function fleetProviderCapabilities(providersPayload: any): FleetProviderCapability[] {
  const source = Array.isArray(providersPayload?.providers) ? providersPayload.providers : [];
  const list: FleetProviderCapability[] = [];
  for (const entry of source) {
    if (entry === null || typeof entry !== 'object') continue;
    if (entry.enabled === false) continue;
    const provider = String(entry.provider || entry.name || '');
    if (!provider) continue;
    let tiers: string[];
    if (Array.isArray(entry.tiers)) {
      tiers = entry.tiers.map((t: any) => String(t)).filter(Boolean);
    } else {
      const models = entry.models && typeof entry.models === 'object' ? entry.models : {};
      tiers = ['cheap', 'normal', 'smart'].filter((tier) => Boolean(models[tier]));
    }
    const defaultTier = String(entry.default_tier || entry.defaultTier || '');
    list.push({ provider, tiers, defaultTier: defaultTier || undefined });
  }
  return list;
}

export interface ChangedFleetEntry {
  agentId: string;
  capacity: number;
  provider: string;
  tier: string;
}

function fleetAgentId(f: any): string {
  return String(f?.agent_id || f?.agentId || '');
}

function fleetProviderTier(f: any): FleetProviderTier {
  return { provider: String(f?.provider || ''), tier: String(f?.tier || '') };
}

/** Draft provider/tier per role, seeded from server-returned fleets ('' = inherit). */
export function seedProviderTierDrafts(fleets: any[]): Record<string, FleetProviderTier> {
  const init: Record<string, FleetProviderTier> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    init[aid] = fleetProviderTier(f);
  }
  return init;
}

/** Server/original provider+tier for a role; roles without a persisted row inherit ''/''. */
export function getOriginalProviderTier(fleets: any[], agentId: string): FleetProviderTier {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  return found ? fleetProviderTier(found) : { provider: '', tier: '' };
}

/** Tier options offered by the selected provider; '' (Auto) provider has none. */
export function tierOptionsForProvider(capabilities: FleetProviderCapability[], provider: string): string[] {
  if (!provider) return [];
  const cap = (capabilities || []).find((c) => c && c.provider === provider);
  return cap ? (cap.tiers || []).slice() : [];
}

/**
 * Tier to keep when a role's provider changes: a tier the new provider does not
 * offer would yield a provider/tier pair the bridge can never launch, so it
 * falls back to '' (Auto).
 */
export function nextTierOnProviderChange(
  currentTier: string,
  nextProvider: string,
  capabilities: FleetProviderCapability[],
): string {
  if (!nextProvider) return '';
  return tierOptionsForProvider(capabilities, nextProvider).includes(currentTier) ? currentTier : '';
}

/** Server/original capacity for a role; null = role not persisted and not a standard role. */
export function getOriginalFleetCapacity(fleets: any[], agentId: string): number | null {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  if (found) return typeof found.capacity === 'number' ? found.capacity : 1;
  if (agentId === 'agt_worker' || agentId === 'agt_reviewer') return 1;
  return null;
}

/**
 * Roles whose drafts diverge from the server state (or that are newly staged):
 * the exact entries the drawer's Apply button turns into fleet PUTs. A role
 * counts as changed when its capacity differs, its provider/tier differs, or it
 * is a not-yet-persisted role with any non-inherit value staged.
 */
export function changedFleetEntries(
  fleets: any[],
  draftCapacities: Record<string, number>,
  draftProviderTiers: Record<string, FleetProviderTier>,
  rawFleets: any[],
): ChangedFleetEntry[] {
  const list: ChangedFleetEntry[] = [];
  for (const fleet of fleets || []) {
    const aid = fleetAgentId(fleet);
    if (!aid) continue;
    const draftCapacity = draftCapacities[aid];
    const draftPT = draftProviderTiers[aid];
    // Roles with neither draft are untouched (an unpersisted standard role has
    // no seeded drafts, so it must stay out until the user stages something).
    if (draftCapacity === undefined && draftPT === undefined) continue;
    const effectiveCapacity =
      draftCapacity !== undefined ? draftCapacity : (typeof fleet.capacity === 'number' ? fleet.capacity : 1);
    const origCapacity = getOriginalFleetCapacity(rawFleets, aid);
    const origPT = getOriginalProviderTier(rawFleets, aid);
    const capacityChanged = origCapacity === null || effectiveCapacity !== origCapacity;
    const providerChanged = draftPT !== undefined && draftPT.provider !== origPT.provider;
    const tierChanged = draftPT !== undefined && draftPT.tier !== origPT.tier;
    if (capacityChanged || providerChanged || tierChanged) {
      list.push({
        agentId: aid,
        capacity: effectiveCapacity,
        provider: draftPT ? draftPT.provider : origPT.provider,
        tier: draftPT ? draftPT.tier : origPT.tier,
      });
    }
  }
  return list;
}

// ---------------------------------------------------------------------------
// Restart confirmation (REQ-RS-3 / REQ-RS-4)
//
// A provider/tier edit only takes effect for instances launched AFTER the change;
// live instances keep the old values until they restart. The drawer therefore asks
// the user, before any PUT, whether the affected roles' live instances should be
// relaunched now (the hub's PUT restart_live_instances flag) — and the decision of
// WHICH roles are affected is pure and lives here so `node --test` can drive it.
// ---------------------------------------------------------------------------

export interface FleetRestartFailure {
  instance_id: string;
  message: string;
}

/** A live fleet member: every runtime status except the three terminal ones. */
export function isLiveFleetMember(member: any): boolean {
  const status = String(member?.runtimeStatus || member?.runtime_status || '').toLowerCase();
  return status !== 'stopped' && status !== 'failed' && status !== 'terminated';
}

/** Live members grouped by role (agent_id), preserving member order. */
export function liveInstancesByRole(members: any[]): Record<string, any[]> {
  const map: Record<string, any[]> = {};
  for (const m of members || []) {
    const aid = fleetAgentId(m);
    if (!aid || !isLiveFleetMember(m)) continue;
    (map[aid] || (map[aid] = [])).push(m);
  }
  return map;
}

const ACTIVE_TASK_STATUSES = ['in_progress', 'in_validation', 'queued'];

/**
 * Tasks still occupying a role's fleet, grouped by role (agent_id). Mirrors the
 * drawer's per-role predicate: a task matches its assignee role and, when bound to
 * a member instance, that instance's role too — so it can count for both.
 */
export function activeTasksByRole(tasks: any[], members: any[]): Record<string, any[]> {
  const roleByInstanceId: Record<string, string> = {};
  for (const m of members || []) {
    const aid = fleetAgentId(m);
    const iid = String(m?.agentInstanceId || m?.agent_instance_id || '');
    if (aid && iid) roleByInstanceId[iid] = aid;
  }
  const map: Record<string, any[]> = {};
  for (const t of tasks || []) {
    const status = String(t?.status || '').toLowerCase();
    if (!ACTIVE_TASK_STATUSES.includes(status)) continue;
    const assigneeAid = String(t?.assigneeRef?.agent_id || t?.assigneeRef?.agentId || '');
    const instanceAid = t?.assigneeAgentInstanceId
      ? roleByInstanceId[String(t.assigneeAgentInstanceId)] || ''
      : '';
    for (const aid of new Set([assigneeAid, instanceAid])) {
      if (!aid) continue;
      (map[aid] || (map[aid] = [])).push(t);
    }
  }
  return map;
}

/** True when a role's staged provider/tier diverges from its persisted values. */
export function providerTierModified(
  rawFleets: any[],
  agentId: string,
  draftProviderTiers: Record<string, FleetProviderTier>,
): boolean {
  const draft = draftProviderTiers[agentId];
  if (!draft) return false;
  const orig = getOriginalProviderTier(rawFleets, agentId);
  return draft.provider !== orig.provider || draft.tier !== orig.tier;
}

/**
 * The changed roles a restart decision applies to: provider/tier changed AND the
 * role currently has at least one live instance. Capacity-only edits never restart.
 */
export function restartAffectedEntries(
  changedEntries: ChangedFleetEntry[],
  rawFleets: any[],
  draftProviderTiers: Record<string, FleetProviderTier>,
  liveInstanceCounts: Record<string, number>,
): ChangedFleetEntry[] {
  return (changedEntries || []).filter(
    (entry) =>
      providerTierModified(rawFleets, entry.agentId, draftProviderTiers) &&
      (liveInstanceCounts[entry.agentId] || 0) >= 1,
  );
}

export interface FleetApplyRequest {
  agentId: string;
  capacity: number;
  provider: string;
  tier: string;
  /** Present (true) only on the PUTs that must relaunch live role instances. */
  restartLiveInstances?: true;
}

/**
 * The PUT payloads for an Apply, one per changed role, in changedFleets order.
 * `restartAffected` empty = "Apply to New Instances Only": every payload then
 * carries no flag key at all, i.e. today's request shape byte-for-byte.
 */
export function fleetApplyRequests(
  changedEntries: ChangedFleetEntry[],
  restartAffected: ChangedFleetEntry[],
): FleetApplyRequest[] {
  const restartIds = new Set((restartAffected || []).map((entry) => entry.agentId));
  return (changedEntries || []).map((entry) => {
    const request: FleetApplyRequest = {
      agentId: entry.agentId,
      capacity: entry.capacity,
      provider: entry.provider,
      tier: entry.tier,
    };
    if (restartIds.has(entry.agentId)) request.restartLiveInstances = true;
    return request;
  });
}

export interface FleetRestartRoleResult {
  agentId: string;
  restarted_instance_ids?: string[];
  restart_failures?: FleetRestartFailure[];
}

export interface FleetRestartSummary {
  restartedByRole: { agentId: string; count: number }[];
  failures: FleetRestartFailure[];
}

/**
 * Collapse the flagged PUT responses into the Apply summary. A role's
 * restarted_instance_ids is counted only when the server sent it (it is present
 * exactly on the flagged PUTs); failures are flattened verbatim.
 */
export function summarizeFleetRestartResults(results: FleetRestartRoleResult[]): FleetRestartSummary {
  const restartedByRole: { agentId: string; count: number }[] = [];
  const failures: FleetRestartFailure[] = [];
  for (const result of results || []) {
    if (!result) continue;
    if (Array.isArray(result.restarted_instance_ids)) {
      restartedByRole.push({ agentId: result.agentId, count: result.restarted_instance_ids.length });
    }
    for (const failure of result.restart_failures || []) {
      failures.push({
        instance_id: String(failure?.instance_id || ''),
        message: String(failure?.message || ''),
      });
    }
  }
  return { restartedByRole, failures };
}
