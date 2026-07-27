import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type AgentBridgeSupportEntry = {
  bridgeId: string;
  enabled: boolean;
  providerProfile?: string;
  modelTier?: string;
  priority?: number;
  maxInstances?: number;
};

export type BridgeCapability = {
  provider: string;
  tiers: string[];
  defaultTier?: string;
};

export function normalizeBridgeCapabilities(raw: any): BridgeCapability[] {
  const caps = raw?.capabilities || raw?.capability_report || raw?.provider_capabilities || raw || [];
  const source = Array.isArray(caps)
    ? caps
    : Array.isArray(caps?.providers)
      ? caps.providers
      : Array.isArray(caps?.provider_profiles)
        ? caps.provider_profiles
        : [];
  return source.map((entry: any) => {
    if (typeof entry === 'string') return { provider: entry, tiers: [], defaultTier: undefined };
    const tiers = Array.isArray(entry?.tiers) ? entry.tiers.map((tier: any) => String(tier)).filter(Boolean) : [];
    const defaultTier = String(entry?.default_tier || entry?.defaultTier || '');
    return { provider: String(entry?.provider || entry?.name || ''), tiers, defaultTier: defaultTier || undefined };
  }).filter((entry: BridgeCapability) => Boolean(entry.provider));
}

function normalizeBridgeSupportEntry(raw: any): AgentBridgeSupportEntry {
  return {
    bridgeId: String(raw?.bridge_id || raw?.bridgeId || ''),
    enabled: Boolean(raw?.enabled ?? raw?.is_enabled ?? false),
    providerProfile: raw?.provider || raw?.provider_profile || raw?.providerProfile || undefined,
    modelTier: raw?.tier || raw?.model_tier || raw?.modelTier || undefined,
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
    patchAgentBridgeSupport: build.mutation<any, { agentId: string; bridgeId: string; enabled?: boolean; providerProfile?: string; modelTier?: string; priority?: number; maxInstances?: number }>({
      queryFn: async (arg) => {
        if (!arg.agentId || !arg.bridgeId) return { data: { ok: false, message: 'Missing agentId/bridgeId' } };
        try {
          let current: AgentBridgeSupportEntry | undefined;
          const preservesFields = arg.providerProfile === undefined || arg.modelTier === undefined || arg.priority === undefined || arg.maxInstances === undefined;
          if (preservesFields) {
            const rows = normalizeBridgeSupport(await cookieJsonFetch(`/agents/${encodeURIComponent(arg.agentId)}/bridge-support`)).entries;
            current = rows.find((row) => row.bridgeId === arg.bridgeId);
          }
          const payload = {
            bridge_id: arg.bridgeId,
            enabled: arg.enabled ?? current?.enabled ?? true,
            provider: arg.providerProfile !== undefined ? arg.providerProfile : (current?.providerProfile || ''),
            tier: arg.modelTier !== undefined ? arg.modelTier : (current?.modelTier || ''),
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
    listBridges: build.query<any, void | {}>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/bridges');
          return { data: { bridges: data?.bridges || data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
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
    renameBridge: build.mutation<any, { bridgeId: string; label: string }>({
      queryFn: async ({ bridgeId, label }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}`, 'PATCH', { label });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
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
    createBridgeEnrollment: build.mutation<any, { label?: string; expiresInSeconds?: number }>({
      queryFn: async ({ label, expiresInSeconds }) => {
        try {
          const data = await cookieMutation('/bridge-enrollments', 'POST', { label, expires_in_seconds: expiresInSeconds });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'BridgeEnrollments' as const, id: 'LIST' }],
    }),
    listBridgeEnrollments: build.query<any, void | {}>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/bridge-enrollments');
          return { data: { enrollments: data?.enrollments || data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'BridgeEnrollments' as const, id: 'LIST' }],
    }),
    revokeBridgeEnrollment: build.mutation<any, { enrollmentId: string }>({
      queryFn: async ({ enrollmentId }) => {
        try {
          const data = await cookieMutation(`/bridge-enrollments/${encodeURIComponent(enrollmentId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'BridgeEnrollments' as const, id: 'LIST' }],
    }),
    listBridgeProviders: build.query<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        if (!bridgeId) return { data: { bridge_id: '', providers: [] } };
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/providers`);
          return { data: { bridge_id: data?.bridge_id || bridgeId, providers: Array.isArray(data?.providers) ? data.providers : [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    upsertBridgeProvider: build.mutation<any, { bridgeId: string; name: string; profile: any }>({
      queryFn: async ({ bridgeId, name, profile }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(name)}`, 'PUT', profile);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }, { type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    deleteBridgeProvider: build.mutation<any, { bridgeId: string; name: string }>({
      queryFn: async ({ bridgeId, name }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(name)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }, { type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    testBridgeProvider: build.mutation<any, { bridgeId: string; name: string; tier?: string }>({
      queryFn: async ({ bridgeId, name, tier }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(name)}/test`, 'POST', { tier });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    refreshBridgeCapabilities: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/refresh`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }, { type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
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
  usePatchAgentBridgeSupportMutation,
  useListBridgesQuery,
  useFetchBridgeDetailQuery,
  useRenameBridgeMutation,
  useRevokeBridgeMutation,
  useCreateBridgeEnrollmentMutation,
  useListBridgeEnrollmentsQuery,
  useRevokeBridgeEnrollmentMutation,
  useListBridgeProvidersQuery,
  useUpsertBridgeProviderMutation,
  useDeleteBridgeProviderMutation,
  useTestBridgeProviderMutation,
  useRefreshBridgeCapabilitiesMutation,
  usePutProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  useValidateProjectBridgePathMutation,
} = bridgeSupportApi;
