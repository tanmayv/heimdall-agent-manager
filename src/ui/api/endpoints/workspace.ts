import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

export function normalizeChain(chain: any) {
  const result: any = {
    id: chain.chain_id || chain.chainId || chain.id || '',
    chainId: chain.chain_id || chain.chainId || chain.id || '',
    title: chain.title || '',
    status: chain.status || 'active',
    projectId: chain.project_id || chain.projectId || '',
    vcsWorkspaceId: chain.vcs_workspace_id || chain.vcsWorkspaceId || '',
    diffBaseSha: chain.diff_base_sha || chain.diffBaseSha || '',
    repoDiffSupported: Boolean(chain.repo_diff_supported || chain.repoDiffSupported),
    coordinatorAgentInstanceId: chain.coordinator_agent_instance_id || chain.coordinatorAgentInstanceId || '',
    defaultReviewerAgentInstanceId: chain.default_reviewer_agent_instance_id || chain.defaultReviewerAgentInstanceId || '',
    createdAtUnixMs: Number(chain.created_at_unix_ms || chain.createdAtUnixMs || 0),
    completedAtUnixMs: Number(chain.completed_at_unix_ms || chain.completedAtUnixMs || 0),
    archivePending: Boolean(chain.archive_pending || chain.archivePending),
    archived: Boolean(chain.archived),
    evaluation: chain.evaluation || 'unreviewed',
  };
  if (chain.description !== undefined) {
    result.description = chain.description;
  }
  const summary = chain.final_summary !== undefined ? chain.final_summary : chain.finalSummary;
  if (summary !== undefined) {
    result.finalSummary = summary;
  }
  return result;
}

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

export const workspaceApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listChains: build.query<any, { createdAfter?: number; createdBefore?: number; limit?: number; offset?: number; status?: string } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { chains: [], totalCount: 0, hasMore: false, offset: 0 };
        const args = (arg && typeof arg === 'object') ? arg : {};
        const limit = args.limit ?? 10000;
        const offset = args.offset ?? 0;
        const status = args.status;
        const data = await daemonApi.listTaskChains({
          ...auth(session),
          createdAfter: args.createdAfter,
          createdBefore: args.createdBefore,
          limit,
          offset,
          status,
        });
        const chains = (data.chains || []).map(normalizeChain);
        const totalCount = data.total_count || 0;
        const hasMore = offset + chains.length < totalCount;
        return { chains, totalCount, hasMore, offset };
      }),
      providesTags: (result, _error, arg) => [
        { type: 'ChainList' as const, id: JSON.stringify(arg || {}) },
        ...((result?.chains || []).map((chain: any) => ({ type: 'Chain' as const, id: chain.chainId })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchChainsPage: build.query<any, { createdAfter?: number; createdBefore?: number; limit: number; offset: number; status?: string }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { chains: [], totalCount: 0, hasMore: false, offset: 0 };
        const data = await daemonApi.listTaskChains({
          ...auth(session),
          createdAfter: arg.createdAfter,
          createdBefore: arg.createdBefore,
          limit: arg.limit,
          offset: arg.offset,
          status: arg.status,
        });
        const chains = (data.chains || []).map(normalizeChain);
        const totalCount = data.total_count || 0;
        const hasMore = arg.offset + chains.length < totalCount;
        return { chains, totalCount, hasMore, offset: arg.offset };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const baseArgs = {} as any;
          if (arg.createdAfter !== undefined) baseArgs.createdAfter = arg.createdAfter;
          if (arg.createdBefore !== undefined) baseArgs.createdBefore = arg.createdBefore;
          if (arg.status !== undefined) baseArgs.status = arg.status;
          dispatch(
            workspaceApi.util.updateQueryData('listChains', baseArgs, (draft: any) => {
              if (!draft) return;
              const existingIds = new Set(draft.chains.map((c: any) => c.chainId));
              for (const chain of data.chains) {
                if (!existingIds.has(chain.chainId)) {
                  draft.chains.push(chain);
                }
              }
              draft.totalCount = data.totalCount;
              draft.hasMore = data.hasMore;
              draft.offset = data.offset;
            })
          );
        } catch (_error) {
          // noop
        }
      },
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
  useFetchChainsPageQuery,
  useLazyFetchChainsPageQuery,
  useFetchChainQuery,
  useFocusChainMutation,
  useUpdateChainMutation,
  useUpdateChainStatusMutation,
  useFetchWorkspaceQuery,
  usePreviewWorkspaceMergeQuery,
  useLazyPreviewWorkspaceMergeQuery,
  useFetchWorkspaceDiffQuery,
  useLazyFetchWorkspaceDiffQuery,
} = workspaceApi;
