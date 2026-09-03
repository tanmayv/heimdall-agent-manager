import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type ActionState = 'active' | 'in_flight' | 'completed';

export type Action = {
  id: string;
  owner_user_id: string;
  target_instance_id: string;
  prompt_text: string;
  cron_expr?: string;
  timezone?: string;
  blackout_dates?: string[] | string;
  active_from?: string;
  active_until?: string;
  target_run_at?: string;
  interval?: string;
  state: ActionState;
  in_flight: boolean;
  leased_at?: string;
  created_at: string;
  updated_at: string;
};

export type CreateActionInput = {
  target_instance_id: string;
  prompt_text: string;
  cron_expr?: string;
  timezone?: string;
  blackout_dates?: string[] | string;
  active_from?: string;
  active_until?: string;
  target_run_at?: string;
  interval?: string;
};

export type PatchActionInput = {
  prompt_text?: string;
  cron_expr?: string;
  timezone?: string;
  blackout_dates?: string[] | string;
  active_from?: string;
  active_until?: string;
  target_run_at?: string;
  interval?: string;
  state?: ActionState;
};

export function parseBlackoutDates(blackoutDates?: string[] | string | null): string[] {
  if (!blackoutDates) return [];
  if (Array.isArray(blackoutDates)) return blackoutDates;
  try {
    const parsed = JSON.parse(blackoutDates);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_err) {
    return [];
  }
}

function normalizePayload<T extends { blackout_dates?: string[] | string }>(input: T): any {
  const result: any = { ...input };
  if (result.blackout_dates !== undefined) {
    if (Array.isArray(result.blackout_dates)) {
      result.blackout_dates = JSON.stringify(result.blackout_dates);
    } else if (typeof result.blackout_dates === 'string' && !result.blackout_dates.startsWith('[')) {
      result.blackout_dates = JSON.stringify([result.blackout_dates]);
    }
  }
  return result;
}

export const actionsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listActions: build.query<{ actions: Action[] }, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/actions');
          const actions: Action[] = Array.isArray(data)
            ? data
            : (Array.isArray(data?.data) ? data.data : (data?.actions || []));
          return { data: { actions } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (result) => [
        { type: 'Actions' as const, id: 'LIST' },
        ...((result?.actions || []).map((action) => ({ type: 'Action' as const, id: action.id }))),
      ],
    }),

    fetchAction: build.query<{ action: Action | null }, { id: string }>({
      queryFn: async ({ id }) => {
        if (!id) return { data: { action: null } };
        try {
          const data = await cookieJsonFetch(`/actions/${encodeURIComponent(id)}`);
          const action = data?.data || data?.action || data || null;
          return { data: { action } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { id }) => [{ type: 'Action' as const, id }],
    }),

    createAction: build.mutation<{ action: Action }, CreateActionInput>({
      queryFn: async (payload) => {
        try {
          const body = normalizePayload(payload);
          const data = await cookieMutation('/actions', 'POST', body);
          const action = data?.data || data?.action || data;
          return { data: { action } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Actions' as const, id: 'LIST' }],
    }),

    patchAction: build.mutation<{ action: Action }, { id: string } & PatchActionInput>({
      queryFn: async ({ id, ...payload }) => {
        try {
          const body = normalizePayload(payload);
          const data = await cookieMutation(`/actions/${encodeURIComponent(id)}`, 'PATCH', body);
          const action = data?.data || data?.action || data;
          return { data: { action } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Actions' as const, id: 'LIST' },
        { type: 'Action' as const, id },
      ],
    }),

    deleteAction: build.mutation<{ deleted: boolean }, { id: string }>({
      queryFn: async ({ id }) => {
        try {
          const data = await cookieMutation(`/actions/${encodeURIComponent(id)}`, 'DELETE');
          return { data: { deleted: Boolean(data?.deleted ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Actions' as const, id: 'LIST' },
        { type: 'Action' as const, id },
      ],
    }),

    runAction: build.mutation<any, { id: string }>({
      queryFn: async ({ id }) => {
        try {
          const data = await cookieMutation(`/actions/${encodeURIComponent(id)}/run`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { id }) => [
        { type: 'Action' as const, id },
        { type: 'Actions' as const, id: 'LIST' },
      ],
    }),

    listAllAgentInstances: build.query<any, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/agent-instances?limit=200');
          const instances = Array.isArray(data) ? data : (data?.data || []);
          return { data: { instances } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'AgentInstances' as const, id: 'ALL' }],
    }),
  }),
});

export const {
  useListActionsQuery,
  useFetchActionQuery,
  useCreateActionMutation,
  usePatchActionMutation,
  useDeleteActionMutation,
  useRunActionMutation,
  useListAllAgentInstancesQuery,
} = actionsApi;
