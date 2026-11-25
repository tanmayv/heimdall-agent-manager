import type { FleetApplyInput, FleetRuntime, FleetSettings } from '../../api/endpoints/bridgeFleet';
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
