import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import type { ProjectAnchor } from '../api/daemonApi';

export type { ProjectAnchor };

function auth(state: any) {
  const { session } = state.chat;
  return { daemonUrl: session.daemonUrl, clientInstanceId: session.clientInstanceId, clientToken: session.clientToken };
}

export const refreshProjects = createAsyncThunk('projects/refreshProjects', async (_, { getState }) => {
  const state = getState() as any;
  if (!state.chat.session.clientToken) return { projects: [] };
  return daemonApi.listProjects(auth(state));
});

export const fetchProjectDetail = createAsyncThunk('projects/fetchProjectDetail', async (projectId: string | undefined, { getState }) => {
  const state = getState() as any;
  const selectedProjectId = projectId || state.projects.selectedProjectId;
  if (!selectedProjectId || !state.chat.session.clientToken) return { project: null };
  return daemonApi.showProject({ ...auth(state), projectId: selectedProjectId });
});

export const createProjectFromUi = createAsyncThunk('projects/createProjectFromUi', async (payload: { name: string; description?: string; anchors?: ProjectAnchor[] }, { dispatch, getState }) => {
  const state = getState() as any;
  const result = await daemonApi.createProject({ ...auth(state), name: payload.name, description: payload.description, anchors: payload.anchors || [] });
  await (dispatch as any)(refreshProjects());
  return result;
});

export const updateProjectFromUi = createAsyncThunk('projects/updateProjectFromUi', async (payload: { projectId: string; name?: string; description?: string; anchors?: ProjectAnchor[] }, { dispatch, getState }) => {
  const state = getState() as any;
  const result = await daemonApi.updateProject({ ...auth(state), projectId: payload.projectId, name: payload.name, description: payload.description, anchors: payload.anchors || [] });
  await (dispatch as any)(refreshProjects());
  await (dispatch as any)(fetchProjectDetail(payload.projectId));
  return result;
});

const initialState = {
  projectsById: {},
  projectIds: [],
  selectedProjectId: '',
  loading: false,
  detailLoading: false,
  mutating: false,
  error: '',
};

const projectSlice = createSlice({
  name: 'projects',
  initialState,
  reducers: {
    selectProject(state: any, action) {
      state.selectedProjectId = action.payload || '';
    },
    clearProjectError(state: any) {
      state.error = '';
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(refreshProjects.pending, (state: any) => {
        state.loading = true;
        state.error = '';
      })
      .addCase(refreshProjects.fulfilled, (state: any, action) => {
        state.loading = false;
        const projectsById: any = {};
        const projectIds = [...(action.payload.projects ?? [])]
          .sort((left: any, right: any) => (right.updatedUnixMs || right.createdUnixMs || 0) - (left.updatedUnixMs || left.createdUnixMs || 0))
          .map((project: any) => {
            projectsById[project.projectId] = project;
            return project.projectId;
          });
        state.projectsById = projectsById;
        state.projectIds = projectIds;
        if (state.selectedProjectId && !projectsById[state.selectedProjectId]) state.selectedProjectId = '';
        if (!state.selectedProjectId) state.selectedProjectId = projectIds[0] || '';
      })
      .addCase(refreshProjects.rejected, (state: any, action) => {
        state.loading = false;
        state.error = action.error.message || 'Failed to load projects';
      })
      .addCase(fetchProjectDetail.pending, (state: any) => {
        state.detailLoading = true;
        state.error = '';
      })
      .addCase(fetchProjectDetail.fulfilled, (state: any, action) => {
        state.detailLoading = false;
        if (action.payload.project) {
          const project = action.payload.project;
          state.projectsById[project.projectId] = project;
          if (!state.projectIds.includes(project.projectId)) state.projectIds.unshift(project.projectId);
          state.selectedProjectId = project.projectId;
        }
      })
      .addCase(fetchProjectDetail.rejected, (state: any, action) => {
        state.detailLoading = false;
        state.error = action.error.message || 'Failed to load project';
      })
      .addCase(createProjectFromUi.pending, (state: any) => {
        state.mutating = true;
        state.error = '';
      })
      .addCase(createProjectFromUi.fulfilled, (state: any, action) => {
        state.mutating = false;
        if (action.payload.project_id) state.selectedProjectId = action.payload.project_id;
      })
      .addCase(createProjectFromUi.rejected, (state: any, action) => {
        state.mutating = false;
        state.error = action.error.message || 'Failed to create project';
      })
      .addCase(updateProjectFromUi.pending, (state: any) => {
        state.mutating = true;
        state.error = '';
      })
      .addCase(updateProjectFromUi.fulfilled, (state: any) => {
        state.mutating = false;
      })
      .addCase(updateProjectFromUi.rejected, (state: any, action) => {
        state.mutating = false;
        state.error = action.error.message || 'Failed to update project';
      });
  },
});

export const { selectProject, clearProjectError } = projectSlice.actions;
export default projectSlice.reducer;
