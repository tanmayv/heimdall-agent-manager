import type { FleetApplication, FleetApplyInput, FleetRuntime, FleetSettings } from '../../api/endpoints/bridgeFleet';
import type { FleetProviderCapability } from '../tasks/fleetSelection';

export function runtimeKey(runtime: FleetRuntime): string {
  return JSON.stringify([runtime.provider, runtime.provider_profile || runtime.provider, runtime.model]);
}
export function fleetDraftKey(draft: Pick<FleetSettings, 'default_runtime' | 'overrides'>): string {
  return JSON.stringify([runtimeKey(draft.default_runtime), draft.overrides.map((o) => [o.agent_id, runtimeKey(o.runtime)]).sort((a, b) => a[0].localeCompare(b[0]))]);
}
export function catalogRuntime(capability?: FleetProviderCapability): FleetRuntime {
  return { provider: capability?.provider || '', provider_profile: capability?.profile_id || capability?.provider || '', model: capability?.models[0] || '' };
}
export function initialFleetDraft(settings: FleetSettings, catalog: FleetProviderCapability[]): FleetSettings {
  return settings.revision || settings.default_runtime.provider ? settings : { ...settings, default_runtime: catalogRuntime(catalog.find((c) => c.models.length)) };
}
export function validFleetDraft(draft: FleetSettings, catalog: FleetProviderCapability[]): boolean {
  const valid = (r: FleetRuntime) => catalog.some((c) => c.provider === r.provider && (c.profile_id || c.provider) === (r.provider_profile || r.provider) && c.models.includes(r.model));
  return valid(draft.default_runtime) && draft.overrides.every((o) => !!o.agent_id && valid(o.runtime)) && new Set(draft.overrides.map((o) => o.agent_id)).size === draft.overrides.length;
}
export function fleetApplyInput(draft: FleetSettings, requestId: string): FleetApplyInput {
  return { request_id: requestId, expected_revision: draft.revision, default_runtime: draft.default_runtime, overrides: draft.overrides };
}
export function fleetFocusHref(bridgeId = '', agentId = ''): string {
  const search = new URLSearchParams({ widget: 'fleet' });
  if (bridgeId) search.set('bridge', bridgeId);
  if (agentId) search.set('agent', agentId);
  return `#/?${search}`;
}

export type FleetSettingsSnapshot = Pick<FleetSettings, 'revision' | 'default_runtime' | 'overrides'>;
export interface FleetExcludedCounts {
  unchanged: number; notRunning: number; other: number;
  /** 'applied': compared with the settings revision the application saved; 'current': that revision is not loaded, so compared with current settings. */
  basis: 'applied' | 'current';
  /** Revision of the settings the counts were compared against. */
  revision: number;
}

/**
 * A bounded client view, not historical server outcomes or eligibility decisions.
 * Instances are compared with the settings revision the application saved: the
 * snapshot recorded at Apply time, or the loaded settings when they are still at
 * that revision. Otherwise the counts fall back to current settings, labelled so.
 */
export function fleetExcludedCounts(
  instances: { agent_instance_id: string; bridge_id: string; agent_id: string; runtime_status: string; provider: string; provider_profile?: string; model: string }[],
  settings: FleetSettingsSnapshot,
  application: FleetApplication,
  appliedSettings?: FleetSettingsSnapshot,
): FleetExcludedCounts {
  const applied = [appliedSettings, settings].find((candidate) => !!candidate && !!application.settings_revision && candidate.revision === application.settings_revision);
  const basisSettings = applied || settings;
  const targets = new Set(application.targets.map((target) => target.agent_instance_id));
  const seen = new Set<string>();
  const counts: FleetExcludedCounts = { unchanged: 0, notRunning: 0, other: 0, basis: applied ? 'applied' : 'current', revision: basisSettings.revision };
  for (const instance of instances) {
    if (!instance.agent_instance_id || instance.bridge_id !== application.bridge_id || targets.has(instance.agent_instance_id) || seen.has(instance.agent_instance_id)) continue;
    seen.add(instance.agent_instance_id);
    if (instance.runtime_status !== 'running') { counts.notRunning += 1; continue; }
    const desired = basisSettings.overrides.find((override) => override.agent_id === instance.agent_id)?.runtime || basisSettings.default_runtime;
    if (runtimeKey({ provider: instance.provider, provider_profile: instance.provider_profile || instance.provider, model: instance.model }) === runtimeKey(desired)) counts.unchanged += 1;
    else counts.other += 1;
  }
  return counts;
}
