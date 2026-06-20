import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

function normalizeMemory(record: any) {
  return {
    id: record.memory_id || '',
    memoryId: record.memory_id || '',
    proposalId: record.proposal_id || '',
    subjectAgent: record.subject_agent || '',
    scope: record.scope || 'global',
    type: record.type || 'fact',
    title: record.title || '',
    body: record.body || '',
    status: record.status || 'pending',
    reason: record.reason || '',
    evidence: record.evidence || '',
    metadataJson: record.metadata_json || '',
    sourceTaskId: record.source_task_id || '',
    version: Number(record.version || 0),
    createdUnixMs: Number(record.created_unix_ms || 0),
    updatedUnixMs: Number(record.updated_unix_ms || 0),
  };
}

function normalizeHistory(event: any) {
  return {
    eventId: event.event_id || '',
    memoryId: event.memory_id || '',
    proposalId: event.proposal_id || '',
    reason: event.reason || '',
    evidence: event.evidence || '',
    author: event.author || '',
    createdUnixMs: Number(event.created_unix_ms || 0),
  };
}

function auth(state: any) {
  const { session } = state.chat;
  return { daemonUrl: session.daemonUrl, clientInstanceId: session.clientInstanceId, clientToken: session.clientToken };
}

export const refreshMemory = createAsyncThunk('memory/refreshMemory', async (_, { getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const { filters } = state.memory;
  if (!session.clientToken) return { records: [] };
  const data = await daemonApi.listMemory({ ...auth(state), subjectAgent: filters.subjectAgent, type: filters.type, status: filters.status, includeAllStatuses: true });
  return { records: (data.records ?? []).map(normalizeMemory) };
});

export const fetchMemoryDetail = createAsyncThunk('memory/fetchMemoryDetail', async (memoryId: string, { getState }) => {
  const state = getState() as any;
  if (!memoryId || !state.chat.session.clientToken) return { memoryId, record: null, history: [] };
  const [detail, history] = await Promise.all([
    daemonApi.showMemory({ ...auth(state), memoryId }),
    daemonApi.memoryHistory({ ...auth(state), memoryId }),
  ]);
  return { memoryId, record: detail.record ? normalizeMemory(detail.record) : null, history: (history.events ?? []).map(normalizeHistory) };
});

export const proposeMemoryChange = createAsyncThunk('memory/proposeMemoryChange', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const result = await daemonApi.proposeMemory({ ...auth(state), ...payload });
  await (dispatch as any)(refreshMemory());
  return result;
});

export const decideMemoryProposal = createAsyncThunk('memory/decideMemoryProposal', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const result = await daemonApi.decideMemory({ ...auth(state), proposalId: payload.proposalId, decision: payload.decision, reason: payload.reason });
  await (dispatch as any)(refreshMemory());
  return result;
});

const initialState = {
  recordsById: {},
  recordIds: [],
  selectedMemoryId: '',
  historyById: {},
  filters: { subjectAgent: '', type: '', status: '' },
  loading: false,
  detailLoading: false,
  error: '',
  lastMemoryEvent: null,
};

const memorySlice = createSlice({
  name: 'memory',
  initialState,
  reducers: {
    selectMemory(state: any, action) {
      state.selectedMemoryId = action.payload || '';
    },
    setMemoryFilters(state: any, action) {
      state.filters = { ...state.filters, ...action.payload };
    },
    memoryEventReceived(state: any, action) {
      state.lastMemoryEvent = action.payload;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(refreshMemory.pending, (state: any) => {
        state.loading = true;
        state.error = '';
      })
      .addCase(refreshMemory.fulfilled, (state: any, action) => {
        state.loading = false;
        const recordsById: any = {};
        const activeFilters = state.filters;
        const recordIds = [...action.payload.records]
          .filter((record: any) => !activeFilters.subjectAgent || record.subjectAgent.toLowerCase().includes(activeFilters.subjectAgent.toLowerCase()))
          .filter((record: any) => !activeFilters.type || record.type === activeFilters.type)
          .filter((record: any) => !activeFilters.status || record.status === activeFilters.status)
          .sort((left, right) => (right.updatedUnixMs || right.createdUnixMs || 0) - (left.updatedUnixMs || left.createdUnixMs || 0))
          .map((record: any) => {
            recordsById[record.memoryId] = record;
            return record.memoryId;
          });
        state.recordsById = recordsById;
        state.recordIds = recordIds;
        if (state.selectedMemoryId && !recordsById[state.selectedMemoryId]) state.selectedMemoryId = '';
        if (!state.selectedMemoryId) state.selectedMemoryId = recordIds[0] || '';
      })
      .addCase(refreshMemory.rejected, (state: any, action) => {
        state.loading = false;
        state.error = action.error.message || 'Failed to load memory';
      })
      .addCase(fetchMemoryDetail.pending, (state: any) => {
        state.detailLoading = true;
      })
      .addCase(fetchMemoryDetail.fulfilled, (state: any, action) => {
        state.detailLoading = false;
        if (action.payload.record) state.recordsById[action.payload.memoryId] = action.payload.record;
        state.historyById[action.payload.memoryId] = action.payload.history;
      })
      .addCase(fetchMemoryDetail.rejected, (state: any, action) => {
        state.detailLoading = false;
        state.error = action.error.message || 'Failed to load memory detail';
      });
  },
});

export const { selectMemory, setMemoryFilters, memoryEventReceived } = memorySlice.actions;
export default memorySlice.reducer;
