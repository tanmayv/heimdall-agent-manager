import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export interface TaskChainFleet {
  task_chain_id?: string;
  taskChainId?: string;
  agent_id: string;
  agentId?: string;
  capacity: number;
  active_count?: number;
  activeCount?: number;
  min_warm?: number;
  minWarm?: number;
  idle_ttl_seconds?: number;
  idleTtlSeconds?: number;
  provider?: string;
  tier?: string;
  created_at?: string;
  updated_at?: string;
}

function normalizeFleet(f: any): TaskChainFleet {
  return {
    task_chain_id: f.task_chain_id || f.taskChainId || '',
    taskChainId: f.taskChainId || f.task_chain_id || '',
    agent_id: f.agent_id || f.agentId || '',
    agentId: f.agentId || f.agent_id || '',
    capacity: typeof f.capacity === 'number' ? f.capacity : 1,
    active_count: typeof f.active_count === 'number' ? f.active_count : (typeof f.activeCount === 'number' ? f.activeCount : 0),
    activeCount: typeof f.activeCount === 'number' ? f.activeCount : (typeof f.active_count === 'number' ? f.active_count : 0),
    min_warm: typeof f.min_warm === 'number' ? f.min_warm : (typeof f.minWarm === 'number' ? f.minWarm : 0),
    minWarm: typeof f.minWarm === 'number' ? f.minWarm : (typeof f.min_warm === 'number' ? f.min_warm : 0),
    idle_ttl_seconds: typeof f.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : (typeof f.idleTtlSeconds === 'number' ? f.idleTtlSeconds : 600),
    idleTtlSeconds: typeof f.idleTtlSeconds === 'number' ? f.idleTtlSeconds : (typeof f.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : 600),
    provider: f.provider || '',
    tier: f.tier || '',
    created_at: f.created_at || '',
    updated_at: f.updated_at || '',
  };
}

export const taskChainsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getTaskChainFleets: build.query<TaskChainFleet[], { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/fleets`);
          const rawList = Array.isArray(raw) ? raw : (Array.isArray(raw?.data) ? raw.data : []);
          const list = rawList.map(normalizeFleet);
          return { data: list };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [{ type: 'TaskChainFleets' as const, id: chainId }],
    }),

    updateTaskChainFleet: build.mutation<TaskChainFleet, {
      chainId: string;
      agentId: string;
      capacity: number;
      minWarm?: number;
      idleTtlSeconds?: number;
      provider?: string;
      tier?: string;
    }>({
      queryFn: async ({ chainId, agentId, capacity, minWarm, idleTtlSeconds, provider, tier }) => {
        try {
          const body: any = { capacity, provider: provider ?? '', tier: tier ?? '' };
          if (minWarm !== undefined) body.min_warm = minWarm;
          if (idleTtlSeconds !== undefined) body.idle_ttl_seconds = idleTtlSeconds;
          const raw = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/fleets/${encodeURIComponent(agentId)}`,
            'PUT',
            body
          );
          const data = normalizeFleet(raw?.data !== undefined ? raw.data : raw);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'TaskChainFleets' as const, id: chainId },
        { type: 'Chain' as const, id: chainId },
      ],
    }),
  }),
});

export const {
  useGetTaskChainFleetsQuery,
  useLazyGetTaskChainFleetsQuery,
  useUpdateTaskChainFleetMutation,
} = taskChainsApi;
