import { createSlice } from '@reduxjs/toolkit';
import type { ProjectAnchor } from '../api/daemonApi';

export type { ProjectAnchor };

const initialState = {
  selectedProjectId: '',
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
});

export const { selectProject, clearProjectError } = projectSlice.actions;
export default projectSlice.reducer;
