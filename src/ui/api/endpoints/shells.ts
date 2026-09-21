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
  // Total number of lines in the session's log file. The hub sends this as
  // `total_lines` (src/hub/transport/http/shell_session_rest_handlers.odin), which is
  // why the mapping below reads that key first. Note it counts the WHOLE file and is
  // not affected by `grep`, while `offset` indexes post-grep lines — so callers must
  // not derive an offset from `total` while a grep filter is active.
  total: number;
  truncated: boolean;
  // Echo of the `limit` this response was requested with, so a caller can tell which
  // window a cached response describes (the viewer uses it to discard its cheap
  // one-line probe instead of painting it).
  limit: number;
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

export interface GetShellPaneArgs {
  sessionId: string;
  sinceHash?: string;
  width?: number;
  lineLimit?: number;
}

// Same payload shape the agent pane returns (see AgentPaneResult): on unchanged the
// bridge omits output entirely rather than resending the screen.
export interface ShellPaneResult {
  ok?: boolean;
  status?: string;
  unchanged?: boolean;
  hash?: string;
  output?: string;
  line_count?: number;
  truncated?: boolean;
  [key: string]: any;
}

type ShellSignalArgs = { sessionId: string; signal: number };
type ShellLogArgs = { sessionId: string; offset?: number; limit?: number; grep?: string };

// The bridge terminates every emitted line with a newline and the hub then splits that
// buffer on '\n' (src/bridge/hub_runtime_client.odin, shell_logs_result), so the array
// always ends in one empty string that is a line *terminator*, not a line — and an empty
// log arrives as [""] rather than []. Left in place it shifts every window by one: a tail
// view would push the newest line out of the page, and "No log output yet." would never
// show. Only the single trailing element is dropped, so blank lines inside the log
// survive.
function normalizeLogLines(lines: string[]): string[] {
  if (lines.length > 0 && lines[lines.length - 1] === '') return lines.slice(0, -1);
  return lines;
}

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

    // XM-9: declare (or clear, with server_port 0) the port of a session that is
    // already running. Invalidates the same tags restartShell does, because the
    // reachability of the row changes with it and both views read server_port.
    setShellPort: build.mutation<ShellSession, { sessionId: string; server_port: number }>({
      queryFn: async ({ sessionId, server_port }) => {
        try {
          const data = await cookieMutation(
            `/shells/${encodeURIComponent(sessionId)}/port`,
            'POST',
            { server_port },
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

    getShellPane: build.query<ShellPaneResult, GetShellPaneArgs>({
      queryFn: async ({ sessionId, sinceHash, width = 80, lineLimit = 120 }) => {
        if (!sessionId) {
          return { data: { ok: false, unchanged: true, hash: '', output: '' } };
        }
        try {
          const path = `/shells/${encodeURIComponent(sessionId)}/pane?since_hash=${encodeURIComponent(sinceHash || '')}&width=${width || 80}&line_limit=${lineLimit || 120}`;
          const data = await cookieJsonFetch(path);
          return { data: data || {} };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      serializeQueryArgs: ({ endpointName, queryArgs }) => {
        return `${endpointName}-${queryArgs.sessionId}-${queryArgs.width || 80}-${queryArgs.lineLimit || 120}`;
      },
      // An unchanged reply carries no output; keep the last rendered screen in cache so the
      // consumer sees a referentially identical value and skips the repaint entirely.
      merge: (currentCache, newItems) => {
        if (newItems?.unchanged && currentCache?.output !== undefined) {
          return {
            ...currentCache,
            ...newItems,
            output: currentCache.output,
            line_count: currentCache.line_count ?? newItems.line_count,
            truncated: currentCache.truncated ?? newItems.truncated,
          };
        }
        return newItems;
      },
      providesTags: (_result, _error, { sessionId }) => [
        { type: 'ShellSession' as const, id: `${sessionId}:PANE` },
      ],
    }),

    sendShellInput: build.mutation<{ ok?: boolean; [key: string]: any }, { sessionId: string; data: string }>({
      queryFn: async ({ sessionId, data }) => {
        if (!sessionId) {
          return { error: { status: 'CUSTOM_ERROR', error: 'Missing sessionId' } as any };
        }
        try {
          const res = await cookieMutation(`/shells/${encodeURIComponent(sessionId)}/input`, 'POST', { data });
          return { data: res || { ok: true } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),

    sendShellResize: build.mutation<{ ok?: boolean; [key: string]: any }, { sessionId: string; rows: number; cols: number }>({
      queryFn: async ({ sessionId, rows, cols }) => {
        if (!sessionId) {
          return { error: { status: 'CUSTOM_ERROR', error: 'Missing sessionId' } as any };
        }
        try {
          const res = await cookieMutation(`/shells/${encodeURIComponent(sessionId)}/resize`, 'POST', { rows, cols });
          return { data: res || { ok: true } };
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
              lines: normalizeLogLines(data?.lines ?? (Array.isArray(data) ? data : [])),
              offset: data?.offset ?? offset,
              total: data?.total_lines ?? data?.total ?? 0,
              truncated: Boolean(data?.truncated),
              limit,
            },
          };
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
  useSetShellPortMutation,
  useSignalShellMutation,
  useGetShellLogQuery,
  useGetShellPaneQuery,
  useLazyGetShellPaneQuery,
  useSendShellInputMutation,
  useSendShellResizeMutation,
} = shellsApi;
