import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

export function normalizeChain(chain: any) {
  return {
    id: chain.chain_id || chain.chainId || chain.id || '',
    chainId: chain.chain_id || chain.chainId || chain.id || '',
    title: chain.title || '',
    description: chain.description || '',
    status: chain.status || 'active',
    projectId: chain.project_id || chain.projectId || '',
    vcsWorkspaceId: chain.vcs_workspace_id || chain.vcsWorkspaceId || '',
    diffBaseSha: chain.diff_base_sha || chain.diffBaseSha || '',
    repoDiffSupported: Boolean(chain.repo_diff_supported || chain.repoDiffSupported),
    teamId: chain.team_id || chain.teamId || '',
    coordinatorAgentInstanceId: chain.coordinator_agent_instance_id || chain.coordinatorAgentInstanceId || '',
    defaultReviewerAgentInstanceId: chain.default_reviewer_agent_instance_id || chain.defaultReviewerAgentInstanceId || '',
    finalSummary: chain.final_summary || chain.finalSummary || '',
    createdAtUnixMs: Number(chain.created_at_unix_ms || chain.createdAtUnixMs || 0),
    completedAtUnixMs: Number(chain.completed_at_unix_ms || chain.completedAtUnixMs || 0),
    archivePending: Boolean(chain.archive_pending || chain.archivePending),
    archived: Boolean(chain.archived),
    evaluation: chain.evaluation || 'unreviewed',
  };
}

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

export const workspaceApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listChains: build.query<any, { createdAfter?: number; createdBefore?: number } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { chains: [] };
        const args = (arg && typeof arg === 'object') ? arg : {};
        const data = await daemonApi.listTaskChains({
          ...auth(session),
          createdAfter: args.createdAfter,
          createdBefore: args.createdBefore,
        });
        return { chains: (data.chains || []).map(normalizeChain) };
      }),
      providesTags: (result) => [
        { type: 'ChainList' as const, id: 'ALL' },
        ...((result?.chains || []).map((chain: any) => ({ type: 'Chain' as const, id: chain.chainId })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchChain: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chain: null };
        const data = await daemonApi.fetchTaskChain({ ...auth(session), chainId });
        return { chain: data?.chain ? normalizeChain(data.chain) : null };
      }),
      providesTags: (_result, _error, { chainId }) => [{ type: 'Chain' as const, id: chainId }],
    }),
    focusChain: build.mutation<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { ok: false, message: 'Missing chain' };
        return daemonApi.focusTaskChain({ ...auth(session), chainId });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain' as const, id: chainId }],
    }),
    updateChain: build.mutation<any, { chainId: string; title?: string; description?: string; coordinatorAgentInstanceId?: string; defaultReviewerAgentInstanceId?: string; finalSummary?: string }>({
      queryFn: withSessionQuery(async ({ chainId, title, description, coordinatorAgentInstanceId, defaultReviewerAgentInstanceId, finalSummary }, { session }) => {
        if (!session?.clientToken || !chainId) return { ok: false, message: 'Missing chain' };
        return daemonApi.updateTaskChain({ ...auth(session), chainId, title, description, coordinatorAgentInstanceId, defaultReviewerAgentInstanceId, finalSummary });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    updateChainStatus: build.mutation<any, { chainId: string; status: string; finalSummary?: string }>({
      queryFn: withSessionQuery(async ({ chainId, status, finalSummary }, { session }) => {
        if (!session?.clientToken || !chainId) return { ok: false, message: 'Missing chain' };
        return daemonApi.updateTaskChainStatus({ ...auth(session), chainId, status, finalSummary });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    fetchTeam: build.query<any, { teamId: string }>({
      queryFn: withSessionQuery(async ({ teamId }, { session }) => {
        if (!session?.daemonUrl || !teamId) return { teamId, team: null };
        const data = await daemonApi.fetchTeam({ daemonUrl: session.daemonUrl, teamId });
        return { teamId, team: data?.team || data || null };
      }),
      providesTags: (_result, _error, { teamId }) => [{ type: 'Team' as const, id: teamId }],
    }),
    addTeamMember: build.mutation<any, { teamId: string; roleKey: string; agentInstanceId: string }>({
      queryFn: withSessionQuery(async ({ teamId, roleKey, agentInstanceId }, { session }) => {
        if (!session?.clientToken || !teamId || !agentInstanceId) return { ok: false, message: 'Missing team member' };
        return daemonApi.addTeamMember({ ...auth(session), teamId, roleKey, agentInstanceId });
      }),
      invalidatesTags: (_result, _error, { teamId }) => [{ type: 'Team' as const, id: teamId }],
    }),
    fetchWorkspace: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, workspace: null };
        const data = await daemonApi.fetchWorkspace({ ...auth(session), chainId });
        return { chainId, workspace: data?.workspace || null };
      }),
      providesTags: (_result, _error, { chainId }) => [{ type: 'Workspace' as const, id: chainId }],
    }),
    previewWorkspaceMerge: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, preview: null };
        const preview = await daemonApi.previewWorkspaceMerge({ ...auth(session), chainId }).catch((err: any) => ({ ok: false, message: err?.message || 'preview failed' }));
        return { chainId, preview };
      }),
      providesTags: (_result, _error, { chainId }) => [{ type: 'Workspace' as const, id: chainId }],
    }),
    fetchWorkspaceDiff: build.query<any, { chainId: string; file?: string }>({
      queryFn: withSessionQuery(async ({ chainId, file = '' }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, file, diff: null };
        const diff = await daemonApi.fetchWorkspaceDiff({ ...auth(session), chainId, file }).catch(() => null);
        return { chainId, file, diff };
      }),
      providesTags: (_result, _error, { chainId, file = '' }) => [{ type: 'WorkspaceDiff' as const, id: `${chainId}:${file}` }],
    }),
  }),
});

export const {
  useListChainsQuery,
  useFetchChainQuery,
  useFocusChainMutation,
  useUpdateChainMutation,
  useUpdateChainStatusMutation,
  useFetchTeamQuery,
  useAddTeamMemberMutation,
  useFetchWorkspaceQuery,
  usePreviewWorkspaceMergeQuery,
  useLazyPreviewWorkspaceMergeQuery,
  useFetchWorkspaceDiffQuery,
  useLazyFetchWorkspaceDiffQuery,
} = workspaceApi;
