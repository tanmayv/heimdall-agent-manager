import { announceTaskChainCreated } from '../taskChainCreationEvents';
import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { encryptVaultText, isVaultArmored, getActiveVaultKey } from '../../utils/vaultContent';
import { decryptChainRecord, decryptChainList } from '../../utils/vaultChains';

export interface FleetRestartResult {
  instance_id: string;
  outcome: 'accepted' | 'unchanged' | 'ineligible' | 'failed';
  message: string;
}

export interface FleetRestartFailure {
  instance_id: string;
  message: string;
}

export type CreateTaskChainInput = {
  title: string;
  description?: string;
  kind?: string;
  coordinatorAgentId?: string;
  bridgeId?: string;
  provider?: string;
  model?: string;
  projectId?: string;
};

export type UpdateTaskChainInput = {
  chainId: string;
  title?: string;
  description?: string;
  status?: string;
  coordinatorAgentInstanceId?: string;
};

export interface TaskChainFleet {
  bridge_models?: Record<string, { provider: string; provider_profile?: string; model: string }>;
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
  provider_profile?: string;
  provider?: string;
  model?: string;
  /** REQ-SCHED-2: the row's one pause switch; no new lease of any kind, live leases continue. */
  paused?: boolean;
  /** Advisory text from a fleet PUT. */
  warning?: string;
  /** What the matcher would apply for this row (hub-resolved, plan REQ-UI-12). */
  effective?: EffectivePlacement | null;
  bridge_id?: string;
  bridgeId?: string;
  // PUT-only additive fields, present when the request carried a well-formed
  // restart_live_instances boolean; absent on fleet list rows.
  restarted_instance_ids?: string[];
  restart_failures?: FleetRestartFailure[];
  restart_results?: FleetRestartResult[];
  created_at?: string;
  updated_at?: string;
}

/**
 * Chain cap (REQ-SCHED-34). `max_parallel` 0 means unlimited; otherwise it is
 * at least 2 and `review_reserve` is between 1 and max_parallel - 1. Same rule
 * as the hub's apply_chain_caps.
 */
export interface ChainCaps {
  maxParallel: number;
  reviewReserve: number;
}

export function readChainCaps(chain: any): ChainCaps {
  const m = Number(chain?.max_parallel ?? 0);
  const r = Number(chain?.review_reserve ?? 0);
  return {
    maxParallel: Number.isInteger(m) && m > 0 ? m : 0,
    reviewReserve: Number.isInteger(r) && r > 0 ? r : 0,
  };
}

/** Returns a message for invalid caps, or '' when the hub would accept them. */
export function chainCapsError({ maxParallel, reviewReserve }: ChainCaps): string {
  if (!Number.isInteger(maxParallel) || !Number.isInteger(reviewReserve)) return 'Use whole numbers.';
  if (maxParallel === 0) return reviewReserve === 0 ? '' : 'A review reserve needs a parallel limit.';
  if (maxParallel < 2) return 'The parallel limit is 0 (unlimited) or at least 2.';
  if (reviewReserve < 1 || reviewReserve > maxParallel - 1) return `The review reserve must be between 1 and ${maxParallel - 1}.`;
  return '';
}

export interface EffectivePlacement {
  provider_profile?: string;
  runtime_error?: string;
  bridge_id: string;
  /** task_pin | fleet | chain_directory | coordinator | none */
  bridge_source: string;
  provider: string;
  model: string;
  /** agent_override | bridge_default | fleet | bridge_override | catalog_default | none */
  model_source: string;
}

export function normalizeFleet(f: any): TaskChainFleet {
  const bridgeId = String(f?.bridge_id ?? f?.bridgeId ?? '');

  return {
    bridge_models: f?.bridge_models || f?.bridgeModels || {},
    task_chain_id: f?.task_chain_id || f?.taskChainId || '',
    taskChainId: f?.taskChainId || f?.task_chain_id || '',
    agent_id: f?.agent_id || f?.agentId || '',
    agentId: f?.agentId || f?.agent_id || '',
    capacity: typeof f?.capacity === 'number' ? f.capacity : 1,
    active_count: typeof f?.active_count === 'number' ? f.active_count : (typeof f?.activeCount === 'number' ? f.activeCount : 0),
    activeCount: typeof f?.activeCount === 'number' ? f.activeCount : (typeof f?.active_count === 'number' ? f.active_count : 0),
    min_warm: typeof f?.min_warm === 'number' ? f.min_warm : (typeof f?.minWarm === 'number' ? f.minWarm : 0),
    minWarm: typeof f?.minWarm === 'number' ? f.minWarm : (typeof f?.min_warm === 'number' ? f.min_warm : 0),
    idle_ttl_seconds: typeof f?.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : (typeof f?.idleTtlSeconds === 'number' ? f.idleTtlSeconds : 600),
    idleTtlSeconds: typeof f?.idleTtlSeconds === 'number' ? f.idleTtlSeconds : (typeof f?.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : 600),
    provider: f?.provider || '',
    provider_profile: f?.provider_profile || f?.provider || '',
    model: f?.model || '',
    bridge_id: bridgeId,
    bridgeId,
    paused: f?.paused === true,
    warning: typeof f?.warning === 'string' && f.warning ? f.warning : undefined,
    effective: f?.effective && typeof f.effective === 'object' ? (f.effective as EffectivePlacement) : null,
    restarted_instance_ids: Array.isArray(f?.restarted_instance_ids)
      ? f.restarted_instance_ids.map((id: any) => String(id))
      : undefined,
    restart_results: Array.isArray(f?.restart_results) ? f.restart_results : undefined,
    restart_failures: Array.isArray(f?.restart_failures)
      ? f.restart_failures.map((entry: any) => ({
          instance_id: String(entry?.instance_id || ''),
          message: String(entry?.message || ''),
        }))
      : undefined,
    created_at: f?.created_at || '',
    updated_at: f?.updated_at || '',
  };
}

export const taskChainsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // Per-agent + chain-total token usage (T10). Raw hub payload; normalized by
    // components/taskchain/chainTokenUsageModel.ts. Refreshed by the instance
    // token_usage_changed event (wsInvalidation.ts).
    getTaskChainTokenUsage: build.query<unknown, { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          return { data: await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/token-usage`) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [{ type: 'ChainTokenUsage' as const, id: chainId }],
    }),

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
      min_warm?: number;
      idleTtlSeconds?: number;
      idle_ttl_seconds?: number;
      provider_profile?: string;
      provider?: string;
      model?: string;
      bridgeId?: string;
      bridge_id?: string;
      /** Ask the hub to relaunch this row's live instances with the new provider/model. */
      restartLiveInstances?: boolean;
      bridgeModels?: Record<string, { provider: string; provider_profile?: string; model: string }>;
      bridge_models?: Record<string, { provider: string; provider_profile?: string; model: string }>;
    }>({
      queryFn: async ({
        chainId,
        agentId,
        capacity,
        minWarm,
        min_warm,
        idleTtlSeconds,
        idle_ttl_seconds,
        provider,
        provider_profile,
        model,
        bridgeId,
        bridge_id,
        restartLiveInstances,
        bridgeModels,
        bridge_models,
      }) => {
        try {
          const body: any = { capacity };
          if (provider !== undefined) body.provider = provider;
          if (model !== undefined) body.model = model;
          if (provider_profile !== undefined) body.provider_profile = provider_profile;
          const resolvedBridgeModels = bridgeModels ?? bridge_models;
          if (resolvedBridgeModels !== undefined) body.bridge_models = resolvedBridgeModels;
          const resolvedMinWarm = minWarm ?? min_warm;
          if (resolvedMinWarm !== undefined) body.min_warm = resolvedMinWarm;
          const resolvedIdleTtl = idleTtlSeconds ?? idle_ttl_seconds;
          if (resolvedIdleTtl !== undefined) body.idle_ttl_seconds = resolvedIdleTtl;
          const resolvedBridgeId = bridgeId !== undefined ? bridgeId : bridge_id;
          if (resolvedBridgeId !== undefined) body.bridge_id = resolvedBridgeId;
          // Only a true flag reaches the wire: flag-less bodies stay byte-identical
          // to the pre-restart request shape.
          if (restartLiveInstances === true) body.restart_live_instances = true;
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

    // REQ-SCHED-2: pause and resume take no body; the whole row is paused.
    setTaskChainStaffingPaused: build.mutation<TaskChainFleet, { chainId: string; agentId: string; paused: boolean }>({
      queryFn: async ({ chainId, agentId, paused }) => {
        try {
          const raw = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/fleets/${encodeURIComponent(agentId)}/${paused ? 'pause' : 'resume'}`, 'POST');
          return { data: normalizeFleet(raw?.data !== undefined ? raw.data : raw) };
        }
        catch (error: any) { return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any }; }
      },
      invalidatesTags: (_r, _e, { chainId }) => [{ type: 'TaskChainFleets', id: chainId }, { type: 'Attention', id: 'ALL' }],
    }),
    deleteTaskChainFleet: build.mutation<{ deleted: boolean; removed?: boolean }, { chainId: string; agentId: string }>({
      queryFn: async ({ chainId, agentId }) => {
        try {
          const raw = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/fleets/${encodeURIComponent(agentId)}`,
            'DELETE'
          );
          const data = raw?.data !== undefined ? raw.data : raw;
          return { data: { deleted: Boolean(data?.deleted ?? true), removed: Boolean(data?.removed ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'TaskChainFleets' as const, id: chainId },
        { type: 'Chain' as const, id: chainId },
      ],
    }),

    // REQ-SCHED-34: chain cap. Only the keys given are sent; the hub validates
    // with the same rule as chainCapsError.
    updateTaskChainCaps: build.mutation<any, { chainId: string; maxParallel?: number; reviewReserve?: number }>({
      queryFn: async ({ chainId, maxParallel, reviewReserve }) => {
        try {
          const body: Record<string, number> = {};
          if (maxParallel !== undefined) body.max_parallel = maxParallel;
          if (reviewReserve !== undefined) body.review_reserve = reviewReserve;
          const raw = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}`, 'PATCH', body);
          return { data: raw?.data !== undefined ? raw.data : raw };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'TaskChainFleets' as const, id: chainId },
      ],
    }),

    getTaskChain: build.query<any, { chainId: string } | string>({
      queryFn: async (arg, api) => {
        const chainId = typeof arg === 'string' ? arg : arg?.chainId;
        if (!chainId) return { data: null };
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}`);
          let data = raw?.data ?? raw;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && data) {
            data = await decryptChainRecord(data, activeKey);
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const chainId = typeof arg === 'string' ? arg : arg?.chainId;
        return [{ type: 'Chain' as const, id: chainId }];
      },
    }),

    getTaskChains: build.query<any, { projectId?: string; hasTasks?: boolean; includeArchived?: boolean; pinned?: boolean } | void>({
      queryFn: async (arg, api) => {
        try {
          const options = typeof arg === 'object' && arg !== null ? arg : undefined;
          const params = new URLSearchParams();
          if (options?.projectId) params.set('project_id', options.projectId);
          if (options?.hasTasks) params.set('has_tasks', '1');
          if (options?.includeArchived) params.set('include_archived', '1');
          if (options?.pinned) params.set('pinned', '1');
          const qs = params.toString();
          const raw = await cookieJsonFetch(`/task-chains${qs ? `?${qs}` : ''}`);
          let data = raw?.data ?? raw;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && Array.isArray(data)) {
            data = await decryptChainList(data, activeKey);
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Chain' as const, id: 'LIST' }],
    }),

    createTaskChain: build.mutation<any, CreateTaskChainInput>({
      queryFn: async (payload, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let title = payload.title;
          let description = payload.description || '';

          if (isUnlocked && activeKey) {
            if (!isVaultArmored(title)) {
              title = await encryptVaultText(title, activeKey);
            }
            if (description && !isVaultArmored(description)) {
              description = await encryptVaultText(description, activeKey);
            }
          }

          const body: any = {
            title,
            description,
            kind: payload.kind || 'team_work',
          };
          if (payload.coordinatorAgentId) body.coordinator_agent_id = payload.coordinatorAgentId;
          if (payload.bridgeId) body.bridge_id = payload.bridgeId;
          if (payload.provider) body.provider = payload.provider;
          if (payload.model) body.model = payload.model;
          if (payload.projectId) body.project_id = payload.projectId;

          const data = await cookieMutation('/task-chains', 'POST', body);
          announceTaskChainCreated(String(data?.chain_id || data?.chainId || ''));
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: ['ChainList', { type: 'Chain' as const }],
    }),

    updateTaskChain: build.mutation<any, UpdateTaskChainInput>({
      queryFn: async ({ chainId, title, description, status, coordinatorAgentInstanceId }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          const body: any = {};
          if (title !== undefined) {
            body.title =
              isUnlocked && activeKey && !isVaultArmored(title)
                ? await encryptVaultText(title, activeKey)
                : title;
          }
          if (description !== undefined) {
            body.description =
              isUnlocked && activeKey && description && !isVaultArmored(description)
                ? await encryptVaultText(description, activeKey)
                : description;
          }
          if (status !== undefined) body.status = status;
          if (coordinatorAgentInstanceId !== undefined) {
            body.coordinator_agent_instance_id = coordinatorAgentInstanceId;
          }

          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain', id: chainId },
        'ChainList',
        { type: 'Chain' as const, id: 'GROUPED_LIST' },
        { type: 'Chain' as const, id: 'PINNED_LIST' },
      ],
    }),

    listFlatTaskChains: build.query<any, { includeArchived?: boolean } | void>({
      queryFn: async (arg, api) => {
        try {
          const options = typeof arg === 'object' && arg !== null ? arg : undefined;
          const params = new URLSearchParams();
          params.set('flat', '1');
          if (options?.includeArchived) params.set('include_archived', '1');
          const qs = params.toString();
          const raw = await cookieJsonFetch(`/task-chains?${qs}`);
          let data = raw?.data ?? raw;
          const state: any = api.getState();
          const activeKey = getActiveVaultKey();
          if (state?.vault?.isUnlocked && activeKey) {
            if (Array.isArray(data)) {
              data = await decryptChainList(data, activeKey);
            } else if (Array.isArray(data?.chains)) {
              data = { ...data, chains: await decryptChainList(data.chains, activeKey) };
            }
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'ChainList' as const, id: 'FLAT' }, { type: 'Chain' as const, id: 'LIST' }],
    }),
  }),
});

export const {
  useUpdateTaskChainCapsMutation,
  useGetTaskChainQuery,
  useGetTaskChainFleetsQuery,
  useLazyGetTaskChainFleetsQuery,
  useGetTaskChainTokenUsageQuery,
  useUpdateTaskChainFleetMutation,
  useDeleteTaskChainFleetMutation,
  useListFlatTaskChainsQuery,
} = taskChainsApi;
