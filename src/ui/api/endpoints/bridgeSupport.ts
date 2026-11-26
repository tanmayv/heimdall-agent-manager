import { normalizeProviderExtension, type ProviderExtensionStatus } from '../../components/extension/extensionBadgeModel';
import { normalizeModelCatalog, type ModelCatalogMetadata } from '../../components/providers/modelCatalogStatus';
import { normalizeProviderRuntime, type ProviderRuntimeFields } from '../../components/providers/providerRuntime';
import * as daemonApi from '../daemonApi';
import { heimdallApi, heimdallApiDispatch, withSessionQuery } from '../heimdallApi';
import { profileLabel } from '../../components/providers/providerProfiles';
import { useMemo } from 'react';
import { ApiError, cookieJsonFetch, cookieMutation, customQueryError } from '../cookieFetch';
import { type ExtensionCommandKind, type ProviderExtensionCommand, isExtensionInstallTerminal } from '../../components/extension/extensionInstallModel';

export type AgentBridgeSupportEntry = {
  bridgeId: string;
  enabled: boolean;
  providerProfile?: string;
  model?: string;
  priority?: number;
  maxInstances?: number;
};

export interface BridgeUpdateChoice {
  version: string;
  prerelease: boolean;
  downgrade: boolean;
  artifact_available: boolean;
}

export interface Bridge {
  bridge_id?: string;
  bridgeId?: string;
  id?: string;
  label?: string;
  machine_hostname?: string;
  hostname?: string;
  machine_os?: string;
  os?: string;
  machine_arch?: string;
  arch?: string;
  status?: string;
  runtime_status?: string;
  runtime_connected?: boolean;
  version?: string;
  commit_sha?: string;
  build_timestamp?: string;
  target?: string;
  update_available?: boolean;
  update_choices?: BridgeUpdateChoice[];
  /** REQ-T13-2: false when the latest release ships no bundle for `target` (e.g. termux-arm64). */
  update_artifact_available?: boolean;
  latest_version?: string;
  latest_source?: 'promoted' | 'override' | 'manifest';
  update_warning?: string;
  update_fallback_reason?: string;
  latest_commit_sha?: string;
  update_status?: 'idle' | 'downloading' | 'validating' | 'restarting' | 'healthy' | 'complete' | 'failed' | string;
  update_message?: string;
  update_progress?: number;
  update_error?: string;
  active_instance_count?: number;
  instance_count?: number;
  instances?: any[];
  capabilities?: any[] | BridgeCapability[];
  provider_capabilities?: any[];
  provider_profiles?: any[];
  last_seen_at?: string;
  updated_at?: string;
  revoked_at?: string;
  /** Hub-owned plan suspension; existing agents are retained. */
  plan_disabled_at?: string;
  telemetry_enabled?: 'inherit' | 'enabled' | 'disabled' | string;
  public_key?: string;
  bridge_public_key?: string;
  /**
   * REQ-BVS-2/REQ-BVS-3: the vault state this bridge last reported, serialized
   * verbatim by the hub — `"disabled" | "locked" | "unlocked"`, or `""` when the
   * bridge has never reported one (older builds). Never infer "unlocked" from an
   * absent value; see `utils/bridgeVaultStatus.ts` for the derivation.
   */
  vault_status?: string;
}

/** One row of GET /api/v1/bridges/{id}/events. `fields` values are enum names or ints. */
export interface BridgeEvent {
  id: number;
  ts_ms: number;
  received_at: number;
  level: 'warn' | 'error' | string;
  code: string;
  fields: Record<string, string | number>;
  count: number;
  message: string;
}

export interface BridgeEventsPage {
  bridge_id: string;
  events: BridgeEvent[];
  has_more: boolean;
  next_before_id: number;
}

export function normalizeBridgeEventsPage(raw: any): BridgeEventsPage {
  const events = Array.isArray(raw?.events) ? raw.events : [];
  return {
    bridge_id: String(raw?.bridge_id || ''),
    events: events.map((e: any) => ({
      id: Number(e?.id || 0),
      ts_ms: Number(e?.ts_ms || 0),
      received_at: Number(e?.received_at || 0),
      level: String(e?.level || 'warn'),
      code: String(e?.code || 'other'),
      fields: e?.fields && typeof e.fields === 'object' ? e.fields : {},
      count: Math.max(1, Number(e?.count || 1)),
      message: String(e?.message || e?.code || ''),
    })),
    has_more: Boolean(raw?.has_more),
    next_before_id: Number(raw?.next_before_id || 0),
  };
}

export type BridgeCapability = Partial<ProviderRuntimeFields> & {
  provider: string;
  profile_id?: string; label?: string; accent?: string;
  models: string[];
};

/**
 * Mirrors contracts.ACP_Availability (src/contracts/runtime_transport.odin): the
 * Hub's computed ACP verdict for this bridge + provider. Render it; never
 * re-derive it from acp_runtime_supported / acp_adapter.
 */
export type AcpAvailabilityReason = 'ready' | 'no_recipe' | 'unsupported_bridge' | 'adapter_missing' | 'adapter_outdated'
  | 'adapter_missing_node' | 'adapter_error' | 'installing' | 'not_checked';
export type AcpAvailabilityFix = 'update_bridge' | 'install_adapter' | 'check_now';
export interface AcpAvailability { available: boolean; reason: AcpAvailabilityReason; fix: AcpAvailabilityFix | null }
const acpAvailabilityReasons = new Set<string>(['ready', 'no_recipe', 'unsupported_bridge', 'adapter_missing', 'adapter_outdated',
  'adapter_missing_node', 'adapter_error', 'installing', 'not_checked']);
const acpAvailabilityFixes = new Set<string>(['update_bridge', 'install_adapter', 'check_now']);
/** null when the Hub predates the verdict or sends an unknown reason. */
export function normalizeAcpAvailability(raw: any): AcpAvailability | null {
  if (!raw || typeof raw !== 'object' || !acpAvailabilityReasons.has(raw.reason)) return null;
  return {
    available: raw.available === true && raw.reason === 'ready',
    reason: raw.reason as AcpAvailabilityReason,
    fix: acpAvailabilityFixes.has(raw.fix) ? raw.fix as AcpAvailabilityFix : null,
  };
}

export interface ProviderModelStatus { model_id: string; label: string; state: string; resolved_model?: string }
export interface ProviderStatusRow extends ModelCatalogMetadata, ProviderRuntimeFields {
  profile_id?: string; label?: string; label_enc?: string; accent?: string; profile_state?: string;
  provider: 'claude' | 'codex' | 'copilot' | 'antigravity' | 'pi' | 'kiro' | 'opencode';
  display_name: string; icon_url: string; catalog_state: string;
  state: 'absent' | 'present'; binary_path: string; version_text: string; checked_at: string | null;
  enabled: boolean; models: ProviderModelStatus[];
  /** REQ-EXT-DET-1/2: the bridge's probe of the provider's Heimdall extension; null = provider has none. */
  extension: ProviderExtensionStatus | null;
  /** T2: Hub-computed ACP verdict for this bridge + provider; null from an older Hub. */
  acp_availability: AcpAvailability | null;
}
function normalizeProviderStatusRow(raw: any): ProviderStatusRow {
  return {
    ...raw,
    provider: String(raw?.provider || '') as ProviderStatusRow['provider'],
    profile_id: String(raw?.profile_id || raw?.provider || ''), label_enc: String(raw?.label_enc || ''), accent: String(raw?.accent || ''), profile_state: String(raw?.profile_state || ''),
    display_name: String(raw?.display_name || raw?.provider || ''), icon_url: String(raw?.icon_url || ''),
    catalog_state: String(raw?.catalog_state || ''),
    state: raw?.state === 'present' ? 'present' : 'absent', binary_path: String(raw?.binary_path || ''),
    version_text: String(raw?.version_text || ''), checked_at: raw?.checked_at ? String(raw.checked_at) : null,
    enabled: Boolean(raw?.enabled),
    ...normalizeProviderRuntime(raw),
    ...normalizeModelCatalog(raw),
    extension: normalizeProviderExtension(raw?.extension),
    acp_availability: normalizeAcpAvailability(raw?.acp_availability),
    models: Array.isArray(raw?.models) ? raw.models.map((model: any) => ({
      ...model,
      model_id: String(model?.model_id || ''), label: String(model?.label || model?.model_id || ''),
      state: String(model?.state || ''),
      resolved_model: model?.resolved_model ? String(model.resolved_model) : undefined,
    })) : [],
  };
}


/** Preserve every status row and model; launch filtering happens only in selectors. */
export async function normalizeProviderStatus(raw: any, bridgeId = '') {
  const providers = await Promise.all((Array.isArray(raw?.providers) ? raw.providers : []).map(async (entry: any) => ({
    ...normalizeProviderStatusRow(entry),
    label: await profileLabel(entry, entry.profile_id === entry.provider || !entry.profile_id ? entry.display_name : ''),
  })));
  return { ...raw, bridge_id: String(raw?.bridge_id || bridgeId), providers };
}

export function selectLaunchableProviderCapabilities(status: any): BridgeCapability[] {
  return (Array.isArray(status?.providers) ? status.providers : [])
    .filter((entry: any) => entry.enabled === true && entry.state === 'present' && entry.catalog_state === 'active')
    .map((entry: any) => ({
      ...entry,
      models: (Array.isArray(entry.models) ? entry.models : [])
        .filter((model: any) => model.state === 'active')
        .map((model: any) => String(model.model_id || '')).filter(Boolean),
    })).filter((entry: any) => Boolean(entry.provider));
}

/** The caller already scopes status to one bridge. */
export function selectBridgeProvider(status: any, provider: string, profileId?: string) {
  return status?.providers?.find((entry: any) =>
    entry.provider === provider && (entry.profile_id || entry.provider) === (profileId || provider));
}

export function invalidateBridgeProviderStatus(bridgeId: string) {
  heimdallApiDispatch()?.(heimdallApi.util.invalidateTags([{ type: 'BridgeProviders', id: bridgeId }]));
}

export async function readBridgeProviderStatus(bridgeId: string, options: { fresh?: boolean } = {}) {
  const dispatch = heimdallApiDispatch();
  if (!dispatch) return normalizeProviderStatus(await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/provider-status`), bridgeId);
  const request = dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId }, { forceRefetch: Boolean(options.fresh) }));
  try {
    return await request.unwrap();
  } catch (error: any) {
    if (error?.status === 'CUSTOM_ERROR') throw new ApiError(error.error, error.originalStatus, error.code, undefined, undefined, error.details);
    throw error;
  } finally {
    request.unsubscribe();
  }
}

export function normalizeBridgeCapabilities(raw: any): BridgeCapability[] {
  if (Array.isArray(raw?.providers)) return selectLaunchableProviderCapabilities(raw);
  const caps = raw?.capabilities || raw?.capability_report || raw?.provider_capabilities || raw || [];
  const source = Array.isArray(caps)
    ? caps
    : Array.isArray(caps?.providers)
      ? caps.providers
      : Array.isArray(caps?.provider_profiles)
        ? caps.provider_profiles
        : [];
  return source.map((entry: any) => {
    if (typeof entry === 'string') return { provider: entry, models: [] };
    const models = Array.isArray(entry?.models) ? entry.models.map((model: any) => String(model)).filter(Boolean) : [];
    return { provider: String(entry?.provider || entry?.name || ''), models, ...normalizeProviderRuntime(entry), ...(entry?.profile_id ? { profile_id: String(entry.profile_id), label: String(entry.label || entry.profile_id), accent: String(entry.accent || '') } : {}) };
  }).filter((entry: BridgeCapability) => Boolean(entry.provider));
}

function normalizeBridgeSupportEntry(raw: any): AgentBridgeSupportEntry {
  return {
    bridgeId: String(raw?.bridge_id || raw?.bridgeId || ''),
    enabled: Boolean(raw?.enabled ?? raw?.is_enabled ?? false),
    providerProfile: raw?.provider || raw?.provider_profile || raw?.providerProfile || undefined,
    model: raw?.model || raw?.model || raw?.model || undefined,
    priority: raw?.priority !== undefined ? Number(raw.priority) : undefined,
    maxInstances: raw?.max_instances !== undefined ? Number(raw.max_instances) : raw?.maxInstances !== undefined ? Number(raw.maxInstances) : undefined,
  };
}

function normalizeBridgeSupport(data: any): { agentId: string; entries: AgentBridgeSupportEntry[] } {
  const rawEntries = data?.entries || data?.bridge_support || data?.supports || (Array.isArray(data) ? data : []);
  const list = Array.isArray(rawEntries) ? rawEntries : [];
  return {
    agentId: String(data?.agent_id || data?.agentId || ''),
    entries: list.map(normalizeBridgeSupportEntry).filter((entry: AgentBridgeSupportEntry) => Boolean(entry.bridgeId)),
  };
}

/**
 * GET /bridges rows (list or `{bridges}`), tolerant of either envelope. The hub's
 * row `capabilities` are dropped because they are not filtered to
 * enabled/present/active providers (see listBridges).
 */
function bridgeRowsFrom(data: any): any[] {
  const rows = data?.bridges || data || [];
  return (Array.isArray(rows) ? rows : []).map((bridge: any) => {
    const { capabilities: _unfiltered, ...rest } = bridge || {};
    return rest;
  });
}

export interface ReadBridgeRowsOptions {
  /** Include approved-but-not-enrolled bridges (`?include_pending=1`). */
  includePending?: boolean;
  /**
   * Fetch now even when the cache holds the list. For decisions that must not act
   * on a stale row (auto-unseal re-check, key delivery, enrollment); the answer
   * still lands in the shared cache for every mounted consumer.
   */
  fresh?: boolean;
}

/**
 * The bridge list for code outside React. Reads through the shared listBridges
 * (or listBridgesWithPending) cache instead of calling GET /bridges directly, so a
 * list a mounted component already holds costs no request. Falls back to a plain
 * fetch when no app store is bound (tests, demos).
 */
export async function readBridgeRows(options: ReadBridgeRowsOptions = {}): Promise<any[]> {
  const dispatch = heimdallApiDispatch();
  if (!dispatch) {
    return bridgeRowsFrom(await cookieJsonFetch(options.includePending ? '/bridges?include_pending=1' : '/bridges'));
  }
  const endpoint = options.includePending
    ? bridgeSupportApi.endpoints.listBridgesWithPending
    : bridgeSupportApi.endpoints.listBridges;
  // Subscribe briefly, then release: the entry stays cached for its
  // keepUnusedDataFor instead of being dropped at once like a subscribe:false read.
  const request = dispatch((endpoint as any).initiate(undefined, { forceRefetch: Boolean(options.fresh) }));
  try {
    const data = await request.unwrap();
    return Array.isArray(data?.bridges) ? data.bridges : [];
  } catch (error: any) {
    // unwrap() rejects with the queryFn's plain CUSTOM_ERROR object (no .message).
    // Rebuild the ApiError that cookieJsonFetch threw, so callers see the same
    // shape (message, status, code) as on the no-store path.
    if (error?.status === 'CUSTOM_ERROR') {
      throw new ApiError(error.error, error.originalStatus, error.code, undefined, undefined, error.details);
    }
    throw error;
  } finally {
    request.unsubscribe();
  }
}

export const bridgeSupportApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listAgentBridgeSupport: build.query<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        if (!agentId) return { data: { agentId, entries: [] } };
        try {
          const data = await cookieJsonFetch(`/agents/${encodeURIComponent(agentId)}/bridge-support`);
          return { data: normalizeBridgeSupport(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentId }) => [{ type: 'BridgeSupport' as const, id: agentId }],
    }),
    patchAgentBridgeSupport: build.mutation<any, { agentId: string; bridgeId: string; enabled?: boolean; providerProfile?: string; model?: string; priority?: number; maxInstances?: number }>({
      queryFn: async (arg) => {
        if (!arg.agentId || !arg.bridgeId) return { data: { ok: false, message: 'Missing agentId/bridgeId' } };
        try {
          let current: AgentBridgeSupportEntry | undefined;
          const preservesFields = arg.providerProfile === undefined || arg.model === undefined || arg.priority === undefined || arg.maxInstances === undefined;
          if (preservesFields) {
            const rows = normalizeBridgeSupport(await cookieJsonFetch(`/agents/${encodeURIComponent(arg.agentId)}/bridge-support`)).entries;
            current = rows.find((row) => row.bridgeId === arg.bridgeId);
          }
          const payload = {
            bridge_id: arg.bridgeId,
            enabled: arg.enabled ?? current?.enabled ?? true,
            priority: arg.priority !== undefined ? arg.priority : (current?.priority || 0),
            max_instances: arg.maxInstances !== undefined ? arg.maxInstances : (current?.maxInstances || 0),
          };
          const data = await cookieMutation(`/agents/${encodeURIComponent(arg.agentId)}/bridge-support/${encodeURIComponent(arg.bridgeId)}`, 'PATCH', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'BridgeSupport' as const, id: agentId }, { type: 'Agents' as const, id: 'LIST' }],
    }),
    // Plain GET /bridges: one request, no per-bridge fan-out. Provider availability is
    // NOT here: capability consumers read it per bridge, lazily, through
    // useBridgeProviderStatus (listBridgeProviders). The hub's own row `capabilities`
    // are dropped because they are not filtered to enabled/present/active providers,
    // so a consumer reading them would offer providers the bridge cannot run.
    listBridges: build.query<any, void | {}>({
      queryFn: async () => {
        try {
          return { data: { bridges: bridgeRowsFrom(await cookieJsonFetch('/bridges')) } };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: [{ type: 'Bridges' as const, id: 'LIST' }],
      // Bridges change rarely; keep cached across conversation switches (was the
      // 30s global default). Bridge mutations and the user WebSocket's bridge events
      // (wsInvalidation.ts) invalidate the LIST tag, so consumers need no poll.
      keepUnusedDataFor: 600,
    }),
    // GET /bridges?include_pending=1: the same rows plus approved-but-not-enrolled
    // bridges (REQ-EA-6). Only Settings and the enrollment flows want those, so they
    // are a separate entry that shares the LIST tag: the WebSocket's
    // bridge_enrollment_changed invalidation refreshes both.
    listBridgesWithPending: build.query<{ bridges: any[] }, void>({
      queryFn: async () => {
        try {
          return { data: { bridges: bridgeRowsFrom(await cookieJsonFetch('/bridges?include_pending=1')) } };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: [{ type: 'Bridges' as const, id: 'LIST' }],
    }),
    fetchBridgeDetail: build.query<any, { bridgeId: string; expand?: string }>({
      queryFn: withSessionQuery(async ({ bridgeId, expand }, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !bridgeId) return { bridge: null };
        const data = await daemonApi.fetchBridgeDetail({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, bridgeId, expand });
        return { bridge: data?.bridge || data, instances: data?.instances || [], project_paths: data?.project_paths || [] };
      }),
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: bridgeId }],
    }),
    renameBridge: build.mutation<any, { bridgeId: string; label?: string; telemetry_enabled?: string }>({
      queryFn: async ({ bridgeId, label, telemetry_enabled }) => {
        try {
          const body: Record<string, any> = {};
          if (label !== undefined) body.label = label;
          if (telemetry_enabled !== undefined) body.telemetry_enabled = telemetry_enabled;
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    updateBridgeTelemetry: build.mutation<any, { bridgeId: string; telemetry_enabled: 'inherit' | 'enabled' | 'disabled' | string }>({
      queryFn: async ({ bridgeId, telemetry_enabled }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}`, 'PATCH', { telemetry_enabled });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    // Bridge error events (bridge_logs plan v2 §4.4): the hub's per-bridge ring of
    // structured warn/error events, with `message` rendered server-side. Owner
    // scoped; a purge invalidates the same cache key.
    listBridgeEvents: build.query<BridgeEventsPage, { bridgeId: string; limit?: number; beforeId?: number }>({
      queryFn: async ({ bridgeId, limit, beforeId }) => {
        try {
          const params = new URLSearchParams();
          params.set('limit', String(limit ?? 50));
          if (beforeId) params.set('before_id', String(beforeId));
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/events?${params.toString()}`);
          return { data: normalizeBridgeEventsPage(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: `events:${bridgeId}` }],
    }),
    purgeBridgeEvents: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/events`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: `events:${bridgeId}` }],
    }),
    revokeBridge: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/revoke`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    // REQ-ENR-10: ask a live bridge to uninstall itself (ham-bridge uninstall,
    // which revokes it and wipes its secrets). An offline bridge answers 422:
    // revoke it instead.
    uninstallBridge: build.mutation<any, { bridgeId: string; purge?: boolean }>({
      queryFn: async ({ bridgeId, purge }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/uninstall`, 'POST', { purge: purge !== false });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    updateBridge: build.mutation<any, { bridgeId: string; targetVersion?: string; force?: boolean; drainTimeoutSeconds?: number; updateExtensions?: boolean; allowDowngrade?: boolean }>({
      queryFn: async ({ bridgeId, targetVersion, force, drainTimeoutSeconds, updateExtensions, allowDowngrade }) => {
        try {
          const body: Record<string, any> = {};
          if (targetVersion !== undefined) body.target_version = targetVersion;
          if (force !== undefined) body.force = force;
          if (allowDowngrade !== undefined) body.allow_downgrade = allowDowngrade;
          if (updateExtensions !== undefined) body.update_extensions = updateExtensions;
          if (drainTimeoutSeconds !== undefined) body.drain_timeout_seconds = drainTimeoutSeconds;
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/update`, 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    installProviderExtension: build.mutation<ProviderExtensionCommand, { bridgeId: string; provider: string; profileId?: string }>({
      queryFn: async ({ bridgeId, provider, profileId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/extension-install`, 'POST', profileId ? { profile_id: profileId } : {});
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    uninstallProviderExtension: build.mutation<ProviderExtensionCommand, { bridgeId: string; provider: string; profileId?: string }>({
      queryFn: async ({ bridgeId, provider, profileId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/extension-uninstall`, 'POST', profileId ? { profile_id: profileId } : {});
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    // ACP adapter install for one provider on a bridge (the Agent settings panel's
    // "Install adapter" fix). Progress arrives as provider_status_changed, which
    // refetches the bridge's provider status (acp_availability reason `installing`).
    installAcpAdapter: build.mutation<{ command_id?: string }, { bridgeId: string; provider: string }>({
      queryFn: async ({ bridgeId, provider }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/acp-adapter`, 'POST', { action: 'install' });
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    getProviderExtensionInstall: build.query<ProviderExtensionCommand, { bridgeId: string; provider: string; commandId: string; profileId?: string; kind?: ExtensionCommandKind }>({
      queryFn: async ({ bridgeId, provider, commandId, kind, profileId }) => {
        try {
          const verb = kind === 'uninstall' ? 'extension-uninstall' : 'extension-install';
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/${verb}/${encodeURIComponent(commandId)}${profileId ? "?profile_id=" + encodeURIComponent(profileId) : ""}`);
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      async onQueryStarted({ bridgeId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          if (isExtensionInstallTerminal(data.status)) {
            dispatch(heimdallApi.util.invalidateTags([{ type: 'BridgeProviders', id: bridgeId }]));
          }
        } catch { /* Request errors are shown by the caller; retain the tracked command. */ }
      },
      keepUnusedDataFor: 0,
    }),
    // The three bridge-enrollment endpoints are DELETED (REQ-ENROLL-9):
    // POST/GET /bridge-enrollments and DELETE /bridge-enrollments/<id>. They minted,
    // listed and revoked the one-time enrollment token, and all three now 404.
    // Enrollment is browser-approved and the bridge drives it, so the UI mints
    // nothing and has no enrollment rows to list or revoke.
    refreshBridgeModels: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const { refreshBridgeProviderCatalog } = await import('../../components/providers/providerSetupApi');
          return { data: await refreshBridgeProviderCatalog(bridgeId) };
        }
        catch (error: any) { return { error: customQueryError(error) as any }; }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    listBridgeProviders: build.query<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        if (!bridgeId) return { data: { bridge_id: '', providers: [] } };
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/provider-status`);
          return { data: await normalizeProviderStatus(data, bridgeId) };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
      // Shared by every pane/picker on the same bridge; survive brief unmounts.
      keepUnusedDataFor: 300,
    }),
    putProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string; path: string }>({
      queryFn: withSessionQuery(async ({ projectId, bridgeId, path }, { session }) => daemonApi.putProjectBridgePath({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, projectId, bridgeId, path })),
      invalidatesTags: (_result, _error, { projectId }) => [{ type: 'ProjectBridgePaths' as const, id: projectId }],
    }),
    deleteProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: withSessionQuery(async ({ projectId, bridgeId }, { session }) => daemonApi.deleteProjectBridgePath({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, projectId, bridgeId })),
      invalidatesTags: (_result, _error, { projectId }) => [{ type: 'ProjectBridgePaths' as const, id: projectId }],
    }),
    validateProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: withSessionQuery(async ({ projectId, bridgeId }, { session }) => daemonApi.validateProjectBridgePath({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, projectId, bridgeId })),
    }),
  }),
});

export const {
  useListAgentBridgeSupportQuery,
  useListBridgesQuery,
  useListBridgesWithPendingQuery,
  useRenameBridgeMutation,
  useUpdateBridgeTelemetryMutation,
  useRevokeBridgeMutation,
  useListBridgeEventsQuery,
  usePurgeBridgeEventsMutation,
  useUpdateBridgeMutation,
  useUninstallBridgeMutation,
  useInstallProviderExtensionMutation,
  useUninstallProviderExtensionMutation,
  useInstallAcpAdapterMutation,
  useGetProviderExtensionInstallQuery,
  useListBridgeProvidersQuery,
  useRefreshBridgeModelsMutation,
} = bridgeSupportApi;

/** How long a visible, open runtime/provider picker may show provider status. */
export const PROVIDER_STATUS_LIVE_POLL_MS = 30000;

export type BridgeProviderStatus = {
  /** The bridge row with `capabilities` and `provider_status_error` filled in. */
  bridge: any;
  capabilities: BridgeCapability[];
  /** Provider status answered (or failed, or cannot exist for this bridge). */
  loaded: boolean;
};

/**
 * Provider availability for ONE bridge, keyed by its id (GET
 * /bridges/{id}/provider-status). `skip` keeps it lazy: callers pass it until the
 * capability is needed (a selected bridge, an open runtime picker). `live` adds a
 * bounded poll while a picker is open and the window is focused; nothing pushes
 * provider changes yet.
 */
export function useBridgeProviderStatus(bridge: any, opts: { skip?: boolean; live?: boolean } = {}): BridgeProviderStatus {
  const bridgeId = String(bridge?.bridge_id || bridge?.id || '');
  const revoked = String(bridge?.status || '').toLowerCase() === 'revoked';
  const query = useListBridgeProvidersQuery({ bridgeId }, {
    skip: Boolean(opts.skip) || !bridgeId || revoked,
    pollingInterval: opts.live ? PROVIDER_STATUS_LIVE_POLL_MS : 0,
    skipPollingIfUnfocused: true,
  });
  const { currentData: data, isError } = query;
  return useMemo(() => {
    if (!bridge) return { bridge, capabilities: [], loaded: false };
    const capabilities = data ? normalizeBridgeCapabilities(data) : [];
    return {
      bridge: { ...bridge, capabilities, provider_status_error: Boolean(isError) },
      capabilities,
      loaded: Boolean(data) || Boolean(isError) || revoked,
    };
  }, [bridge, data, isError, revoked]);
}
