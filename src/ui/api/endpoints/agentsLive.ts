import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';

// UI: consolidated sidebar tree from GET /api/v1/agents/live — EVERY project
// (alphabetical, even with nothing live) -> the chains with >=1 live agent ->
// those chains' live agents + full member roster. One call replaces the old
// per-project/per-chain fan-out and carries the coordinator flag the rail uses to
// gold-highlight a coordinator agent's own name. Cookie-authed like the rest of
// the sidebar data (same session as /api/v1/me).

export type LiveAgent = {
  agentInstanceId: string;
  displayName: string;
  isCoordinator: boolean;
  runtimeStatus: string;
  activityStatus: string;
  // Project this running agent belongs to (matches the chain entry's project for
  // live agents; cross-project chains list an agent under its own project).
  projectId: string;
};

export type LiveMember = {
  agentInstanceId: string;
  displayName: string;
  role: string;
  isCoordinator: boolean;
  isLive: boolean;
  runtimeStatus: string;
  // Project this member's instance belongs to ('' when unresolved). members[] is
  // the full chain roster, so cross-project members each carry their own id.
  projectId: string;
};

export type LiveChain = {
  chainId: string;
  title: string;
  coordinatorAgentInstanceId: string;
  liveAgents: LiveAgent[];
  members: LiveMember[];
};

export type LiveProject = {
  projectId: string;
  name: string;
  chains: LiveChain[];
};

function normalizeLiveAgent(raw: any): LiveAgent {
  return {
    agentInstanceId: String(raw?.agent_instance_id || raw?.agentInstanceId || ''),
    displayName: String(raw?.display_name || raw?.displayName || ''),
    isCoordinator: Boolean(raw?.is_coordinator ?? raw?.isCoordinator),
    runtimeStatus: String(raw?.runtime_status || raw?.runtimeStatus || ''),
    activityStatus: String(raw?.activity_status || raw?.activityStatus || ''),
    projectId: String(raw?.project_id || raw?.projectId || ''),
  };
}

function normalizeLiveMember(raw: any): LiveMember {
  return {
    agentInstanceId: String(raw?.agent_instance_id || raw?.agentInstanceId || ''),
    displayName: String(raw?.display_name || raw?.displayName || ''),
    role: String(raw?.role || ''),
    isCoordinator: Boolean(raw?.is_coordinator ?? raw?.isCoordinator),
    isLive: Boolean(raw?.is_live ?? raw?.isLive),
    runtimeStatus: String(raw?.runtime_status || raw?.runtimeStatus || ''),
    projectId: String(raw?.project_id || raw?.projectId || ''),
  };
}

function normalizeLiveChain(raw: any): LiveChain {
  return {
    chainId: String(raw?.chain_id || raw?.chainId || ''),
    title: String(raw?.title || ''),
    coordinatorAgentInstanceId: String(raw?.coordinator_agent_instance_id || raw?.coordinatorAgentInstanceId || ''),
    liveAgents: Array.isArray(raw?.live_agents || raw?.liveAgents) ? (raw.live_agents || raw.liveAgents).map(normalizeLiveAgent) : [],
    members: Array.isArray(raw?.members) ? raw.members.map(normalizeLiveMember) : [],
  };
}

function normalizeLiveProject(raw: any): LiveProject {
  return {
    projectId: String(raw?.project_id || raw?.projectId || ''),
    name: String(raw?.name || ''),
    chains: Array.isArray(raw?.chains) ? raw.chains.map(normalizeLiveChain) : [],
  };
}

export const agentsLiveApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // The whole projects->live-chains->agents tree in one query. Tagged with the
    // SidebarConversations id so the same user-WS invalidation path that refreshes
    // conversation state also refreshes the live tree (project/chain/agent set).
    getAgentsLive: build.query<LiveProject[], void>({
      queryFn: async () => {
        try {
          const payload = await cookieJsonFetch('/agents/live');
          const rows = Array.isArray(payload?.projects) ? payload.projects : Array.isArray(payload) ? payload : [];
          return { data: rows.map(normalizeLiveProject) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: [{ type: 'SidebarConversations' as const, id: 'ALL' }],
    }),
  }),
});

export const { useGetAgentsLiveQuery } = agentsLiveApi;
