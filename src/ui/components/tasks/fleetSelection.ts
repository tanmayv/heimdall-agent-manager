// Fleet provider/tier selection logic (REQ-FLEET-PT-3).
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
