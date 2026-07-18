import type { ProjectAnchor } from '../daemonApi';
import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

export type { ProjectAnchor };

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientInstanceId: session.clientInstanceId, clientToken: session.clientToken };
}

function projectTagId(project: any, fallback = '') {
  return String(project?.projectId || project?.project_id || fallback || '');
}

export const projectsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listProjects: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken) return { projects: [] };
        const data = await daemonApi.listProjects(auth(session));
        const projects = [...(data.projects || [])].sort((left: any, right: any) => {
          const diff = (left.order ?? 0) - (right.order ?? 0);
          if (diff !== 0) return diff;
          return (right.updatedUnixMs || right.createdUnixMs || 0) - (left.updatedUnixMs || left.createdUnixMs || 0);
        });
        return { ...data, projects };
      }),
      providesTags: (result) => [
        { type: 'Projects' as const, id: 'LIST' },
        ...((result?.projects || []).map((project: any) => ({ type: 'Project' as const, id: projectTagId(project) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchProject: build.query<any, { projectId: string; scope?: string }>({
      queryFn: withSessionQuery(async ({ projectId }, { session }) => {
        if (!session?.clientToken || !projectId) return { project: null };
        return daemonApi.showProject({ ...auth(session), projectId });
      }),
      providesTags: (_result, _error, { projectId }) => [{ type: 'Project' as const, id: projectId }],
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const project = data?.project;
          const id = projectTagId(project);
          if (!id) return;
          dispatch(projectsApi.util.updateQueryData('listProjects', undefined, (draft: any) => {
            const rows = draft?.projects || (draft.projects = []);
            const index = rows.findIndex((item: any) => projectTagId(item) === id);
            if (index >= 0) rows[index] = project;
            else rows.unshift(project);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    createProject: build.mutation<any, { name: string; description?: string; anchors?: ProjectAnchor[] }>({
      queryFn: withSessionQuery(async ({ name, description, anchors = [] }, { session }) => {
        return daemonApi.createProject({ ...auth(session), name, description, anchors });
      }),
      invalidatesTags: [{ type: 'Projects' as const, id: 'LIST' }],
    }),
    updateProject: build.mutation<any, { projectId: string; name?: string; description?: string; anchors?: ProjectAnchor[] }>({
      queryFn: withSessionQuery(async ({ projectId, name, description, anchors = [] }, { session }) => {
        return daemonApi.updateProject({ ...auth(session), projectId, name, description, anchors });
      }),
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'Projects' as const, id: 'LIST' },
      ],
    }),
    deleteProject: build.mutation<any, { projectId: string }>({
      queryFn: withSessionQuery(async ({ projectId }, { session }) => daemonApi.deleteProject({ ...auth(session), projectId })),
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'Projects' as const, id: 'LIST' },
      ],
    }),
    reorderProjects: build.mutation<any, { projectIds: string[] }>({
      queryFn: withSessionQuery(async ({ projectIds }, { session }) => daemonApi.reorderProjects({ ...auth(session), projectIds })),
      invalidatesTags: [{ type: 'Projects' as const, id: 'LIST' }],
    }),
  }),
});

export const {
  useListProjectsQuery,
  useFetchProjectQuery,
  useCreateProjectMutation,
  useUpdateProjectMutation,
  useDeleteProjectMutation,
  useReorderProjectsMutation,
} = projectsApi;
