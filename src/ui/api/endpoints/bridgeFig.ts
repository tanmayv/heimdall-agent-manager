// Bridge Fig (CitC) filesystem & workspace management endpoints.
//
// Live pass-through to a bridge's CitC workspace tools and sandboxed
// google3 directory browser.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type FigWorkspace = {
  name: string;
  path: string;
  has_google3: boolean;
};

export type ListBridgeFigWorkspacesResult = {
  ok: boolean;
  workspaces: FigWorkspace[];
  error_code?: string;
  message?: string;
};

export type CreateBridgeFigWorkspaceResult = {
  ok: boolean;
  name: string;
  path: string;
  created: boolean;
  error_code?: string;
  message?: string;
};

export type FigFsEntry = {
  name: string;
  is_dir: boolean;
  path: string;
};

export type ListBridgeFigFsResult = {
  ok: boolean;
  workspace: string;
  path: string;
  entries: FigFsEntry[];
  next_cursor: string;
  has_more: boolean;
  error_code?: string;
  message?: string;
};

export const bridgeFigApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listBridgeFigWorkspaces: build.query<ListBridgeFigWorkspacesResult, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fig/workspaces`);
          return { data: data as ListBridgeFigWorkspacesResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [
        { type: 'BridgeFigWorkspaces' as const, id: bridgeId },
      ],
    }),

    createBridgeFigWorkspace: build.mutation<CreateBridgeFigWorkspaceResult, { bridgeId: string; name: string }>({
      queryFn: async ({ bridgeId, name }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/fig/workspaces`, 'POST', { name });
          return { data: data as CreateBridgeFigWorkspaceResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [
        { type: 'BridgeFigWorkspaces' as const, id: bridgeId },
      ],
    }),

    listBridgeFigFs: build.query<ListBridgeFigFsResult, { bridgeId: string; workspace: string; path?: string; cursor?: string; limit?: number }>({
      queryFn: async ({ bridgeId, workspace, path = '', cursor = '', limit = 50 }) => {
        try {
          const params = new URLSearchParams();
          params.set('workspace', workspace);
          if (path) params.set('path', path);
          if (cursor) params.set('cursor', cursor);
          if (limit) params.set('limit', String(limit));
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fig/fs?${params.toString()}`);
          return { data: data as ListBridgeFigFsResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

export const {
  useListBridgeFigWorkspacesQuery,
  useLazyListBridgeFigWorkspacesQuery,
  useCreateBridgeFigWorkspaceMutation,
  useListBridgeFigFsQuery,
  useLazyListBridgeFigFsQuery,
} = bridgeFigApi;
