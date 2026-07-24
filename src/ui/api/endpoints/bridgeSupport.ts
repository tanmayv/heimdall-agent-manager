import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

export type AgentBridgeSupportEntry = {
  bridgeId: string;
  enabled: boolean;
  providerProfile?: string;
  modelTier?: string;
  priority?: number;
  maxInstances?: number;
};

function normalizeBridgeSupportEntry(raw: any): AgentBridgeSupportEntry {
  return {
    bridgeId: String(raw?.bridge_id || raw?.bridgeId || ''),
    enabled: Boolean(raw?.enabled ?? raw?.is_enabled ?? false),
    providerProfile: raw?.provider_profile || raw?.providerProfile || undefined,
    modelTier: raw?.model_tier || raw?.modelTier || undefined,
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
      queryFn: withSessionQuery(async ({ agentId }, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !agentId) return { agentId, entries: [] };
        const data = await daemonApi.listAgentBridgeSupport({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, agentId });
        return normalizeBridgeSupport(data);
      }),
      providesTags: (_result, _error, { agentId }) => [{ type: 'BridgeSupport' as const, id: agentId }],
    }),
    patchAgentBridgeSupport: build.mutation<any, { agentId: string; bridgeId: string; enabled?: boolean; providerProfile?: string; modelTier?: string; priority?: number; maxInstances?: number }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !arg.agentId || !arg.bridgeId) return { ok: false, message: 'Missing agentId/bridgeId' };
        return daemonApi.patchAgentBridgeSupport({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, ...arg });
      }),
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'BridgeSupport' as const, id: agentId }],
    }),
    listBridges: build.query<any, void | {}>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken) return { bridges: [] };
        const data = await daemonApi.listBridges({ daemonUrl: session.daemonUrl, clientToken: session.clientToken });
        return { bridges: data?.bridges || [] };
      }),
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
      queryFn: withSessionQuery(async ({ bridgeId, label }, { session }) => daemonApi.renameBridge({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, bridgeId, label })),
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    revokeBridge: build.mutation<any, { bridgeId: string }>({
      queryFn: withSessionQuery(async ({ bridgeId }, { session }) => daemonApi.revokeBridge({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, bridgeId })),
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    createBridgeEnrollment: build.mutation<any, { label?: string; expiresInSeconds?: number }>({
      queryFn: withSessionQuery(async ({ label, expiresInSeconds }, { session }) => daemonApi.createBridgeEnrollment({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, label, expiresInSeconds })),
      invalidatesTags: [{ type: 'BridgeEnrollments' as const, id: 'LIST' }],
    }),
    listBridgeEnrollments: build.query<any, void | {}>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken) return { enrollments: [] };
        const data = await daemonApi.listBridgeEnrollments({ daemonUrl: session.daemonUrl, clientToken: session.clientToken });
        return { enrollments: data?.enrollments || [] };
      }),
      providesTags: [{ type: 'BridgeEnrollments' as const, id: 'LIST' }],
    }),
    revokeBridgeEnrollment: build.mutation<any, { enrollmentId: string }>({
      queryFn: withSessionQuery(async ({ enrollmentId }, { session }) => daemonApi.revokeBridgeEnrollment({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, enrollmentId })),
      invalidatesTags: [{ type: 'BridgeEnrollments' as const, id: 'LIST' }],
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
  usePutProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  useValidateProjectBridgePathMutation,
} = bridgeSupportApi;
