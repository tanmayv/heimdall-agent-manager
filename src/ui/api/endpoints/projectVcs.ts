// Project-scoped VCS endpoints (VCS Integration feature — REQ-VCS-8/9).
//
// Project-scoped Hub wrappers that resolve (project_id -> bridge_id, root_path)
// server-side and relay a read-only vcs_* WS command to the owning bridge, mirroring
// projectFs.ts. All four backing commands are read-only; the UI uses three of them:
//
//   GET /api/v1/projects/{projectId}/vcs/capabilities  -> vcs_capabilities
//   GET /api/v1/projects/{projectId}/vcs/files          -> vcs_files (?cursor=&limit=)
//   GET /api/v1/projects/{projectId}/vcs/diff           -> vcs_diff  (?file=&cursor=&limit=)
//
// The bridge result JSON is returned verbatim by the hub, so these types mirror the
// bridge serialization in src/bridge/vcs_api.odin exactly. UI cache is keyed by
// (projectId, bridgeId[, file]) so switching project/bridge only refetches what changed.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';

// ---- Contract types (mirror the bridge vcs_* result JSON exactly) -----------

// Shared trailing error object on every vcs_* result (empty code/message on success).
export type VcsError = { code: string; message: string };

export type VcsCapabilities = {
  ok: boolean;
  provider: string;
  supports_staging: boolean;
  error: VcsError;
};

export type VcsStatus = {
  ok: boolean;
  provider: string;
  branch: string;
  remote: string;
  ahead: number;
  behind: number;
  is_clean: boolean;
  error: VcsError;
};

export type VcsFileStatus = 'added' | 'modified' | 'deleted' | 'renamed' | 'untracked';

export type VcsChangedFile = {
  path: string;
  status: VcsFileStatus;
  staged: boolean;
  additions: number;
  deletions: number;
};

export type VcsFilesResult = {
  ok: boolean;
  files: VcsChangedFile[];
  next_cursor: string | null;
  has_more: boolean;
  error: VcsError;
};

export type VcsDiffLine = { op: string; text: string };

export type VcsDiffHunk = {
  old_start: number;
  old_len: number;
  new_start: number;
  new_len: number;
  lines: VcsDiffLine[];
};

export type VcsDiffResult = {
  ok: boolean;
  file: string;
  hunks: VcsDiffHunk[];
  next_cursor: string | null;
  has_more: boolean;
  error: VcsError;
};

// ---- Cache key helpers ------------------------------------------------------

// Tag id for a project's VCS data. Keyed by (projectId, bridgeId[, suffix]) so a
// different project/bridge (or file diff) gets its own cache entry.
function vcsTagId(projectId: string, bridgeId: string, suffix = ''): string {
  return `${projectId}::${bridgeId}::${suffix}`;
}

// ---- Arg types --------------------------------------------------------------

type CapabilitiesArgs = { projectId: string; bridgeId?: string };
type FilesArgs = { projectId: string; bridgeId?: string; cursor?: string | null; limit?: number };
type DiffArgs = { projectId: string; bridgeId?: string; file: string; cursor?: string | null; limit?: number };

function base(projectId: string): string {
  return `/projects/${encodeURIComponent(projectId)}/vcs`;
}

export const projectVcsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // Detect the VCS provider at the project root (drives the "Changes" tab
    // visibility). ok=false / empty provider => no supported VCS.
    getVcsCapabilities: build.query<VcsCapabilities, CapabilitiesArgs>({
      queryFn: async ({ projectId, bridgeId = '' }) => {
        try {
          const qs = new URLSearchParams();
          // Disambiguate which bridge's project path to use (see projectFs.ts): a
          // project may be configured on multiple bridges, so pass the conversation's
          // bridge_id to resolve THIS bridge's path.
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/capabilities${suffix}`);
          return { data: data as VcsCapabilities };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'capabilities') },
      ],
    }),

    // Paginated list of changed files. Fetched lazily and stitched in the component,
    // so we don't key the cache by cursor.
    listVcsFiles: build.query<VcsFilesResult, FilesArgs>({
      queryFn: async ({ projectId, bridgeId = '', cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/files${suffix}`);
          return { data: data as VcsFilesResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Paginated diff hunks for a single changed file. Pages are fetched lazily and
    // appended in the component, so the cache is keyed by (project, bridge, file) —
    // not by cursor.
    getVcsDiff: build.query<VcsDiffResult, DiffArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams({ file });
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const data = await cookieJsonFetch(`${base(projectId)}/diff?${qs.toString()}`);
          return { data: data as VcsDiffResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', file }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `diff::${file}`) },
      ],
    }),

    // Live VCS status (branch, remote, ahead, behind, is_clean).
    getProjectVcsStatus: build.query<VcsStatus, { projectId: string; bridgeId?: string } | string>({
      queryFn: async (arg) => {
        const projectId = typeof arg === 'string' ? arg : arg.projectId;
        const bridgeId = typeof arg === 'string' ? '' : (arg.bridgeId || '');
        if (!projectId) {
          return { data: { ok: false, provider: '', branch: '', remote: '', ahead: 0, behind: 0, is_clean: true, error: { code: 'no_project', message: 'No project ID' } } };
        }
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/status${suffix}`);
          return { data: data as VcsStatus };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const projectId = typeof arg === 'string' ? arg : arg.projectId;
        const bridgeId = typeof arg === 'string' ? '' : (arg.bridgeId || '');
        return [
          { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'status') },
        ];
      },
    }),
  }),
});

export const {
  useGetVcsCapabilitiesQuery,
  useLazyGetVcsCapabilitiesQuery,
  useListVcsFilesQuery,
  useLazyListVcsFilesQuery,
  useGetVcsDiffQuery,
  useLazyGetVcsDiffQuery,
  useGetProjectVcsStatusQuery,
  useLazyGetProjectVcsStatusQuery,
} = projectVcsApi;
