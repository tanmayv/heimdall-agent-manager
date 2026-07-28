import { useEffect, useState } from 'react';
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
  file?: File | Blob | null;
  name: string;
  kind?: string;
  mime?: string;
  projectId?: string;
  description?: string;
  originKind?: string;
  originRef?: string;
  contentBase64?: string;
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

function isElectronDeviceAuth(): boolean {
  return typeof window !== 'undefined' && Boolean((window as any).odinApi?.deviceAuth);
}

function auth(session: any) {
  // Hub v1 artifact endpoints should be auth-mode neutral. In the routed
  // Authentik app, same-origin cookies authenticate relative /api/v1 requests;
  // in Electron, the fetch bridge rewrites relative /api/v1 requests to the
  // configured Hub and injects the secure-store user token. Do not pass legacy
  // Redux clientToken values on those paths.
  const token = String(session?.clientToken || '');
  if (isElectronDeviceAuth() || token === 'v1') return { daemonUrl: '', clientToken: '' };
  return { daemonUrl: session.daemonUrl, clientToken: token };
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

function artifactContentUrl(session: any, artifactId: string, versionNo?: number | null) {
  const a = auth(session);
  return daemonApi.artifactContentUrl({ daemonUrl: a.daemonUrl, clientToken: a.clientToken, artifactId, version: versionNo });
}

function artifactFetchInit(session: any): RequestInit {
  const a = auth(session);
  return a.clientToken
    ? { headers: { 'Authorization': `Bearer ${a.clientToken}` }, credentials: 'omit' }
    : { credentials: 'include' };
}

export const artifactsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listArtifacts: build.query<any, ArtifactListArgs>({
      queryFn: withSessionQuery(async ({ projectId = '', creatorId = '', originRef = '', includeDeleted = false, limit = 20, offset = 0 }, { session }) => {
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
        if (!artifactId) return { artifact: null };
        const data = await daemonApi.fetchArtifactMeta({ ...auth(session), artifactId });
        return { ...data, artifact: normalizeArtifact(data?.artifact || data?.data || data) };
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'Artifact' as const, id: artifactId }],
    }),
    fetchArtifactVersions: build.query<any, { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!artifactId) return { versions: [] };
        try {
          const data = await daemonApi.fetchArtifactVersions({ ...auth(session), artifactId });
          return { ...data, versions: Array.isArray(data?.versions) ? data.versions : (Array.isArray(data?.data) ? data.data : []) };
        } catch {
          return { versions: [] };
        }
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactVersions' as const, id: artifactId }],
    }),
    fetchArtifactTextContent: build.query<any, ArtifactTextContentArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session }) => {
        if (!artifactId) return { artifactId, versionNo, text: '' };
        const response = await fetch(artifactContentUrl(session, artifactId, versionNo), artifactFetchInit(session));
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        return { artifactId, versionNo, text: await response.text() };
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactContent' as const, id: artifactId }],
      keepUnusedDataFor: 0,
    }),
    fetchArtifactAnnotations: build.query<any, ArtifactAnnotationsArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session }) => {
        if (!artifactId) return { annotations: [] };
        try {
          const data = await daemonApi.fetchArtifactAnnotations({ ...auth(session), artifactId, versionNo });
          return { ...data, annotations: Array.isArray(data?.annotations) ? data.annotations : (Array.isArray(data?.data) ? data.data : []) };
        } catch {
          return { annotations: [] };
        }
      }),
      providesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    createArtifact: build.mutation<any, ArtifactCreateArgs>({
      queryFn: withSessionQuery(async (args, { session }) => {
        const data = await daemonApi.createArtifact({ ...auth(session), ...args });
        const artifact = normalizeArtifact(data?.artifact || data?.data || data);
        return { ...data, artifact, link: artifact?.link || (artifact?.artifact_id ? `artifact://${artifact.artifact_id}` : '') };
      }),
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

export function normalizeArtifact(row: any) {
  if (!row) return null;
  const artifactId = artifactIdOf(row);
  const mime = String(row?.mime || row?.content_type || row?.contentType || '');
  const rawSize = row?.size_bytes ?? row?.sizeBytes ?? row?.size;
  const sizeBytes = Number(rawSize || 0);
  return {
    ...row,
    artifact_id: artifactId,
    artifactId,
    mime,
    content_type: row?.content_type || row?.contentType || mime,
    size_bytes: Number.isFinite(sizeBytes) ? sizeBytes : 0,
    sizeBytes: Number.isFinite(sizeBytes) ? sizeBytes : 0,
    link: row?.link || (artifactId ? `artifact://${artifactId}` : ''),
  };
}

export function normalizeArtifacts(data: any) {
  const rows = Array.isArray(data?.artifacts)
    ? data.artifacts
    : (Array.isArray(data?.data) ? data.data : (Array.isArray(data) ? data : []));
  return rows
    .map((row: any) => normalizeArtifact(row))
    .filter((row: any) => row?.artifact_id || row?.artifactId)
    .sort((a: any, b: any) => {
      const left = Number(b?.updated_unix_ms || b?.updatedUnixMs || b?.updated_at || b?.updatedAt || b?.created_unix_ms || b?.createdUnixMs || 0);
      const right = Number(a?.updated_unix_ms || a?.updatedUnixMs || a?.updated_at || a?.updatedAt || a?.created_unix_ms || a?.createdUnixMs || 0);
      return left - right;
    });
}

export function useArtifactContentState({ daemonUrl, clientToken, artifactId, versionNo = null }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo?: number | null }) {
  const [state, setState] = useState<{ url: string; loading: boolean; error: string }>({ url: '', loading: false, error: '' });
  useEffect(() => {
    const token = String(clientToken || '');
    const ambientAuth = isElectronDeviceAuth() || token === 'v1';
    if (!artifactId || (!ambientAuth && (!daemonUrl || !token))) {
      setState({ url: '', loading: false, error: '' });
      return;
    }
    let cancelled = false;
    let nextUrl = '';
    setState({ url: '', loading: true, error: '' });
    fetch(daemonApi.artifactContentUrl({ daemonUrl: ambientAuth ? '' : daemonUrl, artifactId, version: versionNo }), ambientAuth
      ? { credentials: 'include' }
      : { headers: token ? { 'Authorization': `Bearer ${token}` } : undefined, credentials: token ? 'omit' : 'include' })
      .then((response) => {
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        return response.blob();
      })
      .then((blob) => {
        nextUrl = URL.createObjectURL(blob);
        if (cancelled) URL.revokeObjectURL(nextUrl);
        else setState({ url: nextUrl, loading: false, error: '' });
      })
      .catch((err) => {
        if (!cancelled) setState({ url: '', loading: false, error: String(err?.message || err || 'Failed to load artifact content') });
      });
    return () => {
      cancelled = true;
      if (nextUrl) URL.revokeObjectURL(nextUrl);
    };
  }, [daemonUrl, clientToken, artifactId, versionNo]);
  return state;
}

export function useArtifactContentUrl({ daemonUrl, clientToken, artifactId, versionNo = null }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo?: number | null }) {
  return useArtifactContentState({ daemonUrl, clientToken, artifactId, versionNo }).url;
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
