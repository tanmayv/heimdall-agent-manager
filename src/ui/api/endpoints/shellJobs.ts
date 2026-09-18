import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';

// A background shell job the bridge ran locally on behalf of an agent (REQ-13/14/15).
// The hub stores STATUS/metadata only — command output stays on the bridge host and
// is never returned here.
export type ShellJobStatus = 'running' | 'completed' | 'failed';

export type ShellJob = {
  exec_id: string;
  agent_instance_id: string;
  cmd: string;
  status: ShellJobStatus;
  started_at: string;
  finished_at?: string;
  created_at: string;
  exit_code?: number;
};

type ListShellJobsArgs = { instanceId: string; status?: ShellJobStatus; cursor?: string };
type FetchShellJobOutputArgs = { instanceId: string; execId: string };
export type ShellJobOutput = { output: string; truncated: boolean; exec_id: string };

function base(instanceId: string): string {
  return `/agent-instances/${encodeURIComponent(instanceId)}/shell-jobs`;
}

export type ShellJobPage = { jobs: ShellJob[]; next_cursor: string; has_more: boolean };

export const shellJobsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listShellJobs: build.query<ShellJobPage, ListShellJobsArgs>({
      queryFn: async ({ instanceId, status, cursor }) => {
        try {
          if (!instanceId) return { data: { jobs: [], next_cursor: '', has_more: false } };
          const qs = new URLSearchParams();
          if (status) qs.set('status', status);
          if (cursor) qs.set('cursor', cursor);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(instanceId)}${suffix}`);
          const jobs: ShellJob[] = Array.isArray(data)
            ? data
            : (Array.isArray(data?.data) ? data.data : (data?.jobs || []));
          return { data: { jobs, next_cursor: data?.next_cursor ?? '', has_more: data?.has_more ?? false } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
    fetchShellJobOutput: build.query<ShellJobOutput, FetchShellJobOutputArgs>({
      queryFn: async ({ instanceId, execId }) => {
        try {
          if (!instanceId || !execId) return { error: { status: 'CUSTOM_ERROR', error: 'missing instanceId or execId' } as any };
          const data = await cookieJsonFetch(`/agent-instances/${encodeURIComponent(instanceId)}/shell-jobs/${encodeURIComponent(execId)}/output`);
          const result: ShellJobOutput = {
            output: data?.output ?? '',
            truncated: data?.truncated ?? false,
            exec_id: data?.exec_id ?? execId,
          };
          return { data: result };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

export const {
  useListShellJobsQuery,
  useLazyListShellJobsQuery,
  useFetchShellJobOutputQuery,
} = shellJobsApi;
