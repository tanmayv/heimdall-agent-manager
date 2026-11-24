import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type ActionInstanceStrategy = 'reuse' | 'fresh_per_run';
export type PlacementRule = { bridge_id: string; provider: string; model: string };
export type ActionTarget =
  | { kind: 'agent'; agent_id: string; project_id?: string; instance_strategy: ActionInstanceStrategy; selector: string; rules: PlacementRule[]; last_spawned_instance_id?: string }
  | { kind: 'instance'; instance_id: string }
  | { kind: 'bot'; bot_id: string };
export type ScheduleConfig = { mode: 'cron' | 'interval' | 'once'; cron_expr?: string; timezone?: string; interval_s?: number; run_at?: string; blackout_dates?: string[]; active_from?: string; active_until?: string };
export type EventConfig = { event_type: string; chain_id?: string; data?: Record<string, string> };
export type ActionTrigger = ({ kind: 'schedule'; config: ScheduleConfig } | { kind: 'event'; config: EventConfig }) & { id?: string; enabled: boolean; rev?: number; next_fire_at?: string; created_at?: string; updated_at?: string };
export type Action = { id: string; owner_user_id: string; name: string; prompt_text: string; enabled: boolean; min_interval_s: number; target: ActionTarget; triggers: ActionTrigger[]; created_at: string; updated_at: string };
export type CreateActionInput = Pick<Action, 'prompt_text' | 'target'> & Partial<Pick<Action, 'name' | 'enabled' | 'min_interval_s' | 'triggers'>>;
export type PatchActionInput = Partial<CreateActionInput>;
export type TriggerEvent = { event_type: string; label: string; scope: string; data_keys: { key: string; values: string[] }[]; presets: { id: string; label: string; data: Record<string, string> }[] };
export type TriggerTypes = { target_kinds: ActionTarget['kind'][]; schedules_supported: boolean; limits: { max_triggers: number; max_rules: number; min_interval_s: { min: number; max: number; default: number } }; trigger_kinds: { kind: string; label: string; modes?: ScheduleConfig['mode'][]; events?: TriggerEvent[] }[] };
export type PlacementCandidates = { candidates: { bridge_id: string; provider: string; provider_profile: string; model: string; rank: number }[]; bridges: { bridge_id: string; label: string; eligible: boolean; reason: string }[]; providers: { provider: string; label: string; models: string[] }[] };
export type ActionRun = { id: string; trigger_id: string; event_type: string; event_id: string; state: 'queued' | 'deferred' | 'routed' | 'delivered' | 'joined' | 'skipped' | 'failed'; reason: string; not_before: string; joined_run_id: string; joined_count: number; rule_position: number; target_instance_id: string; message_id: string; delivery_id: string; delivery_expires_at: string; delivery_state?: string; delivery_outcome?: string; created_at: string; started_at: string; finished_at: string };

function apiError(error: any): any {
  return { status: error?.status || 'CUSTOM_ERROR', error: String(error?.message || error), data: { code: error?.code, details: error?.details } };
}
async function request<T>(path: string, method?: string, body?: unknown) {
  try { return { data: await (method ? cookieMutation(path, method, body) : cookieJsonFetch(path)) as T }; }
  catch (error) { return { error: apiError(error) }; }
}
const path = (id: string) => '/actions/' + encodeURIComponent(id);
const tags = (id: string) => [{ type: 'Action' as const, id }, { type: 'Actions' as const, id: 'LIST' }];
export const actionsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listActions: build.query<{ actions: Action[] }, void>({
      queryFn: async () => { const result = await request<Action[]>('/actions'); return result.error ? { error: result.error } : { data: { actions: Array.isArray(result.data) ? result.data : (Array.isArray((result.data as any)?.actions) ? (result.data as any).actions : []) } }; },
      providesTags: result => [{ type: 'Actions', id: 'LIST' }, ...(result?.actions || []).map(a => ({ type: 'Action' as const, id: a.id }))],
    }),
    fetchAction: build.query<{ action: Action | null }, { id: string }>({
      queryFn: async ({ id }) => { const result = await request<Action>(path(id)); return result.error ? { error: result.error } : { data: { action: result.data! } }; },
      providesTags: (_r, _e, { id }) => [{ type: 'Action', id }],
    }),
    createAction: build.mutation<{ action: Action }, CreateActionInput>({
      queryFn: async body => { const result = await request<Action>('/actions', 'POST', body); return result.error ? { error: result.error } : { data: { action: result.data! } }; },
      invalidatesTags: [{ type: 'Actions', id: 'LIST' }],
    }),
    patchAction: build.mutation<{ action: Action }, { id: string } & PatchActionInput>({
      queryFn: async ({ id, ...body }) => { const result = await request<Action>(path(id), 'PATCH', body); return result.error ? { error: result.error } : { data: { action: result.data! } }; },
      invalidatesTags: (_r, _e, { id }) => tags(id),
    }),
    deleteAction: build.mutation<{ deleted: boolean }, { id: string }>({
      queryFn: ({ id }) => request(path(id), 'DELETE'),
      invalidatesTags: (_r, _e, { id }) => tags(id),
    }),
    actionTriggerTypes: build.query<TriggerTypes, void>({
      queryFn: () => request('/actions/trigger-types'),
    }),
    actionPlacementCandidates: build.query<PlacementCandidates, { agent_id: string }>({
      queryFn: ({ agent_id }) => request('/placement/candidates?' + new URLSearchParams({ agent_id, feature: 'event_pipeline_v1' })),
    }),
    actionRuns: build.query<ActionRun[], { id: string; before?: string; before_id?: string; limit?: number }>({
      queryFn: ({ id, before, before_id, limit = 50 }) => { const params = new URLSearchParams({ limit: String(limit) }); if (before) params.set('before', before); if (before_id) params.set('before_id', before_id); return request(path(id) + '/runs?' + params); },
      providesTags: (_r, _e, { id }) => [{ type: 'Action', id }],
    }),
    setActionEnabled: build.mutation<{ action: Action }, { id: string; enabled: boolean }>({
      queryFn: async ({ id, enabled }) => { const result = await request<Action>(path(id) + (enabled ? '/enable' : '/disable'), 'POST'); return result.error ? { error: result.error } : { data: { action: result.data! } }; },
      invalidatesTags: (_r, _e, { id }) => tags(id),
    }),
    listAllAgentInstances: build.query<any, void>({
      queryFn: async () => { const result = await request<any>('/agent-instances?limit=200'); return result.error ? { error: result.error } : { data: { instances: Array.isArray(result.data) ? result.data : result.data?.instances || [] } }; },
      providesTags: [{ type: 'AgentInstances', id: 'ALL' }],
    }),
  }),
});
export const { useListActionsQuery, useFetchActionQuery, useCreateActionMutation, usePatchActionMutation, useDeleteActionMutation, useActionTriggerTypesQuery, useActionPlacementCandidatesQuery, useActionRunsQuery, useLazyActionRunsQuery, useSetActionEnabledMutation, useListAllAgentInstancesQuery } = actionsApi;
