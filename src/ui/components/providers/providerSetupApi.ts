import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import type { RuntimeTransport, ProviderSetupCommand } from './providerRuntime';
export type { RuntimeTransport, AcpAdapterStatus } from './providerRuntime';


export type DiscoveryState = 'idle' | 'running' | 'complete' | 'failed';
export type DetectionState = 'absent' | 'present';
export type ProviderTestRunState = 'starting' | 'detecting' | 'awaiting_validation' | 'stopping' | 'stopped' | 'failed' | 'cancelled' | 'expired';

export type { ProviderModelStatus, ProviderStatusRow as BridgeProviderStatus } from '../../api/endpoints/bridgeSupport';
import { normalizeProviderStatus, readBridgeProviderStatus, invalidateBridgeProviderStatus, type ProviderStatusRow as BridgeProviderStatus } from '../../api/endpoints/bridgeSupport';
export interface ProviderSetupResponse {
  bridge: { bridge_id: string; label: string; machine_hostname: string; status: 'online' | 'offline' };
  discovery: { state: DiscoveryState; requested_at: string | null; completed_at: string | null };
  providers: BridgeProviderStatus[];
  acp_runtime_supported?: boolean;
  extension_commands?: ProviderSetupCommand[];
}
export interface ProviderTestRunResponse {
  run_id: string; agent_instance_id: string; bridge_id: string; provider: string; model: string;
  state: ProviderTestRunState; expires_at: string; error: string | null;
}

/** The bridge's row from the shared bridge-list cache (label, hostname, status). */
async function bridgeDetails(bridgeId: string) {
  // Keep the shared endpoint dependency lazy for bootstrap callers.
  const { readBridgeRows } = await import('../../api/endpoints/bridgeSupport');
  const bridges = await readBridgeRows();
  return bridges.find((bridge: any) => String(bridge?.bridge_id || bridge?.id || '') === bridgeId) || {};
}

export const providerSetupApi = {
  async get(bridgeId: string, includeProfiles = false, fresh = false): Promise<ProviderSetupResponse> {
    if (!bridgeId) throw new Error('Bridge id is required.');
    const [status, bridge] = await Promise.all([
      readBridgeProviderStatus(bridgeId, { fresh }), bridgeDetails(bridgeId),
    ]);
    return {
      bridge: { bridge_id: bridgeId, label: String(bridge?.label || bridge?.machine_hostname || bridgeId),
        machine_hostname: String(bridge?.machine_hostname || ''),
        status: String(bridge?.status || '').toLowerCase() === 'online' ? 'online' : 'offline' },
      discovery: { state: 'idle', requested_at: null, completed_at: null },
      acp_runtime_supported: status?.acp_runtime_supported === true,
      extension_commands: Array.isArray(status?.extension_commands) ? status.extension_commands : [],
      providers: (Array.isArray(status?.providers) ? status.providers : []).filter((p: any) => includeProfiles || !p.profile_id || p.profile_id === p.provider),
    };
  },
  async discover(current: ProviderSetupResponse): Promise<ProviderSetupResponse> {
    const requestedAt = new Date().toISOString();
    const status = await discoverBridgeProviders(current.bridge.bridge_id, 'providers');
    return { ...current, discovery: { state: 'complete', requested_at: requestedAt, completed_at: new Date().toISOString() },
      providers: (Array.isArray(status?.providers) ? status.providers : []).filter((p: any) => !p.profile_id || p.profile_id === p.provider) };
  },
  /**
   * Explicit re-detection of one provider on the bridge (binary, version, Node.js,
   * npm, ACP runtime), then a fresh read. Offline bridges can only be re-read.
   */
  async redetect(current: ProviderSetupResponse, provider: string): Promise<ProviderSetupResponse> {
    if (current.bridge.status === 'online') await discoverBridgeProviders(current.bridge.bridge_id, 'providers', true, [provider]);
    return providerSetupApi.get(current.bridge.bridge_id, true, true);
  },
  /** Explicit second stage. Hub derives the present + enabled provider filter. */
  async refreshModels(current: ProviderSetupResponse): Promise<ProviderSetupResponse> {
    const status = await discoverBridgeProviders(current.bridge.bridge_id, 'models');
    return { ...current, providers: (Array.isArray(status?.providers) ? status.providers : []).filter((p: any) => !p.profile_id || p.profile_id === p.provider) };
  },
  async setEnabled(current: ProviderSetupResponse, provider: string, enabled: boolean, profileId?: string): Promise<ProviderSetupResponse> {
    await cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/providers/${encodeURIComponent(provider)}`, 'PUT', { enabled, ...(profileId ? { profile_id: profileId } : {}) });
    invalidateBridgeProviderStatus(current.bridge.bridge_id);
    return { ...current, providers: current.providers.map((entry) => entry.provider === provider && (entry.profile_id || entry.provider) === (profileId || provider) ? { ...entry, enabled } : entry) };
  },
  async setTransport(current: ProviderSetupResponse, provider: string, transport: RuntimeTransport | null): Promise<ProviderSetupResponse> {
    await cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/providers/${encodeURIComponent(provider)}`, 'PUT', { transport });
    invalidateBridgeProviderStatus(current.bridge.bridge_id);
    return providerSetupApi.get(current.bridge.bridge_id, true, true);
  },
  async installAdapter(current: ProviderSetupResponse, provider: string): Promise<{ command_id: string }> {
    return cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/providers/${encodeURIComponent(provider)}/acp-adapter`, 'POST', { action: 'install' });
  },
  async startTestRun(current: ProviderSetupResponse, provider: string, model: string, profileId?: string): Promise<ProviderTestRunResponse> {
    return cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/provider-tests`, 'POST', { provider, model, ...(profileId ? { profile_id: profileId } : {}) });
  },
  async getTestRun(runId: string): Promise<ProviderTestRunResponse> {
    return cookieJsonFetch(`/provider-tests/${encodeURIComponent(runId)}`);
  },
  async validateTestRun(runId: string): Promise<ProviderTestRunResponse> {
    return cookieMutation(`/provider-tests/${encodeURIComponent(runId)}/validate`, 'POST', {});
  },
  async cancelTestRun(runId: string): Promise<void> {
    await cookieMutation(`/provider-tests/${encodeURIComponent(runId)}`, 'DELETE');
  },
};

/** Only user Refresh actions call this; neither stage is retried automatically. */
export async function refreshBridgeProviderCatalog(bridgeId: string): Promise<any> {
  await discoverBridgeProviders(bridgeId, 'providers', false);
  return discoverBridgeProviders(bridgeId, 'models', false);
}

/**
 * Explicit, awaited discovery stage. A status read never waits on a probe; the
 * Hub itself asks the bridge to re-detect a stale ACP report in the background
 * (G5), and the next read shows the result.
 */
export async function discoverBridgeProviders(bridgeId: string, stage: 'providers' | 'models', invalidate = true, providers?: string[]) {
  const raw = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/discover`, 'POST', providers?.length ? { stage, providers } : { stage });
  if (invalidate) invalidateBridgeProviderStatus(bridgeId);
  return normalizeProviderStatus(raw, bridgeId);
}
