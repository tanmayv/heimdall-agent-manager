import * as daemonApi from '../daemonApi';
import { applyAgentRuntimeEvent, loadKnownAgents, mapAgent, mergeKnownAndLiveAgents, storeKnownAgents, upsertKnownAgentRecord } from '../agentCatalog';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function agentTagId(agent: any, fallback = '') {
  return String(agent?.id || agent?.agent_instance_id || agent?.agentInstanceId || fallback || '');
}

export const agentsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listAgents: build.query<any, { limit?: number; offset?: number; projectId?: string } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const localKnown = loadKnownAgents();
        if (!session?.daemonUrl) {
          const agents = mergeKnownAndLiveAgents(localKnown, [], false, false);
          storeKnownAgents(agents);
          return { agents, identities: [], totalCount: 0, hasMore: false, offset: 0 };
        }

        const args = (arg && typeof arg === 'object') ? arg : {};
        const limit = args.limit ?? 20;
        const offset = args.offset ?? 0;
        const projectId = args.projectId ?? '';
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
    fetchAgentsPage: build.query<any, { limit: number; offset: number; projectId?: string }>({
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
          const baseArgs = arg.projectId ? { projectId: arg.projectId } : undefined;
          dispatch(
            agentsApi.util.updateQueryData('listAgents', baseArgs as any, (draft: any) => {
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
  dispatch(heimdallApi.util.invalidateTags([{ type: 'Agents', id: 'LIST' }, { type: 'Agents', id: agentId }]));
}

export const { useListAgentsQuery, useFetchAgentsPageQuery, useLazyFetchAgentsPageQuery, useFetchAgentQuery, useStartAgentMutation, useStopAgentMutation, useFetchPeerAgentTemplateQuery, useListPeerAdvertisedAgentsQuery, useRemapRemoteProxyMutation } = agentsApi;
