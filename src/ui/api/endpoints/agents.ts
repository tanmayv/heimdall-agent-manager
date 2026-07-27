import * as daemonApi from '../daemonApi';
import { applyAgentRuntimeEvent, loadKnownAgents, mapAgent, mergeKnownAndLiveAgents, storeKnownAgents, upsertKnownAgentRecord } from '../agentCatalog';
import { cookieMutation, cookieJsonFetch } from '../cookieFetch';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function agentTagId(agent: any, fallback = '') {
  return String(agent?.id || agent?.agent_instance_id || agent?.agentInstanceId || fallback || '');
}

export const agentsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listAgentIdentities: build.query<any, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/agents');
          return { data: { agents: data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Agents' as const, id: 'LIST' }],
    }),
    listAgentTemplates: build.query<any, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/templates');
          return { data: { templates: data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }],
    }),
    fetchAgentIdentity: build.query<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        if (!agentId) return { data: { agent: null } };
        try {
          const data = await cookieJsonFetch(`/agents/${encodeURIComponent(agentId)}`);
          return { data: { agent: data || null } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: agentId }],
    }),
    updateAgentIdentity: build.mutation<any, { agentId: string; name?: string; defaultProvider?: string; defaultTier?: string; instructions?: string }>({
      queryFn: async ({ agentId, name, defaultProvider, defaultTier, instructions }) => {
        try {
          const payload: any = {};
          if (name !== undefined) payload.name = name;
          if (defaultProvider !== undefined) payload.default_provider = defaultProvider;
          if (defaultTier !== undefined) payload.default_tier = defaultTier;
          if (instructions !== undefined) payload.instructions = instructions;
          const data = await cookieMutation(`/agents/${encodeURIComponent(agentId)}`, 'PATCH', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'BridgeSupport' as const, id: agentId }],
    }),
    enableBridgeSupport: build.mutation<any, { agentId: string; bridges?: Array<{ bridgeId?: string; bridge_id?: string; enabled?: boolean; provider?: string; providerProfile?: string; tier?: string; modelTier?: string; priority?: number; maxInstances?: number }> }>({
      queryFn: async ({ agentId, bridges }) => {
        try {
          let rows = bridges || [];
          if (!rows.length) {
            const bridgesData = await cookieJsonFetch('/bridges');
            rows = (bridgesData?.bridges || bridgesData || []).map((b: any) => ({ bridgeId: b.bridge_id, enabled: true }));
          }
          const payload = {
            bridges: rows.map((b: any) => ({
              bridge_id: b.bridge_id || b.bridgeId,
              enabled: b.enabled !== false,
              provider: b.provider || b.providerProfile || '',
              tier: b.tier || b.modelTier || '',
              priority: b.priority || 0,
              max_instances: b.maxInstances || 0,
            }))
          };
          const data = await cookieMutation(`/agents/${encodeURIComponent(agentId)}/bridge-support`, 'PUT', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'BridgeSupport' as const, id: agentId }],
    }),
    listAgents: build.query<any, { limit?: number; offset?: number; projectId?: string; running?: boolean } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const localKnown = loadKnownAgents();
        if (!session?.daemonUrl) {
          const agents = mergeKnownAndLiveAgents(localKnown, [], false, false);
          storeKnownAgents(agents);
          return { agents, identities: [], totalCount: 0, hasMore: false, offset: 0 };
        }

        const args = (arg && typeof arg === 'object') ? arg : {};
        const limit = args.limit ?? 10000;
        const offset = args.offset ?? 0;
        const projectId = args.projectId ?? '';
        const running = args.running;
        const isPaged = args.limit !== undefined || args.offset !== undefined;

        let daemonAgents: any[] = [];
        let daemonIdentities: any[] = [];
        let daemonReachable = false;
        let totalCount = 0;
        let hasMore = false;
        try {
          const catalog = await daemonApi.listKnownAgentsCatalog({
            daemonUrl: session.daemonUrl,
            projectId,
            includeIdentities: true,
            includeConversations: true,
            limit,
            offset,
            running,
          });
          daemonAgents = catalog.agents || [];
          daemonIdentities = catalog.identities || [];
          daemonReachable = true;
          totalCount = catalog.total || 0;
          hasMore = catalog.hasMore || false;
        } catch {
          daemonAgents = [];
          daemonIdentities = [];
        }

        const agents = mergeKnownAndLiveAgents(localKnown, daemonAgents, daemonReachable, isPaged);
        storeKnownAgents(agents);
        return { agents, identities: daemonIdentities, totalCount, hasMore, offset };
      }),
      providesTags: (result, _error, arg) => [
        { type: 'Agents' as const, id: JSON.stringify(arg || {}) },
        ...((result?.agents || []).map((agent: any) => ({ type: 'Agents' as const, id: agentTagId(agent) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchAgentsPage: build.query<any, { limit: number; offset: number; projectId?: string; running?: boolean }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const localKnown = loadKnownAgents();
        if (!session?.daemonUrl) {
          const agents = mergeKnownAndLiveAgents(localKnown, [], false, false);
          return { agents, identities: [], totalCount: 0, hasMore: false, offset: arg.offset };
        }
        const data = await daemonApi.listKnownAgentsCatalog({
          daemonUrl: session.daemonUrl,
          projectId: arg.projectId,
          includeIdentities: true,
          includeConversations: true,
          limit: arg.limit,
          offset: arg.offset,
          running: arg.running,
        });
        const daemonAgents = data.agents || [];
        const daemonIdentities = data.identities || [];
        const agents = mergeKnownAndLiveAgents(localKnown, daemonAgents, true, true);
        return {
          agents,
          identities: daemonIdentities,
          totalCount: data.total || 0,
          hasMore: data.hasMore || false,
          offset: arg.offset,
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const baseArgs: any = {};
          if (arg.projectId) baseArgs.projectId = arg.projectId;
          if (arg.running !== undefined) baseArgs.running = arg.running;
          const cacheKeyArgs = Object.keys(baseArgs).length > 0 ? baseArgs : undefined;
          dispatch(
            agentsApi.util.updateQueryData('listAgents', cacheKeyArgs as any, (draft: any) => {
              if (!draft) return;
              const existingIds = new Set(draft.agents.map((a: any) => a.id));
              for (const agent of data.agents) {
                if (!existingIds.has(agent.id)) {
                  draft.agents.push(agent);
                }
              }
              const existingIdentities = new Set(draft.identities.map((id: any) => id.agent_id || id.agentId));
              for (const identity of data.identities) {
                const id = identity.agent_id || identity.agentId;
                if (!existingIdentities.has(id)) {
                  draft.identities.push(identity);
                }
              }
              draft.totalCount = data.totalCount;
              draft.hasMore = data.hasMore;
              draft.offset = data.offset;
            })
          );
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchAgent: build.query<any, { agentInstanceId?: string; agentRecordId?: string }>({
      queryFn: withSessionQuery(async ({ agentInstanceId = '', agentRecordId = '' }, { session }) => {
        if (!session?.daemonUrl || (!agentInstanceId && !agentRecordId)) return { agent: null };
        const data = await daemonApi.showAgent({ daemonUrl: session.daemonUrl, agentInstanceId, agentRecordId });
        const rawAgent = data?.agent || data?.record || data || null;
        return { agent: rawAgent ? mapAgent(rawAgent) : null };
      }),
      providesTags: (result, _error, { agentInstanceId = '', agentRecordId = '' }) => [{
        type: 'Agents' as const,
        id: agentTagId(result?.agent, agentInstanceId || agentRecordId),
      }],
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          if (!data?.agent) return;
          dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
            const rows = draft?.agents || (draft.agents = []);
            upsertKnownAgentRecord(rows, data.agent);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    startAgent: build.mutation<any, { agentInstanceId: string; provider: string; templateId?: string; projectId?: string; projectIdSet?: boolean; alias?: string; displayName?: string; modelTier?: string }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, provider, templateId, projectId, projectIdSet, alias, displayName, modelTier }, { session }) => {
        if (!session?.daemonUrl || !agentInstanceId) return { ok: false, message: 'Missing agent' };
        return daemonApi.startAgent({ daemonUrl: session.daemonUrl, agentInstanceId, provider, templateId, projectId, projectIdSet, alias, displayName, modelTier });
      }),
      invalidatesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'Agents' as const, id: agentInstanceId },
      ],
    }),
    stopAgent: build.mutation<any, { agentInstanceId: string; timeInSec?: number }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, timeInSec }, { session }) => {
        if (!session?.daemonUrl || !agentInstanceId) return { ok: false, message: 'Missing agent' };
        return daemonApi.stopAgent({ daemonUrl: session.daemonUrl, agentInstanceId, timeInSec });
      }),
      invalidatesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'Agents' as const, id: agentInstanceId },
      ],
    }),
    // UI-8: Add agent to chain via the rewrite API (POST /api/v1/agent-instances
    // with existing chain_id). Hydrates a fresh AgentInstance into the chain and
    // creates its 1:1 conversation; never attaches an unrelated live instance.
    createAgentInstanceInChain: build.mutation<any, { agentId: string; chainId: string; providerProfile?: string; modelTier?: string; projectId?: string; displayName?: string; templateId?: string }>({
      queryFn: withSessionQuery(async ({ agentId, chainId, providerProfile, modelTier, projectId, displayName, templateId }, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !agentId || !chainId) return { ok: false, message: 'Missing agentId/chainId' };
        return daemonApi.createAgentInstanceInChain({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, agentId, chainId, providerProfile, modelTier, projectId, displayName, templateId });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'ChainTasks' as const, id: chainId },
      ],
    }),
    createAgent: build.mutation<any, { name: string; slug?: string; templateId?: string; defaultProvider?: string; defaultTier?: string; instructions?: string }>({
      queryFn: async (arg) => {
        try {
          const payload: any = {
            name: arg.name,
            slug: arg.slug || arg.name,
            template_id: arg.templateId || '',
            instructions: arg.instructions || '',
          };
          if (arg.defaultProvider) payload.default_provider = arg.defaultProvider;
          if (arg.defaultTier) payload.default_tier = arg.defaultTier;
          const data = await cookieMutation('/agents', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Agents' as const, id: 'LIST' }],
    }),
    archiveAgentIdentity: build.mutation<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        try {
          const data = await cookieMutation(`/agents/${encodeURIComponent(agentId)}/archive`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Agents' as const, id: 'LIST' }],
    }),
    listAgentInstances: build.query<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        if (!agentId) return { data: { instances: [] } };
        try {
          const data = await cookieJsonFetch(`/agent-instances?agent_id=${encodeURIComponent(agentId)}`);
          return { data: { instances: data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentId }) => [{ type: 'AgentInstances' as const, id: agentId }],
    }),
    launchAgentInstance: build.mutation<any, { agentId: string; bridgeId?: string; provider?: string; tier?: string; projectId?: string }>({
      queryFn: async ({ agentId, bridgeId, provider, tier, projectId }) => {
        try {
          const payload: any = { agent_id: agentId };
          if (bridgeId) payload.bridge_id = bridgeId;
          if (provider) payload.provider = provider;
          if (tier) payload.tier = tier;
          if (projectId) payload.project_id = projectId;
          const data = await cookieMutation('/agent-instances', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }],
    }),
    stopAgentInstance: build.mutation<any, { agentId: string; instanceId: string }>({
      queryFn: async ({ instanceId }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/stop`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }],
    }),
    restartAgentInstance: build.mutation<any, { agentId: string; instanceId: string }>({
      queryFn: async ({ instanceId }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/restart`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }],
    }),
    // Remote role content for a local-proxy agent-id. Cached aggressively
    // (keepUnusedDataFor long) since remote templates change rarely; keyed by
    // peer + remote agent-id so it is fetched once per mapping.
    fetchPeerAgentTemplate: build.query<any, { peerId: string; remoteAgentId: string }>({
      queryFn: withSessionQuery(async ({ peerId, remoteAgentId }, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !peerId || !remoteAgentId) return { template: null, agentId: remoteAgentId };
        return daemonApi.fetchPeerAgentTemplate({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, peerId, remoteAgentId });
      }),
      keepUnusedDataFor: 600,
      providesTags: (_result, _error, { peerId, remoteAgentId }) => [{ type: 'AgentTemplate' as const, id: `remote:${peerId}:${remoteAgentId}` }],
    }),
    // Advertised remote agent-ids for a peer, used to pick a new remap target.
    listPeerAdvertisedAgents: build.query<any, { peerId: string }>({
      queryFn: withSessionQuery(async ({ peerId }, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !peerId) return { daemonId: '', agents: [] };
        return daemonApi.listPeerAdvertisedAgents({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, peerId });
      }),
      keepUnusedDataFor: 120,
      providesTags: (_result, _error, { peerId }) => [{ type: 'Agents' as const, id: `peer-advertised:${peerId}` }],
    }),
    remapRemoteProxy: build.mutation<any, { localAgentId: string; remoteAgentId: string; peerId?: string; originDaemonId?: string; displayName?: string; templateId?: string }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken) return { ok: false, message: 'No session' };
        return daemonApi.remapRemoteProxy({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, ...arg });
      }),
      invalidatesTags: () => [{ type: 'Agents' as const, id: 'LIST' }],
    }),
  }),
});

export function upsertAgentInCaches(dispatch: any, rawAgent: any) {
  const mapped = mapAgent(rawAgent);
  if (!mapped?.id) return '';
  dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
    const rows = draft?.agents || (draft.agents = []);
    upsertKnownAgentRecord(rows, mapped);
  }));
  dispatch(agentsApi.util.upsertQueryData('fetchAgent', { agentInstanceId: mapped.id }, { agent: mapped }));
  return mapped.id;
}

export function patchAgentCachesFromWs(dispatch: any, payload: any) {
  const type = String(payload?.type || '');
  if (type === 'agent_runtime_changed') {
    let agentId = '';
    dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
      const rows = draft?.agents || (draft.agents = []);
      agentId = applyAgentRuntimeEvent(rows, payload) || agentId;
    }));
    if (!agentId) return;
    dispatch(agentsApi.util.updateQueryData('fetchAgent', { agentInstanceId: agentId }, (draft: any) => {
      if (!draft?.agent) return;
      const rows = [draft.agent];
      applyAgentRuntimeEvent(rows, payload);
      draft.agent = rows[0];
    }));
    return;
  }

  const agentId = String(payload?.target_agent_instance_id || payload?.agent_instance_id || payload?.agent?.agent_instance_id || payload?.record?.agent_instance_id || '');
  if (!agentId) return;

  const reason = String(payload?.reason || '');
  if (reason === 'heartbeat') {
    const lastSeenUnixMs = Number(payload?.last_seen_unix_ms || 0);
    if (lastSeenUnixMs) {
      const formatted = new Date(lastSeenUnixMs).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
      dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
        const rows = draft?.agents || (draft.agents = []);
        const idx = rows.findIndex((r: any) => r.id === agentId);
        if (idx >= 0) {
          rows[idx].lastSeenUnixMs = lastSeenUnixMs;
          rows[idx].lastSeen = formatted;
        }
      }));
      dispatch(agentsApi.util.updateQueryData('fetchAgent', { agentInstanceId: agentId }, (draft: any) => {
        if (draft?.agent) {
          draft.agent.lastSeenUnixMs = lastSeenUnixMs;
          draft.agent.lastSeen = formatted;
        }
      }));
    }
    return;
  }

  dispatch(heimdallApi.util.invalidateTags([{ type: 'Agents', id: 'LIST' }, { type: 'Agents', id: agentId }]));
}

export const { useListAgentIdentitiesQuery, useListAgentTemplatesQuery, useFetchAgentIdentityQuery, useUpdateAgentIdentityMutation, useEnableBridgeSupportMutation, useListAgentsQuery, useFetchAgentsPageQuery, useLazyFetchAgentsPageQuery, useFetchAgentQuery, useStartAgentMutation, useStopAgentMutation, useCreateAgentInstanceInChainMutation, useCreateAgentMutation, useArchiveAgentIdentityMutation, useListAgentInstancesQuery, useLaunchAgentInstanceMutation, useStopAgentInstanceMutation, useRestartAgentInstanceMutation, useFetchPeerAgentTemplateQuery, useListPeerAdvertisedAgentsQuery, useRemapRemoteProxyMutation } = agentsApi;
