import { createApi, fakeBaseQuery, setupListeners } from '@reduxjs/toolkit/query/react';

export const HEIMDALL_TAG_TYPES = [
  'TaskLog',
  'Task',
  'TaskComments',
  'ChainTasks',
  'Chain',
  'ChainList',
  'Chat',
  'GuideChat',
  'CoordinatorChat',
  'ConversationSummaries',
  'Agents',
  'AgentTemplate',
  'Memory',
  'MemoryHistory',
  'Project',
  'Projects',
  'Workspace',
  'WorkspaceDiff',
  'Artifact',
  'ArtifactContent',
  'ArtifactVersions',
  'ArtifactAnnotations',
  'Preferences',
  'ChatApprovals',
  'MergeDecisions',
  'Attention',
] as const;

export type HeimdallTagType = (typeof HEIMDALL_TAG_TYPES)[number];

type QueryError = {
  status: string;
  error: string;
};

function queryError(error: any): QueryError & { message: string } {
  return {
    status: 'CUSTOM_ERROR',
    error: String(error?.message || error || 'Request failed'),
    message: String(error?.message || error || 'Request failed'),
  } as any;
}

export function withSessionQuery<Arg, Result>(
  run: (arg: Arg, context: { state: any; session: any }) => Promise<Result>,
) {
  return async (arg: Arg, api: { getState: () => unknown }) => {
    const state = api.getState() as any;
    const session = state?.chat?.session || {};
    try {
      return { data: await run(arg, { state, session }) };
    } catch (error: any) {
      return { error: queryError(error) };
    }
  };
}

export const heimdallApi = createApi({
  reducerPath: 'heimdallApi',
  baseQuery: fakeBaseQuery<QueryError>(),
  tagTypes: [...HEIMDALL_TAG_TYPES],
  keepUnusedDataFor: 30,
  refetchOnReconnect: true,
  endpoints: () => ({}),
});

export function setupHeimdallApiListeners(dispatch: Parameters<typeof setupListeners>[0]) {
  setupListeners(dispatch);
}
