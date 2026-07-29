import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

type ArtifactListArgs = {
  projectId?: string;
  creatorId?: string;
  originRef?: string;
  includeDeleted?: boolean;
  limit?: number;
  offset?: number;
};

type ArtifactCreateArgs = {
  name: string;
  kind?: string;
  mime?: string;
  projectId?: string;
  description?: string;
  originKind?: string;
  originRef?: string;
  contentBase64: string;
};

type ArtifactUpdateArgs = {
  artifactId: string;
  name?: string;
  kind?: string;
  projectId?: string;
  description?: string;
  originKind?: string;
  originRef?: string;
  contentBase64?: string;
  changeReason?: string;
};

type ArtifactTextContentArgs = {
  artifactId: string;
  versionNo?: number | null;
};

type ArtifactRollbackArgs = {
  artifactId: string;
  versionNo: number;
  changeReason?: string;
};

type ArtifactAnnotationsArgs = {
  artifactId: string;
  versionNo?: number | null;
};

type CreateArtifactAnnotationArgs = {
  artifactId: string;
  versionNo?: number | null;
  contextType: string;
  contextJson: unknown;
  comment: string;
};

type UpdateArtifactAnnotationArgs = {
  annotationId: string;
  artifactId: string;
  versionNo?: number | null;
  comment: string;
};

type DeleteArtifactAnnotationArgs = {
  annotationId: string;
  artifactId: string;
  versionNo?: number | null;
};

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

function artifactIdOf(row: any, fallback = '') {
  return String(row?.artifact_id || row?.artifactId || fallback || '');
}

function projectListTag(projectId = '') {
  return `PROJECT:${projectId || 'NONE'}`;
}

function originListTag(originRef = '') {
  return `ORIGIN:${originRef || 'NONE'}`;
}

function annotationScopeTag(artifactId: string, versionNo?: number | null) {
  return `${artifactId}:${versionNo == null ? 'HEAD' : versionNo}`;
}

function stringField(row: any, ...keys: string[]): string {
  for (const key of keys) {
    const value = row?.[key];
    if (value != null && String(value).trim()) return String(value).trim();
  }
  return '';
}

function inferExt(name: string, explicitExt = ''): string {
  const normalizedExt = String(explicitExt || '').trim().toLowerCase();
  if (normalizedExt) return normalizedExt.startsWith('.') ? normalizedExt : `.${normalizedExt}`;
  const normalizedName = String(name || '').trim().toLowerCase();
  const dot = normalizedName.lastIndexOf('.');
  if (dot <= 0 || dot === normalizedName.length - 1) return '';
  return normalizedName.slice(dot);
}

function inferKind(kind: string, mime: string, ext: string, name: string, renderer = ''): string {
  const explicit = String(kind || '').trim().toLowerCase();
  if (explicit) return explicit;
  const normalizedMime = String(mime || '').trim().toLowerCase();
  const normalizedExt = String(ext || '').trim().toLowerCase();
  const normalizedName = String(name || '').trim().toLowerCase();
  const normalizedRenderer = String(renderer || '').trim().toLowerCase();
  if (normalizedRenderer === 'markdown' || normalizedMime === 'text/markdown' || normalizedMime === 'text/plain' || ['.md', '.markdown', '.txt'].includes(normalizedExt) || normalizedName.endsWith('.md') || normalizedName.endsWith('.markdown') || normalizedName.endsWith('.txt')) return 'markdown';
  if (normalizedMime === 'image/png' || normalizedExt === '.png' || normalizedName.endsWith('.png')) return 'png';
  if (normalizedMime === 'image/jpeg' || ['.jpg', '.jpeg'].includes(normalizedExt) || normalizedName.endsWith('.jpg') || normalizedName.endsWith('.jpeg')) return 'jpeg';
  if (normalizedMime === 'text/csv' || normalizedExt === '.csv' || normalizedName.endsWith('.csv')) return 'csv';
  if (normalizedMime === 'text/html' || ['.html', '.htm'].includes(normalizedExt) || normalizedName.endsWith('.html') || normalizedName.endsWith('.htm')) return 'html';
  return '';
}

function inferMime(kind: string, explicitMime: string): string {
  const normalizedMime = String(explicitMime || '').trim().toLowerCase();
  if (normalizedMime) return normalizedMime;
  switch (String(kind || '').trim().toLowerCase()) {
    case 'markdown':
    case 'text':
      return 'text/markdown';
    case 'png':
      return 'image/png';
    case 'jpeg':
    case 'jpg':
      return 'image/jpeg';
    case 'csv':
      return 'text/csv';
    case 'html':
      return 'text/html';
    default:
      return '';
  }
}

export function normalizeArtifactRecord(row: any) {
  if (!row || typeof row !== 'object') return row;
  const artifactId = artifactIdOf(row);
  const name = stringField(row, 'name') || artifactId || 'Untitled artifact';
  const ext = inferExt(name, stringField(row, 'ext', 'extension'));
  const explicitMime = stringField(row, 'mime', 'content_type', 'contentType');
  const kind = inferKind(stringField(row, 'kind', 'type'), explicitMime, ext, name, stringField(row, 'renderer'));
  const mime = inferMime(kind, explicitMime);
  const contentType = stringField(row, 'content_type', 'contentType') || mime;
  return {
    ...row,
    artifact_id: artifactId,
    artifactId,
    name,
    kind,
    mime,
    content_type: contentType,
    contentType,
    ext,
    link: stringField(row, 'link') || (artifactId ? `artifact://${artifactId}` : ''),
  };
}

function normalizeArtifactResponse(data: any) {
  const raw = data?.artifact || data?.data?.artifact || (data?.data?.artifact_id || data?.data?.artifactId ? data.data : null) || (data?.artifact_id || data?.artifactId ? data : null);
  if (!raw) return data;
  return { ...data, artifact: normalizeArtifactRecord(raw) };
}

function normalizeArtifactVersionsResponse(data: any) {
  const rows = Array.isArray(data?.versions) ? data.versions : Array.isArray(data?.data?.versions) ? data.data.versions : [];
  return { ...data, versions: rows.map((row: any) => normalizeArtifactRecord(row)) };
}

function artifactContentUrl(session: any, artifactId: string, versionNo?: number | null) {
  return daemonApi.artifactContentUrl({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, artifactId, version: versionNo });
}

export const artifactsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listArtifacts: build.query<any, ArtifactListArgs>({
      queryFn: withSessionQuery(async ({ projectId = '', creatorId = '', originRef = '', includeDeleted = false, limit = 20, offset = 0 }, { session }) => {
        if (!session?.clientToken) return { artifacts: [] };
        const data = await daemonApi.listArtifacts({ ...auth(session), projectId, creatorId, originRef, includeDeleted, limit, offset });
        return { ...data, artifacts: normalizeArtifacts(data) };
      }),
      providesTags: (result, _error, { projectId = '', originRef = '' }) => [
        { type: 'Artifact' as const, id: projectListTag(projectId) },
        ...(originRef ? [{ type: 'Artifact' as const, id: originListTag(originRef) }] : []),
        ...((result?.artifacts || []).map((artifact: any) => ({ type: 'Artifact' as const, id: artifactIdOf(artifact) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchArtifactsPage: build.query<any, ArtifactListArgs & { offset: number }>({
      queryFn: withSessionQuery(async ({ projectId = '', creatorId = '', originRef = '', includeDeleted = false, limit = 20, offset }, { session }) => {
        if (!session?.clientToken) return { artifacts: [] };
        const data = await daemonApi.listArtifacts({ ...auth(session), projectId, creatorId, originRef, includeDeleted, limit, offset });
        return { ...data, artifacts: normalizeArtifacts(data) };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const { projectId, creatorId, originRef, includeDeleted, limit = 20 } = arg;
          const cacheKeyArgs = { projectId, creatorId, originRef, includeDeleted, limit };
          dispatch(
            artifactsApi.util.updateQueryData('listArtifacts', cacheKeyArgs, (draft) => {
              if (!draft) return;
              draft.has_more = data.has_more;
              draft.next_offset = data.next_offset;
              draft.total = data.total;
              
              const existingIds = new Set(draft.artifacts.map((a: any) => a.artifact_id || a.artifactId));
              for (const art of data.artifacts) {
                const id = art.artifact_id || art.artifactId;
                if (!existingIds.has(id)) {
                  draft.artifacts.push(art);
                }
              }
            })
          );
        } catch {}
      }
    }),
    fetchArtifactMeta: build.query<any, { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!session?.clientToken || !artifactId) return { artifact: null };
        return normalizeArtifactResponse(await daemonApi.fetchArtifactMeta({ ...auth(session), artifactId }));
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'Artifact' as const, id: artifactId }],
    }),
    fetchArtifactVersions: build.query<any, { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!session?.clientToken || !artifactId) return { versions: [] };
        return normalizeArtifactVersionsResponse(await daemonApi.fetchArtifactVersions({ ...auth(session), artifactId }));
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactVersions' as const, id: artifactId }],
    }),
    fetchArtifactTextContent: build.query<any, ArtifactTextContentArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session }) => {
        if (!session?.clientToken || !artifactId) return { artifactId, versionNo, text: '' };
        const response = await fetch(artifactContentUrl(session, artifactId, versionNo));
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        const body = await response.text();
        const responseContentType = response.headers.get('content-type') || '';
        if (/\bjson\b/i.test(responseContentType)) {
          try {
            const parsed = JSON.parse(body);
            const text = typeof parsed?.content === 'string'
              ? parsed.content
              : typeof parsed?.data?.content === 'string'
                ? parsed.data.content
                : typeof parsed?.text === 'string'
                  ? parsed.text
                  : '';
            if (text) return { artifactId, versionNo, text };
          } catch {}
        }
        return { artifactId, versionNo, text: body };
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactContent' as const, id: artifactId }],
      keepUnusedDataFor: 0,
    }),
    fetchArtifactAnnotations: build.query<any, ArtifactAnnotationsArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session }) => {
        if (!session?.clientToken || !artifactId) return { annotations: [] };
        return daemonApi.fetchArtifactAnnotations({ ...auth(session), artifactId, versionNo });
      }),
      providesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    createArtifact: build.mutation<any, ArtifactCreateArgs>({
      queryFn: withSessionQuery(async (args, { session }) => daemonApi.createArtifact({ ...auth(session), ...args })),
      invalidatesTags: (result, _error, { projectId = '', originRef = '' }) => {
        const artifactId = artifactIdOf(result?.artifact);
        return [
          { type: 'Artifact' as const, id: projectListTag(projectId || result?.artifact?.project_id || result?.artifact?.projectId || '') },
          ...(originRef || result?.artifact?.origin_ref ? [{ type: 'Artifact' as const, id: originListTag(originRef || result?.artifact?.origin_ref || result?.artifact?.originRef || '') }] : []),
          ...(artifactId ? [
            { type: 'Artifact' as const, id: artifactId },
            { type: 'ArtifactContent' as const, id: artifactId },
            { type: 'ArtifactVersions' as const, id: artifactId },
            { type: 'ArtifactAnnotations' as const, id: artifactId },
          ] : []),
        ];
      },
    }),
    updateArtifact: build.mutation<any, ArtifactUpdateArgs>({
      queryFn: withSessionQuery(async (args, { session }) => daemonApi.updateArtifact({ ...auth(session), ...args })),
      invalidatesTags: (result, _error, { artifactId, projectId = '', originRef = '' }) => {
        const updated = result?.artifact || {};
        return [
          { type: 'Artifact' as const, id: artifactId },
          { type: 'Artifact' as const, id: projectListTag(projectId || updated.project_id || updated.projectId || '') },
          ...(originRef || updated.origin_ref ? [{ type: 'Artifact' as const, id: originListTag(originRef || updated.origin_ref || updated.originRef || '') }] : []),
          { type: 'ArtifactContent' as const, id: artifactId },
          { type: 'ArtifactVersions' as const, id: artifactId },
          { type: 'ArtifactAnnotations' as const, id: artifactId },
        ];
      },
    }),
    rollbackArtifact: build.mutation<any, ArtifactRollbackArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo, changeReason = '' }, { session }) => {
        return daemonApi.rollbackArtifact({ ...auth(session), artifactId, versionNo, changeReason });
      }),
      invalidatesTags: (_result, _error, { artifactId }) => [
        { type: 'Artifact' as const, id: artifactId },
        { type: 'ArtifactContent' as const, id: artifactId },
        { type: 'ArtifactVersions' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: artifactId },
      ],
    }),
    createArtifactAnnotation: build.mutation<any, CreateArtifactAnnotationArgs>({
      queryFn: withSessionQuery(async (args, { session }) => daemonApi.createArtifactAnnotation({ ...auth(session), ...args })),
      invalidatesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    updateArtifactAnnotation: build.mutation<any, UpdateArtifactAnnotationArgs>({
      queryFn: withSessionQuery(async ({ annotationId, comment }, { session }) => daemonApi.updateArtifactAnnotation({ ...auth(session), annotationId, comment })),
      invalidatesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    deleteArtifactAnnotation: build.mutation<any, DeleteArtifactAnnotationArgs>({
      queryFn: withSessionQuery(async ({ annotationId }, { session }) => daemonApi.deleteArtifactAnnotation({ ...auth(session), annotationId })),
      invalidatesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    deleteArtifact: build.mutation<any, { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => daemonApi.deleteArtifact({ ...auth(session), artifactId })),
      invalidatesTags: (_result, _error, { artifactId }) => [
        { type: 'Artifact' as const, id: artifactId },
        { type: 'ArtifactContent' as const, id: artifactId },
        { type: 'ArtifactVersions' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: artifactId },
      ],
    }),
  }),
});

export function normalizeArtifacts(data: any) {
  const rows = Array.isArray(data?.artifacts) ? data.artifacts : Array.isArray(data?.data?.artifacts) ? data.data.artifacts : [];
  return [...rows]
    .map((row: any) => normalizeArtifactRecord(row))
    .filter((row: any) => row?.artifact_id || row?.artifactId)
    .sort((a: any, b: any) => {
      const left = Number(b?.updated_unix_ms || b?.updatedUnixMs || b?.created_unix_ms || b?.createdUnixMs || 0);
      const right = Number(a?.updated_unix_ms || a?.updatedUnixMs || a?.created_unix_ms || a?.createdUnixMs || 0);
      return left - right;
    });
}

export function useArtifactContentUrl({ daemonUrl, clientToken, artifactId, versionNo = null }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo?: number | null }) {
  return daemonApi.artifactContentUrl({ daemonUrl, clientToken, artifactId, version: versionNo });
}

export const {
  useListArtifactsQuery,
  useLazyFetchArtifactsPageQuery,
  useFetchArtifactMetaQuery,
  useFetchArtifactVersionsQuery,
  useFetchArtifactTextContentQuery,
  useFetchArtifactAnnotationsQuery,
  useCreateArtifactMutation,
  useUpdateArtifactMutation,
  useRollbackArtifactMutation,
  useCreateArtifactAnnotationMutation,
  useUpdateArtifactAnnotationMutation,
  useDeleteArtifactAnnotationMutation,
  useDeleteArtifactMutation,
} = artifactsApi;
