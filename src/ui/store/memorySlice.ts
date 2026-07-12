import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

function normalizeStringArray(value: any) {
  if (Array.isArray(value)) return value.map((entry) => String(entry || '').trim()).filter(Boolean);
  if (typeof value === 'string') return value.split(',').map((entry) => entry.trim()).filter(Boolean);
  return [];
}

function normalizeMemory(record: any) {
  return {
    id: record.memory_id || '',
    memoryId: record.memory_id || '',
    proposalId: record.proposal_id || '',
    subjectAgent: record.subject_agent || '',
    scope: record.scope || 'global',
    subjectKey: record.subject_key || '',
    projectIds: normalizeStringArray(record.project_ids),
    roleKeys: normalizeStringArray(record.role_keys),
    taskChainTypes: normalizeStringArray(record.task_chain_types),
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
    subjectKey: event.subject_key || '',
    projectIds: normalizeStringArray(event.project_ids),
    roleKeys: normalizeStringArray(event.role_keys),
    taskChainTypes: normalizeStringArray(event.task_chain_types),
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

function sortMemoryRecords(records: any[]) {
  return [...records].sort((left, right) => (right.updatedUnixMs || right.createdUnixMs || 0) - (left.updatedUnixMs || left.createdUnixMs || 0));
}

function sortMemoryIds(recordsById: Record<string, any>) {
  return sortMemoryRecords(Object.values(recordsById || {})).map((record: any) => record.memoryId);
}

function includesText(value: any, needle: string) {
  return String(value || '').toLowerCase().includes(needle);
}

function includesListValue(values: any[], target: string) {
  const normalizedTarget = String(target || '').trim().toLowerCase();
  if (!normalizedTarget) return true;
  return (values || []).some((value: any) => String(value || '').trim().toLowerCase() === normalizedTarget);
}

function hasTargeting(record: any) {
  return Boolean(record.subjectKey || record.projectIds?.length || record.roleKeys?.length || record.taskChainTypes?.length);
}

const initialFilters = {
  subject: '',
  subjectAgent: '',
  scope: '',
  subjectKey: '',
  projectId: '',
  roleKey: '',
  taskChainType: '',
  type: '',
  status: '',
  targeting: 'all',
  pendingActiveOnly: false,
  search: '',
};

export function matchesMemoryFilters(record: any, filters: any) {
  const subjectFilter = String(filters?.subject || filters?.subjectAgent || '').trim().toLowerCase();
  if (subjectFilter && ![
    record.subjectAgent,
    record.subjectKey,
    record.memoryId,
    record.proposalId,
  ].some((value) => includesText(value, subjectFilter))) return false;

  const scopeFilter = String(filters?.scope || '').trim().toLowerCase();
  if (scopeFilter && String(record.scope || '').trim().toLowerCase() !== scopeFilter) return false;

  const subjectKeyFilter = String(filters?.subjectKey || '').trim().toLowerCase();
  if (subjectKeyFilter && !includesText(record.subjectKey, subjectKeyFilter)) return false;

  const projectIdFilter = String(filters?.projectId || '').trim();
  if (projectIdFilter && !includesListValue(record.projectIds || [], projectIdFilter)) return false;

  const roleKeyFilter = String(filters?.roleKey || '').trim();
  if (roleKeyFilter && !includesListValue(record.roleKeys || [], roleKeyFilter)) return false;

  const taskChainTypeFilter = String(filters?.taskChainType || '').trim();
  if (taskChainTypeFilter && !includesListValue(record.taskChainTypes || [], taskChainTypeFilter)) return false;

  const typeFilter = String(filters?.type || '').trim().toLowerCase();
  if (typeFilter && String(record.type || '').trim().toLowerCase() !== typeFilter) return false;

  const statusFilter = String(filters?.status || '').trim().toLowerCase();
  if (statusFilter && String(record.status || '').trim().toLowerCase() !== statusFilter) return false;

  if (filters?.pendingActiveOnly && !['pending', 'active'].includes(String(record.status || '').trim().toLowerCase())) return false;

  if (filters?.targeting === 'targeted' && !hasTargeting(record)) return false;
  if (filters?.targeting === 'untargeted' && hasTargeting(record)) return false;

  const search = String(filters?.search || '').trim().toLowerCase();
  if (!search) return true;
  return [
    record.memoryId,
    record.proposalId,
    record.title,
    record.body,
    record.subjectAgent,
    record.scope,
    record.subjectKey,
    record.type,
    record.status,
    record.reason,
    record.evidence,
    record.metadataJson,
    record.sourceTaskId,
    ...(record.projectIds || []),
    ...(record.roleKeys || []),
    ...(record.taskChainTypes || []),
  ].some((value) => includesText(value, search));
}

export const refreshMemory = createAsyncThunk('memory/refreshMemory', async (_, { getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
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
  filters: { ...initialFilters },
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
    resetMemoryFilters(state: any) {
      state.filters = { ...initialFilters };
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
          state.activeAudit.error = action.payload.reason || action.payload.failure_reason || 'Unknown audit failure';
        }
      } else {
        state.activeAudit = {
          auditId: action.payload.audit_id || '',
          timeRange: '',
          status: action.payload.status || 'completed',
          targetChains: [],
          startedAtUnixMs: Date.now() - 5000,
          completedAtUnixMs: action.payload.completed_at_unix_ms || Date.now(),
          error: action.payload.status === 'failed' ? (action.payload.reason || action.payload.failure_reason || 'Unknown audit failure') : undefined,
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
        const sortedRecords = sortMemoryRecords(action.payload.records || []);
        const recordsById: any = {};
        sortedRecords.forEach((record: any) => {
          recordsById[record.memoryId] = record;
        });
        state.recordsById = recordsById;
        state.recordIds = sortedRecords.map((record: any) => record.memoryId);
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
        if (action.payload.record) {
          state.recordsById[action.payload.memoryId] = action.payload.record;
          state.recordIds = sortMemoryIds(state.recordsById);
        }
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
      .addCase(triggerMemoryAudit.fulfilled, (state: any, action) => {
        state.error = '';
        state.auditLoading = false;
        if (action.payload?.audit_id) {
          if (!state.activeAudit || state.activeAudit.auditId !== action.payload.audit_id) {
            state.activeAudit = {
              auditId: action.payload.audit_id || '',
              timeRange: action.meta.arg.timeRange || (action.meta.arg.targetChains?.length ? 'manual' : ''),
              status: 'started',
              targetChains: action.meta.arg.targetChains || [],
              startedAtUnixMs: Date.now(),
            };
          }
          state.auditLoading = state.activeAudit?.status === 'started';
        }
      })
      .addCase(triggerMemoryAudit.rejected, (state: any, action) => {
        state.auditLoading = false;
        state.error = action.error.message || 'Failed to trigger memory audit';
      });
  },
});

export const selectMemoryState = (state: any) => state.memory;
export const selectMemoryFilters = (state: any) => selectMemoryState(state).filters || initialFilters;
export const selectMemoryRecords = (state: any) => (selectMemoryState(state).recordIds || []).map((id: string) => selectMemoryState(state).recordsById?.[id]).filter(Boolean);
export const selectFilteredMemoryRecords = (state: any) => selectMemoryRecords(state).filter((record: any) => matchesMemoryFilters(record, selectMemoryFilters(state)));
export const selectFilteredMemoryIds = (state: any) => selectFilteredMemoryRecords(state).map((record: any) => record.memoryId);
export const selectPendingMemoryRecords = (state: any) => selectMemoryRecords(state).filter((record: any) => record.status === 'pending');
export const selectPendingMemoryCount = (state: any) => selectPendingMemoryRecords(state).length;
export const selectPendingActiveMemoryRecords = (state: any) => selectMemoryRecords(state).filter((record: any) => ['pending', 'active'].includes(record.status));

export const { setMemoryFilters, resetMemoryFilters, memoryEventReceived, auditStartedReceived, auditEndedReceived, clearActiveAudit } = memorySlice.actions;
export default memorySlice.reducer;
