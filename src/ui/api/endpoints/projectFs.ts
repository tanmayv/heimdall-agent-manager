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
  // Byte-range pagination (utf8 text): offset of this chunk, bytes it covers, and
  // whether it reached end of file. Page by requesting offset += bytes_returned.
  offset?: number;
  bytes_returned?: number;
  eof?: boolean;
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
type ReadFileArgs = { projectId: string; bridgeId?: string; path: string; offset?: number; limit?: number };
type CreateArgs = { projectId: string; bridgeId?: string; path: string };
type MoveArgs = { projectId: string; bridgeId?: string; from: string; to: string };
type DeleteArgs = { projectId: string; bridgeId?: string; path: string; recursive?: boolean };

function base(projectId: string): string {
  return `/projects/${encodeURIComponent(projectId)}/fs`;
}

// Query fragment that pins the resolution to the conversation's bridge, so a
// project configured on multiple bridges (or on a different/offline bridge) still
// targets the bridge the agent actually runs on. Empty => hub falls back to the
// single configured path.
function bridgeParam(bridgeId?: string): string {
  return bridgeId ? `bridge_id=${encodeURIComponent(bridgeId)}` : '';
}

export const projectFsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // List a single directory (project-root-relative `path`, '' => project root).
    listProjectDir: build.query<FsListResult, ListArgs>({
      queryFn: async ({ projectId, bridgeId = '', path = '', includeHidden = false, cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          // Disambiguate which bridge's project path to use: a project may be
          // configured on multiple bridges (or only on a DIFFERENT bridge than the
          // one the conversation's agent runs on). Passing the conversation's
          // bridge_id makes the hub resolve THIS bridge's path instead of falling
          // back to "the single configured path" (which can be an offline bridge).
          if (bridgeId) qs.set('bridge_id', bridgeId);
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

    // Bounded, byte-range-paginated read of a single file for the viewer. Pass
    // offset/limit to stream a large text file in chunks (avoids the one-huge-
    // frame WS relay timeout). We assume the file doesn't change between pages.
    readProjectFile: build.query<FsReadFileResult, ReadFileArgs>({
      queryFn: async ({ projectId, bridgeId = '', path, offset, limit }) => {
        try {
          const qs = new URLSearchParams({ path });
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (offset != null && offset > 0) qs.set('offset', String(offset));
          if (limit != null && limit > 0) qs.set('limit', String(limit));
          const data = await cookieJsonFetch(`${base(projectId)}/file?${qs.toString()}`);
          return { data: data as FsReadFileResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      // File views are point reads; keep them per (project, bridge, path). Chunks
      // are fetched lazily (useLazy…) and stitched in the component, so we don't
      // key the cache by offset.
      providesTags: (_result, _error, { projectId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: `file::${fsListTagId(projectId, bridgeId, path)}` },
      ],
    }),

    // Create an empty file at `path`.
    createProjectFile: build.mutation<FsMutationResult, CreateArgs>({
      queryFn: async ({ projectId, bridgeId = '', path }) => {
        try {
          const bp = bridgeParam(bridgeId);
          const data = await cookieMutation(`${base(projectId)}/file${bp ? `?${bp}` : ''}`, 'POST', { path });
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
      queryFn: async ({ projectId, bridgeId = '', path }) => {
        try {
          const bp = bridgeParam(bridgeId);
          const data = await cookieMutation(`${base(projectId)}/dir${bp ? `?${bp}` : ''}`, 'POST', { path });
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
      queryFn: async ({ projectId, bridgeId = '', from, to }) => {
        try {
          const bp = bridgeParam(bridgeId);
          const data = await cookieMutation(`${base(projectId)}/move${bp ? `?${bp}` : ''}`, 'POST', { from, to });
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
      queryFn: async ({ projectId, bridgeId = '', path, recursive = false }) => {
        try {
          const qs = new URLSearchParams({ path });
          if (recursive) qs.set('recursive', 'true');
          if (bridgeId) qs.set('bridge_id', bridgeId);
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
