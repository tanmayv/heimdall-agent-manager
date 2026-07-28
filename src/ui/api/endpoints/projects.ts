import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

export type ProjectBridgePath = {
  bridge_id: string;
  path: string;
  is_validated?: boolean;
  last_validated_at?: string;
  validation_error?: string;
};

export type Project = {
  project_id: string;
  name: string;
  description?: string;
  repo_url?: string;
  vcs_kind?: 'none' | 'git' | 'jj' | string;
  default_path: string;
  is_default_conversations?: boolean;
  created_at?: string;
  updated_at?: string;
  bridge_paths?: ProjectBridgePath[];
};

function projectTagId(project: any, fallback = '') {
  return String(project?.project_id || project?.projectId || fallback || '');
}

export const projectsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listProjects: build.query<any, { scope?: string } | void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/projects');
          const projects = Array.isArray(data) ? data : (data?.projects || []);
          return { data: { projects } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (result) => [
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
        ...((result?.projects || []).map((project: any) => ({ type: 'Project' as const, id: projectTagId(project) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchProject: build.query<any, { projectId: string; scope?: string }>({
      queryFn: async ({ projectId }) => {
        if (!projectId) return { data: { project: null, bridge_paths: [] } };
        try {
          const data = await cookieJsonFetch(`/projects/${encodeURIComponent(projectId)}`);
          const project = data?.project || data;
          const bridge_paths = project?.bridge_paths || data?.bridge_paths || [];
          return { data: { project: { ...project, bridge_paths }, bridge_paths } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId }) => [{ type: 'Project' as const, id: projectId }],
    }),
    createProject: build.mutation<any, { name: string; description?: string; repo_url?: string; vcs_kind?: string; default_path?: string }>({
      queryFn: async (payload) => {
        try {
          const data = await cookieMutation('/projects', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
      ],
    }),
    updateProject: build.mutation<any, { projectId: string; name?: string; description?: string; repo_url?: string; vcs_kind?: string; default_path?: string }>({
      queryFn: async ({ projectId, ...payload }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}`, 'PATCH', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
      ],
    }),
    deleteProject: build.mutation<any, { projectId: string }>({
      queryFn: async ({ projectId }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'Projects' as const, id: 'LIST' },
        { type: 'SidebarProjects' as const, id: 'ALL' },
      ],
    }),
    setProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string; path: string }>({
      queryFn: async ({ projectId, bridgeId, path }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}`, 'PUT', { path });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'ProjectBridgePaths' as const, id: projectId },
      ],
    }),
    deleteProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: async ({ projectId, bridgeId }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
        { type: 'ProjectBridgePaths' as const, id: projectId },
      ],
    }),
    validateProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: async ({ projectId, bridgeId }) => {
        try {
          const data = await cookieMutation(`/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}/validate`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId }) => [
        { type: 'Project' as const, id: projectId },
      ],
    }),
  }),
});

export const {
  useListProjectsQuery,
  useFetchProjectQuery,
  useCreateProjectMutation,
  useUpdateProjectMutation,
  useDeleteProjectMutation,
  useSetProjectBridgePathMutation,
  useDeleteProjectBridgePathMutation,
  useValidateProjectBridgePathMutation,
} = projectsApi;
