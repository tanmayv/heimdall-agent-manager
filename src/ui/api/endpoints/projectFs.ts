// Project-scoped filesystem browser endpoints (Project Directory Browser feature).
//
// Built against the LOCKED API contract (art_18d23e8bfc65311a). These are the
// project-scoped Hub wrappers that resolve (project_id -> bridge_id, root_path)
// server-side and relay a WS command to the owning bridge. All request paths are
// RELATIVE to the project root; the bridge re-sandboxes them.
//
//   GET    /api/v1/projects/{projectId}/fs        -> fs_list_dir    (?path=&include_hidden=&cursor=&limit=)
//   GET    /api/v1/projects/{projectId}/fs/file   -> fs_read_file   (?path=)
//   POST   /api/v1/projects/{projectId}/fs/file   -> fs_create_file (body { path })
//   POST   /api/v1/projects/{projectId}/fs/dir    -> fs_make_dir    (body { path })
//   POST   /api/v1/projects/{projectId}/fs/move   -> fs_move        (body { from, to })
//   DELETE /api/v1/projects/{projectId}/fs        -> fs_delete      (?path=&recursive=)
//
// UI cache is keyed by (projectId, bridgeId, path) so switching project/bridge or
// mutating a directory only refetches the affected listing.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

// ---- Contract types (mirror the LOCKED contract exactly) --------------------

export type FsEntry = {
  name: string;
  is_dir: boolean;
  hidden: boolean;
  has_git: boolean;
  size: number;
  modified_at: string;
};

export type FsListResult = {
  ok: boolean;
  path: string;
  root: string;
  parent: string;
  entries: FsEntry[];
  next_cursor: string | null;
  has_more: boolean;
  truncated: boolean;
  error: { code: string; message: string };
};

export type FsReadFileResult = {
  ok: boolean;
  path: string;
  viewable: boolean;
  content?: string;
  encoding?: 'utf8' | 'base64';
  mime: string;
  size: number;
  modified_at: string;
  truncated: boolean;
  error: { code: string; message: string };
};

export type FsMutationResult = {
  ok: boolean;
  path: string;
  within_root: boolean;
  error: { code: string; message: string };
};

// The shared error vocabulary from the contract, exported for callers that want
// to branch on specific failures (e.g. friendly "already exists" messaging).
export const FS_ERROR_CODES = [
  'path_outside_root',
  'path_not_found',
  'path_not_directory',
  'not_a_file',
  'file_too_large',
  'unsupported_type',
  'path_exists',
  'dest_exists',
  'dir_not_empty',
  'cannot_delete_root',
  'read_failed',
  'write_failed',
  'mkdir_failed',
  'move_failed',
  'delete_failed',
] as const;
export type FsErrorCode = (typeof FS_ERROR_CODES)[number] | '';

// ---- Cache key helpers ------------------------------------------------------

// Tag id for a directory listing. Keyed by (projectId, bridgeId, path) so a
// mutation in one directory only invalidates that directory's listing.
function fsListTagId(projectId: string, bridgeId: string, path: string): string {
  return `${projectId}::${bridgeId}::${path || ''}`;
}

// ---- Arg types --------------------------------------------------------------

type ListArgs = {
  projectId: string;
  bridgeId?: string; // cache-key only; the server resolves the real bridge
  path?: string;
  includeHidden?: boolean;
  cursor?: string | null;
  limit?: number;
};
type ReadFileArgs = { projectId: string; bridgeId?: string; path: string };
type CreateArgs = { projectId: string; bridgeId?: string; path: string };
type MoveArgs = { projectId: string; bridgeId?: string; from: string; to: string };
type DeleteArgs = { projectId: string; bridgeId?: string; path: string; recursive?: boolean };

function base(projectId: string): string {
  return `/projects/${encodeURIComponent(projectId)}/fs`;
}

export const projectFsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // List a single directory (project-root-relative `path`, '' => project root).
    listProjectDir: build.query<FsListResult, ListArgs>({
      queryFn: async ({ projectId, path = '', includeHidden = false, cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          if (path) qs.set('path', path);
          if (includeHidden) qs.set('include_hidden', 'true');
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}${suffix}`);
          return { data: data as FsListResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', path = '' }) => [
        { type: 'ProjectFs' as const, id: fsListTagId(projectId, bridgeId, path) },
      ],
    }),

    // Bounded read of a single file for the read-only viewer.
    readProjectFile: build.query<FsReadFileResult, ReadFileArgs>({
      queryFn: async ({ projectId, path }) => {
        try {
          const data = await cookieJsonFetch(`${base(projectId)}/file?path=${encodeURIComponent(path)}`);
          return { data: data as FsReadFileResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      // File views are point reads; keep them per (project, bridge, path).
      providesTags: (_result, _error, { projectId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: `file::${fsListTagId(projectId, bridgeId, path)}` },
      ],
    }),

    // Create an empty file at `path`.
    createProjectFile: build.mutation<FsMutationResult, CreateArgs>({
      queryFn: async ({ projectId, path }) => {
        try {
          const data = await cookieMutation(`${base(projectId)}/file`, 'POST', { path });
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: fsListTagId(projectId, bridgeId, parentOf(path)) },
      ],
    }),

    // Create a directory at `path` (reuses the existing fs_make_dir command).
    createProjectDir: build.mutation<FsMutationResult, CreateArgs>({
      queryFn: async ({ projectId, path }) => {
        try {
          const data = await cookieMutation(`${base(projectId)}/dir`, 'POST', { path });
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: fsListTagId(projectId, bridgeId, parentOf(path)) },
      ],
    }),

    // Rename/move `from` -> `to`. Invalidates both source and dest parents.
    moveProjectPath: build.mutation<FsMutationResult, MoveArgs>({
      queryFn: async ({ projectId, from, to }) => {
        try {
          const data = await cookieMutation(`${base(projectId)}/move`, 'POST', { from, to });
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', from, to }) => [
        { type: 'ProjectFs' as const, id: fsListTagId(projectId, bridgeId, parentOf(from)) },
        { type: 'ProjectFs' as const, id: fsListTagId(projectId, bridgeId, parentOf(to)) },
      ],
    }),

    // Delete `path` (optionally recursive for non-empty dirs).
    deleteProjectPath: build.mutation<FsMutationResult, DeleteArgs>({
      queryFn: async ({ projectId, path, recursive = false }) => {
        try {
          const qs = new URLSearchParams({ path });
          if (recursive) qs.set('recursive', 'true');
          const data = await cookieMutation(`${base(projectId)}?${qs.toString()}`, 'DELETE');
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: fsListTagId(projectId, bridgeId, parentOf(path)) },
      ],
    }),
  }),
});

// Parent directory of a project-root-relative path (''=root). Kept local so the
// cache invalidation targets the listing that actually changed.
function parentOf(path: string): string {
  const clean = String(path || '').replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx <= 0 ? '' : clean.slice(0, idx);
}

export const {
  useListProjectDirQuery,
  useLazyListProjectDirQuery,
  useReadProjectFileQuery,
  useLazyReadProjectFileQuery,
  useCreateProjectFileMutation,
  useCreateProjectDirMutation,
  useMoveProjectPathMutation,
  useDeleteProjectPathMutation,
} = projectFsApi;
