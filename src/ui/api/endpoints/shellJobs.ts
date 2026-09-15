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

type ListShellJobsArgs = { instanceId: string; status?: ShellJobStatus };

function base(instanceId: string): string {
  return `/agent-instances/${encodeURIComponent(instanceId)}/shell-jobs`;
}

export const shellJobsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listShellJobs: build.query<{ jobs: ShellJob[] }, ListShellJobsArgs>({
      queryFn: async ({ instanceId, status }) => {
        try {
          if (!instanceId) return { data: { jobs: [] } };
          const qs = new URLSearchParams();
          if (status) qs.set('status', status);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(instanceId)}${suffix}`);
          const jobs: ShellJob[] = Array.isArray(data)
            ? data
            : (Array.isArray(data?.data) ? data.data : (data?.jobs || []));
          return { data: { jobs } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

export const { useListShellJobsQuery, useLazyListShellJobsQuery } = shellJobsApi;
