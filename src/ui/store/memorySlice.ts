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
  const data = await daemonApi.listMemory({ ...auth(state), includeAllStatuses: true });
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

export const triggerMemoryAudit = createAsyncThunk(
  'memory/triggerMemoryAudit',
  async (
    payload: { timeRange?: string; targetChains?: string[]; auditorInstructions?: string },
    { getState }
  ) => {
    const state = getState() as any;
    const { session } = state.chat;
    if (!session.clientToken) throw new Error('Not authenticated');
    const result = await daemonApi.triggerMemoryAudit({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
      timeRange: payload.timeRange,
      targetChains: payload.targetChains,
      auditorInstructions: payload.auditorInstructions,
    });
    return result;
  }
);

const initialState = {
  recordsById: {} as Record<string, any>,
  recordIds: [] as string[],
  historyById: {} as Record<string, any[]>,
  filters: { subjectAgent: '', type: '', status: '' },
  loading: false,
  detailLoading: false,
  error: '',
  lastMemoryEvent: null as any,
  activeAudit: null as {
    auditId: string;
    timeRange: string;
    status: string;
    targetChains: string[];
    startedAtUnixMs: number;
    completedAtUnixMs?: number;
    error?: string;
  } | null,
  auditLoading: false,
};

const memorySlice = createSlice({
  name: 'memory',
  initialState,
  reducers: {
    setMemoryFilters(state: any, action) {
      state.filters = { ...state.filters, ...action.payload };
    },
    memoryEventReceived(state: any, action) {
      state.lastMemoryEvent = action.payload;
    },
    auditStartedReceived(state: any, action) {
      state.activeAudit = {
        auditId: action.payload.audit_id || '',
        timeRange: action.payload.time_range || '',
        status: 'started',
        targetChains: action.payload.target_chains || [],
        startedAtUnixMs: Date.now(),
      };
      state.auditLoading = true;
      state.error = '';
    },
    auditEndedReceived(state: any, action) {
      if (state.activeAudit && state.activeAudit.auditId === action.payload.audit_id) {
        state.activeAudit.status = action.payload.status || 'completed';
        state.activeAudit.completedAtUnixMs = action.payload.completed_at_unix_ms || Date.now();
        if (action.payload.status === 'failed') {
          state.activeAudit.error = action.payload.reason || 'Unknown audit failure';
        }
      } else {
        // If we missed the start event (e.g. page refresh), create a completed stub
        state.activeAudit = {
          auditId: action.payload.audit_id || '',
          timeRange: '',
          status: action.payload.status || 'completed',
          targetChains: [],
          startedAtUnixMs: Date.now() - 5000,
          completedAtUnixMs: action.payload.completed_at_unix_ms || Date.now(),
          error: action.payload.status === 'failed' ? (action.payload.reason || 'Unknown audit failure') : undefined,
        };
      }
      state.auditLoading = false;
    },
    clearActiveAudit(state: any) {
      state.activeAudit = null;
      state.error = '';
    }
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
      })
      .addCase(triggerMemoryAudit.pending, (state: any) => {
        state.auditLoading = true;
        state.error = '';
      })
      .addCase(triggerMemoryAudit.fulfilled, (state: any) => {
        state.error = '';
      })
      .addCase(triggerMemoryAudit.rejected, (state: any, action) => {
        state.auditLoading = false;
        state.error = action.error.message || 'Failed to trigger memory audit';
      });
  },
});

export const { setMemoryFilters, memoryEventReceived, auditStartedReceived, auditEndedReceived, clearActiveAudit } = memorySlice.actions;
export default memorySlice.reducer;
