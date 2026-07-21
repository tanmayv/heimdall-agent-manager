import * as daemonApi from '../daemonApi';
import { applyAgentRuntimeEvent, loadKnownAgents, mapAgent, mergeKnownAndLiveAgents, storeKnownAgents, upsertKnownAgentRecord } from '../agentCatalog';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function agentTagId(agent: any, fallback = '') {
  return String(agent?.id || agent?.agent_instance_id || agent?.agentInstanceId || fallback || '');
}

export const agentsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listAgents: build.query<any, void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        const localKnown = loadKnownAgents();
        if (!session?.daemonUrl) {
          const agents = mergeKnownAndLiveAgents(localKnown, [], false);
          storeKnownAgents(agents);
          return { agents, identities: [] };
        }

        let daemonAgents: any[] = [];
        let daemonIdentities: any[] = [];
        let daemonReachable = false;
        try {
          const catalog = await daemonApi.listKnownAgentsCatalog({
            daemonUrl: session.daemonUrl,
            includeIdentities: true,
            includeConversations: true,
          });
          daemonAgents = catalog.agents || [];
          daemonIdentities = catalog.identities || [];
          daemonReachable = true;
        } catch {
          daemonAgents = [];
          daemonIdentities = [];
        }

        const agents = mergeKnownAndLiveAgents(localKnown, daemonAgents, daemonReachable);
        storeKnownAgents(agents);
        return { agents, identities: daemonIdentities };
      }),
      providesTags: (result) => [
        { type: 'Agents' as const, id: 'LIST' },
        ...((result?.agents || []).map((agent: any) => ({ type: 'Agents' as const, id: agentTagId(agent) })).filter((tag: any) => Boolean(tag.id))),
      ],
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

export const { useListAgentsQuery, useFetchAgentQuery, useStartAgentMutation, useStopAgentMutation, useFetchPeerAgentTemplateQuery, useListPeerAdvertisedAgentsQuery, useRemapRemoteProxyMutation } = agentsApi;
