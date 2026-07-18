import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

type ArtifactListArgs = {
  projectId?: string;
  creatorId?: string;
  originRef?: string;
  includeDeleted?: boolean;
  limit?: number;
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

function artifactContentUrl(session: any, artifactId: string, versionNo?: number | null) {
  return daemonApi.artifactContentUrl({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, artifactId, version: versionNo });
}

export const artifactsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listArtifacts: build.query<any, ArtifactListArgs>({
      queryFn: withSessionQuery(async ({ projectId = '', creatorId = '', originRef = '', includeDeleted = false, limit = 100 }, { session }) => {
        if (!session?.clientToken) return { artifacts: [] };
        const data = await daemonApi.listArtifacts({ ...auth(session), projectId, creatorId, originRef, includeDeleted, limit });
        return { ...data, artifacts: normalizeArtifacts(data) };
      }),
      providesTags: (result, _error, { projectId = '', originRef = '' }) => [
        { type: 'Artifact' as const, id: projectListTag(projectId) },
        ...(originRef ? [{ type: 'Artifact' as const, id: originListTag(originRef) }] : []),
        ...((result?.artifacts || []).map((artifact: any) => ({ type: 'Artifact' as const, id: artifactIdOf(artifact) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchArtifactMeta: build.query<any, { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!session?.clientToken || !artifactId) return { artifact: null };
        return daemonApi.fetchArtifactMeta({ ...auth(session), artifactId });
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'Artifact' as const, id: artifactId }],
    }),
    fetchArtifactVersions: build.query<any, { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!session?.clientToken || !artifactId) return { versions: [] };
        return daemonApi.fetchArtifactVersions({ ...auth(session), artifactId });
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactVersions' as const, id: artifactId }],
    }),
    fetchArtifactTextContent: build.query<any, ArtifactTextContentArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session }) => {
        if (!session?.clientToken || !artifactId) return { artifactId, versionNo, text: '' };
        const response = await fetch(artifactContentUrl(session, artifactId, versionNo));
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        return { artifactId, versionNo, text: await response.text() };
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
  const rows = Array.isArray(data?.artifacts) ? data.artifacts : [];
  return [...rows]
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
