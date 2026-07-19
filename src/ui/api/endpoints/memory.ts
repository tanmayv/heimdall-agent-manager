import * as daemonApi from '../daemonApi';
import { normalizeHistory, normalizeMemory, sortMemoryRecords } from '../memoryCatalog';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function memoryTagId(record: any, fallback = '') {
  return String(record?.memoryId || record?.memory_id || record?.id || fallback || '');
}

function auth(session: any) {
  return {
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
  };
}

export const memoryApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listMemory: build.query<any, void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken) return { records: [] };
        const data = await daemonApi.listMemory({ ...auth(session), includeAllStatuses: true });
        return { records: sortMemoryRecords((data.records ?? []).map(normalizeMemory)) };
      }),
      providesTags: (result) => [
        { type: 'Memory' as const, id: 'ALL' },
        ...((result?.records || []).map((record: any) => ({ type: 'Memory' as const, id: memoryTagId(record) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    listApplicableMemory: build.query<any, { targetAgentId?: string; targetProjectId?: string }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { records: [] };
        const data = await daemonApi.listApplicableMemory({ ...auth(session), ...arg });
        return { records: sortMemoryRecords((data.records ?? []).map(normalizeMemory)) };
      }),
      providesTags: (result) => [
        { type: 'Memory' as const, id: 'ALL' },
        ...((result?.records || []).map((record: any) => ({ type: 'Memory' as const, id: memoryTagId(record) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchMemory: build.query<any, { memoryId: string }>({
      queryFn: withSessionQuery(async ({ memoryId }, { session }) => {
        if (!memoryId || !session?.clientToken) return { memoryId, record: null };
        const detail = await daemonApi.showMemory({ ...auth(session), memoryId });
        return { memoryId, record: detail.record ? normalizeMemory(detail.record) : null };
      }),
      providesTags: (result, _error, { memoryId }) => [{ type: 'Memory' as const, id: memoryTagId(result?.record, memoryId) }],
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          if (!data?.record) return;
          dispatch(memoryApi.util.updateQueryData('listMemory', undefined, (draft: any) => {
            const rows = draft?.records || (draft.records = []);
            const index = rows.findIndex((record: any) => record.memoryId === data.record.memoryId);
            if (index >= 0) rows[index] = data.record;
            else rows.push(data.record);
            draft.records = sortMemoryRecords(rows);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchMemoryHistory: build.query<any, { memoryId: string }>({
      queryFn: withSessionQuery(async ({ memoryId }, { session }) => {
        if (!memoryId || !session?.clientToken) return { memoryId, events: [] };
        const history = await daemonApi.memoryHistory({ ...auth(session), memoryId });
        return { memoryId, events: (history.events ?? []).map(normalizeHistory) };
      }),
      providesTags: (_result, _error, { memoryId }) => [{ type: 'MemoryHistory' as const, id: memoryId }],
    }),
    proposeMemoryChange: build.mutation<any, any>({
      queryFn: withSessionQuery(async (payload, { session }) => {
        if (!session?.clientToken) throw new Error('Not authenticated');
        return daemonApi.proposeMemory({ ...auth(session), ...payload });
      }),
      invalidatesTags: (_result, _error, payload) => [
        { type: 'Memory' as const, id: 'ALL' },
        ...(payload?.memoryId ? [{ type: 'Memory' as const, id: payload.memoryId }, { type: 'MemoryHistory' as const, id: payload.memoryId }] : []),
      ],
    }),
    decideMemoryProposal: build.mutation<any, { proposalId: string; decision: 'approve' | 'reject'; reason?: string }>({
      queryFn: withSessionQuery(async (payload, { session }) => {
        if (!session?.clientToken) throw new Error('Not authenticated');
        return daemonApi.decideMemory({ ...auth(session), proposalId: payload.proposalId, decision: payload.decision, reason: payload.reason });
      }),
      invalidatesTags: [{ type: 'Memory', id: 'ALL' }],
    }),
  }),
});

function memoryEventMayChangeListMembership(payload: any) {
  const event = String(payload?.event || payload?.change || payload?.kind || '').toLowerCase();
  const action = String(payload?.action || '').toLowerCase();
  const status = String(payload?.status || '').toLowerCase();
  return [
    event,
    action,
    status,
  ].some((value) => (
    value.includes('proposed') ||
    value.includes('approved') ||
    value.includes('rejected') ||
    value.includes('archived') ||
    value.includes('rollback') ||
    value.includes('edit') ||
    value.includes('created') ||
    value.includes('deleted') ||
    value.includes('active') ||
    value.includes('pending')
  ));
}

export function patchMemoryCachesFromWs(dispatch: any, payload: any) {
  const rawRecord = payload?.record || payload?.memory || null;
  const memoryId = String(payload?.memory_id || rawRecord?.memory_id || rawRecord?.memoryId || '');
  const membershipChanged = memoryEventMayChangeListMembership(payload);
  if (rawRecord && memoryId) {
    const record = normalizeMemory({ ...rawRecord, memory_id: memoryId });
    dispatch(memoryApi.util.upsertQueryData('fetchMemory', { memoryId }, { memoryId, record }));
    dispatch(memoryApi.util.updateQueryData('listMemory', undefined, (draft: any) => {
      const rows = draft?.records || (draft.records = []);
      const index = rows.findIndex((item: any) => item.memoryId === memoryId);
      if (index >= 0) rows[index] = { ...rows[index], ...record };
      else rows.push(record);
      draft.records = sortMemoryRecords(rows);
    }));
  }
  const tags: any[] = [];
  if (memoryId) {
    tags.push({ type: 'Memory', id: memoryId }, { type: 'MemoryHistory', id: memoryId });
  }
  // Daemon memory_event payloads are often id-only membership/status changes
  // such as Memory_Proposed or Memory_Approved. A newly proposed/activated
  // record is not yet present in subscribed listMemory/listApplicableMemory
  // caches, so those queries only provide Memory:ALL and would not refetch on a
  // per-id invalidation. Invalidate ALL for membership-affecting events while
  // retaining per-id detail/history invalidation.
  if (!memoryId || membershipChanged || rawRecord) {
    tags.push({ type: 'Memory', id: 'ALL' });
  }
  if (tags.length > 0) dispatch(heimdallApi.util.invalidateTags(tags));
}

export const {
  useListMemoryQuery,
  useListApplicableMemoryQuery,
  useFetchMemoryQuery,
  useFetchMemoryHistoryQuery,
  useProposeMemoryChangeMutation,
  useDecideMemoryProposalMutation,
} = memoryApi;
