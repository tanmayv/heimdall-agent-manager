import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type ShellSessionKind = 'agent' | 'interactive' | 'server' | 'command';
export type ShellSessionStatus = 'starting' | 'running' | 'exited' | 'killed' | 'failed';

export type ShellSession = {
  session_id: string;
  bridge_id: string;
  project_id: string;
  chain_id: string;
  agent_instance_id: string;
  kind: ShellSessionKind;
  status: ShellSessionStatus;
  label: string;
  cmd: string;
  cwd: string;
  pid: number;
  exit_code: number | null;
  exit_code_set: boolean;
  server_port: number;
  preview_enabled: boolean;
  tee_path: string;
  started_at: string;
  last_activity_at: string;
};

export type ShellSessionPage = {
  sessions: ShellSession[];
  next_cursor: string;
  has_more: boolean;
};

export type ShellLogResponse = {
  session_id: string;
  lines: string[];
  offset: number;
  total: number;
};

export type ShellPreviewTokenResponse = {
  token: string;
  preview_url: string;
};

type ListShellsArgs = {
  chainId?: string;
  bridgeId?: string;
  projectId?: string;
  status?: ShellSessionStatus;
  cursor?: string;
};

type CreateShellArgs = {
  bridgeId: string;
  kind: ShellSessionKind;
  cmd?: string;
  cwd?: string;
  label?: string;
  server_port?: number;
  chain_id?: string;
};

type ShellSignalArgs = { sessionId: string; signal: number };
type ShellLogArgs = { sessionId: string; offset?: number; limit?: number; grep?: string };

export const shellsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listShells: build.query<ShellSessionPage, ListShellsArgs>({
      queryFn: async ({ chainId, bridgeId, projectId, status, cursor }) => {
        try {
          const qs = new URLSearchParams();
          if (chainId) qs.set('chain_id', chainId);
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (projectId) qs.set('project_id', projectId);
          if (status) qs.set('status', status);
          if (cursor) qs.set('cursor', cursor);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`/shells${suffix}`);
          const sessions: ShellSession[] = Array.isArray(data)
            ? data
            : (Array.isArray(data?.sessions) ? data.sessions : []);
          return {
            data: {
              sessions,
              next_cursor: data?.next_cursor ?? '',
              has_more: data?.has_more ?? false,
            },
          };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _err, arg) => [
        { type: 'ShellSessions' as const, id: arg.chainId || 'LIST' },
        { type: 'ShellSessions' as const, id: 'LIST' },
      ],
    }),

    getShellSession: build.query<ShellSession, { sessionId: string }>({
      queryFn: async ({ sessionId }) => {
        try {
          const data = await cookieJsonFetch(`/shells/${encodeURIComponent(sessionId)}`);
          const session: ShellSession = data?.session ?? data;
          return { data: session };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _err, { sessionId }) => [
        { type: 'ShellSession' as const, id: sessionId },
      ],
    }),

    createShell: build.mutation<ShellSession, CreateShellArgs>({
      queryFn: async ({ bridgeId, ...body }) => {
        try {
          const data = await cookieMutation(
            `/bridges/${encodeURIComponent(bridgeId)}/shells`,
            'POST',
            body,
          );
          const session: ShellSession = data?.session ?? data;
          return { data: session };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'ShellSessions' as const, id: 'LIST' }],
    }),

    killShell: build.mutation<void, { sessionId: string }>({
      queryFn: async ({ sessionId }) => {
        try {
          await cookieMutation(`/shells/${encodeURIComponent(sessionId)}`, 'DELETE', undefined);
          return { data: undefined };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _err, { sessionId }) => [
        { type: 'ShellSession' as const, id: sessionId },
        { type: 'ShellSessions' as const, id: 'LIST' },
      ],
    }),

    restartShell: build.mutation<ShellSession, { sessionId: string }>({
      queryFn: async ({ sessionId }) => {
        try {
          const data = await cookieMutation(
            `/shells/${encodeURIComponent(sessionId)}/restart`,
            'POST',
            undefined,
          );
          const session: ShellSession = data?.session ?? data;
          return { data: session };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _err, { sessionId }) => [
        { type: 'ShellSession' as const, id: sessionId },
        { type: 'ShellSessions' as const, id: 'LIST' },
      ],
    }),

    signalShell: build.mutation<void, ShellSignalArgs>({
      queryFn: async ({ sessionId, signal }) => {
        try {
          await cookieMutation(
            `/shells/${encodeURIComponent(sessionId)}/signal`,
            'POST',
            { signal },
          );
          return { data: undefined };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),

    getShellLog: build.query<ShellLogResponse, ShellLogArgs>({
      queryFn: async ({ sessionId, offset = 0, limit = 100, grep }) => {
        try {
          const qs = new URLSearchParams();
          qs.set('offset', String(offset));
          qs.set('limit', String(limit));
          if (grep) qs.set('grep', grep);
          const data = await cookieJsonFetch(
            `/shells/${encodeURIComponent(sessionId)}/log?${qs.toString()}`,
          );
          return {
            data: {
              session_id: sessionId,
              lines: data?.lines ?? (Array.isArray(data) ? data : []),
              offset: data?.offset ?? offset,
              total: data?.total ?? 0,
            },
          };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),

    getShellPreviewToken: build.mutation<ShellPreviewTokenResponse, { sessionId: string }>({
      queryFn: async ({ sessionId }) => {
        try {
          const data = await cookieMutation(
            `/shells/${encodeURIComponent(sessionId)}/preview-token`,
            'POST',
            undefined,
          );
          return { data: { token: data?.token ?? '', preview_url: data?.preview_url ?? '' } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

export const {
  useListShellsQuery,
  useGetShellSessionQuery,
  useCreateShellMutation,
  useKillShellMutation,
  useRestartShellMutation,
  useSignalShellMutation,
  useGetShellLogQuery,
  useGetShellPreviewTokenMutation,
} = shellsApi;
