// Agent instance run-dir browser endpoints (READ-ONLY).
//
// The run-dir explorer browses an agent INSTANCE's bridge-managed run directory —
// the exact context materialized for the agent (AGENTS.md/CLAUDE.md, .heimdall/,
// skills/, bootstrap manifest). Unlike the project-scoped browser this is
// read-only: only list + bounded file read, no create/move/delete.
//
//   GET /api/v1/agent-instances/{instanceId}/fs        -> agent_run_dir_list
//        (?path=&include_hidden=&cursor=&limit=)
//   GET /api/v1/agent-instances/{instanceId}/fs/file   -> agent_run_dir_read
//        (?path=&offset=&limit=)
//
// The hub resolves (instance -> owner-checked -> bridge) and relays to the bridge,
// which computes the run dir from the instance id and re-sandboxes every path to
// it. Responses reuse the bridge's FsListResult / FsReadFileResult envelopes, so
// the UI types are shared with the project-scoped browser (projectFs.ts).

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';
// Reuse the project browser's contract types (identical bridge envelopes) so the
// run-dir panel and the project Files panel share one shape.
import type { FsListResult, FsReadFileResult } from './projectFs';

export type { FsEntry, FsListResult, FsReadFileResult, FsErrorCode } from './projectFs';
export { FS_ERROR_CODES } from './projectFs';

// Tag id for a run-dir listing, keyed by (instanceId, path) so navigating or
// refreshing one directory only refetches that listing.
function instanceFsTagId(instanceId: string, path: string): string {
  return `${instanceId}::${path || ''}`;
}

type ListArgs = {
  instanceId: string;
  path?: string;
  includeHidden?: boolean;
  cursor?: string | null;
  limit?: number;
};
type ReadFileArgs = { instanceId: string; path: string; offset?: number; limit?: number };

function base(instanceId: string): string {
  return `/agent-instances/${encodeURIComponent(instanceId)}/fs`;
}

export const instanceFsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // List a single directory in the instance run dir (root-relative `path`,
    // '' => run-dir root). include_hidden defaults TRUE (the whole point is to see
    // dotfiles/.heimdall), so we only send include_hidden=false to hide them.
    listInstanceDir: build.query<FsListResult, ListArgs>({
      queryFn: async ({ instanceId, path = '', includeHidden = true, cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          if (path) qs.set('path', path);
          if (!includeHidden) qs.set('include_hidden', 'false');
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(instanceId)}${suffix}`);
          return { data: data as FsListResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { instanceId, path = '' }) => [
        { type: 'InstanceFs' as const, id: instanceFsTagId(instanceId, path) },
      ],
    }),

    // Bounded, byte-range-paginated read of a single file for the viewer. Pass
    // offset/limit to stream a large text file in chunks over the size-limited WS
    // relay (same contract as readProjectFile).
    readInstanceFile: build.query<FsReadFileResult, ReadFileArgs>({
      queryFn: async ({ instanceId, path, offset, limit }) => {
        try {
          const qs = new URLSearchParams({ path });
          if (offset != null && offset > 0) qs.set('offset', String(offset));
          if (limit != null && limit > 0) qs.set('limit', String(limit));
          const data = await cookieJsonFetch(`${base(instanceId)}/file?${qs.toString()}`);
          return { data: data as FsReadFileResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { instanceId, path }) => [
        { type: 'InstanceFs' as const, id: `file::${instanceFsTagId(instanceId, path)}` },
      ],
    }),
  }),
});

export const {
  useListInstanceDirQuery,
  useLazyListInstanceDirQuery,
  useReadInstanceFileQuery,
  useLazyReadInstanceFileQuery,
} = instanceFsApi;
