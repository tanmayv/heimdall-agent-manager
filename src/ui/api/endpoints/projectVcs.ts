// Project-scoped VCS endpoints (VCS Integration feature — REQ-VCS-8/9, REQ-VCS-DIFF-TARGETS, REQ-VCS-FILE-CONTENT-API, REQ-VCS-STATUS-AND-LOG-INDICATORS, REQ-VCS-FILE-ACTIONS).
//
// Project-scoped Hub wrappers that resolve (project_id -> bridge_id, root_path)
// server-side and relay a vcs_* WS command to the owning bridge, mirroring
// projectFs.ts. Backing commands:
//
//   GET /api/v1/projects/{projectId}/vcs/capabilities   -> vcs_capabilities
//   GET /api/v1/projects/{projectId}/vcs/targets        -> vcs_targets
//   GET /api/v1/projects/{projectId}/vcs/log            -> vcs_log (?limit=)
//   GET /api/v1/projects/{projectId}/vcs/files          -> vcs_files (?target=&cursor=&limit=)
//   GET /api/v1/projects/{projectId}/vcs/diff           -> vcs_diff  (?file=&target=&cursor=&limit=)
//   GET /api/v1/projects/{projectId}/vcs/file-content   -> vcs_file_content (?file=&target=)
//   GET /api/v1/projects/{projectId}/vcs/status         -> vcs_status
//   POST /api/v1/projects/{projectId}/vcs/action        -> vcs_action (body: { action, file })
//   POST /api/v1/projects/{projectId}/vcs/commit        -> vcs_commit (body: { message, amend })
//
// The bridge result JSON is returned verbatim by the hub, so these types mirror the
// bridge serialization in src/bridge/vcs_api.odin exactly. UI cache is keyed by
// (projectId, bridgeId[, file, target]) so switching project/bridge only refetches what changed.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

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

export type VcsDiffTarget = {
  id: string;
  label: string;
  description: string;
  is_default: boolean;
};

export type VcsTargetsResult = {
  ok: boolean;
  provider: string;
  targets: VcsDiffTarget[];
  error: VcsError;
};

export type VcsLogEntry = {
  revision: string;
  cl_number: string;
  title: string;
  author: string;
  timestamp: string;
  is_current: boolean;
  status: string;
};

export type VcsLogResult = {
  ok: boolean;
  provider: string;
  entries: VcsLogEntry[];
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
  provider?: string;
  target?: string;
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
  provider?: string;
  file: string;
  target?: string;
  hunks: VcsDiffHunk[];
  next_cursor: string | null;
  has_more: boolean;
  error: VcsError;
};

export type VcsFileContentResult = {
  ok: boolean;
  provider: string;
  file: string;
  target: string;
  content: string;
  error: VcsError;
};

export type VcsActionResult = {
  ok: boolean;
  provider: string;
  action: string;
  file: string;
  error: VcsError;
};

export type VcsCommitResult = {
  ok: boolean;
  provider: string;
  output: string;
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
type TargetsArgs = { projectId: string; bridgeId?: string };
type LogArgs = { projectId: string; bridgeId?: string; limit?: number };
type FilesArgs = { projectId: string; bridgeId?: string; target?: string; cursor?: string | null; limit?: number };
type DiffArgs = { projectId: string; bridgeId?: string; file: string; target?: string; cursor?: string | null; limit?: number };
type FileContentArgs = { projectId: string; bridgeId?: string; file: string; target?: string; revision?: string };
type ActionArgs = { projectId: string; bridgeId?: string; action: 'add' | 'revert' | 'revert_all' | string; file?: string; path?: string };
type CommitArgs = { projectId: string; bridgeId?: string; message?: string; amend?: boolean };

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

    // Available diff targets (HEAD, cached, p4base, p4head, recent commits/CLs).
    getVcsTargets: build.query<VcsTargetsResult, TargetsArgs>({
      queryFn: async ({ projectId, bridgeId = '' }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/targets${suffix}`);
          return { data: data as VcsTargetsResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'targets') },
      ],
    }),

    // Recent commit log / Fig CL stack entries.
    getVcsLog: build.query<VcsLogResult, LogArgs>({
      queryFn: async ({ projectId, bridgeId = '', limit }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/log${suffix}`);
          return { data: data as VcsLogResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', limit }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `log::${limit ?? 20}`) },
      ],
    }),

    // Paginated list of changed files relative to target (default HEAD/p4base).
    listVcsFiles: build.query<VcsFilesResult, FilesArgs>({
      queryFn: async ({ projectId, bridgeId = '', target = '', cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (target) qs.set('target', target);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/files${suffix}`);
          return { data: data as VcsFilesResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', target = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `files::${target}`) },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Paginated diff hunks for a single changed file against optional target.
    getVcsDiff: build.query<VcsDiffResult, DiffArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, target = '', cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams({ file });
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (target) qs.set('target', target);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const data = await cookieJsonFetch(`${base(projectId)}/diff?${qs.toString()}`);
          return { data: data as VcsDiffResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', file, target = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `diff::${file}`) },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `diff::${file}::${target}`) },
      ],
    }),

    // Fetch base file content at a specific revision/target.
    getVcsFileContent: build.query<VcsFileContentResult, FileContentArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, target = '', revision = '' }) => {
        try {
          const effTarget = target || revision;
          const qs = new URLSearchParams({ file });
          if (effTarget) qs.set('target', effTarget);
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const data = await cookieJsonFetch(`${base(projectId)}/file-content?${qs.toString()}`);
          return { data: data as VcsFileContentResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', file, target = '', revision = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `content::${file}::${target || revision}`) },
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

    // Execute VCS file actions: 'add', 'revert', 'revert_all'.
    executeVcsAction: build.mutation<VcsActionResult, ActionArgs>({
      queryFn: async ({ projectId, bridgeId = '', action, file, path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const targetFile = file || path || '';
          const data = await cookieMutation(`${base(projectId)}/action${suffix}`, 'POST', {
            action,
            file: targetFile,
          });
          return { data: data as VcsActionResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', file, path }) => {
        const filePath = file || path || '';
        return [
          { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
          { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'status') },
          { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `diff::${filePath}`) },
        ];
      },
    }),

    // Commit changes or amend CL.
    commitVcs: build.mutation<VcsCommitResult, CommitArgs>({
      queryFn: async ({ projectId, bridgeId = '', message = '', amend = false }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieMutation(`${base(projectId)}/commit${suffix}`, 'POST', {
            message,
            amend,
          });
          return { data: data as VcsCommitResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'status') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'targets') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'log::20') },
      ],
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
  useGetVcsTargetsQuery,
  useLazyGetVcsTargetsQuery,
  useGetVcsLogQuery,
  useLazyGetVcsLogQuery,
  useGetVcsFileContentQuery,
  useLazyGetVcsFileContentQuery,
  useExecuteVcsActionMutation,
  useCommitVcsMutation,
} = projectVcsApi;
